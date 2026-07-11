extends Node
## Autoload "Net". Owns the ENet session and the entire RPC surface: lobby
## membership, match start, client input up, server snapshots + events down.
## The simulation itself stays network-agnostic — on the server, remote
## players are driven by NetworkControllers that read `latest_inputs` here.
##
## Modes:
##   OFFLINE — no peer, M1 local play (default)
##   SERVER  — listen server (host plays slot 0) or dedicated (--server)
##   CLIENT  — renders replicated state, sends inputs

signal lobby_updated
signal match_started
signal arena_reload_requested
signal snapshot_received(tick: int, state: int, time_left: float, countdown_left: float, data: PackedFloat32Array)
signal net_eliminated(slot: int, at: Vector3)
signal net_round_over(winner_slot: int, wins: Array)
signal session_ended(reason: String)

enum Mode { OFFLINE, SERVER, CLIENT }

const DEFAULT_PORT := 9050
const SNAPSHOT_EVERY_N_TICKS := 3      # 60 Hz sim -> 20 Hz snapshots
const PLAYER_STRIDE := 6               # x, y, z, rot_y, stamina, flags
const FLAG_ALIVE := 1
const FLAG_CHARGING := 2
const INPUT_STALE_TICKS := 15          # zero a remote input not refreshed for 0.25 s

var mode := Mode.OFFLINE
var dedicated := false                 # SERVER with no local player
var my_slot := -1                      # this machine's player slot in the match
var slot_peers: Array[int] = []        # slot -> peer id (0 = bot, 1 = server/host)
var lobby_peer_ids: Array[int] = []    # connected human peers, join order (server-side truth)
var lobby_player_count := 4
var lobby_fill_bots := true
var autostart_humans := 0              # dedicated: auto-start once N humans joined (0 = off)

# server-side: peer id -> {move: Vector2, charge: bool, tick: int}
var latest_inputs := {}

var _round_active := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func() -> void: _end_session("Connection failed"))
	multiplayer.server_disconnected.connect(func() -> void: _end_session("Server disconnected"))


func is_online() -> bool:
	return mode != Mode.OFFLINE


func is_server() -> bool:
	return mode == Mode.SERVER


# --- session setup -----------------------------------------------------------

func host(port: int, p_dedicated := false) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, 16)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.SERVER
	dedicated = p_dedicated
	lobby_peer_ids = []
	if not dedicated:
		lobby_peer_ids.append(1)
	return OK


func join(ip: String, port: int) -> Error:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	mode = Mode.CLIENT
	return OK


func leave() -> void:
	_end_session("")


func _end_session(reason: String) -> void:
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	mode = Mode.OFFLINE
	dedicated = false
	my_slot = -1
	slot_peers = []
	lobby_peer_ids = []
	latest_inputs = {}
	_round_active = false
	if reason != "":
		session_ended.emit(reason)


# --- lobby -------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_server():
		return
	if _round_active or lobby_peer_ids.size() >= 8:
		multiplayer.multiplayer_peer.disconnect_peer(id) # reconnect-safe lobby is M3
		return
	lobby_peer_ids.append(id)
	_broadcast_lobby()


func _on_peer_disconnected(id: int) -> void:
	if not is_server():
		return
	lobby_peer_ids.erase(id)
	latest_inputs.erase(id)
	if not _round_active:
		_broadcast_lobby()
	lobby_updated.emit()


func _on_connected_to_server() -> void:
	lobby_updated.emit()


func set_lobby_config(player_count: int, fill_bots: bool) -> void:
	lobby_player_count = clampi(player_count, 2, 8)
	lobby_fill_bots = fill_bots
	_broadcast_lobby()


func _broadcast_lobby() -> void:
	if is_server():
		_s2c_lobby_state.rpc(lobby_peer_ids, lobby_player_count, lobby_fill_bots)
		lobby_updated.emit()
		if autostart_humans > 0 and not _round_active \
				and lobby_peer_ids.size() >= autostart_humans:
			_try_start(leader_peer())


@rpc("authority", "call_remote", "reliable")
func _s2c_lobby_state(peer_ids: Array, player_count: int, fill_bots: bool) -> void:
	lobby_peer_ids.assign(peer_ids)
	lobby_player_count = player_count
	lobby_fill_bots = fill_bots
	lobby_updated.emit()


## The lobby leader: the host on a listen server, the first-joined client on a
## dedicated server. Only the leader can start the match / next round.
func leader_peer() -> int:
	if dedicated:
		return lobby_peer_ids[0] if lobby_peer_ids.size() > 0 else -1
	return 1


func i_am_leader() -> bool:
	return is_online() and multiplayer.get_unique_id() == leader_peer()


func humans_connected() -> int:
	return lobby_peer_ids.size()


# --- match start -------------------------------------------------------------

func request_start() -> void:
	if is_server():
		_try_start(1)
	else:
		_c2s_request_start.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _c2s_request_start() -> void:
	if is_server():
		_try_start(multiplayer.get_remote_sender_id())


func _try_start(requester: int) -> void:
	if requester != leader_peer() or _round_active:
		return
	var humans := lobby_peer_ids.size()
	var count := lobby_player_count
	if not lobby_fill_bots:
		count = clampi(humans, 2, 8)
	if humans == 0 or (not lobby_fill_bots and humans < 2):
		return
	if humans > count:
		count = humans # never lock a connected human out
	slot_peers = []
	for slot in count:
		slot_peers.append(lobby_peer_ids[slot] if slot < humans else 0)
	_round_active = true
	_s2c_match_start.rpc(slot_peers)
	_apply_match_start(slot_peers)


@rpc("authority", "call_remote", "reliable")
func _s2c_match_start(assignments: Array) -> void:
	_round_active = true
	_apply_match_start(assignments)


func _apply_match_start(assignments: Array) -> void:
	slot_peers.assign(assignments)
	my_slot = slot_peers.find(multiplayer.get_unique_id())
	print("[net] match starting: slots=%s my_slot=%d" % [str(assignments), my_slot])
	MatchConfig.player_count = slot_peers.size()
	if MatchConfig.wins.size() != slot_peers.size():
		MatchConfig.wins = []
		for i in slot_peers.size():
			MatchConfig.wins.append(0)
	match_started.emit()
	get_tree().change_scene_to_file("res://scenes/arena.tscn")


# --- next round / end --------------------------------------------------------

func request_next_round() -> void:
	if is_server():
		_do_next_round(1)
	else:
		_c2s_request_next_round.rpc_id(1)


@rpc("any_peer", "call_remote", "reliable")
func _c2s_request_next_round() -> void:
	if is_server():
		_do_next_round(multiplayer.get_remote_sender_id())


func _do_next_round(requester: int) -> void:
	if requester != leader_peer():
		return
	_s2c_reload_arena.rpc()
	arena_reload_requested.emit()


@rpc("authority", "call_remote", "reliable")
func _s2c_reload_arena() -> void:
	arena_reload_requested.emit()


func round_finished_on_server() -> void:
	_round_active = false # lobby stays as-is; leader can trigger the next round


# --- gameplay: input up ------------------------------------------------------

func send_input(move: Vector2, charge: bool) -> void:
	_c2s_input.rpc_id(1, move, charge)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _c2s_input(move: Vector2, charge: bool) -> void:
	if not is_server():
		return
	latest_inputs[multiplayer.get_remote_sender_id()] = {
		"move": move.limit_length(1.0),
		"charge": charge,
		"tick": Engine.get_physics_frames(),
	}


## Called by NetworkController on the server every sim tick.
func input_for_peer(peer_id: int) -> PlayerInput:
	var pi := PlayerInput.new()
	var rec: Dictionary = latest_inputs.get(peer_id, {})
	if rec.is_empty():
		return pi
	if Engine.get_physics_frames() - int(rec["tick"]) > INPUT_STALE_TICKS:
		return pi # peer stopped sending (lag/disconnect): stand still
	pi.move = rec["move"]
	pi.charge = rec["charge"]
	return pi


# --- gameplay: state down ----------------------------------------------------

func broadcast_snapshot(sim: MatchSim) -> void:
	if sim.tick % SNAPSHOT_EVERY_N_TICKS != 0:
		return
	var data := PackedFloat32Array()
	data.resize(sim.players.size() * PLAYER_STRIDE)
	for i in sim.players.size():
		var p := sim.players[i]
		var base := i * PLAYER_STRIDE
		data[base] = p.global_position.x
		data[base + 1] = p.global_position.y
		data[base + 2] = p.global_position.z
		data[base + 3] = p.rotation.y
		data[base + 4] = p.stamina
		var flags := 0
		if p.alive:
			flags |= FLAG_ALIVE
		if p.charging:
			flags |= FLAG_CHARGING
		data[base + 5] = float(flags)
	_s2c_snapshot.rpc(sim.tick, sim.state, sim.time_left, sim.countdown_left, data)


@rpc("authority", "call_remote", "unreliable_ordered")
func _s2c_snapshot(tick: int, state: int, time_left: float, countdown_left: float, data: PackedFloat32Array) -> void:
	snapshot_received.emit(tick, state, time_left, countdown_left, data)


func broadcast_eliminated(slot: int, at: Vector3) -> void:
	_s2c_eliminated.rpc(slot, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_eliminated(slot: int, at: Vector3) -> void:
	net_eliminated.emit(slot, at)


func broadcast_round_over(winner_slot: int, wins: Array) -> void:
	_s2c_round_over.rpc(winner_slot, wins)


@rpc("authority", "call_remote", "reliable")
func _s2c_round_over(winner_slot: int, wins: Array) -> void:
	MatchConfig.wins.assign(wins)
	net_round_over.emit(winner_slot, wins)


# --- labels ------------------------------------------------------------------

func slot_is_human(slot: int) -> bool:
	return slot < slot_peers.size() and slot_peers[slot] != 0
