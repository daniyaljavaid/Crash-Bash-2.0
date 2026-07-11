# Shove Kings (working title)

Original 3D sumo party game for Godot 4.4+. Four-to-eight players on a slippery
ice floe; shove everyone else into the water; last one standing wins.

## Milestone 3 — WAN play & deployment

### Export builds

One-time setup: install export templates (Editor → *Editor* menu →
*Manage Export Templates* → Download and Install; ~900 MB, matches your exact
Godot version).

Then, from the project folder:

```sh
mkdir -p build/windows build/macos build/server
godot --headless --path . --export-release "Windows Desktop" build/windows/shove-kings.exe
godot --headless --path . --export-release "macOS"           build/macos/shove-kings.zip
godot --headless --path . --export-release "Linux Server"    build/server/shove-kings-server.x86_64
```

The three presets live in `export_presets.cfg`. "Linux Server" exports in
dedicated-server mode (visual resources stripped) for a typical Linux VPS.
macOS builds are ad-hoc signed — Gatekeeper will require right-click → Open on
first launch (proper signing/notarization needs an Apple Developer identity).

### Run a server over the internet

```sh
./shove-kings-server.x86_64 --headless --server -- port=9050 players=8 bots=1
```

Optional server args: `autostart=N` (start once N humans join — otherwise the
first-joined client gets the Start button), `autonext=SECONDS` (auto-start the
next round after each one ends).

Clients: main menu → Join Game → the server's IP. Options:
- **Tailscale (easiest):** install on server + players, join one tailnet, use
  the server's `100.x.y.z` IP. No port forwarding, works through any NAT.
- **Port forwarding:** forward UDP 9050 on the server's router; players use
  the public IP. ENet is UDP — forward UDP, not TCP.
- **LAN:** just use the machine's local IP.

The last-used IP/port are remembered (`user://settings.cfg`, alongside the
video settings).

### Reconnect-safe lobby

The lobby stays open while a match runs: anyone joining (or rejoining after a
drop) waits in the lobby and is dealt into the next round automatically. Win
standings follow players by peer identity across roster changes.

## Milestone 2 — online multiplayer (LAN/local)

Server-authoritative over ENet: clients send input intents at 60 Hz, the server
runs the only simulation and broadcasts 20 Hz snapshots; clients interpolate
puppets ~100 ms behind (`scripts/net/`).

**Host + join on one machine:** launch two instances → one clicks *Host Game*
(port 9050), the other *Join Game* with `127.0.0.1`. Host configures match size
/ bots in the lobby and starts. The host plays as slot 0 (listen server).

**Dedicated server:**
```sh
godot --headless --path . --server -- port=9050 players=8 bots=1 autostart=2
```
`autostart=N` starts the match automatically once N humans join; omit it and
the first-joined client becomes the lobby leader with the Start button.

**Scripted client (for testing):**
```sh
godot --path . -- join=127.0.0.1:9050 autopilot
```
`autopilot` replaces keyboard input with a bot driving off the replicated
state — exercises the full client input path end-to-end.

M2 limitations: no client-side prediction (your own capsule is ~100 ms behind
your keys), no reconnect after match start (M3), lobby config is fixed on a
dedicated server, disconnected players idle in place until eliminated.

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
