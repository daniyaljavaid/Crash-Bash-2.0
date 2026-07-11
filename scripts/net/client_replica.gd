class_name ClientReplica
extends Node3D
## Client-side stand-in for MatchSim: exposes the same read API the HUD and
## camera use (players, state, time_left, countdown_left, arena_radius) and
## the same signals, but is driven entirely by server snapshots. Runs no
## gameplay logic — puppets are interpolated between two buffered snapshots
## ~100 ms behind the newest, so 20 Hz snapshots render smoothly at any FPS.

signal player_eliminated(slot: int, at: Vector3)
signal round_ended(winner_slot: int)

const INTERP_DELAY_TICKS := 6.0   # 100 ms at the 60 Hz sim tick
const MAX_BUFFER := 20

var players: Array[SimPlayer] = []
var state := MatchSim.State.COUNTDOWN
var time_left := Tuning.ROUND_TIME
var countdown_left := Tuning.COUNTDOWN_TIME
var arena_radius := Tuning.ARENA_RADIUS_SMALL
var tick := 0

signal block_destroyed(index: int, at: Vector3)

var ice_ring: IceBlockRing = null

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
	for i in player_count:
		var p: SimPlayer = MatchSim.PLAYER_SCENE.instantiate()
		add_child(p)
		p.setup(i, CharacterStats.for_slot(i), MatchConfig.PLAYER_COLORS[i])
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


func _exit_tree() -> void:
	if Net.snapshot_received.is_connected(_on_snapshot):
		Net.snapshot_received.disconnect(_on_snapshot)
		Net.net_eliminated.disconnect(_on_eliminated)
		Net.net_round_over.disconnect(_on_round_over)
		Net.net_powerup_spawned.disconnect(_on_powerup_spawned)
		Net.net_powerup_collected.disconnect(_on_powerup_collected)


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
		data: PackedFloat32Array) -> void:
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


func _process(delta: float) -> void:
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
