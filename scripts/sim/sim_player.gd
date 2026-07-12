class_name SimPlayer
extends CharacterBody3D
## Simulation-layer player body. All authoritative state (velocity, stamina,
## charge, alive) lives here. Never reads input devices — MatchSim hands it a
## PlayerInput each tick. Visuals (mesh color, HUD) only READ this state.

signal landed_hit(victim: SimPlayer) # charge connected; presentation juice hook
signal throw_requested(dir: Vector3) # Snow Brawl: charge button throws instead

var throw_mode := false # Snow Brawl/Boulder Brawl: charge input becomes a throw
var carry_slow := false # Boulder Brawl: hauling a boulder slows you
var team := -1          # -1 = free-for-all; teammates can't hurt each other
var slot := 0
var stats := {}          # one entry of CharacterStats.ARCHETYPES
var stamina := Tuning.STAMINA_MAX
var alive := true
var charging := false
var charge_time_left := 0.0
var recovery_left := 0.0
var charge_dir := Vector3.FORWARD
var facing := Vector3.FORWARD
var stagger_left := 0.0 # can't steer while > 0 (just got charged into)

# Power-up state (all sim-authoritative; visuals mirror via snapshots)
var power_mult := 1.0       # outgoing charge impulse multiplier
var knockback_mult := 1.0   # incoming impulse multiplier
var visual_scale := 1.0     # mesh-only scale; collision stays constant
var frozen_left := 0.0
var effect_left := 0.0      # remaining grow/shrink time

var _prev_charge_held := false
var _hit_landed := false
var _base_color := Color.WHITE
var _was_frozen := false
var _anim_t := 0.0
var _last_pos := Vector3.ZERO
var _correction := Vector3.ZERO # prediction reconcile offset, decays visually
var _archetype_scale := Vector3.ONE

@onready var _visual: Node3D = $Visual
@onready var _body: MeshInstance3D = $Visual/Body


func setup(p_slot: int, p_stats: Dictionary, color: Color) -> void:
	slot = p_slot
	stats = p_stats
	collision_layer = 2
	collision_mask = 3 # platform (1) + other players (2)
	_base_color = color
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = color
	_body.material_override = body_mat
	$Visual/FlipperL.material_override = _flat(color.darkened(0.25))
	$Visual/FlipperR.material_override = _flat(color.darkened(0.25))
	var white := _flat(Color(0.95, 0.96, 1.0))
	$Visual/Belly.material_override = white
	var eye := _flat(Color(0.08, 0.08, 0.1))
	$Visual/EyeL.material_override = eye
	$Visual/EyeR.material_override = eye
	var orange := _flat(Color(0.95, 0.6, 0.15))
	$Visual/Beak.material_override = orange
	$Visual/FootL.material_override = orange
	$Visual/FootR.material_override = orange
	_apply_archetype_look()


## Silhouette + hat per archetype so builds read at a glance without models:
## Heavy is broad with a dark headband, Bruiser has an angry brow, Trickster
## is slim with an antenna bobble, Balanced stays clean.
func _apply_archetype_look() -> void:
	match stats.get("name", ""):
		"Heavy":
			_archetype_scale = Vector3(1.18, 0.95, 1.18)
			var band := MeshInstance3D.new()
			var torus := TorusMesh.new()
			torus.inner_radius = 0.34
			torus.outer_radius = 0.46
			band.mesh = torus
			band.material_override = _flat(Color(0.15, 0.15, 0.2))
			band.scale = Vector3(1, 0.5, 1)
			band.position = Vector3(0, 0.32, 0)
			_visual.add_child(band)
		"Bruiser":
			_archetype_scale = Vector3(1.08, 1.0, 1.08)
			for side in [-1.0, 1.0]:
				var brow := MeshInstance3D.new()
				var mesh := BoxMesh.new()
				mesh.size = Vector3(0.16, 0.05, 0.06)
				brow.mesh = mesh
				brow.material_override = _flat(Color(0.1, 0.1, 0.12))
				brow.position = Vector3(side * 0.16, 0.32, -0.36)
				brow.rotation.z = -side * 0.35 # angled: permanently unimpressed
				_visual.add_child(brow)
		"Trickster":
			_archetype_scale = Vector3(0.88, 1.08, 0.88)
			var stem := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.02
			cyl.bottom_radius = 0.02
			cyl.height = 0.3
			stem.mesh = cyl
			stem.material_override = _flat(Color(0.2, 0.2, 0.25))
			stem.position = Vector3(0, 0.6, 0)
			_visual.add_child(stem)
			var bobble := MeshInstance3D.new()
			var s := SphereMesh.new()
			s.radius = 0.07
			s.height = 0.14
			bobble.mesh = s
			bobble.material_override = _flat(_base_color.lightened(0.4))
			bobble.position = Vector3(0, 0.78, 0)
			_visual.add_child(bobble)
	_visual.scale = _archetype_scale


static func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


## Presentation only: waddle by measured movement (works for both the sim body
## and client puppets, which are moved externally), lean into charges.
func _process(delta: float) -> void:
	if not alive:
		return
	var speed := Vector2(global_position.x - _last_pos.x,
		global_position.z - _last_pos.z).length() / maxf(delta, 0.0001)
	_last_pos = global_position
	_anim_t += delta * clampf(speed, 0.0, 8.0) * 1.7
	var waddle := sin(_anim_t) * clampf(speed / 8.0, 0.0, 1.0) * 0.18
	_visual.rotation.z = waddle
	_visual.rotation.x = -0.4 if charging else 0.0
	if _correction.length_squared() > 0.00001:
		_correction *= exp(-10.0 * delta)
		_visual.position = _correction
	elif _visual.position != Vector3.ZERO:
		_visual.position = Vector3.ZERO


## Prediction reconcile: shift the visual by the correction and let it decay,
## so authoritative snaps read as a fast glide instead of a teleport.
func add_correction_offset(err: Vector3) -> void:
	_correction = (_correction + err).limit_length(2.5)


## One authoritative simulation step. dt is the fixed physics delta.
func sim_tick(input: PlayerInput, dt: float) -> void:
	if not alive:
		return

	stamina = minf(stamina + Tuning.STAMINA_REGEN * stats.regen_mult * dt, Tuning.STAMINA_MAX)
	recovery_left = maxf(recovery_left - dt, 0.0)
	stagger_left = maxf(stagger_left - dt, 0.0)
	frozen_left = maxf(frozen_left - dt, 0.0)
	if effect_left > 0.0:
		effect_left -= dt
		if effect_left <= 0.0:
			_clear_size_effect()

	var move3 := Vector3(input.move.x, 0.0, input.move.y)
	if stagger_left > 0.0 or frozen_left > 0.0:
		move3 = Vector3.ZERO # knocked silly / frozen solid: no steering
	if move3.length_squared() > 1.0:
		move3 = move3.normalized()

	var charge_edge := input.charge and not _prev_charge_held and frozen_left <= 0.0
	_prev_charge_held = input.charge

	if charging:
		charge_time_left -= dt
		velocity.x = charge_dir.x * Tuning.CHARGE_SPEED
		velocity.z = charge_dir.z * Tuning.CHARGE_SPEED
		if charge_time_left <= 0.0:
			_end_charge(stats.momentum_keep) # whiffed: keep momentum (overshoot risk)
	else:
		if charge_edge and recovery_left <= 0.0 and stamina >= stats.stamina_cost:
			if throw_mode:
				_throw(move3)
			else:
				_start_charge(move3)
		else:
			var accel: float = Tuning.MOVE_ACCEL * stats.accel_mult * (0.75 if carry_slow else 1.0)
			velocity.x += move3.x * accel * dt
			velocity.z += move3.z * accel * dt
			var damp := exp(-Tuning.FRICTION_K * dt)
			velocity.x *= damp
			velocity.z *= damp
		if move3.length_squared() > 0.01:
			var t := 1.0 - exp(-Tuning.TURN_SPEED * dt)
			facing = facing.slerp(move3.normalized(), t).normalized()

	if is_on_floor():
		velocity.y = 0.0
	else:
		velocity.y -= Tuning.GRAVITY * dt

	var pre_move_speed := Vector2(velocity.x, velocity.z).length()
	move_and_slide()
	_resolve_contacts(dt, pre_move_speed)
	rotation.y = atan2(-facing.x, -facing.z)

	var frozen := frozen_left > 0.0
	if frozen != _was_frozen:
		_was_frozen = frozen
		set_frozen_visual(frozen)


func is_teammate(other: SimPlayer) -> bool:
	return team >= 0 and other.team == team


## Flat ring under the penguin marking its team (gold = A, silver = B).
## Used by both the sim body and puppets.
func set_team(p_team: int) -> void:
	team = p_team
	if team < 0:
		return
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.5
	torus.outer_radius = 0.62
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.25) if team == 0 else Color(0.8, 0.85, 0.95)
	mat.emission_enabled = true
	mat.emission = mat.albedo_color * 0.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = mat
	ring.mesh = torus
	ring.scale = Vector3(1, 0.06, 1)
	ring.position = Vector3(0, -0.76, 0)
	add_child(ring)


func apply_grow() -> void:
	power_mult = Tuning.GROW_POWER
	knockback_mult = Tuning.GROW_KNOCKBACK_RESIST
	visual_scale = Tuning.GROW_SCALE
	effect_left = Tuning.POWERUP_EFFECT_TIME
	set_visual_scale(visual_scale)


func apply_shrink() -> void:
	power_mult = Tuning.SHRINK_POWER
	knockback_mult = Tuning.SHRINK_KNOCKBACK
	visual_scale = Tuning.SHRINK_SCALE
	effect_left = Tuning.POWERUP_EFFECT_TIME
	set_visual_scale(visual_scale)


func _clear_size_effect() -> void:
	power_mult = 1.0
	knockback_mult = 1.0
	visual_scale = 1.0
	set_visual_scale(1.0)


## Mesh-only scale (collision shape stays constant — the size effect is a stat
## change with a visual tell, not a hitbox change). Also used by puppets.
## Composes with the archetype silhouette scale.
func set_visual_scale(s: float) -> void:
	_visual.scale = _archetype_scale * s


## Ice tint while frozen. Also used by puppets (driven from snapshot flags).
func set_frozen_visual(frozen: bool) -> void:
	var mat := _body.material_override as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = _base_color.lerp(Color(0.6, 0.85, 1.0), 0.7) if frozen \
		else _base_color


## Client-side visual stand-in: no physics, no collisions; the ClientReplica
## writes interpolated transforms and replicated stats straight into it.
func make_puppet() -> void:
	collision_layer = 0
	collision_mask = 0
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF


func eliminate() -> void:
	alive = false
	velocity = Vector3.ZERO
	visible = false
	# Deferred: elimination is triggered from an Area3D signal during physics flush.
	set_deferred("collision_layer", 0)
	set_deferred("collision_mask", 0)


## Snow Brawl: spend stamina, aim like a charge, let the sim spawn the ball.
func _throw(move3: Vector3) -> void:
	stamina -= stats.stamina_cost
	recovery_left = stats.recovery + 0.3
	var dir := move3.normalized() if move3.length_squared() > 0.01 else facing
	facing = dir
	throw_requested.emit(dir)


## Charge aims along the current move intent (responsive: you charge where you
## push the stick), falling back to facing when standing still.
func _start_charge(move3: Vector3) -> void:
	stamina -= stats.stamina_cost
	charging = true
	_hit_landed = false
	charge_time_left = Tuning.CHARGE_DURATION
	charge_dir = move3.normalized() if move3.length_squared() > 0.01 else facing
	facing = charge_dir


func _end_charge(momentum_keep: float) -> void:
	charging = false
	recovery_left = stats.recovery
	velocity.x = charge_dir.x * Tuning.CHARGE_SPEED * momentum_keep
	velocity.z = charge_dir.z * Tuning.CHARGE_SPEED * momentum_keep


func _resolve_contacts(dt: float, pre_move_speed: float) -> void:
	for i in get_slide_collision_count():
		var other := get_slide_collision(i).get_collider()
		if other is StaticBody3D and other.has_meta("ice_block_index"):
			if charging and not _hit_landed:
				# Smashing a block spends the charge: brake hard, no recoil.
				other.get_meta("ice_block_ring").smash(other.get_meta("ice_block_index"))
				_hit_landed = true
				_end_charge(0.0)
				velocity.x = charge_dir.x * Tuning.CHARGE_SPEED * Tuning.BLOCK_SMASH_BRAKE
				velocity.z = charge_dir.z * Tuning.CHARGE_SPEED * Tuning.BLOCK_SMASH_BRAKE
			elif pre_move_speed > Tuning.BLOCK_BREAK_SPEED:
				# Slammed into the wall hard (knockback victim): crash through.
				# Judged on pre-move speed — move_and_slide has already bled
				# the velocity along the wall by the time we get here. Carry
				# the remaining momentum through the opening (along the inverse
				# collision normal), not along the deflected slide direction.
				other.get_meta("ice_block_ring").smash(other.get_meta("ice_block_index"))
				var through := -get_slide_collision(i).get_normal()
				through.y = 0.0
				through = through.normalized()
				velocity.x = through.x * pre_move_speed * Tuning.BLOCK_ABSORB
				velocity.z = through.z * pre_move_speed * Tuning.BLOCK_ABSORB
			continue
		if not (other is SimPlayer) or not other.alive:
			continue
		if charging and not _hit_landed and not is_teammate(other):
			_hit_landed = true
			var impulse: float = stats.push_power * power_mult * other.knockback_mult
			other.velocity.x += charge_dir.x * impulse
			other.velocity.z += charge_dir.z * impulse
			other.velocity.y += Tuning.HIT_POP
			other.stagger_left = Tuning.HIT_STAGGER
			_end_charge(0.0)
			velocity.x = -charge_dir.x * Tuning.CHARGE_RECOIL
			velocity.z = -charge_dir.z * Tuning.CHARGE_RECOIL
			landed_hit.emit(other)
		elif not charging:
			var push: Vector3 = other.global_position - global_position
			push.y = 0.0
			if push.length_squared() < 0.0001:
				push = Vector3.FORWARD
			push = push.normalized()
			other.velocity += push * Tuning.GENTLE_PUSH_ACCEL * dt
