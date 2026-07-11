class_name NetworkController
extends PlayerController
## Server-side controller for a remote human: returns the most recent
## PlayerInput received from that peer (zero input when stale). The sim can't
## tell it apart from a local human or a bot.

var peer_id := 0


func _init(p_peer_id: int) -> void:
	peer_id = p_peer_id


func get_player_input(_player: SimPlayer, _sim) -> PlayerInput:
	return Net.input_for_peer(peer_id)
