class_name BotController
extends PlayerController
## Simple wander-toward-nearest-opponent AI. Reads sim state only, emits the
## same PlayerInput a human would — the simulation can't tell the difference.

const CHARGE_RANGE := 3.5        # start a charge when this close to the target
const EDGE_MARGIN := 1.6         # start steering inward this far from the edge
const EDGE_LOOKAHEAD := 0.6      # seconds of velocity extrapolation for edge check
const WOBBLE := 0.35             # radians of steering noise so bots don't beeline
const OUTWARD_DOT_MIN := 0.0     # near the edge, only charge if it shoves the victim outward
const FEAR_TICKS := 30           # 0.5 s: after being hit, flee instead of re-engaging

var _fear_until_tick := 0


func get_player_input(player: SimPlayer, sim) -> PlayerInput:
	var pi := PlayerInput.new()
	var target := _nearest_opponent(player, sim)
	if target == null:
		return pi

	# Just got charged: dodge PERPENDICULAR to the attack line (biased inward)
	# until composure returns. Without evasion the victim steers straight back
	# at its attacker and gets escort-charged off; fleeing straight away is
	# worse (it runs ahead of the next charge, toward the edge); running dead
	# center makes bots unkillable and rounds stalemate. Sideways breaks the
	# attacker's line so follow-up charges overshoot.
	if player.stagger_left > 0.0:
		_fear_until_tick = sim.tick + FEAR_TICKS
	if sim.tick < _fear_until_tick:
		var flat: Vector3 = player.global_position
		flat.y = 0.0
		var away: Vector3 = player.global_position - target.global_position
		away.y = 0.0
		var tangent: Vector3 = away.normalized().cross(Vector3.UP)
		var inward := -flat.normalized() if flat.length() > 0.5 else Vector3.ZERO
		if tangent.dot(inward) < 0.0:
			tangent = -tangent # dodge toward the side that leads inward
		var flee := tangent * 0.65 + inward * 0.35
		pi.move = Vector2(flee.x, flee.z).limit_length(1.0)
		return pi

	var to_target: Vector3 = target.global_position - player.global_position
	to_target.y = 0.0
	var dist := to_target.length()
	var dir := to_target / maxf(dist, 0.001)

	# Deterministic wobble driven by the sim tick (no wall-clock randomness).
	var desired := dir.rotated(Vector3.UP, sin(sim.tick * 0.03 + player.slot * 2.1) * WOBBLE)

	# Edge avoidance: extrapolate position and steer inward if headed off.
	var future: Vector3 = player.global_position + player.velocity * EDGE_LOOKAHEAD
	future.y = 0.0
	if future.length() > sim.arena_radius - EDGE_MARGIN:
		desired = desired * 0.35 - future.normalized() * 0.65

	pi.move = Vector2(desired.x, desired.z).limit_length(1.0)

	# Charge if close, off recovery, stamina up, the shove is worth it, and the
	# post-charge slide won't carry the bot off the platform. Aim by overriding
	# the move intent (the sim charges along the stick direction).
	if dist < CHARGE_RANGE and player.recovery_left <= 0.0 \
			and player.stamina >= player.stats.stamina_cost:
		var travel: float = Tuning.CHARGE_SPEED * Tuning.CHARGE_DURATION * (1.0 + player.stats.momentum_keep)
		var landing: Vector3 = player.global_position + dir * travel
		landing.y = 0.0
		var safe: bool = landing.length() < sim.arena_radius - 0.3
		# Finisher: victim hugging the edge and the shove points squarely off
		# the platform — take the shot even if the follow-through is risky.
		var finisher: bool = _target_radius(target) > sim.arena_radius * 0.72 \
			and dir.dot(_target_flat(target).normalized()) > 0.5
		# Aggression throttle: outside finishers, each bot is only "willing" to
		# charge during a periodic window (phase-shifted per slot) so 8 bots
		# don't resolve the round in seconds. The window widens as the round
		# clock runs down, so late-game bots turn relentless and rounds resolve
		# instead of stalling to the timer.
		var elapsed_frac: float = (Tuning.ROUND_TIME - sim.time_left) / Tuning.ROUND_TIME
		var window := 8 + int(62.0 * elapsed_frac)
		var phase: int = (sim.tick + player.slot * 53) % 90
		var willing: bool = phase < window or finisher
		if willing and (safe or finisher) and _kill_worthy(dir, target, sim):
			pi.move = Vector2(dir.x, dir.z)
			pi.charge = true
	return pi


func _target_flat(target: SimPlayer) -> Vector3:
	var flat: Vector3 = target.global_position
	flat.y = 0.0
	return flat


func _target_radius(target: SimPlayer) -> float:
	return _target_flat(target).length()


## Don't waste charges ping-ponging victims around the middle: when the victim
## is in the outer half, only charge if the shove points them off the platform.
func _kill_worthy(dir: Vector3, target: SimPlayer, sim) -> bool:
	var target_flat: Vector3 = target.global_position
	target_flat.y = 0.0
	if target_flat.length() < sim.arena_radius * 0.5:
		return true
	return dir.dot(target_flat.normalized()) > OUTWARD_DOT_MIN


func _nearest_opponent(player: SimPlayer, sim) -> SimPlayer:
	var best: SimPlayer = null
	var best_d := INF
	for p in sim.players:
		if p == player or not p.alive:
			continue
		var d := player.global_position.distance_squared_to(p.global_position)
		if d < best_d:
			best_d = d
			best = p
	return best
