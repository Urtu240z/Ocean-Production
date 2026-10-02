extends SceneTree

const OCEAN_SCENE: PackedScene = preload("res://addons/ocean/ocean.tscn")
const ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const CUMULATIVE_BAND_MASKS := [1, 3, 7]
const BAND_NAMES := ["LONG", "MID", "SHORT"]
const PROFILE_FIELDS := ["phase", "evolve", "frequency_prepare", "row_x_including_normalization",
	"transpose_to_columns", "row_z_including_normalization", "transpose_back", "unpack"]
const PROFILE_SUFFIXES := ["prepare_queue", "prepare_barrier_wall", "transform_queue", "transform_barrier_wall", "publication"]

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var ticks := _arg_int("--ticks=", 600)
	var workers := _arg_int("--workers=", 4)
	var load_ms := _arg_int("--load-ms=", 0)
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("long_enabled", true)
	ocean.set("mid_enabled", true)
	ocean.set("short_enabled", true)
	ocean.set("coastal", true)
	ocean.set("breakers", false)
	ocean.set("crest_foam", false)
	ocean.set("surface_foam", false)
	root.add_child(ocean)
	for _i in 6:
		await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4:
		await physics_frame
	var fft: Node = ocean.get_node_or_null("OpenOceanFFT")
	if fft == null:
		_fail("OpenOceanFFT missing")
		return
	var snapshots: Array[Dictionary] = fft.call("get_phys2_band_spectrum_snapshots")
	if snapshots.size() != 3:
		_fail("Expected LONG/MID/SHORT spectrum snapshots")
		return
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	var configured: Dictionary = ADAPTER.configure_bands(native, snapshots, float(ocean.get("sea_level")), 7)
	if not bool(configured.get("ok", false)):
		_fail("native configuration failed: " + str(configured))
		return
	var wave_time := float(ocean.call("get_wave_time"))
	if not bool(native.call("build_dynamic_physics_fields", wave_time)):
		_fail("initial CPU FFT mirror build failed")
		return
	var lattice_errors: Array[float] = []
	for band in [0]:
		var n := int(snapshots[band]["resolution"])
		var domain := float(snapshots[band]["domain_size_m"])
		for sample_index in 64:
			var ix := posmod(sample_index * 47 + 3, n)
			var iz := posmod(sample_index * 83 + 11, n)
			var qx := (float(ix) + 0.5) * domain / n - 0.5 * domain
			var qz := (float(iz) + 0.5) * domain / n - 0.5 * domain
			var direct: PackedFloat64Array = native.call("sample_material_q_with_band_mask", qx, qz, wave_time, CUMULATIVE_BAND_MASKS[band])
			var mirror: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band, qx, qz)
			if direct.size() < 15 or mirror.size() != 12:
				_fail("invalid direct/mirror parity smoke result band=%d direct=%d mirror=%d" % [band, direct.size(), mirror.size()])
				return
			for pair in [[mirror[0], direct[3]], [mirror[1], direct[2]], [mirror[2], direct[4]],
				[mirror[9], direct[9]], [mirror[10], direct[8]], [mirror[11], direct[10]]]:
				lattice_errors.append(absf(float(pair[0]) - float(pair[1])))
	if int(native.call("set_dynamic_worker_count", workers)) != workers:
		_fail("worker count change failed")
	if not bool(native.call("start_dynamic_async_fields", wave_time, 0)):
		_fail("async publisher failed to start")
	var build_id := String(native.call("get_dynamic_async_build_id"))
	if build_id != "PHYS-OPT-2E-packed-avx-twiddle-v2":
		_fail("stale native DLL: " + build_id)
	ocean.set("wave_speed_multiplier", 1.0)
	var tick_id := 0
	var previous_builds := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[3])
	var build_ms: Array[float] = []
	var stage_samples: Array = []
	for _i in 29:
		stage_samples.append([])
	var queries_ms: Array[float] = []
	var age_ticks: Array[float] = []
	var query_failures := 0
	for _i in ticks:
		await physics_frame
		tick_id += 1
		var now := float(ocean.call("get_wave_time"))
		var result: PackedInt64Array = native.call("advance_dynamic_async", tick_id, now, now + 1.0 / 60.0, 1.0 / 60.0)
		if result.size() < 8:
			query_failures += 1
			continue
		age_ticks.append(float(result[7]) / 1000000.0)
		var q0 := Time.get_ticks_usec()
		var sample: PackedFloat64Array = native.call("sample_dynamic_material_q", 123.456, -78.9)
		queries_ms.append(float(Time.get_ticks_usec() - q0) / 1000.0)
		if sample.size() < 15:
			query_failures += 1
		if load_ms > 0:
			native.call("run_dynamic_contention_us", load_ms * 1000)
		var stats: PackedInt64Array = native.call("get_dynamic_async_stats")
		if int(stats[3]) > previous_builds:
			var completed := int(stats[3]) - previous_builds
			var profile: PackedInt64Array = native.call("get_dynamic_async_profile_us")
			for _build in completed:
				build_ms.append(float(stats[34]) / 1000.0)
				for slot in min(profile.size(), stage_samples.size()):
					stage_samples[slot].append(float(profile[slot]) / 1000.0)
			previous_builds = int(stats[3])
	# Freeze and drain after timing. Compare the async packed snapshot against a
	# synchronous SoA build at the exact published timestamp to isolate layout
	# and checkerboard-coordinate correctness from continuous interpolation error.
	ocean.set("wave_speed_multiplier", 0.0)
	var snapshot_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	var drain_ok := false
	for _i in 240:
		await physics_frame
		var frozen_time := float(ocean.call("get_wave_time"))
		tick_id += 1
		native.call("advance_dynamic_async", tick_id, frozen_time, frozen_time, 1.0 / 60.0)
		snapshot_info = native.call("get_dynamic_snapshot_info")
		var current_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
		if int(snapshot_info[0]) == 1 and int(snapshot_info[4]) > 1 and int(current_stats[22]) == 0:
			drain_ok = true
			break
	var packed_soa_errors: Array[float] = []
	var packed_soa_by_field: Array = []
	for _field in 12:
		packed_soa_by_field.append([])
	var packed_first_sample := {}
	if drain_ok:
		var published_time := float(snapshot_info[1]) / 1000000000.0
		var reference: Object = ClassDB.instantiate("OceanQueryNative")
		var reference_config: Dictionary = ADAPTER.configure_bands(reference, snapshots, float(ocean.get("sea_level")), 7)
		if not bool(reference_config.get("ok", false)) or not bool(reference.call("build_dynamic_physics_fields", published_time)):
			_fail("SoA parity reference failed to build at published time")
			return
		for band in 3:
			var n := int(snapshots[band]["resolution"])
			var domain := float(snapshots[band]["domain_size_m"])
			for sample_index in 64:
				var ix := posmod(sample_index * 47 + 3, n)
				var iz := posmod(sample_index * 83 + 11, n)
				var qx := (float(ix) + 0.5) * domain / n - 0.5 * domain
				var qz := (float(iz) + 0.5) * domain / n - 0.5 * domain
				var soa: PackedFloat64Array = reference.call("sample_dynamic_band_material_q", band, qx, qz)
				var packed: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band, qx, qz)
				if soa.size() != 12 or packed.size() != 12:
					_fail("invalid packed/SoA parity sample")
					return
				for field in 12:
					var error := absf(float(packed[field]) - float(soa[field]))
					packed_soa_errors.append(error)
					packed_soa_by_field[field].append(error)
				if packed_first_sample.is_empty():
					packed_first_sample = {"band": band, "q": [qx, qz], "soa": Array(soa), "packed": Array(packed)}
	var final_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	var stage_report := {}
	for band in 3:
		for field_index in PROFILE_FIELDS.size():
			stage_report["%s.%s_ms" % [BAND_NAMES[band], PROFILE_FIELDS[field_index]]] = _statistics(stage_samples[band * 8 + field_index])
	for suffix_index in PROFILE_SUFFIXES.size():
		stage_report["scheduler.%s_ms" % PROFILE_SUFFIXES[suffix_index]] = _statistics(stage_samples[24 + suffix_index])
	var band_config := []
	for band in 3:
		band_config.append({"band": BAND_NAMES[band], "N": int(snapshots[band]["resolution"]),
			"L_m": float(snapshots[band]["domain_size_m"])})
	print("PHYS_OPT_2E_PRODUCER=" + JSON.stringify({
		"build_id": build_id, "workers": workers, "ticks": ticks, "main_load_ms": load_ms,
		"bands": band_config, "lattice_oracle_error_m_or_mps": _statistics(lattice_errors),
		"packed_vs_soa_same_snapshot_time": {"drained": drain_ok, "errors": _statistics(packed_soa_errors),
			"by_field": packed_soa_by_field.map(func(errors): return _statistics(errors)), "first_sample": packed_first_sample},
		"build_ms": _statistics(build_ms), "stage_ms": stage_report,
		"query_ms": _statistics(queries_ms), "field_age_ticks": _statistics(age_ticks),
		"misses": int(final_stats[7]), "builds": int(final_stats[3]), "requests": int(final_stats[1]),
		"coalesced": int(final_stats[24]), "obsolete": int(final_stats[25]),
		"buffer_wait_us": int(final_stats[26]), "query_failures": query_failures,
		"gpu_readback": false}))
	quit(0 if query_failures == 0 else 1)

func _arg_int(prefix: String, fallback: int) -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix):
			return int(arg.substr(prefix.length()))
	return fallback

func _statistics(source: Array) -> Dictionary:
	if source.is_empty():
		return {"count": 0}
	var values: Array = source.duplicate()
	values.sort()
	var total := 0.0
	for value in values:
		total += float(value)
	return {"count": values.size(), "mean": total / values.size(), "p50": _quantile(values, 0.50),
		"p90": _quantile(values, 0.90), "p95": _quantile(values, 0.95),
		"p99": _quantile(values, 0.99), "max": float(values.back())}

func _quantile(sorted_values: Array, fraction: float) -> float:
	return float(sorted_values[clampi(int(ceil(fraction * sorted_values.size())) - 1, 0, sorted_values.size() - 1)])

func _fail(message: String) -> void:
	printerr("PHYS_OPT_2E_PRODUCER_FAIL=" + message)
	quit(1)
