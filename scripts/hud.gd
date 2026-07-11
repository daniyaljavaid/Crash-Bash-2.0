extends Control
## Reads sim state every frame and displays it. Writes nothing back into the
## simulation — buttons only emit signals the arena scene acts on.

signal next_round_requested
signal menu_requested

const GO_BANNER_TIME := 0.9

var _sim = null # MatchSim (offline/server) or ClientReplica (client) — same read API
var _cells: Array[Dictionary] = []
var _prev_state := -1
var _go_left := 0.0
var _last_countdown := -1

@onready var _timer_label: Label = $TimerLabel
@onready var _banner: Label = $Banner
@onready var _strip: HBoxContainer = $Strip
@onready var _end_panel: CenterContainer = $EndPanel
@onready var _winner_label: Label = $EndPanel/Panel/VBox/WinnerLabel
@onready var _score_rows: VBoxContainer = $EndPanel/Panel/VBox/ScoreRows


func _ready() -> void:
	$EndPanel/Panel/VBox/Buttons/NextButton.pressed.connect(
		func() -> void: next_round_requested.emit())
	$EndPanel/Panel/VBox/Buttons/MenuButton.pressed.connect(
		func() -> void: menu_requested.emit())


func bind_sim(sim) -> void:
	_sim = sim
	_sim.player_eliminated.connect(_on_player_eliminated)
	_sim.round_ended.connect(_on_round_ended)
	_build_strip()


func _process(delta: float) -> void:
	if _sim == null:
		return
	_timer_label.text = "%d:%02d" % [floori(_sim.time_left / 60.0), int(_sim.time_left) % 60]
	match _sim.state:
		MatchSim.State.COUNTDOWN:
			_banner.visible = true
			var n := int(ceil(_sim.countdown_left))
			_banner.text = str(n)
			if n != _last_countdown:
				_last_countdown = n
				SoundBank.play("beep")
		MatchSim.State.PLAYING:
			if _prev_state == MatchSim.State.COUNTDOWN:
				_go_left = GO_BANNER_TIME
				_banner.text = "GO!"
				SoundBank.play("go")
			_go_left -= delta
			_banner.visible = _go_left > 0.0
		MatchSim.State.OVER:
			pass # banner is owned by _on_round_ended from here
	_prev_state = _sim.state
	for i in _sim.players.size():
		_cells[i]["bar"].value = _sim.players[i].stamina


func _build_strip() -> void:
	for i in _sim.players.size():
		var cell := VBoxContainer.new()
		var swatch := ColorRect.new()
		swatch.color = MatchConfig.PLAYER_COLORS[i]
		swatch.custom_minimum_size = Vector2(84, 8)
		var bar := ProgressBar.new()
		bar.max_value = Tuning.STAMINA_MAX
		bar.value = Tuning.STAMINA_MAX
		bar.show_percentage = false
		bar.custom_minimum_size = Vector2(84, 12)
		var label := Label.new()
		label.text = MatchConfig.player_label(i)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 11)
		cell.add_child(swatch)
		cell.add_child(bar)
		cell.add_child(label)
		_strip.add_child(cell)
		_cells.append({"root": cell, "bar": bar, "label": label})


func _on_player_eliminated(slot: int, _at: Vector3) -> void:
	_cells[slot]["root"].modulate = Color(1, 1, 1, 0.35)
	_cells[slot]["label"].text = "OUT"


func _on_round_ended(winner_slot: int) -> void:
	_banner.visible = true
	if winner_slot >= 0:
		_banner.text = "%s WINS!" % MatchConfig.COLOR_NAMES[winner_slot]
		_banner.add_theme_color_override("font_color", MatchConfig.PLAYER_COLORS[winner_slot])
	else:
		_banner.text = "TIE!"
		_banner.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
	SoundBank.play("jingle", -6.0)
	await get_tree().create_timer(1.5).timeout
	_banner.visible = false
	_show_end_panel(winner_slot)


func _show_end_panel(winner_slot: int) -> void:
	var trophy_slot := MatchConfig.match_winner()
	if trophy_slot >= 0:
		_winner_label.text = "🏆  %s TAKES THE TROPHY  🏆" % MatchConfig.player_label(trophy_slot)
		_winner_label.add_theme_color_override("font_color", MatchConfig.PLAYER_COLORS[trophy_slot])
	else:
		_winner_label.text = ("%s WINS THE ROUND" % MatchConfig.COLOR_NAMES[winner_slot]) \
			if winner_slot >= 0 else "TIE!"
	for child in _score_rows.get_children():
		child.queue_free()
	for i in _sim.players.size():
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var swatch := ColorRect.new()
		swatch.color = MatchConfig.PLAYER_COLORS[i]
		swatch.custom_minimum_size = Vector2(18, 18)
		var label := Label.new()
		label.text = "%s — %d / %d wins" % [
			MatchConfig.player_label(i), MatchConfig.wins[i], MatchConfig.wins_target]
		if i == winner_slot:
			label.add_theme_color_override("font_color", Color(1, 0.9, 0.4))
		row.add_child(swatch)
		row.add_child(label)
		_score_rows.add_child(row)
	# Online, only the lobby leader may advance the match.
	var next_btn: Button = $EndPanel/Panel/VBox/Buttons/NextButton
	next_btn.text = "New Match" if trophy_slot >= 0 else "Next Round"
	next_btn.disabled = false
	if Net.is_online() and not Net.i_am_leader():
		next_btn.text = "Waiting for host..."
		next_btn.disabled = true
	_end_panel.visible = true
