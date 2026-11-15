/**
 * TF2 Bot Roam
 *
 * On maps without an objective (trade_, hangout, idle, many custom maps) stock
 * TFBots of every class except Spy, Sniper, Medic and Engineer stand around:
 * their fallback behaviour, CTFBotSeekAndDestroy, only travels to the enemy
 * team's spawn-room exits (and the current control point), and the nav mesh
 * marks spawn-room exits only from func_respawnroom volumes that contain team
 * spawn points (CTFNavMesh::DecorateMesh). Maps without such volumes leave the
 * bots with no destination ("Bots will perform poorly" in the server console).
 *
 * This plugin adds small invisible func_respawnroom volumes around clusters of
 * info_player_teamspawn points and asks the nav mesh to recompute
 * (tf_point_nav_interface RecomputeBlockers). The volumes belong to the
 * spectator team, so they never give players spawn-room privileges (class
 * change, flag drop, touch effects); the nav mesh labels areas by the spawn
 * point's team, not the volume's. Teamless spawn points get a RED copy at the
 * same spot because the nav mesh files team-0 spawns under BLU only.
 *
 * Works for any class the bot fallback covers, including class-10 bots from
 * custom-class plugins. No gamedata, offsets or SDK calls.
 */
#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"
#define ROAM_NAME      "tf_bot_roam"
#define BOX_MODEL      "models/items/ammopack_small.mdl"
#define TEAM_SPECTATOR 1
#define TEAM_RED       2
#define TEAM_BLUE      3
#define MAX_CLUSTERS   64

public Plugin myinfo =
{
	name        = "TF2 Bot Roam",
	author      = "AgitationSkeleton",
	description = "Gives stock TFBots somewhere to go on maps without an objective.",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/AgitationSkeleton/tf-bot-roam"
};

ConVar g_cvMode;
ConVar g_cvMerge;
ConVar g_cvPad;
ConVar g_cvDebug;

bool g_bApplied;
int g_iRooms;
int g_iCopies;
char g_sReason[128];

/* Objective entities: any of these means the stock bot behaviours already
 * have targets (or the mode has its own bot logic, e.g. real MvM). */
static const char g_sObjectives[][] =
{
	"team_control_point", "item_teamflag", "team_train_watcher", "func_capturezone",
	"tf_logic_mann_vs_machine", "passtime_logic", "tf_logic_robot_destruction",
	"tf_logic_player_destruction", "tf_logic_koth", "tf_logic_hybrid_ctf_cp"
};

public void OnPluginStart()
{
	CreateConVar("tf_bot_roam_version", PLUGIN_VERSION, "TF2 Bot Roam version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvMode = CreateConVar("tf_bot_roam_mode", "auto",
		"auto = only on maps without an objective entity or team spawn rooms | force = every map | off");
	g_cvMerge = CreateConVar("tf_bot_roam_merge_distance", "384",
		"Spawn points closer than this share one volume (fewer entities).", _, true, 0.0);
	g_cvPad = CreateConVar("tf_bot_roam_padding", "48",
		"Units added around each spawn cluster; keep small (Engineers cannot build inside).", _, true, 8.0, true, 512.0);
	g_cvDebug = CreateConVar("tf_bot_roam_debug", "0", "1 = log what the plugin does on each map/round.", _, true, 0.0, true, 1.0);
	AutoExecConfig(true, "tf_bot_roam");

	HookEvent("teamplay_round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	RegAdminCmd("sm_botroam", Cmd_Status, ADMFLAG_GENERIC, "Show what TF2 Bot Roam did on this map; sm_botroam apply re-applies.");
}

public void OnMapStart()
{
	PrecacheModel(BOX_MODEL, true);
	g_bApplied = false;
	g_iRooms = g_iCopies = 0;
	g_sReason[0] = '\0';
}

public void OnConfigsExecuted()
{
	CreateTimer(1.0, Timer_Apply, _, TIMER_FLAG_NO_MAPCHANGE);
}

/* Round restarts clean up entities the map did not create; re-add ours. */
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	CreateTimer(0.5, Timer_Apply, _, TIMER_FLAG_NO_MAPCHANGE);
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
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	ReplyToCommand(client, "[BotRoam] %s: %s (%d volume(s), %d RED spawn copies)%s%s", map,
		g_bApplied ? "ACTIVE" : "inactive", g_iRooms, g_iCopies, g_sReason[0] ? " - " : "", g_sReason);
	int spawns[4], rooms[4], red, blue;
	int e = -1;
	while ((e = FindEntityByClassname(e, "info_player_teamspawn")) != -1)
		if (!IsOurs(e))
			spawns[GetEntProp(e, Prop_Send, "m_iTeamNum") & 3]++;
	e = -1;
	while ((e = FindEntityByClassname(e, "func_respawnroom")) != -1)
		if (!IsOurs(e))
			rooms[GetEntProp(e, Prop_Send, "m_iTeamNum") & 3]++;
	SpawnCoverage(red, blue);
	ReplyToCommand(client, "[BotRoam] map spawns: teamless %d, RED %d, BLU %d | map spawn rooms: unassigned %d, RED %d, BLU %d | spawns inside rooms: RED %d, BLU/teamless %d",
		spawns[0], spawns[2], spawns[3], rooms[0], rooms[2], rooms[3], red, blue);
	return Plugin_Handled;
}

void Apply()
{
	RemoveOurs();
	g_bApplied = false;
	g_iRooms = g_iCopies = 0;

	char mode[16];
	g_cvMode.GetString(mode, sizeof(mode));
	if (StrEqual(mode, "off", false))
	{
		strcopy(g_sReason, sizeof(g_sReason), "tf_bot_roam_mode off");
		return;
	}
	if (!StrEqual(mode, "force", false) && !NeedsHelp(g_sReason, sizeof(g_sReason)))
	{
		Debug("not applied: %s", g_sReason);
		return;
	}

	// Cluster enabled spawn points per team (teamless points count for both).
	float mins[MAX_CLUSTERS][3], maxs[MAX_CLUSTERS][3], first[MAX_CLUSTERS][3], ang[MAX_CLUSTERS][3];
	int team[MAX_CLUSTERS];
	bool teamless[MAX_CLUSTERS];
	int n = 0;
	float merge = g_cvMerge.FloatValue;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "info_player_teamspawn")) != -1)
	{
		if (IsOurs(ent) || GetEntProp(ent, Prop_Data, "m_bDisabled"))
			continue;
		int t = GetEntProp(ent, Prop_Send, "m_iTeamNum");
		int clusterTeam = t >= TEAM_RED ? t : 0;
		float pos[3];
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
		int c = -1;
		for (int i = 0; i < n; i++)
		{
			if (team[i] != clusterTeam)
				continue;
			if (pos[0] >= mins[i][0] - merge && pos[0] <= maxs[i][0] + merge
				&& pos[1] >= mins[i][1] - merge && pos[1] <= maxs[i][1] + merge
				&& pos[2] >= mins[i][2] - 128.0 && pos[2] <= maxs[i][2] + 128.0)
			{
				c = i;
				break;
			}
		}
		if (c == -1)
		{
			if (n >= MAX_CLUSTERS)
				continue;
			c = n++;
			team[c] = clusterTeam;
			teamless[c] = clusterTeam == 0;
			mins[c] = pos;
			maxs[c] = pos;
			first[c] = pos;
			GetEntPropVector(ent, Prop_Data, "m_angAbsRotation", ang[c]);
			continue;
		}
		for (int k = 0; k < 3; k++)
		{
			if (pos[k] < mins[c][k]) mins[c][k] = pos[k];
			if (pos[k] > maxs[c][k]) maxs[c][k] = pos[k];
		}
	}
	if (n == 0)
	{
		strcopy(g_sReason, sizeof(g_sReason), "no enabled info_player_teamspawn");
		return;
	}

	float pad = g_cvPad.FloatValue;
	for (int i = 0; i < n; i++)
	{
		float lo[3], hi[3];
		lo[0] = mins[i][0] - pad; lo[1] = mins[i][1] - pad; lo[2] = mins[i][2];
		hi[0] = maxs[i][0] + pad; hi[1] = maxs[i][1] + pad; hi[2] = maxs[i][2] + 96.0;
		if (AddRoom(lo, hi))
			g_iRooms++;
		// Team-0 spawns are filed under BLU by the nav mesh; give RED one too.
		if (teamless[i] && AddSpawnCopy(first[i], ang[i], TEAM_RED))
			g_iCopies++;
	}

	RecomputeNav();
	g_bApplied = g_iRooms > 0;
	FormatEx(g_sReason, sizeof(g_sReason), "%d spawn cluster(s)", n);
	Debug("applied: %d volume(s), %d RED copies, %d cluster(s)", g_iRooms, g_iCopies, n);
}

/** True when stock bots have nothing to travel to on this map. */
bool NeedsHelp(char[] reason, int maxlen)
{
	for (int i = 0; i < sizeof(g_sObjectives); i++)
	{
		if (FindEntityByClassname(-1, g_sObjectives[i]) != -1)
		{
			FormatEx(reason, maxlen, "map has %s", g_sObjectives[i]);
			return false;
		}
	}
	// The nav mesh only gets exits for a team when one of that team's enabled
	// spawn points lies inside an active func_respawnroom (teamless points count
	// as BLU). Many trade maps have rooms whose spawns are elsewhere or teamless.
	int red, blue;
	SpawnCoverage(red, blue);
	if (red > 0 && blue > 0)
	{
		FormatEx(reason, maxlen, "map spawn rooms already hold RED (%d) and BLU (%d) spawns", red, blue);
		return false;
	}
	return true;
}

/** Enabled map spawn points per team that sit inside a map-made spawn room's box. */
void SpawnCoverage(int &red, int &blue)
{
	red = blue = 0;
	int sp = -1;
	while ((sp = FindEntityByClassname(sp, "info_player_teamspawn")) != -1)
	{
		if (IsOurs(sp) || GetEntProp(sp, Prop_Data, "m_bDisabled"))
			continue;
		float pos[3];
		GetEntPropVector(sp, Prop_Data, "m_vecAbsOrigin", pos);
		if (!InMapSpawnRoom(pos))
			continue;
		if (GetEntProp(sp, Prop_Send, "m_iTeamNum") == TEAM_RED)
			red++;
		else
			blue++;
	}
}

bool InMapSpawnRoom(const float pos[3])
{
	int room = -1;
	while ((room = FindEntityByClassname(room, "func_respawnroom")) != -1)
	{
		if (IsOurs(room) || GetEntProp(room, Prop_Data, "m_bDisabled"))
			continue;
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

bool AddRoom(const float lo[3], const float hi[3])
{
	int room = CreateEntityByName("func_respawnroom");
	if (room == -1)
		return false;
	DispatchKeyValue(room, "targetname", ROAM_NAME);
	DispatchKeyValue(room, "TeamNum", "1");   // spectator: no player is ever "in" it
	DispatchKeyValue(room, "StartDisabled", "0");
	if (!DispatchSpawn(room))
	{
		RemoveEntity(room);
		return false;
	}
	ActivateEntity(room);

	float center[3], bmin[3], bmax[3];
	for (int k = 0; k < 3; k++)
	{
		center[k] = (lo[k] + hi[k]) * 0.5;
		bmin[k] = lo[k] - center[k];
		bmax[k] = hi[k] - center[k];
	}
	// A brush-less trigger: box collision (PointIsWithin clips against it).
	SetEntityModel(room, BOX_MODEL);
	SetEntPropVector(room, Prop_Send, "m_vecMins", bmin);
	SetEntPropVector(room, Prop_Send, "m_vecMaxs", bmax);
	SetEntProp(room, Prop_Send, "m_nSolidType", 2);   // SOLID_BBOX
	SetEntProp(room, Prop_Send, "m_usSolidFlags", GetEntProp(room, Prop_Send, "m_usSolidFlags") | 0x0008 | 0x0004);   // FSOLID_TRIGGER | FSOLID_NOT_SOLID
	SetEntProp(room, Prop_Send, "m_fEffects", GetEntProp(room, Prop_Send, "m_fEffects") | 0x020);   // EF_NODRAW
	TeleportEntity(room, center, NULL_VECTOR, NULL_VECTOR);
	SetEntProp(room, Prop_Send, "m_iTeamNum", TEAM_SPECTATOR);
	return true;
}

bool AddSpawnCopy(const float pos[3], const float ang[3], int t)
{
	int spawn = CreateEntityByName("info_player_teamspawn");
	if (spawn == -1)
		return false;
	DispatchKeyValue(spawn, "targetname", ROAM_NAME);
	char tn[4];
	IntToString(t, tn, sizeof(tn));
	DispatchKeyValue(spawn, "TeamNum", tn);
	TeleportEntity(spawn, pos, ang, NULL_VECTOR);
	if (!DispatchSpawn(spawn))
	{
		RemoveEntity(spawn);
		return false;
	}
	ActivateEntity(spawn);
	return true;
}

void RecomputeNav()
{
	int nav = CreateEntityByName("tf_point_nav_interface");
	if (nav == -1)
		return;
	DispatchKeyValue(nav, "targetname", ROAM_NAME);
	DispatchSpawn(nav);
	AcceptEntityInput(nav, "RecomputeBlockers");
}

void RemoveOurs()
{
	static const char classes[][] = { "func_respawnroom", "info_player_teamspawn", "tf_point_nav_interface" };
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
			if (IsOurs(ent))
				RemoveEntity(ent);
	}
}

bool IsOurs(int ent)
{
	char name[32];
	GetEntPropString(ent, Prop_Data, "m_iName", name, sizeof(name));
	return StrEqual(name, ROAM_NAME);
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
