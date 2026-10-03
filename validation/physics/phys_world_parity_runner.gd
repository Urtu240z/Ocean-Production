extends "res://validation/physics/phys3_coastal_probe_runner.gd"
## PHYS-OPT-2J. Fixed legacy failure and native-double iteration trace.
func _run() -> void:
	load(NATIVE_DESCRIPTOR)
	_ocean = OCEAN_SCENE.instantiate()
	for name in ["long_enabled", "mid_enabled", "short_enabled", "coastal"]: _ocean.set(name, true)
	_ocean.set("coastal_bake", COASTAL_BAKE)
	for name in ["breakers", "crest_foam", "surface_foam"]: _ocean.set(name, false)
	for name in ["long_band_scale", "mid_band_scale", "short_band_scale", "wave_height_scale", "ocean_scale", "clipmap_geometry_scale"]: _ocean.set(name, 1.0)
	root.add_child(_ocean)
	for frame in 6: await RenderingServer.frame_post_draw
	_ocean.set("wave_speed_multiplier", 0.0)
	_fft = _ocean.get_node("OpenOceanFFT")
	_spectra = _fft.call("get_phys2_band_spectrum_snapshots")
	_bake_snapshot = _fft.call("get_phys3_coastal_snapshot")
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if not SPECTRUM_ADAPTER.configure_bands(native, _spectra, float(_ocean.get("sea_level")), 7).ok \
			or not SPECTRUM_ADAPTER.configure_coastal(native, _bake_snapshot).ok:
		_fail("world parity source configuration"); return
	if OS.get_cmdline_user_args().has("--sweep") or OS.get_cmdline_user_args().has("--baseline") or OS.get_cmdline_user_args().has("--storm-proof") or OS.get_cmdline_user_args().has("--moving-proof"):
		await _sweep(native)
		return
	var t := 0.473258666666665
	var samples: Array[Dictionary] = _make_bake_texel_samples(64, 1).slice(36, 40)
	if OS.get_cmdline_user_args().has("--compact-proof"):
		var candidates := _make_bake_texel_samples(64,1)
		samples = [candidates[5],candidates[19],candidates[5],candidates[39]]
	var worlds := PackedVector3Array()
	var sources := []
	for sample in samples:
		var q: Vector2 = sample.q
		var s: PackedFloat64Array = native.call("sample_material_q", q.x, q.y, t)
		var world := Vector3(q.x + s[DX], 0.0, q.y + s[DZ])
		worlds.append(world)
		sources.append({"q": [q.x, q.y], "world": [world.x, world.z]})
	if OS.get_cmdline_user_args().has("--mask-proof"):
		worlds = PackedVector3Array()
		sources = []
		for i in 4:
			worlds.append(Vector3(271.149230957031,0,-995.921691894531))
			sources.append({"world": [worlds[i].x,worlds[i].z],"region":"warp_mask_transition"})
	var report := {"build_id": native.call("get_dynamic_async_build_id"), "time": t,
		"sources": sources, "debug": native.call("debug_world_parity", t, worlds, 3)}
	if not OS.get_cmdline_user_args().has("--mask-proof"):
		report.batch = _validate_batch(native, samples, t)
	var packed_batch: PackedFloat64Array = native.call("sample_batch",t,worlds)
	var packing_max := 0.0; var native_error_max := 0.0
	var debug: Dictionary = report.debug
	for i in worlds.size():
		var s: PackedFloat64Array = native.call("sample_world_with_material_q",worlds[i].x,worlds[i].z,t)
		native_error_max = maxf(native_error_max,_distance(debug.scalar_native,i*17,debug.batch_native,i*17,[DX,DY,DZ]))
		for f in 17: packing_max = maxf(packing_max,absf(s[f]-debug.scalar_native[i*17+f]))
		for f in 15: packing_max = maxf(packing_max,absf(packed_batch[i*15+f]-debug.batch_native[i*17+f]))
	report.native_double_world_max = native_error_max
	report.packing_max = packing_max
	report.passed = native_error_max <= 1e-8 and packing_max == 0.0
	var file := FileAccess.open("res://.godot/phys_world_parity.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("WORLD_PARITY_TRACE_COMPLETE=" + str(native_error_max))
	native = null
	quit(0 if report.passed else 1)

func _distance(a: PackedFloat64Array, ai: int, b: PackedFloat64Array, bi: int, fields: Array) -> float:
	var squared := 0.0
	for f in fields: squared += pow(a[ai + f] - b[bi + f], 2.0)
	return sqrt(squared)

func _percentiles(a: Array) -> Dictionary:
	var b := a.duplicate(); b.sort()
	if b.is_empty(): return {}
	var total := 0.0
	for v in b: total += float(v)
	return {"count": b.size(), "mean": total / b.size(), "p95": b[mini(b.size()-1, ceili(b.size()*.95)-1)],
		"p99": b[mini(b.size()-1, ceili(b.size()*.99)-1)], "max": b[-1]}

func _benchmark(native: Object, worlds: PackedVector3Array, time: float) -> Dictionary:
	var result := {}
	for count in [1, 4, 16]:
		var points := worlds.slice(0, count)
		native.call("sample_batch", time, points)
		var scalar: Array = []; var batch: Array = []
		for repeat in 3:
			var start := Time.get_ticks_usec()
			for q in points: native.call("sample_world", q.x, q.z, time)
			scalar.append((Time.get_ticks_usec() - start) / 1000.0)
			start = Time.get_ticks_usec()
			native.call("sample_batch", time, points)
			batch.append((Time.get_ticks_usec() - start) / 1000.0)
		result[str(count)] = {"scalar_ms": _percentiles(scalar), "batch_ms": _percentiles(batch)}
	return result

func _sweep(native: Object) -> void:
	const STATE = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
	const PROFILE = preload("res://addons/ocean/resources/default_wave_profile.tres")
	var baseline := OS.get_cmdline_user_args().has("--baseline")
	var storm_proof := OS.get_cmdline_user_args().has("--storm-proof")
	var moving_proof := OS.get_cmdline_user_args().has("--moving-proof")
	var matrix_part := ""
	for part in ["base","fixed","moving"]:
		if OS.get_cmdline_user_args().has("--matrix-part="+part): matrix_part = part
	var states: Array = [{"name": "current", "bands": _spectra}]
	var endpoints: Array = []
	if not baseline:
		for weather in [[0.8,4.0,20.0,0.8], [3.0,18.0,75.0,2.0], [3.0,18.0,20.0,2.0]]:
			var configs: Array = PROFILE.build_fft_configs(weather[0],weather[1],weather[2],0.8,1.0)
			configs[0].choppiness = weather[3]
			var state: Dictionary = STATE.build(configs,1,weather[0],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,native)
			endpoints.append(state.bands)
		for i in 3: states.append({"name": ["calm","storm","direction"][i], "bands": endpoints[i]})
		# Same linear float32 H0 endpoint interpolation used by runtime weather.
		for alpha in [0.25,0.5,0.75]:
			var bands: Array[Dictionary] = []
			for band in 3:
				var a: Dictionary = endpoints[0][band]; var b: Dictionary = endpoints[1][band]
				var s: Dictionary = a.duplicate(true)
				var raw_a: PackedByteArray = a.h0_rgba32f; var raw_b: PackedByteArray = b.h0_rgba32f
				var bytes := PackedByteArray(); bytes.resize(raw_a.size())
				for index in range(0,bytes.size(),4): bytes.encode_float(index,raw_a.decode_float(index) + alpha*(raw_b.decode_float(index)-raw_a.decode_float(index)))
				s.h0_rgba32f = bytes
				s.choppiness = lerpf(a.choppiness,b.choppiness,alpha)
				s.wind_direction = a.wind_direction.lerp(b.wind_direction,alpha).normalized()
				s.wind_speed_mps = lerpf(a.wind_speed_mps,b.wind_speed_mps,alpha)
				bands.append(s)
			states.append({"name": "moving_alpha_%s" % alpha, "bands": bands})
	if storm_proof: states = [states[2]]
	if moving_proof: states = [states[5]]
	if matrix_part == "base": states = states.slice(0,1)
	elif matrix_part == "fixed": states = states.slice(1,4)
	elif matrix_part == "moving": states = states.slice(4,7)
	var output_suffix := "" if matrix_part.is_empty() else "_"+matrix_part
	var poses := PackedVector3Array(); var regions: Array = []
	for sample in _make_bake_texel_samples(64,1):
		poses.append(Vector3(sample.q.x,0,sample.q.y)); regions.append("interior_mask_fold")
	for sample in _make_boundary_samples():
		poses.append(Vector3(sample.q.x,0,sample.q.y)); regions.append("coverage_edge")
	for band in _spectra:
		var seam := float(band.domain_size_m) / (2.0 * float(band.resolution))
		for offset in [-0.025,-0.000001,0.000001,0.025]:
			poses.append(Vector3(seam + offset + float(band.domain_size_m),0,81.04028)); regions.append("periodic_x")
			poses.append(Vector3(37.13506,0,seam + offset - float(band.domain_size_m))); regions.append("periodic_z")
	for sample in _make_outside_samples():
		poses.append(Vector3(sample.q.x,0,sample.q.y)); regions.append("open")
	for offset in [-0.15,-0.05,0.0,0.05,0.15]:
		poses.append(Vector3(37.13506+offset,0,81.04028)); regions.append("known_fold")
	if not baseline and not storm_proof:
		var origin: Vector2 = _bake_snapshot.field_origin
		var extent: Vector2 = _bake_snapshot.field_extent
		for distance in [1.0,2.0,3.0]:
			for q in [origin+Vector2(distance,extent.y*.5),origin+Vector2(extent.x-distance,extent.y*.5),
				origin+Vector2(extent.x*.5,distance),origin+Vector2(extent.x*.5,extent.y-distance)]:
				poses.append(Vector3(q.x,0,q.y)); regions.append("coverage_feather")
		var resolution: Vector2i = _bake_snapshot.warp_resolution
		var valid: PackedByteArray = _bake_snapshot.warp_valid
		var transitions: Array[Vector2i] = []
		for y in range(1,resolution.y-1):
			for x in range(1,resolution.x-2):
				if valid[y*resolution.x+x] != valid[y*resolution.x+x+1]: transitions.append(Vector2i(x,y))
		for i in 8:
			var texel: Vector2i = transitions[i*transitions.size()/8]
			var q: Vector2 = _bake_snapshot.warp_origin + _bake_snapshot.warp_extent * Vector2(float(texel.x+1)/resolution.x,(texel.y+.5)/resolution.y)
			for side in [-0.01,0.01]:
				poses.append(Vector3(q.x+side,0,q.y)); regions.append("warp_mask_transition")
	while poses.size() % 4 != 0: poses.append(poses[0]); regions.append("padding")
	var all_errors: Array = []; var all_material: Array = []; var packets: Array = []
	var valid_mismatch := 0; var iteration_mismatch := 0; var branch_mismatch := 0; var q_errors: Array = []
	var native_packing_max := 0.0; var performance := {}
	for state in states:
		if not SPECTRUM_ADAPTER.configure_bands(native,state.bands,0.0,7).ok or not SPECTRUM_ADAPTER.configure_coastal(native,_bake_snapshot).ok:
			_fail("world sweep coherent state"); return
		for time in ([0.473258666666665] if baseline or storm_proof or moving_proof else [0.473258666666665,2.25]):
			var material: PackedFloat64Array = native.call("sample_material_q_batch",time,poses)
			var worlds := PackedVector3Array(); var scalar_material := PackedFloat64Array()
			for q in poses:
				var s: PackedFloat64Array = native.call("sample_material_q",q.x,q.z,time)
				scalar_material.append_array(s)
				worlds.append(Vector3(q.x+s[DX],0,q.z+s[DZ]))
			if moving_proof:
				var debug: Dictionary = native.call("debug_world_parity",time,worlds,132,true)
				var file := FileAccess.open("res://.godot/phys_world_parity_moving_trace.json",FileAccess.WRITE)
				file.store_string(JSON.stringify({"state":state.name,"time":time,"world":[worlds[132].x,worlds[132].z],"debug":debug},"\t")); file.close()
				print("WORLD_MOVING_TRACE_COMPLETE"); quit(0); return
			var batch: PackedFloat64Array = native.call("sample_batch",time,worlds)
			var warm: PackedFloat64Array = native.call("sample_batch_warm_prepared",worlds,worlds)
			var scalar := PackedFloat64Array(); var packet_errors: Array = []; var invalid := 0
			for i in worlds.size():
				var w: Vector3 = worlds[i]
				var s: PackedFloat64Array = native.call("sample_world_with_material_q",w.x,w.z,time)
				scalar.append_array(s)
				var error := _distance(s,0,batch,i*15,[DX,DY,DZ])
				all_errors.append(error); packet_errors.append(error)
				all_material.append(_distance(scalar_material,i*15,material,i*15,[DX,DY,DZ]))
				if s[0] != batch[i*15]: valid_mismatch += 1
				if s[14] != batch[i*15+14]: iteration_mismatch += 1
				if s[0] < 0.5: invalid += 1
				var q_error := _distance(s,0,warm,i*17,[15,16]); q_errors.append(q_error)
				if q_error > 0.01: branch_mismatch += 1
				for f in 15: native_packing_max = maxf(native_packing_max,absf(batch[i*15+f]-warm[i*17+f]))
			packets.append({"state": state.name,"time": time,"errors": _percentiles(packet_errors),"invalid_both": invalid,
				"worlds": Array(worlds).map(func(w): return [w.x,w.z]),"scalar": Array(scalar),"batch": Array(batch),"batch_solved_q": Array(warm)})
			var progress := FileAccess.open("res://.godot/phys_world_parity_progress"+output_suffix+".json",FileAccess.WRITE)
			progress.store_string(JSON.stringify({"packets":packets,"world":_percentiles(all_errors),"material":_percentiles(all_material),
				"q_delta":_percentiles(q_errors),"valid_mismatches":valid_mismatch,"iteration_mismatches":iteration_mismatch,
				"branch_mismatches":branch_mismatch,"performance":performance})); progress.close()
			print("WORLD_SWEEP_PACKET="+state.name+" time="+str(time)+" max="+str(packet_errors.max()))
			if storm_proof:
				var worst := packet_errors.find(packet_errors.max())
				packets[-1]["worst_index"] = worst
				packets[-1]["debug"] = native.call("debug_world_parity",time,worlds,worst)
			if state.name == "current" and time == 0.473258666666665: performance = _benchmark(native,worlds,time)
			await process_frame
	var result := {"build_id": native.call("get_dynamic_async_build_id"),"poses": Array(poses),"regions": regions,
		"world": _percentiles(all_errors),"material": _percentiles(all_material),"q_delta": _percentiles(q_errors),
		"valid_mismatches": valid_mismatch,"iteration_mismatches": iteration_mismatch,"root_mismatches_over_1cm": branch_mismatch,
		"cold_vs_identically_seeded_warm_fields_max": native_packing_max,"performance": performance,"packets": packets}
	result.passed = all_errors.max() <= 1e-8 and valid_mismatch == 0 and branch_mismatch == 0 and all_material.max() <= 1e-8
	result.matrix_part = matrix_part
	var file := FileAccess.open("res://.godot/phys_world_parity_sweep"+output_suffix+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t")); file.close()
	native = null
	print("WORLD_SWEEP_COMPLETE="+str(result.passed))
	quit(0 if baseline or storm_proof or result.passed else 1)
