class_name SnowballManager
extends Node3D
## Snow Brawl minigame module: straight-flying snowball projectiles. Runs only
## on the simulating side; clients animate identical flights locally from the
## spawn event (paths are deterministic: origin + direction + fixed speed).

signal ball_spawned(id: int, from: Vector3, dir: Vector3)
signal ball_gone(id: int, at: Vector3)
signal ball_hit(attacker_slot: int, victim_slot: int, at: Vector3)

const SPEED := 15.0
const RANGE := 12.0
const HIT_RADIUS := 0.7
const KNOCKBACK_FACTOR := 0.85 # of the thrower archetype's push_power

var _sim = null # MatchSim
var _next_id := 0
var _balls := {} # id -> {owner: int, pos: Vector3, dir: Vector3, traveled: float, node}


func setup(sim) -> void:
	_sim = sim


func throw_ball(owner: SimPlayer, dir: Vector3) -> void:
	var id := _next_id
	_next_id += 1
	var from := owner.global_position + Vector3(0, 0.35, 0) + dir * 0.6
	var node := make_ball_visual()
	node.position = from
	add_child(node)
	_balls[id] = {"owner": owner.slot, "pos": from, "dir": dir, "traveled": 0.0, "node": node}
	ball_spawned.emit(id, from, dir)


func tick(dt: float) -> void:
	for id in _balls.keys():
		var b: Dictionary = _balls[id]
		var step: Vector3 = b["dir"] * SPEED * dt
		b["pos"] += step
		b["traveled"] += SPEED * dt
		b["node"].position = b["pos"]
		var hit := false
		for p in _sim.players:
			if p.slot == b["owner"] or not p.alive:
				continue
			var d: Vector3 = p.global_position + Vector3(0, 0.3, 0) - b["pos"]
			if d.length() <= HIT_RADIUS:
				_apply_hit(b, p)
				hit = true
				break
		if hit or b["traveled"] >= RANGE:
			_remove(id, b["pos"])


func _apply_hit(ball: Dictionary, victim: SimPlayer) -> void:
	var attacker: SimPlayer = _sim.players[ball["owner"]]
	var impulse: float = attacker.stats.push_power * KNOCKBACK_FACTOR \
		* attacker.power_mult * victim.knockback_mult
	var dir: Vector3 = ball["dir"]
	victim.velocity.x += dir.x * impulse
	victim.velocity.z += dir.z * impulse
	victim.velocity.y += Tuning.HIT_POP
	victim.stagger_left = Tuning.HIT_STAGGER
	ball_hit.emit(ball["owner"], victim.slot, victim.global_position)


func _remove(id: int, at: Vector3) -> void:
	_balls[id]["node"].queue_free()
	_balls.erase(id)
	ball_gone.emit(id, at)


## Shared with ClientReplica so both sides render the same ball.
static func make_ball_visual() -> Node3D:
	var node := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.22
	mesh.height = 0.44
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.97, 0.98, 1.0)
	mesh.material = mat
	node.mesh = mesh
	return node
