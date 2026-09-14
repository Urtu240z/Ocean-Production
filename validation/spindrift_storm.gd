extends Node3D
## Visual validation scene: strong wind, existing crest foam, and all spindrift layers.

func _ready() -> void:
	var ocean := get_node_or_null(^"Ocean") as Ocean
	if ocean == null:
		push_error("Spindrift storm scene requires the P0 Ocean node.")
		return
	ocean.spindrift_profile = load("res://validation/profiles/p0_spindrift_profile.tres") as OceanSpindriftProfile
	ocean.spindrift_debug_mode = 5
	ocean.enable_spindrift = true
