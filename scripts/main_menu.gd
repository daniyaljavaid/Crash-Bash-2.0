extends Control
## Pre-round setup: local match config, online host/join, and the dedicated
## server bootstrap (`--headless --server`, options after `--`).

@onready var _players_spin: SpinBox = $Center/VBox/PlayersRow/PlayersSpin
@onready var _humans_spin: SpinBox = $Center/VBox/HumansRow/HumansSpin
@onready var _variant_opt: OptionButton = $Center/VBox/VariantRow/VariantOption
@onready var _difficulty_opt: OptionButton = $Center/VBox/DifficultyRow/DifficultyOption
@onready var _target_spin: SpinBox = $Center/VBox/TargetRow/TargetSpin
@onready var _char_rows: VBoxContainer = $Center/VBox/CharRows

var _char_opts: Array[OptionButton] = []
@onready var _ip_edit: LineEdit = $Center/VBox/NetRow/IpEdit
@onready var _port_edit: LineEdit = $Center/VBox/NetRow/PortEdit
@onready var _error_label: Label = $Center/VBox/ErrorLabel


func _ready() -> void:
	if _bootstrap_dedicated_server():
		return
	if _bootstrap_auto_join():
		return
	$Center/VBox/StartButton.pressed.connect(_on_start_local)
	$Center/VBox/NetButtons/HostButton.pressed.connect(_on_host)
	$Center/VBox/NetButtons/JoinButton.pressed.connect(_on_join)
	$Center/VBox/QuitButton.pressed.connect(func() -> void: get_tree().quit())
	for name in MatchConfig.VARIANT_NAMES:
		_variant_opt.add_item(name)
	_variant_opt.selected = MatchConfig.variant
	for name in MatchConfig.DIFFICULTY_NAMES:
		_difficulty_opt.add_item(name)
	_difficulty_opt.selected = MatchConfig.difficulty
	_target_spin.value = MatchConfig.wins_target
	_humans_spin.value_changed.connect(func(_v: float) -> void: _rebuild_char_rows())
	_rebuild_char_rows()
	_ip_edit.text = MatchConfig.last_ip
	_port_edit.text = str(MatchConfig.last_port)
	$Center/VBox/StartButton.grab_focus()


## One character dropdown per local human (Auto + the four archetypes).
func _rebuild_char_rows() -> void:
	for child in _char_rows.get_children():
		child.queue_free()
	_char_opts = []
	for i in int(_humans_spin.value):
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 12)
		var label := Label.new()
		label.text = "P%d character" % (i + 1)
		var opt := OptionButton.new()
		opt.add_item("Auto")
		for arch in CharacterStats.ARCHETYPES:
			opt.add_item(arch["name"])
		row.add_child(label)
		row.add_child(opt)
		_char_rows.add_child(row)
		_char_opts.append(opt)


func _on_start_local() -> void:
	var choices: Array[int] = []
	for opt in _char_opts:
		choices.append(opt.selected - 1) # item 0 = Auto = -1
	MatchConfig.start_new_match(int(_players_spin.value), int(_humans_spin.value),
		_variant_opt.selected as MatchConfig.Variant, int(_target_spin.value), choices,
		_difficulty_opt.selected as MatchConfig.Difficulty)
	get_tree().change_scene_to_file("res://scenes/arena.tscn")


func _on_host() -> void:
	var err := Net.host(_port())
	if err != OK:
		_error_label.text = "Could not host on port %d (in use?)" % _port()
		return
	MatchConfig.last_port = _port()
	MatchConfig.save_settings()
	MatchConfig.wins = []
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _on_join() -> void:
	var ip := _ip_edit.text.strip_edges()
	if ip.is_empty():
		ip = "127.0.0.1"
	var err := Net.join(ip, _port())
	if err != OK:
		_error_label.text = "Invalid address: %s" % ip
		return
	MatchConfig.last_ip = ip
	MatchConfig.last_port = _port()
	MatchConfig.save_settings()
	MatchConfig.wins = []
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _port() -> int:
	var p := _port_edit.text.strip_edges().to_int()
	return p if p > 0 else Net.DEFAULT_PORT


## `godot --headless --path . --server -- port=9050 players=8 bots=1 autostart=2`
## Hosts a dedicated lobby and (optionally) auto-starts once N humans joined.
func _bootstrap_dedicated_server() -> bool:
	if not ("--server" in OS.get_cmdline_args() or "server" in OS.get_cmdline_user_args()):
		return false
	var port := Net.DEFAULT_PORT
	var fill_bots := true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("port="):
			port = arg.get_slice("=", 1).to_int()
		elif arg.begins_with("bots="):
			fill_bots = arg.get_slice("=", 1).to_int() != 0
		elif arg.begins_with("autostart="):
			Net.autostart_humans = arg.get_slice("=", 1).to_int()
		elif arg.begins_with("autonext="):
			Net.autonext_seconds = arg.get_slice("=", 1).to_int()
		elif arg.begins_with("target="):
			Net.lobby_wins_target = clampi(arg.get_slice("=", 1).to_int(), 1, 5)
	var err := Net.host(port, true)
	if err != OK:
		printerr("[server] failed to bind port %d" % port)
		get_tree().quit(1)
		return true
	Net.lobby_player_count = MatchConfig.player_count # honors `players=` user arg
	Net.lobby_fill_bots = fill_bots
	Net.lobby_variant = MatchConfig.variant # honors `variant=` user arg
	Net.lobby_difficulty = MatchConfig.difficulty # honors `difficulty=` user arg
	print("[server] dedicated server listening on port %d (players=%d bots=%s autostart=%d variant=%d)" % [
		port, Net.lobby_player_count, fill_bots, Net.autostart_humans, Net.lobby_variant])
	get_tree().change_scene_to_file.call_deferred("res://scenes/lobby.tscn")
	return true


## `godot --path . -- join=127.0.0.1:9050 [autopilot]` — skip the menu and
## connect straight to a server. `-- host=9050 autostart=2` hosts a listen
## server the same way. Used by automated network tests and scripting.
func _bootstrap_auto_join() -> bool:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("host="):
			var host_port := arg.get_slice("=", 1).to_int()
			if Net.host(host_port if host_port > 0 else Net.DEFAULT_PORT) != OK:
				printerr("[host] failed to bind port %d" % host_port)
				get_tree().quit(1)
				return true
			for a2 in OS.get_cmdline_user_args():
				if a2.begins_with("autostart="):
					Net.autostart_humans = a2.get_slice("=", 1).to_int()
			Net.lobby_player_count = MatchConfig.player_count
			Net.lobby_variant = MatchConfig.variant
			print("[host] listen server on port %d" % host_port)
			get_tree().change_scene_to_file.call_deferred("res://scenes/lobby.tscn")
			return true
		if arg.begins_with("join="):
			var addr := arg.get_slice("=", 1)
			var ip := addr.get_slice(":", 0)
			var port := addr.get_slice(":", 1).to_int() if ":" in addr else Net.DEFAULT_PORT
			var err := Net.join(ip, port)
			if err != OK:
				printerr("[client] failed to join %s" % addr)
				get_tree().quit(1)
				return true
			print("[client] joining %s:%d" % [ip, port])
			get_tree().change_scene_to_file.call_deferred("res://scenes/lobby.tscn")
			return true
	return false
