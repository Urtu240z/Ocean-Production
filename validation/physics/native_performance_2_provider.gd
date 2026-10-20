extends "res://validation/physics/perf_contact_instrumented_provider.gd"
## Validation-only exclusive pipeline clocks; no production instrumentation.
func _np2_span(label: StringName, started: int) -> void:
	_np2_span_us(label,Time.get_ticks_usec()-started)

func _np2_span_us(label: StringName, value: int) -> void:
	if diagnostic_controller_sink != null:
		diagnostic_controller_sink.call("scaling_span",StringName("pipeline."+label),value)

func _np2_counter(label: StringName, value: int) -> void:
	if diagnostic_controller_sink != null and diagnostic_controller_sink.get("measured"):
		diagnostic_controller_sink.get("runtime").metrics.record(StringName("pipeline."+label),0,value)

func _is_water_source_current() -> bool:
	var before := counts[1]
	var result := super()
	_np2_span_us("source_validation",counts[1]-before)
	return result

func sample_water(position: Vector3, output: WaterSample3D = null) -> WaterSample3D:
	var hit := _contact_cache_cursor < _contact_positions.size() and _contact_cache_cursor < _selected_contact_cache.size() and _same_xz(position,_contact_positions[_contact_cache_cursor])
	var validation_before := counts[1]
	var started := Time.get_ticks_usec()
	var result := super(position,output)
	var elapsed := Time.get_ticks_usec()-started
	_np2_span_us("cache_read_without_validation" if hit else "missed_sample_inclusive",elapsed-(counts[1]-validation_before) if hit else elapsed)
	return result

func _sample_direct_water_batch(positions: PackedVector3Array, selected_backend := -1,
		interpolation_modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	_ensure_tick_metrics()
	var samples: Array[WaterSample3D] = []
	if positions.is_empty() or not _is_water_source_current(): return samples
	var actual_backend := backend if selected_backend < 0 else selected_backend
	if actual_backend == Backend.CPU_LITE_B and query_mode == QueryMode.CONTACT_TRACKED_DISPLACED:
		return _sample_contact_tracked_batch(positions, interpolation_modes)
	var started := Time.get_ticks_usec()
	var segment := started
	var samples_per_position := 5 if water_race_normal_enabled else 1
	var query_positions := PackedVector3Array()
	query_positions.resize(positions.size() * samples_per_position)
	for index in positions.size():
		var point := positions[index]
		var offset := index * samples_per_position
		query_positions[offset] = point
		if samples_per_position == 5:
			query_positions[offset + 1] = point + Vector3(-WATER_RACE_NORMAL_SAMPLE_STEP, 0.0, 0.0)
			query_positions[offset + 2] = point + Vector3(WATER_RACE_NORMAL_SAMPLE_STEP, 0.0, 0.0)
			query_positions[offset + 3] = point + Vector3(0.0, 0.0, -WATER_RACE_NORMAL_SAMPLE_STEP)
			query_positions[offset + 4] = point + Vector3(0.0, 0.0, WATER_RACE_NORMAL_SAMPLE_STEP)
	# Shader phase = world XZ / (authored domain * clipmap scale). Native
	# lattices retain authored domains, so this is that same UV transform.
	# It does not invert the visual horizontal displacement (choppiness).
	for query_index in query_positions.size():
		var q := query_positions[query_index]
		query_positions[query_index] = Vector3(q.x / ocean_horizontal_scale, q.y, q.z / ocean_horizontal_scale)
	var modes := lite_interpolation_modes if interpolation_modes.size() != BAND_COUNT else interpolation_modes
	_np2_span("positions",segment)
	segment = Time.get_ticks_usec()
	var packed: PackedFloat64Array = native.call("sample_dynamic_lite_contacts",
		query_positions, sea_level, modes)
	_np2_span("query_bridge",segment)
	segment = Time.get_ticks_usec()
	const ROW_SIZE := 6
	if packed.size() != 1 + query_positions.size() * ROW_SIZE:
		_record_query_batch(started, int(packed[0]) if not packed.is_empty() else 0,
			positions.size(), query_positions.size())
		return samples
	var native_us := int(packed[0])
	for index in positions.size():
		var sample_index := index * samples_per_position
		var center_offset := 1 + sample_index * ROW_SIZE
		var valid := packed[center_offset] > 0.5
		var center_height := sea_level + (packed[center_offset + 1] - sea_level) * ocean_height_scale
		var center_velocity := packed[center_offset + 2] * ocean_height_scale
		var normal := _ocean_space_normal_to_world(Vector3(
			packed[center_offset + 3], packed[center_offset + 4], packed[center_offset + 5]))
		if samples_per_position == 5:
			var left_offset := center_offset + ROW_SIZE
			var right_offset := center_offset + ROW_SIZE * 2
			var back_offset := center_offset + ROW_SIZE * 3
			var front_offset := center_offset + ROW_SIZE * 4
			valid = valid and packed[left_offset] > 0.5 and packed[right_offset] > 0.5 \
				and packed[back_offset] > 0.5 and packed[front_offset] > 0.5
			if valid:
				# Neighbours were placed in world metres before transforming phase,
				# so horizontal scale is already included in these derivatives.
				var dh_dx := ocean_height_scale * (packed[right_offset + 1] - packed[left_offset + 1]) / (2.0 * WATER_RACE_NORMAL_SAMPLE_STEP)
				var dh_dz := ocean_height_scale * (packed[front_offset + 1] - packed[back_offset + 1]) / (2.0 * WATER_RACE_NORMAL_SAMPLE_STEP)
				normal = Vector3(-dh_dx, 1.0, -dh_dz).normalized()
		var sample := WaterSample3D.new()
		if valid and normal.is_finite() and is_finite(center_height) and is_finite(center_velocity):
			var point := positions[index]
			sample.valid = true
			sample.surface_position = Vector3(point.x, center_height, point.z)
			sample.signed_depth = center_height - point.y
			sample.velocity = Vector3(0.0, center_velocity * wave_time_rate, 0.0)
			sample.normal = normal
			sample.provider = self
		else:
			invalid_sample_count += 1
		samples.append(sample)
	_np2_span("decode_samples",segment)
	_np2_span_us("fft_native",native_us)
	_np2_counter("direct_contacts",positions.size())
	_np2_counter("fft_positions",query_positions.size())
	_record_query_batch(started, native_us, positions.size(), query_positions.size())
	return samples

func _perf2_sample_water_batch(positions: PackedVector3Array, selected_backend: int,
		interpolation_modes: PackedInt32Array) -> Array[WaterSample3D]:
	if positions.is_empty() or not _is_water_source_current(): return []
	var actual_backend := backend if selected_backend < 0 else selected_backend
	var samples: Array[WaterSample3D]
	_local_geometry_rows = PackedFloat64Array()
	if actual_backend == Backend.CPU_LITE_B and query_mode == QueryMode.LOCAL_SURFACE:
		samples = _sample_choppy_contacts(positions, interpolation_modes)
	else:
		samples = _sample_direct_water_batch(positions, selected_backend, interpolation_modes)
	if actual_backend == backend and _is_contact_prefetch(positions) and query_mode in [QueryMode.DIRECT, QueryMode.LOCAL_SURFACE]:
		if query_mode == QueryMode.LOCAL_SURFACE: local_surface_contact_query_us = local_surface_last_query_us
		var publication_started := Time.get_ticks_usec()
		samples = _local_contacts.publish(samples, positions, _local_geometry_rows, current_field_time, _contact_delta_s)
		_np2_span("publication",publication_started)
	return samples

func sample_water_batch(positions: PackedVector3Array, selected_backend := -1,
		interpolation_modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	_np2_counter("batches",1)
	var started := Time.get_ticks_usec() if _perf2_supported else 0
	var samples := _perf2_sample_water_batch(positions, selected_backend, interpolation_modes)
	var segment := Time.get_ticks_usec()
	if is_instance_valid(ocean_root) and ocean_root.has_method("get_wave_area_runtime"):
		var areas: RefCounted = ocean_root.get_wave_area_runtime()
		areas.apply(samples, positions, wave_time_rate)
	_np2_span("areas_inclusive",segment)
	segment = Time.get_ticks_usec()
	# Compose after base-surface history/seams, so branch recovery never stores
	# hull displacement as FFT geometry. Cached reads already contain this overlay.
	if is_instance_valid(ocean_root) and ocean_root.has_method("get_physical_hull_wave_state"):
		var waves: RefCounted = ocean_root.get_physical_hull_wave_state()
		if waves != null:
			var native_before: int = waves.query_us
			waves.apply(samples,positions,ocean_root.get_hull_foam_settings(),
				_active_consumer.wave_owner_id if _active_consumer != null else 0,_local_patch_center)
			_np2_span_us("hull_waves_native_bridge",waves.query_us-native_before)
	_np2_span("hull_waves",segment)
	segment = Time.get_ticks_usec()
	if is_instance_valid(ocean_root) and ocean_root.has_method("get_boundary_tsunami_state"):
		ocean_root.get_boundary_tsunami_state().apply(samples,positions)
	_np2_span("tsunami",segment)
	segment = Time.get_ticks_usec()
	for sample in samples:
		if not sample.valid: continue
		sample.sample_time_seconds = current_field_time
		sample.sample_physics_tick = last_build_tick
		if wave_drift_enabled and wave_drift_strength > 0.0 and wave_drift_max_speed_mps > 0.0:
			sample.velocity += WaveDrift.velocity(sample.normal, sample.velocity.y,
				wave_drift_strength, wave_drift_max_speed_mps)
	_np2_span("drift_and_stamp",segment)
	_perf2_span(5, started)
	return samples

