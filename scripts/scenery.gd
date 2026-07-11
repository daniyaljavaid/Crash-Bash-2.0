class_name Scenery
extends Node3D
## Presentation-only arctic surroundings: icebergs, drifting floes, snowfall,
## a moon, and aurora ribbons. Built from primitives, positioned
## deterministically (golden-angle spread), animated in _process. No collision,
## no sim impact — skipped entirely on headless servers.

const GOLDEN_ANGLE := 2.399963

var _bobbers: Array[Dictionary] = []   # {node, base_y, phase, spin}
var _auroras: Array[Dictionary] = []   # {node, base_x, phase}
var _t := 0.0


func build(arena_radius: float) -> void:
	var ice_mat := _flat(Color(0.72, 0.83, 0.94))
	ice_mat.roughness = 0.2
	# Faint self-glow so berg faces in shadow read as dark ice, not black voids.
	ice_mat.emission_enabled = true
	ice_mat.emission = Color(0.17, 0.22, 0.33)
	ice_mat.emission_energy_multiplier = 1.0
	var berg_count := 14
	for i in berg_count:
		var angle := i * GOLDEN_ANGLE
		var dist := arena_radius * (1.9 + 2.6 * fposmod(i * 0.618, 1.0))
		var pos := Vector3(sin(angle), 0.0, cos(angle)) * dist
		pos.y = -2.3
		_add_iceberg(i, pos, ice_mat)

	for i in 6:
		var angle := (i + 0.5) * GOLDEN_ANGLE * 1.7
		var dist := arena_radius * (1.6 + 1.8 * fposmod(i * 0.37, 1.0))
		var floe := MeshInstance3D.new()
		var mesh := CylinderMesh.new()
		mesh.top_radius = 1.2 + fposmod(i * 0.71, 1.0) * 1.6
		mesh.bottom_radius = mesh.top_radius + 0.2
		mesh.height = 0.5
		mesh.radial_segments = 7 # chunky, low-poly floe look
		floe.mesh = mesh
		floe.material_override = ice_mat
		floe.position = Vector3(sin(angle), 0.0, cos(angle)) * dist
		floe.position.y = -2.35
		add_child(floe)
		_bobbers.append({"node": floe, "base_y": floe.position.y,
			"phase": i * 1.3, "spin": 0.0})

	_add_moon()
	_add_aurora()
	_add_snow(arena_radius)


func _add_iceberg(index: int, pos: Vector3, mat: StandardMaterial3D) -> void:
	var berg := Node3D.new()
	berg.position = pos
	berg.rotation.y = index * 1.7
	# 2-3 stacked, tilted chunks read as one jagged berg.
	var chunks := 2 + index % 2
	for c in chunks:
		var chunk := MeshInstance3D.new()
		var box := BoxMesh.new()
		var s := 1.6 + fposmod(index * 0.83 + c * 0.47, 1.0) * 2.8
		box.size = Vector3(s, s * (0.8 + 0.5 * (c % 2)), s * 0.85)
		chunk.mesh = box
		chunk.material_override = mat
		chunk.position = Vector3(c * s * 0.35 - s * 0.3, c * s * 0.28, c * s * 0.2)
		chunk.rotation = Vector3(0.12 * c, index * 0.9 + c, 0.1 + 0.15 * c)
		berg.add_child(chunk)
	add_child(berg)
	_bobbers.append({"node": berg, "base_y": pos.y,
		"phase": index * 0.9, "spin": 0.01 + 0.02 * fposmod(index * 0.31, 1.0)})


func _add_moon() -> void:
	var moon := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 9.0
	mesh.height = 18.0
	moon.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.92, 0.94, 0.98)
	mat.emission_enabled = true
	mat.emission = Color(0.85, 0.88, 0.95)
	mat.emission_energy_multiplier = 1.6
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	moon.material_override = mat
	moon.position = Vector3(-95.0, 65.0, -140.0)
	add_child(moon)


func _add_aurora() -> void:
	for i in 3:
		var ribbon := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(120.0 + i * 30.0, 26.0)
		mesh.orientation = PlaneMesh.FACE_Z
		ribbon.mesh = mesh
		var mat := StandardMaterial3D.new()
		var tint: Color = [Color(0.2, 0.9, 0.55), Color(0.25, 0.7, 0.9), Color(0.5, 0.4, 0.9)][i]
		mat.albedo_color = Color(tint.r, tint.g, tint.b, 0.10)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.emission_enabled = true
		mat.emission = tint
		mat.emission_energy_multiplier = 0.7
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		ribbon.material_override = mat
		ribbon.position = Vector3(-30.0 + i * 35.0, 55.0 + i * 9.0, -160.0 - i * 15.0)
		ribbon.rotation = Vector3(0.15, 0.1 * i - 0.1, 0.28 - 0.18 * i)
		add_child(ribbon)
		_auroras.append({"node": ribbon, "base_x": ribbon.position.x, "phase": i * 2.1})


func _add_snow(arena_radius: float) -> void:
	var snow := CPUParticles3D.new()
	snow.amount = 160
	snow.lifetime = 9.0
	snow.preprocess = 9.0 # sky is already snowing on round start
	snow.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	snow.emission_box_extents = Vector3(arena_radius * 2.6, 1.0, arena_radius * 2.6)
	snow.direction = Vector3.DOWN
	snow.spread = 12.0
	snow.gravity = Vector3(0.35, -1.6, 0.0) # slow fall with sideways drift
	snow.initial_velocity_min = 0.4
	snow.initial_velocity_max = 1.1
	var mesh := SphereMesh.new()
	mesh.radius = 0.045
	mesh.height = 0.09
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.97, 1.0)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	snow.mesh = mesh
	snow.position = Vector3(0, 12.0, 0)
	add_child(snow)


func _flat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	return mat


func _process(delta: float) -> void:
	_t += delta
	for b in _bobbers:
		var node: Node3D = b["node"]
		node.position.y = b["base_y"] + sin(_t * 0.4 + b["phase"]) * 0.22
		node.rotation.y += b["spin"] * delta
	for a in _auroras:
		var node: Node3D = a["node"]
		node.position.x = a["base_x"] + sin(_t * 0.13 + a["phase"]) * 8.0
		node.scale.y = 1.0 + sin(_t * 0.21 + a["phase"] * 1.7) * 0.12
