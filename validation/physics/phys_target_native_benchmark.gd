extends SceneTree
## Reproducible native scalar/batch benchmark across PHYS-1/2/3 band sets.
## All inputs and native setup are prepared outside each timed query loop.

const OCEAN_SCENE := preload("res://addons/ocean/ocean.tscn")
const SpectrumAdapter := preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const DESCRIPTOR := "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"
const QUERY_COUNTS := [1, 4, 8, 16, 64]
const REPEATS := 3
const STRIDE := 15
const INDEX_DX := 2
const INDEX_DY := 3
const INDEX_DZ := 4
const INDEX_NX := 5
const INDEX_NY := 6
const INDEX_NZ := 7
const INDEX_VY := 10
const INDEX_JACOBIAN := 11
const BAND_LONG := 1
const BAND_LONG_MID := 3
const BAND_ALL := 7

var _ocean: Node
var _quick_smoke := false
var _coastal_only := false
var _optimization_sweep := false
var _profile_only := false
var _band_mask_benchmark := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--target-phys-quick-smoke":
			_quick_smoke = true
		elif argument == "--target-phys-coastal-only":
			_coastal_only = true
		elif argument == "--target-phys-optimization-sweep":
			_coastal_only = true
			_optimization_sweep = true
		elif argument == "--target-phys-opt-profile":
			_coastal_only = true
			_optimization_sweep = true
			_profile_only = true
		elif argument == "--target-phys-opt-band-mask":
			_coastal_only = true
			_band_mask_benchmark = true
	if load(DESCRIPTOR) == null or not ClassDB.class_exists("OceanQueryNative"):
		_fail("OceanQueryNative extension failed to load.")
		return
	_ocean = OCEAN_SCENE.instantiate()
	_ocean.set("long_enabled", true)
	_ocean.set("mid_enabled", true)
	_ocean.set("short_enabled", true)
	_ocean.set("coastal", true)
	_ocean.set("breakers", false)
	_ocean.set("crest_foam", false)
	_ocean.set("surface_foam", false)
	_ocean.set("optics", false)
	_ocean.set("reflections", false)
	_ocean.set("surface_detail", false)
	_ocean.set("wave_height_scale", 1.0)
	_ocean.set("ocean_scale", 1.0)
	_ocean.set("clipmap_geometry_scale", 1.0)
	_ocean.set("long_band_scale", 1.0)
	_ocean.set("mid_band_scale", 1.0)
	_ocean.set("short_band_scale", 1.0)
	_ocean.set("mid_fill_amount", 1.0)
	_ocean.set("coastal_bake", load("res://validation/p4_paradise/coastal_bake.tres"))
	root.add_child(_ocean)
	for _frame in 6:
		await RenderingServer.frame_post_draw
	var fft := _ocean.get_node_or_null("OpenOceanFFT")
	if fft == null:
		_fail("Production OpenOceanFFT was not created.")
		return
	var spectra: Array[Dictionary] = fft.call("get_phys2_band_spectrum_snapshots")
	var coastal: Dictionary = fft.call("get_phys3_coastal_snapshot")
	if spectra.size() != 3 or coastal.is_empty():
		_fail("Production did not provide all three retained H0 spectra and the Coastal CPU snapshot.")
		return
	var time := float(_ocean.call("get_wave_time"))
	var positions := _make_positions(coastal)
	var query_counts: Array = [4, 8, 16] if _band_mask_benchmark else ([4] if _profile_only else ([1, 4] if _quick_smoke else ([1, 4, 8, 16] if _optimization_sweep else QUERY_COUNTS)))
	print("TARGET_PHYS_NATIVE_ENV " + JSON.stringify({
		"cpu": OS.get_processor_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"godot": Engine.get_version_info().get("string", "unknown"),
		"wave_time": time,
		"query_counts": query_counts,
		"repeats": REPEATS,
		"gpu_readback": false,
		"source": "retained Production H0 and authoritative CPU Coastal bake",
	}))
	var configurations := [
		{"label": "LONG", "mask": 1, "coastal": false},
		{"label": "LONG+MID", "mask": 3, "coastal": false},
		{"label": "LONG+MID+SHORT", "mask": 7, "coastal": false},
		{"label": "LONG+MID+SHORT+COASTAL", "mask": 7, "coastal": true},
	]
	if _quick_smoke:
		configurations = [configurations[0]]
	elif _band_mask_benchmark:
		configurations = [configurations[3]]
	elif _coastal_only:
		configurations = [configurations[3]]
	for config in configurations:
		var native: Object = ClassDB.instantiate("OceanQueryNative")
		var setup: Dictionary = SpectrumAdapter.configure_bands(native, spectra, float(_ocean.get("sea_level")), int(config["mask"]))
		if not bool(setup.get("ok", false)):
			_fail("Native band configuration failed for %s: %s" % [config["label"], setup])
			return
		if bool(config["coastal"]):
			var coastal_setup: Dictionary = SpectrumAdapter.configure_coastal(native, coastal)
			if not bool(coastal_setup.get("ok", false)):
				_fail("Native Coastal configuration failed: %s" % coastal_setup)
				return
		native.call("set_coastal_profile_enabled", true)
		var batch_diagnostics_available := native.has_method("set_batch_profile_enabled")
		if batch_diagnostics_available:
			native.call("set_batch_profile_enabled", true)
		var prepare_time_us := 0
		if not _band_mask_benchmark:
			var prepare_start := Time.get_ticks_usec()
			native.call("ensure_prepared", time)
			prepare_time_us = Time.get_ticks_usec() - prepare_start
		print("TARGET_PHYS_NATIVE_CONFIGURATION " + JSON.stringify({"label": config["label"], "mask": config["mask"], "coastal": config["coastal"], "bands": setup.get("bands", []), "coastal_generation": coastal.get("generation", -1) if bool(config["coastal"]) else null, "cpu_supports_avx2": native.call("get_cpu_supports_avx2"), "selected_backend": native.call("get_query_execution_backend"), "batch_diagnostics_available": batch_diagnostics_available, "prepare_time_us": prepare_time_us}))
		if _band_mask_benchmark:
			var band_report := _run_band_mask_benchmark(native, time, coastal, spectra, positions)
			if not bool(band_report.get("ok", false)):
				_fail("Band mask validation failed: %s" % JSON.stringify(band_report))
				return
			print("TARGET_PHYS_OPT_BAND_MASK " + JSON.stringify(band_report))
			native = null
			_ocean.queue_free()
			quit(0)
			return
		var world_positions := _make_world_positions(native, positions, time)
		for count_variant in query_counts:
			var count := int(count_variant)
			var subset := PackedVector3Array()
			var world_subset := PackedVector3Array()
			for index in count:
				subset.append(positions[index])
				world_subset.append(world_positions[index])
			var material_check := _compare_paths(native, time, subset, false)
			var measure_world := not _optimization_sweep or (count <= 8 and not _profile_only)
			var world_check: Dictionary = _compare_paths(native, time, world_subset, true) if measure_world else {}
			if float(material_check["max_scalar_batch_error"]) > 1.0e-8 or (measure_world and float(world_check["max_scalar_batch_error"]) > 1.0e-5):
				_fail("Scalar/batch correctness exceeded tolerance for %s / %d: material=%s world=%s" % [config["label"], count, material_check, world_check])
				return
			var material_timing := _time_paths(native, time, subset, false)
			var world_timing: Dictionary = _time_paths(native, time, world_subset, true) if measure_world else {}
			var world_warm_timing: Dictionary = {}
			if measure_world and bool(config["coastal"]) and not _coastal_only:
				world_warm_timing = _time_world_warm(native, time, world_subset, float(world_timing["batch_total_mean_ms"]))
			print("TARGET_PHYS_NATIVE_RESULT " + JSON.stringify({
				"configuration": config["label"], "queries": count,
				"material_q": material_timing, "world_xz": world_timing,
				"world_xz_warm": world_warm_timing,
				"material_scalar_batch_max_error": material_check["max_scalar_batch_error"],
				"world_scalar_batch_max_error": world_check.get("max_scalar_batch_error", null),
				"time_ms": time,
			}))
		# OceanQueryNative is RefCounted; release it before configuring the next case.
		native = null
	print("TARGET_PHYS_NATIVE_COMPLETE")
	_ocean.queue_free()
	quit(0)


func _run_band_mask_benchmark(native: Object, time: float, coastal: Dictionary,
		spectra: Array[Dictionary], positions: PackedVector3Array) -> Dictionary:
	var bound_masks := {
		"LONG": ClassDB.class_get_integer_constant("OceanQueryNative", "BAND_LONG"),
		"MID": ClassDB.class_get_integer_constant("OceanQueryNative", "BAND_MID"),
		"SHORT": ClassDB.class_get_integer_constant("OceanQueryNative", "BAND_SHORT"),
		"ALL": ClassDB.class_get_integer_constant("OceanQueryNative", "BAND_ALL"),
	}
	if bound_masks != {"LONG": BAND_LONG, "MID": 2, "SHORT": 4, "ALL": BAND_ALL}:
		return {"ok": false, "error": "Native query band constants do not match the documented bit flags.", "bound_masks": bound_masks}
	var candidate: Object = ClassDB.instantiate("OceanQueryNative")
	var setup: Dictionary = SpectrumAdapter.configure_bands(candidate, spectra, float(_ocean.get("sea_level")), BAND_ALL)
	if not bool(setup.get("ok", false)):
		return {"ok": false, "error": "Could not configure the full spectrum on the candidate query object.", "setup": setup}
	var coastal_setup: Dictionary = SpectrumAdapter.configure_coastal(candidate, coastal)
	if not bool(coastal_setup.get("ok", false)):
		return {"ok": false, "error": "Could not configure candidate Coastal snapshot.", "setup": coastal_setup}
	candidate.call("set_coastal_profile_enabled", true)
	candidate.call("set_batch_profile_enabled", true)
	var mode_counts: Array[int] = []
	for snapshot in spectra:
		var resolution := int(snapshot.get("resolution", 0))
		mode_counts.append(resolution * resolution)
	native.call("set_coastal_profile_enabled", true)
	native.call("set_batch_profile_enabled", true)
	var results: Array[Dictionary] = []
	for count in [4, 8, 16]:
		var subset := _spread_positions(positions, count)
		var variants: Array[Dictionary] = []
		for config in [
			{"label": "FULL_LONG_MID_SHORT_COASTAL", "mask": BAND_ALL, "native": native},
			{"label": "JETSKI_LONG_MID_COASTAL", "mask": BAND_LONG_MID, "native": candidate},
		]:
			var mask := int(config["mask"])
			var query_native: Object = config["native"]
			var material_check := _compare_masked_paths(query_native, time, subset, mask, false)
			var world_positions := _masked_world_positions(query_native, time, subset, mask)
			var world_check := _compare_masked_paths(query_native, time, world_positions, mask, true)
			if float(material_check["max_scalar_batch_error"]) > 1.0e-8 \
					or float(world_check["max_scalar_batch_error"]) > 1.0e-8:
				return {"ok": false, "query_count": count, "configuration": config["label"],
					"material": material_check, "world": world_check}
			var timing := _time_masked_batch(query_native, time, subset, mask, mode_counts)
			variants.append({
				"configuration": config["label"], "band_mask": mask,
				"material_scalar_batch_max_error": material_check["max_scalar_batch_error"],
				"world_scalar_batch_max_error": world_check["max_scalar_batch_error"],
				"material_batch": timing,
			})
		var full_ms := float((variants[0]["material_batch"] as Dictionary)["total_ms_per_batch"])
		var long_mid_ms := float((variants[1]["material_batch"] as Dictionary)["total_ms_per_batch"])
		results.append({"queries": count, "variants": variants,
			"speedup_from_disabling_short": full_ms / maxf(long_mid_ms, 0.000001)})
	var impact := _measure_short_band_impact(native, candidate, time, positions)
	var default_restore_error := _masked_scope_default_regression(native, candidate, time, positions[0])
	if default_restore_error > 1.0e-8:
		return {"ok": false, "error": "A masked query changed the subsequent default FULL query.",
			"default_restore_error": default_restore_error}
	return {
		"ok": true,
		"machine": OS.get_processor_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"wave_time": time,
		"spectral_mode_counts": mode_counts,
		"band_mask_flags": bound_masks,
		"spectral_passes_per_four_lane_group": {"full": 9, "long_mid": 8},
		"results": results,
		"short_band_impact": impact,
		"masked_scope_default_full_max_error": default_restore_error,
		"short_is_skipped_by_mask": true,
		"default_query_mask": BAND_ALL,
	}


func _masked_scope_default_regression(full_native: Object, candidate_native: Object,
		time: float, point: Vector3) -> float:
	candidate_native.call("sample_material_q_with_band_mask", point.x, point.z, time, BAND_LONG_MID)
	var candidate_full: PackedFloat64Array = candidate_native.call("sample_material_q", point.x, point.z, time)
	var reference_full: PackedFloat64Array = full_native.call("sample_material_q", point.x, point.z, time)
	var max_error := 0.0
	for field in STRIDE:
		max_error = maxf(max_error, absf(candidate_full[field] - reference_full[field]))
	return max_error


func _spread_positions(source: PackedVector3Array, count: int) -> PackedVector3Array:
	var output := PackedVector3Array()
	for index in count:
		var source_index := mini(int(floor(float(index) * float(source.size()) / float(count))), source.size() - 1)
		output.append(source[source_index])
	return output


func _masked_world_positions(native: Object, time: float, material_positions: PackedVector3Array,
		band_mask: int) -> PackedVector3Array:
	var output := PackedVector3Array()
	for point in material_positions:
		var value: PackedFloat64Array = native.call("sample_material_q_with_band_mask", point.x, point.z, time, band_mask)
		output.append(Vector3(point.x + value[INDEX_DX], 0.0, point.z + value[INDEX_DZ]))
	return output


func _compare_masked_paths(native: Object, time: float, positions: PackedVector3Array,
		band_mask: int, world_xz: bool) -> Dictionary:
	var batch_method := "sample_batch_with_band_mask" if world_xz else "sample_material_q_batch_with_band_mask"
	var scalar_method := "sample_world_with_band_mask" if world_xz else "sample_material_q_with_band_mask"
	var batch: PackedFloat64Array = native.call(batch_method, time, positions, band_mask)
	var max_error := 0.0
	var displacement_error := Vector3.ZERO
	for index in positions.size():
		var point := positions[index]
		var scalar: PackedFloat64Array = native.call(scalar_method, point.x, point.z, time, band_mask)
		for field in STRIDE:
			max_error = maxf(max_error, absf(batch[index * STRIDE + field] - scalar[field]))
		var base := index * STRIDE
		displacement_error.x = maxf(displacement_error.x, absf(batch[base + INDEX_DX] - scalar[INDEX_DX]))
		displacement_error.y = maxf(displacement_error.y, absf(batch[base + INDEX_DY] - scalar[INDEX_DY]))
		displacement_error.z = maxf(displacement_error.z, absf(batch[base + INDEX_DZ] - scalar[INDEX_DZ]))
	return {"max_scalar_batch_error": max_error, "displacement_component_max_error": displacement_error}


func _time_masked_batch(native: Object, time: float, positions: PackedVector3Array,
		band_mask: int, mode_counts: Array[int]) -> Dictionary:
	var values: Array[float] = []
	var checksum := 0.0
	# Warm only this explicit mask at the measured wave time. For LONG+MID this
	# intentionally leaves the SHORT temporal coefficients unprepared.
	native.call("sample_material_q_batch_with_band_mask", time, positions, band_mask)
	native.call("reset_coastal_profile")
	for _repeat_index in REPEATS:
		var start := Time.get_ticks_usec()
		var result: PackedFloat64Array = native.call("sample_material_q_batch_with_band_mask", time, positions, band_mask)
		values.append(float(Time.get_ticks_usec() - start) / 1000.0)
		checksum += result[INDEX_DY]
	var profile: PackedInt64Array = native.call("get_coastal_profile_detail")
	var work := _masked_work_summary(profile, mode_counts)
	return {
		"total_ms_per_batch": _mean(values),
		"p95_ms_per_batch": _percentile(values, 0.95),
		"ms_per_query": _mean(values) / float(positions.size()),
		"work_per_batch": work,
		"checksum": checksum,
	}


func _masked_work_summary(values: PackedInt64Array, mode_counts: Array[int]) -> Dictionary:
	if values.size() < 93:
		return {"error": "Native spectral profile unavailable."}
	var per_band := [0, 0, 0]
	var stages := 5
	for stage in stages:
		for band in 3:
			per_band[band] += int(values[50 + stage * 3 + band])
		per_band[0] += int(values[65 + stage])
	per_band[0] += int(values[91])
	var per_query_batch := [0, 0, 0]
	var pass_counts := [0.0, 0.0, 0.0]
	var base_evaluations := [0, 0, 0]
	var deep_long_evaluations := 0
	var fused_long_evaluations := int(values[91])
	for band in 3:
		base_evaluations[band] = per_band[band]
		per_query_batch[band] = int(round(float(per_band[band]) / float(REPEATS)))
	for stage in stages:
		deep_long_evaluations += int(values[65 + stage])
	base_evaluations[0] -= deep_long_evaluations + fused_long_evaluations
	for band in 3:
		if band < mode_counts.size() and mode_counts[band] > 0:
			var total_pass_evaluations: int = per_band[band]
			if band == 0:
				# Fused stencil counts four displaced outputs per traversed mode;
				# divide that term by four when converting work to loop traversals.
				total_pass_evaluations = base_evaluations[0] + deep_long_evaluations + int(round(float(fused_long_evaluations) / 4.0))
			pass_counts[band] = float(total_pass_evaluations) / float(mode_counts[band] * 4 * REPEATS)
	var simd_iterations := 0
	for band in 3:
		if band < mode_counts.size():
			simd_iterations += int(round(pass_counts[band] * float(mode_counts[band])))
	return {
		"mode_evaluations_per_batch": {"LONG": per_query_batch[0], "MID": per_query_batch[1], "SHORT": per_query_batch[2]},
		"spectral_passes_per_batch": pass_counts[0] + pass_counts[1] + pass_counts[2],
		"simd_mode_iterations_per_batch": simd_iterations,
		"short_mode_evaluations": per_query_batch[2],
		"profile_breakdown_mode_evaluations_per_run": {
			"base_by_band": {
				"LONG": int(round(float(base_evaluations[0]) / float(REPEATS))),
				"MID": int(round(float(base_evaluations[1]) / float(REPEATS))),
				"SHORT": int(round(float(base_evaluations[2]) / float(REPEATS))),
			},
			"coastal_deep_LONG": int(round(float(deep_long_evaluations) / float(REPEATS))),
			"fused_open_stencil_LONG": int(round(float(fused_long_evaluations) / float(REPEATS))),
		},
	}


func _measure_short_band_impact(full_native: Object, candidate_native: Object, time: float,
		all_positions: PackedVector3Array) -> Dictionary:
	var positions := _spread_positions(all_positions, 64)
	var height_delta: Array[float] = []
	var vertical_velocity_delta: Array[float] = []
	var horizontal_delta: Array[float] = []
	var normal_angle_delta: Array[float] = []
	var jacobian_delta: Array[float] = []
	var time_offsets: Array[float] = [0.0, 0.53, 1.37, 2.91]
	for time_offset in time_offsets:
		var sample_time := time + time_offset
		for point in positions:
			var full: PackedFloat64Array = full_native.call("sample_material_q", point.x, point.z, sample_time)
			var candidate: PackedFloat64Array = candidate_native.call("sample_material_q_with_band_mask", point.x, point.z, sample_time, BAND_LONG_MID)
			height_delta.append(absf(full[INDEX_DY] - candidate[INDEX_DY]))
			vertical_velocity_delta.append(absf(full[INDEX_VY] - candidate[INDEX_VY]))
			var dx := full[INDEX_DX] - candidate[INDEX_DX]
			var dz := full[INDEX_DZ] - candidate[INDEX_DZ]
			horizontal_delta.append(Vector2(dx, dz).length())
			var full_normal := Vector3(full[INDEX_NX], full[INDEX_NY], full[INDEX_NZ]).normalized()
			var candidate_normal := Vector3(candidate[INDEX_NX], candidate[INDEX_NY], candidate[INDEX_NZ]).normalized()
			normal_angle_delta.append(rad_to_deg(acos(clampf(full_normal.dot(candidate_normal), -1.0, 1.0))))
			jacobian_delta.append(absf(full[INDEX_JACOBIAN] - candidate[INDEX_JACOBIAN]))
	return {
		"space": "same material_q; LONG+MID+SHORT+Coastal vs LONG+MID+Coastal",
		"sample_count": height_delta.size(),
		"time_offsets_seconds": time_offsets,
		"height_delta_m": _stats(height_delta),
		"vertical_velocity_delta_mps": _stats(vertical_velocity_delta),
		"horizontal_displacement_delta_m": _stats(horizontal_delta),
		"normal_angle_delta_degrees": _stats(normal_angle_delta),
		"jacobian_delta": _stats(jacobian_delta),
	}


func _stats(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var sorted: Array = values.duplicate()
	sorted.sort()
	return {"mean": _mean(values), "p95": _percentile(values, 0.95), "max": float(sorted.back())}


func _make_positions(coastal: Dictionary) -> PackedVector3Array:
	var output := PackedVector3Array()
	var origin: Vector2 = coastal.get("field_origin", Vector2.ZERO)
	var extent: Vector2 = coastal.get("field_extent", Vector2(512.0, 512.0))
	for index in QUERY_COUNTS.back():
		var x: int = index % 16
		var z: int = int(index / 16)
		var qx := origin.x + (float(x) + 0.5) * extent.x / 16.0
		var qz := origin.y + (float(z) + 0.5) * extent.y / 16.0
		output.append(Vector3(qx, 0.0, qz))
	return output


func _make_world_positions(native: Object, material_positions: PackedVector3Array, time: float) -> PackedVector3Array:
	var output := PackedVector3Array()
	for point in material_positions:
		var value: PackedFloat64Array = native.call("sample_material_q", point.x, point.z, time)
		output.append(Vector3(point.x + value[INDEX_DX], 0.0, point.z + value[INDEX_DZ]))
	return output


func _compare_paths(native: Object, time: float, positions: PackedVector3Array, world_xz: bool) -> Dictionary:
	var batch: PackedFloat64Array = native.call("sample_batch" if world_xz else "sample_material_q_batch", time, positions)
	var max_error := 0.0
	var vector_error := Vector3.ZERO
	var worst := {}
	for index in positions.size():
		var point := positions[index]
		var scalar: PackedFloat64Array
		if world_xz:
			scalar = native.call("sample_world", point.x, point.z, time)
		else:
			scalar = native.call("sample_material_q", point.x, point.z, time)
		for field in STRIDE:
			var error := absf(batch[index * STRIDE + field] - scalar[field])
			if error > max_error:
				max_error = error
				worst = {"index": index, "field": field, "batch": batch[index * STRIDE + field], "scalar": scalar[field]}
		var base := index * STRIDE
		vector_error.x = maxf(vector_error.x, absf(batch[base + 2] - scalar[2]))
		vector_error.y = maxf(vector_error.y, absf(batch[base + 3] - scalar[3]))
		vector_error.z = maxf(vector_error.z, absf(batch[base + 4] - scalar[4]))
	return {"max_scalar_batch_error": max_error, "displacement_component_max_error": vector_error, "worst_field": worst}


func _time_paths(native: Object, time: float, positions: PackedVector3Array, world_xz: bool) -> Dictionary:
	var scalar_times: Array[float] = []
	var batch_times: Array[float] = []
	var scalar_sum := 0.0
	var batch_sum := 0.0
	native.call("reset_coastal_profile")
	var start := Time.get_ticks_usec()
	for repeat_index in REPEATS:
		start = Time.get_ticks_usec()
		for point in positions:
			var value: PackedFloat64Array
			if world_xz:
				value = native.call("sample_world", point.x, point.z, time)
			else:
				value = native.call("sample_material_q", point.x, point.z, time)
			scalar_sum += value[INDEX_DY]
		scalar_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	var scalar_profile: PackedInt64Array = native.call("get_coastal_profile_us")
	native.call("reset_coastal_profile")
	for repeat_index in REPEATS:
		start = Time.get_ticks_usec()
		var batch: PackedFloat64Array
		if world_xz:
			batch = native.call("sample_batch", time, positions)
		else:
			batch = native.call("sample_material_q_batch", time, positions)
		batch_sum += batch[INDEX_DY]
		batch_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	var batch_profile: PackedInt64Array = native.call("get_coastal_profile_us")
	var batch_profile_detail: PackedInt64Array = native.call("get_coastal_profile_detail") if native.has_method("get_coastal_profile_detail") else PackedInt64Array()
	var wrapper_profile := PackedInt64Array()
	var execution := PackedInt32Array()
	if native.has_method("get_last_batch_profile_us"):
		wrapper_profile = native.call("get_last_batch_profile_us")
		execution = native.call("get_last_batch_diagnostics")
	var newton_histogram: Array[int] = []
	for index in range(3, execution.size()):
		newton_histogram.append(execution[index])
	return {
		"scalar_total_mean_ms": _mean(scalar_times), "scalar_total_p95_ms": _percentile(scalar_times, 0.95),
		"scalar_us_per_query": _mean(scalar_times) * 1000.0 / float(maxi(positions.size(), 1)),
		"batch_total_mean_ms": _mean(batch_times), "batch_total_p95_ms": _percentile(batch_times, 0.95),
		"batch_us_per_query": _mean(batch_times) * 1000.0 / float(maxi(positions.size(), 1)),
		"batch_speedup": _mean(scalar_times) / maxf(_mean(batch_times), 0.000001),
		"scalar_coastal_profile_us": _profile_dict(scalar_profile),
		"batch_coastal_profile_us": _profile_dict(batch_profile),
		"batch_coastal_profile_detail": _profile_detail_dict(batch_profile_detail),
		"batch_diagnostics_available": not execution.is_empty(),
		"batch_wrapper_profile_us": {
			"prepare": wrapper_profile[0] if wrapper_profile.size() > 0 else 0,
			"input_array_copy": wrapper_profile[1] if wrapper_profile.size() > 1 else 0,
			"native_core": wrapper_profile[2] if wrapper_profile.size() > 2 else 0,
			"output_array_copy": wrapper_profile[3] if wrapper_profile.size() > 3 else 0,
		},
		"batch_execution": {
			"material_avx2": execution.size() > 0 and execution[0] == 1,
			"world_avx2": execution.size() > 1 and execution[1] == 1,
			"coastal_deep_avx2": execution.size() > 2 and execution[2] == 1,
			"newton_histogram_0_to_12_then_nonconverged": newton_histogram,
		},
		"checksum": scalar_sum + batch_sum,
	}


func _time_world_warm(native: Object, time: float, world_positions: PackedVector3Array,
		cold_mean_ms: float) -> Dictionary:
	var initial_q := PackedVector3Array()
	for point in world_positions:
		var previous: PackedFloat64Array = native.call("sample_world_with_material_q", point.x, point.z, time - (1.0 / 60.0))
		initial_q.append(Vector3(previous[STRIDE], 0.0, previous[STRIDE + 1]))
	native.call("ensure_prepared", time)
	native.call("reset_coastal_profile")
	var cold: PackedFloat64Array = native.call("sample_batch", time, world_positions)
	native.call("reset_coastal_profile")
	var warm: PackedFloat64Array = native.call("sample_batch_warm_prepared", world_positions, initial_q)
	var max_error := 0.0
	var worst := {}
	var residual_error := 0.0
	var iteration_error := 0.0
	for index in world_positions.size():
		for field in 13:
			var error := absf(cold[index * STRIDE + field] - warm[index * (STRIDE + 2) + field])
			if error > max_error:
				max_error = error
				worst = {"index": index, "field": field, "cold": cold[index * STRIDE + field], "warm": warm[index * (STRIDE + 2) + field]}
		residual_error = maxf(residual_error, absf(cold[index * STRIDE + 13] - warm[index * (STRIDE + 2) + 13]))
		iteration_error = maxf(iteration_error, absf(cold[index * STRIDE + 14] - warm[index * (STRIDE + 2) + 14]))
	if max_error > 1.0e-5:
		_fail("Warm world-XZ physical output differs from cold: %s" % JSON.stringify({"max_error": max_error, "worst": worst}))
		return {}
	native.call("reset_coastal_profile")
	var times: Array[float] = []
	for repeat_index in REPEATS:
		var start := Time.get_ticks_usec()
		native.call("sample_batch_warm_prepared", world_positions, initial_q)
		times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	var profile: PackedInt64Array = native.call("get_coastal_profile_us")
	var wrapper: PackedInt64Array = native.call("get_last_batch_profile_us")
	var execution: PackedInt32Array = native.call("get_last_batch_diagnostics")
	return {
		"previous_frame_seed": true,
		"batch_total_mean_ms": _mean(times),
		"batch_total_p95_ms": _percentile(times, 0.95),
		"batch_speedup_vs_cold": cold_mean_ms / maxf(_mean(times), 0.000001),
		"max_cold_error": max_error,
		"max_cold_error_worst": worst,
		"max_residual_difference": residual_error,
		"max_iteration_count_difference": iteration_error,
		"coastal_profile_us": _profile_dict(profile),
		"wrapper_profile_us": {
			"prepare": wrapper[0], "input_array_copy": wrapper[1],
			"native_core": wrapper[2], "output_array_copy": wrapper[3],
		},
		"batch_execution": {
			"world_avx2": execution[1] == 1,
			"coastal_deep_avx2": execution[2] == 1,
		},
	}


func _profile_dict(values: PackedInt64Array) -> Dictionary:
	return {
		"base_spectra": values[0], "sampler": values[1],
		"coastal_q": values[2], "coastal_deep": values[3],
		"combine": values[4], "active_calls": values[5],
	}


func _profile_detail_dict(values: PackedInt64Array) -> Dictionary:
	if values.size() < 93:
		return {}
	var stages: Array[String] = ["center", "+X", "-X", "+Z", "-Z"]
	var bands: Array[String] = ["LONG", "MID", "SHORT"]
	var output := {"stages": {}}
	var stage_data := output["stages"] as Dictionary
	for stage_index in stages.size():
		var stage := {
			"base_mode_ns": {}, "base_reduce_ns": {}, "base_mode_evaluations": {},
			"deep_mode_ns": values[30 + stage_index], "deep_reduce_ns": values[35 + stage_index],
			"sampler_ns": values[40 + stage_index], "combine_ns": values[45 + stage_index],
			"base_vector_sincos_calls": values[70 + stage_index],
			"base_direct_sincos_calls": values[75 + stage_index],
			"deep_mode_evaluations": values[65 + stage_index],
			"deep_vector_sincos_calls": values[80 + stage_index],
			"deep_direct_sincos_calls": values[85 + stage_index],
		}
		var mode_ns := stage["base_mode_ns"] as Dictionary
		var reduce_ns := stage["base_reduce_ns"] as Dictionary
		var evaluations := stage["base_mode_evaluations"] as Dictionary
		for band_index in bands.size():
			var flat_index := stage_index * 3 + band_index
			mode_ns[bands[band_index]] = values[flat_index]
			reduce_ns[bands[band_index]] = values[15 + flat_index]
			evaluations[bands[band_index]] = values[50 + flat_index]
		stage_data[stages[stage_index]] = stage
	output["fused_stencil_mode_ns"] = values[90]
	output["fused_stencil_mode_evaluations"] = values[91]
	output["fused_stencil_sincos_calls"] = values[92]
	return output


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _percentile(values: Array[float], percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil((sorted.size() - 1) * clampf(percentile, 0.0, 1.0))), 0, sorted.size() - 1)
	return float(sorted[index])


func _fail(message: String) -> void:
	printerr("TARGET_PHYS_NATIVE_FAIL=" + message)
	if _ocean != null and is_instance_valid(_ocean):
		_ocean.queue_free()
	quit(1)
