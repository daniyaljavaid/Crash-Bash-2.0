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
	_fps_opt.item_selected.connect(_on_fps_selected)
	$Center/Panel/VBox/ResumeButton.pressed.connect(_toggle)
	$Center/Panel/VBox/MenuButton.pressed.connect(_on_quit_to_menu)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle()
		get_viewport().set_input_as_handled()


func _toggle() -> void:
	visible = not visible
	get_tree().paused = visible


func _on_vsync_toggled(pressed: bool) -> void:
	MatchConfig.vsync_enabled = pressed
	MatchConfig.apply_video_settings()


func _on_fps_selected(index: int) -> void:
	MatchConfig.fps_cap = FPS_OPTIONS[index]
	MatchConfig.apply_video_settings()


func _on_quit_to_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
