extends "res://validation/physics/phys_weather_runner.gd"
## Independent displacement-only temporal oracle. No velocity enters its FD.
const PROFILE = preload("res://addons/ocean/resources/default_wave_profile.tres")
const H := 1.0 / 120.0
const VELOCITY_TOL := 0.0001 # New dX/dt oracle budget: 0.1 mm/s, not a PHYS-3 tolerance.
var _points := PackedVector3Array()
var _groups: Array[String] = []
var _samples: Dictionary = {}
var _packet_tick := 0

func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for property in ["breakers", "crest_foam", "surface_foam"]: ocean.set(property, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var coastal: Dictionary = fft.call("get_phys3_coastal_snapshot")
	var states: Array = []
	for s in [[0.8, 4.0, 20.0, 0.8], [3.0, 18.0, 75.0, 2.0], [3.0, 18.0, 20.0, 2.0]]:
		var configs: Array = PROFILE.build_fft_configs(s[0], s[1], s[2], 0.8, 1.0)
		configs[0].choppiness = s[3]
		var builder: Object = ClassDB.instantiate("OceanQueryNative")
		var state: Dictionary = SPECTRUM_STATE.build(configs, 1, s[0], PROFILE.combined_significant_wave_height_m(),
			1.0, [1.0, 1.0, 1.0], 1.0, 7, builder)
		if state.is_empty() or not builder.call("prepare_production_spectrum", state.bands): _fail("endpoint preparation"); return
		state["native"] = builder; states.append(state)
	_make_points(coastal)
	for label in ["open", "interior", "boundary", "wrap"]:
		_samples[label] = {"x": [], "y": [], "z": [], "envelope": [], "envelope_x": [], "envelope_y": [], "envelope_z": [],
			"phase": [], "phase_x": [], "phase_y": [], "phase_z": [], "total": [], "total_x": [], "total_y": [], "total_z": [],
			"coarse": [], "medium": []}
	var fixed_max := Vector3.ZERO
	var fixed_rows: Array = []
	for bands in [states[0].bands, fft.call("get_phys2_band_spectrum_snapshots"), states[1].bands]:
		var native := _new_mirror(bands, coastal, 0.0)
		if native == null: return
		if not await _at(native, 2.25): return
		var actual: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", _points)
		var phase := _phase_only(native, coastal, 2.25)
		var row_max := Vector3.ZERO
		for i in _points.size():
			for axis in 3: row_max[axis] = maxf(row_max[axis], absf(actual[i * 15 + 8 + axis] - phase[i * 15 + 8 + axis]))
		fixed_max = fixed_max.max(row_max); fixed_rows.append([row_max.x, row_max.y, row_max.z])
		native.call("clear")
	var rows: Array = []; var traces: Array = []; var endpoint_rows: Array = []
	var geometry_control_max := 0.0
	var start := 10.0
	var smoke := OS.get_cmdline_user_args().has("--smoke")
	for pair in ([[0, 1]] if smoke else [[0, 1], [1, 0], [1, 2]]):
		for duration in ([3.0] if smoke else [1.0, 3.0, 10.0]):
			var source: Dictionary = states[pair[0]]; var target: Dictionary = states[pair[1]]
			var native := _new_mirror(source.bands, coastal, start - 1.0)
			if native == null: return
			if not native.call("transition_dynamic_spectrum", source.native, target.native, start, duration): _fail("transition rejected"); return
			for alpha in ([0.5] if smoke else [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]):
				var time: float = start + alpha * duration
				var packets: Array = []
				for offset in [-2.0, -1.0, -0.5, -0.25, 0.0, 0.25, 0.5, 1.0, 2.0]:
					if not await _at(native, time + offset * H): return
					packets.append(native.call("sample_dynamic_material_q_batch", _points))
					if offset == 0.0:
						var info: Array = native.call("get_dynamic_snapshot_spectrum", false)
						var expected_dot: float = 1.0 / duration if alpha > 0.0 and alpha < 1.0 else 0.0
						for band in 3:
							if absf(info[band].weather_alpha - alpha) > 1e-12 or info[band].weather_alpha_dot != expected_dot \
								or info[band].configuration_version != info[0].configuration_version:
								_fail("incoherent transition metadata"); return
						# A separate fixed-H0 FFT has the old, phase-only derivative.
						packets.append(_phase_only(native, coastal, time))
				# The inserted phase packet is index 5; post-center packets shift by one.
				var center: PackedFloat64Array = packets[4]; var phase: PackedFloat64Array = packets[5]
				var errors: Array = []; var envelope_values: Array = []; var phase_values: Array = []; var total_values: Array = []
				for i in _points.size():
					# New velocity spectra must not leak into packed geometry fields.
					for field in [2, 3, 4, 5, 6, 7, 11, 12]:
						geometry_control_max = maxf(geometry_control_max, absf(center[i * 15 + field] - phase[i * 15 + field]))
					var velocity := _v(center, i); var old := _v(phase, i)
					var fd_coarse := _fd(packets[8], packets[1], i, 2.0 * H)
					var fd_medium := _fd(packets[7], packets[2], i, H)
					var fd_small := _fd(packets[6], packets[3], i, H * 0.5)
					var envelope := velocity - old
					envelope_values.append(envelope.length()); phase_values.append(old.length()); total_values.append(velocity.length())
					if alpha > 0.0 and alpha < 1.0:
						var e := velocity - fd_small
						var bucket: Dictionary = _samples[_groups[i]]
						for axis in 3: bucket[["x", "y", "z"][axis]].append(absf(e[axis]))
						for axis in 3: bucket[["envelope_x", "envelope_y", "envelope_z"][axis]].append(absf(envelope[axis]))
						for axis in 3:
							bucket[["phase_x", "phase_y", "phase_z"][axis]].append(absf(old[axis]))
							bucket[["total_x", "total_y", "total_z"][axis]].append(absf(velocity[axis]))
						bucket.envelope.append(envelope.length()); bucket.phase.append(old.length()); bucket.total.append(velocity.length())
						bucket.coarse.append((velocity - fd_coarse).length()); bucket.medium.append((velocity - fd_medium).length())
						errors.append(e.length())
						if maxf(absf(e.x), maxf(absf(e.y), absf(e.z))) > VELOCITY_TOL:
							_fail("dX/dt oracle error: " + str({"q": _points[i], "alpha": alpha, "duration": duration, "error": e})); return
					else:
						var eps := H * 0.25
						var left := _one_side(center, packets[3], packets[2], i, -eps)
						var right := _one_side(center, packets[6], packets[7], i, eps)
						var outside := left if alpha == 0.0 else right
						if (outside - velocity).length() > VELOCITY_TOL: _fail("endpoint fixed-side derivative"); return
						endpoint_rows.append({"pair": pair, "duration": duration, "alpha": alpha, "q": _points[i], "region": _groups[i],
							"selected_velocity": _xyz(velocity), "left_fd": _xyz(left), "right_fd": _xyz(right),
							"central_fd": _xyz(fd_small), "outside_error": (outside - velocity).length(), "jump": (right - left).length()})
					if i in [0, 20, 60, 85]:
						traces.append({"pair": pair, "duration": duration, "alpha": alpha, "time": time,
							"q": _points[i], "region": _groups[i], "height": center[i * 15 + 3],
							"phase": _xyz(old), "envelope": _xyz(envelope), "total": _xyz(velocity), "fd": _xyz(fd_small)})
				rows.append({"pair": pair, "duration": duration, "alpha": alpha, "error": _metrics(errors),
					"envelope_mps": _metrics(envelope_values), "phase_mps": _metrics(phase_values), "total_mps": _metrics(total_values)})
				print("VELOCITY_PACKET=" + JSON.stringify(rows.back()))
			native.call("clear"); start += duration + 2.0
	var scaling := await _scaling(states, coastal)
	if geometry_control_max > 1e-10: _fail("velocity changed packed geometry fields"); return
	if not scaling.passed: _fail("envelope 1/duration scaling"); return
	var chop_only := await _choppiness_only(states[0].bands, coastal)
	if not chop_only.passed: _fail("isolated choppiness derivative"); return
	var by_region := {}
	for label in _samples:
		var bucket: Dictionary = _samples[label]; var summary := {}
		for field in bucket: summary[field] = _metrics(bucket[field])
		by_region[label] = summary
	var report := {"build_id": preload("res://validation/physics/phys_native_build_contract.gd").ID,
		"points": _points.size(), "h_values": [H, H / 2.0, H / 4.0], "oracle_budget_mps": VELOCITY_TOL,
		"fixed_velocity_max_xyz": [fixed_max.x, fixed_max.y, fixed_max.z], "fixed_rows": fixed_rows,
		"geometry_control_max": geometry_control_max,
		"regions": by_region, "packets": rows, "endpoints": endpoint_rows, "traces": traces,
		"duration_scaling": scaling, "choppiness_only": chop_only}
	var output := FileAccess.open("res://.godot/phys_weather_velocity.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t")); output.close()
	if fixed_max.length() > 1e-10: _fail("fixed-state velocity changed"); return
	print("PHYS_OPT_2G_VELOCITY=PASS"); ocean.queue_free(); await process_frame; quit(0)

func _new_mirror(bands: Array, coastal: Dictionary, time: float) -> Object:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native.call("get_dynamic_async_build_id") != preload("res://validation/physics/phys_native_build_contract.gd").ID \
			or not native.call("prepare_production_spectrum", bands): _fail("mirror build/import"); return null
	native.call("set_dynamic_worker_count", 5)
	if not ADAPTER.configure_coastal(native, coastal).ok or not native.call("start_dynamic_async_fields", time, _packet_tick):
		_fail("Coastal mirror startup"); return null
	return native

func _at(native: Object, time: float) -> bool:
	_packet_tick += 1
	for _i in 300:
		native.call("advance_dynamic_async", _packet_tick, time, time, DT)
		var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
		var wanted := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
		if info[0] == 1 and absf(info[1] / 1e9 - time) < 2e-9 and info[3] == wanted: return true
		await physics_frame
	_fail("snapshot time/version not ready: " + str(time)); return false

func _phase_only(native: Object, coastal: Dictionary, time: float) -> PackedFloat64Array:
	var fixed: Object = ClassDB.instantiate("OceanQueryNative")
	if not fixed.call("prepare_production_spectrum", native.call("get_dynamic_snapshot_spectrum")) \
			or not ADAPTER.configure_coastal(fixed, coastal).ok or not fixed.call("build_dynamic_physics_fields", time):
		_fail("phase-only control"); return PackedFloat64Array()
	return fixed.call("sample_dynamic_material_q_batch", _points)

func _scaling(states: Array, coastal: Dictionary) -> Dictionary:
	var source: Dictionary = states[0]; var target: Dictionary = states[1]
	var reference := PackedFloat64Array(); var max_error := 0.0; var rows: Array = []
	for duration in [1.0, 3.0, 10.0]:
		const TIME := 120.0
		var start: float = TIME - duration * 0.5
		var native := _new_mirror(source.bands, coastal, start - 1.0)
		if not native.call("transition_dynamic_spectrum", source.native, target.native, start, duration) or not await _at(native, TIME):
			return {"passed": false}
		var total: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", _points)
		var phase := _phase_only(native, coastal, TIME); var magnitude: Array = []
		var current := PackedFloat64Array()
		for i in _points.size():
			var squared := 0.0
			for axis in 3:
				var e: float = (total[i * 15 + 8 + axis] - phase[i * 15 + 8 + axis]) * duration
				current.append(e); squared += e * e
			magnitude.append(sqrt(squared) / duration)
		if reference.is_empty(): reference = current
		else:
			for i in current.size(): max_error = maxf(max_error, absf(current[i] - reference[i]))
		rows.append({"duration": duration, "envelope_mps": _metrics(magnitude), "query": _query_timing(native)})
		native.call("clear")
	return {"passed": max_error < 1e-10, "scaled_max_error": max_error, "rows": rows}

func _query_timing(native: Object) -> Dictionary:
	var q := _points.slice(16, 20); var target := PackedVector3Array()
	var samples: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", q)
	for i in 4: target.append(Vector3(q[i].x + samples[i * 15 + 2], 0.0, q[i].z + samples[i * 15 + 4]))
	var started := Time.get_ticks_usec()
	for _i in 2000: native.call("sample_dynamic_material_q_batch", q)
	var material := (Time.get_ticks_usec() - started) / 2000000.0
	started = Time.get_ticks_usec()
	for _i in 100: native.call("sample_dynamic_world_batch", target, PackedVector3Array(), false)
	return {"material_N4_ms": material, "world_N4_ms": (Time.get_ticks_usec() - started) / 100000.0}

func _choppiness_only(bands: Array, coastal: Dictionary) -> Dictionary:
	var a := bands.duplicate(true); var b := bands.duplicate(true)
	a[0].choppiness = 0.0; b[0].choppiness = 2.0
	var source: Object = ClassDB.instantiate("OceanQueryNative")
	var target: Object = ClassDB.instantiate("OceanQueryNative")
	if not source.call("prepare_production_spectrum", a) or not target.call("prepare_production_spectrum", b): return {"passed": false}
	var native := _new_mirror(a, coastal, 0.0)
	if not native.call("transition_dynamic_spectrum", source, target, 10.0, 3.0): return {"passed": false}
	var center := PackedFloat64Array(); var phase := PackedFloat64Array(); var packets: Array = []
	for offset in [-1.0, 0.0, 1.0]:
		if not await _at(native, 11.5 + offset * H * 0.25): return {"passed": false}
		packets.append(native.call("sample_dynamic_material_q_batch", _points))
		if offset == 0.0:
			center = packets.back(); phase = _phase_only(native, coastal, 11.5)
	var vy_delta := 0.0; var horizontal := 0.0; var fd_error := 0.0
	for i in _points.size():
		vy_delta = maxf(vy_delta, absf(center[i * 15 + 9] - phase[i * 15 + 9]))
		horizontal = maxf(horizontal, Vector2(center[i * 15 + 8] - phase[i * 15 + 8], center[i * 15 + 10] - phase[i * 15 + 10]).length())
		fd_error = maxf(fd_error, (_v(center, i) - _fd(packets[2], packets[0], i, H * 0.5)).length())
	native.call("clear")
	return {"passed": vy_delta < 1e-12 and horizontal > 0.0 and fd_error < VELOCITY_TOL,
		"vertical_envelope_max": vy_delta, "horizontal_envelope_max": horizontal, "fd_vector_max_mps": fd_error,
		"long_chop": [0.0, 2.0], "H0_changed": false}

func _d(packet: PackedFloat64Array, index: int) -> Vector3:
	return Vector3(packet[index * 15 + 2], packet[index * 15 + 3], packet[index * 15 + 4])

func _fd(p: PackedFloat64Array, m: PackedFloat64Array, index: int, dt: float) -> Vector3:
	# Subtract in double scalar arithmetic BEFORE constructing Godot's float32 Vector3.
	return Vector3((p[index * 15 + 2] - m[index * 15 + 2]) / dt,
		(p[index * 15 + 3] - m[index * 15 + 3]) / dt, (p[index * 15 + 4] - m[index * 15 + 4]) / dt)

func _one_side(c: PackedFloat64Array, p: PackedFloat64Array, pp: PackedFloat64Array, index: int, h: float) -> Vector3:
	var v := Vector3.ZERO
	for axis in 3:
		var j := index * 15 + 2 + axis
		v[axis] = (-3.0 * c[j] + 4.0 * p[j] - pp[j]) / (2.0 * h)
	return v

func _v(packet: PackedFloat64Array, index: int) -> Vector3:
	return Vector3(packet[index * 15 + 8], packet[index * 15 + 9], packet[index * 15 + 10])

func _xyz(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

func _make_points(c: Dictionary) -> void:
	var origin: Vector2 = c.field_origin; var extent: Vector2 = c.field_extent
	for i in 16: _append_q(origin - Vector2(1000.0 + i * 71.3, 700.0 + i * 43.7), "open")
	for i in 32:
		_append_q(origin + extent * Vector2(0.1 + fposmod(i * 0.61803398875, 0.8), 0.1 + fposmod(i * 0.41421356237, 0.8)), "interior")
	for i in 16:
		var side := i % 4; var f := 0.1 + (i / 4) * 0.25
		var uv := Vector2(-0.00001 if i % 8 < 4 else 0.00001, f)
		if side == 1: uv.x += 1.0
		if side == 2: uv = Vector2(f, uv.x)
		if side == 3: uv = Vector2(f, uv.x + 1.0)
		_append_q(origin + extent * uv, "boundary")
	# Include interior validity transitions, not only rectangular bake borders.
	var size: Vector2i = c.warp_resolution; var valid: PackedByteArray = c.warp_valid
	var found := 0
	for y in range(1, size.y - 1, 7):
		for x in range(1, size.x - 1):
			if valid[y * size.x + x] != valid[y * size.x + x + 1]:
				_append_q(c.warp_origin + c.warp_extent * Vector2((x + 1.0) / size.x, (y + 0.5) / size.y), "boundary")
				found += 1; break
		if found == 16: break
	for domain in [512.0, 137.0, 37.0]:
		for epsilon in [-0.00001, 0.0, 0.00001, 0.2]:
			_append_q(Vector2(-domain * 0.5 + epsilon, domain * 0.5 - epsilon), "wrap")

func _append_q(q: Vector2, group: String) -> void:
	_points.append(Vector3(q.x, 0.0, q.y)); _groups.append(group)

func _metrics(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	var sorted := values.duplicate(); sorted.sort()
	var sum := 0.0; var squares := 0.0
	for value in values: sum += value; squares += value * value
	return {"count": values.size(), "mean": sum / values.size(), "rms": sqrt(squares / values.size()),
		"p95": sorted[int(ceil(values.size() * 0.95)) - 1], "p99": sorted[int(ceil(values.size() * 0.99)) - 1], "max": sorted.back()}
