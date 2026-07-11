# Shove Kings (working title)

Original 3D arctic party game for Godot 4.4+, 2-8 players. Three minigames
(menu / lobby "Minigame" selector, `game=0..2` on dedicated servers):

- **Shove Out** — sumo on an ice floe; shove everyone into the water; last
  penguin standing wins.
- **Tile Rush** — the floor is a claim-grid: walk to paint tiles your color,
  shove rivals off their turf; falling only respawns you. Most tiles at 0:00.
- **Snow Brawl** — the charge button throws snowballs instead of dashing;
  ranged knockback, same deadly edges, last penguin standing.
- **Puck Panic** — goal-defense: the rim is split into one colored goal arc
  per player, pucks ricochet off bodies, and a puck crossing YOUR arc costs a
  life (5 each). Dead players' arcs become walls. Falling in still kills you.
- **Boulder Brawl** — snow boulders lie on the ice; walk into one to hoist it
  (it slows you), charge hurls it. Hits cost one of five hearts and shove
  hard. Missed throws stay where they slid; shattered ones respawn.
- **Floe Dash** — 7 laps counterclockwise around the lane. Corner-cutting
  earns nothing, shoving is legal, and falling in respawns you where you fell.

Arena variants (ice blocks / melting / power-ups / chaos) and bot difficulty
apply to every minigame.

Roadmap: 3-4 stages per minigame, 2v2 teams and handicap matches, client-side
prediction, and polish (music, online names, character models).

## Milestone 5 — meta & polish

- **Character select** — each local human picks an archetype in the main menu;
  online, everyone picks their own in the lobby ("Auto" keeps the slot-cycled
  default). Bots stay on Auto.
- **Trophy structure** — first to N round-wins (default 3, configurable 1-5 in
  menu/lobby, `target=N` on dedicated servers) takes the trophy; the end panel
  announces it and "New Match" restarts standings from zero. Online, standings
  reset server-side when the next match begins.
- **Sound** — all SFX are synthesized at startup (`scripts/sound_bank.gd`):
  countdown beeps, charge whoosh, hit thump, splash, block crack, pickups,
  win jingle. No audio asset files.
- **Juice** — camera shake on hits/eliminations/block smashes, impact sparks,
  and a brief hit-stop (offline only — warping time on a networked simulation
  desyncs it, so online keeps shake + sparks).
- **Characters** — procedural penguin-style models built from Godot primitives
  (body, belly, eyes, beak, flippers, feet) with a speed-driven waddle and a
  charge lean. Deliberate deviation from the CC0-model plan: zero external
  assets keeps the project self-contained; the visual rig is isolated under
  `Visual/` in `scenes/player.tscn`, so swapping in a GLB later is contained.

## Milestone 4 — arena variants

Pick a variant in the main menu (local) or lobby (host/leader). Dedicated
servers take `variant=N` (0 Classic, 1 Ice Blocks, 2 Melting, 3 Power-Ups,
4 Chaos = all three).

- **Ice Blocks** — a wall of blocks rings the platform edge. A charge smashes
  one open (and spends the charge); a body slammed in fast enough crashes
  straight through. Nobody falls until edges are opened.
- **Melting Platform** — 10 s in, the floe starts shrinking to 30 % of its
  size over ~70 s. The safe zone follows the collision shape exactly.
- **Power-Ups** — a drop lands every 15 s, cycling Grow (bigger shoves,
  knockback resistance), Shrink-Others, and Freeze-Others (2.5 s). Effects
  last 8 s and change stats + silhouette, not the hitbox.
- **Chaos** — all three at once. Rim blocks fall into the water as the edge
  melts past them.

All variant state replicates online: block masks and platform radius ride the
20 Hz snapshots, drops/collections are reliable events.

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
