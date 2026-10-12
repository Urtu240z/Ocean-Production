extends WaterSurfaceProvider3D
## Synchronous open-ocean CPU provider for Jetski backend validation.
## A single native field is shared by every consumer; it is rebuilt at most
## once per physics frame, then any number of contacts sample the published grid.
enum Backend { FULL_CPU, CPU_LITE_B }
enum QueryMode { DIRECT, FULL_DISPLACED, MACRO_DISPLACED, LOCAL_SURFACE }

const CURRENT_NORMAL_SAMPLE_STEP := 0.01
const WATER_RACE_NORMAL_SAMPLE_STEP := 0.40
const BAND_COUNT := 3

@export_enum("Full CPU reference", "CPU Lite B (128/128/128 cubic)") var backend: int = Backend.CPU_LITE_B
@export var compare_other_cpu_backend := false

var fft: Node
var ocean_root: Node
var spectrum_sync_generation := 0
var spectrum_refresh_count := 0
var _last_fft_spectrum_generation := -1
var imported_spectrum_bands: Array[Dictionary] = []
var water_sync_status := "UPDATING"
var water_sync_reason := "Not configured"
var _synced_fft_instance_id := -1
var _synced_ocean_revision := -1
var _failed_spectrum_key := ""
var _synced_ocean_weather: Dictionary = {}
var native: Object
var lite_resolutions := PackedInt32Array([128, 128, 128])
## Per-band interpolation mode: 0=periodic bilinear, 1=periodic Catmull-Rom cubic.
var lite_interpolation_modes := PackedInt32Array([1, 1, 1])
var sea_level := 0.0
@export_range(0.75, 2.0, 0.05, "suffix:m") var physics_min_wavelength_m := 1.0
var normal_sample_step := CURRENT_NORMAL_SAMPLE_STEP
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
var invalid_sample_count := 0
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
var contact_query_batch_samples_us := PackedInt64Array()
var _contact_query_batch_sample_count := 0
var last_contact_query_wall_us := 0
var last_contact_query_native_us := 0
var field_builds_this_physics_tick := 0
var native_query_batches_this_physics_tick := 0
var native_query_positions_this_physics_tick := 0
var water_query_batch_us_this_physics_tick := 0
var _metrics_physics_tick := -1
var water_race_normal_enabled := false
## CPU Lite height query uses the same all-cascade contribution as the visible
## ocean vertex path. In the gameplay area all cascade distance fades are 1.
var physical_band_weights := Vector3.ONE
var displaced_query_enabled := false
var query_mode := QueryMode.DIRECT
var debug_experimental_queries_enabled := false
var local_surface_useful_radius_m := 14.0
var local_surface_spacing_m := 0.35
var local_surface_build_tick := -1
var local_surface_patch_summary: Dictionary = {}
var local_surface_missed_queries := 0
var local_surface_multi_hit_queries := 0
var local_patch_build_samples_us := PackedInt64Array()
var local_bin_build_samples_us := PackedInt64Array()
var local_query_samples_us := PackedInt64Array()
var _local_query_debug_rows: Array[Dictionary] = []
var displaced_fallback_count := 0
var query_residual_samples := PackedFloat32Array()
var query_correction_samples := PackedFloat32Array()
var query_height_difference_samples := PackedFloat32Array()
var _query_metric_write_indices := {"residual": 0, "correction": 0, "height": 0}
var _warm_q_by_position := PackedVector3Array()
var _query_debug_rows: Array[Dictionary] = []
var _last_telemetry_refresh_tick := -1
var _query_telemetry_cache := {"residual": {"mean": 0.0, "p95": 0.0, "max": 0.0},
	"correction": {"mean": 0.0, "p95": 0.0, "max": 0.0},
	"height_difference": {"mean": 0.0, "p95": 0.0, "max": 0.0},
	"field_build": {"mean": 0.0, "p95": 0.0, "max": 0.0}, "fallbacks": 0, "iterations": 3}
var capture_contact_trace := false
var trace_scenario := ""
var contact_trace_rows: Array[Dictionary] = []

func _init() -> void:
	field_update_samples_us.resize(20000)
	selected_update_samples_us.resize(20000)
	comparison_update_samples_us.resize(20000)
	sample_samples_us.resize(200000)
	contact_query_batch_samples_us.resize(20000)

func configure(ocean: Node, selected_backend: int = Backend.CPU_LITE_B, compare_backends := false) -> bool:
	_disconnect_ocean_sync_signal()
	_invalidate_water_sync("UPDATING", "Configuring CPU Lite")
	ocean_root = ocean
	_synced_fft_instance_id = -1
	_synced_ocean_revision = -1
	_last_fft_spectrum_generation = -1
	_failed_spectrum_key = ""
	backend = selected_backend
	compare_other_cpu_backend = compare_backends
	_comparison_backend = Backend.FULL_CPU if backend == Backend.CPU_LITE_B else Backend.CPU_LITE_B
	if not is_instance_valid(ocean_root) or not ClassDB.class_exists("OceanQueryNative"):
		_invalidate_water_sync("ERROR", "Ocean or native CPU provider unavailable")
		push_error("CPU water provider requires OpenOceanFFT and OceanQueryNative")
		return false
	if ocean_root.has_signal("physics_source_invalidated"):
		ocean_root.connect("physics_source_invalidated", _on_ocean_source_invalidated)
	native = ClassDB.instantiate("OceanQueryNative")
	if native == null:
		_invalidate_water_sync("ERROR", "Native CPU provider unavailable")
		push_error("Could not instantiate OceanQueryNative")
		return false
	native.call("set_gameplay_min_wavelength_m", physics_min_wavelength_m)
	if not _refresh_runtime_spectrum_if_needed():
		return false
	wave_time_rate = wave_time_rate_override if wave_time_rate_override >= 0.0 else float(fft.call("get_simulation_time_scale"))
	field_ready = _build_fields(float(fft.call("get_wave_time")))
	return field_ready


func _record_imported_spectrum(snapshots: Array) -> void:
	spectrum_sync_generation += 1
	_clear_sync_contact_caches()
	imported_spectrum_bands.clear()
	for snapshot in snapshots:
		var h0: PackedByteArray = snapshot.get("h0_rgba32f", PackedByteArray())
		imported_spectrum_bands.append({
			"band": str(snapshot.get("band", "")),
			"wind_speed_mps": float(snapshot.get("wind_speed_mps", 0.0)),
			"wind_direction": snapshot.get("wind_direction", Vector2.ZERO),
			"domain_size_m": float(snapshot.get("domain_size_m", 0.0)),
			"effective_amplitude_scale": float(snapshot.get("effective_amplitude_scale", 1.0)),
			"h0_bytes": h0.size(),
			"h0_hash": hash(h0),
		})


func _refresh_runtime_spectrum_if_needed() -> bool:
	var source := _read_ocean_source_state()
	if str(source.get("status", "ERROR")) != "OK":
		_invalidate_water_sync(str(source.get("status", "ERROR")), "Ocean source unavailable or rebuilding")
		return false
	var current_fft: Node = ocean_root.get_node_or_null("OpenOceanFFT")
	if not is_instance_valid(current_fft) or current_fft.is_queued_for_deletion() \
			or current_fft.get_instance_id() != int(source.get("fft_instance_id", -1)):
		_invalidate_water_sync("UPDATING", "Waiting for the published ocean instance")
		return false
	if not is_instance_valid(native):
		_invalidate_water_sync("ERROR", "Native CPU provider unavailable")
		return false
	var instance_id := int(source.fft_instance_id)
	var revision := int(source.revision)
	var version := int(source.spectrum_version)
	if instance_id == _synced_fft_instance_id and revision == _synced_ocean_revision \
			and version == _last_fft_spectrum_generation:
		fft = current_fft
		return true
	_invalidate_water_sync("UPDATING", "Importing the published ocean spectrum")
	var key := "%d:%d:%d" % [instance_id, revision, version]
	if key == _failed_spectrum_key:
		water_sync_status = "ERROR"
		water_sync_reason = "Spectrum import failed for " + key
		return false
	var snapshots: Array = current_fft.call("get_phys2_band_spectrum_snapshots")
	# Lite coefficients are cached by lattice/resolution. An H0 replacement at
	# the same resolution must also retire that cache, once per source version.
	native.call("clear")
	if snapshots.size() != BAND_COUNT or not bool(native.call("set_production_spectrum", snapshots)):
		_failed_spectrum_key = key
		_invalidate_water_sync("ERROR", "CPU Lite could not import spectrum " + key)
		return false
	fft = current_fft
	sea_level = float(source.sea_level)
	native.call("set_sea_level", sea_level)
	_record_imported_spectrum(snapshots)
	_synced_fft_instance_id = instance_id
	_synced_ocean_revision = revision
	_last_fft_spectrum_generation = version
	_failed_spectrum_key = ""
	_synced_ocean_weather = ocean_root.call("get_sea_state") if ocean_root.has_method("get_sea_state") else {}
	if spectrum_sync_generation > 1:
		spectrum_refresh_count += 1
	last_build_tick = -1
	return true


func _read_ocean_source_state() -> Dictionary:
	if not is_instance_valid(ocean_root) or ocean_root.is_queued_for_deletion():
		return {"status": "ERROR"}
	if ocean_root.has_method("get_physics_source_state"):
		return ocean_root.call("get_physics_source_state")
	# Compatibility with existing validation hosts using the same FFT provider.
	var current_fft: Node = ocean_root.get_node_or_null("OpenOceanFFT")
	if not is_instance_valid(current_fft) or current_fft.is_queued_for_deletion():
		return {"status": "UPDATING"}
	return {"status": "OK", "revision": 0, "fft_instance_id": current_fft.get_instance_id(),
		"spectrum_version": int(current_fft.call("get_phys2_spectrum_generation")) \
			if current_fft.has_method("get_phys2_spectrum_generation") else 0,
		"sea_level": float(ocean_root.get("sea_level"))}


func _clear_sync_contact_caches() -> void:
	_contact_positions.clear()
	_selected_contact_cache.clear()
	_comparison_contact_cache.clear()
	_contact_cache_cursor = 0
	_contact_cache_waiting_for_comparison = false
	local_surface_build_tick = -1
	local_surface_patch_summary.clear()
	_local_query_debug_rows.clear()
	_query_debug_rows.clear()
	_warm_q_by_position.clear()
	# Optional experimental contact trackers own their additional histories.
	if has_method("invalidate_contacts"):
		call("invalidate_contacts")


func _invalidate_water_sync(status: String, reason: String) -> void:
	# Clearing the node reference before queue_free prevents all later access to
	# the retiring instance. Native grids can remain allocated but are never read.
	if field_ready or is_instance_valid(fft) or not _selected_contact_cache.is_empty():
		_clear_sync_contact_caches()
	fft = null
	field_ready = false
	current_field_time = -1.0
	water_sync_status = status
	water_sync_reason = reason


func _on_ocean_source_invalidated() -> void:
	_invalidate_water_sync("UPDATING", "Ocean reconstruction requested")


func _disconnect_ocean_sync_signal() -> void:
	if is_instance_valid(ocean_root) and ocean_root.has_signal("physics_source_invalidated") \
			and ocean_root.is_connected("physics_source_invalidated", _on_ocean_source_invalidated):
		ocean_root.disconnect("physics_source_invalidated", _on_ocean_source_invalidated)


func _is_water_source_current() -> bool:
	var source := _read_ocean_source_state()
	var status := str(source.get("status", "ERROR"))
	if status != "OK":
		_invalidate_water_sync(status, "Ocean source unavailable or rebuilding")
		return false
	var key := "%d:%d:%d" % [int(source.get("fft_instance_id", -1)),
		int(source.get("revision", -1)), int(source.get("spectrum_version", -1))]
	if key == _failed_spectrum_key:
		_invalidate_water_sync("ERROR", "CPU Lite could not import spectrum " + key)
		return false
	if int(source.get("fft_instance_id", -1)) != _synced_fft_instance_id \
			or int(source.get("revision", -1)) != _synced_ocean_revision \
			or int(source.get("spectrum_version", -1)) != _last_fft_spectrum_generation:
		_invalidate_water_sync("UPDATING", "Waiting for CPU Lite spectrum synchronization")
		return false
	return field_ready and is_instance_valid(fft) and is_instance_valid(native)


func get_water_sync_status() -> Dictionary:
	_is_water_source_current()
	return {"status": water_sync_status, "ocean_revision": _synced_ocean_revision,
		"spectrum_version": _last_fft_spectrum_generation,
		"fft_instance_id": _synced_fft_instance_id, "wave_time": current_field_time}


func get_spectrum_sync_diagnostics() -> Dictionary:
	var sync := get_water_sync_status()
	return {
		"status": sync.status,
		"reason": water_sync_reason,
		"ocean_revision": _synced_ocean_revision,
		"spectrum_version": _last_fft_spectrum_generation,
		"generation": spectrum_sync_generation,
		"refresh_count": spectrum_refresh_count,
		"fft_instance_id": fft.get_instance_id() if is_instance_valid(fft) else -1,
		"fft_valid": is_instance_valid(fft),
		"physics_wave_time": current_field_time,
		"bands": imported_spectrum_bands.duplicate(true),
		"ocean_weather": _synced_ocean_weather.duplicate(),
	}

func get_surface_query_contract() -> Dictionary:
	if not _is_water_source_current() or not fft.has_method("get_physics_query_surface_contract"):
		return {}
	return fft.call("get_physics_query_surface_contract")

## Selects a manual A/B field without replacing the provider or disturbing the craft.
## The next physics contact phase rebuilds the field at that tick's authoritative ocean time.
func set_manual_candidate(candidate: int) -> bool:
	if candidate == 0 and not debug_experimental_queries_enabled:
		return false
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
	return true

func get_manual_candidate_name() -> String:
	if backend == Backend.FULL_CPU: return "FULL CPU"
	if lite_resolutions == PackedInt32Array([256, 128, 64]): return "LITE B+LONG 256/128/64"
	if lite_resolutions == PackedInt32Array([256, 128, 128]): return "LITE LONG+SHORT 256/128/128"
	if lite_resolutions == PackedInt32Array([128, 128, 128]) and lite_interpolation_modes == PackedInt32Array([1, 1, 1]):
		return "LITE 128/128/128 CUBIC"
	return "LITE %d/%d/%d" % [lite_resolutions[0], lite_resolutions[1], lite_resolutions[2]]

func set_water_race_mode(enabled: bool) -> void:
	water_race_normal_enabled = enabled
	normal_sample_step = WATER_RACE_NORMAL_SAMPLE_STEP if enabled else CURRENT_NORMAL_SAMPLE_STEP

func set_displaced_query_enabled(enabled: bool) -> void:
	set_query_mode(QueryMode.FULL_DISPLACED if enabled else QueryMode.DIRECT)

func set_experimental_queries_enabled(enabled: bool) -> void:
	debug_experimental_queries_enabled = enabled
	if not enabled:
		set_query_mode(QueryMode.DIRECT)


func set_query_mode(mode: int) -> void:
	var next_mode := clampi(mode, QueryMode.DIRECT, QueryMode.LOCAL_SURFACE)
	if next_mode != QueryMode.DIRECT and not debug_experimental_queries_enabled:
		return
	if next_mode != query_mode:
		_warm_q_by_position.clear()
	query_mode = next_mode
	displaced_query_enabled = query_mode == QueryMode.FULL_DISPLACED or query_mode == QueryMode.MACRO_DISPLACED

func get_query_mode_name() -> String:
	match query_mode:
		QueryMode.DIRECT: return "DIRECT"
		QueryMode.FULL_DISPLACED: return "FULL_DISPLACED"
		QueryMode.MACRO_DISPLACED: return "MACRO DISPLACED (LONG+MID)"
		_: return "LOCAL_SURFACE"

func get_local_surface_debug_wireframe() -> PackedVector3Array:
	if native == null or not native.has_method("get_dynamic_lite_local_surface_wireframe"):
		return PackedVector3Array()
	return native.call("get_dynamic_lite_local_surface_wireframe", 4)

func get_local_surface_debug_query(index: int) -> Dictionary:
	if index < 0 or index >= _local_query_debug_rows.size(): return {}
	return _local_query_debug_rows[index]

func get_local_surface_telemetry() -> Dictionary:
	return {
		"patch": local_surface_patch_summary,
		"patch_build_ms": _timing_stats_ms(local_patch_build_samples_us),
		"spatial_bin_build_ms": _timing_stats_ms(local_bin_build_samples_us),
		"query_batch_ms": _timing_stats_ms(local_query_samples_us),
		"missed_queries": local_surface_missed_queries,
		"multi_hit_queries": local_surface_multi_hit_queries,
	}

func validate_surface_query_modes(positions: PackedVector3Array) -> Dictionary:
	if positions.is_empty() or not field_ready or native == null:
		return {"error": "CPU Lite field unavailable or probe positions empty"}
	var original_mode := query_mode
	var experiments_were_enabled := debug_experimental_queries_enabled
	set_experimental_queries_enabled(true)
	var output := {"wave_time_s": current_field_time}
	for mode in [QueryMode.DIRECT, QueryMode.FULL_DISPLACED, QueryMode.MACRO_DISPLACED, QueryMode.LOCAL_SURFACE]:
		set_query_mode(mode)
		if mode == QueryMode.LOCAL_SURFACE:
			local_surface_build_tick = -1
		var samples: Array[WaterSample3D] = sample_water_batch(positions, Backend.CPU_LITE_B)
		var rows: Array[Dictionary] = []
		for index in samples.size():
			var sample := samples[index]
			var row := {"valid": sample.valid, "height_m": sample.surface_position.y,
				"vertical_velocity_mps": sample.velocity.y,
				"normal": [sample.normal.x, sample.normal.y, sample.normal.z]}
			if mode == QueryMode.LOCAL_SURFACE:
				row["surface_hit"] = get_local_surface_debug_query(index)
			else:
				row["query_debug"] = get_query_debug(index)
			rows.append(row)
		var key := "direct" if mode == QueryMode.DIRECT else ("full_displaced" if mode == QueryMode.FULL_DISPLACED else ("macro_displaced" if mode == QueryMode.MACRO_DISPLACED else "local_surface"))
		output[key] = rows
		if mode == QueryMode.LOCAL_SURFACE:
			output["local_patch"] = local_surface_patch_summary.duplicate(true)
	set_query_mode(original_mode)
	set_experimental_queries_enabled(experiments_were_enabled)
	local_surface_build_tick = -1
	return output

func get_query_telemetry() -> Dictionary:
	var tick := Engine.get_physics_frames()
	if _last_telemetry_refresh_tick < 0 or tick - _last_telemetry_refresh_tick >= 30:
		_query_telemetry_cache = {
		"residual": _query_stats(query_residual_samples),
		"correction": _query_stats(query_correction_samples),
		"height_difference": _query_stats(query_height_difference_samples),
		"field_build": _field_build_stats(),
		"fallbacks": displaced_fallback_count,
		"iterations": 3,
		}
		_last_telemetry_refresh_tick = tick
	return _query_telemetry_cache

func get_query_debug(index: int) -> Dictionary:
	if index < 0 or index >= _query_debug_rows.size(): return {}
	return _query_debug_rows[index]

func _append_metric(values: PackedFloat32Array, value: float, metric: String) -> void:
	if not is_finite(value): return
	if values.size() < 1024:
		values.append(value)
	else:
		var write_index := int(_query_metric_write_indices[metric])
		values[write_index] = value
		_query_metric_write_indices[metric] = (write_index + 1) % values.size()

func _query_stats(values: PackedFloat32Array) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in values: total += value
	return {"mean": total / values.size(), "p95": ordered[mini(ordered.size() - 1, int(ceil((ordered.size() - 1) * 0.95)))], "max": ordered[-1]}

func _field_build_stats() -> Dictionary:
	if _field_update_sample_count == 0: return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var ordered := PackedInt64Array()
	ordered.resize(_field_update_sample_count)
	var total := 0.0
	for index in _field_update_sample_count:
		var value := field_update_samples_us[index]
		ordered[index] = value
		total += float(value)
	ordered.sort()
	var p95_index := mini(ordered.size() - 1, int(ceil((ordered.size() - 1) * 0.95)))
	return {"mean": total / ordered.size() / 1000.0,
		"p95": float(ordered[p95_index]) / 1000.0, "max": float(ordered[-1]) / 1000.0}


func set_physical_band_weights(long_weight: float, mid_weight: float, short_weight: float) -> void:
	physical_band_weights = Vector3(maxf(long_weight, 0.0), maxf(mid_weight, 0.0),
		clampf(short_weight, 0.0, 1.0))

func begin_contacts(body_transform: Transform3D, local_points: PackedVector3Array) -> void:
	begin_gameplay_contacts(body_transform, local_points, PackedVector3Array())

func begin_gameplay_contacts(body_transform: Transform3D, local_points: PackedVector3Array,
		additional_local_points: PackedVector3Array) -> void:
	if not _refresh_runtime_spectrum_if_needed(): return
	wave_time_rate = wave_time_rate_override if wave_time_rate_override >= 0.0 else float(fft.call("get_simulation_time_scale"))
	var tick := Engine.get_physics_frames()
	if tick != last_build_tick and not _build_fields(float(fft.call("get_wave_time"))): return
	if not field_ready: return
	_contact_positions.clear()
	for local_point in local_points: _contact_positions.append(body_transform * local_point)
	for local_point in additional_local_points: _contact_positions.append(body_transform * local_point)
	_selected_contact_cache = sample_water_batch(_contact_positions, backend)
	_comparison_contact_cache.clear()
	if compare_other_cpu_backend:
		_comparison_contact_cache = sample_water_batch(_contact_positions, _comparison_backend)
	_contact_cache_cursor = 0
	_contact_cache_waiting_for_comparison = false

func _build_fields(wave_time: float) -> bool:
	_ensure_tick_metrics()
	field_builds_this_physics_tick += 1
	if field_builds_this_physics_tick > 1:
		field_update_failures += 1
		push_error("CPU water field build limit exceeded: more than one build in physics tick %d" % Engine.get_physics_frames())
		return false
	if not is_instance_valid(native) or not is_finite(wave_time):
		_invalidate_water_sync("ERROR", "Invalid CPU field source or simulation time")
		return false
	if backend == Backend.CPU_LITE_B:
		native.call("set_gameplay_min_wavelength_m", physics_min_wavelength_m)
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
	if not field_ready:
		field_update_failures += 1
		_invalidate_water_sync("ERROR", "CPU Lite field build failed")
	else:
		water_sync_status = "OK"
		water_sync_reason = ""
	return field_ready

func _build_backend(selected: int, wave_time: float) -> bool:
	if selected == Backend.CPU_LITE_B:
		return bool(native.call("build_dynamic_physics_lite", wave_time, lite_resolutions))
	return bool(native.call("build_dynamic_physics_fields", wave_time))

func has_usable_contacts() -> bool:
	# Synchronous fields never use an age-based drop rule. A failed native build
	# is surfaced as invalid and counted; otherwise the current tick is usable.
	return _is_water_source_current() and current_field_time >= 0.0

func sample_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	var out := out_sample.reset() if out_sample != null else WaterSample3D.new()
	var started := Time.get_ticks_usec()
	if not _is_water_source_current(): return _finish_sample(out, started)
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

## Optional batched query used by the contact prefetch and scaling runner.
## Keeps WaterSurfaceProvider3D's per-point interface intact for vehicle code.
func sample_water_batch(positions: PackedVector3Array, selected_backend := -1,
		interpolation_modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	_ensure_tick_metrics()
	var samples: Array[WaterSample3D] = []
	if positions.is_empty() or not _is_water_source_current(): return samples
	var started := Time.get_ticks_usec()
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
	var modes := lite_interpolation_modes if interpolation_modes.size() != BAND_COUNT else interpolation_modes
	var packed: PackedFloat64Array = native.call("sample_dynamic_lite_contacts",
		query_positions, sea_level, modes)
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
		var center_height := packed[center_offset + 1]
		var center_velocity := packed[center_offset + 2]
		var normal := Vector3(packed[center_offset + 3], packed[center_offset + 4], packed[center_offset + 5])
		if samples_per_position == 5:
			var left_offset := center_offset + ROW_SIZE
			var right_offset := center_offset + ROW_SIZE * 2
			var back_offset := center_offset + ROW_SIZE * 3
			var front_offset := center_offset + ROW_SIZE * 4
			valid = valid and packed[left_offset] > 0.5 and packed[right_offset] > 0.5 \
				and packed[back_offset] > 0.5 and packed[front_offset] > 0.5
			if valid:
				var dh_dx := (packed[right_offset + 1] - packed[left_offset + 1]) / (2.0 * WATER_RACE_NORMAL_SAMPLE_STEP)
				var dh_dz := (packed[front_offset + 1] - packed[back_offset + 1]) / (2.0 * WATER_RACE_NORMAL_SAMPLE_STEP)
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
	_record_query_batch(started, native_us, positions.size(), query_positions.size())
	return samples


func _sample_water_batch_experimental(positions: PackedVector3Array, selected_backend := -1,
		interpolation_modes: PackedInt32Array = PackedInt32Array()) -> Array[WaterSample3D]:
	_ensure_tick_metrics()
	var actual_backend := backend if selected_backend < 0 else selected_backend
	var samples: Array[WaterSample3D] = []
	if positions.is_empty() or not _is_water_source_current(): return samples
	var started := Time.get_ticks_usec()
	var native_us := 0
	var native_position_count := positions.size()
	if actual_backend == Backend.CPU_LITE_B:
		if query_mode == QueryMode.LOCAL_SURFACE:
			return _sample_local_surface_batch(positions, started)
		var modes := lite_interpolation_modes if interpolation_modes.size() != BAND_COUNT else interpolation_modes
		var query_positions := positions
		var samples_per_position := 1
		if water_race_normal_enabled:
			samples_per_position = 5
			native_position_count = positions.size() * samples_per_position
			query_positions = PackedVector3Array()
			query_positions.resize(positions.size() * samples_per_position)
			for index in positions.size():
				var point := positions[index]
				var offset := index * samples_per_position
				query_positions[offset] = point
				query_positions[offset + 1] = point + Vector3(-WATER_RACE_NORMAL_SAMPLE_STEP, 0.0, 0.0)
				query_positions[offset + 2] = point + Vector3(WATER_RACE_NORMAL_SAMPLE_STEP, 0.0, 0.0)
				query_positions[offset + 3] = point + Vector3(0.0, 0.0, -WATER_RACE_NORMAL_SAMPLE_STEP)
				query_positions[offset + 4] = point + Vector3(0.0, 0.0, WATER_RACE_NORMAL_SAMPLE_STEP)
		if _warm_q_by_position.size() != query_positions.size():
			_warm_q_by_position.resize(query_positions.size())
		for warm_index in query_positions.size():
			if _warm_q_by_position[warm_index] == Vector3.ZERO:
				_warm_q_by_position[warm_index] = query_positions[warm_index]
		var surface_contract := get_surface_query_contract()
		var camera_world_xz: Vector2 = surface_contract.get("camera_world_xz", Vector2.ZERO)
		var surface_scales := Vector2(
			float(surface_contract.get("clipmap_geometry_scale", 1.0)),
			float(surface_contract.get("ocean_surface_scale", 1.0)))
		var fade_ranges: PackedVector2Array = surface_contract.get("fade_ranges", PackedVector2Array())
		var query_weights: Vector3 = physical_band_weights if water_race_normal_enabled else Vector3.ONE
		if query_mode == QueryMode.MACRO_DISPLACED:
			query_weights.z = 0.0
		var packed: PackedFloat64Array = native.call("sample_dynamic_lite_surface_queries",
			query_positions, modes, query_mode, query_weights, _warm_q_by_position,
			camera_world_xz, surface_scales, fade_ranges)
		const band_row_size := 13
		if packed.size() != 1 + query_positions.size() * band_row_size:
			_record_query_batch(started, int(packed[0]) if not packed.is_empty() else 0,
				positions.size(), query_positions.size())
			return samples
		native_us = int(packed[0])
		_query_debug_rows.clear()
		for query_index in positions.size():
			var center_offset := 1 + query_index * samples_per_position * band_row_size
			var center_qx := packed[center_offset + 5]
			var center_qz := packed[center_offset + 6]
			var center_row := {"direct_height": packed[center_offset + 3],
				"displaced_height": packed[center_offset + 4], "q": Vector2(center_qx, center_qz),
				"dx": packed[center_offset + 7], "dz": packed[center_offset + 8],
				"residual": packed[center_offset + 9], "correction": packed[center_offset + 10],
				"height_difference": packed[center_offset + 11], "fallback": packed[center_offset + 12] > 0.5}
			_query_debug_rows.append(center_row)
		for query_index in query_positions.size():
			var row_offset := 1 + query_index * band_row_size
			var corrected_q := Vector3(packed[row_offset + 5], query_positions[query_index].y,
				packed[row_offset + 6])
			_warm_q_by_position[query_index] = corrected_q
			if displaced_query_enabled:
				_append_metric(query_residual_samples, packed[row_offset + 9], "residual")
				_append_metric(query_correction_samples, packed[row_offset + 10], "correction")
				_append_metric(query_height_difference_samples, absf(packed[row_offset + 11]), "height")
				if packed[row_offset + 12] > 0.5: displaced_fallback_count += 1
		for index in positions.size():
			var sample_index := index * samples_per_position
			var offset := 1 + sample_index * band_row_size
			var sample := WaterSample3D.new()
			var valid := packed[offset] > 0.5
			var center_height := packed[offset + 1]
			var center_velocity := packed[offset + 2]
			var normal := Vector3.UP
			if water_race_normal_enabled:
				var left_offset := offset + band_row_size
				var right_offset := offset + band_row_size * 2
				var back_offset := offset + band_row_size * 3
				var front_offset := offset + band_row_size * 4
				valid = valid and packed[left_offset] > 0.5 and packed[right_offset] > 0.5 \
					and packed[back_offset] > 0.5 and packed[front_offset] > 0.5
				if valid:
					var left_height: float = packed[left_offset + 1]
					var right_height: float = packed[right_offset + 1]
					var back_height: float = packed[back_offset + 1]
					var front_height: float = packed[front_offset + 1]
					var dh_dx := (right_height - left_height) / (2.0 * WATER_RACE_NORMAL_SAMPLE_STEP)
					var dh_dz := (front_height - back_height) / (2.0 * WATER_RACE_NORMAL_SAMPLE_STEP)
					normal = Vector3(-dh_dx, 1.0, -dh_dz).normalized()
			if valid and normal.is_finite():
				var point := positions[index]
				sample.valid = true
				sample.surface_position = Vector3(point.x, sea_level + center_height, point.z)
				sample.signed_depth = sea_level + center_height - point.y
				sample.velocity = Vector3(0.0, center_velocity * wave_time_rate, 0.0)
				sample.normal = normal
				sample.provider = self
			samples.append(sample)
	else:
		# The Full CPU oracle never computes the playable 0.40 m Water Race normal.
		var full_reference_step := CURRENT_NORMAL_SAMPLE_STEP
		var query_positions := PackedVector3Array()
		query_positions.resize(positions.size() * 5)
		native_position_count = query_positions.size()
		for index in positions.size():
			var point := positions[index]
			var offset := index * 5
			query_positions[offset] = point
			query_positions[offset + 1] = point + Vector3(full_reference_step, 0.0, 0.0)
			query_positions[offset + 2] = point - Vector3(full_reference_step, 0.0, 0.0)
			query_positions[offset + 3] = point + Vector3(0.0, 0.0, full_reference_step)
			query_positions[offset + 4] = point - Vector3(0.0, 0.0, full_reference_step)
		var packed: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", query_positions)
		const full_stride := 15
		if packed.size() != query_positions.size() * full_stride:
			_record_query_batch(started, 0, positions.size(), query_positions.size())
			return samples
		native_us = Time.get_ticks_usec() - started
		for index in positions.size():
			var offset := index * 5 * full_stride
			var center_height := packed[offset + 1] - sea_level
			var dhx := ((packed[offset + full_stride + 1] - sea_level) -
				(packed[offset + 2 * full_stride + 1] - sea_level)) / (2.0 * full_reference_step)
			var dhz := ((packed[offset + 3 * full_stride + 1] - sea_level) -
				(packed[offset + 4 * full_stride + 1] - sea_level)) / (2.0 * full_reference_step)
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
	_record_query_batch(started, native_us, positions.size(), native_position_count)
	return samples

func _sample_local_surface_batch(positions: PackedVector3Array, started: int) -> Array[WaterSample3D]:
	var samples: Array[WaterSample3D] = []
	var native_us := 0
	var normal_step := WATER_RACE_NORMAL_SAMPLE_STEP if water_race_normal_enabled else normal_sample_step
	var query_positions := PackedVector3Array()
	var samples_per_position := 5
	query_positions.resize(positions.size() * samples_per_position)
	var center_x := 0.0
	var center_z := 0.0
	for index in positions.size():
		var point := positions[index]
		center_x += point.x / float(positions.size())
		center_z += point.z / float(positions.size())
		var offset := index * samples_per_position
		query_positions[offset] = point
		query_positions[offset + 1] = point + Vector3(-normal_step, 0.0, 0.0)
		query_positions[offset + 2] = point + Vector3(normal_step, 0.0, 0.0)
		query_positions[offset + 3] = point + Vector3(0.0, 0.0, -normal_step)
		query_positions[offset + 4] = point + Vector3(0.0, 0.0, normal_step)
	var tick := Engine.get_physics_frames()
	if local_surface_build_tick != tick:
		var contract := get_surface_query_contract()
		var fade_ranges: PackedVector2Array = contract.get("fade_ranges", PackedVector2Array())
		if fade_ranges.size() == 3:
			var camera_world_xz: Vector2 = contract.get("camera_world_xz", Vector2.ZERO)
			var summary: Dictionary = native.call("build_dynamic_lite_local_surface",
				center_x, center_z, camera_world_xz.x, camera_world_xz.y,
				local_surface_useful_radius_m, local_surface_spacing_m, sea_level,
				float(contract.get("clipmap_geometry_scale", 1.0)),
				float(contract.get("ocean_surface_scale", 1.0)),
				float(contract.get("horizontal_displacement_bound_world_m", 0.0)),
				fade_ranges, lite_interpolation_modes)
			local_surface_patch_summary = summary
			local_surface_build_tick = tick
			if not summary.is_empty():
				_append_timing(local_patch_build_samples_us, int(summary.get("build_us", 0)))
				_append_timing(local_bin_build_samples_us, int(summary.get("spatial_bin_build_us", 0)))
		else:
			local_surface_patch_summary = {}
			local_surface_build_tick = tick
	var packed: PackedFloat64Array = native.call("sample_dynamic_lite_local_surface_batch", query_positions)
	const row_size := 5
	_local_query_debug_rows.clear()
	if packed.size() != 1 + query_positions.size() * row_size:
		_record_query_batch(started, 0, positions.size(), query_positions.size())
		return samples
	native_us = int(packed[0])
	_append_timing(local_query_samples_us, native_us)
	for index in positions.size():
		var sample := WaterSample3D.new()
		var point := positions[index]
		var offset := 1 + index * samples_per_position * row_size
		var valid := true
		for sample_index in samples_per_position:
			if packed[offset + sample_index * row_size] <= 0.5:
				valid = false
				break
		var center_height := packed[offset + 1]
		var center_velocity := packed[offset + 2]
		var normal := Vector3.UP
		if valid:
			var left_height: float = packed[offset + row_size + 1]
			var right_height: float = packed[offset + row_size * 2 + 1]
			var back_height: float = packed[offset + row_size * 3 + 1]
			var front_height: float = packed[offset + row_size * 4 + 1]
			var dh_dx := (right_height - left_height) / (2.0 * normal_step)
			var dh_dz := (front_height - back_height) / (2.0 * normal_step)
			normal = Vector3(-dh_dx, 1.0, -dh_dz).normalized()
			valid = normal.is_finite()
		if valid:
			sample.valid = true
			sample.surface_position = Vector3(point.x, center_height, point.z)
			sample.signed_depth = center_height - point.y
			sample.velocity = Vector3(0.0, center_velocity * wave_time_rate, 0.0)
			sample.normal = normal
			sample.provider = self
		else:
			local_surface_missed_queries += 1
		var triangle_index := int(packed[offset + 3])
		var hit_count := int(packed[offset + 4])
		if hit_count > 1: local_surface_multi_hit_queries += 1
		_local_query_debug_rows.append({
			"triangle_index": triangle_index,
			"hit_count": hit_count,
			"height": center_height,
			"valid": sample.valid,
		})
		samples.append(sample)
	_record_query_batch(started, native_us, positions.size(), query_positions.size())
	return samples

func _append_timing(values: PackedInt64Array, value_us: int) -> void:
	values.append(maxi(value_us, 0))
	if values.size() > 512: values.remove_at(0)

func _timing_stats_ms(values: PackedInt64Array) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in values: total += float(value)
	return {
		"mean": total / values.size() / 1000.0,
		"p95": float(ordered[mini(ordered.size() - 1, int(ceil((ordered.size() - 1) * 0.95)))]) / 1000.0,
		"max": float(ordered[-1]) / 1000.0,
	}

func _record_query_batch(started: int, native_us: int, position_count: int,
		native_position_count: int) -> void:
	var wall_us := Time.get_ticks_usec() - started
	_ensure_tick_metrics()
	native_query_batches_this_physics_tick += 1
	native_query_positions_this_physics_tick += native_position_count
	water_query_batch_us_this_physics_tick += wall_us
	contact_query_batch_count += 1
	contact_query_count += position_count
	contact_query_wall_us += wall_us
	contact_query_native_us += native_us
	contact_query_provider_overhead_us += maxi(0, wall_us - native_us)
	contact_query_max_batch = maxi(contact_query_max_batch, position_count)
	if _contact_query_batch_sample_count < contact_query_batch_samples_us.size():
		contact_query_batch_samples_us[_contact_query_batch_sample_count] = wall_us
		_contact_query_batch_sample_count += 1
	last_contact_query_wall_us = wall_us
	last_contact_query_native_us = native_us

func _ensure_tick_metrics() -> void:
	var tick := Engine.get_physics_frames()
	if tick == _metrics_physics_tick: return
	_metrics_physics_tick = tick
	field_builds_this_physics_tick = 0
	native_query_batches_this_physics_tick = 0
	native_query_positions_this_physics_tick = 0
	water_query_batch_us_this_physics_tick = 0

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
	if not _is_water_source_current() or not world_position.is_finite(): return out
	var started := Time.get_ticks_usec()
	var sample_step := CURRENT_NORMAL_SAMPLE_STEP if selected == Backend.FULL_CPU else normal_sample_step
	var center := _height_velocity(selected, world_position.x, world_position.z)
	if not bool(center.valid):
		return _finish_sample(out, started)
	var hx_plus := _height_velocity(selected, world_position.x + sample_step, world_position.z)
	var hx_minus := _height_velocity(selected, world_position.x - sample_step, world_position.z)
	var hz_plus := _height_velocity(selected, world_position.x, world_position.z + sample_step)
	var hz_minus := _height_velocity(selected, world_position.x, world_position.z - sample_step)
	if not bool(hx_plus.valid and hx_minus.valid and hz_plus.valid and hz_minus.valid):
		return _finish_sample(out, started)
	var dhx := (float(hx_plus.height) - float(hx_minus.height)) / (2.0 * sample_step)
	var dhz := (float(hz_plus.height) - float(hz_minus.height)) / (2.0 * sample_step)
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
	var query_batches := PackedInt64Array()
	query_batches.resize(_contact_query_batch_sample_count)
	for i in _contact_query_batch_sample_count: query_batches[i] = contact_query_batch_samples_us[i]
	query_batches.sort()
	var field_total := 0
	for i in _field_update_sample_count: field_total += field_update_samples_us[i]
	return {"backend": "CPU_LITE_B" if backend == Backend.CPU_LITE_B else "FULL_CPU",
		"comparison_backend": "FULL_CPU" if _comparison_backend == Backend.FULL_CPU else "CPU_LITE_B",
		"ready": field_ready, "field_time": current_field_time, "field_update_us": field_update_us,
		"field_update_count": field_update_count, "field_update_failures": field_update_failures,
		"field_update_mean_us": float(field_total) / maxf(1.0, float(_field_update_sample_count)),
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
		"contact_query_batch_mean_us": float(contact_query_wall_us) / maxf(1.0, float(contact_query_batch_count)),
		"contact_query_batch_p95_us": _percentile(query_batches, 0.95),
		"comparison_calls": comparison_calls, "comparison_records": comparison_rows.size()}

func _percentile(values: PackedInt64Array, percentile: float) -> int:
	if values.is_empty(): return 0
	return int(values[clampi(ceili(values.size() * percentile) - 1, 0, values.size() - 1)])

func get_status_text() -> String:
	var profile := get_provider_profile()
	return "%s | t %.3f | update %.3f ms | %d samples" % [profile.backend, current_field_time,
		float(field_update_us) / 1000.0, sample_calls]

func shutdown() -> void:
	set_physics_process(false)
	_disconnect_ocean_sync_signal()
	_invalidate_water_sync("UPDATING", "CPU provider stopped")
	ocean_root = null
	if is_instance_valid(native):
		native.call("clear")
		native = null
