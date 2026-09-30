extends SceneTree
## Reproducible native scalar/batch benchmark across PHYS-1/2/3 band sets.
## All inputs and native setup are prepared outside each timed query loop.

const OCEAN_SCENE := preload("res://addons/ocean/ocean.tscn")
const SpectrumAdapter := preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const DESCRIPTOR := "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"
const QUERY_COUNTS := [1, 4, 16, 64, 256]
const REPEATS := 3
const STRIDE := 15
const INDEX_DX := 2
const INDEX_DY := 3
const INDEX_DZ := 4

var _ocean: Node
var _quick_smoke := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--target-phys-quick-smoke":
			_quick_smoke = true
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
	var query_counts: Array = [1, 4] if _quick_smoke else QUERY_COUNTS
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
		print("TARGET_PHYS_NATIVE_CONFIGURATION " + JSON.stringify({"label": config["label"], "mask": config["mask"], "coastal": config["coastal"], "bands": setup.get("bands", []), "coastal_generation": coastal.get("generation", -1) if bool(config["coastal"]) else null}))
		var world_positions := _make_world_positions(native, positions, time)
		for count_variant in query_counts:
			var count := int(count_variant)
			var subset := PackedVector3Array()
			var world_subset := PackedVector3Array()
			for index in count:
				subset.append(positions[index])
				world_subset.append(world_positions[index])
			var material_check := _compare_paths(native, time, subset, false)
			var world_check := _compare_paths(native, time, world_subset, true)
			if float(material_check["max_scalar_batch_error"]) > 1.0e-8 or float(world_check["max_scalar_batch_error"]) > 1.0e-5:
				_fail("Scalar/batch correctness exceeded tolerance for %s / %d: material=%s world=%s" % [config["label"], count, material_check, world_check])
				return
			var material_timing := _time_paths(native, time, subset, false)
			var world_timing := _time_paths(native, time, world_subset, true)
			print("TARGET_PHYS_NATIVE_RESULT " + JSON.stringify({
				"configuration": config["label"], "queries": count,
				"material_q": material_timing, "world_xz": world_timing,
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
	for index in positions.size():
		var point := positions[index]
		var scalar: PackedFloat64Array
		if world_xz:
			scalar = native.call("sample_world", point.x, point.z, time)
		else:
			scalar = native.call("sample_material_q", point.x, point.z, time)
		for field in STRIDE:
			max_error = maxf(max_error, absf(batch[index * STRIDE + field] - scalar[field]))
	return {"max_scalar_batch_error": max_error}


func _time_paths(native: Object, time: float, positions: PackedVector3Array, world_xz: bool) -> Dictionary:
	var scalar_times: Array[float] = []
	var batch_times: Array[float] = []
	var scalar_sum := 0.0
	var batch_sum := 0.0
	for repeat_index in REPEATS:
		var start := Time.get_ticks_usec()
		for point in positions:
			var value: PackedFloat64Array
			if world_xz:
				value = native.call("sample_world", point.x, point.z, time)
			else:
				value = native.call("sample_material_q", point.x, point.z, time)
			scalar_sum += value[INDEX_DY]
		scalar_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
		start = Time.get_ticks_usec()
		var batch: PackedFloat64Array
		if world_xz:
			batch = native.call("sample_batch", time, positions)
		else:
			batch = native.call("sample_material_q_batch", time, positions)
		batch_sum += batch[INDEX_DY]
		batch_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
	return {
		"scalar_total_mean_ms": _mean(scalar_times), "scalar_total_p95_ms": _percentile(scalar_times, 0.95),
		"scalar_us_per_query": _mean(scalar_times) * 1000.0 / float(maxi(positions.size(), 1)),
		"batch_total_mean_ms": _mean(batch_times), "batch_total_p95_ms": _percentile(batch_times, 0.95),
		"batch_us_per_query": _mean(batch_times) * 1000.0 / float(maxi(positions.size(), 1)),
		"batch_speedup": _mean(scalar_times) / maxf(_mean(batch_times), 0.000001),
		"checksum": scalar_sum + batch_sum,
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
