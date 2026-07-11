class_name MatchSim
extends Node3D
## Authoritative match simulation: arena geometry, player spawning, the round
## state machine, and the fixed-tick loop that feeds PlayerInputs into players.
## In M2 this node runs on the server; clients only render its synced state.

signal player_eliminated(slot: int, at: Vector3)
signal round_ended(winner_slot: int) # -1 = tie

enum State { COUNTDOWN, PLAYING, OVER }

const PLAYER_SCENE := preload("res://scenes/player.tscn")

var state := State.COUNTDOWN
var players: Array[SimPlayer] = []
var controllers: Array[PlayerController] = []
var arena_radius := Tuning.ARENA_RADIUS_SMALL
var time_left := Tuning.ROUND_TIME
var countdown_left := Tuning.COUNTDOWN_TIME
var tick := 0
var winner_slot := -1

var _started := false


## controllers_override lets the network layer supply per-slot controllers
## (host input, remote peers, bots) without the sim knowing about networking.
## Empty = M1 behavior (local humans by scheme, bots for the rest).
func start_match(player_count: int, human_count: int,
		controllers_override: Array[PlayerController] = []) -> void:
	arena_radius = radius_for_player_count(player_count)
	add_child(build_platform(arena_radius))
	_build_kill_zone()
	_spawn_players(player_count, human_count, controllers_override)
	time_left = Tuning.ROUND_TIME
	countdown_left = Tuning.COUNTDOWN_TIME
	state = State.COUNTDOWN
	_started = true


func _physics_process(delta: float) -> void:
	if not _started:
		return
	match state:
		State.COUNTDOWN:
			countdown_left -= delta
			if countdown_left <= 0.0:
				state = State.PLAYING
		State.PLAYING:
			tick += 1
			time_left = maxf(time_left - delta, 0.0)
			for i in players.size():
				var p := players[i]
				if p.alive:
					p.sim_tick(controllers[i].get_player_input(p, self), delta)
			_check_round_end()
		State.OVER:
			pass


func alive_count() -> int:
	var n := 0
	for p in players:
		if p.alive:
			n += 1
	return n


func _spawn_players(player_count: int, human_count: int,
		controllers_override: Array[PlayerController]) -> void:
	for i in player_count:
		var p: SimPlayer = PLAYER_SCENE.instantiate()
		add_child(p)
		p.setup(i, CharacterStats.for_slot(i), MatchConfig.PLAYER_COLORS[i])
		var angle := TAU * float(i) / float(player_count)
		var out := Vector3(sin(angle), 0.0, cos(angle))
		p.global_position = out * arena_radius * Tuning.SPAWN_RADIUS_FRACTION + Vector3(0, 1.0, 0)
		p.facing = -out
		p.rotation.y = atan2(-p.facing.x, -p.facing.z)
		# Teleport: clear interpolation history so there is no first-frame streak.
		p.reset_physics_interpolation()
		players.append(p)
		if controllers_override.size() > i:
			controllers.append(controllers_override[i])
		else:
			controllers.append(_make_controller(i, human_count))


func _make_controller(slot: int, human_count: int) -> PlayerController:
	if slot >= human_count:
		return BotController.new()
	match slot:
		0: return HumanController.new(HumanController.Scheme.KEYBOARD_WASD)
		1: return HumanController.new(HumanController.Scheme.KEYBOARD_ARROWS)
		_: return HumanController.new(HumanController.Scheme.GAMEPAD, slot - 2)


## Radius scales with head count; shared with the client replica so both sides
## build identical arenas from the same player count.
static func radius_for_player_count(player_count: int) -> float:
	return Tuning.ARENA_RADIUS_SMALL \
		+ maxf(0.0, player_count - 4) * Tuning.ARENA_RADIUS_PER_EXTRA_PLAYER


## Also used by ClientReplica for the visual copy of the arena.
static func build_platform(radius: float) -> StaticBody3D:
	var platform := StaticBody3D.new()
	platform.name = "Platform"
	platform.collision_layer = 1
	platform.collision_mask = 0

	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = radius
	cyl.height = 2.0
	shape.shape = cyl
	shape.position = Vector3(0, -1.0, 0)
	platform.add_child(shape)

	var mesh_i := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius + 0.35 # slight bevel
	cm.height = 2.0
	cm.radial_segments = 48
	mesh_i.mesh = cm
	mesh_i.position = Vector3(0, -1.0, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.78, 0.88, 0.97)
	mat.roughness = 0.15
	mesh_i.material_override = mat
	platform.add_child(mesh_i)
	return platform


func _build_kill_zone() -> void:
	var kz := Area3D.new()
	kz.name = "KillZone"
	kz.collision_layer = 0
	kz.collision_mask = 2 # players only
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(arena_radius * 8.0, 2.0, arena_radius * 8.0)
	shape.shape = box
	kz.add_child(shape)
	kz.position = Vector3(0, Tuning.KILL_Y, 0)
	kz.body_entered.connect(_on_kill_zone_body_entered)
	add_child(kz)


func _on_kill_zone_body_entered(body: Node3D) -> void:
	if body is SimPlayer and body.alive:
		var at: Vector3 = body.global_position
		body.eliminate()
		print("[sim] t=%.1fs eliminated slot %d (%s), %d alive" % [
			Tuning.ROUND_TIME - time_left, body.slot,
			MatchConfig.COLOR_NAMES[body.slot], alive_count()])
		player_eliminated.emit(body.slot, at)


func _check_round_end() -> void:
	var last_alive: SimPlayer = null
	var n := 0
	for p in players:
		if p.alive:
			n += 1
			last_alive = p
	if n <= 1:
		winner_slot = last_alive.slot if n == 1 else -1
		_finish()
	elif time_left <= 0.0:
		winner_slot = -1 # TIE: 2+ players survived the clock
		_finish()


func _finish() -> void:
	state = State.OVER
	print("[sim] round over at t=%.1fs, winner slot %d" % [
		Tuning.ROUND_TIME - time_left, winner_slot])
	round_ended.emit(winner_slot)
