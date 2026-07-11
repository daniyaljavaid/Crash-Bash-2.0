class_name PlayerInput
extends RefCounted
## Per-player per-tick intent. The ONLY thing that crosses from the input
## layer into the simulation. In M2 this is what clients send to the server.

var move := Vector2.ZERO # x = world +X, y = world +Z (toward camera). Length <= 1.
var charge := false      # charge button held this tick (sim edge-detects)
