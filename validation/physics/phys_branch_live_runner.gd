extends "res://validation/physics/phys_branch_continuity_runner.gd"
## Sustained real Production clock/weather path. No oracle in timed loop.
func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var native := _new_mirror(fft.call("get_phys2_band_spectrum_snapshots"), fft.call("get_phys3_coastal_snapshot"), ocean.call("get_wave_time"))
	if native == null: return
	_weather = WEATHER.new(native, fft)
	var targets := PackedVector3Array(); var history := PackedFloat64Array()
	for q in [Vector2(2000, -2000), Vector2(37.13506, 81.04028), Vector2(175.65347, -915.52533), Vector2(-168.3, -652.48)]:
		var w := _world(native, q); targets.append(Vector3(w.x, 0, w.y)); history.append_array(_state_at(native, q, w))
	var base_targets := targets.duplicate()
	var counts := [0, 0, 0, 0]; var query: Array = []; var delta: Array = []; var residual: Array = []; var iterations: Array = []
	var mixed := 0; var times_backwards := 0; var builds: Array = []; var last_build := -1
	var stages: Array = []; var pause := {}; var live_trace: Array = []
	ocean.set("wave_speed_multiplier", 1.0)
	for tick in 1200:
		if tick % 300 == 0:
			var s: Array = [[0.8, 4.0, 20.0, 0.8], [3.0, 18.0, 75.0, 2.0], [0.8, 4.0, 20.0, 0.8], [3.0, 18.0, 20.0, 2.0]][tick / 300]
			var profile: Resource = ocean.get("wave_profile")
			var configs: Array = profile.call("build_fft_configs", s[0], s[1], s[2], ocean.get("swell"), ocean.get("long_wave_spacing"))
			configs[0].choppiness = s[3]
			var serial: int = _weather.call("request", configs, {"seed": ocean.get("simulation_seed"), "overall_hs": s[0],
				"profile_hs": profile.call("combined_significant_wave_height_m"), "wave_height_scale": 1.0,
				"band_scales": [1.0, 1.0, 1.0], "mid_fill": ocean.get("mid_fill_amount")}, 3.0)
			stages.append({"tick": tick, "serial": serial, "state": s})
		await physics_frame
		var ready := _advance(ocean, native)
		if not ready.is_empty() and not ready.get("ok", false): _fail("live contact weather preparation"); return
		var wave_time := float(ocean.call("get_wave_time"))
		for i in 4: targets[i] = base_targets[i] + Vector3(sin(wave_time * 0.7), 0, cos(wave_time * 0.7)) * (0.2 if i == 0 else 0.01)
		var at := Time.get_ticks_usec()
		var rows: PackedFloat64Array = native.call("sample_dynamic_contact_batch", targets, history)
		query.append((Time.get_ticks_usec() - at) / 1000.0)
		if rows[0] == 0.0 or rows[CS] == 0.0 or rows[2 * CS] == 0.0 or rows[3 * CS] == 0.0:
			# Only a failure captures its exact immutable spectrum for offline
			# diagnosis; this is CPU state, outside the measured query interval.
			var capture := FileAccess.open("res://.godot/branch_failure_%d.bin" % tick, FileAccess.WRITE)
			capture.store_var({"bands": native.call("get_dynamic_snapshot_spectrum"), "history": history,
				"targets": targets, "rows": rows}); capture.close()
		for i in 4:
			var offset := i * CS
			counts[int(rows[offset + STATUS])] += 1; delta.append(rows[offset + 24]); residual.append(rows[offset + 13]); iterations.append(rows[offset + 14])
			if rows[offset + WT] < history[offset + WT]: times_backwards += 1
			if rows[offset + WT] != rows[WT] or rows[offset + 21] != rows[21] or rows[offset + 22] != rows[22]: mixed += 1
		live_trace.append({"tick": tick, "ocean_time": wave_time, "targets": Array(targets), "rows": Array(rows)})
		history = rows
		var st: PackedInt64Array = native.call("get_dynamic_async_stats")
		if st[3] != last_build: builds.append(st[34] / 1000.0); last_build = st[3]
		if tick == 600:
			ocean.set("wave_speed_multiplier", 0.0)
			for _j in 40:
				await physics_frame; _advance(ocean, native)
			history = native.call("sample_dynamic_contact_batch", targets, history)
			var before := history.duplicate(); var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
			var changed := 0; var reacquired := 0
			for _j in 30:
				await physics_frame; _advance(ocean, native)
				history = native.call("sample_dynamic_contact_batch", targets, history)
				for i in 4:
					for f in [QX, QZ, WT, 21, 22]:
						if history[i * CS + f] != before[i * CS + f]: changed += 1
					if history[i * CS + STATUS] != 0: reacquired += 1
			pause = {"ticks": 30, "changes": changed, "reacquired": reacquired, "field_frozen": info == native.call("get_dynamic_snapshot_info")}
			ocean.set("wave_speed_multiplier", 1.0)
	var report := {"build_id": preload("res://validation/physics/phys_native_build_contract.gd").ID, "ticks": 1200,
		"counts": counts, "query_N4_ms": _metrics(query), "residual": _metrics(residual), "iterations": _metrics(iterations),
		"q_delta": _metrics(delta), "build_ms": _metrics(builds), "field_age": _stats(_ages), "mixed": mixed,
		"time_backwards": times_backwards, "pause": pause, "weather": stages,
		"passed": counts[3] == 0 and mixed == 0 and times_backwards == 0 and pause.changes == 0 and pause.reacquired == 0 and pause.field_frozen}
	var file := FileAccess.open("res://.godot/phys_branch_live.json", FileAccess.WRITE); file.store_string(JSON.stringify(report, "\t")); file.close()
	file = FileAccess.open("res://.godot/phys_branch_live_trace.json", FileAccess.WRITE); file.store_string(JSON.stringify(live_trace)); file.close()
	_weather.call("shutdown"); _weather = null; native.call("clear")
	print("PHYS_BRANCH_LIVE=" + JSON.stringify(report)); quit(0 if report.passed else 1)
