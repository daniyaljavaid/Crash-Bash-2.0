class_name RaceManager
extends Node3D
## Floe Dash minigame module (race genre): sprint laps counterclockwise around
## the floe. Progress is accumulated rim angle, so corner-cutting through the
## middle earns nothing and running backwards loses ground. Shoving is legal
## and encouraged. Falling in respawns you on the lane where you fell.
## First to LAPS_TO_WIN, or most progress when the clock dies.

signal lap_completed(slot: int, laps: int, at: Vector3) # reuses the lives event channel

const LAPS_TO_WIN := 7
const LANE_FRACTION := 0.72

var progress: Array[float] = [] # accumulated radians, counterclockwise positive
var laps: Array[int] = []

var _sim = null
var _prev_angle: Array[float] = []


func setup(sim) -> void:
	_sim = sim
	for i in sim.players.size():
		progress.append(0.0)
		laps.append(0)
		var pos: Vector3 = sim.players[i].global_position
		_prev_angle.append(atan2(pos.x, pos.z))
	build_track_markers(self, sim.arena_radius)


func tick() -> void:
	for slot in _sim.players.size():
		var p: SimPlayer = _sim.players[slot]
		if not p.alive:
			continue
		var a := atan2(p.global_position.x, p.global_position.z)
		var delta := wrapf(a - _prev_angle[slot], -PI, PI)
		_prev_angle[slot] = a
		# Airborne (falling) movement doesn't count.
		if p.is_on_floor():
			progress[slot] = maxf(progress[slot] + delta, -TAU)
		if progress[slot] >= TAU * (laps[slot] + 1):
			laps[slot] += 1
			lap_completed.emit(slot, laps[slot], p.global_position)


## Called by MatchSim when a racer falls in — back onto the lane where they
## fell, so no progress is gained or lost by swimming.
func respawn_position(fell_at: Vector3) -> Vector3:
	var flat := Vector3(fell_at.x, 0.0, fell_at.z)
	if flat.length() < 0.5:
		flat = Vector3(0, 0, 1)
	return flat.normalized() * _sim.arena_radius * LANE_FRACTION + Vector3(0, 1.0, 0)


func finished_slot() -> int:
	for slot in laps.size():
		if laps[slot] >= LAPS_TO_WIN:
			return slot
	return -1


## Most progress; -1 on a tie for first.
func leader() -> int:
	var best := -1
	var best_p := -INF
	var tied := false
	for slot in progress.size():
		if progress[slot] > best_p:
			best_p = progress[slot]
			best = slot
			tied = false
		elif is_equal_approx(progress[slot], best_p):
			tied = true
	return -1 if tied else best


## Snapshot payload: [progress] per slot.
func encode() -> PackedByteArray:
	var floats := PackedFloat32Array()
	for p in progress:
		floats.append(p)
	return floats.to_byte_array()


## Lane dashes + a start gate. Shared with ClientReplica.
static func build_track_markers(parent: Node3D, arena_radius: float) -> void:
	var lane_r := arena_radius * LANE_FRACTION
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.9, 1.0, 0.85)
	for i in 24:
		var a := TAU * float(i) / 24.0
		var dash := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.18, 0.04, 0.9)
		dash.mesh = mesh
		dash.material_override = mat
		dash.position = Vector3(sin(a), 0.03, cos(a)) * lane_r
		dash.rotation.y = a
		parent.add_child(dash)
	# Start/finish gate at angle 0 (the slot-0 spawn side).
	var gate_mat := StandardMaterial3D.new()
	gate_mat.albedo_color = Color(1.0, 0.85, 0.3)
	gate_mat.emission_enabled = true
	gate_mat.emission = Color(1.0, 0.85, 0.3) * 0.5
	for side in [-1.0, 1.0]:
		var pillar := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.12
		mesh.bottom_radius = 0.16
		mesh.height = 2.2
		pillar.mesh = mesh
		pillar.material_override = gate_mat
		var offset := Vector3(0, 0, side * arena_radius * 0.14)
		pillar.position = Vector3(0, 1.1, lane_r) + offset
		parent.add_child(pillar)
