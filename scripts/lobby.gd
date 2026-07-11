extends Control
## Pre-match staging area for online play. The lobby leader (host on a listen
## server, first-joined client on a dedicated one) picks the match size and
## starts the round; everyone else watches the roster fill up.

@onready var _status: Label = $Center/VBox/StatusLabel
@onready var _player_list: VBoxContainer = $Center/VBox/PlayerList
@onready var _players_spin: SpinBox = $Center/VBox/PlayersRow/PlayersSpin
@onready var _bots_check: CheckButton = $Center/VBox/BotsCheck
@onready var _start_btn: Button = $Center/VBox/StartButton


func _ready() -> void:
	Net.lobby_updated.connect(_refresh)
	Net.session_ended.connect(_on_session_ended)
	_players_spin.value_changed.connect(func(_v: float) -> void: _push_config())
	_bots_check.toggled.connect(func(_on: bool) -> void: _push_config())
	_start_btn.pressed.connect(func() -> void: Net.request_start())
	$Center/VBox/LeaveButton.pressed.connect(_on_leave)
	_players_spin.value = Net.lobby_player_count
	_bots_check.button_pressed = Net.lobby_fill_bots
	_refresh()


func _push_config() -> void:
	# Only the server owns lobby config; on a dedicated server it comes from
	# the command line instead (client leader can't edit it — M2 limitation).
	if Net.is_server():
		Net.set_lobby_config(int(_players_spin.value), _bots_check.button_pressed)


func _refresh() -> void:
	var me := multiplayer.get_unique_id()
	if Net.waiting_peer_ids.has(me):
		_status.text = "Match in progress — you will join the next round"
	elif Net.is_server():
		_status.text = "Hosting on port %d — %d player(s) connected" \
			% [Net.current_port, Net.humans_connected()]
	elif Net.lobby_peer_ids.is_empty() and Net.waiting_peer_ids.is_empty():
		_status.text = "Connecting..."
	else:
		_status.text = "Connected (%d players in lobby)" % Net.humans_connected()

	for child in _player_list.get_children():
		child.queue_free()
	for i in Net.lobby_peer_ids.size():
		var peer: int = Net.lobby_peer_ids[i]
		var row := Label.new()
		var name_text := "Host" if peer == 1 else "Player (peer %d)" % peer
		if peer == me:
			name_text += "  — you"
		if peer == Net.leader_peer():
			name_text += "  [leader]"
		row.text = "%d. %s" % [i + 1, name_text]
		row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_player_list.add_child(row)
	for peer in Net.waiting_peer_ids:
		var row := Label.new()
		row.text = "Player (peer %d) — waiting for next round" % peer
		if peer == me:
			row.text = "You — waiting for next round"
		row.modulate = Color(1, 1, 1, 0.6)
		row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_player_list.add_child(row)

	var editable := Net.is_server()
	_players_spin.editable = editable
	_bots_check.disabled = not editable
	if not editable:
		_players_spin.set_value_no_signal(Net.lobby_player_count)
		_bots_check.set_pressed_no_signal(Net.lobby_fill_bots)
	_start_btn.visible = Net.i_am_leader()
	_start_btn.disabled = Net.humans_connected() == 0 \
		or (not Net.lobby_fill_bots and Net.humans_connected() < 2)


func _on_leave() -> void:
	Net.leave()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _on_session_ended(_reason: String) -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
