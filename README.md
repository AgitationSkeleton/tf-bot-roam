# TF2 Bot Roam

A SourceMod plugin for Team Fortress 2 that gets stock TFBots of every class
moving on maps without an objective: trade maps, hangout/idle maps and many
custom maps. It needs no gamedata or extensions.

## The problem

On maps without an objective, only Spy and Sniper bots roam. Medics follow
patients and Engineers try to build. Every other class stands near where it
spawned until an enemy wanders into view. That includes Scout, Soldier, Pyro,
Demoman and Heavy, plus class-10 bots from custom-class plugins.

The cause is in TFBot's behaviour tree (public Source SDK 2013 TF code):

* Spy and Sniper have their own roaming behaviours (`CTFBotSpyInfiltrate`,
  `CTFBotSniperLurk`).
* Every other class falls back to `CTFBotSeekAndDestroy` when the map has no
  flag, cart or control point ("scenario not implemented yet - just fight").
* `CTFBotSeekAndDestroy::ChooseGoalArea` has only two kinds of destination:
  * **"Enemy spawn exit" areas.** These come from
    `CTFNavMesh::CollectSpawnRoomThresholdAreas`, which reads
    `TheNavAreas[i]` where it should read the exit list. The goals are
    therefore whichever areas the `.nav` file happens to store first, in
    practice useless spots. That is why bots idle even on maps with proper
    spawn rooms.
  * **The bot's current control point.** Maps without an objective have none.

## What the plugin does

On maps that need it, the plugin:

1. Adds hidden, silent, neutral control points under a disabled
   `team_control_point_master`. The default is two points.
2. Places each point on a playable spot. Spots are taken from map entities
   (lights, props, items, sounds, triggers) dropped to the floor, and from
   where players walk. Each spot must fit a standing player outside the
   spawn rooms.
3. Moves a point to a new spot a few seconds after someone reaches it, plus
   every `tf_bot_roam_interval` seconds as a fallback.
4. Asks the nav mesh to recompute after each move, through a
   `tf_point_nav_interface` `RecomputeBlockers` input.

Bots of every class head for their current point, meet and fight on the way,
then move on when the point does.

## Safety

* **No round wins.** The master starts disabled, so its win check never runs.
* **No real captures.** A capture takes about 28 hours (`area_time_to_cap`),
  so it never completes.
* **Hidden and silent.** The points have no HUD icon, model, shadow, capture
  sounds or capture warnings.
* **Linear capping.** Each point lists itself as its own previous point, so
  `tf_caplinear` never blocks it.
* **Game mode unchanged.** The game decides the mode once at map start, before
  the points exist, so the map stays in its normal mode.
* **Objective maps untouched.** In `auto` mode the plugin leaves alone any map
  with an objective: a control point, flag, payload, capture zone, arena,
  KotH, Mann vs. Machine, PASS Time, Robot Destruction or Player Destruction.

## ConVars

`cfg/sourcemod/tf_bot_roam.cfg` is generated on first load.

| ConVar | Default | Meaning |
|---|---|---|
| `tf_bot_roam_mode` | `auto` | `auto` = only maps without an objective, `force` = every map without a control-point master, `off` |
| `tf_bot_roam_points` | `2` | Hidden roam points at a time (1-4). |
| `tf_bot_roam_interval` | `40` | Seconds between moving one of the points (fallback). |
| `tf_bot_roam_arrive_delay` | `6` | Seconds a point stays after someone reaches it. |
| `tf_bot_roam_min_distance` | `768` | Distance a moved point goes from its last spot (when possible). |
| `tf_bot_roam_debug` | `0` | `1` = log what the plugin does. |

Command `sm_botroam` (generic admin flag) shows the state and point
positions. `sm_botroam apply` re-applies, `sm_botroam move` moves a point now.

## Install

Copy `plugins/tf_bot_roam.smx` to `tf/addons/sourcemod/plugins/`. It loads at
the next map change, or straight away with `sm plugins load tf_bot_roam`.
Requires SourceMod 1.11 or newer; built with 1.12.

## Limitations

* The map needs a nav mesh (`.nav`). Generate one with `nav_generate` if it
  has none.
* Medics keep healing and Engineers keep building, as in stock TF2.
* Players standing on a hidden point start an endless, invisible capture.
  Nothing happens, but the game does fire a "capture started" event.

## License

GPL-3.0 (see `LICENSE`), like SourceMod itself.
