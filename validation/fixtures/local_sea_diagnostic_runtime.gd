extends "res://addons/ocean/areas/ocean_wave_area_runtime.gd"
## Diagnostic fixture only; FFT dispatch remains active in all combinations.
var local_render := true
var local_physics := true
func apply(samples: Array, positions: PackedVector3Array, rate: float) -> void:
	if local_physics: super.apply(samples,positions,rate)
func shader_parameters() -> Dictionary:
	var parameters := super.shader_parameters()
	if not local_render: parameters[&"wave_area_count"] = 0
	return parameters
func pack_gpu() -> PackedByteArray:
	var bytes := super.pack_gpu()
	if not local_render: bytes.encode_float(0,0.0)
	return bytes
