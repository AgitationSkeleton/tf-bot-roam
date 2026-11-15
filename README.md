# TF2 Bot Roam

A SourceMod plugin for Team Fortress 2 that gets stock TFBots moving on maps
without an objective: trade maps, hangout/idle maps, and many custom maps. It
needs no gamedata or extensions.

## The problem

On maps without an objective, only Spy and Sniper bots roam. Medics follow
patients and Engineers try to build. Every other class stands near where it
spawned until an enemy wanders into view. That includes Scout, Soldier, Pyro,
Demoman and Heavy, plus class-10 bots from custom-class plugins.

The cause is in TFBot's behaviour tree:

* Spy and Sniper have their own roaming behaviours (`CTFBotSpyInfiltrate`,
  `CTFBotSniperLurk`).
* Every other class falls back to `CTFBotSeekAndDestroy` when the map has no
  flag, cart or control point ("scenario not implemented yet - just fight").
* `CTFBotSeekAndDestroy::ChooseGoalArea` only travels to two kinds of place:
  the enemy team's spawn-room exits and the current control point.
* The nav mesh marks spawn-room exits only inside `func_respawnroom` volumes
  that contain `info_player_teamspawn` points (`CTFNavMesh::DecorateMesh`).
  Maps without them make the server print *"Can't compute incursion distances
  ... Bots will perform poorly"*, and the bots have nowhere to go.

## What the plugin does

On maps that need it, the plugin:

1. Groups each team's spawn points into clusters, then adds one small invisible
   `func_respawnroom` around each cluster.
2. Gives teamless spawn points a RED copy at the same spot. The nav mesh files
   team-0 spawns under BLU only, so without the copy RED bots would get no
   destinations.
3. Asks the nav mesh to recompute through a `tf_point_nav_interface`
   `RecomputeBlockers` input. It repeats all of this after every round restart,
   because a restart removes entities the map did not create.

The bots then use their own pathfinding to head for enemy spawn areas, and they
fight whatever they meet on the way.

The added volumes belong to the spectator team. Players never count as inside
them, so nobody gets spawn-room privileges such as instant class change or flag
drops. The nav mesh labels areas by the spawn point's team, not the volume's,
so the bots still get their destinations. The one side effect is that
Engineers cannot build inside these small volumes.

## When it applies

In `auto` mode (the default) it does nothing on a map that has any of these:

* an objective: `team_control_point`, `item_teamflag`, `team_train_watcher`,
  `func_capturezone`, `passtime_logic`, a robot or player destruction logic
  entity, `tf_logic_koth`, or `tf_logic_hybrid_ctf_cp`;
* real Mann vs. Machine (`tf_logic_mann_vs_machine`);
* the map's own spawn rooms for both teams.

## ConVars

`cfg/sourcemod/tf_bot_roam.cfg` is generated on first load.

| ConVar | Default | Meaning |
|---|---|---|
| `tf_bot_roam_mode` | `auto` | `auto` = only maps that need it, `force` = every map, `off` |
| `tf_bot_roam_merge_distance` | `384` | Spawn points closer than this share one volume, so there are fewer entities. |
| `tf_bot_roam_padding` | `48` | Units added around each spawn cluster. Keep it small: Engineers cannot build inside. |
| `tf_bot_roam_debug` | `0` | `1` = log what the plugin did on each map and round. |

Command: `sm_botroam` shows what the plugin did on the current map, and
`sm_botroam apply` re-applies it (generic admin flag).

## Install

Copy `plugins/tf_bot_roam.smx` to `tf/addons/sourcemod/plugins/`. It loads at
the next map change, or straight away with `sm plugins load tf_bot_roam`.
Requires SourceMod 1.11 or newer; built with 1.12.

## Limitations

* Bots travel toward enemy spawn areas, which isn't the same as wandering
  freely. On a map where everyone spawns in one hub, bots converge on the hub
  and fight there.
* Medics and Engineers keep their stock behaviours.
* The map needs a nav mesh (`.nav`). Generate one with `nav_generate` if it
  has none.

## License

GPL-3.0 (see `LICENSE`), like SourceMod itself. The behaviour analysis
references the public Source SDK 2013 TF code.
