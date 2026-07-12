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

enum Variant { CLASSIC, ICE_BLOCKS, MELTING, POWER_UPS, CHAOS }
const VARIANT_NAMES := ["Classic", "Ice Blocks", "Melting Platform", "Power-Ups", "Chaos (all)"]

enum Difficulty { EASY, MEDIUM, HARD, EXPERT }
const DIFFICULTY_NAMES := ["Easy", "Medium", "Hard", "Expert"]

enum Minigame { SHOVE, TILE, SNOW, GOAL, BOULDER, RACE }
const MINIGAME_NAMES := ["Shove Out", "Tile Rush", "Snow Brawl", "Puck Panic", "Boulder Brawl", "Floe Dash"]

enum TeamMode { FFA, ALTERNATING, HUMANS_VS_BOTS }
const TEAM_MODE_NAMES := ["Free-for-All", "Two Teams", "Humans vs Bots"]

var player_count := 4
var human_count := 1
var variant := Variant.CLASSIC
var minigame := Minigame.SHOVE
var stage := 0                          # per-minigame arena layout (see Stages)
var team_mode := TeamMode.FFA
var difficulty := Difficulty.MEDIUM     # bot decision quality; never stat cheats
var wins_target := 3                    # round wins needed to take the trophy
var archetype_choices: Array[int] = []  # per slot; -1 = auto (cycle by slot)

const LOOK_NAMES := ["Penguin", "Blocky", "Snowman", "Robot"]
var look_choices: Array[int] = []       # per slot; -1 = penguin
var wins: Array[int] = []

const RESOLUTIONS: Array = [
	Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
	Vector2i(2560, 1440), Vector2i.ZERO] # ZERO = fullscreen
const RESOLUTION_NAMES := ["1280 × 720", "1600 × 900", "1920 × 1080", "2560 × 1440", "Fullscreen"]

var vsync_enabled := true
var fps_cap := 0 # 0 = uncapped
var music_on := true
var resolution_index := 0
var last_ip := "127.0.0.1"
var last_port := 9050
var player_name_local := ""            # shown to other players online
var slot_names: Array = []             # per-slot display names, set at match start


func _ready() -> void:
	_load_settings()
	_parse_cmdline()
	if wins.size() != player_count:
		_reset_wins()
	apply_video_settings()


func start_new_match(players: int, humans: int, p_variant := Variant.CLASSIC,
		p_wins_target := 3, choices: Array[int] = [],
		p_difficulty := Difficulty.MEDIUM, p_minigame := Minigame.SHOVE,
		p_stage := 0, p_team_mode := TeamMode.FFA, looks: Array[int] = []) -> void:
	player_count = clampi(players, 2, 8)
	human_count = clampi(humans, 1, mini(4, player_count))
	variant = p_variant
	minigame = p_minigame
	stage = clampi(p_stage, 0, Stages.count(minigame) - 1)
	team_mode = p_team_mode
	difficulty = p_difficulty
	wins_target = clampi(p_wins_target, 1, 5)
	archetype_choices = []
	look_choices = []
	for i in player_count:
		archetype_choices.append(choices[i] if i < choices.size() else -1)
		look_choices.append(looks[i] if i < looks.size() else -1)
	_reset_wins()


func look_for_slot(slot: int) -> int:
	if slot < look_choices.size() and look_choices[slot] >= 0:
		return look_choices[slot] % LOOK_NAMES.size()
	return 0


func archetype_for_slot(slot: int) -> Dictionary:
	if slot < archetype_choices.size() and archetype_choices[slot] >= 0:
		return CharacterStats.ARCHETYPES[archetype_choices[slot] % CharacterStats.ARCHETYPES.size()]
	return CharacterStats.for_slot(slot)


## Slot that has reached the trophy target, or -1 if the match is still open.
func match_winner() -> int:
	for i in wins.size():
		if wins[i] >= wins_target:
			return i
	return -1


## Team id for a slot (-1 = free-for-all). Humans-vs-Bots degrades to FFA when
## the roster has no bots (or no humans) — otherwise one side starts empty and
## the round would end instantly.
func team_of(slot: int) -> int:
	match team_mode:
		TeamMode.ALTERNATING:
			return slot % 2
		TeamMode.HUMANS_VS_BOTS:
			var humans := 0
			for i in player_count:
				if _slot_is_human(i):
					humans += 1
			if humans == 0 or humans == player_count:
				return -1
			return 0 if _slot_is_human(slot) else 1
		_:
			return -1


func _slot_is_human(slot: int) -> bool:
	if Net.is_online():
		return Net.slot_is_human(slot)
	return slot < human_count


func has_ice_blocks() -> bool:
	return variant == Variant.ICE_BLOCKS or variant == Variant.CHAOS


func has_melting() -> bool:
	return variant == Variant.MELTING or variant == Variant.CHAOS


func has_power_ups() -> bool:
	return variant == Variant.POWER_UPS or variant == Variant.CHAOS


func record_win(slot: int) -> void:
	if slot >= 0 and slot < wins.size():
		wins[slot] += 1


func player_label(slot: int) -> String:
	var who: String
	var custom := ""
	if slot < slot_names.size() and str(slot_names[slot]) != "":
		custom = str(slot_names[slot])
	if Net.is_online():
		if slot == Net.my_slot:
			who = custom if custom != "" else "YOU"
		elif Net.slot_is_human(slot):
			who = custom if custom != "" else "P%d" % (slot + 1)
		else:
			who = "BOT"
	elif slot == 0 and player_name_local != "":
		who = player_name_local
	else:
		who = "P%d" % (slot + 1) if slot < human_count else "BOT"
	var team_tag := ""
	var t := team_of(slot)
	if t >= 0:
		team_tag = "[%s] " % ("A" if t == 0 else "B")
	return "%s%s %s (%s)" % [team_tag, who, COLOR_NAMES[slot], archetype_for_slot(slot)["name"]]


func apply_video_settings() -> void:
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync_enabled else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = fps_cap
	apply_resolution()
	save_settings()


## Desktop only — phones and browsers own their window.
func apply_resolution() -> void:
	if DisplayServer.get_name() == "headless" or OS.has_feature("web") \
			or DisplayServer.is_touchscreen_available():
		return
	var res: Vector2i = RESOLUTIONS[clampi(resolution_index, 0, RESOLUTIONS.size() - 1)]
	if res == Vector2i.ZERO:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(res)
		# Re-center on the current screen.
		var screen := DisplayServer.window_get_current_screen()
		var screen_pos := DisplayServer.screen_get_position(screen)
		var screen_size := DisplayServer.screen_get_size(screen)
		DisplayServer.window_set_position(screen_pos + (screen_size - res) / 2)


func save_settings() -> void:
	var cf := ConfigFile.new()
	cf.set_value("video", "vsync", vsync_enabled)
	cf.set_value("video", "fps_cap", fps_cap)
	cf.set_value("audio", "music", music_on)
	cf.set_value("video", "resolution", resolution_index)
	cf.set_value("net", "last_ip", last_ip)
	cf.set_value("net", "last_port", last_port)
	cf.set_value("net", "player_name", player_name_local)
	cf.save(SETTINGS_PATH)


func _load_settings() -> void:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return
	vsync_enabled = cf.get_value("video", "vsync", true)
	fps_cap = cf.get_value("video", "fps_cap", 0)
	music_on = cf.get_value("audio", "music", true)
	resolution_index = cf.get_value("video", "resolution", 0)
	last_ip = cf.get_value("net", "last_ip", "127.0.0.1")
	last_port = cf.get_value("net", "last_port", 9050)
	player_name_local = cf.get_value("net", "player_name", "")


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
		elif arg.begins_with("variant="):
			variant = clampi(arg.get_slice("=", 1).to_int(), 0, Variant.size() - 1) as Variant
		elif arg.begins_with("difficulty="):
			difficulty = clampi(arg.get_slice("=", 1).to_int(), 0, Difficulty.size() - 1) as Difficulty
		elif arg.begins_with("game="):
			minigame = clampi(arg.get_slice("=", 1).to_int(), 0, Minigame.size() - 1) as Minigame
		elif arg.begins_with("stage="):
			stage = maxi(arg.get_slice("=", 1).to_int(), 0)
		elif arg.begins_with("teams="):
			team_mode = clampi(arg.get_slice("=", 1).to_int(), 0, TeamMode.size() - 1) as TeamMode
		elif arg.begins_with("looks="): # e.g. looks=0123 — per-slot body styles
			look_choices = []
			for c in arg.get_slice("=", 1):
				look_choices.append(c.to_int())
