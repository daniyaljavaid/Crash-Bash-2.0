class_name Stages
extends RefCounted
## Stage definitions: each minigame has four hand-authored arena layouts built
## from the shared pieces — platform size, ring-hole width, and cover presets.
## A stage is data only; MatchSim and ClientReplica both build from it, so the
## two sides always agree.
##
## Keys (all optional): size (radius multiplier), hole (ring inner fraction,
## Floe Dash only), cover (preset name for build_cover).

const DEFS := {
	MatchConfig.Minigame.SHOVE: [
		{"name": "Classic Floe"},
		{"name": "Tight Floe", "size": 0.72},
		{"name": "Pillar Floe", "cover": "pillars3"},
		{"name": "Bumper Floe", "cover": "bumpers6"},
	],
	MatchConfig.Minigame.TILE: [
		{"name": "Courtyard"},
		{"name": "Grand Plaza", "size": 1.25},
		{"name": "The Cross", "cover": "cross"},
		{"name": "Four Posts", "cover": "pillars4"},
	],
	MatchConfig.Minigame.SNOW: [
		{"name": "Snowfield", "cover": "walls5"},
		{"name": "Open Tundra", "size": 1.15},
		{"name": "Wall Maze", "cover": "walls8"},
		{"name": "Bunkers", "cover": "pillars4"},
	],
	MatchConfig.Minigame.GOAL: [
		{"name": "Center Rink"},
		{"name": "Mini Rink", "size": 0.8},
		{"name": "Bumper Rink", "cover": "pillars3"},
		{"name": "Grand Rink", "size": 1.2},
	],
	MatchConfig.Minigame.BOULDER: [
		{"name": "Quarry", "cover": "pillars4"},
		{"name": "Open Pit", "size": 0.9},
		{"name": "Stone Ring", "cover": "pillars6"},
		{"name": "The Canyon", "cover": "walls2long"},
	],
	MatchConfig.Minigame.RACE: [
		{"name": "Dawn Ring"},
		{"name": "Knife Edge", "hole": 0.62},
		{"name": "Boulevard", "hole": 0.3, "size": 1.15},
		{"name": "Chicane Run", "cover": "chicanes3"},
	],
	MatchConfig.Minigame.BARRAGE: [
		{"name": "Center Court"},
		{"name": "Speed Court", "speed": 1.35},
		{"name": "Twin Volley", "balls": 3},
		{"name": "Mini Court", "size": 0.8},
	],
}

const ICE := Color(0.75, 0.86, 0.96)
const ROCK := Color(0.45, 0.5, 0.56)


static func count(mg: int) -> int:
	return DEFS[mg].size()


static func get_def(mg: int, index: int) -> Dictionary:
	var list: Array = DEFS[mg]
	return list[clampi(index, 0, list.size() - 1)]


static func stage_name(mg: int, index: int) -> String:
	return get_def(mg, index)["name"]


## Cover layout presets → obstacle definitions for MatchSim.build_cover.
## Each: {pos, size, rot, color}.
static func cover_defs(preset: String, radius: float) -> Array:
	var out: Array = []
	match preset:
		"walls5":
			for i in 5:
				var a := i * 2.399963
				out.append(_wall(a, radius * 0.55, Vector3(2.6, 1.3, 0.5), a + PI * 0.5, ICE))
		"walls8":
			for i in 8:
				var a := i * TAU / 8.0 + 0.4
				var r := radius * (0.38 if i % 2 == 0 else 0.68)
				out.append(_wall(a, r, Vector3(2.2, 1.3, 0.5), a + PI * 0.5, ICE))
		"walls2long":
			for side in [-1.0, 1.0]:
				out.append({"pos": Vector3(side * radius * 0.35, 0, 0),
					"size": Vector3(0.6, 1.5, radius * 1.1), "rot": 0.0, "color": ROCK})
		"pillars3":
			for i in 3:
				var a := i * TAU / 3.0 + 0.5
				out.append(_wall(a, radius * 0.35, Vector3(1.2, 1.6, 1.2), a, ROCK))
		"pillars4":
			for i in 4:
				var a := i * TAU / 4.0 + 0.6
				out.append(_wall(a, radius * 0.5, Vector3(1.3, 1.7, 1.3), a, ROCK))
		"pillars6":
			for i in 6:
				var a := i * TAU / 6.0
				out.append(_wall(a, radius * 0.55, Vector3(1.2, 1.7, 1.2), a, ROCK))
		"bumpers6":
			for i in 6:
				var a := i * TAU / 6.0 + 0.3
				out.append(_wall(a, radius * 0.5, Vector3(0.9, 0.8, 0.9), a, Color(0.8, 0.9, 1.0)))
		"cross":
			for i in 4:
				var a := i * TAU / 4.0
				out.append(_wall(a, radius * 0.32, Vector3(0.6, 1.3, radius * 0.5), a, ICE))
		"chicanes3":
			# Half-gates on the race lane, alternating inner/outer, forcing weaves.
			for i in 3:
				var a := i * TAU / 3.0 + 1.0
				var lane := radius * 0.725
				var offset := radius * (0.06 if i % 2 == 0 else -0.06)
				out.append(_wall(a, lane + offset, Vector3(2.0, 1.1, 0.45), a + PI * 0.5, ICE))
	return out


static func _wall(angle: float, r: float, size: Vector3, rot: float, color: Color) -> Dictionary:
	return {"pos": Vector3(sin(angle), 0, cos(angle)) * r,
		"size": size, "rot": rot, "color": color}
