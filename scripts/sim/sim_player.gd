class_name SimPlayer
extends CharacterBody3D
## Simulation-layer player body. All authoritative state (velocity, stamina,
## charge, alive) lives here. Never reads input devices — MatchSim hands it a
## PlayerInput each tick. Visuals (mesh color, HUD) only READ this state.

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

var _prev_charge_held := false
var _hit_landed := false

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _nose: MeshInstance3D = $Nose


func setup(p_slot: int, p_stats: Dictionary, color: Color) -> void:
	slot = p_slot
	stats = p_stats
	collision_layer = 2
	collision_mask = 3 # platform (1) + other players (2)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	_mesh.material_override = mat
	var nose_mat := StandardMaterial3D.new()
	nose_mat.albedo_color = color.lightened(0.6)
	_nose.material_override = nose_mat


## One authoritative simulation step. dt is the fixed physics delta.
func sim_tick(input: PlayerInput, dt: float) -> void:
	if not alive:
		return

	stamina = minf(stamina + Tuning.STAMINA_REGEN * stats.regen_mult * dt, Tuning.STAMINA_MAX)
	recovery_left = maxf(recovery_left - dt, 0.0)
	stagger_left = maxf(stagger_left - dt, 0.0)

	var move3 := Vector3(input.move.x, 0.0, input.move.y)
	if stagger_left > 0.0:
		move3 = Vector3.ZERO # knocked silly: slide with no steering
	if move3.length_squared() > 1.0:
		move3 = move3.normalized()

	var charge_edge := input.charge and not _prev_charge_held
	_prev_charge_held = input.charge

	if charging:
		charge_time_left -= dt
		velocity.x = charge_dir.x * Tuning.CHARGE_SPEED
		velocity.z = charge_dir.z * Tuning.CHARGE_SPEED
		if charge_time_left <= 0.0:
			_end_charge(stats.momentum_keep) # whiffed: keep momentum (overshoot risk)
	else:
		if charge_edge and recovery_left <= 0.0 and stamina >= stats.stamina_cost:
			_start_charge(move3)
		else:
			velocity.x += move3.x * Tuning.MOVE_ACCEL * stats.accel_mult * dt
			velocity.z += move3.z * Tuning.MOVE_ACCEL * stats.accel_mult * dt
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

	move_and_slide()
	_resolve_contacts(dt)
	rotation.y = atan2(-facing.x, -facing.z)


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


func _resolve_contacts(dt: float) -> void:
	for i in get_slide_collision_count():
		var other := get_slide_collision(i).get_collider()
		if not (other is SimPlayer) or not other.alive:
			continue
		if charging and not _hit_landed:
			_hit_landed = true
			other.velocity.x += charge_dir.x * stats.push_power
			other.velocity.z += charge_dir.z * stats.push_power
			other.velocity.y += Tuning.HIT_POP
			other.stagger_left = Tuning.HIT_STAGGER
			_end_charge(0.0)
			velocity.x = -charge_dir.x * Tuning.CHARGE_RECOIL
			velocity.z = -charge_dir.z * Tuning.CHARGE_RECOIL
		elif not charging:
			var push: Vector3 = other.global_position - global_position
			push.y = 0.0
			if push.length_squared() < 0.0001:
				push = Vector3.FORWARD
			push = push.normalized()
			other.velocity += push * Tuning.GENTLE_PUSH_ACCEL * dt
