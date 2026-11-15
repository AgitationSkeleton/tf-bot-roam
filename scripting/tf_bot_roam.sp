/**
 * TF2 Bot Roam
 *
 * On maps without an objective (trade_, hangout, idle and many custom maps)
 * stock TFBots of most classes stand still. Spy and Sniper have their own
 * roaming behaviours, Medics follow patients and Engineers build, but every
 * other class - including class-10 bots from custom-class plugins - falls back
 * to CTFBotSeekAndDestroy, whose destinations come from
 * CTFNavMesh::CollectSpawnRoomThresholdAreas. That function reads
 * TheNavAreas[i] instead of the exit list, so the "goals" are whatever areas
 * the .nav file stores first: in practice the bots go nowhere.
 *
 * TFBot's scenario selection checks for a flag to fetch before that fallback
 * (CTFBotScenarioMonitor::DesiredScenarioAndClassAction -> GetFlagToFetch ->
 * CTFBotFetchFlag), and CTFBotFetchFlag paths straight to the flag every 1-2 s.
 * This plugin (same idea as EfeDursun's "Bots on Payload Race") gives each team
 * an invisible enemy flag to fetch and moves it around the map's playable
 * spots: bots of every class roam toward it, meet and fight on the way, and
 * move on when it moves.
 *
 * Safety:
 *  - Nobody can pick the flags up (touch is blocked), so there are no
 *    captures, drops, returns, announcer lines or score.
 *  - The flags are not drawn and their glow is disabled.
 *  - The game type is decided at map start (CTFGameRules::Activate), before the
 *    flags exist, so the map stays in its normal mode (no CTF HUD).
 *  - Maps that already have an objective are left alone (tf_bot_roam_mode auto).
 *
 * Standard entities only: no gamedata, offsets or SDK calls.
 */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "3.0.0"
#define ROAM_NAME      "tf_bot_roam"
#define MAX_SPOTS      256

public Plugin myinfo =
{
	name        = "TF2 Bot Roam",
	author      = "AgitationSkeleton",
	description = "Gives stock TFBots somewhere to go on maps without an objective.",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/AgitationSkeleton/tf-bot-roam"
};

ConVar g_cvMode;
ConVar g_cvInterval;
ConVar g_cvArrive;
ConVar g_cvSpread;
ConVar g_cvDebug;
ConVar g_cvMeet;

bool g_bActive;
char g_sReason[160];
// Index 0: RED's flag (BLU bots fetch it), 1: BLU's flag (RED bots fetch it).
int g_iFlag[2] = { INVALID_ENT_REFERENCE, ... };
int g_iFlagSpot[2] = { -1, ... };
float g_flArrivedAt[2];
float g_vSpots[MAX_SPOTS][3];
int g_iSpots;
int g_iNextMove;
Handle g_hMoveTimer;
Handle g_hWatchTimer;

/* Objective entities: any of these means stock bots already have targets. */
static const char g_sObjectives[][] =
{
	"team_control_point", "team_control_point_master", "item_teamflag", "team_train_watcher",
	"func_capturezone", "tf_logic_mann_vs_machine", "passtime_logic", "tf_logic_robot_destruction",
	"tf_logic_player_destruction", "tf_logic_koth", "tf_logic_hybrid_ctf_cp", "tf_logic_arena"
};

/* Classes never used as spot sources (players, ours, world-wide logic). */
static const char g_sSpotSkip[][] =
{
	"player", "worldspawn", "tf_", "team_", "logic_", "info_player_", "point_", "env_fog", "env_sky",
	"sky_camera", "func_respawnroom", "item_teamflag", "game_", "filter_", "math_", "instructor_",
	"monster_resource", "light_environment", "shadow_control", "water_lod_control", "env_tonemap",
	"env_wind", "func_occluder", "info_node", "info_map", "predicted_viewmodel"
};

public void OnPluginStart()
{
	CreateConVar("tf_bot_roam_version", PLUGIN_VERSION, "TF2 Bot Roam version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvMode = CreateConVar("tf_bot_roam_mode", "auto", "auto = only maps without an objective | force = every map without flags | off");
	g_cvInterval = CreateConVar("tf_bot_roam_interval", "30", "Seconds between moving one of the flags (fallback when nobody reaches it).", _, true, 10.0);
	g_cvArrive = CreateConVar("tf_bot_roam_arrive_delay", "5", "Seconds a flag stays once someone reaches it before it moves on.", _, true, 1.0);
	g_cvSpread = CreateConVar("tf_bot_roam_min_distance", "768", "A moved flag goes at least this far from its last spot (when possible).", _, true, 0.0);
	g_cvMeet = CreateConVar("tf_bot_roam_meet_chance", "0.5", "Chance a moved flag lands near the other team's flag, so both teams head for the same area and meet (big maps).", _, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("tf_bot_roam_debug", "0", "1 = log what the plugin does.", _, true, 0.0, true, 1.0);
	AutoExecConfig(true, "tf_bot_roam");

	HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	RegAdminCmd("sm_botroam", Cmd_Status, ADMFLAG_GENERIC, "Show TF2 Bot Roam state; 'sm_botroam apply' re-applies, 'sm_botroam move' moves a flag now.");
}

public void OnMapStart()
{
	g_bActive = false;
	g_iSpots = 0;
	g_iNextMove = 0;
	g_sReason[0] = '\0';
	for (int i = 0; i < 2; i++)
	{
		g_iFlag[i] = INVALID_ENT_REFERENCE;
		g_iFlagSpot[i] = -1;
		g_flArrivedAt[i] = 0.0;
	}
	g_hMoveTimer = null;   // TIMER_FLAG_NO_MAPCHANGE timers are gone
	g_hWatchTimer = null;
}

public void OnConfigsExecuted()
{
	CreateTimer(2.0, Timer_Apply, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	// Round restarts remove entities the map did not create.
	CreateTimer(1.0, Timer_Apply, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Apply(Handle timer)
{
	Apply();
	return Plugin_Stop;
}

public Action Cmd_Status(int client, int args)
{
	char a[16];
	GetCmdArg(1, a, sizeof(a));
	if (StrEqual(a, "apply", false))
		Apply();
	else if (StrEqual(a, "move", false) && g_bActive)
		MoveFlag(g_iNextMove++ % 2);
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	ReplyToCommand(client, "[BotRoam] %s: %s, %d spot(s)%s%s", map, g_bActive ? "ACTIVE" : "inactive", g_iSpots,
		g_sReason[0] ? " - " : "", g_sReason);
	for (int i = 0; i < 2; i++)
	{
		int f = EntRefToEntIndex(g_iFlag[i]);
		if (f <= 0)
			continue;
		float pos[3];
		GetEntPropVector(f, Prop_Data, "m_vecAbsOrigin", pos);
		ReplyToCommand(client, "[BotRoam]   %s flag (fetched by %s) at %.0f %.0f %.0f, %d player(s) there", i == 0 ? "RED" : "BLU",
			i == 0 ? "BLU" : "RED", pos[0], pos[1], pos[2], PlayersAt(pos));
	}
	return Plugin_Handled;
}

void Apply()
{
	char mode[16];
	g_cvMode.GetString(mode, sizeof(mode));
	if (StrEqual(mode, "off", false))
	{
		Teardown();
		strcopy(g_sReason, sizeof(g_sReason), "tf_bot_roam_mode off");
		return;
	}
	if (!g_bActive && !MapNeedsHelp(StrEqual(mode, "force", false), g_sReason, sizeof(g_sReason)))
	{
		Debug("not applied: %s", g_sReason);
		return;
	}
	if (g_iSpots == 0)
		CollectSpots();
	if (g_iSpots < 2)
	{
		strcopy(g_sReason, sizeof(g_sReason), "not enough playable spots found");
		Teardown();
		return;
	}

	Teardown();
	for (int i = 0; i < 2; i++)
	{
		g_iFlagSpot[i] = PickSpot(-1);
		if (!CreateFlag(i, g_vSpots[g_iFlagSpot[i]]))
		{
			strcopy(g_sReason, sizeof(g_sReason), "could not create the flags");
			Teardown();
			return;
		}
	}
	g_bActive = true;
	FormatEx(g_sReason, sizeof(g_sReason), "one hidden flag per team, moving every %.0f s or %.0f s after someone reaches it",
		g_cvInterval.FloatValue, g_cvArrive.FloatValue);
	g_hMoveTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Move, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	g_hWatchTimer = CreateTimer(1.0, Timer_Watch, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	Debug("applied: %d spots", g_iSpots);
}

bool MapNeedsHelp(bool force, char[] reason, int maxlen)
{
	for (int i = 0; i < sizeof(g_sObjectives); i++)
	{
		if (force && !StrEqual(g_sObjectives[i], "item_teamflag"))
			continue;
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, g_sObjectives[i])) != -1)
		{
			if (!IsOurs(ent))
			{
				FormatEx(reason, maxlen, "map has %s", g_sObjectives[i]);
				return false;
			}
		}
	}
	return true;
}

public Action Timer_Move(Handle timer)
{
	if (!g_bActive)
	{
		g_hMoveTimer = null;
		return Plugin_Stop;
	}
	if (EntRefToEntIndex(g_iFlag[0]) <= 0 || EntRefToEntIndex(g_iFlag[1]) <= 0)
	{
		// Map logic or a round reset removed ours: rebuild.
		g_hMoveTimer = null;
		g_bActive = false;
		Apply();
		return Plugin_Stop;
	}
	AddPlayerSpots();
	MoveFlag(g_iNextMove++ % 2);
	return Plugin_Continue;
}

/** Once someone has stood at a flag for the arrive delay, move it on. */
public Action Timer_Watch(Handle timer)
{
	if (!g_bActive)
	{
		g_hWatchTimer = null;
		return Plugin_Stop;
	}
	float now = GetGameTime();
	for (int i = 0; i < 2; i++)
	{
		int f = EntRefToEntIndex(g_iFlag[i]);
		if (f <= 0)
			continue;
		float pos[3];
		GetEntPropVector(f, Prop_Data, "m_vecAbsOrigin", pos);
		if (PlayersAt(pos) == 0)
		{
			g_flArrivedAt[i] = 0.0;
			continue;
		}
		if (g_flArrivedAt[i] == 0.0)
			g_flArrivedAt[i] = now;
		else if (now - g_flArrivedAt[i] >= g_cvArrive.FloatValue)
		{
			g_flArrivedAt[i] = 0.0;
			AddPlayerSpots();
			MoveFlag(i);
		}
	}
	return Plugin_Continue;
}

int PlayersAt(const float pos[3])
{
	int n = 0;
	float c[3];
	for (int k = 1; k <= MaxClients; k++)
	{
		if (!IsClientInGame(k) || !IsPlayerAlive(k) || GetClientTeam(k) < 2)
			continue;
		GetClientAbsOrigin(k, c);
		if (FloatAbs(c[0] - pos[0]) <= 160.0 && FloatAbs(c[1] - pos[1]) <= 160.0 && FloatAbs(c[2] - pos[2]) <= 96.0)
			n++;
	}
	return n;
}

void MoveFlag(int i)
{
	int f = EntRefToEntIndex(g_iFlag[i]);
	if (f <= 0)
		return;
	int spot = -1;
	if (GetURandomFloat() < g_cvMeet.FloatValue)
		spot = PickSpotNear(g_iFlagSpot[1 - i], g_iFlagSpot[i]);
	if (spot < 0)
		spot = PickSpot(g_iFlagSpot[i]);
	g_iFlagSpot[i] = spot;
	TeleportEntity(f, g_vSpots[spot], NULL_VECTOR, NULL_VECTOR);
	Debug("%s flag -> %.0f %.0f %.0f", i == 0 ? "RED" : "BLU", g_vSpots[spot][0], g_vSpots[spot][1], g_vSpots[spot][2]);
}

/** A random spot 256-1200 units from spot `near` (not `from`), or -1. */
int PickSpotNear(int near, int from)
{
	if (near < 0)
		return -1;
	int cand[MAX_SPOTS], n = 0;
	for (int s = 0; s < g_iSpots; s++)
	{
		if (s == near || s == from)
			continue;
		float d = GetVectorDistance(g_vSpots[s], g_vSpots[near]);
		if (d >= 256.0 && d <= 1200.0)
			cand[n++] = s;
	}
	return n ? cand[GetRandomInt(0, n - 1)] : -1;
}

/** A random spot, preferably far from the one this flag leaves and not the other flag's. */
int PickSpot(int from)
{
	float minDist = g_cvSpread.FloatValue;
	for (int attempt = 0; attempt < 24; attempt++)
	{
		int s = GetRandomInt(0, g_iSpots - 1);
		if (s == from || s == g_iFlagSpot[0] || s == g_iFlagSpot[1])
			continue;
		if (from < 0 || GetVectorDistance(g_vSpots[s], g_vSpots[from]) >= minDist || attempt == 23)
			return s;
	}
	return GetRandomInt(0, g_iSpots - 1);
}

/* ------------------------------------------------------------------ */
/* Playable spots                                                     */
/* ------------------------------------------------------------------ */

/**
 * Any positioned map entity (lights, props, items, sounds, brushes...) hints
 * at somewhere people go; each source and a ring around it is dropped to the
 * floor and must fit a standing player outside the spawn rooms (TryAddSpot).
 */
void CollectSpots()
{
	g_iSpots = 0;
	char cls[64];
	int max = GetMaxEntities();
	for (int ent = MaxClients + 1; ent < max && g_iSpots < MAX_SPOTS; ent++)
	{
		if (!IsValidEntity(ent) || !HasEntProp(ent, Prop_Data, "m_vecAbsOrigin"))
			continue;
		GetEntityClassname(ent, cls, sizeof(cls));
		bool skip = false;
		for (int k = 0; k < sizeof(g_sSpotSkip) && !skip; k++)
			skip = StrContains(cls, g_sSpotSkip[k]) == 0;
		if (skip || IsOurs(ent))
			continue;
		float pos[3];
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
		// Brush entities sit at the world origin: use the centre of their bounds.
		if (HasEntProp(ent, Prop_Send, "m_vecMins"))
		{
			float lo[3], hi[3];
			GetEntPropVector(ent, Prop_Send, "m_vecMins", lo);
			GetEntPropVector(ent, Prop_Send, "m_vecMaxs", hi);
			for (int k = 0; k < 3; k++)
				pos[k] += (lo[k] + hi[k]) * 0.5;
		}
		if (pos[0] == 0.0 && pos[1] == 0.0 && pos[2] == 0.0)
			continue;   // unplaced logic
		TryAddSpot(pos);
		for (int r = 0; r < 8 && g_iSpots < MAX_SPOTS; r++)
		{
			float off[3];
			off = pos;
			off[0] += Cosine(r * 0.785398) * 384.0;
			off[1] += Sine(r * 0.785398) * 384.0;
			if (!TR_PointOutsideWorld(off))
				TryAddSpot(off);
		}
	}
	AddPlayerSpots();
}

/** Where living players stand (outside spawn rooms) is walkable by definition. */
void AddPlayerSpots()
{
	for (int i = 1; i <= MaxClients && g_iSpots < MAX_SPOTS; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || !(GetEntityFlags(i) & FL_ONGROUND))
			continue;
		float pos[3];
		GetClientAbsOrigin(i, pos);
		TryAddSpot(pos);
	}
}

void TryAddSpot(const float origin[3])
{
	float start[3], end[3], floorPos[3];
	start = origin;
	start[2] += 8.0;
	end = origin;
	end[2] -= 2048.0;
	TR_TraceRayFilter(start, end, MASK_PLAYERSOLID, RayType_EndPoint, Filter_World);
	if (!TR_DidHit() || TR_StartSolid())
		return;
	TR_GetEndPosition(floorPos);
	float normal[3];
	TR_GetPlaneNormal(INVALID_HANDLE, normal);
	if (normal[2] < 0.7)
		return;   // too steep to stand on
	floorPos[2] += 2.0;
	float mins[3] = { -24.0, -24.0, 0.0 }, maxs[3] = { 24.0, 24.0, 82.0 };
	TR_TraceHullFilter(floorPos, floorPos, mins, maxs, MASK_PLAYERSOLID, Filter_World);
	if (TR_DidHit())
		return;   // a standing player would not fit
	if (InSpawnRoom(floorPos))
		return;   // bots treat the enemy's spawn room as off limits
	for (int i = 0; i < g_iSpots; i++)
		if (GetVectorDistance(g_vSpots[i], floorPos) < 256.0)
			return;
	g_vSpots[g_iSpots++] = floorPos;
}

public bool Filter_World(int entity, int mask)
{
	return entity == 0;
}

bool InSpawnRoom(const float pos[3])
{
	int room = -1;
	while ((room = FindEntityByClassname(room, "func_respawnroom")) != -1)
	{
		float o[3], lo[3], hi[3];
		GetEntPropVector(room, Prop_Data, "m_vecAbsOrigin", o);
		GetEntPropVector(room, Prop_Send, "m_vecMins", lo);
		GetEntPropVector(room, Prop_Send, "m_vecMaxs", hi);
		if (pos[0] >= o[0] + lo[0] && pos[0] <= o[0] + hi[0]
			&& pos[1] >= o[1] + lo[1] && pos[1] <= o[1] + hi[1]
			&& pos[2] >= o[2] + lo[2] - 16.0 && pos[2] <= o[2] + hi[2])
			return true;
	}
	return false;
}

/* ------------------------------------------------------------------ */
/* Flags                                                              */
/* ------------------------------------------------------------------ */

bool CreateFlag(int i, const float pos[3])
{
	int flag = CreateEntityByName("item_teamflag");
	if (flag == -1)
		return false;
	char name[48];
	FormatEx(name, sizeof(name), "%s_flag%d", ROAM_NAME, i);
	DispatchKeyValue(flag, "targetname", name);
	DispatchKeyValue(flag, "GameType", "0");             // CTF: the enemy team fetches it
	DispatchKeyValue(flag, "TeamNum", i == 0 ? "2" : "3");
	DispatchKeyValue(flag, "ReturnTime", "99999");
	DispatchKeyValue(flag, "trail_effect", "0");
	DispatchKeyValue(flag, "VisibleWhenDisabled", "0");
	TeleportEntity(flag, pos, NULL_VECTOR, NULL_VECTOR);
	if (!DispatchSpawn(flag))
	{
		RemoveEntity(flag);
		return false;
	}
	ActivateEntity(flag);
	SetEntProp(flag, Prop_Send, "m_fEffects", GetEntProp(flag, Prop_Send, "m_fEffects") | 0x020);   // EF_NODRAW
	SetEntityRenderMode(flag, RENDER_NONE);
	SetVariantInt(1);
	AcceptEntityInput(flag, "ForceGlowDisabled");
	// Nobody may pick it up: no captures, drops, returns or announcer lines.
	SDKHook(flag, SDKHook_StartTouch, Hook_BlockTouch);
	SDKHook(flag, SDKHook_Touch, Hook_BlockTouch);
	g_iFlag[i] = EntIndexToEntRef(flag);
	return true;
}

public Action Hook_BlockTouch(int entity, int other)
{
	return Plugin_Handled;
}

void Teardown()
{
	delete g_hMoveTimer;
	delete g_hWatchTimer;
	g_bActive = false;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "item_teamflag")) != -1)
		if (IsOurs(ent))
			RemoveEntity(ent);
	for (int i = 0; i < 2; i++)
	{
		g_iFlag[i] = INVALID_ENT_REFERENCE;
		g_iFlagSpot[i] = -1;
		g_flArrivedAt[i] = 0.0;
	}
}

public void OnPluginEnd()
{
	Teardown();
}

bool IsOurs(int ent)
{
	char name[48];
	GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
	return StrContains(name, ROAM_NAME) == 0;
}

void Debug(const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue)
		return;
	char buf[256], map[PLATFORM_MAX_PATH];
	VFormat(buf, sizeof(buf), fmt, 2);
	GetCurrentMap(map, sizeof(map));
	LogMessage("[%s] %s", map, buf);
}
