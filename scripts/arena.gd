extends Node3D
## Presentation/orchestration for a round. Starts the sim, wires HUD + camera,
## spawns splash effects. Contains zero gameplay rules.

@onready var _sim: MatchSim = $MatchSim
@onready var _hud: Control = $UI/HUD
@onready var _camera_rig: Node3D = $CameraRig


func _ready() -> void:
	$Sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	_sim.start_match(MatchConfig.player_count, MatchConfig.human_count)
	_camera_rig.setup(_sim)
	_hud.bind_sim(_sim)
	_sim.player_eliminated.connect(_on_player_eliminated)
	_sim.round_ended.connect(_on_round_ended)
	_hud.next_round_requested.connect(func() -> void: get_tree().reload_current_scene())
	_hud.menu_requested.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	_maybe_schedule_screenshot()


# Dev tool: `godot --path . res://scenes/arena.tscn -- screenshot=/tmp/shot.png`
# saves a viewport capture ~8 s into the round and quits.
func _maybe_schedule_screenshot() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("screenshot="):
			var path := arg.get_slice("=", 1)
			await get_tree().create_timer(8.0).timeout
			get_viewport().get_texture().get_image().save_png(path)
			print("[debug] screenshot saved to ", path)
			get_tree().quit()


func _on_player_eliminated(_slot: int, at: Vector3) -> void:
	_spawn_splash(Vector3(at.x, -2.3, at.z))


func _on_round_ended(winner_slot: int) -> void:
	MatchConfig.record_win(winner_slot)


func _spawn_splash(at: Vector3) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 1.0
	p.amount = 30
	p.lifetime = 0.8
	p.direction = Vector3.UP
	p.spread = 55.0
	p.initial_velocity_min = 4.0
	p.initial_velocity_max = 8.0
	p.gravity = Vector3(0, -20, 0)
	var mesh := SphereMesh.new()
	mesh.radius = 0.08
	mesh.height = 0.16
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.75, 0.95)
	mesh.material = mat
	p.mesh = mesh
	p.position = at
	add_child(p)
	p.emitting = true
	get_tree().create_timer(2.0).timeout.connect(p.queue_free)
