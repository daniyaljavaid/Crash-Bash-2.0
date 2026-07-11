class_name HumanController
extends PlayerController
## Reads a local input device and converts it to a PlayerInput.
## The only gameplay-adjacent code allowed to touch the Input singleton.

enum Scheme { KEYBOARD_WASD, KEYBOARD_ARROWS, GAMEPAD }

const GAMEPAD_DEADZONE := 0.25

var scheme := Scheme.KEYBOARD_WASD
var device := 0 # joypad device id, used when scheme == GAMEPAD


func _init(p_scheme: Scheme, p_device := 0) -> void:
	scheme = p_scheme
	device = p_device


func get_player_input(_player: SimPlayer, _sim) -> PlayerInput:
	var pi := PlayerInput.new()
	match scheme:
		Scheme.KEYBOARD_WASD:
			pi.move = Input.get_vector("p1_left", "p1_right", "p1_up", "p1_down")
			pi.charge = Input.is_action_pressed("p1_charge")
		Scheme.KEYBOARD_ARROWS:
			pi.move = Input.get_vector("p2_left", "p2_right", "p2_up", "p2_down")
			pi.charge = Input.is_action_pressed("p2_charge")
		Scheme.GAMEPAD:
			var v := Vector2(
				Input.get_joy_axis(device, JOY_AXIS_LEFT_X),
				Input.get_joy_axis(device, JOY_AXIS_LEFT_Y))
			pi.move = Vector2.ZERO if v.length() < GAMEPAD_DEADZONE else v.limit_length(1.0)
			pi.charge = Input.is_joy_button_pressed(device, JOY_BUTTON_A)
	return pi
