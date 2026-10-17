extends SceneTree
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var failures: Array[String] = []
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	var n := 128
	var floats := PackedFloat32Array()
	floats.resize(n * n * 4)
	for i in n * n:
		floats[4 * i] = sin(float(i) * 0.71) * 0.003
		floats[4 * i + 1] = cos(float(i) * 0.37) * 0.003
		floats[4 * i + 2] = sin(float(i) * 0.19) * 0.003
		floats[4 * i + 3] = cos(float(i) * 0.53) * 0.003
	var bands: Array = []
	for b in 3:
		bands.append({"resolution": n, "domain_size_m": 256.0 / (b + 1), "gravity_mps2": 9.81, "choppiness": 1.0, "h0_rgba32f": floats.to_byte_array()})
	native.call("set_production_spectrum", bands)
	native.call("perf1_set_context", 7, 100, 100, 1, false, 1)
	native.call("build_dynamic_physics_lite", 1.0, PackedInt32Array([n,n,n]))
	var before: PackedFloat64Array = native.call("sample_dynamic_lite_surface", 0, 2.3, -4.7, 0.0, 1)
	# Explicit fixture override: capture without ETW and without a slow threshold.
	native.call("perf3_set_fft_probe", true, false, 0)
	native.call("build_dynamic_physics_lite", 1.0, PackedInt32Array([n,n,n]))
	var after: PackedFloat64Array = native.call("sample_dynamic_lite_surface", 0, 2.3, -4.7, 0.0, 1)
	if before.to_byte_array() != after.to_byte_array(): failures.append("probe changed water query")
	var directory := ProjectSettings.globalize_path("res://temp/perf3-fixture")
	DirAccess.make_dir_recursive_absolute(directory)
	var snapshots: Array = native.call("get_perf3_fft_snapshots")
	if snapshots.size() != 3: failures.append("expected one snapshot per band")
	for s: Dictionary in snapshots:
		var file := FileAccess.open(directory.path_join("band_%d.bin" % int(s.band)), FileAccess.WRITE)
		file.store_buffer(s.bytes)
		file.close()
	if not native.call("get_perf3_fft_snapshots").is_empty(): failures.append("snapshot exported twice")
	print("PERF3_SNAPSHOT_VALIDATION ", JSON.stringify({"status": "PASS" if failures.is_empty() else "FAIL", "failures": failures, "snapshots": snapshots.size(), "directory": directory}))
	native = null
	quit(0 if failures.is_empty() else 1)
