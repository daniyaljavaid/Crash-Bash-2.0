extends Node
## Autoload "MatchConfig". Session state that must survive scene reloads:
## match setup, win counts across rounds, video settings.

const PLAYER_COLORS: Array[Color] = [
	Color("e74c3c"), # red
	Color("3498db"), # blue
	Color("2ecc71"), # green
	Color("f1c40f"), # yellow
	Color("9b59b6"), # purple
	Color("e67e22"), # orange
	Color("1abcbc"), # cyan
	Color("ff7ac8"), # pink
]
const COLOR_NAMES := ["RED", "BLUE", "GREEN", "YELLOW", "PURPLE", "ORANGE", "CYAN", "PINK"]

const SETTINGS_PATH := "user://settings.cfg"

var player_count := 4
var human_count := 1
var wins: Array[int] = []

var vsync_enabled := true
var fps_cap := 0 # 0 = uncapped
var last_ip := "127.0.0.1"
var last_port := 9050


func _ready() -> void:
	_load_settings()
	_parse_cmdline()
	if wins.size() != player_count:
		_reset_wins()
	apply_video_settings()


func start_new_match(players: int, humans: int) -> void:
	player_count = clampi(players, 2, 8)
	human_count = clampi(humans, 1, mini(4, player_count))
	_reset_wins()


func record_win(slot: int) -> void:
	if slot >= 0 and slot < wins.size():
		wins[slot] += 1


func player_label(slot: int) -> String:
	var who: String
	if Net.is_online():
		if slot == Net.my_slot:
			who = "YOU"
		elif Net.slot_is_human(slot):
			who = "P%d" % (slot + 1)
		else:
			who = "BOT"
	else:
		who = "P%d" % (slot + 1) if slot < human_count else "BOT"
	return "%s %s (%s)" % [who, COLOR_NAMES[slot], CharacterStats.for_slot(slot)["name"]]


func apply_video_settings() -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync_enabled else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = fps_cap
	save_settings()


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("video", "vsync", vsync_enabled)
	cf.set_value("video", "fps_cap", fps_cap)
	cf.set_value("net", "last_ip", last_ip)
	cf.set_value("net", "last_port", last_port)
	cf.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	vsync_enabled = cf.get_value("video", "vsync", true)
	fps_cap = cf.get_value("video", "fps_cap", 0)
	last_ip = cf.get_value("net", "last_ip", "127.0.0.1")
	last_port = cf.get_value("net", "last_port", 9050)


func _reset_wins() -> void:
	wins = []
	for i in player_count:
		wins.append(0)


# Lets headless/CI runs configure a match without the menu, e.g.:
#   godot --headless res://scenes/arena.tscn --quit-after 900 -- players=8 humans=0
func _parse_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("players="):
			player_count = clampi(arg.get_slice("=", 1).to_int(), 2, 8)
		elif arg.begins_with("humans="):
			human_count = clampi(arg.get_slice("=", 1).to_int(), 0, 4)
