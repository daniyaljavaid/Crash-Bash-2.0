class_name CharacterStats
extends RefCounted
## Data-driven archetype table. Slots cycle through these until character
## select exists (slot 0 = Balanced, 1 = Heavy, 2 = Bruiser, 3 = Trickster, 4 = Balanced, ...).
##
## push_power    — impulse (m/s) given to the victim of a landed charge.
##                 Slide distance ~= push_power / Tuning.FRICTION_K.
## stamina_cost  — stamina consumed per charge (bar is 100).
## regen_mult    — multiplier on Tuning.STAMINA_REGEN.
## accel_mult    — multiplier on Tuning.MOVE_ACCEL (agility).
## momentum_keep — fraction of charge speed kept when a charge WHIFFS.
##                 High value = overshoot risk (Heavy can slide off the edge).
## recovery      — seconds after a charge ends before the next may start.

const ARCHETYPES: Array[Dictionary] = [
	{
		"name": "Balanced",
		"push_power": 9.0,
		"stamina_cost": 50.0,
		"regen_mult": 1.0,
		"accel_mult": 1.0,
		"momentum_keep": 0.4,
		"recovery": 0.25,
	},
	{
		"name": "Heavy",
		"push_power": 13.0,
		"stamina_cost": 100.0,
		"regen_mult": 0.85,
		"accel_mult": 0.9,
		"momentum_keep": 0.85,
		"recovery": 0.8,
	},
	{
		"name": "Bruiser",
		"push_power": 10.5,
		"stamina_cost": 70.0,
		"regen_mult": 1.0,
		"accel_mult": 0.95,
		"momentum_keep": 0.55,
		"recovery": 0.45,
	},
	{
		"name": "Trickster",
		"push_power": 7.0,
		"stamina_cost": 40.0,
		"regen_mult": 1.35,
		"accel_mult": 1.15,
		"momentum_keep": 0.3,
		"recovery": 0.15,
	},
]


static func for_slot(slot: int) -> Dictionary:
	return ARCHETYPES[slot % ARCHETYPES.size()]
