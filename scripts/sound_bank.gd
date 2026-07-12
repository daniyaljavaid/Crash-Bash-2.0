extends Node
## Autoload "SoundBank". Every SFX is synthesized into an AudioStreamWAV at
## startup — no external audio assets. Playback goes through a small pool of
## AudioStreamPlayers so overlapping events don't cut each other off.

const MIX_RATE := 22050
const POOL_SIZE := 10

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _music_player: AudioStreamPlayer = null
var _music_tracks := {}
var _current_track := ""


func _ready() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.volume_db = -16.0
	_music_player.process_mode = Node.PROCESS_MODE_ALWAYS # keeps playing in pause
	add_child(_music_player)
	if DisplayServer.get_name() != "headless":
		_music_tracks["menu"] = _make_music(false)
		_music_tracks["game"] = _make_music(true)
	_streams["beep"] = _make_wav(_tone(660.0, 0.09))
	_streams["go"] = _make_wav(_tone(880.0, 0.28))
	_streams["hit"] = _make_wav(_hit())
	_streams["whoosh"] = _make_wav(_whoosh())
	_streams["splash"] = _make_wav(_noise(0.5, 14, 1.0))
	_streams["crack"] = _make_wav(_noise(0.08, 2, 0.9))
	_streams["pickup"] = _make_wav(_tone(520.0, 0.08) + _tone(780.0, 0.1))
	_streams["freeze"] = _make_wav(_sweep(900.0, 300.0, 0.3))
	_streams["jingle"] = _make_wav(
		_tone(523.25, 0.13) + _tone(659.25, 0.13) + _tone(783.99, 0.13) + _tone(1046.5, 0.3))
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


func play_music(track: String) -> void:
	if not MatchConfig.music_on or not _music_tracks.has(track):
		return
	if _current_track == track and _music_player.playing:
		return
	_current_track = track
	_music_player.stream = _music_tracks[track]
	_music_player.play()


func stop_music() -> void:
	_current_track = ""
	_music_player.stop()


func music_setting_changed() -> void:
	if not MatchConfig.music_on:
		stop_music()


## A 16-second seamless chiptune loop, composed in code: Am-F-C-G, sine arp,
## soft bass; the battle variant adds a kick/hat pulse and doubles the tempo
## feel. No audio files anywhere in the project.
func _make_music(battle: bool) -> AudioStreamWAV:
	var bpm := 112.0 if battle else 66.0
	var beat := 60.0 / bpm
	var bars := 8
	var total := beat * 4.0 * bars
	var n := int(MIX_RATE * total)
	var buf := PackedFloat32Array()
	buf.resize(n)
	# Chord roots (Hz): Am, F, C, G — two bars each.
	var roots := [110.0, 87.31, 130.81, 98.0]
	var minor := [true, false, false, false]
	for bar in bars:
		var root: float = roots[(bar / 2) % 4]
		var is_minor: bool = minor[(bar / 2) % 4]
		var third := root * (1.189 if is_minor else 1.26)  # minor/major third
		var fifth := root * 1.498
		var bar_start := bar * beat * 4.0
		# Pad: whole-bar soft triad, one octave up.
		_add_tone(buf, bar_start, beat * 4.0, root * 2.0, 0.05, 0.4)
		_add_tone(buf, bar_start, beat * 4.0, third * 2.0, 0.04, 0.4)
		_add_tone(buf, bar_start, beat * 4.0, fifth * 2.0, 0.04, 0.4)
		# Arp: chord tones on eighths, two octaves up.
		var arp := [root * 4.0, third * 4.0, fifth * 4.0, third * 4.0,
			root * 4.0, fifth * 4.0, third * 4.0, fifth * 4.0]
		for i in 8:
			_add_tone(buf, bar_start + i * beat * 0.5, beat * 0.45, arp[i],
				0.1 if battle else 0.07, 6.0)
		# Bass: root on each beat.
		for b in 4:
			_add_tone(buf, bar_start + b * beat, beat * 0.9, root, 0.14, 3.0)
		if battle:
			for b in 4:
				_add_thump(buf, bar_start + b * beat, 0.10)          # kick
				_add_tick(buf, bar_start + (b + 0.5) * beat, 0.05)   # offbeat hat
	# Gentle master clip.
	for i in n:
		buf[i] = clampf(buf[i], -0.95, 0.95)
	var wav := _make_wav(buf)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_end = n
	return wav


func _add_tone(buf: PackedFloat32Array, start: float, dur: float, freq: float,
		amp: float, decay: float) -> void:
	var s := int(start * MIX_RATE)
	var count := mini(int(dur * MIX_RATE), buf.size() - s)
	for i in count:
		var t := float(i) / MIX_RATE
		var env := minf(t / 0.01, 1.0) * exp(-decay * t / dur)
		buf[s + i] += sin(TAU * freq * t) * amp * env


func _add_thump(buf: PackedFloat32Array, start: float, amp: float) -> void:
	var s := int(start * MIX_RATE)
	var count := mini(int(0.1 * MIX_RATE), buf.size() - s)
	for i in count:
		var t := float(i) / MIX_RATE
		buf[s + i] += sin(TAU * 70.0 * t) * amp * exp(-30.0 * t)


func _add_tick(buf: PackedFloat32Array, start: float, amp: float) -> void:
	var s := int(start * MIX_RATE)
	var count := mini(int(0.03 * MIX_RATE), buf.size() - s)
	for i in count:
		buf[s + i] += (fmod(i * 12.9898, 2.0) - 1.0) * amp * exp(-6.0 * float(i) / count)


func play(sound: String, volume_db := -8.0) -> void:
	if not _streams.has(sound):
		return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = _streams[sound]
	p.volume_db = volume_db
	p.play()


# --- synthesis ---------------------------------------------------------------

func _tone(freq: float, dur: float) -> PackedFloat32Array:
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		var t := float(i) / MIX_RATE
		var env := minf(t / 0.005, 1.0) * exp(-4.0 * t / dur)
		out[i] = sin(TAU * freq * t) * env * 0.8
	return out


func _sweep(from_hz: float, to_hz: float, dur: float) -> PackedFloat32Array:
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	for i in n:
		var frac := float(i) / n
		var freq := lerpf(from_hz, to_hz, frac)
		phase += TAU * freq / MIX_RATE
		out[i] = sin(phase) * (1.0 - frac) * 0.7
	return out


## Filtered noise burst with exponential decay. `smooth` is a running-average
## window: larger = duller (splash), smaller = sharper (crack).
func _noise(dur: float, smooth: int, punch: float) -> PackedFloat32Array:
	var n := int(MIX_RATE * dur)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var acc := 0.0
	for i in n:
		var t := float(i) / n
		acc += (rng.randf() * 2.0 - 1.0 - acc) / smooth
		out[i] = acc * exp(-5.0 * t) * punch * 2.0
	return out


## Charge whoosh: noise swelling up then cut.
func _whoosh() -> PackedFloat32Array:
	var n := int(MIX_RATE * 0.22)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var acc := 0.0
	for i in n:
		var t := float(i) / n
		var env := sin(t * PI) # swell in, fade out
		acc += (rng.randf() * 2.0 - 1.0 - acc) / 6.0
		out[i] = acc * env * 1.6
	return out


## Charge impact: low thump + noise transient.
func _hit() -> PackedFloat32Array:
	var n := int(MIX_RATE * 0.14)
	var out := PackedFloat32Array()
	out.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in n:
		var t := float(i) / MIX_RATE
		var frac := float(i) / n
		var thump := sin(TAU * 85.0 * t) * exp(-14.0 * frac)
		var snap := (rng.randf() * 2.0 - 1.0) * exp(-40.0 * frac) * 0.6
		out[i] = clampf(thump + snap, -1.0, 1.0)
	return out


func _make_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		bytes.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = bytes
	return wav
