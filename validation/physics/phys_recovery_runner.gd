extends SceneTree
## Uses Production time. Reports render-clock jumps separately from producer
## misses, including a deliberate main-thread hitch and recovery trace.

const OCEAN_SCENE = preload("res://addons/ocean/ocean.tscn")
const COASTAL_BAKE = preload("res://validation/p4_paradise/coastal_bake.tres")
const ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const BUILD_ID = preload("res://validation/physics/phys_native_build_contract.gd").ID
const DT = 1.0 / 60.0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var ticks := _arg("--ticks=", 3600)
	var load_ms := _arg("--load-ms=", 0)
	var hitch_ms := _arg("--hitch-ms=", 0)
	var workers := _arg("--workers=", 5)
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for property in ["breakers", "crest_foam", "surface_foam"]: ocean.set(property, false)
	root.add_child(ocean)
	for _i in 12: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var spectra: Array[Dictionary] = fft.call("get_phys2_band_spectrum_snapshots")
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native == null or String(native.call("get_dynamic_async_build_id")) != BUILD_ID:
		_fail("native DLL/build id unavailable"); return
	var setup_at := Time.get_ticks_usec()
	if not bool(native.call("set_production_spectrum", spectra)):
		_fail("bulk spectrum import failed"); return
	var import_ms := (Time.get_ticks_usec() - setup_at) / 1000.0
	var legacy: Object = ClassDB.instantiate("OceanQueryNative")
	if not bool(ADAPTER.configure_bands(legacy, spectra, 0.0, 7).get("ok", false)):
		_fail("legacy bridge unavailable"); return
	var import_error := 0.0
	var frozen_time := float(ocean.call("get_wave_time"))
	for band in 3:
		var domain := float(spectra[band]["domain_size_m"])
		var n := int(spectra[band]["resolution"])
		for j in 8:
			var q := Vector2((posmod(j * 47 + 3, n) + 0.5) * domain / n - domain * 0.5,
				(posmod(j * 83 + 11, n) + 0.5) * domain / n - domain * 0.5)
			var a: PackedFloat64Array = native.call("sample_material_q_with_band_mask", q.x, q.y, frozen_time, (1 << (band + 1)) - 1)
			var b: PackedFloat64Array = legacy.call("sample_material_q_with_band_mask", q.x, q.y, frozen_time, (1 << (band + 1)) - 1)
			for f in a.size(): import_error = maxf(import_error, absf(a[f] - b[f]))
	if import_error > 0.00001:
		_fail("bulk import disagrees with legacy bridge: " + str(import_error)); return
	var coastal: Dictionary = fft.call("get_phys3_coastal_snapshot")
	if not bool(coastal.get("active", false)) or not bool(ADAPTER.configure_coastal(native, coastal).get("ok", false)):
		_fail("active Coastal setup failed"); return
	native.call("set_dynamic_worker_count", workers)
	if not bool(native.call("start_dynamic_async_fields", frozen_time, 0)):
		_fail("async startup failed"); return
	ocean.set("wave_speed_multiplier", 1.0)
	var tick := 0
	# Prime renderer shaders and native buffers; warmup is explicitly excluded.
	for _i in 180:
		await physics_frame
		tick += 1
		var now := float(ocean.call("get_wave_time"))
		native.call("advance_dynamic_async", tick, now, now + DT, DT)
	var ages: Array = []; var queries: Array = []; var waits: Array = []; var builds: Array = []
	var wall_gaps: Array = []; var wave_steps: Array = []; var trace: Array = []
	var bad := 0; var regressions := 0; var mixed := 0
	var previous_time := float(ocean.call("get_wave_time"))
	var previous_field := -1.0
	var previous_wall := Time.get_ticks_usec()
	var previous_builds := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[3])
	var before: PackedInt64Array = native.call("get_dynamic_async_stats")
	for i in ticks:
		if hitch_ms > 0 and i == 500: native.call("run_dynamic_contention_us", hitch_ms * 1000)
		await physics_frame
		tick += 1
		var now := float(ocean.call("get_wave_time"))
		var wall := Time.get_ticks_usec()
		var result: PackedInt64Array = native.call("advance_dynamic_async", tick, now, now + DT, DT)
		var age := result[7] / 1000000.0
		var field := result[3] / 1000000000.0
		ages.append(age); waits.append(result[6] / 1000.0)
		wall_gaps.append((wall - previous_wall) / 1000.0); wave_steps.append((now - previous_time) / DT)
		if field < previous_field - 0.0000001: regressions += 1
		var at := Time.get_ticks_usec()
		var sample: PackedFloat64Array = native.call("sample_dynamic_material_q", 123.456, -78.9)
		queries.append((Time.get_ticks_usec() - at) / 1000.0)
		if sample.size() != 15: bad += 1
		var info: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
		if info.size() != 3 or info[0] != info[1] or info[1] != info[2]: mixed += 1
		var stats: PackedInt64Array = native.call("get_dynamic_async_stats")
		if int(stats[3]) != previous_builds:
			builds.append(stats[34] / 1000.0)
			previous_builds = int(stats[3])
		if age >= 2.0 or (hitch_ms > 0 and i >= 498 and i <= 540):
			trace.append({"i": i, "age": age, "wave_step_ticks": (now - previous_time) / DT,
				"main_gap_ms": (wall - previous_wall) / 1000.0, "field_time": field,
				"wave_time": now, "build_ms": stats[34] / 1000.0, "worker": stats[22]})
		if load_ms > 0: native.call("run_dynamic_contention_us", load_ms * 1000)
		previous_time = now; previous_wall = wall; previous_field = field
	var after: PackedInt64Array = native.call("get_dynamic_async_stats")
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 60:
		await physics_frame
		tick += 1
		var now := float(ocean.call("get_wave_time"))
		native.call("advance_dynamic_async", tick, now, now, DT)
	var pause_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	var pause_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	for _i in 30:
		await physics_frame
		tick += 1
		var now := float(ocean.call("get_wave_time"))
		native.call("advance_dynamic_async", tick, now, now, DT)
	var pause_after: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	var end_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	var freeze := pause_info[1] == pause_after[1] and pause_stats[3] == end_stats[3]
	ocean.set("wave_speed_multiplier", 1.0)
	for _i in 60:
		await physics_frame
		tick += 1
		var now := float(ocean.call("get_wave_time"))
		native.call("advance_dynamic_async", tick, now, now + DT, DT)
	var resumed: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	# Model a renderer holding the native reference while its owner shuts down.
	# The reader must see one complete immutable spectrum or an empty result.
	var reader_started := Semaphore.new()
	var reader := Thread.new()
	reader.start(_read_during_shutdown.bind(native, reader_started))
	reader_started.wait()
	native.call("clear")
	var shutdown_reader_safe := bool(reader.wait_to_finish())
	var report := {"build_id": BUILD_ID, "ticks": ticks, "load_ms": load_ms, "hitch_ms": hitch_ms,
		"coastal_active": true, "workers": native.call("get_dynamic_worker_count"),
		"stale_ge_1_tick": ages.filter(func(age): return age >= 1.0).size(),
		"stale_ge_2_ticks": ages.filter(func(age): return age >= 2.0).size(),
		"stale_ge_3_ticks": ages.filter(func(age): return age >= 3.0).size(),
		"bulk_import_ms": import_ms, "bulk_vs_legacy_max": import_error,
		"build_ms": _stats(builds), "age_ticks": _stats(ages), "query_ms": _stats(queries),
		"wait_ms": _stats(waits), "wall_gap_ms": _stats(wall_gaps), "wave_step_ticks": _stats(wave_steps),
		"misses": after[7] - before[7], "requests": after[1] - before[1], "coalesced": after[24] - before[24],
		"buffer_wait_us": after[26] - before[26], "regressions": regressions, "mixed": mixed,
		"bad_queries": bad, "freeze": freeze, "resume": resumed[1] > pause_after[1],
		"shutdown_reader_safe": shutdown_reader_safe, "trace": trace}
	var suffix := "" if workers == 5 else "_w%d" % workers
	var output := FileAccess.open("res://.godot/phys_recovery_%d_%d_%d%s.json" % [ticks, load_ms, hitch_ms, suffix], FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t")); output.close()
	print("PHYS_RECOVERY=" + JSON.stringify(report.merged({"trace": trace.slice(0, 20)}, true)))
	quit(0 if bad == 0 and mixed == 0 and regressions == 0 and freeze and resumed[1] > pause_after[1] and shutdown_reader_safe else 1)

func _read_during_shutdown(native: Object, started: Semaphore) -> bool:
	var notified := false
	for _i in 1000:
		var spectra: Array = native.call("get_dynamic_snapshot_spectrum")
		if not notified:
			started.post(); notified = true
		if spectra.is_empty(): return true
		if spectra.size() != 3: return false
		for band in spectra:
			if band.generation != spectra[0].generation or band.configuration_version != spectra[0].configuration_version \
					or band.wave_time != spectra[0].wave_time: return false
	return false

func _arg(prefix: String, fallback: int) -> int:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(prefix): return int(arg.substr(prefix.length()))
	return fallback

func _stats(source: Array) -> Dictionary:
	if source.is_empty(): return {"count": 0}
	var values := source.duplicate(); values.sort()
	var total := 0.0
	for value in values: total += float(value)
	var result := {"count": values.size(), "mean": total / values.size(), "max": values.back()}
	for p in [50, 95, 99]: result["p%d" % p] = values[clampi(int(ceil(values.size() * p / 100.0)) - 1, 0, values.size() - 1)]
	return result

func _fail(message: String) -> void:
	printerr("PHYS_RECOVERY_FAIL=" + message); quit(1)
