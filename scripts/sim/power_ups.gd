class_name PowerUpManager
extends Node3D
## Variant module: a drone drops a power-up every POWERUP_INTERVAL seconds.
## Drop positions/types are derived deterministically from the drop index
## (golden-angle spread), so the server sim stays reproducible. Runs only on
## the simulating side; clients mirror pickups from spawn/collect events.

signal powerup_spawned(id: int, type: int, at: Vector3)
signal powerup_collected(id: int, type: int, slot: int)

enum Type { GROW, SHRINK_OTHERS, FREEZE_OTHERS }

const GOLDEN_ANGLE := 2.399963

var _sim = null # MatchSim
var _next_drop_index := 0
var _active := {} # id -> {type, pos, node}


func setup(sim) -> void:
	_sim = sim


func tick() -> void:
	var elapsed: float = Tuning.ROUND_TIME - _sim.time_left
	if elapsed >= Tuning.POWERUP_INTERVAL * (_next_drop_index + 1):
		_spawn(_next_drop_index)
		_next_drop_index += 1
	_check_pickups()


func _spawn(index: int) -> void:
	var angle := fposmod(index * GOLDEN_ANGLE, TAU)
	var frac := fposmod(index * 0.618, 1.0)
	# Keep drops inside the melted platform if both variants are active.
	var r: float = _sim.arena_radius * (0.2 + 0.55 * frac)
	var pos := Vector3(sin(angle), 0.0, cos(angle)) * r + Vector3(0, 0.7, 0)
	var type := index % Type.size() as Type
	var node := make_pickup_visual(type)
	node.position = pos
	add_child(node)
	_active[index] = {"type": type, "pos": pos, "node": node}
	print("[sim] power-up %d (%s) dropped at %s" % [index, Type.keys()[type], pos])
	powerup_spawned.emit(index, type, pos)


func _check_pickups() -> void:
	for id in _active.keys():
		var pickup: Dictionary = _active[id]
		for p in _sim.players:
			if not p.alive:
				continue
			var d: Vector3 = p.global_position - pickup["pos"]
			d.y = 0.0
			if d.length() <= Tuning.POWERUP_PICKUP_RADIUS:
				_collect(id, pickup, p)
				break


func _collect(id: int, pickup: Dictionary, collector: SimPlayer) -> void:
	var type: int = pickup["type"]
	match type:
		Type.GROW:
			collector.apply_grow()
		Type.SHRINK_OTHERS:
			for p in _sim.players:
				if p.alive and p != collector:
					p.apply_shrink()
		Type.FREEZE_OTHERS:
			for p in _sim.players:
				if p.alive and p != collector:
					p.frozen_left = Tuning.POWERUP_FREEZE_TIME
	pickup["node"].queue_free()
	_active.erase(id)
	print("[sim] power-up %d (%s) collected by slot %d" % [id, Type.keys()[type], collector.slot])
	powerup_collected.emit(id, type, collector.slot)


## Shared with ClientReplica so pickups look identical on both sides:
## a slowly-bobbing colored crate on a stub "drone" antenna.
static func make_pickup_visual(type: int) -> Node3D:
	var root := Node3D.new()
	var mesh_i := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.55, 0.55, 0.55)
	mesh_i.mesh = mesh
	var mat := StandardMaterial3D.new()
	match type:
		Type.GROW:
			mat.albedo_color = Color(0.3, 0.9, 0.35)
		Type.SHRINK_OTHERS:
			mat.albedo_color = Color(0.7, 0.35, 0.9)
		Type.FREEZE_OTHERS:
			mat.albedo_color = Color(0.4, 0.85, 1.0)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color * 0.6
	mesh_i.material_override = mat
	root.add_child(mesh_i)
	var spin := AnimationHelper.new()
	root.add_child(spin)
	return root


## Tiny presentation helper: spins/bobs the pickup so it reads as collectible.
class AnimationHelper extends Node:
	var _t := 0.0
	var _base_y := 0.0

	func _ready() -> void:
		_base_y = (get_parent() as Node3D).position.y

	func _process(delta: float) -> void:
		_t += delta
		var parent := get_parent() as Node3D
		parent.rotation.y += delta * 2.0
		parent.position.y = _base_y + sin(_t * 3.0) * 0.12
