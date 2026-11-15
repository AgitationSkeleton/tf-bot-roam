/**
 * TF2 Bot Roam
 *
 * On maps without an objective (trade_, hangout, idle and many custom maps)
 * stock TFBots of most classes stand still: Spy and Sniper have their own
 * roaming behaviours, Medics follow patients and Engineers build, but every
 * other class - including class-10 bots from custom-class plugins - falls back
 * to CTFBotSeekAndDestroy. That behaviour's destinations are "enemy spawn exit"
 * areas (CTFNavMesh::CollectSpawnRoomThresholdAreas), which is buggy: it reads
 * TheNavAreas[i] instead of the exit list, so the goals are whatever areas the
 * .nav file happens to store first - in practice useless spots. Its only other
 * destination is the bot's current control point.
 *
 * This plugin gives the bots that control point. It adds hidden, silent,
 * neutral control points under a disabled team_control_point_master and moves
 * them between play-area spots every so often. Bots of every class head for
 * the current point, hold there briefly, and move on when it moves, meeting
 * and fighting each other on the way.
 *
 * Safety:
 *  - The master starts disabled, so no capture can ever trigger a round win.
 *  - Capturing takes ~28 hours (area_time_to_cap), so it never completes.
 *  - The points are hidden on the HUD, have no model, shadow or capture sounds,
 *    and never warn on capture.
 *  - The game type is decided at map start (CTFGameRules::Activate), before the
 *    points exist, so the map stays in its normal mode.
 *  - Maps that already have an objective are left alone (tf_bot_roam_mode auto).
 *
 * Standard entities only: no gamedata, offsets or SDK calls.
 */
#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.0.0"
#define ROAM_NAME      "tf_bot_roam"
#define BOX_MODEL      "models/items/ammopack_small.mdl"
#define MAX_POINTS     4
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
ConVar g_cvPoints;
ConVar g_cvInterval;
ConVar g_cvSpread;
ConVar g_cvDebug;
ConVar g_cvArrive;
ConVar g_cvExits;
bool g_bMovePending[MAX_POINTS];
float g_flArrivedAt[MAX_POINTS];
Handle g_hWatchTimer;

bool g_bActive;
char g_sReason[128];
int g_iPoint[MAX_POINTS] = { INVALID_ENT_REFERENCE, ... };
int g_iArea[MAX_POINTS] = { INVALID_ENT_REFERENCE, ... };
int g_iMaster = INVALID_ENT_REFERENCE;
int g_iPointSpot[MAX_POINTS] = { -1, ... };
float g_vSpots[MAX_SPOTS][3];
int g_iSpots;
int g_iNextMove;
Handle g_hMoveTimer;

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
	"sky_camera", "func_respawnroom", "trigger_capture_area", "game_", "filter_", "math_", "instructor_",
	"tf_objective_resource", "monster_resource", "tf_gamerules", "light_environment", "shadow_control",
	"water_lod_control", "env_tonemap", "env_wind", "func_occluder", "info_node", "info_map", "predicted_viewmodel"
};

public void OnPluginStart()
{
	CreateConVar("tf_bot_roam_version", PLUGIN_VERSION, "TF2 Bot Roam version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvMode = CreateConVar("tf_bot_roam_mode", "auto", "auto = only maps without an objective | force = every map without a control point master | off");
	g_cvPoints = CreateConVar("tf_bot_roam_points", "2", "Hidden roam points at a time (bots head for one).", _, true, 1.0, true, float(MAX_POINTS));
	g_cvInterval = CreateConVar("tf_bot_roam_interval", "40", "Seconds between moving one of the points.", _, true, 10.0);
	g_cvSpread = CreateConVar("tf_bot_roam_min_distance", "768", "A moved point goes at least this far from its last spot (when possible).", _, true, 0.0);
	g_cvExits = CreateConVar("tf_bot_roam_exits", "0", "0 = hide the map's buggy spawn-exit goals from bots across each nav recompute (spawn rooms disabled ~3 s), so they head for the roam points | 1 = leave them.", _, true, 0.0, true, 1.0);
	g_cvArrive = CreateConVar("tf_bot_roam_arrive_delay", "6", "Seconds a point stays after someone reaches it (starts capturing) before it moves on.", _, true, 1.0);
	g_cvDebug = CreateConVar("tf_bot_roam_debug", "0", "1 = log what the plugin does.", _, true, 0.0, true, 1.0);
	AutoExecConfig(true, "tf_bot_roam");

	HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("teamplay_point_startcapture", Event_StartCapture);
	RegAdminCmd("sm_botroam", Cmd_Status, ADMFLAG_GENERIC, "Show TF2 Bot Roam state; 'sm_botroam apply' re-applies, 'sm_botroam move' moves a point now.");
}

public void OnMapStart()
{
	PrecacheModel(BOX_MODEL, true);
	g_bActive = false;
	g_iSpots = 0;
	g_iNextMove = 0;
	g_sReason[0] = '\0';
	g_iMaster = INVALID_ENT_REFERENCE;
	for (int i = 0; i < MAX_POINTS; i++)
	{
		g_iPoint[i] = g_iArea[i] = INVALID_ENT_REFERENCE;
		g_iPointSpot[i] = -1;
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

/** Someone reached a roam point: move it on after a short hold. */
public void Event_StartCapture(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bActive)
		return;
	int cp = event.GetInt("cp");
	for (int i = 0; i < MAX_POINTS; i++)
	{
		int p = EntRefToEntIndex(g_iPoint[i]);
		if (p <= 0 || g_bMovePending[i] || GetEntProp(p, Prop_Data, "m_iPointIndex") != cp)
			continue;
		g_bMovePending[i] = true;
		CreateTimer(g_cvArrive.FloatValue, Timer_MoveArrived, i, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_MoveArrived(Handle timer, int i)
{
	g_bMovePending[i] = false;
	if (g_bActive)
	{
		AddPlayerSpots();
		MovePoint(i);
	}
	return Plugin_Stop;
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
		MoveOne();
	else if (StrEqual(a, "relink", false))
		LinkAreas();
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	ReplyToCommand(client, "[BotRoam] %s: %s, %d spot(s)%s%s", map, g_bActive ? "ACTIVE" : "inactive", g_iSpots,
		g_sReason[0] ? " - " : "", g_sReason);
	for (int i = 0; i < MAX_POINTS; i++)
	{
		int p = EntRefToEntIndex(g_iPoint[i]);
		if (p <= 0)
			continue;
		float pos[3];
		GetEntPropVector(p, Prop_Data, "m_vecAbsOrigin", pos);
		ReplyToCommand(client, "[BotRoam]   point %d at %.0f %.0f %.0f, %d player(s) there", i, pos[0], pos[1], pos[2], PlayersAtPoint(i));
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
	bool force = StrEqual(mode, "force", false);
	if (!g_bActive && !MapNeedsHelp(force, g_sReason, sizeof(g_sReason)))
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
	int n = g_cvPoints.IntValue;
	for (int i = 0; i < n; i++)
	{
		g_iPointSpot[i] = PickSpot(-1);
		if (!CreatePoint(i, g_vSpots[g_iPointSpot[i]]))
		{
			strcopy(g_sReason, sizeof(g_sReason), "could not create control point entities");
			Teardown();
			return;
		}
	}
	if (!CreateMaster())
	{
		strcopy(g_sReason, sizeof(g_sReason), "could not create control point master");
		Teardown();
		return;
	}
	// The nav recompute runs after the areas are linked (Timer_Link).
	g_bActive = true;
	FormatEx(g_sReason, sizeof(g_sReason), "%d point(s), moving one every %.0f s", n, g_cvInterval.FloatValue);
	delete g_hMoveTimer;
	g_hMoveTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Move, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	delete g_hWatchTimer;
	g_hWatchTimer = CreateTimer(1.0, Timer_Watch, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	Debug("applied: %s, %d spots", g_sReason, g_iSpots);
}

bool MapNeedsHelp(bool force, char[] reason, int maxlen)
{
	for (int i = 0; i < sizeof(g_sObjectives); i++)
	{
		if (force && !StrEqual(g_sObjectives[i], "team_control_point_master") && !StrEqual(g_sObjectives[i], "team_control_point"))
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
	// Map logic or a round reset may have removed ours: rebuild.
	if (EntRefToEntIndex(g_iMaster) <= 0)
	{
		g_hMoveTimer = null;
		g_bActive = false;
		Apply();
		return Plugin_Stop;
	}
	AddPlayerSpots();
	MoveOne();
	return Plugin_Continue;
}

void MoveOne()
{
	MovePoint(g_iNextMove++ % g_cvPoints.IntValue);
}

void MovePoint(int i)
{
	int p = EntRefToEntIndex(g_iPoint[i]);
	int a = EntRefToEntIndex(g_iArea[i]);
	if (p <= 0 || a <= 0)
		return;
	int spot = PickSpot(g_iPointSpot[i]);
	g_iPointSpot[i] = spot;
	TeleportEntity(p, g_vSpots[spot], NULL_VECTOR, NULL_VECTOR);
	TeleportEntity(a, g_vSpots[spot], NULL_VECTOR, NULL_VECTOR);
	RecomputeNav();
	Debug("point %d -> %.0f %.0f %.0f", i, g_vSpots[spot][0], g_vSpots[spot][1], g_vSpots[spot][2]);
}

/** A random spot, preferably far from the one this point leaves and from the other points. */
int PickSpot(int from)
{
	float minDist = g_cvSpread.FloatValue;
	for (int attempt = 0; attempt < 24; attempt++)
	{
		int s = GetRandomInt(0, g_iSpots - 1);
		if (s == from)
			continue;
		bool ok = from < 0 || GetVectorDistance(g_vSpots[s], g_vSpots[from]) >= minDist;
		for (int i = 0; ok && i < MAX_POINTS; i++)
			if (g_iPointSpot[i] == s)
				ok = false;
		if (ok || attempt == 23)
			return s;
	}
	return GetRandomInt(0, g_iSpots - 1);
}

/* ------------------------------------------------------------------ */
/* Playable spots                                                     */
/* ------------------------------------------------------------------ */

/**
 * Any positioned map entity (lights, props, items, sounds, triggers...) is a
 * hint of somewhere people go; each is dropped to the floor and must fit a
 * standing player outside the spawn rooms (TryAddSpot).
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
		// A ring around each source finds floor nearby (rooms, corridors).
		for (int r = 0; r < 8 && g_iSpots < MAX_SPOTS; r++)
		{
			float off[3];
			off = pos;
			off[0] += Cosine(r * 0.785398) * 384.0;
			off[1] += Sine(r * 0.785398) * 384.0;
			if (TR_PointOutsideWorld(off))
				continue;
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
	// Drop to the floor below the point.
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
	// A standing player must fit there.
	float mins[3] = { -24.0, -24.0, 0.0 }, maxs[3] = { 24.0, 24.0, 82.0 };
	TR_TraceHullFilter(floorPos, floorPos, mins, maxs, MASK_PLAYERSOLID, Filter_World);
	if (TR_DidHit())
		return;
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
/* Entities                                                           */
/* ------------------------------------------------------------------ */

bool CreatePoint(int i, const float pos[3])
{
	char name[48], idx[4];
	FormatEx(name, sizeof(name), "%s_cp%d", ROAM_NAME, i);
	IntToString(i, idx, sizeof(idx));

	int point = CreateEntityByName("team_control_point");
	if (point == -1)
		return false;
	DispatchKeyValue(point, "targetname", name);
	DispatchKeyValue(point, "point_index", idx);
	DispatchKeyValue(point, "point_default_owner", "0");
	DispatchKeyValue(point, "point_warn_on_cap", "2");   // never warn
	DispatchKeyValue(point, "point_start_locked", "0");
	DispatchKeyValue(point, "point_printname", "Roam");
	// A point that requires itself is always cappable (CTFGameRules::
	// TeamMayCapturePoint), so linear capping (tf_caplinear) never hides it from bots.
	DispatchKeyValue(point, "team_previouspoint_2_0", name);
	DispatchKeyValue(point, "team_previouspoint_3_0", name);
	// Valid HUD materials (the point is hidden, but the objective resource wants them).
	DispatchKeyValue(point, "team_icon_0", "sprites/obj_icons/icon_obj_neutral");
	DispatchKeyValue(point, "team_icon_2", "sprites/obj_icons/icon_obj_red");
	DispatchKeyValue(point, "team_icon_3", "sprites/obj_icons/icon_obj_blu");
	// Hide on HUD | no model | no shadow | no capture sounds.
	DispatchKeyValue(point, "spawnflags", "15");
	TeleportEntity(point, pos, NULL_VECTOR, NULL_VECTOR);
	if (!DispatchSpawn(point))
	{
		RemoveEntity(point);
		return false;
	}
	ActivateEntity(point);
	g_iPoint[i] = EntIndexToEntRef(point);

	int area = CreateEntityByName("trigger_capture_area");
	if (area == -1)
		return false;
	char areaName[48];
	FormatEx(areaName, sizeof(areaName), "%s_area%d", ROAM_NAME, i);
	DispatchKeyValue(area, "targetname", areaName);
	DispatchKeyValue(area, "area_cap_point", name);
	DispatchKeyValue(area, "area_time_to_cap", "99999");   // never completes
	DispatchKeyValue(area, "team_cancap_2", "1");
	DispatchKeyValue(area, "team_cancap_3", "1");
	DispatchKeyValue(area, "team_numcap_2", "1");
	DispatchKeyValue(area, "team_numcap_3", "1");
	DispatchKeyValue(area, "spawnflags", "1");   // clients
	if (!DispatchSpawn(area))
	{
		RemoveEntity(area);
		return false;
	}
	ActivateEntity(area);
	// Brush-less trigger: box collision. The nav marks areas overlapping it as
	// the point's areas (CTFNavMesh::CollectControlPointAreas).
	SetEntityModel(area, BOX_MODEL);
	float mins[3] = { -96.0, -96.0, 0.0 }, maxs[3] = { 96.0, 96.0, 72.0 };
	SetEntPropVector(area, Prop_Send, "m_vecMins", mins);
	SetEntPropVector(area, Prop_Send, "m_vecMaxs", maxs);
	SetEntProp(area, Prop_Send, "m_nSolidType", 2);   // SOLID_BBOX
	SetEntProp(area, Prop_Send, "m_usSolidFlags", GetEntProp(area, Prop_Send, "m_usSolidFlags") | 0x0008 | 0x0004);
	SetEntProp(area, Prop_Send, "m_fEffects", GetEntProp(area, Prop_Send, "m_fEffects") | 0x020);
	TeleportEntity(area, pos, NULL_VECTOR, NULL_VECTOR);
	g_iArea[i] = EntIndexToEntRef(area);
	return true;
}

bool CreateMaster()
{
	int master = CreateEntityByName("team_control_point_master");
	if (master == -1)
		return false;
	DispatchKeyValue(master, "targetname", ROAM_NAME);
	// Disabled: CheckWinConditions never runs, so no capture can end a round.
	DispatchKeyValue(master, "StartDisabled", "1");
	if (!DispatchSpawn(master))
	{
		RemoveEntity(master);
		return false;
	}
	ActivateEntity(master);   // FindControlPoints -> objective resource
	g_iMaster = EntIndexToEntRef(master);
	// Link the capture areas a moment later (entities created this frame are
	// not reliably found by name yet).
	CreateTimer(0.2, Timer_Link, _, TIMER_FLAG_NO_MAPCHANGE);
	return true;
}

public Action Timer_Link(Handle timer)
{
	LinkAreas();
	RecomputeNav();
	return Plugin_Stop;
}

/** Players (alive, on a team) within the point's capture box footprint. */
int PlayersAtPoint(int i)
{
	int p = EntRefToEntIndex(g_iPoint[i]);
	if (p <= 0)
		return 0;
	float pos[3], c[3];
	GetEntPropVector(p, Prop_Data, "m_vecAbsOrigin", pos);
	int n = 0;
	for (int k = 1; k <= MaxClients; k++)
	{
		if (!IsClientInGame(k) || !IsPlayerAlive(k) || GetClientTeam(k) < 2)
			continue;
		GetClientAbsOrigin(k, c);
		if (FloatAbs(c[0] - pos[0]) <= 128.0 && FloatAbs(c[1] - pos[1]) <= 128.0 && FloatAbs(c[2] - pos[2]) <= 96.0)
			n++;
	}
	return n;
}

/** Arrival watch: once someone has stood at a point for the arrive delay, move it on. */
public Action Timer_Watch(Handle timer)
{
	if (!g_bActive)
	{
		g_hWatchTimer = null;
		return Plugin_Stop;
	}
	float now = GetGameTime();
	int n = g_cvPoints.IntValue;
	for (int i = 0; i < n; i++)
	{
		if (PlayersAtPoint(i) == 0)
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
			MovePoint(i);
		}
	}
	return Plugin_Continue;
}

/**
 * SetControlPoint re-links an area to its point and runs RoundSpawn, which
 * registers the cap rules with the objective resource; bots only target
 * points ObjectiveResource()->TeamCanCapPoint allows.
 */
void LinkAreas()
{
	for (int i = 0; i < MAX_POINTS; i++)
	{
		int area = EntRefToEntIndex(g_iArea[i]);
		if (area <= 0)
			continue;
		char name[48];
		FormatEx(name, sizeof(name), "%s_cp%d", ROAM_NAME, i);
		SetVariantString(name);
		AcceptEntityInput(area, "SetControlPoint");
		SetVariantString("2 1");
		AcceptEntityInput(area, "SetTeamCanCap");
		SetVariantString("3 1");
		AcceptEntityInput(area, "SetTeamCanCap");
	}
}

/**
 * CTFBotSeekAndDestroy picks at random between the point's area and one "enemy
 * spawn exit" per exit, and that exit list is the buggy one (first N areas of
 * the .nav), so the point lost most picks. With tf_bot_roam_exits 0 the map's
 * func_respawnroom triggers are disabled just across the nav recompute
 * (CTFNavMesh::DecorateMesh skips disabled rooms), leaving the point as the
 * only destination. "Disable" stops spawn-room touch for ~3 s; the enemy
 * blocking visualizers follow the room's Active state and are not touched.
 */
void RecomputeNav()
{
	int nav = CreateEntityByName("tf_point_nav_interface");
	if (nav == -1)
		return;
	DispatchSpawn(nav);
	bool hideExits = !g_cvExits.BoolValue;
	if (hideExits)
		SetMapRoomsEnabled(false);
	AcceptEntityInput(nav, "RecomputeBlockers");   // runs ~2 s later
	RemoveEntity(nav);
	if (hideExits)
		CreateTimer(3.0, Timer_RoomsBack, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RoomsBack(Handle timer)
{
	SetMapRoomsEnabled(true);
	return Plugin_Stop;
}

void SetMapRoomsEnabled(bool on)
{
	static bool s_wasDisabled[2048];
	int room = -1;
	while ((room = FindEntityByClassname(room, "func_respawnroom")) != -1)
	{
		if (IsOurs(room) || room >= sizeof(s_wasDisabled))
			continue;
		if (!on)
		{
			s_wasDisabled[room] = GetEntProp(room, Prop_Data, "m_bDisabled") != 0;
			if (!s_wasDisabled[room])
				AcceptEntityInput(room, "Disable");
		}
		else if (!s_wasDisabled[room])
			AcceptEntityInput(room, "Enable");
	}
}

void Teardown()
{
	delete g_hMoveTimer;
	delete g_hWatchTimer;
	g_bActive = false;
	static const char classes[][] = { "team_control_point_master", "trigger_capture_area", "team_control_point" };
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
			if (IsOurs(ent))
				RemoveEntity(ent);
	}
	g_iMaster = INVALID_ENT_REFERENCE;
	for (int i = 0; i < MAX_POINTS; i++)
	{
		g_iPoint[i] = g_iArea[i] = INVALID_ENT_REFERENCE;
		g_iPointSpot[i] = -1;
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
