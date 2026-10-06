extends WaterSurfaceProvider3D
## Synchronous open-ocean CPU provider for Jetski backend validation.
## A single native field is shared by every consumer; it is rebuilt at most
## once per physics frame, then any number of contacts sample the published grid.
enum Backend { FULL_CPU, CPU_LITE_B }

const NORMAL_EPSILON := 0.01
const BAND_COUNT := 3

@export_enum("Full CPU reference", "CPU Lite B (128/128/64)") var backend: int = Backend.CPU_LITE_B
@export var compare_other_cpu_backend := false

var fft: Node
var native: Object
var lite_resolutions := PackedInt32Array([128, 128, 64])
## Per-band interpolation mode: 0=periodic bilinear, 1=periodic Catmull-Rom cubic.
var lite_interpolation_modes := PackedInt32Array([0, 0, 0])
var sea_level := 0.0
var wave_time_rate := 1.0
## Test harness override for deterministic fixed-step wave clocks; -1 uses FFT runtime scale.
var wave_time_rate_override := -1.0
var field_ready := false
var current_field_time := -1.0
var last_build_tick := -1
var field_update_us := 0
var selected_field_update_us := 0
var comparison_field_update_us := 0
var field_update_count := 0
var field_update_failures := 0
var field_update_samples_us := PackedInt64Array()
var _field_update_sample_count := 0
var selected_update_samples_us := PackedInt64Array()
var comparison_update_samples_us := PackedInt64Array()
var sample_calls := 0
var sample_total_us := 0
var sample_max_us := 0
var sample_samples_us := PackedInt64Array()
var comparison_calls := 0
var comparison_rows: Array[Dictionary] = []
var _comparison_backend := Backend.FULL_CPU
var _contact_positions := PackedVector3Array()
var _selected_contact_cache: Array[WaterSample3D] = []
var _comparison_contact_cache: Array[WaterSample3D] = []
var _contact_cache_cursor := 0
var _contact_cache_waiting_for_comparison := false
var contact_query_batch_count := 0
var contact_query_count := 0
var contact_query_wall_us := 0
var contact_query_native_us := 0
var contact_query_provider_overhead_us := 0
var contact_query_max_batch := 0
var last_contact_query_wall_us := 0
var last_contact_query_native_us := 0
var capture_contact_trace := false
var trace_scenario := ""
var contact_trace_rows: Array[Dictionary] = []

func _init() -> void:
	field_update_samples_us.resize(20000)
	selected_update_samples_us.resize(20000)
	comparison_update_samples_us.resize(20000)
	sample_samples_us.resize(200000)

func configure(ocean: Node, selected_backend: int = Backend.CPU_LITE_B, compare_backends := false) -> bool:
	fft = ocean.get_node_or_null("OpenOceanFFT")
	sea_level = float(ocean.get("sea_level"))
	backend = selected_backend
	compare_other_cpu_backend = compare_backends
	_comparison_backend = Backend.FULL_CPU if backend == Backend.CPU_LITE_B else Backend.CPU_LITE_B
	if fft == null or not ClassDB.class_exists("OceanQueryNative"):
		push_error("CPU water provider requires OpenOceanFFT and OceanQueryNative")
		return false
	native = ClassDB.instantiate("OceanQueryNative")
	if native == null:
		push_error("Could not instantiate OceanQueryNative")
		return false
	native.call("set_sea_level", sea_level)
	var snapshots: Array = fft.call("get_phys2_band_spectrum_snapshots")
	if snapshots.size() != BAND_COUNT or not bool(native.call("set_production_spectrum", snapshots)):
		push_error("CPU water provider could not import the current Production spectrum")
		return false
	field_ready = _build_fields(float(fft.call("get_wave_time")))
	return field_ready

## Selects a manual A/B field without replacing the provider or disturbing the craft.
## The next physics contact phase rebuilds the field at that tick's authoritative ocean time.
func set_manual_candidate(candidate: int) -> bool:
	if candidate == 0:
		backend = Backend.FULL_CPU
		lite_resolutions = PackedInt32Array([128, 128, 64])
		lite_interpolation_modes = PackedInt32Array([0, 0, 0])
	elif candidate == 1:
		backend = Backend.CPU_LITE_B
		lite_resolutions = PackedInt32Array([256, 128, 64])
		lite_interpolation_modes = PackedInt32Array([0, 0, 0])
	elif candidate == 2:
		backend = Backend.CPU_LITE_B
		lite_resolutions = PackedInt32Array([256, 128, 128])
		lite_interpolation_modes = PackedInt32Array([0, 0, 0])
	elif candidate == 3:
		backend = Backend.CPU_LITE_B
		lite_resolutions = PackedInt32Array([128, 128, 128])
		lite_interpolation_modes = PackedInt32Array([1, 1, 1])
	else:
		return false
	last_build_tick = -1
	return true

func get_manual_candidate_name() -> String:
	if backend == Backend.FULL_CPU: return "FULL CPU"
	if lite_resolutions == PackedInt32Array([256, 128, 64]): return "LITE B+LONG 256/128/64"
	if lite_resolutions == PackedInt32Array([256, 128, 128]): return "LITE LONG+SHORT 256/128/128"
	if lite_resolutions == PackedInt32Array([128, 128, 128]) and lite_interpolation_modes == PackedInt32Array([1, 1, 1]):
		return "LITE 128/128/128 CUBIC"
	return "LITE %d/%d/%d" % [lite_resolutions[0], lite_resolutions[1], lite_resolutions[2]]

func begin_contacts(body_transform: Transform3D, local_points: PackedVector3Array) -> void:
	if not field_ready or fft == null: return
	wave_time_rate = wave_time_rate_override if wave_time_rate_override >= 0.0 else float(fft.call("get_simulation_time_scale"))
	var tick := Engine.get_physics_frames()
	if tick != last_build_tick and not _build_fields(float(fft.call("get_wave_time"))): return
	_contact_positions.clear()
	for local_point in local_points: _contact_positions.append(body_transform * local_point)
	_selected_contact_cache = sample_water_batch(_contact_positions, backend)
	_comparison_contact_cache.clear()
	if compare_other_cpu_backend:
		_comparison_contact_cache = sample_water_batch(_contact_positions, _comparison_backend)
	_contact_cache_cursor = 0
	_contact_cache_waiting_for_comparison = false

func _build_fields(wave_time: float) -> bool:
	if native == null or not is_finite(wave_time):
		field_ready = false
		return false
	var started := Time.get_ticks_usec()
	var selected_started := Time.get_ticks_usec()
	var primary_ok := _build_backend(backend, wave_time)
	selected_field_update_us = Time.get_ticks_usec() - selected_started
	var comparison_ok := true
	if compare_other_cpu_backend:
		var comparison_started := Time.get_ticks_usec()
		comparison_ok = _build_backend(_comparison_backend, wave_time)
		comparison_field_update_us = Time.get_ticks_usec() - comparison_started
	else:
		comparison_field_update_us = 0
	field_update_us = Time.get_ticks_usec() - started
	field_update_count += 1
	if _field_update_sample_count < field_update_samples_us.size():
		field_update_samples_us[_field_update_sample_count] = field_update_us
		selected_update_samples_us[_field_update_sample_count] = selected_field_update_us
		comparison_update_samples_us[_field_update_sample_count] = comparison_field_update_us
		_field_update_sample_count += 1
	last_build_tick = Engine.get_physics_frames()
	current_field_time = wave_time
	field_ready = primary_ok and comparison_ok
	if not field_ready: field_update_failures += 1
	return field_ready

func _build_backend(selected: int, wave_time: float) -> bool:
	if selected == Backend.CPU_LITE_B:
		return bool(native.call("build_dynamic_physics_lite", wave_time, lite_resolutions))
	return bool(native.call("build_dynamic_physics_fields", wave_time))

func has_usable_contacts() -> bool:
	# Synchronous fields never use an age-based drop rule. A failed native build
	# is surfaced as invalid and counted; otherwise the current tick is usable.
	return field_ready and current_field_time >= 0.0

func sample_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var out := out_sample.reset() if out_sample != null else WaterSample3D.new()
	var started := Time.get_ticks_usec()
	if _contact_cache_cursor < _contact_positions.size() and _contact_cache_cursor < _selected_contact_cache.size() and _same_xz(world_position, _contact_positions[_contact_cache_cursor]):
		_copy_sample(_selected_contact_cache[_contact_cache_cursor], out)
		if compare_other_cpu_backend and out.valid:
			_contact_cache_waiting_for_comparison = true
		else:
			_contact_cache_cursor += 1
		return _finish_sample(out, started)
	var samples := sample_water_batch(PackedVector3Array([world_position]), backend)
	if not samples.is_empty(): _copy_sample(samples[0], out)
	return _finish_sample(out, started)

func sample_comparison_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var out := out_sample.reset() if out_sample != null else WaterSample3D.new()
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

## Optional batched query used by the contact prefetch and scaling runner.
## Keeps WaterSurfaceProvider3D's per-point interface intact for vehicle code.
func sample_water_batch(positions: PackedVector3Array, selected_backend := -1,
		interpolation_modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	var actual_backend := backend if selected_backend < 0 else selected_backend
	var samples: Array[WaterSample3D] = []
	if positions.is_empty() or not field_ready or native == null: return samples
	var started := Time.get_ticks_usec()
	var native_us := 0
	if actual_backend == Backend.CPU_LITE_B:
		var modes := lite_interpolation_modes if interpolation_modes.size() != BAND_COUNT else interpolation_modes
		var packed: PackedFloat64Array = native.call("sample_dynamic_lite_contacts", positions, sea_level, modes)
		if packed.size() != 1 + positions.size() * 6: return samples
		native_us = int(packed[0])
		for index in positions.size():
			var offset := 1 + index * 6
			var sample := WaterSample3D.new()
			if packed[offset] > 0.5:
				var point := positions[index]
				sample.valid = true
				sample.surface_position = Vector3(point.x, packed[offset + 1], point.z)
				sample.signed_depth = packed[offset + 1] - point.y
				sample.velocity = Vector3(0.0, packed[offset + 2] * wave_time_rate, 0.0)
				sample.normal = Vector3(packed[offset + 3], packed[offset + 4], packed[offset + 5])
				sample.provider = self
			samples.append(sample)
	else:
		# Preserve the Full CPU reference's 1 cm centered finite-difference normal.
		var query_positions := PackedVector3Array()
		query_positions.resize(positions.size() * 5)
		for index in positions.size():
			var point := positions[index]
			var offset := index * 5
			query_positions[offset] = point
			query_positions[offset + 1] = point + Vector3(NORMAL_EPSILON, 0.0, 0.0)
			query_positions[offset + 2] = point - Vector3(NORMAL_EPSILON, 0.0, 0.0)
			query_positions[offset + 3] = point + Vector3(0.0, 0.0, NORMAL_EPSILON)
			query_positions[offset + 4] = point - Vector3(0.0, 0.0, NORMAL_EPSILON)
		var packed: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", query_positions)
		const full_stride := 15
		if packed.size() != query_positions.size() * full_stride: return samples
		native_us = Time.get_ticks_usec() - started
		for index in positions.size():
			var offset := index * 5 * full_stride
			var center_height := packed[offset + 1] - sea_level
			var dhx := ((packed[offset + full_stride + 1] - sea_level) -
				(packed[offset + 2 * full_stride + 1] - sea_level)) / (2.0 * NORMAL_EPSILON)
			var dhz := ((packed[offset + 3 * full_stride + 1] - sea_level) -
				(packed[offset + 4 * full_stride + 1] - sea_level)) / (2.0 * NORMAL_EPSILON)
			var sample := WaterSample3D.new()
			var point := positions[index]
			var surface_y := sea_level + center_height
			sample.valid = packed[offset] > 0.5
			sample.surface_position = Vector3(point.x, surface_y, point.z)
			sample.signed_depth = surface_y - point.y
			sample.velocity = Vector3(0.0, packed[offset + 9] * wave_time_rate, 0.0)
			sample.normal = Vector3(-dhx, 1.0, -dhz).normalized()
			sample.provider = self
			samples.append(sample)
	var wall_us := Time.get_ticks_usec() - started
	contact_query_batch_count += 1
	contact_query_count += positions.size()
	contact_query_wall_us += wall_us
	contact_query_native_us += native_us
	contact_query_provider_overhead_us += maxi(0, wall_us - native_us)
	contact_query_max_batch = maxi(contact_query_max_batch, positions.size())
	last_contact_query_wall_us = wall_us
	last_contact_query_native_us = native_us
	return samples

func _same_xz(a: Vector3, b: Vector3) -> bool:
	return Vector2(a.x, a.z).distance_squared_to(Vector2(b.x, b.z)) <= 0.00000001

func _copy_sample(source: WaterSample3D, target: WaterSample3D) -> void:
	if source == null: return
	target.valid = source.valid
	target.surface_position = source.surface_position
	target.normal = source.normal
	target.velocity = source.velocity
	target.signed_depth = source.signed_depth
	target.provider = self

func _sample_backend(selected: int, world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var out := out_sample.reset() if out_sample != null else WaterSample3D.new()
	if not field_ready or native == null or not world_position.is_finite(): return out
	var started := Time.get_ticks_usec()
	var center := _height_velocity(selected, world_position.x, world_position.z)
	if not bool(center.valid):
		return _finish_sample(out, started)
	var hx_plus := _height_velocity(selected, world_position.x + NORMAL_EPSILON, world_position.z)
	var hx_minus := _height_velocity(selected, world_position.x - NORMAL_EPSILON, world_position.z)
	var hz_plus := _height_velocity(selected, world_position.x, world_position.z + NORMAL_EPSILON)
	var hz_minus := _height_velocity(selected, world_position.x, world_position.z - NORMAL_EPSILON)
	if not bool(hx_plus.valid and hx_minus.valid and hz_plus.valid and hz_minus.valid):
		return _finish_sample(out, started)
	var dhx := (float(hx_plus.height) - float(hx_minus.height)) / (2.0 * NORMAL_EPSILON)
	var dhz := (float(hz_plus.height) - float(hz_minus.height)) / (2.0 * NORMAL_EPSILON)
	var normal := Vector3(-dhx, 1.0, -dhz).normalized()
	var surface_y := sea_level + float(center.height)
	var vy := float(center.vertical_velocity) * wave_time_rate
	if not is_finite(surface_y) or not is_finite(vy) or not normal.is_finite():
		return _finish_sample(out, started)
	out.valid = true
	out.surface_position = Vector3(world_position.x, surface_y, world_position.z)
	out.signed_depth = surface_y - world_position.y
	out.normal = normal
	out.velocity = Vector3(0.0, vy, 0.0)
	out.provider = self
	return _finish_sample(out, started)

func _finish_sample(out: WaterSample3D, started_usec: int) -> WaterSample3D:
	var elapsed := Time.get_ticks_usec() - started_usec
	sample_calls += 1
	sample_total_us += elapsed
	sample_max_us = maxi(sample_max_us, elapsed)
	if sample_calls <= sample_samples_us.size(): sample_samples_us[sample_calls - 1] = elapsed
	return out

func _height_velocity(selected: int, x: float, z: float) -> Dictionary:
	if selected == Backend.FULL_CPU:
		var values: PackedFloat64Array = native.call("sample_dynamic_material_q", x, z)
		if values.size() < 11: return {"valid": false}
		# This field's q is world XZ, and physical horizontal displacement is zero.
		return {"valid": true, "height": values[1] - sea_level, "vertical_velocity": values[9]}
	var height := 0.0
	var vertical_velocity := 0.0
	for band in BAND_COUNT:
		var values: PackedFloat64Array = native.call("sample_dynamic_lite_surface", band, x, z, 0.0)
		if values.size() != 5: return {"valid": false}
		height += values[0]
		vertical_velocity += values[1]
	return {"valid": true, "height": height, "vertical_velocity": vertical_velocity}

func record_contact_comparison(contact_index: int, world_position: Vector3,
		selected_sample: WaterSample3D, alternate_sample: WaterSample3D,
		selected_support_force: float, alternate_support_force: float) -> void:
	if not compare_other_cpu_backend or not selected_sample.valid or not alternate_sample.valid: return
	if comparison_rows.size() >= 200000: return
	comparison_rows.append({
		"tick": Engine.get_physics_frames(), "time": current_field_time, "contact": contact_index,
		"sample_kind": "propulsion_point" if contact_index == 4 else "buoyancy_contact",
		"world_xz": [world_position.x, world_position.z],
		"selected_backend": "CPU_LITE_B" if backend == Backend.CPU_LITE_B else "FULL_CPU",
		"comparison_backend": "FULL_CPU" if _comparison_backend == Backend.FULL_CPU else "CPU_LITE_B",
		"selected_sample": {"height_m": selected_sample.surface_position.y,
			"normal": [selected_sample.normal.x, selected_sample.normal.y, selected_sample.normal.z],
			"vertical_velocity_mps": selected_sample.velocity.y, "signed_depth_m": selected_sample.signed_depth,
			"support_force_n": selected_support_force},
		"comparison_sample": {"height_m": alternate_sample.surface_position.y,
			"normal": [alternate_sample.normal.x, alternate_sample.normal.y, alternate_sample.normal.z],
			"vertical_velocity_mps": alternate_sample.velocity.y, "signed_depth_m": alternate_sample.signed_depth,
			"support_force_n": alternate_support_force},
		"selected_wet": selected_sample.signed_depth > 0.0,
		"comparison_wet": alternate_sample.signed_depth > 0.0,
		"height_delta_m": selected_sample.surface_position.y - alternate_sample.surface_position.y,
		"normal_delta_degrees": rad_to_deg(selected_sample.normal.angle_to(alternate_sample.normal)),
		"vertical_velocity_delta_mps": selected_sample.velocity.y - alternate_sample.velocity.y,
		"signed_depth_delta_m": selected_sample.signed_depth - alternate_sample.signed_depth,
		"support_force_delta_n": selected_support_force - alternate_support_force,
	})

func record_contact_trace(contact_index: int, world_position: Vector3, contact_velocity: Vector3,
		body_transform: Transform3D, body_linear_velocity: Vector3, body_angular_velocity: Vector3,
		water_sample: WaterSample3D) -> void:
	if not capture_contact_trace or water_sample == null or not water_sample.valid or contact_trace_rows.size() >= 200000: return
	var basis := body_transform.basis
	contact_trace_rows.append({
		"scenario": trace_scenario, "tick": Engine.get_physics_frames(), "simulation_time": current_field_time,
		"contact": contact_index, "world_position": [world_position.x, world_position.y, world_position.z],
		"contact_velocity": [contact_velocity.x, contact_velocity.y, contact_velocity.z],
		"body_origin": [body_transform.origin.x, body_transform.origin.y, body_transform.origin.z],
		"body_basis": [[basis.x.x, basis.x.y, basis.x.z], [basis.y.x, basis.y.y, basis.y.z], [basis.z.x, basis.z.y, basis.z.z]],
		"body_linear_velocity": [body_linear_velocity.x, body_linear_velocity.y, body_linear_velocity.z],
		"body_angular_velocity": [body_angular_velocity.x, body_angular_velocity.y, body_angular_velocity.z],
		"full_sample": {"surface_y": water_sample.surface_position.y,
			"normal": [water_sample.normal.x, water_sample.normal.y, water_sample.normal.z],
			"vertical_velocity": water_sample.velocity.y, "signed_depth": water_sample.signed_depth},
	})

func reset_comparison_metrics() -> void:
	comparison_rows.clear()
	comparison_calls = 0

func reset_sample_metrics() -> void:
	sample_calls = 0
	sample_total_us = 0
	sample_max_us = 0
	contact_query_batch_count = 0
	contact_query_count = 0
	contact_query_wall_us = 0
	contact_query_native_us = 0
	contact_query_provider_overhead_us = 0
	contact_query_max_batch = 0

func get_provider_profile() -> Dictionary:
	var updates := PackedInt64Array()
	updates.resize(_field_update_sample_count)
	for i in _field_update_sample_count: updates[i] = field_update_samples_us[i]
	var sorted_updates := updates.duplicate()
	sorted_updates.sort()
	var selected_updates := PackedInt64Array()
	var comparison_updates := PackedInt64Array()
	selected_updates.resize(_field_update_sample_count)
	comparison_updates.resize(_field_update_sample_count)
	for i in _field_update_sample_count:
		selected_updates[i] = selected_update_samples_us[i]
		comparison_updates[i] = comparison_update_samples_us[i]
	selected_updates.sort(); comparison_updates.sort()
	var samples := PackedInt64Array()
	var sample_count := mini(sample_calls, sample_samples_us.size())
	samples.resize(sample_count)
	for i in sample_count: samples[i] = sample_samples_us[i]
	samples.sort()
	return {"backend": "CPU_LITE_B" if backend == Backend.CPU_LITE_B else "FULL_CPU",
		"comparison_backend": "FULL_CPU" if _comparison_backend == Backend.FULL_CPU else "CPU_LITE_B",
		"ready": field_ready, "field_time": current_field_time, "field_update_us": field_update_us,
		"field_update_count": field_update_count, "field_update_failures": field_update_failures,
		"field_update_p95_us": _percentile(sorted_updates, 0.95), "field_update_p99_us": _percentile(sorted_updates, 0.99),
		"field_update_max_us": int(sorted_updates[sorted_updates.size() - 1]) if not sorted_updates.is_empty() else 0,
		"selected_update_p95_us": _percentile(selected_updates, 0.95), "selected_update_p99_us": _percentile(selected_updates, 0.99),
		"selected_update_max_us": int(selected_updates[selected_updates.size() - 1]) if not selected_updates.is_empty() else 0,
		"comparison_update_p95_us": _percentile(comparison_updates, 0.95), "comparison_update_p99_us": _percentile(comparison_updates, 0.99),
		"comparison_update_max_us": int(comparison_updates[comparison_updates.size() - 1]) if not comparison_updates.is_empty() else 0,
		"sample_calls": sample_calls, "sample_total_us": sample_total_us, "sample_mean_us":
			(float(sample_total_us) / sample_calls if sample_calls > 0 else 0.0), "sample_max_us": sample_max_us,
		"sample_p95_us": _percentile(samples, 0.95), "sample_p99_us": _percentile(samples, 0.99),
		"contact_query_batch_count": contact_query_batch_count, "contact_query_count": contact_query_count,
		"contact_query_max_batch": contact_query_max_batch, "contact_query_wall_us": contact_query_wall_us,
		"contact_query_native_us": contact_query_native_us,
		"contact_query_provider_overhead_us": contact_query_provider_overhead_us,
		"comparison_calls": comparison_calls, "comparison_records": comparison_rows.size()}

func _percentile(values: PackedInt64Array, percentile: float) -> int:
	if values.is_empty(): return 0
	return int(values[clampi(ceili(values.size() * percentile) - 1, 0, values.size() - 1)])

func get_status_text() -> String:
	var profile := get_provider_profile()
	return "%s | t %.3f | update %.3f ms | %d samples" % [profile.backend, current_field_time,
		float(field_update_us) / 1000.0, sample_calls]

func shutdown() -> void:
	field_ready = false
	if native != null:
		native.call("clear")
		native = null
