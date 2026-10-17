extends WaterInteractionSink3D
## Optional integration only. Neither Ocean nor the standalone vehicle loads it.
## The host supplies the same Ocean instance used by the shared water provider.
var _ocean_root: Node

func configure(ocean_root: Node) -> void:
	_ocean_root = ocean_root

func _current_fft() -> Node:
	return _ocean_root.get_node_or_null("OpenOceanFFT") if is_instance_valid(_ocean_root) else null

func is_persistent_foam_enabled() -> bool:
	var _ocean := _current_fft()
	return is_instance_valid(_ocean) and bool(_ocean.get("persistent_foam_enabled"))

func is_landing_ripple_enabled() -> bool:
	var _ocean := _current_fft()
	return is_instance_valid(_ocean) and bool(_ocean.get("landing_ripples_enabled"))

func submit_foam_stamp(position: Vector3, velocity: Vector3,
		strength: float, landing: bool) -> void:
	var _ocean := _current_fft()
	if is_instance_valid(_ocean):
		_ocean.call("submit_interaction_foam_stamp", position, velocity, strength, landing)
