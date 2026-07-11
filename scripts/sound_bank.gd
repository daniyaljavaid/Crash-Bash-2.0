extends Node
## Autoload "SoundBank". Every SFX is synthesized into an AudioStreamWAV at
## startup — no external audio assets. Playback goes through a small pool of
## AudioStreamPlayers so overlapping events don't cut each other off.

const MIX_RATE := 22050
const POOL_SIZE := 10

var _streams := {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0


func _ready() -> void:
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
