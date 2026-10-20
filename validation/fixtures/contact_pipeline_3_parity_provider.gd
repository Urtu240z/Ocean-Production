extends "res://addons/ocean/physics/water/cpu_fft_water_provider.gd"
## Replay counters only; no clocks and no query/caching policy changes.
var contact_counts := PackedInt64Array([0,0,0,0])
func sample_water(point: Vector3, output: WaterSample3D = null) -> WaterSample3D:
	var hit := _contact_cache_cursor < _contact_positions.size() and _contact_cache_cursor < _selected_contact_cache.size() and _same_xz(point,_contact_positions[_contact_cache_cursor])
	var result := super(point,output)
	contact_counts[0] += 1
	contact_counts[1 if hit else 2] += 1
	if not result.valid: contact_counts[3] += 1
	return result
