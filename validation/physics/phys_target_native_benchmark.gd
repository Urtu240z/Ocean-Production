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

var _ocean: Node
var _quick_smoke := false
var _coastal_only := false
var _optimization_sweep := false


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
	var query_counts: Array = [1, 4] if _quick_smoke else ([1, 4, 8, 16] if _optimization_sweep else QUERY_COUNTS)
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
		var prepare_start := Time.get_ticks_usec()
		native.call("ensure_prepared", time)
		var prepare_time_us := Time.get_ticks_usec() - prepare_start
		print("TARGET_PHYS_NATIVE_CONFIGURATION " + JSON.stringify({"label": config["label"], "mask": config["mask"], "coastal": config["coastal"], "bands": setup.get("bands", []), "coastal_generation": coastal.get("generation", -1) if bool(config["coastal"]) else null, "cpu_supports_avx2": native.call("get_cpu_supports_avx2"), "selected_backend": native.call("get_query_execution_backend"), "batch_diagnostics_available": batch_diagnostics_available, "prepare_time_us": prepare_time_us}))
		var world_positions := _make_world_positions(native, positions, time)
		for count_variant in query_counts:
			var count := int(count_variant)
			var subset := PackedVector3Array()
			var world_subset := PackedVector3Array()
			for index in count:
				subset.append(positions[index])
				world_subset.append(world_positions[index])
			var material_check := _compare_paths(native, time, subset, false)
			var measure_world := not _optimization_sweep or count <= 8
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
				"world_scalar_batch_max_error": world_check["max_scalar_batch_error"],
				"time_ms": time,
			}))
		# OceanQueryNative is RefCounted; release it before configuring the next case.
		native = null
	print("TARGET_PHYS_NATIVE_COMPLETE")
	_ocean.queue_free()
	quit(0)


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
