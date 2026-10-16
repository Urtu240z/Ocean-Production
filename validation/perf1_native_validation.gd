extends SceneTree
## Synthetic fixture only: never changes production scene or saved settings.
const N := 128
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if not ClassDB.class_exists("OceanQueryNative"):
		failures.append("native extension missing")
		_finish({}); return
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	var baseline := OS.get_cmdline_user_args().has("--baseline")
	if not baseline and not native.has_method("get_perf1_capture"):
		failures.append("PERF-1 API missing"); _finish({}); return
	var floats := PackedFloat32Array()
	floats.resize(N * N * 4)
	for i in N * N:
		floats[4 * i] = sin(float(i) * 0.71) * 0.003
		floats[4 * i + 1] = cos(float(i) * 0.37) * 0.003
		floats[4 * i + 2] = sin(float(i) * 0.19) * 0.003
		floats[4 * i + 3] = cos(float(i) * 0.53) * 0.003
	var bands: Array = []
	for b in 3:
		bands.append({"resolution": N, "domain_size_m": 256.0 / (b + 1),
			"gravity_mps2": 9.81, "choppiness": 1.0, "h0_rgba32f": floats.to_byte_array()})
	if not native.call("set_production_spectrum", bands):
		failures.append("spectrum fixture import failed"); _finish({}); return
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	var reasons: Dictionary = {}
	var configured := false
	var times: Array[float] = [0.0]
	for i in range(1, 602): times.append(float(i) / 60.0)
	times.append(times[-1] + 0.30)
	times.append(0.05)
	for tick in times.size():
		if not baseline:
			native.call("perf1_set_context", tick, tick / 3, tick / 3, 1, false, 1)
			native.call("perf1_record_tick", tick, tick / 3, tick / 3)
		if not native.call("build_dynamic_physics_lite", times[tick], PackedInt32Array([N, N, N])):
			failures.append("build failed %d" % tick); break
		for band in 3:
			for point: Vector2 in [Vector2.ZERO, Vector2(2.3, -4.7), Vector2(-13.0, 9.2)]:
				var sample: PackedFloat64Array = native.call("sample_dynamic_lite_surface", band, point.x, point.y, 0.0, 1)
				digest.update(sample.to_byte_array())
		if not baseline:
			var capture: Dictionary = native.call("get_perf1_capture")
			var row: Dictionary = capture.records[-1]
			for band: Dictionary in row.bands:
				reasons[int(band.phase_reason)] = true
				if tick == 0 and int(band.configure_reason_mask) != 0: configured = true
			if row.physics_tick != tick or row.selected_backend != 1 or row.comparison_enabled:
				failures.append("incorrect context")
	if not baseline:
		for reason in [1, 3, 4]:
			if not reasons.has(reason): failures.append("missing phase reason %d" % reason)
		if not configured: failures.append("first configuration missing")
		var capture: Dictionary = native.call("get_perf1_capture")
		if int(capture.physics_frames[1].physics_steps) != 3: failures.append("physics step aggregation failed")
		var sample_before: PackedFloat64Array = native.call("sample_dynamic_lite_surface", 0, 2.0, 4.0)
		native.call("perf1_set_enabled", false)
		native.call("build_dynamic_physics_lite", times[-1], PackedInt32Array([N, N, N]))
		if sample_before != native.call("sample_dynamic_lite_surface", 0, 2.0, 4.0): failures.append("disabled capture changed sample")
		var reporter := preload("res://addons/ocean/physics/water/perf1_capture.gd").new()
		root.add_child(reporter)
		reporter.configure(native)
		await create_timer(0.25).timeout
		var capture_path: String = reporter.report_path
		reporter.queue_free()
		await process_frame
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(capture_path))
		if not parsed is Dictionary or int(parsed.get("schema_version", -1)) != 1:
			failures.append("automatic JSON capture failed")
	_finish({"baseline": baseline, "sample_sha256": digest.finish().hex_encode(), "builds": times.size(),
		"phase_reasons_seen": reasons.keys(), "automatic_report": not baseline})

func _finish(result: Dictionary) -> void:
	result["failures"] = failures
	result["status"] = "PASS" if failures.is_empty() else "FAIL"
	var suffix := "baseline" if OS.get_cmdline_user_args().has("--baseline") else "instrumented"
	var file := FileAccess.open("res://temp/perf1_%s_validation.json" % suffix, FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t")); file.close()
	print("PERF1_VALIDATION ", result)
	quit(0 if failures.is_empty() else 1)
