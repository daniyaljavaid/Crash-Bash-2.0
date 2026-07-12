class_name TileGrid
extends Node3D
## Tile Rush minigame module: a square grid clipped to the platform circle.
## Walking over a tile claims it in your color; most tiles at 0:00 wins.
## Serves both sides of the wire — the server claims authoritatively, clients
## mirror ownership from the byte array riding the snapshots.

signal tile_claimed(index: int, slot: int)

const TILE_SIZE := 1.7
const UNOWNED := 255

var owners := PackedByteArray()   # per tile: slot or UNOWNED
var counts: Array[int] = []       # tiles held per slot

var _centers: Array[Vector2] = []
var _meshes: Array[MeshInstance3D] = []
var _index_by_cell := {} # Vector2i grid coord -> tile index
var _unowned_color := Color(0.62, 0.72, 0.85)


func build(arena_radius: float, player_count: int, square := true,
		cover_specs: Array = []) -> void:
	counts = []
	for i in player_count:
		counts.append(0)
	var half := int(arena_radius / TILE_SIZE)
	for gx in range(-half, half + 1):
		for gz in range(-half, half + 1):
			var center := Vector2(gx * TILE_SIZE, gz * TILE_SIZE)
			# Keep tiles that sit fully on the platform (square courtyard fills
			# the corners; legacy circular clip kept for future stage variety).
			if square:
				if maxf(absf(center.x), absf(center.y)) > arena_radius - TILE_SIZE * 0.55:
					continue
			elif center.length() > arena_radius - TILE_SIZE * 0.55:
				continue
			# No tiles underneath stage obstacles — they'd be unclaimable.
			if MatchSim.cover_contains(cover_specs, Vector3(center.x, 0.1, center.y)):
				continue
			var mesh_i := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3(TILE_SIZE * 0.92, 0.08, TILE_SIZE * 0.92)
			mesh_i.mesh = mesh
			var mat := StandardMaterial3D.new()
			mat.albedo_color = _unowned_color
			mat.roughness = 0.3
			mesh_i.material_override = mat
			mesh_i.position = Vector3(center.x, 0.05, center.y)
			add_child(mesh_i)
			_index_by_cell[Vector2i(gx, gz)] = _centers.size()
			_centers.append(center)
			_meshes.append(mesh_i)
			owners.append(UNOWNED)


func tile_count() -> int:
	return _centers.size()


## Server/offline: claim the tile under a player every tick.
func claim_under(player: SimPlayer) -> void:
	var pos := Vector2(player.global_position.x, player.global_position.z)
	var index := _tile_at(pos)
	if index >= 0 and owners[index] != player.slot:
		_set_owner(index, player.slot)
		tile_claimed.emit(index, player.slot)


## Client: adopt authoritative ownership from a snapshot.
func apply_owners(data: PackedByteArray) -> void:
	if data.size() != owners.size():
		return
	for i in owners.size():
		if owners[i] != data[i]:
			_set_owner(i, data[i])


## Winner by tile count; -1 on a tie for first place.
func leader() -> int:
	var best := -1
	var best_n := -1
	var tied := false
	for slot in counts.size():
		if counts[slot] > best_n:
			best_n = counts[slot]
			best = slot
			tied = false
		elif counts[slot] == best_n:
			tied = true
	return -1 if tied or best_n <= 0 else best


func _tile_at(pos: Vector2) -> int:
	var cell := Vector2i(roundi(pos.x / TILE_SIZE), roundi(pos.y / TILE_SIZE))
	return _index_by_cell.get(cell, -1)


func _set_owner(index: int, slot: int) -> void:
	var prev := owners[index]
	if prev != UNOWNED and prev < counts.size():
		counts[prev] -= 1
	owners[index] = slot
	if slot != UNOWNED and slot < counts.size():
		counts[slot] += 1
	var mat := _meshes[index].material_override as StandardMaterial3D
	mat.albedo_color = MatchConfig.PLAYER_COLORS[slot] if slot != UNOWNED else _unowned_color
