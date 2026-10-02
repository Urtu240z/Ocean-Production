extends "res://validation/physics/phys_weather_runner.gd"
## End-to-end weather timing without frozen oracle/probe work in the loop.

func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native == null or native.call("get_dynamic_async_build_id") != preload("res://validation/physics/phys_native_build_contract.gd").ID:
		_fail("current native build required"); return
	if not native.call("set_production_spectrum", fft.call("get_phys2_band_spectrum_snapshots")):
		_fail("initial spectrum import"); return
	if not bool(ADAPTER.configure_coastal(native, fft.call("get_phys3_coastal_snapshot")).get("ok", false)):
		_fail("active Coastal setup"); return
	native.call("set_dynamic_worker_count", 5)
	if not native.call("start_dynamic_async_fields", ocean.call("get_wave_time"), 0):
		_fail("async startup"); return
	_weather = WEATHER.new(native, fft)
	ocean.set("wave_speed_multiplier", 1.0)
	for _i in 180:
		await physics_frame
		_advance(ocean, native)
	_ages.clear(); _queries.clear(); _polls.clear()
	var rows: Array = []; var builds: Array = []
	var prepare_wall: Array = []; var transform_wall: Array = []; var outside_fft: Array = []
	var mixed := 0
	var last_build := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[3])
	for state in [
		{"name": "calm", "hs": 0.8, "wind": 4.0, "direction": 20.0, "chop": 0.8},
		{"name": "storm", "hs": 3.0, "wind": 18.0, "direction": 75.0, "chop": 2.0},
		{"name": "calm_again", "hs": 0.8, "wind": 4.0, "direction": 20.0, "chop": 0.8},
	]:
		var profile: Resource = ocean.get("wave_profile")
		var configs: Array = profile.call("build_fft_configs", state.hs, state.wind, state.direction,
			ocean.get("swell"), ocean.get("long_wave_spacing"))
		configs[0].choppiness = state.chop
		var serial := int(_weather.call("request", configs, {
			"seed": ocean.get("simulation_seed"), "overall_hs": state.hs,
			"profile_hs": profile.call("combined_significant_wave_height_m"), "wave_height_scale": 1.0,
			"band_scales": [1.0, 1.0, 1.0], "mid_fill": ocean.get("mid_fill_amount")}, 3.0))
		var ready := {}; var complete := false
		var wanted_version := -1
		var state_start := _ages.size()
		for _i in 600:
			await physics_frame
			var result := _advance(ocean, native)
			if not result.is_empty():
				if not bool(result.get("ok", false)) or int(result.serial) != serial:
					_fail("weather request failed"); return
				ready = result
			var stats: PackedInt64Array = native.call("get_dynamic_async_stats")
			if not result.is_empty(): wanted_version = int(stats[21])
			if int(stats[3]) != last_build:
				builds.append(stats[34] / 1000.0); last_build = int(stats[3])
				var profile_us: PackedInt64Array = native.call("get_dynamic_async_profile_us")
				var prepare_ms := (profile_us[24] + profile_us[25]) / 1000.0
				var transform_ms := (profile_us[26] + profile_us[27]) / 1000.0
				prepare_wall.append(prepare_ms); transform_wall.append(transform_ms)
				outside_fft.append(maxf(0.0, stats[34] / 1000.0 - prepare_ms - transform_ms))
			var times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
			if times.size() != 3 or times[0] != times[1] or times[1] != times[2]: mixed += 1
			var info: Array = native.call("get_dynamic_snapshot_spectrum", false)
			if not ready.is_empty() and info.size() == 3 and int(info[0].configuration_version) == wanted_version \
					and float(info[0].weather_alpha) >= 1.0:
				complete = true; break
		if not complete: _fail("continuous weather ramp did not complete"); return
		rows.append({"state": state.name, "prepare_ms": ready.prepare_ms,
			"ticks": _ages.size() - state_start, "age_ticks": _stats(_ages.slice(state_start))})
	var report := {"build_id": preload("res://validation/physics/phys_native_build_contract.gd").ID,
		"states": rows, "mixed": mixed, "age_ticks": _stats(_ages), "build_ms": _stats(builds),
		"prepare_batch_ms": _stats(prepare_wall), "transform_batch_ms": _stats(transform_wall),
		"outside_fft_ms": _stats(outside_fft),
		"query_ms": _stats(_queries), "main_weather_poll_ms": _stats(_polls),
		"stale_ge_2_ticks": _ages.filter(func(v): return v >= 2.0).size(),
		"stale_ge_3_ticks": _ages.filter(func(v): return v >= 3.0).size(),
		"oracle_in_timed_loop": false}
	var output := FileAccess.open("res://.godot/phys_weather_freshness.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t")); output.close()
	_weather.call("shutdown"); _weather = null
	native.call("clear")
	print("PHYS_WEATHER_FRESHNESS=" + JSON.stringify(report))
	quit(0 if mixed == 0 else 1)
