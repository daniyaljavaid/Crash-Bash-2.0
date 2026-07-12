class_name PuckManager
extends Node3D
## Puck Panic minigame module (goal-defense genre): the platform rim is split
## into one colored goal arc per player. Pucks launch from the center and
## ricochet off bodies; a puck crossing YOUR arc costs a life. A dead player's
## arc turns into a neutral wall. Runs only on the simulating side; clients
## mirror puck positions from snapshot extra data and lives from events.

signal puck_spawned(id: int, at: Vector3)
signal puck_gone(id: int, at: Vector3)
signal goal_scored(slot: int, lives_left: int, at: Vector3)

const SPAWN_INTERVAL := 6.0
const MAX_PUCKS := 3
const START_SPEED := 7.0
const MAX_SPEED := 12.0
const DEFLECT_RADIUS := 0.8
const GOAL_MARGIN := 0.5       # puck scores this far from the rim
const START_LIVES := 5
const GOLDEN_ANGLE := 2.399963

var lives: Array[int] = []

var _sim = null
var _next_id := 0
var _spawned_count := 0
var _pucks := {} # id -> {pos: Vector3, vel: Vector3, node: Node3D}
var _arc_markers: Array = [] # per slot: Array[MeshInstance3D]


func setup(sim) -> void:
	_sim = sim
	for i in sim.players.size():
		lives.append(START_LIVES)
	_arc_markers = build_arc_markers(self, sim.arena_radius, sim.players.size())


func tick(dt: float) -> void:
	var elapsed: float = Tuning.ROUND_TIME - _sim.time_left
	if _pucks.size() < MAX_PUCKS \
			and elapsed >= 3.0 + _spawned_count * SPAWN_INTERVAL:
		_spawn()
	for id in _pucks.keys():
		_step_puck(id, _pucks[id], dt)
	# Arcs of players who fell in the water (or ran out of lives) go neutral.
	for slot in _sim.players.size():
		if not _sim.players[slot].alive:
			set_arc_neutral(_arc_markers, slot)


func _spawn() -> void:
	var id := _next_id
	_next_id += 1
	_spawned_count += 1
	var angle := fposmod(_spawned_count * GOLDEN_ANGLE, TAU)
	var vel := Vector3(sin(angle), 0.0, cos(angle)) * START_SPEED
	var pos := Vector3(0, 0.25, 0)
	var node := make_puck_visual()
	node.position = pos
	add_child(node)
	_pucks[id] = {"pos": pos, "vel": vel, "node": node}
	puck_spawned.emit(id, pos)


func _step_puck(id: int, p: Dictionary, dt: float) -> void:
	p["pos"] += p["vel"] * dt
	p["node"].position = p["pos"]

	# Body deflection: reflect off any alive player, inherit some of their
	# motion so a sprinting save actually clears the puck.
	for pl in _sim.players:
		if not pl.alive:
			continue
		var n: Vector3 = p["pos"] - pl.global_position
		n.y = 0.0
		if n.length() > DEFLECT_RADIUS or n.length() < 0.001:
			continue
		n = n.normalized()
		var v: Vector3 = p["vel"]
		if v.dot(n) < 0.0: # only when approaching
			v = v - 2.0 * v.dot(n) * n
			v += Vector3(pl.velocity.x, 0, pl.velocity.z) * 0.4
			v.y = 0.0
			p["vel"] = v.normalized() * clampf(v.length() * 1.05, START_SPEED, MAX_SPEED)
			SoundBank.play("crack", -14.0)

	# Stage obstacles (Bumper Rink): pucks ricochet off cover.
	if _sim.point_in_cover(p["pos"]):
		var center = _sim.cover_center_at(p["pos"])
		if center != null:
			var n: Vector3 = p["pos"] - center
			n.y = 0.0
			if n.length() > 0.001:
				n = n.normalized()
				var v: Vector3 = p["vel"]
				if v.dot(n) < 0.0:
					p["vel"] = v - 2.0 * v.dot(n) * n
					SoundBank.play("crack", -16.0)

	# Rim: score against the arc owner, or bounce off a neutralized arc.
	var flat := Vector2(p["pos"].x, p["pos"].z)
	if flat.length() >= _sim.arena_radius - GOAL_MARGIN:
		var slot := arc_slot_at(atan2(flat.x, flat.y), _sim.players.size())
		if _sim.players[slot].alive and lives[slot] > 0:
			lives[slot] -= 1
			goal_scored.emit(slot, lives[slot], p["pos"])
			_remove(id, p["pos"])
		else:
			var inward := -Vector3(flat.x, 0, flat.y).normalized()
			var v: Vector3 = p["vel"]
			if v.dot(inward) < 0.0:
				p["vel"] = (v - 2.0 * v.dot(-inward) * -inward) * 0.95


func _remove(id: int, at: Vector3) -> void:
	_pucks[id]["node"].queue_free()
	_pucks.erase(id)
	puck_gone.emit(id, at)


## Alive slot with the most lives; -1 on a tie (round-timer resolution).
func leader() -> int:
	var best := -1
	var best_lives := -1
	var tied := false
	for slot in lives.size():
		if not _sim.players[slot].alive:
			continue
		if lives[slot] > best_lives:
			best_lives = lives[slot]
			best = slot
			tied = false
		elif lives[slot] == best_lives:
			tied = true
	return -1 if tied else best


## Snapshot payload: [x, z, vx, vz] per puck (ids implicit by order — clients
## rebuild the set every snapshot, so identity doesn't matter for rendering).
func encode_pucks() -> PackedByteArray:
	var floats := PackedFloat32Array()
	for id in _pucks:
		var p: Dictionary = _pucks[id]
		floats.append(p["pos"].x)
		floats.append(p["pos"].z)
		floats.append(p["vel"].x)
		floats.append(p["vel"].z)
	return floats.to_byte_array()


## For bots: list of {pos, vel} snapshots of live pucks.
func puck_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _pucks:
		out.append({"pos": _pucks[id]["pos"], "vel": _pucks[id]["vel"]})
	return out


# --- shared visual helpers (also used by ClientReplica) ----------------------

static func make_puck_visual() -> Node3D:
	var node := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.34
	mesh.bottom_radius = 0.34
	mesh.height = 0.18
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.15, 0.16, 0.2)
	mat.roughness = 0.35
	mesh.material = mat
	node.mesh = mesh
	return node


## Which player's goal arc covers this rim angle (arcs centered on spawns).
static func arc_slot_at(angle: float, player_count: int) -> int:
	var per := TAU / player_count
	return int(fposmod(angle + per * 0.5, TAU) / per) % player_count


## Colored rim markers, one arc per player. Returns per-slot marker arrays.
static func build_arc_markers(parent: Node3D, arena_radius: float, player_count: int) -> Array:
	var per_slot: Array = []
	var per := TAU / player_count
	for slot in player_count:
		var markers: Array = []
		var center := TAU * float(slot) / float(player_count)
		var arc_len := per * (arena_radius - 0.2)
		var seg_count := maxi(int(arc_len / 1.1), 3)
		for s in seg_count:
			var a := center + per * (float(s) + 0.5) / seg_count - per * 0.5
			var seg := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(1.0, 0.35, 0.18)
			seg.mesh = mesh
			var mat := StandardMaterial3D.new()
			mat.albedo_color = MatchConfig.PLAYER_COLORS[slot]
			mat.emission_enabled = true
			mat.emission = MatchConfig.PLAYER_COLORS[slot] * 0.4
			seg.material_override = mat
			seg.position = Vector3(sin(a), 0.0, cos(a)) * (arena_radius - 0.15) \
				+ Vector3(0, 0.18, 0)
			seg.rotation.y = a
			parent.add_child(seg)
			markers.append(seg)
		per_slot.append(markers)
	return per_slot


static func set_arc_neutral(arc_markers: Array, slot: int) -> void:
	for seg in arc_markers[slot]:
		var mat := (seg as MeshInstance3D).material_override as StandardMaterial3D
		if mat.albedo_color != Color(0.45, 0.5, 0.58):
			mat.albedo_color = Color(0.45, 0.5, 0.58)
			mat.emission_enabled = false
