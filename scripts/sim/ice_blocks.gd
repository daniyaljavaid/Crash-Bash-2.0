class_name IceBlockRing
extends Node3D
## Variant module: a ring of destructible ice blocks around the platform edge.
## Blocks are solid walls — a CHARGING player contact smashes one open; plain
## body contact just bumps. The same node serves both sides of the wire: the
## server simulates and owns the alive-mask, the client mirrors it from
## snapshots via apply_mask().

signal block_destroyed(index: int, at: Vector3)

var alive_mask := 0 # bit i set = block i still standing

var _blocks: Array[StaticBody3D] = []


func build(arena_radius: float) -> void:
	var ring_radius := arena_radius - Tuning.BLOCK_DEPTH * 0.5
	var count := int(TAU * ring_radius / (Tuning.BLOCK_WIDTH + Tuning.BLOCK_GAP))
	count = mini(count, 24) # mask must fit comfortably in an int
	for i in count:
		var angle := TAU * float(i) / float(count)
		var block := StaticBody3D.new()
		block.collision_layer = 1
		block.collision_mask = 0
		block.set_meta("ice_block_index", i)
		block.set_meta("ice_block_ring", self)

		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(Tuning.BLOCK_WIDTH, Tuning.BLOCK_HEIGHT, Tuning.BLOCK_DEPTH)
		shape.shape = box
		block.add_child(shape)

		var mesh_i := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = box.size
		mesh_i.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.62, 0.78, 0.92, 1.0)
		mat.roughness = 0.1
		mesh_i.material_override = mat
		block.add_child(mesh_i)

		block.position = Vector3(sin(angle), 0.0, cos(angle)) * ring_radius \
			+ Vector3(0, Tuning.BLOCK_HEIGHT * 0.5, 0)
		block.rotation.y = angle
		add_child(block)
		_blocks.append(block)
		alive_mask |= 1 << i


## Server/offline: a charging player smashed block `index`.
func smash(index: int) -> void:
	if alive_mask & (1 << index) == 0:
		return
	var at: Vector3 = _blocks[index].global_position
	_remove_block(index)
	print("[sim] ice block %d smashed, %d standing" % [index, _standing_count()])
	block_destroyed.emit(index, at)


func _standing_count() -> int:
	var n := 0
	for i in _blocks.size():
		if alive_mask & (1 << i):
			n += 1
	return n


## Server/offline, melting variant: blocks fall once the platform edge has
## receded past them.
func melt_check(platform_radius: float) -> void:
	for i in _blocks.size():
		if alive_mask & (1 << i) and _blocks[i].position.length() > platform_radius + 0.1:
			smash(i)


## Client: adopt the authoritative mask from a snapshot.
func apply_mask(mask: int) -> void:
	for i in _blocks.size():
		if alive_mask & (1 << i) and mask & (1 << i) == 0:
			var at: Vector3 = _blocks[i].global_position
			_remove_block(i)
			block_destroyed.emit(i, at)


func _remove_block(index: int) -> void:
	alive_mask &= ~(1 << index)
	_blocks[index].visible = false
	_blocks[index].set_deferred("collision_layer", 0)
