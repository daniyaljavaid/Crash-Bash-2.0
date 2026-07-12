extends CanvasLayer
## Autoload "FpsOverlay": small FPS readout, toggled from the pause menu.
## Runs above everything and keeps updating while the tree is paused.

var _label: Label


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_label = Label.new()
	_label.position = Vector2(10, 8)
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("outline_size", 4)
	add_child(_label)


func _process(_delta: float) -> void:
	visible = MatchConfig.show_fps
	if visible:
		_label.text = "%d FPS" % Engine.get_frames_per_second()
