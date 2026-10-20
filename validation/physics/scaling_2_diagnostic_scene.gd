extends "res://validation/physics/hull_native_real_scene_profile.gd"
func scaling_span(label: StringName, elapsed_us: int) -> void:
	if measured: runtime.metrics.record(StringName("controller."+label),elapsed_us)
