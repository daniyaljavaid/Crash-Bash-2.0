class_name BotController
extends PlayerController
## Wander-toward-opponent AI. Reads sim state only, emits the same PlayerInput
## a human would — the simulation can't tell the difference.
##
## Difficulty (MatchConfig.difficulty) only changes DECISION QUALITY — aim
## noise, aggression, self-preservation, target selection — never player
## stats, so a Hard bot and a human have identical physical capabilities.

const EDGE_LOOKAHEAD := 0.6      # seconds of velocity extrapolation for edge check
const OUTWARD_DOT_MIN := 0.0     # near the edge, only charge if it shoves the victim outward

## Per-difficulty decision profile:
## charge_range  — engagement distance
## wobble        — radians of steering/aim noise
## fear_ticks    — how long a hit bot dodges before re-engaging
## edge_margin   — how early it steers away from the edge (bigger = safer)
## landing_pad   — required distance between predicted whiff-slide and the edge
## window_base/gain — aggression throttle (willing ticks of 90, grows over round)
## finisher_dot  — how squarely a shove must point off-platform to take a risky
##                 finisher (lower = greedier)
## smart_target  — pick the most edge-vulnerable reachable opponent, not nearest
const PROFILES := [
	{ # EASY — wanders, swings wide, panics long, hesitates
		"charge_range": 2.6, "wobble": 0.65, "fear_ticks": 48, "edge_margin": 1.2,
		"landing_pad": 0.1, "window_base": 4, "window_gain": 36.0,
		"finisher_dot": 0.65, "smart_target": false },
	{ # MEDIUM — the tuned M1 baseline
		"charge_range": 3.5, "wobble": 0.35, "fear_ticks": 30, "edge_margin": 1.6,
		"landing_pad": 0.3, "window_base": 8, "window_gain": 62.0,
		"finisher_dot": 0.5, "smart_target": false },
	{ # HARD — tighter aim, braver, recovers fast
		"charge_range": 3.9, "wobble": 0.18, "fear_ticks": 20, "edge_margin": 1.9,
		"landing_pad": 0.5, "window_base": 16, "window_gain": 70.0,
		"finisher_dot": 0.4, "smart_target": false },
	{ # EXPERT — near-perfect aim, always willing, hunts whoever is nearest the edge
		"charge_range": 4.3, "wobble": 0.07, "fear_ticks": 12, "edge_margin": 2.2,
		"landing_pad": 0.6, "window_base": 90, "window_gain": 0.0,
		"finisher_dot": 0.3, "smart_target": true },
]

var _fear_until_tick := 0


func get_player_input(player: SimPlayer, sim) -> PlayerInput:
	var prof: Dictionary = PROFILES[MatchConfig.difficulty]
	var pi := PlayerInput.new()
	# Puck Panic plays goalkeeper, not sumo.
	if sim.pucks != null:
		return _goal_guard_input(player, sim, prof)
	# Floe Dash races the lane.
	if sim.race != null:
		return _race_input(player, sim, prof)
	# Boulder Brawl: fetch ammo when empty-handed; the throw itself reuses the
	# normal engagement logic below (ranged like Snow Brawl).
	if sim.boulders != null and not sim.boulders.carrying(player.slot):
		return _fetch_boulder_input(player, sim, prof)
	var target := _pick_target(player, sim, prof)
	if target == null:
		return pi

	# Just got charged: dodge PERPENDICULAR to the attack line (biased inward)
	# until composure returns. Without evasion the victim steers straight back
	# at its attacker and gets escort-charged off; fleeing straight away is
	# worse (it runs ahead of the next charge, toward the edge); running dead
	# center makes bots unkillable and rounds stalemate. Sideways breaks the
	# attacker's line so follow-up charges overshoot.
	if player.stagger_left > 0.0:
		_fear_until_tick = sim.tick + int(prof["fear_ticks"])
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
	var desired := dir.rotated(Vector3.UP,
		sin(sim.tick * 0.03 + player.slot * 2.1) * float(prof["wobble"]))

	# Edge avoidance: extrapolate position and steer inward if headed off.
	var future: Vector3 = player.global_position + player.velocity * EDGE_LOOKAHEAD
	future.y = 0.0
	if future.length() > sim.arena_radius - float(prof["edge_margin"]):
		desired = desired * 0.35 - future.normalized() * 0.65

	pi.move = Vector2(desired.x, desired.z).limit_length(1.0)

	# Charge if close, off recovery, stamina up, the shove is worth it, and the
	# post-charge slide won't carry the bot off the platform. Aim by overriding
	# the move intent (the sim charges along the stick direction).
	# Snow Brawl throws are ranged and cost no self-momentum, so the engagement
	# distance stretches and the landing check always passes.
	var ranged: bool = player.throw_mode
	# Don't hurl the boulder from across the map — accuracy dies with distance.
	var engage_range: float = 9.0 if ranged else float(prof["charge_range"])
	if sim.boulders != null:
		engage_range = 5.0
	if dist < engage_range and player.recovery_left <= 0.0 \
			and player.stamina >= player.stats.stamina_cost:
		var travel: float = Tuning.CHARGE_SPEED * Tuning.CHARGE_DURATION * (1.0 + player.stats.momentum_keep)
		var landing: Vector3 = player.global_position + dir * travel
		landing.y = 0.0
		var safe: bool = ranged \
			or landing.length() < sim.arena_radius - float(prof["landing_pad"])
		# Finisher: victim hugging the edge and the shove points squarely off
		# the platform — take the shot even if the follow-through is risky.
		var finisher: bool = _target_radius(target) > sim.arena_radius * 0.72 \
			and dir.dot(_target_flat(target).normalized()) > float(prof["finisher_dot"])
		# Aggression throttle: outside finishers, each bot is only "willing" to
		# charge during a periodic window (phase-shifted per slot) so 8 bots
		# don't resolve the round in seconds. The window widens as the round
		# clock runs down, so late-game bots turn relentless and rounds resolve
		# instead of stalling to the timer.
		var elapsed_frac: float = (Tuning.ROUND_TIME - sim.time_left) / Tuning.ROUND_TIME
		var window := int(prof["window_base"]) + int(float(prof["window_gain"]) * elapsed_frac)
		var phase: int = (sim.tick + player.slot * 53) % 90
		var willing: bool = phase < window or finisher
		if willing and (safe or finisher) and _kill_worthy(dir, target, sim):
			# Ranged throws inherit the difficulty aim-noise; melee dashes stay
			# precise (the dash itself already gambles momentum).
			var aim := dir
			if ranged:
				aim = dir.rotated(Vector3.UP,
					sin(sim.tick * 0.11 + player.slot * 3.7) * float(prof["wobble"]) * 0.6)
			pi.move = Vector2(aim.x, aim.z)
			pi.charge = true
	return pi


## Boulder Brawl, empty-handed: run to the nearest idle boulder (dodging while
## staggered still applies upstream via the normal fear handling — this path
## only picks where to walk).
func _fetch_boulder_input(player: SimPlayer, sim, prof: Dictionary) -> PlayerInput:
	var pi := PlayerInput.new()
	var best := Vector3.ZERO
	var best_d := INF
	for pos in sim.boulders.idle_positions():
		var d: float = player.global_position.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = pos
	if best_d == INF:
		# Nothing to grab: circle the middle until a boulder respawns.
		best = Vector3.ZERO
	var to_t: Vector3 = best - player.global_position
	to_t.y = 0.0
	if to_t.length() > 0.2:
		var desired: Vector3 = to_t.normalized().rotated(Vector3.UP,
			sin(sim.tick * 0.03 + player.slot * 2.1) * float(prof["wobble"]) * 0.6)
		pi.move = Vector2(desired.x, desired.z).limit_length(1.0)
	return pi


## Floe Dash: chase a point ~25 degrees ahead on the lane; dash for speed when
## recovered and roughly facing along the track.
func _race_input(player: SimPlayer, sim, prof: Dictionary) -> PlayerInput:
	var pi := PlayerInput.new()
	var pos: Vector3 = player.global_position
	var a := atan2(pos.x, pos.z)
	var ahead := a + 0.45
	var lane_r: float = sim.arena_radius * RaceManager.LANE_FRACTION
	var target := Vector3(sin(ahead), 0.0, cos(ahead)) * lane_r
	var to_t: Vector3 = target - pos
	to_t.y = 0.0
	var dir := to_t.normalized()
	var desired: Vector3 = dir.rotated(Vector3.UP,
		sin(sim.tick * 0.05 + player.slot * 2.1) * float(prof["wobble"]) * 0.4)
	pi.move = Vector2(desired.x, desired.z).limit_length(1.0)
	# Dash along the lane for pace (and through anyone in the way).
	if player.recovery_left <= 0.0 and player.stamina >= Tuning.STAMINA_MAX * 0.95 \
			and player.facing.dot(dir) > 0.85:
		pi.charge = true
	return pi


## Puck Panic: hold position in front of my goal arc; intercept the puck with
## the soonest rim-crossing inside my arc, dashing when it's urgent and far.
func _goal_guard_input(player: SimPlayer, sim, prof: Dictionary) -> PlayerInput:
	var pi := PlayerInput.new()
	var n: int = sim.players.size()
	var my_angle := TAU * float(player.slot) / float(n)
	var target_pos: Vector3 = Vector3(sin(my_angle), 0, cos(my_angle)) * sim.arena_radius * 0.72
	var best_eta := INF
	for puck in sim.pucks.puck_list():
		var pos: Vector3 = puck["pos"]
		var vel: Vector3 = puck["vel"]
		pos.y = 0.0
		vel.y = 0.0
		if vel.length_squared() < 0.01:
			continue
		# Solve |pos + vel*t| = R for the rim-crossing time.
		var rim: float = sim.arena_radius - 0.6
		var a := vel.dot(vel)
		var b := 2.0 * pos.dot(vel)
		var c := pos.dot(pos) - rim * rim
		var disc := b * b - 4.0 * a * c
		if disc <= 0.0:
			continue
		var t := (-b + sqrt(disc)) / (2.0 * a)
		if t < 0.0 or t >= best_eta:
			continue
		var hit := pos + vel * t
		if PuckManager.arc_slot_at(atan2(hit.x, hit.z), n) != player.slot:
			continue
		best_eta = t
		target_pos = hit * 0.9
	var to_t: Vector3 = target_pos - player.global_position
	to_t.y = 0.0
	if to_t.length() > 0.3:
		var desired: Vector3 = to_t.normalized().rotated(Vector3.UP,
			sin(sim.tick * 0.03 + player.slot * 2.1) * float(prof["wobble"]) * 0.5)
		pi.move = Vector2(desired.x, desired.z).limit_length(1.0)
		# Dash to make an urgent distant save.
		if best_eta < 1.2 and to_t.length() > 3.0 \
				and player.recovery_left <= 0.0 \
				and player.stamina >= player.stats.stamina_cost:
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
## In the final 30 s, any hit is worth it — desperation prevents two careful
## bots (especially Experts) from dancing to a tie.
func _kill_worthy(dir: Vector3, target: SimPlayer, sim) -> bool:
	if sim.time_left < 30.0:
		return true
	var target_flat: Vector3 = target.global_position
	target_flat.y = 0.0
	if target_flat.length() < sim.arena_radius * 0.5:
		return true
	return dir.dot(target_flat.normalized()) > OUTWARD_DOT_MIN


## Nearest opponent — except experts, who take a modest detour to hunt whoever
## is closest to the edge (most finishable) when that victim is reachable.
func _pick_target(player: SimPlayer, sim, prof: Dictionary) -> SimPlayer:
	var nearest: SimPlayer = null
	var nearest_d := INF
	for p in sim.players:
		if p == player or not p.alive:
			continue
		var d := player.global_position.distance_squared_to(p.global_position)
		if d < nearest_d:
			nearest_d = d
			nearest = p
	if nearest == null or not bool(prof["smart_target"]):
		return nearest
	var best := nearest
	var best_r := _target_radius(nearest)
	var reach := sqrt(nearest_d) * 1.6 # only detour to victims not much farther
	for p in sim.players:
		if p == player or not p.alive:
			continue
		if player.global_position.distance_to(p.global_position) <= reach \
				and _target_radius(p) > best_r:
			best_r = _target_radius(p)
			best = p
	return best
