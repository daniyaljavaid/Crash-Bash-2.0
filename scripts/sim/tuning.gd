extends Node
## Autoload "Tuning". Every gameplay feel constant lives here — tweak and re-run.
## Per-archetype multipliers live in data/character_stats.gd.

# --- Arena ---
const ARENA_RADIUS_SMALL := 7.0            # radius (m) for 2-4 players (14 m diameter)
const ARENA_RADIUS_PER_EXTRA_PLAYER := 0.75 # extra radius per player above 4 (8p => 10 m radius)
const SPAWN_RADIUS_FRACTION := 0.62        # spawn ring as fraction of arena radius
const KILL_Y := -4.0                       # Y of the kill zone below the water

# --- Movement (ice feel) ---
# Velocity model: v += input * MOVE_ACCEL * dt, then v *= exp(-FRICTION_K * dt).
# Emergent top speed = MOVE_ACCEL / FRICTION_K. Lower FRICTION_K = more slide.
const MOVE_ACCEL := 16.0
const FRICTION_K := 2.2
const TURN_SPEED := 10.0                   # facing slerp rate (visual/charge aim)
const GRAVITY := 22.0

# --- Contact ---
const GENTLE_PUSH_ACCEL := 6.0             # m/s^2 applied while bodies touch (non-charge)

# --- Charge attack ---
# Knockback slide distance with exponential friction = impulse / FRICTION_K.
# Heavy push_power 13 => ~5.2 m slide (~1/3 of a 14-20 m arena).
const CHARGE_SPEED := 14.0                 # burst speed during the charge window
const CHARGE_DURATION := 0.3               # seconds the burst lasts
const CHARGE_RECOIL := 2.5                 # attacker's backward speed after landing a hit
const HIT_POP := 2.0                       # small upward velocity on the victim when hit
const HIT_STAGGER := 0.35                  # seconds the victim can't steer after a hit

# --- Stamina ---
const STAMINA_MAX := 100.0
const STAMINA_REGEN := 40.0                # per second (full bar in 2.5 s); archetype multiplies

# --- Round ---
const ROUND_TIME := 90.0
const COUNTDOWN_TIME := 3.0
