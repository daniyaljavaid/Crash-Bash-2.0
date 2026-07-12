extends CanvasLayer
## ESC pause overlay with the video settings required for high-refresh play.
## PROCESS_MODE_ALWAYS so it keeps working while the tree is paused.

const FPS_OPTIONS := [60, 120, 144, 240, 0] # 0 = uncapped

@onready var _vsync_btn: CheckButton = $Center/Panel/VBox/VSync
@onready var _fps_opt: OptionButton = $Center/Panel/VBox/FpsRow/FpsOption


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	for f in FPS_OPTIONS:
		_fps_opt.add_item("Uncapped" if f == 0 else "%d FPS" % f)
	_fps_opt.selected = maxi(FPS_OPTIONS.find(MatchConfig.fps_cap), 0)
	_vsync_btn.button_pressed = MatchConfig.vsync_enabled
	_vsync_btn.toggled.connect(_on_vsync_toggled)
	var res_opt: OptionButton = $Center/Panel/VBox/ResRow/ResOption
	for name in MatchConfig.RESOLUTION_NAMES:
		res_opt.add_item(name)
	res_opt.selected = clampi(MatchConfig.resolution_index, 0, MatchConfig.RESOLUTION_NAMES.size() - 1)
	res_opt.item_selected.connect(func(i: int) -> void:
		MatchConfig.resolution_index = i
		MatchConfig.apply_video_settings())
	# Phones/browsers own their window size.
	$Center/Panel/VBox/ResRow.visible = not OS.has_feature("web") \
		and not DisplayServer.is_touchscreen_available()
	var fps_btn: CheckButton = $Center/Panel/VBox/ShowFps
	fps_btn.button_pressed = MatchConfig.show_fps
	fps_btn.toggled.connect(func(on: bool) -> void:
		MatchConfig.show_fps = on
		MatchConfig.save_settings())
	var music_btn: CheckButton = $Center/Panel/VBox/Music
	music_btn.button_pressed = MatchConfig.music_on
	music_btn.toggled.connect(func(on: bool) -> void:
		MatchConfig.music_on = on
		MatchConfig.save_settings()
		SoundBank.music_setting_changed()
		if on:
			SoundBank.play_music("game"))
	_fps_opt.item_selected.connect(_on_fps_selected)
	$Center/Panel/VBox/ResumeButton.pressed.connect(_toggle)
	$Center/Panel/VBox/MenuButton.pressed.connect(_on_quit_to_menu)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle()
		get_viewport().set_input_as_handled()


func _toggle() -> void:
	visible = not visible
	# Online, the server keeps simulating for everyone — never pause the tree.
	if not Net.is_online():
		get_tree().paused = visible


func _on_vsync_toggled(pressed: bool) -> void:
	MatchConfig.vsync_enabled = pressed
	MatchConfig.apply_video_settings()


func _on_fps_selected(index: int) -> void:
	MatchConfig.fps_cap = FPS_OPTIONS[index]
	MatchConfig.apply_video_settings()


func _on_quit_to_menu() -> void:
	get_tree().paused = false
	if Net.is_online():
		Net.leave()
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
