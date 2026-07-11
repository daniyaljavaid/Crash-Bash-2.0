extends Control
## Pre-round setup: match size, human count, start.

@onready var _players_spin: SpinBox = $Center/VBox/PlayersRow/PlayersSpin
@onready var _humans_spin: SpinBox = $Center/VBox/HumansRow/HumansSpin


func _ready() -> void:
	$Center/VBox/StartButton.pressed.connect(_on_start)
	$Center/VBox/QuitButton.pressed.connect(func() -> void: get_tree().quit())
	$Center/VBox/StartButton.grab_focus()


func _on_start() -> void:
	MatchConfig.start_new_match(int(_players_spin.value), int(_humans_spin.value))
	get_tree().change_scene_to_file("res://scenes/arena.tscn")
