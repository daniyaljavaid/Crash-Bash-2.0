# Shove Kings (working title)

Original 3D sumo party game for Godot 4.4+. Four-to-eight players on a slippery
ice floe; shove everyone else into the water; last one standing wins.

## Milestone 1 — local play vs bots

**Run:**
1. Open the project folder in Godot 4.4+ (Project Manager → Import → select `project.godot`).
2. Press F5.
3. Pick match size (2–8) and human count (default 1), press START MATCH.

**Controls**

| Slot | Move | Charge |
|---|---|---|
| P1 | WASD | Space |
| P2 | Arrows | Enter |
| P3 / P4 | Gamepad 1/2 left stick | A button |
| — | ESC | Pause + video settings (V-Sync, FPS cap 60/120/144/240/Uncapped) |

All non-human slots are filled by bots.

**Headless smoke test** (all-bot round, no window):

```sh
godot --headless --path . res://scenes/arena.tscn --quit-after 1200 -- players=8 humans=0
```

## Architecture (why it looks over-engineered for local play)

Server-authoritative from day one, so Milestone 2 (ENet multiplayer) is a
refactor-light addition:

- `scripts/sim/` — the authoritative simulation. `MatchSim` owns the round
  state machine and steps every `SimPlayer` at a fixed 60 Hz tick. No sim code
  reads input devices.
- `PlayerInput` — the only object that crosses from input collection into the
  sim. Produced per player per tick by a `PlayerController`
  (`HumanController` reads devices, `BotController` reads sim state). In M2,
  clients will send serialized `PlayerInput`s to the server.
- Presentation (`arena.gd`, `hud.gd`, `camera_rig.gd`) only READS sim state.
- All feel constants live in `scripts/sim/tuning.gd` (autoload `Tuning`);
  archetype stats in `data/character_stats.gd`.

Physics interpolation is enabled project-wide (`physics/common/physics_interpolation`),
physics tick is 60 Hz, and the camera moves in `_process` — so 120–240 Hz
rendering is smooth.
