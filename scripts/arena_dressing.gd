class_name ArenaDressing
extends Node3D
## Presentation-only arena set dressing: themed enclosures that make each
## minigame read as a real place instead of a disc floating in the void.
## Everything is procedural primitives; skipped entirely on headless servers.

const GOLDEN_ANGLE := 2.399963

const CROWD_COLORS: Array = [
	Color(0.9, 0.3, 0.25), Color(0.25, 0.55, 0.9), Color(0.3, 0.8, 0.4),
	Color(0.95, 0.8, 0.25), Color(0.7, 0.45, 0.85), Color(0.95, 0.55, 0.2)]


static func theme_accent(mg: int) -> Color:
	match mg:
		MatchConfig.Minigame.TILE:
			return Color(1.0, 0.55, 0.3)
		MatchConfig.Minigame.SNOW:
			return Color(0.7, 0.85, 1.0)
		MatchConfig.Minigame.GOAL:
			return Color(0.3, 0.9, 1.0)
		MatchConfig.Minigame.BOULDER:
			return Color(0.4, 1.0, 0.8)
		MatchConfig.Minigame.RACE:
			return Color(1.0, 0.75, 0.2)
		MatchConfig.Minigame.BARRAGE:
			return Color(0.15, 0.95, 0.95)
		_:
			return Color(0.45, 0.7, 1.0)


func build(mg: int, radius: float) -> void:
	match mg:
		MatchConfig.Minigame.SHOVE:
			_totem_ring(radius, 8, theme_accent(mg))
		MatchConfig.Minigame.TILE:
			_courtyard_walls(radius, theme_accent(mg))
		MatchConfig.Minigame.SNOW:
			_pine_forest(radius)
		MatchConfig.Minigame.GOAL:
			_stadium(radius, theme_accent(mg))
		MatchConfig.Minigame.BOULDER:
			_crystal_spires(radius, theme_accent(mg))
		MatchConfig.Minigame.RACE:
			_race_flags(radius)
		MatchConfig.Minigame.BARRAGE:
			# Tech court: corner towers with glowing bands, like a proper arena.
			for i in 4:
				var a := TAU * i / 4.0 + PI / 4.0
				_pillar(Vector3(sin(a), 0, cos(a)) * radius * 1.5, 4.2, 1.1,
					Color(0.28, 0.34, 0.4), theme_accent(mg))


# --- shared pieces -----------------------------------------------------------

func _flat(color: Color, emissive := false, energy := 1.0) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	if emissive:
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = energy
	return mat


func _pillar(pos: Vector3, height: float, width: float, color: Color,
		stripe: Color) -> void:
	var body := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width, height, width)
	body.mesh = mesh
	body.material_override = _flat(color)
	body.position = pos + Vector3(0, height * 0.5 - 2.0, 0)
	add_child(body)
	var band := MeshInstance3D.new()
	var bmesh := BoxMesh.new()
	bmesh.size = Vector3(width * 1.06, 0.28, width * 1.06)
	band.mesh = bmesh
	band.material_override = _flat(stripe, true, 1.4)
	band.position = pos + Vector3(0, height - 2.45, 0)
	add_child(band)


func _pine(pos: Vector3, s: float) -> void:
	var trunk := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 0.14 * s
	tm.bottom_radius = 0.2 * s
	tm.height = 0.8 * s
	trunk.mesh = tm
	trunk.material_override = _flat(Color(0.4, 0.28, 0.2))
	trunk.position = pos + Vector3(0, 0.4 * s - 2.0, 0)
	add_child(trunk)
	for i in 3:
		var cone := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.0
		cm.bottom_radius = (1.1 - i * 0.28) * s
		cm.height = 1.0 * s
		cm.radial_segments = 8
		cone.mesh = cm
		cone.material_override = _flat(Color(0.2, 0.45, 0.3).lightened(i * 0.12))
		cone.position = pos + Vector3(0, (0.9 + i * 0.62) * s - 2.0, 0)
		add_child(cone)


## A tiny spectator: round body, belly, no limbs — reads at distance.
func _spectator(pos: Vector3, color: Color, face_angle: float) -> void:
	var body := MeshInstance3D.new()
	var bm := SphereMesh.new()
	bm.radius = 0.34
	bm.height = 0.62
	bm.radial_segments = 8
	bm.rings = 4
	body.mesh = bm
	body.material_override = _flat(color)
	body.position = pos
	body.rotation.y = face_angle
	add_child(body)
	var belly := MeshInstance3D.new()
	var lm := SphereMesh.new()
	lm.radius = 0.2
	lm.height = 0.36
	lm.radial_segments = 8
	lm.rings = 4
	belly.mesh = lm
	belly.material_override = _flat(Color(0.95, 0.96, 1.0))
	belly.position = pos + Vector3(-sin(face_angle), -0.06, -cos(face_angle)) * 0.18
	add_child(belly)


# --- per-mode enclosures -----------------------------------------------------

func _totem_ring(radius: float, count: int, accent: Color) -> void:
	for i in count:
		var a := TAU * float(i) / count + PI / count
		var pos := Vector3(sin(a), 0, cos(a)) * radius * 1.45
		_pillar(pos, 3.2 + fposmod(i * 0.7, 1.0), 0.9, Color(0.55, 0.68, 0.82), accent)


func _courtyard_walls(radius: float, accent: Color) -> void:
	# Low stone walls just off each side, torch pillars at the corners.
	for i in 4:
		var a := TAU * i / 4.0
		var wall := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(radius * 1.7, 1.1, 0.6)
		wall.mesh = mesh
		wall.material_override = _flat(Color(0.42, 0.4, 0.52))
		wall.position = Vector3(sin(a), 0, cos(a)) * radius * 1.35 + Vector3(0, -1.45, 0)
		wall.rotation.y = a # long axis onto the edge tangent
		add_child(wall)
	for i in 4:
		var a := TAU * i / 4.0 + PI / 4.0
		_pillar(Vector3(sin(a), 0, cos(a)) * radius * 1.6, 3.4, 0.8,
			Color(0.4, 0.38, 0.5), accent)


func _pine_forest(radius: float) -> void:
	for i in 14:
		var a := i * GOLDEN_ANGLE
		var r := radius * (1.35 + 0.5 * fposmod(i * 0.618, 1.0))
		_pine(Vector3(sin(a), 0, cos(a)) * r, 1.6 + fposmod(i * 0.41, 1.0) * 1.4)


func _stadium(radius: float, accent: Color) -> void:
	# Bleacher arcs with a penguin crowd + floodlight posts. Game night.
	for row in 2:
		var bleacher_r := radius * (1.35 + row * 0.16)
		var seats := 14 + row * 4
		for i in seats:
			var a := TAU * float(i) / seats + row * 0.11
			var pos := Vector3(sin(a), -1.1 + row * 0.55, cos(a)) * bleacher_r
			pos.y = -1.1 + row * 0.55
			_spectator(pos, CROWD_COLORS[(i + row) % CROWD_COLORS.size()], a)
	for i in 4:
		var a := TAU * i / 4.0 + PI / 4.0
		var pos := Vector3(sin(a), 0, cos(a)) * radius * 1.7
		_pillar(pos, 5.0, 0.5, Color(0.5, 0.58, 0.68), accent)
		var lamp := MeshInstance3D.new()
		var lm := SphereMesh.new()
		lm.radius = 0.42
		lm.height = 0.84
		lamp.mesh = lm
		lamp.material_override = _flat(Color(1.0, 0.98, 0.9), true, 2.2)
		lamp.position = pos + Vector3(0, 3.2, 0)
		add_child(lamp)


func _crystal_spires(radius: float, accent: Color) -> void:
	for i in 9:
		var a := i * GOLDEN_ANGLE + 0.8
		var r := radius * (1.3 + 0.45 * fposmod(i * 0.37, 1.0))
		var spire := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 0.0
		mesh.bottom_radius = 0.55 + fposmod(i * 0.53, 1.0) * 0.4
		mesh.height = 2.6 + fposmod(i * 0.71, 1.0) * 2.4
		mesh.radial_segments = 5
		spire.mesh = mesh
		var lit := i % 3 == 0
		spire.material_override = _flat(
			accent.darkened(0.2) if lit else Color(0.28, 0.33, 0.4), lit, 0.8)
		spire.position = Vector3(sin(a), mesh.height * 0.5 - 2.2, cos(a)) * 1.0 * r
		spire.position.y = mesh.height * 0.5 - 2.2
		spire.rotation.y = i * 1.3
		add_child(spire)


func _race_flags(radius: float) -> void:
	for i in 10:
		var a := TAU * float(i) / 10.0
		var pos := Vector3(sin(a), 0, cos(a)) * radius * 1.28
		var pole := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.05
		pm.bottom_radius = 0.07
		pm.height = 2.6
		pole.mesh = pm
		pole.material_override = _flat(Color(0.75, 0.78, 0.85))
		pole.position = pos + Vector3(0, 1.3 - 2.0, 0)
		add_child(pole)
		var banner := MeshInstance3D.new()
		var bm := PrismMesh.new()
		bm.size = Vector3(0.75, 0.5, 0.06)
		banner.mesh = bm
		banner.material_override = _flat(
			CROWD_COLORS[i % CROWD_COLORS.size()], true, 0.4)
		banner.rotation.z = -PI * 0.5
		banner.rotation.y = a + PI * 0.5
		banner.position = pos + Vector3(0, 2.25 - 2.0, 0)
		add_child(banner)
