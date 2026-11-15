# TF2 Bot Roam

A SourceMod plugin for Team Fortress 2 that gets stock TFBots of every class
moving on maps without an objective: trade maps, hangout/idle maps and many
custom maps. Class-10 bots from custom-class plugins are covered too. It needs
no gamedata or extensions.

## The problem

On maps without an objective, only Spy and Sniper bots roam. Medics follow
patients and Engineers try to build. Every other class stands near where it
spawned until an enemy wanders into view: Scout, Soldier, Pyro, Demoman and
Heavy, plus class-10 bots.

The cause is in TFBot's behaviour tree (public Source SDK 2013 TF code):

* Spy and Sniper have their own roaming behaviours (`CTFBotSpyInfiltrate`,
  `CTFBotSniperLurk`).
* Every other class falls back to `CTFBotSeekAndDestroy` when the map has no
  flag, cart or control point.
* That behaviour's destinations come from
  `CTFNavMesh::CollectSpawnRoomThresholdAreas`, which reads `TheNavAreas[i]`
  where it should read the exit list. The "goals" are therefore whichever areas
  the `.nav` file stores first, so in practice the bots go nowhere, even on
  maps with proper spawn rooms.

## What the plugin does

TFBot checks for a flag to fetch before it reaches that broken fallback
(`CTFBotScenarioMonitor` → `GetFlagToFetch` → `CTFBotFetchFlag`), and
`CTFBotFetchFlag` paths straight to the flag every one or two seconds.

On maps that need it, the plugin:

1. Gives each team an invisible enemy flag (`item_teamflag`) to fetch. BLU
   bots chase RED's flag and RED bots chase BLU's.
2. Places the flags on playable spots. Spots are taken from map entities
   (lights, props, items, sounds, brushes) and from where players walk, each
   dropped to the floor, checked to fit a standing player, and kept outside
   the spawn rooms.
3. Moves each flag a few seconds after someone reaches it, plus every
   `tf_bot_roam_interval` seconds as a fallback.

Bots of every class head for their flag, meet the other team on the way, and
move on when the flag does.

## Safety

* **Nobody can pick the flags up.** Touch is blocked, so there are no
  captures, drops, returns, announcer lines or score changes.
* **Invisible.** The flags are not drawn and their glow is disabled.
* **Game mode unchanged.** The game decides the mode once at map start,
  before the flags exist, so the map stays in its normal mode and shows no
  CTF HUD.
* **Objective maps untouched.** In `auto` mode the plugin leaves alone any map
  with an objective: a flag, control point, payload, capture zone, arena, KotH,
  Mann vs. Machine, PASS Time, Robot Destruction or Player Destruction.

## Results

Measured on a test server with 10 bots. The table gives the average distance
each bot travelled in 30 seconds; "still" means under 150 units.

| Map | Without the plugin | With the plugin |
|---|---|---|
| trade_plaza | 10 of 10 bots still | 0 still in every sample; 2,700-5,900 u; 22 kills in ~2.5 min |
| secret_facility | 8-10 of 10 still | 0 still among survivors; 1,900-2,700 u; 43 kills |
| trade_minecraft_b38 | 8-9 of 10 still | 0 still; 3,000-6,000 u; 2 kills, 13 in 150 s with `tf_bot_roam_meet_chance` 0.5 |
| trade_minecraft_b38_mvm | 8-10 of 10 still | 0 still; 2,300-6,000 u; 13 kills |
| trade_phys_tower_b9 | has its own flag | plugin stays off (map objective) |
| trade_facility, achievement_idle | have control points | plugin stays off (map objective) |

No flag pickups, captures or round wins happened in any run. Bots that die
mid-sample drop out of the averages, which is why some samples count fewer
than 10.

## ConVars

`cfg/sourcemod/tf_bot_roam.cfg` is generated on first load.

| ConVar | Default | Meaning |
|---|---|---|
| `tf_bot_roam_mode` | `auto` | `auto` = only maps without an objective, `force` = every map without flags, `off` |
| `tf_bot_roam_interval` | `30` | Seconds between moving one of the flags (fallback). |
| `tf_bot_roam_arrive_delay` | `5` | Seconds a flag stays once someone reaches it. |
| `tf_bot_roam_min_distance` | `768` | Distance a moved flag goes from its last spot (when possible). |
| `tf_bot_roam_meet_chance` | `0.5` | Chance a moved flag lands near the other team's flag, so both teams head for the same area. This helps on big maps. |
| `tf_bot_roam_debug` | `0` | `1` = log what the plugin does. |

Command `sm_botroam` (generic admin flag) shows the state and flag positions.
`sm_botroam apply` re-applies, `sm_botroam move` moves a flag now.

## Install

Copy `plugins/tf_bot_roam.smx` to `tf/addons/sourcemod/plugins/`. It loads at
the next map change, or straight away with `sm plugins load tf_bot_roam`.
Requires SourceMod 1.11 or newer; built with 1.12.

## Limitations

* The map needs a nav mesh (`.nav`). Generate one with `nav_generate` if it
  has none.
* Medics keep healing and Engineers keep building, as in stock TF2.
* Bots already alive when the plugin first loads keep their current behaviour
  until they respawn.
* Maps that have control points nobody can use (e.g. `achievement_idle`) count
  as having an objective, so `auto` leaves them alone. Set `tf_bot_roam_mode
  force` in that map's config (`cfg/<map>.cfg`) to apply it there. `force`
  only skips maps that have their own flags.

## Credits

The hidden-flag idea comes from EfeDursun's "Bots on Payload Race" plugin,
which uses it to walk bots along the cart. The analysis references the public
Source SDK 2013 TF code.

## License

GPL-3.0 (see `LICENSE`), like SourceMod itself.
