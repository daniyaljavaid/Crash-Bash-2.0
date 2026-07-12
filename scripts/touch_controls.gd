class_name TouchControls
extends CanvasLayer
## Mobile input overlay: a dynamic virtual joystick on the left half (appears
## where the thumb lands), a charge/throw button bottom-right, and a pause
## button top-right. Exposes `move`/`charge` for HumanController's TOUCH
## scheme — the sim consumes the same PlayerInput as every other device.

signal pause_requested

static var current: TouchControls = null

const JOY_RADIUS := 130.0
const BTN_RADIUS := 85.0
const PAUSE_RADIUS := 34.0

var move := Vector2.ZERO
var charge := false

var _joy_touch := -1
var _joy_center := Vector2.ZERO
var _joy_pos := Vector2.ZERO
var _btn_touch := -1
var _canvas: Control = null


func _enter_tree() -> void:
	current = self


func _exit_tree() -> void:
	if current == self:
		current = null


func _ready() -> void:
	layer = 50
	_canvas = DrawLayer.new()
	_canvas.controls = self
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_canvas)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var size := _canvas.get_viewport_rect().size
		if event.pressed:
			if _pause_rect(size).has_point(event.position):
				pause_requested.emit()
			elif event.position.distance_to(_btn_center(size)) <= BTN_RADIUS * 1.3 \
					and _btn_touch < 0:
				_btn_touch = event.index
				charge = true
			elif event.position.x < size.x * 0.55 and _joy_touch < 0:
				_joy_touch = event.index
				_joy_center = event.position
				_joy_pos = event.position
		else:
			if event.index == _btn_touch:
				_btn_touch = -1
				charge = false
			elif event.index == _joy_touch:
				_joy_touch = -1
				move = Vector2.ZERO
		_canvas.queue_redraw()
	elif event is InputEventScreenDrag and event.index == _joy_touch:
		_joy_pos = event.position
		move = ((_joy_pos - _joy_center) / JOY_RADIUS).limit_length(1.0)
		_canvas.queue_redraw()


func _btn_center(size: Vector2) -> Vector2:
	return Vector2(size.x - BTN_RADIUS - 60.0, size.y - BTN_RADIUS - 60.0)


func _pause_rect(size: Vector2) -> Rect2:
	return Rect2(size.x - 90.0, 24.0, 66.0, 66.0)


## Draws the joystick/button shapes — kept in a child Control because a
## CanvasLayer can't draw directly.
class DrawLayer extends Control:
	var controls: TouchControls

	func _draw() -> void:
		var vp := get_viewport_rect().size
		# Charge button
		var bc := controls._btn_center(vp)
		var pressed := controls.charge
		draw_circle(bc, BTN_RADIUS, Color(1, 1, 1, 0.28 if pressed else 0.14))
		draw_arc(bc, BTN_RADIUS, 0, TAU, 40, Color(1, 1, 1, 0.5), 3.0)
		var label := "THROW" if MatchConfig.minigame == MatchConfig.Minigame.SNOW \
			or MatchConfig.minigame == MatchConfig.Minigame.BOULDER else "PUSH"
		var font := ThemeDB.fallback_font
		var tsize := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, 24)
		draw_string(font, bc - Vector2(tsize.x * 0.5, -8), label,
			HORIZONTAL_ALIGNMENT_CENTER, -1, 24, Color(1, 1, 1, 0.75))
		# Pause button
		var pr := controls._pause_rect(vp)
		var pc := pr.get_center()
		draw_circle(pc, PAUSE_RADIUS, Color(1, 1, 1, 0.12))
		draw_rect(Rect2(pc + Vector2(-10, -12), Vector2(7, 24)), Color(1, 1, 1, 0.6))
		draw_rect(Rect2(pc + Vector2(3, -12), Vector2(7, 24)), Color(1, 1, 1, 0.6))
		# Joystick (only while touched)
		if controls._joy_touch >= 0:
			draw_circle(controls._joy_center, JOY_RADIUS, Color(1, 1, 1, 0.08))
			draw_arc(controls._joy_center, JOY_RADIUS, 0, TAU, 40, Color(1, 1, 1, 0.4), 3.0)
			var knob: Vector2 = controls._joy_center \
				+ controls.move * JOY_RADIUS
			draw_circle(knob, 42.0, Color(1, 1, 1, 0.35))
