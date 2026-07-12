class_name BarrageManager
extends Node3D
## Ball Barrage minigame (pong-style edge defense): each player is locked to a
## lane along their own side of a square court. Balls stream from the center;
## deflect them with your body. Every ball that slips past your side ticks
## your counter down from 15 — at zero you're out and your side seals into a
## wall. Last defender standing, or the highest counter when the clock dies.
## Runs on the simulating side only; clients render balls from snapshot extra.

signal counter_changed(slot: int, count_left: int, at: Vector3)
signal ball_launched(id: int, at: Vector3)

const START_COUNT := 15
const BALL_SPEED := 6.0
const BALL_SPEED_MAX := 11.5
const BALL_SPEED_RAMP := 0.25    # per relaunch
const DEFLECT_RADIUS := 0.85
const RELAUNCH_DELAY := 1.0
const RAMP_INTERVAL := 20.0      # +1 concurrent ball this often
const GOLDEN_ANGLE := 2.399963

# Side s spans the platform edge whose outward normal is SIDE_NORMALS[s].
const SIDE_NORMALS: Array = [
	Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0)]

var lives: Array[int] = [] # counters; named to match the other modes for HUD reuse

var _sim = null
var _next_id := 0
var _launched := 0
var _start_balls := 2
var _speed_mult := 1.0
var _balls := {} # id -> {pos, vel, node, respawn_t}


static func side_of_slot(slot: int) -> int:
	return slot % 4


## Lane center line: players sit this far from center, sliding sideways only.
static func lane_distance(radius: float) -> float:
	return radius - 0.8


func setup(sim, stage: Dictionary) -> void:
	_sim = sim
	_start_balls = stage.get("balls", 2)
	_speed_mult = stage.get("speed", 1.0)
	for i in sim.players.size():
		lives.append(START_COUNT)


func tick(dt: float) -> void:
	var elapsed: float = Tuning.ROUND_TIME - _sim.time_left
	var want := mini(_start_balls + int(elapsed / RAMP_INTERVAL), 5)
	if _balls.size() < want:
		_launch()
	for id in _balls.keys():
		var b: Dictionary = _balls[id]
		if b["respawn_t"] > 0.0:
			if elapsed >= b["respawn_t"]:
				_relaunch(b)
			continue
		_step(b, dt)


func _launch() -> void:
	var id := _next_id
	_next_id += 1
	var node := PuckManager.make_puck_visual()
	(node as MeshInstance3D).mesh.material.albedo_color = Color(0.85, 0.9, 0.95)
	add_child(node)
	_balls[id] = {"pos": Vector3(0, 0.25, 0), "vel": Vector3.ZERO,
		"node": node, "respawn_t": 0.0}
	_relaunch(_balls[id])


func _relaunch(b: Dictionary) -> void:
	_launched += 1
	var a := fposmod(_launched * GOLDEN_ANGLE, TAU)
	var speed: float = minf(BALL_SPEED * _speed_mult + _launched * BALL_SPEED_RAMP,
		BALL_SPEED_MAX)
	b["pos"] = Vector3(0, 0.25, 0)
	b["vel"] = Vector3(sin(a), 0, cos(a)) * speed
	b["respawn_t"] = 0.0
	b["node"].visible = true
	b["node"].position = b["pos"]
	ball_launched.emit(_launched, b["pos"])


func _step(b: Dictionary, dt: float) -> void:
	b["pos"] += b["vel"] * dt
	b["node"].position = b["pos"]

	# Deflect off defenders — inherit lateral motion so saves aim.
	for p in _sim.players:
		if not p.alive:
			continue
		var n: Vector3 = b["pos"] - p.global_position
		n.y = 0.0
		if n.length() > DEFLECT_RADIUS or n.length() < 0.001:
			continue
		n = n.normalized()
		var v: Vector3 = b["vel"]
		if v.dot(n) < 0.0:
			v = v - 2.0 * v.dot(n) * n
			v += Vector3(p.velocity.x, 0, p.velocity.z) * 0.45
			v.y = 0.0
			b["vel"] = v.normalized() * clampf(v.length() * 1.03,
				BALL_SPEED * 0.8, BALL_SPEED_MAX)
			SoundBank.play("crack", -14.0)

	# Court edges: score on a defended side, bounce off sealed/empty sides.
	var r: float = _sim.arena_radius
	for s in 4:
		var normal: Vector3 = SIDE_NORMALS[s]
		var along: float = b["pos"].dot(normal)
		if along < r - 0.25:
			continue
		var owner := _defender_for(s, b["pos"])
		if owner >= 0:
			lives[owner] -= 1
			counter_changed.emit(owner, lives[owner], b["pos"])
			b["respawn_t"] = (Tuning.ROUND_TIME - _sim.time_left) + RELAUNCH_DELAY
			b["node"].visible = false
			return
		# Wall bounce.
		if b["vel"].dot(normal) > 0.0:
			b["vel"] = b["vel"] - 2.0 * b["vel"].dot(normal) * normal


## The alive defender responsible for this crossing point (two players can
## share a side at 5-8 players; each owns the half their lane covers).
func _defender_for(side: int, at: Vector3) -> int:
	var tangent: Vector3 = Vector3.UP.cross(SIDE_NORMALS[side])
	var t := at.dot(tangent)
	var best := -1
	var best_d := INF
	for p in _sim.players:
		if not p.alive or side_of_slot(p.slot) != side or lives[p.slot] <= 0:
			continue
		var d := absf(p.global_position.dot(tangent) - t)
		if d < best_d:
			best_d = d
			best = p.slot
	return best


## Alive slot with the highest counter; -1 on a tie (round-timer resolution).
func leader() -> int:
	var best := -1
	var best_n := -1
	var tied := false
	for slot in lives.size():
		if not _sim.players[slot].alive:
			continue
		if lives[slot] > best_n:
			best_n = lives[slot]
			best = slot
			tied = false
		elif lives[slot] == best_n:
			tied = true
	return -1 if tied else best


## Snapshot payload: [x, z, vx, vz] per visible ball.
func encode() -> PackedByteArray:
	var floats := PackedFloat32Array()
	for id in _balls:
		var b: Dictionary = _balls[id]
		if b["respawn_t"] > 0.0:
			continue
		floats.append(b["pos"].x)
		floats.append(b["pos"].z)
		floats.append(b["vel"].x)
		floats.append(b["vel"].z)
	return floats.to_byte_array()


## For bots: live balls.
func ball_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _balls:
		if _balls[id]["respawn_t"] <= 0.0:
			out.append({"pos": _balls[id]["pos"], "vel": _balls[id]["vel"]})
	return out
