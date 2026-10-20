extends "res://addons/ocean/physics/water/cpu_fft_water_provider.gd"
## Exact pre-PERF-CONTACT-1 method, isolated to the validation fixture.
func sample_comparison_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var out := out_sample.reset() if out_sample != null else WaterSample3D.new()
	if not _is_water_source_current(): return out
	if not compare_other_cpu_backend:
		return out
	comparison_calls += 1
	var started := Time.get_ticks_usec()
	if _contact_cache_waiting_for_comparison and _contact_cache_cursor < _contact_positions.size() and _contact_cache_cursor < _comparison_contact_cache.size():
		if _same_xz(world_position, _contact_positions[_contact_cache_cursor]):
			_copy_sample(_comparison_contact_cache[_contact_cache_cursor], out)
			_contact_cache_cursor += 1
			_contact_cache_waiting_for_comparison = false
			return _finish_sample(out, started)
		_contact_cache_waiting_for_comparison = false
	var samples := sample_water_batch(PackedVector3Array([world_position]), _comparison_backend)
	if not samples.is_empty(): _copy_sample(samples[0], out)
	return _finish_sample(out, started)
