class_name WaterInteractionSink3D
extends Node
## Optional medium-side VFX endpoint. Vehicle particles work without any sink.

func is_persistent_foam_enabled() -> bool:
	return false

func is_landing_ripple_enabled() -> bool:
	return false

func submit_foam_stamp(_position: Vector3, _velocity: Vector3,
		_strength: float, _landing: bool) -> void:
	pass
