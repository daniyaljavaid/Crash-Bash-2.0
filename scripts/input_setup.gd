extends Node
## Autoload "InputSetup". Registers keyboard actions in code instead of the
## project.godot [input] section — one obvious place to see/change bindings.
## Gamepad players are read directly by HumanController (analog stick), so no
## actions are needed for them.

func _ready() -> void:
	_bind("p1_up", KEY_W)
	_bind("p1_down", KEY_S)
	_bind("p1_left", KEY_A)
	_bind("p1_right", KEY_D)
	_bind("p1_charge", KEY_SPACE)

	_bind("p2_up", KEY_UP)
	_bind("p2_down", KEY_DOWN)
	_bind("p2_left", KEY_LEFT)
	_bind("p2_right", KEY_RIGHT)
	_bind("p2_charge", KEY_ENTER)


func _bind(action: String, key: Key) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = key
	InputMap.action_add_event(action, ev)
