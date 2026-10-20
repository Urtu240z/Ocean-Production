extends "res://addons/ocean/physics/water/cpu_fft_water_provider.gd"
## Validation only: integer accumulation, one publication per tick; no metric dictionaries per contact.
const CP3_LABELS = ["callbacks","queries","hits","misses","validation_calls","validation_us","reserved",
	"batches","positions_us","native_bridge_us","fft_native_us","decode_us","areas_us","hull_waves_us",
	"tsunami_us","drift_stamp_us","sample_us","callback_us","native_positions","sample_allocations",
	"local_native_bridge_us","local_native_positions"]
var cp3_totals := PackedInt64Array()
var cp3_active := false
var cp3_trace := false
var cp3_measured := false
var cp3_traces: Array = []
var cp3_prepared := {}
var cp3_vehicle: JetSkiController
var cp3_started := 0

func _init() -> void:
	super()
	cp3_totals.resize(CP3_LABELS.size())

func cp3_begin_arcade(vehicle: JetSkiController) -> void:
	cp3_vehicle = vehicle
	cp3_active = true
	cp3_totals[0] += 1
	cp3_started = Time.get_ticks_usec()

func cp3_end_arcade() -> void:
	cp3_totals[17] += Time.get_ticks_usec()-cp3_started
	cp3_active = false

func cp3_flush() -> PackedInt64Array:
	var result := cp3_totals.duplicate()
	cp3_totals.fill(0)
	return result

func prepare_water_queries(body: Transform3D, points: PackedVector3Array, extra: PackedVector3Array, delta: float) -> void:
	super(body,points,extra,delta)
	if not cp3_trace or _active_consumer == null: return
	cp3_prepared[_active_consumer.get_instance_id()] = {"tick":Engine.get_physics_frames(),"root":body.origin,
		"positions":_contact_positions.duplicate(),"field_time":current_field_time,"field_tick":last_build_tick,
		"mode":query_mode,"backend":backend,"spectrum":_last_fft_spectrum_generation,
		"source_revision":_synced_ocean_revision,"space_revision":_synced_ocean_space_revision,
		"owner":_active_consumer.wave_owner_id,"center":_local_patch_center}

func _is_water_source_current() -> bool:
	if not cp3_active: return super()
	var started := Time.get_ticks_usec()
	var result := super()
	cp3_totals[4] += 1
	cp3_totals[5] += Time.get_ticks_usec()-started
	return result

func cp3_trace_query(point: Vector3) -> Dictionary:
	var context: RefCounted = cp3_vehicle.get("_water_consumer_context")
	var own: Dictionary = cp3_prepared.get(context.get_instance_id(),{}) if context != null else {}
	var same_point_count := 0
	var root: Vector3 = own.get("root",Vector3(INF,INF,INF))
	for prepared_point in own.get("positions",PackedVector3Array()):
		if point == prepared_point: same_point_count += 1
	return {"tick":Engine.get_physics_frames(),"vehicle":str(cp3_vehicle.name),"point":point,
		"own_prepare_tick_age":Engine.get_physics_frames()-int(own.get("tick",-1)),
		"root_equal":point==root,"root_delta":point-root,"prefetched_exact_matches":same_point_count,
		"active_is_own":_active_consumer==context,"active_owner":_active_consumer.wave_owner_id if _active_consumer != null else 0,
		"own_owner":own.get("owner",0),"active_center":_local_patch_center,"own_center":own.get("center",Vector3.ZERO),
		"field_time":current_field_time,"own_field_time":own.get("field_time",-1.0),
		"field_tick_age":Engine.get_physics_frames()-last_build_tick,"own_field_tick_age":Engine.get_physics_frames()-int(own.get("field_tick",-1)),
		"same_backend":backend==own.get("backend",-1),"same_mode":query_mode==own.get("mode",-1),
		"same_spectrum":_last_fft_spectrum_generation==own.get("spectrum",-1),
		"same_source_revision":_synced_ocean_revision==own.get("source_revision",-1),
		"same_space_revision":_synced_ocean_space_revision==own.get("space_revision",-1),
		"cursor":_contact_cache_cursor,"cache_size":_contact_positions.size()}

func sample_water(point: Vector3, output: WaterSample3D = null) -> WaterSample3D:
	if not cp3_active: return super(point,output)
	var trace := cp3_trace_query(point) if cp3_trace and cp3_measured else {}
	var hit := _contact_cache_cursor < _contact_positions.size() and _contact_cache_cursor < _selected_contact_cache.size() and _same_xz(point,_contact_positions[_contact_cache_cursor])
	var started := Time.get_ticks_usec()
	var result := super(point,output)
	cp3_totals[16] += Time.get_ticks_usec()-started
	cp3_totals[1] += 1
	cp3_totals[2 if hit else 3] += 1
	if not trace.is_empty():
		trace["valid"] = result.valid
		trace["sample_time"] = result.sample_time_seconds
		trace["sample_tick_age"] = Engine.get_physics_frames()-result.sample_physics_tick
		cp3_traces.append(trace)
	return result

func _sample_direct_water_batch(positions: PackedVector3Array, selected_backend := -1,
		interpolation_modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	if not cp3_active: return super(positions,selected_backend,interpolation_modes)
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
	cp3_totals[8] += Time.get_ticks_usec()-segment
	segment = Time.get_ticks_usec()
	var packed: PackedFloat64Array = native.call("sample_dynamic_lite_contacts",
		query_positions, sea_level, modes)
	cp3_totals[9] += Time.get_ticks_usec()-segment
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
	cp3_totals[10] += native_us
	cp3_totals[11] += Time.get_ticks_usec()-segment
	cp3_totals[18] += query_positions.size()
	cp3_totals[19] += samples.size()
	_record_query_batch(started, native_us, positions.size(), query_positions.size())
	return samples

func sample_water_batch(positions: PackedVector3Array, selected_backend := -1,
		interpolation_modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	if not cp3_active: return super(positions,selected_backend,interpolation_modes)
	cp3_totals[7] += 1
	var started := Time.get_ticks_usec() if _perf2_supported else 0
	var samples := _perf2_sample_water_batch(positions, selected_backend, interpolation_modes)
	var segment := Time.get_ticks_usec()
	if is_instance_valid(ocean_root) and ocean_root.has_method("get_wave_area_runtime"):
		var areas: RefCounted = ocean_root.get_wave_area_runtime()
		var current_tick := Engine.get_physics_frames()
		var before: Dictionary = areas.metrics.ticks.get(current_tick,{})
		var native_before := Vector2i.ZERO
		var positions_before := Vector2i.ZERO
		for slot in 2:
			native_before += before.get(StringName("slot%d.native_query"%slot),Vector2i.ZERO)
			positions_before += before.get(StringName("slot%d.native_positions"%slot),Vector2i.ZERO)
		areas.apply(samples, positions, wave_time_rate)
		var after: Dictionary = areas.metrics.ticks.get(current_tick,{})
		var native_after := Vector2i.ZERO
		var positions_after := Vector2i.ZERO
		for slot in 2:
			native_after += after.get(StringName("slot%d.native_query"%slot),Vector2i.ZERO)
			positions_after += after.get(StringName("slot%d.native_positions"%slot),Vector2i.ZERO)
		cp3_totals[20] += native_after.y-native_before.y
		cp3_totals[21] += positions_after.x-positions_before.x
	cp3_totals[12] += Time.get_ticks_usec()-segment
	segment = Time.get_ticks_usec()
	# Compose after base-surface history/seams, so branch recovery never stores
	# hull displacement as FFT geometry. Cached reads already contain this overlay.
	if is_instance_valid(ocean_root) and ocean_root.has_method("get_physical_hull_wave_state"):
		var waves: RefCounted = ocean_root.get_physical_hull_wave_state()
		if waves != null:
			waves.apply(samples,positions,ocean_root.get_hull_foam_settings(),
				_active_consumer.wave_owner_id if _active_consumer != null else 0,_local_patch_center)
	cp3_totals[13] += Time.get_ticks_usec()-segment
	segment = Time.get_ticks_usec()
	if is_instance_valid(ocean_root) and ocean_root.has_method("get_boundary_tsunami_state"):
		ocean_root.get_boundary_tsunami_state().apply(samples,positions)
	cp3_totals[14] += Time.get_ticks_usec()-segment
	segment = Time.get_ticks_usec()
	for sample in samples:
		if not sample.valid: continue
		sample.sample_time_seconds = current_field_time
		sample.sample_physics_tick = last_build_tick
		if wave_drift_enabled and wave_drift_strength > 0.0 and wave_drift_max_speed_mps > 0.0:
			sample.velocity += WaveDrift.velocity(sample.normal, sample.velocity.y,
				wave_drift_strength, wave_drift_max_speed_mps)
	cp3_totals[15] += Time.get_ticks_usec()-segment
	_perf2_span(5, started)
	return samples

