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
signal snapshot_received(tick: int, state: int, time_left: float, countdown_left: float, radius: float, block_mask: int, data: PackedFloat32Array, extra: PackedByteArray, acked_seqs: PackedInt32Array)
signal net_eliminated(slot: int, at: Vector3)
signal net_round_over(winner_slot: int, wins: Array)
signal net_block_destroyed(index: int, at: Vector3)
signal net_player_hit(attacker_slot: int, victim_slot: int, at: Vector3)
signal net_player_respawned(slot: int, at: Vector3)
signal net_ball_spawned(id: int, from: Vector3, dir: Vector3)
signal net_ball_gone(id: int, at: Vector3)
signal net_goal_scored(slot: int, lives_left: int, at: Vector3)
signal net_powerup_spawned(id: int, type: int, at: Vector3)
signal net_powerup_collected(id: int, type: int, slot: int)
signal session_ended(reason: String)

enum Mode { OFFLINE, SERVER, CLIENT }

const DEFAULT_PORT := 9050
const SNAPSHOT_EVERY_N_TICKS := 3      # 60 Hz sim -> 20 Hz snapshots
const PLAYER_STRIDE := 9               # x, y, z, rot_y, stamina, flags, visual_scale, vx, vz
const FLAG_ALIVE := 1
const FLAG_CHARGING := 2
const FLAG_FROZEN := 4
const INPUT_STALE_TICKS := 15          # zero a remote input not refreshed for 0.25 s

var mode := Mode.OFFLINE
var dedicated := false                 # SERVER with no local player
var my_slot := -1                      # this machine's player slot in the match
var slot_peers: Array[int] = []        # slot -> peer id (0 = bot, 1 = server/host)
var lobby_peer_ids: Array[int] = []    # human peers in the match roster, join order
var waiting_peer_ids: Array[int] = []  # joined mid-round; merged into the roster next round
var lobby_player_count := 4
var lobby_fill_bots := true
var lobby_variant := 0                 # MatchConfig.Variant, host/leader-chosen
var lobby_wins_target := 3
var lobby_difficulty := 1              # MatchConfig.Difficulty, default Medium
var lobby_minigame := 0                # MatchConfig.Minigame
var lobby_stage := 0                   # per-minigame arena layout
var lobby_team_mode := 0               # MatchConfig.TeamMode

# server-side: peer id -> archetype choice (-1 = auto)
var _peer_archetypes := {}
# server-side: peer id -> look/body-style choice
var _peer_looks := {}
# peer id -> display name (server-side truth, mirrored to clients with lobby)
var peer_names := {}
var autostart_humans := 0              # auto-start once N humans joined (0 = off)
var autonext_seconds := 0              # server: auto-start next round after N s (0 = manual)
var current_port := DEFAULT_PORT
var match_in_progress := false         # replicated to lobby clients ("joining next round")

# server-side: peer id -> {move: Vector2, charge: bool, tick: int}
var latest_inputs := {}

# server-side wins that survive roster changes between rounds. Humans are keyed
# by peer id, bots by "bot<slot>"; MatchConfig.wins (slot-indexed, what the HUD
# shows) is rebuilt from this at every round start.
var _wins_by_identity := {}

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

## use_ws hosts over WebSocket (TCP) so browser builds can connect. Browsers
## cannot use ENet/UDP at all — a server that should accept web players must
## be started with ws=1. Everything else in the stack is transport-agnostic.
func host(port: int, p_dedicated := false, use_ws := false) -> Error:
	var err: Error
	if use_ws:
		var ws := WebSocketMultiplayerPeer.new()
		err = ws.create_server(port)
		if err != OK:
			return err
		multiplayer.multiplayer_peer = ws
		_finish_host_setup(p_dedicated, port)
		return OK
	var peer := ENetMultiplayerPeer.new()
	err = peer.create_server(port, 16)
	if err != OK:
		return err
	multiplayer.multiplayer_peer = peer
	_finish_host_setup(p_dedicated, port)
	return OK


func _finish_host_setup(p_dedicated: bool, port: int) -> void:
	mode = Mode.SERVER
	dedicated = p_dedicated
	current_port = port
	lobby_peer_ids = []
	waiting_peer_ids = []
	_wins_by_identity = {}
	peer_names = {}
	if not dedicated:
		lobby_peer_ids.append(1)
		peer_names[1] = MatchConfig.player_name_local


## Web builds always join over WebSocket (the only transport a browser has);
## desktop can opt in with a ws:// address.
func join(ip: String, port: int) -> Error:
	var err: Error
	if OS.has_feature("web") or ip.begins_with("ws://") or ip.begins_with("wss://"):
		var ws := WebSocketMultiplayerPeer.new()
		var url := ip if ip.begins_with("ws") else "ws://%s:%d" % [ip, port]
		err = ws.create_client(url)
		if err != OK:
			return err
		multiplayer.multiplayer_peer = ws
	else:
		var peer := ENetMultiplayerPeer.new()
		err = peer.create_client(ip, port)
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
	waiting_peer_ids = []
	latest_inputs = {}
	_wins_by_identity = {}
	_peer_archetypes = {}
	_peer_looks = {}
	_round_active = false
	match_in_progress = false
	if reason != "":
		session_ended.emit(reason)


# --- lobby -------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_server():
		return
	if lobby_peer_ids.size() + waiting_peer_ids.size() >= 8:
		multiplayer.multiplayer_peer.disconnect_peer(id)
		return
	if _round_active:
		# Reconnect-safe lobby: joiners during a round wait it out and are
		# merged into the roster when the next round is assembled.
		waiting_peer_ids.append(id)
	else:
		lobby_peer_ids.append(id)
	_broadcast_lobby()


func _on_peer_disconnected(id: int) -> void:
	if not is_server():
		return
	lobby_peer_ids.erase(id)
	waiting_peer_ids.erase(id)
	latest_inputs.erase(id)
	_peer_archetypes.erase(id)
	peer_names.erase(id)
	_broadcast_lobby()
	lobby_updated.emit()


func _on_connected_to_server() -> void:
	_c2s_hello.rpc_id(1, MatchConfig.player_name_local)
	lobby_updated.emit()


@rpc("any_peer", "call_remote", "reliable")
func _c2s_hello(display_name: String) -> void:
	if is_server():
		peer_names[multiplayer.get_remote_sender_id()] = display_name.left(16)
		_broadcast_lobby()


func set_lobby_config(player_count: int, fill_bots: bool, variant: int,
		wins_target := 3, difficulty := 1, minigame := 0, stage := 0,
		team_mode := 0) -> void:
	lobby_player_count = clampi(player_count, 2, 8)
	lobby_fill_bots = fill_bots
	lobby_variant = clampi(variant, 0, MatchConfig.Variant.size() - 1)
	lobby_wins_target = clampi(wins_target, 1, 5)
	lobby_difficulty = clampi(difficulty, 0, MatchConfig.Difficulty.size() - 1)
	lobby_minigame = clampi(minigame, 0, MatchConfig.Minigame.size() - 1)
	lobby_stage = clampi(stage, 0, Stages.count(lobby_minigame) - 1)
	lobby_team_mode = clampi(team_mode, 0, MatchConfig.TeamMode.size() - 1)
	_broadcast_lobby()


## Any peer (including the host) declares which archetype they want.
func set_my_archetype(choice: int) -> void:
	if is_server():
		_peer_archetypes[1] = choice
	else:
		_c2s_set_archetype.rpc_id(1, choice)


@rpc("any_peer", "call_remote", "reliable")
func _c2s_set_archetype(choice: int) -> void:
	if is_server():
		_peer_archetypes[multiplayer.get_remote_sender_id()] = clampi(choice, -1, 3)


func set_my_look(choice: int) -> void:
	if is_server():
		_peer_looks[1] = choice
	else:
		_c2s_set_look.rpc_id(1, choice)


@rpc("any_peer", "call_remote", "reliable")
func _c2s_set_look(choice: int) -> void:
	if is_server():
		_peer_looks[multiplayer.get_remote_sender_id()] = \
			clampi(choice, 0, MatchConfig.LOOK_NAMES.size() - 1)


func _broadcast_lobby() -> void:
	if is_server():
		_s2c_lobby_state.rpc(lobby_peer_ids, waiting_peer_ids,
			lobby_player_count, lobby_fill_bots, lobby_variant, lobby_wins_target,
			lobby_difficulty, lobby_minigame, lobby_stage, lobby_team_mode,
			_round_active, peer_names)
		lobby_updated.emit()
		if autostart_humans > 0 and not _round_active \
				and lobby_peer_ids.size() >= autostart_humans:
			_try_start(leader_peer())


@rpc("authority", "call_remote", "reliable")
func _s2c_lobby_state(peer_ids: Array, waiting_ids: Array, player_count: int,
		fill_bots: bool, variant: int, wins_target: int, difficulty: int,
		minigame: int, stage: int, team_mode: int, in_progress: bool,
		names := {}) -> void:
	peer_names = names
	lobby_peer_ids.assign(peer_ids)
	waiting_peer_ids.assign(waiting_ids)
	lobby_player_count = player_count
	lobby_fill_bots = fill_bots
	lobby_variant = variant
	lobby_wins_target = wins_target
	lobby_difficulty = difficulty
	lobby_minigame = minigame
	lobby_stage = stage
	lobby_team_mode = team_mode
	match_in_progress = in_progress
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
	# Late joiners waiting out the previous round enter the roster here.
	for id in waiting_peer_ids:
		lobby_peer_ids.append(id)
	waiting_peer_ids = []
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
	# A finished trophy match starts standings from scratch.
	for w in _wins_by_identity.values():
		if w >= lobby_wins_target:
			_wins_by_identity = {}
			break
	# Slot-indexed wins for the HUD, rebuilt from identity-keyed history so
	# standings survive players joining/leaving between rounds.
	var wins: Array[int] = []
	var choices: Array[int] = []
	var names: Array = []
	var looks: Array = []
	for slot in count:
		wins.append(_wins_by_identity.get(_slot_identity(slot), 0))
		choices.append(_peer_archetypes.get(slot_peers[slot], -1) if slot_peers[slot] != 0 else -1)
		names.append(peer_names.get(slot_peers[slot], "") if slot_peers[slot] != 0 else "")
		looks.append(_peer_looks.get(slot_peers[slot], 0) if slot_peers[slot] != 0 else 0)
	MatchConfig.slot_names = names
	MatchConfig.wins = wins
	_round_active = true
	match_in_progress = true
	_s2c_match_start.rpc(slot_peers, wins, lobby_variant, lobby_wins_target,
		choices, lobby_difficulty, lobby_minigame, lobby_stage, lobby_team_mode,
		names, looks)
	_apply_match_start(slot_peers, wins, lobby_variant, lobby_wins_target,
		choices, lobby_difficulty, lobby_minigame, lobby_stage, lobby_team_mode,
		names, looks)


func _slot_identity(slot: int) -> String:
	var peer: int = slot_peers[slot]
	return "bot%d" % slot if peer == 0 else "peer%d" % peer


@rpc("authority", "call_remote", "reliable")
func _s2c_match_start(assignments: Array, wins: Array, variant: int,
		wins_target: int, choices: Array, difficulty: int, minigame: int,
		stage: int, team_mode: int, names: Array = [], looks: Array = []) -> void:
	_round_active = true
	_apply_match_start(assignments, wins, variant, wins_target, choices,
		difficulty, minigame, stage, team_mode, names, looks)


func _apply_match_start(assignments: Array, wins: Array, variant: int,
		wins_target: int, choices: Array, difficulty: int, minigame: int,
		stage: int, team_mode: int, names: Array = [], looks: Array = []) -> void:
	MatchConfig.slot_names = names
	MatchConfig.look_choices.assign(looks)
	slot_peers.assign(assignments)
	my_slot = slot_peers.find(multiplayer.get_unique_id())
	match_in_progress = true
	print("[net] match starting: slots=%s my_slot=%d wins=%s variant=%d target=%d choices=%s difficulty=%d game=%d stage=%d" % [
		str(assignments), my_slot, str(wins), variant, wins_target, str(choices), difficulty, minigame, stage])
	MatchConfig.player_count = slot_peers.size()
	MatchConfig.variant = variant as MatchConfig.Variant
	MatchConfig.wins_target = wins_target
	MatchConfig.archetype_choices.assign(choices)
	MatchConfig.difficulty = difficulty as MatchConfig.Difficulty
	MatchConfig.minigame = minigame as MatchConfig.Minigame
	MatchConfig.stage = stage
	MatchConfig.team_mode = team_mode as MatchConfig.TeamMode
	MatchConfig.wins.assign(wins)
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
	# A next round is a fresh match start: roster and slots are recomputed so
	# late joiners get in and departed players drop out.
	_try_start(requester)


## Server-side, called by the arena when the round resolves. Records the win
## against a roster-stable identity and re-opens the lobby for late joiners.
func round_finished_on_server(winner_slot: int) -> void:
	if winner_slot >= 0:
		var winner_team := MatchConfig.team_of(winner_slot)
		for slot in slot_peers.size():
			if slot == winner_slot \
					or (winner_team >= 0 and MatchConfig.team_of(slot) == winner_team):
				var key := _slot_identity(slot)
				_wins_by_identity[key] = _wins_by_identity.get(key, 0) + 1
	_round_active = false
	_broadcast_lobby() # waiting clients learn the round ended
	if autonext_seconds > 0:
		get_tree().create_timer(autonext_seconds).timeout.connect(
			func() -> void: _do_next_round(leader_peer()))


# --- gameplay: input up ------------------------------------------------------

func send_input(seq: int, move: Vector2, charge: bool) -> void:
	_c2s_input.rpc_id(1, seq, move, charge)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _c2s_input(seq: int, move: Vector2, charge: bool) -> void:
	if not is_server():
		return
	latest_inputs[multiplayer.get_remote_sender_id()] = {
		"move": move.limit_length(1.0),
		"charge": charge,
		"seq": seq,
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
		if p.frozen_left > 0.0:
			flags |= FLAG_FROZEN
		data[base + 5] = float(flags)
		data[base + 6] = p.visual_scale
		data[base + 7] = p.velocity.x
		data[base + 8] = p.velocity.z
	# Last input sequence applied per slot — clients rewind/replay from here.
	var acked := PackedInt32Array()
	acked.resize(sim.players.size())
	for i in sim.players.size():
		var peer: int = slot_peers[i] if i < slot_peers.size() else 0
		if peer > 1 and latest_inputs.has(peer):
			acked[i] = latest_inputs[peer].get("seq", 0)
	var mask: int = sim.ice_ring.alive_mask if sim.ice_ring != null else 0
	# `extra` carries mode-specific state: tile ownership bytes in Tile Rush,
	# puck positions/velocities in Puck Panic.
	var extra := PackedByteArray()
	if sim.tile_grid != null:
		extra = sim.tile_grid.owners
	elif sim.pucks != null:
		extra = sim.pucks.encode_pucks()
	elif sim.boulders != null:
		extra = sim.boulders.encode()
	elif sim.race != null:
		extra = sim.race.encode()
	_s2c_snapshot.rpc(sim.tick, sim.state, sim.time_left, sim.countdown_left,
		sim.arena_radius, mask, data, extra, acked)


@rpc("authority", "call_remote", "unreliable_ordered")
func _s2c_snapshot(tick: int, state: int, time_left: float, countdown_left: float,
		radius: float, block_mask: int, data: PackedFloat32Array,
		extra: PackedByteArray, acked_seqs: PackedInt32Array) -> void:
	snapshot_received.emit(tick, state, time_left, countdown_left, radius,
		block_mask, data, extra, acked_seqs)


func broadcast_eliminated(slot: int, at: Vector3) -> void:
	_s2c_eliminated.rpc(slot, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_eliminated(slot: int, at: Vector3) -> void:
	net_eliminated.emit(slot, at)


func broadcast_player_hit(attacker_slot: int, victim_slot: int, at: Vector3) -> void:
	_s2c_player_hit.rpc(attacker_slot, victim_slot, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_player_hit(attacker_slot: int, victim_slot: int, at: Vector3) -> void:
	net_player_hit.emit(attacker_slot, victim_slot, at)


func broadcast_player_respawned(slot: int, at: Vector3) -> void:
	_s2c_player_respawned.rpc(slot, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_player_respawned(slot: int, at: Vector3) -> void:
	net_player_respawned.emit(slot, at)


func broadcast_ball_spawned(id: int, from: Vector3, dir: Vector3) -> void:
	_s2c_ball_spawned.rpc(id, from, dir)


@rpc("authority", "call_remote", "reliable")
func _s2c_ball_spawned(id: int, from: Vector3, dir: Vector3) -> void:
	net_ball_spawned.emit(id, from, dir)


func broadcast_ball_gone(id: int, at: Vector3) -> void:
	_s2c_ball_gone.rpc(id, at)


func broadcast_goal_scored(slot: int, lives_left: int, at: Vector3) -> void:
	_s2c_goal_scored.rpc(slot, lives_left, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_goal_scored(slot: int, lives_left: int, at: Vector3) -> void:
	net_goal_scored.emit(slot, lives_left, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_ball_gone(id: int, at: Vector3) -> void:
	net_ball_gone.emit(id, at)


func broadcast_block_destroyed(index: int, at: Vector3) -> void:
	_s2c_block_destroyed.rpc(index, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_block_destroyed(index: int, at: Vector3) -> void:
	net_block_destroyed.emit(index, at)


func broadcast_powerup_spawned(id: int, type: int, at: Vector3) -> void:
	_s2c_powerup_spawned.rpc(id, type, at)


@rpc("authority", "call_remote", "reliable")
func _s2c_powerup_spawned(id: int, type: int, at: Vector3) -> void:
	net_powerup_spawned.emit(id, type, at)


func broadcast_powerup_collected(id: int, type: int, slot: int) -> void:
	_s2c_powerup_collected.rpc(id, type, slot)


@rpc("authority", "call_remote", "reliable")
func _s2c_powerup_collected(id: int, type: int, slot: int) -> void:
	net_powerup_collected.emit(id, type, slot)


func broadcast_round_over(winner_slot: int, wins: Array) -> void:
	_s2c_round_over.rpc(winner_slot, wins)


@rpc("authority", "call_remote", "reliable")
func _s2c_round_over(winner_slot: int, wins: Array) -> void:
	MatchConfig.wins.assign(wins)
	net_round_over.emit(winner_slot, wins)


# --- labels ------------------------------------------------------------------

func slot_is_human(slot: int) -> bool:
	return slot < slot_peers.size() and slot_peers[slot] != 0
