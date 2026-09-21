extends Node3D

## Temporary P7-only geometry probe. These controls are validation-scene state,
## not part of the public Ocean API.
@export_range(0.0, 10.0, 0.1) var breaker_probe_horizontal_gain := 1.0:
	set(value):
		breaker_probe_horizontal_gain = clampf(value, 0.0, 10.0)
		_apply_probe_gains()

@export_range(0.0, 10.0, 0.1) var breaker_probe_vertical_gain := 1.0:
	set(value):
		breaker_probe_vertical_gain = clampf(value, 0.0, 10.0)
		_apply_probe_gains()

@export_range(-1.0, 7.0, 1.0) var breaker_vdm_validation_phase := -1.0:
	set(value):
		breaker_vdm_validation_phase = clampf(value, -1.0, 7.0)
		_apply_probe_gains()

var _surface: Node

func _ready() -> void:
	_apply_probe_gains()

func _process(_delta: float) -> void:
	if not is_instance_valid(_surface):
		_apply_probe_gains()
	else:
		set_process(false)

func _apply_probe_gains() -> void:
	if not is_inside_tree():
		return
	if not is_instance_valid(_surface):
		var ocean := get_node_or_null(^"P0/Ocean")
		_surface = ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") if ocean != null else null
	if is_instance_valid(_surface) and _surface.has_method(&"_set_breaker_probe_gains"):
		_surface.call(&"_set_breaker_probe_gains", breaker_probe_horizontal_gain, breaker_probe_vertical_gain)
	if is_instance_valid(_surface) and _surface.has_method(&"_set_breaker_vdm_validation_phase"):
		_surface.call(&"_set_breaker_vdm_validation_phase", breaker_vdm_validation_phase)
