class_name BoulderManager
extends Node3D
## Boulder Brawl minigame module (melee/throwables genre): snow boulders lie
## on the ice; walk into one to hoist it (slows you), charge button hurls it.
## A hit costs one of three hearts, shoves hard, and shatters the boulder
## (respawns later). Landed misses stay where they slid — the arsenal drifts.
## Runs on the simulating side only; clients render from snapshot extra data.

signal hp_changed(slot: int, hp_left: int, at: Vector3)
signal thrown(id: int, from: Vector3, dir: Vector3) # relayed for the throw sound

enum BState { IDLE, CARRIED, FLYING }

const HP_START := 5
const THROW_SPEED := 13.0
const THROW_RANGE := 14.0
const PICKUP_RADIUS := 1.0
const HIT_RADIUS := 0.8
const DAMAGE_KNOCKBACK := 10.0
const CARRY_HEIGHT := 1.35
const RESPAWN_DELAY := 5.0
const GOLDEN_ANGLE := 2.399963

var lives: Array[int] = [] # hearts; named to match PuckManager for HUD reuse

var _sim = null
var _boulders := {} # id -> {state, pos, vel, carrier, traveled, node, respawn_t, home}
var _carrier_boulder := {} # slot -> boulder id


func setup(sim) -> void:
	_sim = sim
	for i in sim.players.size():
		lives.append(HP_START)
	var count: int = sim.players.size() + 2
	for i in count:
		var angle := i * GOLDEN_ANGLE
		# Center-biased so nobody spawns next to ammo — you leave your corner.
		var r: float = sim.arena_radius * (0.12 + 0.3 * fposmod(i * 0.618, 1.0))
		var home := Vector3(sin(angle), 0.45, cos(angle)) * r
		home.y = 0.45
		var node := make_boulder_visual()
		node.position = home
		add_child(node)
		_boulders[i] = {"state": BState.IDLE, "pos": home, "vel": Vector3.ZERO,
			"carrier": -1, "traveled": 0.0, "node": node, "respawn_t": 0.0, "home": home}
	for p in sim.players:
		p.throw_requested.connect(_on_throw_requested.bind(p))


func carrying(slot: int) -> bool:
	return _carrier_boulder.has(slot)


func tick(dt: float) -> void:
	var elapsed: float = Tuning.ROUND_TIME - _sim.time_left
	for id in _boulders.keys():
		var b: Dictionary = _boulders[id]
		match b["state"]:
			BState.IDLE:
				_check_pickup(id, b)
			BState.CARRIED:
				var carrier: SimPlayer = _sim.players[b["carrier"]]
				if not carrier.alive:
					_drop(id, b, carrier.global_position)
				else:
					b["pos"] = carrier.global_position + Vector3(0, CARRY_HEIGHT, 0)
					b["node"].position = b["pos"]
			BState.FLYING:
				_step_flight(id, b, dt)
		# Shattered boulders respawn at home after a delay.
		if not b["node"].visible and b["respawn_t"] > 0.0 and elapsed >= b["respawn_t"]:
			b["state"] = BState.IDLE
			b["pos"] = b["home"]
			b["respawn_t"] = 0.0
			b["node"].position = b["home"]
			b["node"].visible = true


func _check_pickup(id: int, b: Dictionary) -> void:
	if not b["node"].visible:
		return
	for p in _sim.players:
		if not p.alive or carrying(p.slot):
			continue
		var d: Vector3 = p.global_position - b["pos"]
		d.y = 0.0
		if d.length() <= PICKUP_RADIUS:
			b["state"] = BState.CARRIED
			b["carrier"] = p.slot
			_carrier_boulder[p.slot] = id
			p.carry_slow = true
			return


func _on_throw_requested(dir: Vector3, thrower: SimPlayer) -> void:
	if not carrying(thrower.slot):
		# Empty-handed: the sim already charged stamina for a throw — refund.
		thrower.stamina = minf(thrower.stamina + thrower.stats.stamina_cost, Tuning.STAMINA_MAX)
		thrower.recovery_left = 0.0
		return
	var id: int = _carrier_boulder[thrower.slot]
	var b: Dictionary = _boulders[id]
	_carrier_boulder.erase(thrower.slot)
	thrower.carry_slow = false
	b["state"] = BState.FLYING
	b["carrier"] = thrower.slot
	b["pos"] = thrower.global_position + Vector3(0, 0.6, 0) + dir * 0.7
	b["vel"] = dir * THROW_SPEED
	b["traveled"] = 0.0
	b["node"].position = b["pos"]
	thrown.emit(id, b["pos"], dir)


func _drop(id: int, b: Dictionary, at: Vector3) -> void:
	_carrier_boulder.erase(b["carrier"])
	b["state"] = BState.IDLE
	b["carrier"] = -1
	b["pos"] = Vector3(at.x, 0.45, at.z)
	b["node"].position = b["pos"]


func _step_flight(id: int, b: Dictionary, dt: float) -> void:
	b["pos"] += b["vel"] * dt
	b["traveled"] += b["vel"].length() * dt
	b["node"].position = b["pos"]
	if _sim.point_in_cover(b["pos"]):
		_shatter(id, b) # smashed against a rock pillar
		return
	var thrower: SimPlayer = _sim.players[b["carrier"]]
	for p in _sim.players:
		if p.slot == b["carrier"] or not p.alive or thrower.is_teammate(p):
			continue
		var d: Vector3 = p.global_position + Vector3(0, 0.5, 0) - b["pos"]
		if d.length() <= HIT_RADIUS:
			var dir: Vector3 = b["vel"].normalized()
			var impulse: float = DAMAGE_KNOCKBACK * p.knockback_mult
			p.velocity.x += dir.x * impulse
			p.velocity.z += dir.z * impulse
			p.velocity.y += Tuning.HIT_POP
			p.stagger_left = Tuning.HIT_STAGGER
			if lives[p.slot] > 0:
				lives[p.slot] -= 1
				hp_changed.emit(p.slot, lives[p.slot], p.global_position)
			_shatter(id, b)
			return
	if b["traveled"] >= THROW_RANGE:
		var flat := Vector2(b["pos"].x, b["pos"].z)
		if flat.length() > _sim.arena_radius - 0.5:
			_shatter(id, b) # slid off the edge
		else:
			b["state"] = BState.IDLE
			b["pos"].y = 0.45
			b["node"].position = b["pos"]


func _shatter(id: int, b: Dictionary) -> void:
	b["state"] = BState.IDLE
	b["node"].visible = false
	b["respawn_t"] = (Tuning.ROUND_TIME - _sim.time_left) + RESPAWN_DELAY


## Alive slot with the most hearts; -1 on a tie (round-timer resolution).
func leader() -> int:
	var best := -1
	var best_hp := -1
	var tied := false
	for slot in lives.size():
		if not _sim.players[slot].alive:
			continue
		if lives[slot] > best_hp:
			best_hp = lives[slot]
			best = slot
			tied = false
		elif lives[slot] == best_hp:
			tied = true
	return -1 if tied else best


## Snapshot payload: [state_code, x, z, vx, vz] per boulder.
## state_code: -1 idle, -2 flying, -3 shattered/hidden, >=0 carried-by-slot.
func encode() -> PackedByteArray:
	var floats := PackedFloat32Array()
	for id in _boulders:
		var b: Dictionary = _boulders[id]
		var code := -1.0
		if not b["node"].visible:
			code = -3.0
		elif b["state"] == BState.FLYING:
			code = -2.0
		elif b["state"] == BState.CARRIED:
			code = float(b["carrier"])
		floats.append(code)
		floats.append(b["pos"].x)
		floats.append(b["pos"].z)
		floats.append(b["vel"].x)
		floats.append(b["vel"].z)
	return floats.to_byte_array()


## For bots: idle boulders they can grab / opponents to hit.
func idle_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for id in _boulders:
		var b: Dictionary = _boulders[id]
		if b["state"] == BState.IDLE and b["node"].visible:
			out.append(b["pos"])
	return out


static func make_boulder_visual() -> Node3D:
	var node := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.42
	mesh.height = 0.78 # slightly squashed snowball boulder
	mesh.radial_segments = 10
	mesh.rings = 6
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.92, 0.94, 0.98)
	mat.roughness = 0.6
	mesh.material = mat
	node.mesh = mesh
	return node
