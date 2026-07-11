class_name ClientReplica
extends Node3D
## Client-side stand-in for MatchSim: exposes the same read API the HUD and
## camera use (players, state, time_left, countdown_left, arena_radius) and
## the same signals, but is driven entirely by server snapshots. Runs no
## gameplay logic — puppets are interpolated between two buffered snapshots
## ~100 ms behind the newest, so 20 Hz snapshots render smoothly at any FPS.

signal player_eliminated(slot: int, at: Vector3)
signal round_ended(winner_slot: int)
signal player_hit(attacker_slot: int, victim_slot: int, at: Vector3)

const INTERP_DELAY_TICKS := 6.0   # 100 ms at the 60 Hz sim tick
const MAX_BUFFER := 20

var players: Array[SimPlayer] = []
var state := MatchSim.State.COUNTDOWN
var time_left := Tuning.ROUND_TIME
var countdown_left := Tuning.COUNTDOWN_TIME
var arena_radius := Tuning.ARENA_RADIUS_SMALL
var tick := 0

signal block_destroyed(index: int, at: Vector3)
signal player_respawned(slot: int, at: Vector3)
signal ball_spawned(id: int, from: Vector3, dir: Vector3)
signal ball_gone(id: int, at: Vector3)
signal goal_scored(slot: int, lives_left: int, at: Vector3)

var ice_ring: IceBlockRing = null
var tile_grid: TileGrid = null
var pucks = null # always null: bots probe sim.pucks, clients render from extra

var _balls := {} # id -> {node, dir} — client-side flight matching the sim's path
var _puck_nodes: Array[Node3D] = []      # rebuilt to match each snapshot
var _puck_vels: Array[Vector3] = []      # dead-reckoning between snapshots
var _lives: Array[int] = []              # Puck Panic lives, from events
var _arc_markers: Array = []

var _snaps: Array[Dictionary] = []   # {tick, data}, ascending tick
var _render_tick := -1.0
var _platform_shape: CylinderShape3D = null
var _platform_mesh: CylinderMesh = null
var _pickups := {} # id -> Node3D


func start(player_count: int) -> void:
	arena_radius = MatchSim.radius_for_player_count(player_count)
	var platform := MatchSim.build_platform(arena_radius)
	add_child(platform)
	_platform_shape = platform.get_meta("shape")
	_platform_mesh = platform.get_meta("mesh")
	if MatchConfig.has_ice_blocks():
		ice_ring = IceBlockRing.new()
		add_child(ice_ring)
		ice_ring.build(arena_radius)
		ice_ring.block_destroyed.connect(
			func(index: int, at: Vector3) -> void: block_destroyed.emit(index, at))
	if MatchConfig.minigame == MatchConfig.Minigame.TILE:
		tile_grid = TileGrid.new()
		add_child(tile_grid)
		tile_grid.build(arena_radius, player_count)
	elif MatchConfig.minigame == MatchConfig.Minigame.GOAL:
		_arc_markers = PuckManager.build_arc_markers(self, arena_radius, player_count)
		for i in player_count:
			_lives.append(PuckManager.START_LIVES)
	for i in player_count:
		var p: SimPlayer = MatchSim.PLAYER_SCENE.instantiate()
		add_child(p)
		p.setup(i, MatchConfig.archetype_for_slot(i), MatchConfig.PLAYER_COLORS[i])
		p.make_puppet()
		var angle := TAU * float(i) / float(player_count)
		var out := Vector3(sin(angle), 0.0, cos(angle))
		p.global_position = out * arena_radius * Tuning.SPAWN_RADIUS_FRACTION + Vector3(0, 1.0, 0)
		p.rotation.y = atan2(out.x, out.z) # face center, mirrors server spawn
		players.append(p)
	Net.snapshot_received.connect(_on_snapshot)
	Net.net_eliminated.connect(_on_eliminated)
	Net.net_round_over.connect(_on_round_over)
	Net.net_powerup_spawned.connect(_on_powerup_spawned)
	Net.net_powerup_collected.connect(_on_powerup_collected)
	Net.net_player_hit.connect(_on_player_hit)
	Net.net_player_respawned.connect(_on_respawned)
	Net.net_ball_spawned.connect(_on_ball_spawned)
	Net.net_ball_gone.connect(_on_ball_gone)
	Net.net_goal_scored.connect(_on_goal_scored)


func _exit_tree() -> void:
	if Net.snapshot_received.is_connected(_on_snapshot):
		Net.snapshot_received.disconnect(_on_snapshot)
		Net.net_eliminated.disconnect(_on_eliminated)
		Net.net_round_over.disconnect(_on_round_over)
		Net.net_powerup_spawned.disconnect(_on_powerup_spawned)
		Net.net_powerup_collected.disconnect(_on_powerup_collected)
		Net.net_player_hit.disconnect(_on_player_hit)
		Net.net_player_respawned.disconnect(_on_respawned)
		Net.net_ball_spawned.disconnect(_on_ball_spawned)
		Net.net_ball_gone.disconnect(_on_ball_gone)
		Net.net_goal_scored.disconnect(_on_goal_scored)


func _on_player_hit(attacker_slot: int, victim_slot: int, at: Vector3) -> void:
	player_hit.emit(attacker_slot, victim_slot, at)


func _on_respawned(slot: int, at: Vector3) -> void:
	player_respawned.emit(slot, at)


func _on_ball_spawned(id: int, from: Vector3, dir: Vector3) -> void:
	# Puck Panic pucks render from snapshot data, not this event (their paths
	# bounce unpredictably); the event still fires the arena launch sound.
	if MatchConfig.minigame != MatchConfig.Minigame.GOAL:
		var node := SnowballManager.make_ball_visual()
		node.position = from
		add_child(node)
		_balls[id] = {"node": node, "dir": dir}
	ball_spawned.emit(id, from, dir)


func _on_goal_scored(slot: int, lives_left: int, at: Vector3) -> void:
	if slot < _lives.size():
		_lives[slot] = lives_left
	goal_scored.emit(slot, lives_left, at)


func player_lives(slot: int) -> int:
	if MatchConfig.minigame != MatchConfig.Minigame.GOAL or slot >= _lives.size():
		return -1
	return _lives[slot]


func _on_ball_gone(id: int, at: Vector3) -> void:
	if _balls.has(id):
		_balls[id]["node"].queue_free()
		_balls.erase(id)
	ball_gone.emit(id, at)


func _on_powerup_spawned(id: int, type: int, at: Vector3) -> void:
	var node := PowerUpManager.make_pickup_visual(type)
	node.position = at
	add_child(node)
	_pickups[id] = node


func _on_powerup_collected(id: int, _type: int, _slot: int) -> void:
	if _pickups.has(id):
		_pickups[id].queue_free()
		_pickups.erase(id)


func _on_snapshot(p_tick: int, p_state: int, p_time_left: float,
		p_countdown_left: float, p_radius: float, p_block_mask: int,
		data: PackedFloat32Array, extra: PackedByteArray) -> void:
	if not _snaps.is_empty() and p_tick <= _snaps[-1]["tick"]:
		return # late/duplicate packet
	_snaps.append({"tick": p_tick, "data": data})
	while _snaps.size() > MAX_BUFFER:
		_snaps.pop_front()
	tick = p_tick
	if tick % 600 < Net.SNAPSHOT_EVERY_N_TICKS and Net.my_slot >= 0 \
			and Net.my_slot < players.size():
		print("[net] snap tick=%d state=%d my puppet at %s" % [
			tick, p_state, players[Net.my_slot].global_position])
	if state != MatchSim.State.OVER: # round result is authoritative via event
		state = p_state as MatchSim.State
	time_left = p_time_left
	countdown_left = p_countdown_left
	if absf(p_radius - arena_radius) > 0.001: # melting variant
		arena_radius = p_radius
		MatchSim.resize_platform(_platform_shape, _platform_mesh, arena_radius)
	if ice_ring != null:
		ice_ring.apply_mask(p_block_mask)
	if tile_grid != null:
		tile_grid.apply_owners(extra)
	if MatchConfig.minigame == MatchConfig.Minigame.GOAL:
		_apply_pucks(extra)
		for slot in players.size():
			if not players[slot].alive and slot < _arc_markers.size():
				PuckManager.set_arc_neutral(_arc_markers, slot)
	# Non-interpolated stats come straight from the newest snapshot.
	for i in players.size():
		var base := i * Net.PLAYER_STRIDE
		if base + Net.PLAYER_STRIDE > data.size():
			break
		players[i].stamina = data[base + 4]
		var flags := int(data[base + 5])
		players[i].charging = flags & Net.FLAG_CHARGING != 0
		var frozen := flags & Net.FLAG_FROZEN != 0
		if frozen != (players[i].frozen_left > 0.0):
			players[i].frozen_left = 1.0 if frozen else 0.0
			players[i].set_frozen_visual(frozen)
		var vscale := data[base + 6]
		if absf(vscale - players[i].visual_scale) > 0.01:
			players[i].visual_scale = vscale
			players[i].set_visual_scale(vscale)
		if players[i].alive and flags & Net.FLAG_ALIVE == 0:
			players[i].alive = false
			players[i].visible = false


func _on_eliminated(slot: int, at: Vector3) -> void:
	if slot < players.size():
		players[slot].alive = false
		players[slot].visible = false
	player_eliminated.emit(slot, at)


func _on_round_over(winner_slot: int, _wins: Array) -> void:
	state = MatchSim.State.OVER
	print("[net] round over (client), winner slot %d, wins %s" % [winner_slot, str(MatchConfig.wins)])
	round_ended.emit(winner_slot)


## Rebuild the puck node pool to match the snapshot: [x, z, vx, vz] per puck.
func _apply_pucks(extra: PackedByteArray) -> void:
	var floats := extra.to_float32_array()
	var count := floats.size() / 4
	while _puck_nodes.size() < count:
		var node := PuckManager.make_puck_visual()
		add_child(node)
		_puck_nodes.append(node)
		_puck_vels.append(Vector3.ZERO)
	while _puck_nodes.size() > count:
		_puck_nodes.pop_back().queue_free()
		_puck_vels.pop_back()
	for i in count:
		_puck_nodes[i].position = Vector3(floats[i * 4], 0.25, floats[i * 4 + 1])
		_puck_vels[i] = Vector3(floats[i * 4 + 2], 0.0, floats[i * 4 + 3])


func _process(delta: float) -> void:
	# Snowballs fly deterministic straight lines; the client animates them
	# locally from the spawn event and removes them on the gone event.
	for id in _balls:
		var b: Dictionary = _balls[id]
		b["node"].position += b["dir"] * SnowballManager.SPEED * delta
	# Pucks dead-reckon along their last known velocity between snapshots.
	for i in _puck_nodes.size():
		_puck_nodes[i].position += _puck_vels[i] * delta
	if _snaps.size() < 2:
		return
	var newest: float = _snaps[-1]["tick"]
	var target := newest - INTERP_DELAY_TICKS
	if _render_tick < 0.0:
		_render_tick = target
	# Advance at sim rate, gently drift-correcting toward the target so a
	# hiccup doesn't cause a jump.
	_render_tick = move_toward(_render_tick, target, delta * 60.0 * 1.1)
	_render_tick = clampf(_render_tick, _snaps[0]["tick"], newest)

	var a: Dictionary = _snaps[0]
	var b: Dictionary = _snaps[-1]
	for i in _snaps.size() - 1:
		if _snaps[i + 1]["tick"] >= _render_tick:
			a = _snaps[i]
			b = _snaps[i + 1]
			break
	var span: float = float(b["tick"]) - float(a["tick"])
	var alpha := 0.0 if span <= 0.0 else clampf((_render_tick - float(a["tick"])) / span, 0.0, 1.0)
	var da: PackedFloat32Array = a["data"]
	var db: PackedFloat32Array = b["data"]
	for i in players.size():
		if not players[i].alive:
			continue
		var base := i * Net.PLAYER_STRIDE
		if base + Net.PLAYER_STRIDE > da.size() or base + Net.PLAYER_STRIDE > db.size():
			continue
		players[i].global_position = Vector3(
			lerpf(da[base], db[base], alpha),
			lerpf(da[base + 1], db[base + 1], alpha),
			lerpf(da[base + 2], db[base + 2], alpha))
		players[i].rotation.y = lerp_angle(da[base + 3], db[base + 3], alpha)
