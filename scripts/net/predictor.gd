class_name Predictor
extends Node3D
## Client-side prediction for the local player: runs a real SimPlayer locally
## (platform-only collision), stamps every input with a sequence number, and
## on each snapshot rewinds to the server's authoritative state and replays
## the inputs the server hasn't applied yet. Small corrections are hidden by a
## decaying visual offset; big ones (respawns, heavy shoves) snap.
##
## The predicted body can't see other players' collisions, so contact fights
## briefly diverge — reconciliation pulls them back within a snapshot or two.

const SNAP_ERROR := 3.0     # meters of divergence that warrant a hard snap
const BUFFER_LIMIT := 120   # ~2 s of inputs

var body: SimPlayer = null

var _replica: ClientReplica
var _input_source: PlayerController
var _buffer: Array[Dictionary] = []
var _seq := 0
var _active := true


func setup(replica: ClientReplica, input_source: PlayerController) -> void:
	_replica = replica
	_input_source = input_source
	var slot := Net.my_slot
	body = MatchSim.PLAYER_SCENE.instantiate()
	add_child(body)
	body.setup(slot, MatchConfig.archetype_for_slot(slot), MatchConfig.PLAYER_COLORS[slot])
	body.set_team(MatchConfig.team_of(slot))
	body.collision_layer = 0
	body.collision_mask = 1 # platform only — puppets have no collision anyway
	body.throw_mode = MatchConfig.minigame == MatchConfig.Minigame.SNOW \
		or MatchConfig.minigame == MatchConfig.Minigame.BOULDER
	# Mirror the puppet's spawn placement, then hide the puppet: the predicted
	# body is what the local player sees of themselves.
	var puppet := _replica.players[slot]
	body.global_position = puppet.global_position
	body.rotation.y = puppet.rotation.y
	body.facing = Vector3(-sin(puppet.rotation.y), 0, -cos(puppet.rotation.y))
	body.reset_physics_interpolation()
	puppet.visible = false
	Net.snapshot_received.connect(_on_snapshot)
	_replica.player_eliminated.connect(func(slot_out: int, _at: Vector3) -> void:
		if slot_out == Net.my_slot:
			_active = false
			body.visible = false)


func _exit_tree() -> void:
	if Net.snapshot_received.is_connected(_on_snapshot):
		Net.snapshot_received.disconnect(_on_snapshot)


func _physics_process(delta: float) -> void:
	if not _active or _replica.state != MatchSim.State.PLAYING:
		return
	var pi := _input_source.get_player_input(body, _replica)
	_seq += 1
	_buffer.append({"seq": _seq, "move": pi.move, "charge": pi.charge})
	while _buffer.size() > BUFFER_LIMIT:
		_buffer.pop_front()
	Net.send_input(_seq, pi.move, pi.charge)
	body.sim_tick(pi, delta)


func _on_snapshot(_tick: int, _state: int, _tl: float, _cd: float, _r: float,
		_mask: int, data: PackedFloat32Array, _extra: PackedByteArray,
		acked: PackedInt32Array) -> void:
	if not _active:
		return
	var slot := Net.my_slot
	var base := slot * Net.PLAYER_STRIDE
	if base + Net.PLAYER_STRIDE > data.size() or slot >= acked.size():
		return
	var pre := body.global_position

	# Rewind to the server's authoritative state...
	body.global_position = Vector3(data[base], data[base + 1], data[base + 2])
	body.velocity.x = data[base + 7]
	body.velocity.z = data[base + 8]
	body.stamina = data[base + 4]
	body.stagger_left = maxf(body.stagger_left, 0.0) # server stagger arrives as velocity

	# ...drop acknowledged inputs and replay the rest on top.
	var acked_seq := acked[slot]
	while not _buffer.is_empty() and _buffer[0]["seq"] <= acked_seq:
		_buffer.pop_front()
	var replay := PlayerInput.new()
	for entry in _buffer:
		replay.move = entry["move"]
		replay.charge = entry["charge"]
		body.sim_tick(replay, 1.0 / 60.0)

	# Hide the correction: small errors decay on the visual, big ones snap.
	var err := pre - body.global_position
	if err.length() < SNAP_ERROR:
		body.add_correction_offset(err)
	else:
		body.reset_physics_interpolation()
