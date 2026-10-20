extends "res://addons/ocean/physics/water/cpu_fft_water_provider.gd"
## Fixed published fields for the microbenchmark. Sampling, history and overlays
## use production code; metadata freshness/worker scheduling are not benchmarked.
func _is_water_source_current() -> bool: return field_ready and is_instance_valid(native)
func publish_contacts(transform: Transform3D, points: PackedVector3Array) -> void:
	_local_patch_center = transform.origin
	_contact_positions.clear()
	for point in points: _contact_positions.append(transform*point)
	_selected_contact_cache = sample_water_batch(_contact_positions)
	_contact_cache_cursor = 0
	_contact_cache_waiting_for_comparison = false
