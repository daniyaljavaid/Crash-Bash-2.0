extends Control
## Pre-round setup: local match config, online host/join, and the dedicated
## server bootstrap (`--headless --server`, options after `--`).

@onready var _players_spin: SpinBox = $Center/VBox/PlayersRow/PlayersSpin
@onready var _humans_spin: SpinBox = $Center/VBox/HumansRow/HumansSpin
@onready var _game_opt: OptionButton = $Center/VBox/GameRow/GameOption
@onready var _stage_opt: OptionButton = $Center/VBox/GameRow/StageOption
@onready var _variant_opt: OptionButton = $Center/VBox/VariantRow/VariantOption
@onready var _difficulty_opt: OptionButton = $Center/VBox/DifficultyRow/DifficultyOption
@onready var _teams_opt: OptionButton = $Center/VBox/DifficultyRow/TeamsOption
@onready var _target_spin: SpinBox = $Center/VBox/TargetRow/TargetSpin
@onready var _char_rows: VBoxContainer = $Center/VBox/CharRows

var _char_opts: Array[OptionButton] = []
var _look_opts: Array[OptionButton] = []
@onready var _name_edit: LineEdit = $Center/VBox/NetRow/NameEdit
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
	for name in MatchConfig.MINIGAME_NAMES:
		_game_opt.add_item(name)
	_game_opt.selected = MatchConfig.minigame
	_game_opt.item_selected.connect(func(_i: int) -> void: _rebuild_stage_options())
	_rebuild_stage_options()
	for name in MatchConfig.VARIANT_NAMES:
		_variant_opt.add_item(name)
	_variant_opt.selected = MatchConfig.variant
	for name in MatchConfig.DIFFICULTY_NAMES:
		_difficulty_opt.add_item(name)
	_difficulty_opt.selected = MatchConfig.difficulty
	for name in MatchConfig.TEAM_MODE_NAMES:
		_teams_opt.add_item(name)
	_teams_opt.selected = MatchConfig.team_mode
	_target_spin.value = MatchConfig.wins_target
	_humans_spin.value_changed.connect(func(_v: float) -> void: _rebuild_char_rows())
	_rebuild_char_rows()
	_name_edit.text = MatchConfig.player_name_local
	_ip_edit.text = MatchConfig.last_ip
	_port_edit.text = str(MatchConfig.last_port)
	SoundBank.play_music("menu")
	if OS.has_feature("web"):
		# Browsers can join but never host (no listening sockets).
		$Center/VBox/NetButtons/HostButton.visible = false
	$Center/VBox/StartButton.grab_focus()


## Stage list depends on the selected minigame.
func _rebuild_stage_options() -> void:
	_stage_opt.clear()
	for i in Stages.count(_game_opt.selected):
		_stage_opt.add_item(Stages.stage_name(_game_opt.selected, i))
	_stage_opt.selected = 0


## One character dropdown per local human (Auto + the four archetypes).
func _rebuild_char_rows() -> void:
	for child in _char_rows.get_children():
		child.queue_free()
	_char_opts = []
	_look_opts = []
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
		var look := OptionButton.new()
		for name in MatchConfig.LOOK_NAMES:
			look.add_item(name)
		row.add_child(label)
		row.add_child(opt)
		row.add_child(look)
		_char_rows.add_child(row)
		_char_opts.append(opt)
		_look_opts.append(look)


func _save_name() -> void:
	MatchConfig.player_name_local = _name_edit.text.strip_edges().left(16)
	MatchConfig.save_settings()


func _on_start_local() -> void:
	_save_name()
	MatchConfig.slot_names = []
	var choices: Array[int] = []
	for opt in _char_opts:
		choices.append(opt.selected - 1) # item 0 = Auto = -1
	var looks: Array[int] = []
	for opt in _look_opts:
		looks.append(opt.selected)
	MatchConfig.start_new_match(int(_players_spin.value), int(_humans_spin.value),
		_variant_opt.selected as MatchConfig.Variant, int(_target_spin.value), choices,
		_difficulty_opt.selected as MatchConfig.Difficulty,
		_game_opt.selected as MatchConfig.Minigame, _stage_opt.selected,
		_teams_opt.selected as MatchConfig.TeamMode, looks)
	get_tree().change_scene_to_file("res://scenes/arena.tscn")


func _on_host() -> void:
	_save_name()
	var err := Net.host(_port())
	if err != OK:
		_error_label.text = "Could not host on port %d (in use?)" % _port()
		return
	MatchConfig.last_port = _port()
	MatchConfig.save_settings()
	MatchConfig.wins = []
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func _on_join() -> void:
	_save_name()
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
	var use_ws := false
	for arg in OS.get_cmdline_user_args():
		if arg == "ws=1":
			use_ws = true # WebSocket transport: required for browser players
	var err := Net.host(port, true, use_ws)
	if err != OK:
		printerr("[server] failed to bind port %d" % port)
		get_tree().quit(1)
		return true
	Net.lobby_player_count = MatchConfig.player_count # honors `players=` user arg
	Net.lobby_fill_bots = fill_bots
	Net.lobby_variant = MatchConfig.variant # honors `variant=` user arg
	Net.lobby_difficulty = MatchConfig.difficulty # honors `difficulty=` user arg
	Net.lobby_minigame = MatchConfig.minigame # honors `game=` user arg
	Net.lobby_stage = clampi(MatchConfig.stage, 0, Stages.count(MatchConfig.minigame) - 1)
	Net.lobby_team_mode = MatchConfig.team_mode # honors `teams=` user arg
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
			var ip := addr
			var port := Net.DEFAULT_PORT
			# ws:// URLs pass through whole; host:port pairs are split.
			if not addr.begins_with("ws"):
				ip = addr.get_slice(":", 0)
				if ":" in addr:
					port = addr.get_slice(":", 1).to_int()
			var err := Net.join(ip, port)
			if err != OK:
				printerr("[client] failed to join %s" % addr)
				get_tree().quit(1)
				return true
			print("[client] joining %s:%d" % [ip, port])
			get_tree().change_scene_to_file.call_deferred("res://scenes/lobby.tscn")
			return true
	return false
