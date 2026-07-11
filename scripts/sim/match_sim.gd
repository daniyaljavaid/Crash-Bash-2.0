class_name MatchSim
extends Node3D
## Authoritative match simulation: arena geometry, player spawning, the round
## state machine, and the fixed-tick loop that feeds PlayerInputs into players.
## In M2 this node runs on the server; clients only render its synced state.

signal player_eliminated(slot: int, at: Vector3)
signal round_ended(winner_slot: int) # -1 = tie
signal block_destroyed(index: int, at: Vector3)          # ice-blocks variant
signal powerup_spawned(id: int, type: int, at: Vector3)  # power-ups variant
signal powerup_collected(id: int, type: int, slot: int)
signal player_hit(attacker_slot: int, victim_slot: int, at: Vector3)
signal player_respawned(slot: int, at: Vector3)                 # Tile Rush
signal ball_spawned(id: int, from: Vector3, dir: Vector3)       # Snow Brawl
signal ball_gone(id: int, at: Vector3)
signal goal_scored(slot: int, lives_left: int, at: Vector3)     # Puck Panic

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
var ice_ring: IceBlockRing = null
var power_ups: PowerUpManager = null
var tile_grid: TileGrid = null
var snowballs: SnowballManager = null
var pucks: PuckManager = null
var boulders: BoulderManager = null
var race: RaceManager = null
var minigame := MatchConfig.Minigame.SHOVE

var _started := false
var _initial_radius := Tuning.ARENA_RADIUS_SMALL
var _platform_shape: CylinderShape3D = null
var _platform_mesh: CylinderMesh = null


## controllers_override lets the network layer supply per-slot controllers
## (host input, remote peers, bots) without the sim knowing about networking.
## Empty = M1 behavior (local humans by scheme, bots for the rest).
func start_match(player_count: int, human_count: int,
		controllers_override: Array[PlayerController] = []) -> void:
	minigame = MatchConfig.minigame
	arena_radius = radius_for_player_count(player_count)
	_initial_radius = arena_radius
	var platform := build_platform(arena_radius)
	add_child(platform)
	_platform_shape = platform.get_meta("shape")
	_platform_mesh = platform.get_meta("mesh")
	_build_kill_zone()
	if MatchConfig.has_ice_blocks():
		ice_ring = IceBlockRing.new()
		add_child(ice_ring)
		ice_ring.build(arena_radius)
		ice_ring.block_destroyed.connect(
			func(index: int, at: Vector3) -> void: block_destroyed.emit(index, at))
	if MatchConfig.has_power_ups():
		power_ups = PowerUpManager.new()
		add_child(power_ups)
		power_ups.setup(self)
		power_ups.powerup_spawned.connect(
			func(id: int, type: int, at: Vector3) -> void: powerup_spawned.emit(id, type, at))
		power_ups.powerup_collected.connect(
			func(id: int, type: int, slot: int) -> void: powerup_collected.emit(id, type, slot))
	if minigame == MatchConfig.Minigame.TILE:
		tile_grid = TileGrid.new()
		add_child(tile_grid)
		tile_grid.build(arena_radius, player_count)
	elif minigame == MatchConfig.Minigame.SNOW:
		snowballs = SnowballManager.new()
		add_child(snowballs)
		snowballs.setup(self)
		snowballs.ball_spawned.connect(
			func(id: int, from: Vector3, dir: Vector3) -> void: ball_spawned.emit(id, from, dir))
		snowballs.ball_gone.connect(
			func(id: int, at: Vector3) -> void: ball_gone.emit(id, at))
		snowballs.ball_hit.connect(
			func(attacker: int, victim: int, at: Vector3) -> void: player_hit.emit(attacker, victim, at))
	_spawn_players(player_count, human_count, controllers_override)
	if minigame == MatchConfig.Minigame.BOULDER:
		boulders = BoulderManager.new()
		add_child(boulders)
		for p in players:
			p.throw_mode = true
		boulders.setup(self)
		boulders.hp_changed.connect(_on_goal_scored) # same lives-event plumbing
		boulders.thrown.connect(
			func(id: int, from: Vector3, dir: Vector3) -> void: ball_spawned.emit(id, from, dir))
	elif minigame == MatchConfig.Minigame.RACE:
		race = RaceManager.new()
		add_child(race)
		race.setup(self)
		race.lap_completed.connect(_on_goal_scored) # laps ride the lives channel
	if minigame == MatchConfig.Minigame.GOAL:
		pucks = PuckManager.new()
		add_child(pucks)
		pucks.setup(self)
		pucks.puck_spawned.connect(
			func(id: int, at: Vector3) -> void: ball_spawned.emit(id, at, Vector3.ZERO))
		pucks.puck_gone.connect(
			func(id: int, at: Vector3) -> void: ball_gone.emit(id, at))
		pucks.goal_scored.connect(_on_goal_scored)
	time_left = Tuning.ROUND_TIME
	countdown_left = Tuning.COUNTDOWN_TIME
	state = State.COUNTDOWN
	_started = true


## Shared "counter changed" plumbing: Puck Panic lives, Boulder Brawl hearts,
## and Floe Dash laps all ride this channel. Only a zero eliminates (laps
## count up, so races never trip it).
func _on_goal_scored(slot: int, lives_left: int, at: Vector3) -> void:
	goal_scored.emit(slot, lives_left, at)
	if lives_left <= 0 and players[slot].alive:
		players[slot].eliminate()
		print("[sim] t=%.1fs slot %d (%s) out of lives, %d alive" % [
			Tuning.ROUND_TIME - time_left, slot,
			MatchConfig.COLOR_NAMES[slot], alive_count()])
		player_eliminated.emit(slot, players[slot].global_position)


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
			if MatchConfig.has_melting():
				_melt_tick()
			if power_ups != null:
				power_ups.tick()
			if snowballs != null:
				snowballs.tick(delta)
			if pucks != null:
				pucks.tick(delta)
			if boulders != null:
				boulders.tick(delta)
			for i in players.size():
				var p := players[i]
				if p.alive:
					p.sim_tick(controllers[i].get_player_input(p, self), delta)
					if tile_grid != null and p.is_on_floor():
						tile_grid.claim_under(p)
			if race != null:
				race.tick()
			_check_round_end()
		State.OVER:
			pass


## Lives/hearts for the HUD; -1 in other modes (ClientReplica mirrors this).
func player_lives(slot: int) -> int:
	if pucks != null:
		return pucks.lives[slot]
	if boulders != null:
		return boulders.lives[slot]
	return -1


## Race progress in radians; -1.0 outside Floe Dash (ClientReplica mirrors).
func player_progress(slot: int) -> float:
	return race.progress[slot] if race != null else -1.0


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
		p.setup(i, MatchConfig.archetype_for_slot(i), MatchConfig.PLAYER_COLORS[i])
		p.landed_hit.connect(func(victim: SimPlayer) -> void:
			player_hit.emit(p.slot, victim.slot, victim.global_position))
		if minigame == MatchConfig.Minigame.SNOW:
			p.throw_mode = true
			p.throw_requested.connect(func(dir: Vector3) -> void:
				snowballs.throw_ball(p, dir))
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


## Melting variant: the platform shrinks linearly after a grace period.
## Collision and mesh follow arena_radius, so bots (which read arena_radius
## live) adapt automatically and players beyond the new edge just fall.
func _melt_tick() -> void:
	var elapsed := Tuning.ROUND_TIME - time_left
	var melt_t := clampf((elapsed - Tuning.MELT_START_DELAY) / Tuning.MELT_DURATION, 0.0, 1.0)
	var target := _initial_radius * lerpf(1.0, Tuning.MELT_MIN_FRACTION, melt_t)
	if absf(target - arena_radius) < 0.001:
		return
	arena_radius = target
	resize_platform(_platform_shape, _platform_mesh, arena_radius)
	if ice_ring != null:
		ice_ring.melt_check(arena_radius)


## Shared with ClientReplica (which resizes from snapshot data).
static func resize_platform(shape: CylinderShape3D, mesh: CylinderMesh, radius: float) -> void:
	shape.radius = radius
	mesh.top_radius = radius
	mesh.bottom_radius = radius + 0.35


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
	platform.set_meta("shape", cyl)
	platform.set_meta("mesh", cm)
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
	if not (body is SimPlayer) or not body.alive:
		return
	var at: Vector3 = body.global_position
	if minigame == MatchConfig.Minigame.TILE or minigame == MatchConfig.Minigame.RACE:
		# Tile Rush / Floe Dash: falling costs time, not the round.
		_respawn(body, at)
		return
	body.eliminate()
	print("[sim] t=%.1fs eliminated slot %d (%s), %d alive" % [
		Tuning.ROUND_TIME - time_left, body.slot,
		MatchConfig.COLOR_NAMES[body.slot], alive_count()])
	player_eliminated.emit(body.slot, at)


func _respawn(p: SimPlayer, fell_at: Vector3) -> void:
	p.velocity = Vector3.ZERO
	p.stagger_left = 0.0
	if race != null:
		# Back onto the lane where they fell — no free progress either way.
		p.global_position = race.respawn_position(fell_at)
	else:
		var angle := TAU * float(p.slot) / float(players.size())
		var out := Vector3(sin(angle), 0.0, cos(angle))
		p.global_position = out * arena_radius * Tuning.SPAWN_RADIUS_FRACTION + Vector3(0, 1.0, 0)
	p.reset_physics_interpolation()
	player_respawned.emit(p.slot, fell_at)


func _check_round_end() -> void:
	if minigame == MatchConfig.Minigame.TILE:
		# No eliminations: the clock decides, most tiles wins.
		if time_left <= 0.0:
			winner_slot = tile_grid.leader()
			_finish()
		return
	if minigame == MatchConfig.Minigame.RACE:
		var done := race.finished_slot()
		if done >= 0:
			winner_slot = done
			_finish()
		elif time_left <= 0.0:
			winner_slot = race.leader()
			_finish()
		return
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
		# Lives-based modes resolve the clock by remaining lives; sumo ties.
		if pucks != null:
			winner_slot = pucks.leader()
		elif boulders != null:
			winner_slot = boulders.leader()
		else:
			winner_slot = -1
		_finish()


func _finish() -> void:
	state = State.OVER
	print("[sim] round over at t=%.1fs, winner slot %d" % [
		Tuning.ROUND_TIME - time_left, winner_slot])
	round_ended.emit(winner_slot)
