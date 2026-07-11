class_name PlayerController
extends RefCounted
## Input-layer base. One controller per player slot; produces a PlayerInput per
## tick. Human subclasses read devices, bot subclasses read sim state — the
## simulation itself never touches either. In M2 the server swaps human
## controllers for "network controllers" fed by client RPCs.


# `sim` is duck-typed (MatchSim on the server, ClientReplica for client-side
# autopilot) — both expose players/arena_radius/tick/time_left.
func get_player_input(_player: SimPlayer, _sim) -> PlayerInput:
	return PlayerInput.new()
