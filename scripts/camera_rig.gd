extends Node3D
## Presentation-only camera. Follows the centroid of alive players.
## Moves in _process (render rate) with exponential smoothing so it is fluid at
## 240 Hz. Physics interpolation is disabled on this branch — the rig is not
## driven by physics ticks, interpolating it would fight the _process motion.

const FOLLOW_WEIGHT := 0.3   # how far the camera drifts toward the action
const SMOOTH_RATE := 3.0     # exponential smoothing rate (1/s)

const SHAKE_DECAY := 5.0

var _sim = null # MatchSim or ClientReplica — same read API
var _base_pos := Vector3.ZERO
var _shake := 0.0

@onready var _cam: Camera3D = $Camera3D


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func add_shake(strength: float) -> void:
	_shake = minf(_shake + strength, 1.0)


func setup(sim) -> void:
	_sim = sim
	_base_pos = Vector3(0.0, sim.arena_radius * 1.8, sim.arena_radius * 1.5)
	global_position = _base_pos
	look_at(Vector3.ZERO)


func _process(delta: float) -> void:
	if _sim == null:
		return
	var centroid := Vector3.ZERO
	var n := 0
	for p in _sim.players:
		if p.alive:
			centroid += p.global_position
			n += 1
	if n > 0:
		centroid /= n
	var target := _base_pos + Vector3(centroid.x, 0.0, centroid.z) * FOLLOW_WEIGHT
	var t := 1.0 - exp(-SMOOTH_RATE * delta)
	global_position = global_position.lerp(target, t)
	look_at(Vector3(centroid.x, 0.0, centroid.z) * FOLLOW_WEIGHT)
	# Shake: presentation-only jitter on the camera child, never the rig path.
	if _shake > 0.001:
		_shake = maxf(_shake - SHAKE_DECAY * _shake * delta, 0.0)
		var s := _shake * _shake * 0.35
		_cam.position = Vector3(randf_range(-s, s), randf_range(-s, s), 0.0)
	else:
		_cam.position = Vector3.ZERO
