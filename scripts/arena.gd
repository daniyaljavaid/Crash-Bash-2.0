extends Node3D
## Presentation/orchestration for a round, in one of three modes:
##  OFFLINE — M1: local MatchSim with local humans + bots.
##  SERVER  — authoritative MatchSim; remote humans via NetworkControllers;
##            broadcasts snapshots + events. Host plays locally unless dedicated.
##  CLIENT  — no simulation: a ClientReplica renders server snapshots, local
##            input is sent to the server every tick.
## Contains zero gameplay rules in every mode.

var _view = null # MatchSim or ClientReplica — the HUD/camera read either
var _client_input_source: PlayerController = null

@onready var _sim: MatchSim = $MatchSim
@onready var _hud: Control = $UI/HUD
@onready var _camera_rig: Node3D = $CameraRig


func _ready() -> void:
	$Sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	match Net.mode:
		Net.Mode.OFFLINE:
			_sim.start_match(MatchConfig.player_count, MatchConfig.human_count)
			_view = _sim
		Net.Mode.SERVER:
			_sim.start_match(Net.slot_peers.size(), 0, _server_controllers())
			_view = _sim
		Net.Mode.CLIENT:
			var replica := ClientReplica.new()
			add_child(replica)
			replica.start(Net.slot_peers.size())
			_view = replica
			_client_input_source = _make_client_input_source()
	_camera_rig.setup(_view)
	_hud.bind_sim(_view)
	_view.player_eliminated.connect(_on_player_eliminated)
	_view.round_ended.connect(_on_round_ended)
	_hud.next_round_requested.connect(_on_next_round_requested)
	_hud.menu_requested.connect(_on_menu_requested)
	if Net.is_online():
		# Next round arrives as a fresh match-start (roster may change), which
		# reloads this scene via Net._apply_match_start.
		Net.session_ended.connect(func(_reason: String) -> void:
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	_maybe_schedule_screenshot()


func _physics_process(_delta: float) -> void:
	match Net.mode:
		Net.Mode.SERVER:
			if _sim.state != MatchSim.State.OVER:
				Net.broadcast_snapshot(_sim)
		Net.Mode.CLIENT:
			if _client_input_source != null and _view.state == MatchSim.State.PLAYING \
					and Net.my_slot >= 0 and Net.my_slot < _view.players.size():
				var pi: PlayerInput = _client_input_source.get_player_input(
					_view.players[Net.my_slot], _view)
				Net.send_input(pi.move, pi.charge)


## Server-side controller per slot: host keyboard for peer 1 (listen server),
## NetworkController for remote peers, bots for empty slots.
func _server_controllers() -> Array[PlayerController]:
	var controllers: Array[PlayerController] = []
	for slot in Net.slot_peers.size():
		var peer: int = Net.slot_peers[slot]
		if peer == 0:
			controllers.append(BotController.new())
		elif peer == 1:
			controllers.append(HumanController.new(HumanController.Scheme.KEYBOARD_WASD))
		else:
			controllers.append(NetworkController.new(peer))
	return controllers


## Clients read their own device; `-- autopilot` swaps in a bot driving off the
## replicated view instead — used for automated end-to-end network tests.
func _make_client_input_source() -> PlayerController:
	if "autopilot" in OS.get_cmdline_user_args():
		return BotController.new()
	return HumanController.new(HumanController.Scheme.KEYBOARD_WASD)


func _on_player_eliminated(_slot: int, at: Vector3) -> void:
	if Net.is_server():
		Net.broadcast_eliminated(_slot, at)
	_spawn_splash(Vector3(at.x, -2.3, at.z))


func _on_round_ended(winner_slot: int) -> void:
	if Net.mode == Net.Mode.CLIENT:
		return # wins arrive replicated with the round-over event
	MatchConfig.record_win(winner_slot)
	if Net.is_server():
		Net.broadcast_round_over(winner_slot, MatchConfig.wins)
		Net.round_finished_on_server(winner_slot)


func _on_next_round_requested() -> void:
	if Net.is_online():
		Net.request_next_round()
	else:
		get_tree().reload_current_scene()


func _on_menu_requested() -> void:
	if Net.is_online():
		Net.leave()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


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
