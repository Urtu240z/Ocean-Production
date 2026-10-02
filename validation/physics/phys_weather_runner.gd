extends SceneTree
const OCEAN_SCENE = preload("res://addons/ocean/ocean.tscn")
const COASTAL_BAKE = preload("res://validation/p4_paradise/coastal_bake.tres")
const ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const WEATHER = preload("res://addons/ocean/physics/dynamic_ocean_weather.gd")
const PROBE = preload("res://validation/physics/phys1_gpu_probe.gd")
const SPECTRUM_STATE = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
const DT = 1.0 / 60.0

var _weather: RefCounted
var _probe_ready := false
var _gpu_result: Dictionary = {}
var _tick := 0
var _times: Array = []
var _ages: Array = []
var _queries: Array = []
var _polls: Array = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var fft_id := fft.get_instance_id()
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native == null or native.call("get_dynamic_async_build_id") != preload("res://validation/physics/phys_native_build_contract.gd").ID:
		_fail("current native DLL build guard"); return
	var initial: Array = fft.call("get_phys2_band_spectrum_snapshots")
	if not native.call("set_production_spectrum", initial): _fail("initial import"); return
	# Also prove the runtime recipe against the ACTUAL Production initializer,
	# not merely against another implementation of the helper.
	var configs_for_control: Array = (fft.get("_wave_configs") as Array).map(func(c): return c.call("copy_runtime_config"))
	var initial_manual_hs := float(ocean.get("significant_wave_height_m")) if int(ocean.get("sea_state_mode")) == 1 else -1.0
	var control := SPECTRUM_STATE.build(configs_for_control, ocean.get("simulation_seed"), initial_manual_hs,
		(ocean.get("wave_profile") as Resource).call("combined_significant_wave_height_m"), ocean.get("wave_height_scale"),
		[ocean.get("long_band_scale"), ocean.get("mid_band_scale"), ocean.get("short_band_scale")], ocean.get("mid_fill_amount"), 7, native)
	var initial_identity := not control.is_empty()
	for band in 3: initial_identity = initial_identity and control.bands[band].h0_rgba32f == initial[band].h0_rgba32f
	if not initial_identity: _fail("runtime H0 recipe differs from Production initialization"); return
	var coastal: Dictionary = fft.call("get_phys3_coastal_snapshot")
	if not bool(coastal.get("active", false)) or not bool(ADAPTER.configure_coastal(native, coastal).get("ok", false)):
		_fail("active Coastal setup failed"); return
	native.call("set_dynamic_worker_count", 5)
	if not native.call("start_dynamic_async_fields", ocean.call("get_wave_time"), 0): _fail("async startup"); return
	_weather = WEATHER.new(native, fft)
	var rows: Array = []
	var previous: PackedFloat64Array = native.call("sample_dynamic_material_q", 31.25, -72.5)
	var max_step := 0.0
	var mixed := 0
	var original_rids: Array = initial.map(func(s): return s["displacement_rid"])
	for state in [
		{"name": "calm", "hs": 0.8, "wind": 4.0, "direction": 20.0, "chop": 0.8},
		{"name": "storm", "hs": 3.0, "wind": 18.0, "direction": 75.0, "chop": 2.0},
		{"name": "calm_again", "hs": 0.8, "wind": 4.0, "direction": 20.0, "chop": 0.8},
	]:
		ocean.set("wave_speed_multiplier", 1.0)
		var profile: Resource = (ocean.get("wave_profile") as Resource).duplicate(true)
		var configs: Array = profile.call("build_fft_configs", state.hs, state.wind, state.direction, ocean.get("swell"), ocean.get("long_wave_spacing"))
		configs[0].choppiness = state.chop
		var params := {"seed": ocean.get("simulation_seed"), "overall_hs": state.hs,
			"profile_hs": profile.call("combined_significant_wave_height_m"), "wave_height_scale": 1.0,
			"band_scales": [1.0, 1.0, 1.0], "mid_fill": ocean.get("mid_fill_amount")}
		var request_at := Time.get_ticks_usec()
		var serial := int(_weather.call("request", configs, params, 3.0))
		var request_ms := (Time.get_ticks_usec() - request_at) / 1000.0
		var started := false; var complete := false
		var wanted_version := -1
		var ready_report := {}
		var midpoint_check := {}
		var timeline: Array = []
		for i in 1200:
			await physics_frame
			var result := _advance(ocean, native)
			if not result.is_empty():
				if not bool(result.get("ok", false)): _fail("weather preparation/transition failed"); return
				ready_report = result
				started = true
				wanted_version = int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
			var sample: PackedFloat64Array = native.call("sample_dynamic_material_q", 31.25, -72.5)
			if sample.size() != 15: _fail("invalid query"); return
			var step := Vector3(sample[2] - previous[2], sample[3] - previous[3], sample[4] - previous[4]).length()
			max_step = maxf(max_step, step)
			previous = sample
			var band_times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
			if band_times[0] != band_times[1] or band_times[1] != band_times[2]: mixed += 1
			if i % 30 == 0:
				var spectra: Array = native.call("get_dynamic_snapshot_spectrum", false)
				timeline.append({"tick": _tick, "wave_time": ocean.call("get_wave_time"),
					"field_time": spectra[0].wave_time, "version": spectra[0].configuration_version,
					"alpha": spectra[0].weather_alpha, "height": sample[3], "vertical_velocity": sample[9]})
			if started:
				var spectra: Array = native.call("get_dynamic_snapshot_spectrum", false)
				if midpoint_check.is_empty() and spectra.size() == 3 and float(spectra[0].weather_alpha) > 0.25 \
						and float(spectra[0].weather_alpha) < 0.75:
					midpoint_check = _check_h0_composition(native, ready_report)
					if int(midpoint_check.get("different_float32", -1)) != 0:
						_fail("SIMD weather composition differs from scalar float32 authority: " + str(midpoint_check)); return
				if spectra.size() == 3 and int(spectra[0].configuration_version) == wanted_version and float(spectra[0].weather_alpha) >= 1.0:
					complete = true; break
		if not complete or midpoint_check.is_empty(): _fail("weather/midpoint did not complete: " + state.name); return
		# Freeze ONLY validation; allow both global GPU and CPU pipeline to settle.
		ocean.set("wave_speed_multiplier", 0.0)
		for _i in 40:
			await physics_frame
			_advance(ocean, native)
		var spectra: Array = fft.call("get_phys2_band_spectrum_snapshots")
		var cpu_spectra: Array = native.call("get_dynamic_snapshot_spectrum")
		var byte_identity := true
		for band in 3: byte_identity = byte_identity and spectra[band].h0_rgba32f == cpu_spectra[band].h0_rgba32f \
			and cpu_spectra[band].h0_rgba32f == ready_report.target_spectrum[band].h0_rgba32f
		var reference: Object = ClassDB.instantiate("OceanQueryNative")
		if not reference.call("set_production_spectrum", spectra): _fail("oracle import"); return
		var frozen := float(ocean.call("get_wave_time"))
		var regression := _regression(native, fft.call("get_phys3_coastal_snapshot"))
		var lattice_max := 0.0
		var gpu_max := 0.0
		for band in 3:
			var probe: RefCounted = PROBE.new()
			_probe_ready = false; _gpu_result = {}
			RenderingServer.call_on_render_thread(probe.initialize.bind(self, spectra[band].displacement_rid,
				load("res://validation/physics/phys1_gpu_probe.glsl")))
			while not _probe_ready: await process_frame
			var texels := PackedVector2Array(); var expected: Array = []
			var n := int(spectra[band].resolution); var domain := float(spectra[band].domain_size_m)
			for j in 16:
				var ix := posmod(j * 47 + 3, n); var iz := posmod(j * 83 + 11, n)
				var qx := (ix + 0.5) * domain / n - domain * 0.5
				var qz := (iz + 0.5) * domain / n - domain * 0.5
				var mirror: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band, qx, qz)
				var direct: PackedFloat64Array = reference.call("sample_material_q_with_band_mask", qx, qz, frozen, (1 << (band + 1)) - 1)
				if band > 0:
					var lower: PackedFloat64Array = reference.call("sample_material_q_with_band_mask", qx, qz, frozen, (1 << band) - 1)
					for field in direct.size(): direct[field] -= lower[field]
				for pair in [[mirror[0], direct[3]], [mirror[1], direct[2]], [mirror[2], direct[4]],
					[mirror[9], direct[9]], [mirror[10], direct[8]], [mirror[11], direct[10]]]:
					lattice_max = maxf(lattice_max, absf(pair[0] - pair[1]))
				expected.append(Vector3(mirror[1], mirror[0], mirror[2])); texels.append(Vector2(ix, iz))
			RenderingServer.call_on_render_thread(probe.dispatch_request.bind({"band": band, "time": frozen}, texels))
			while _gpu_result.is_empty(): await process_frame
			if not String(_gpu_result.error).is_empty(): _fail(_gpu_result.error); return
			var bytes: PackedByteArray = _gpu_result.bytes
			for j in 16:
				var raw := Vector3(bytes.decode_float(j * 16), bytes.decode_float(j * 16 + 4), bytes.decode_float(j * 16 + 8))
				gpu_max = maxf(gpu_max, raw.distance_to(expected[j]))
			RenderingServer.call_on_render_thread(probe.shutdown)
		var unchanged := fft_id == ocean.get_node("OpenOceanFFT").get_instance_id()
		for band in 3: unchanged = unchanged and original_rids[band] == spectra[band].displacement_rid
		rows.append({"state": state, "serial": serial, "prepare_ms": ready_report.prepare_ms,
			"midpoint_composition": midpoint_check,
			"request_main_ms": request_ms, "byte_identity": byte_identity, "no_rebuild": unchanged,
			"cpu_oracle_lattice_max": lattice_max, "gpu_cpu_lattice_vector_max": gpu_max, "timeline": timeline,
			"regression": regression})
		if not unchanged or not byte_identity or lattice_max > 0.00001 or gpu_max > 0.0001:
			_fail("state parity/rebuild gate: " + JSON.stringify(rows.back())); return
		if int(regression.regular_failed) != 0 or float(regression.material_batch_max) > 0.000000000001 \
				or float(regression.world_batch_max) > 0.000000000001 or float(regression.normal_fd_max) >= 0.01:
			_fail("world/material regression " + state.name + " t=" + str(frozen) + ": " + JSON.stringify(regression)); return
	var controls := await _control_regression(ocean, fft, native)
	if not bool(controls.get("passed", false)): _fail("runtime controls: " + JSON.stringify(controls)); return
	var phase_resets := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[33])
	if phase_resets < 4: _fail("configuration phase history was not reset"); return
	var report := {"build_id": preload("res://validation/physics/phys_native_build_contract.gd").ID,
		"states": rows, "controls": controls, "configuration_phase_resets": phase_resets,
		"initial_production_recipe_byte_identity": initial_identity,
		"mixed": mixed, "maximum_step_including_wave_motion_m": max_step,
		"field_age_ticks": _stats(_ages), "query_ms": _stats(_queries), "main_weather_poll_ms": _stats(_polls),
		"no_gpu_readback_dependency": true, "tiny_validation_probe_only": true}
	var suffix := "_separate" if OS.get_cmdline_user_args().has("--separate-render-test") else ""
	var output := FileAccess.open("res://.godot/phys_weather%s.json" % suffix, FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t")); output.close()
	_weather.call("shutdown"); _weather = null
	print("PHYS_WEATHER_COMPLETE=" + JSON.stringify(report))
	quit(0 if mixed == 0 else 1)

func _advance(ocean: Node, native: Object) -> Dictionary:
	_tick += 1
	var now := float(ocean.call("get_wave_time"))
	var moving := float(ocean.get("wave_speed_multiplier")) > 0.0
	var result: PackedInt64Array = native.call("advance_dynamic_async", _tick, now, now + DT if moving else now, DT)
	_ages.append(result[7] / 1000000.0)
	var at := Time.get_ticks_usec()
	var ready: Dictionary = _weather.call("poll", now)
	_polls.append((Time.get_ticks_usec() - at) / 1000.0)
	at = Time.get_ticks_usec()
	native.call("sample_dynamic_material_q", 123.456, -78.9)
	_queries.append((Time.get_ticks_usec() - at) / 1000.0)
	return ready

func _check_h0_composition(native: Object, prepared: Dictionary) -> Dictionary:
	var actual: Array = native.call("get_dynamic_snapshot_spectrum")
	var different := 0; var checked := 0
	for band in 3:
		var source: PackedByteArray = prepared.source[band].h0_rgba32f
		var target: PackedByteArray = prepared.target_spectrum[band].h0_rgba32f
		var result: PackedByteArray = actual[band].h0_rgba32f
		var alpha := float(actual[band].weather_alpha)
		for j in 64:
			var index := posmod(j * 997 + 31, source.size() / 16)
			for channel in 4:
				var offset := index * 16 + channel * 4
				var a := source.decode_float(offset); var b := target.decode_float(offset)
				var expected := PackedFloat32Array([a + (b - a) * alpha])[0]
				checked += 1
				if expected != result.decode_float(offset): different += 1
	return {"checked": checked, "different_float32": different, "alpha": actual[0].weather_alpha}

func _regression(native: Object, coastal: Dictionary) -> Dictionary:
	var points := PackedVector3Array(); var targets := PackedVector3Array()
	for j in 64:
		var q := Vector2(j * 19.0 - 900.0, j * -11.0 + 700.0)
		if j < 32 and not coastal.is_empty():
			q = coastal.field_origin + coastal.field_extent * Vector2(0.12 + float(j % 8) * 0.10, 0.10 + float(j / 8) * 0.18)
		points.append(Vector3(q.x, 0.0, q.y))
	var material: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", points)
	var material_error := 0.0
	for j in 64:
		var q := points[j]
		var s: PackedFloat64Array = native.call("sample_dynamic_material_q", q.x, q.z)
		for field in 15: material_error = maxf(material_error, absf(s[field] - material[j * 15 + field]))
		targets.append(Vector3(q.x + s[2], 0.0, q.z + s[4]))
	var world: PackedFloat64Array = native.call("sample_dynamic_world_batch", targets, PackedVector3Array(), false)
	var failed := 0; var regular_failed := 0; var folds := 0
	var residual := 0.0; var regular_residual := 0.0; var q_error := 0.0; var world_error := 0.0
	var warm_residual := 0.0; var normal_error := 0.0
	var failed_cases: Array = []
	for j in 64:
		var source_fold := material[j * 15 + 12] > 0.5
		if source_fold: folds += 1
		else: regular_residual = maxf(regular_residual, world[j * 17 + 13])
		# A nearby warm seed, not the exact known answer. Folded geometry is
		# explicitly reported; cold-start uniqueness is not a valid premise there.
		var nearby: PackedFloat64Array = native.call("sample_dynamic_world", targets[j].x, targets[j].z, points[j].x + 0.05, points[j].z - 0.05, true)
		warm_residual = maxf(warm_residual, nearby[13])
		if world[j * 17] < 0.5:
			failed += 1
			if not source_fold: regular_failed += 1
			var warm: PackedFloat64Array = native.call("sample_dynamic_world", targets[j].x, targets[j].z, points[j].x, points[j].z, true)
			failed_cases.append({"q": points[j], "target": targets[j], "cold_q": Vector2(world[j * 17 + 15], world[j * 17 + 16]),
				"cold_residual": world[j * 17 + 13], "cold_iterations": world[j * 17 + 14],
				"source_det": material[j * 15 + 11], "source_foldover": material[j * 15 + 12], "warm_residual": warm[13]})
		residual = maxf(residual, world[j * 17 + 13])
		q_error = maxf(q_error, Vector2(world[j * 17 + 15] - points[j].x, world[j * 17 + 16] - points[j].z).length())
		var scalar: PackedFloat64Array = native.call("sample_dynamic_world", targets[j].x, targets[j].z, 0.0, 0.0, false)
		for field in 17: world_error = maxf(world_error, absf(scalar[field] - world[j * 17 + field]))
		if j < 16:
			var q := points[j]; const EPS := 0.01
			var xp: PackedFloat64Array = native.call("sample_dynamic_material_q", q.x + EPS, q.z)
			var xm: PackedFloat64Array = native.call("sample_dynamic_material_q", q.x - EPS, q.z)
			var zp: PackedFloat64Array = native.call("sample_dynamic_material_q", q.x, q.z + EPS)
			var zm: PackedFloat64Array = native.call("sample_dynamic_material_q", q.x, q.z - EPS)
			var tx := Vector3(1.0, 0.0, 0.0) + Vector3(xp[2] - xm[2], xp[3] - xm[3], xp[4] - xm[4]) / (2.0 * EPS)
			var tz := Vector3(0.0, 0.0, 1.0) + Vector3(zp[2] - zm[2], zp[3] - zm[3], zp[4] - zm[4]) / (2.0 * EPS)
			var n := tz.cross(tx).normalized()
			if n.y < 0.0: n = -n
			normal_error = maxf(normal_error, n.distance_to(Vector3(material[j * 15 + 5], material[j * 15 + 6], material[j * 15 + 7])))
	var timing := {}
	for count in [4, 16]:
		var qs := points.slice(0, count)
		var started := Time.get_ticks_usec()
		for _i in 200: native.call("sample_dynamic_material_q_batch", qs)
		timing["material_N%d_ms" % count] = (Time.get_ticks_usec() - started) / 200000.0
	var started := Time.get_ticks_usec()
	for _i in 50: native.call("sample_dynamic_world_batch", targets.slice(0, 4), PackedVector3Array(), false)
	timing["world_N4_ms"] = (Time.get_ticks_usec() - started) / 50000.0
	return {"samples": 64, "failed": failed, "regular_failed": regular_failed, "folded_sources": folds, "timing": timing,
		"residual_max_m": residual, "regular_residual_max_m": regular_residual, "q_recovery_max_m": q_error,
		"nearby_warm_residual_max_m": warm_residual, "normal_fd_max": normal_error,
		"material_batch_max": material_error, "world_batch_max": world_error, "failed_cases": failed_cases}

func _control_regression(ocean: Node, fft: Node, native: Object) -> Dictionary:
	var newest := -1
	for direction in [20.0, 75.0, 110.0]:
		newest = _request_test_state(ocean, direction, 1.0)
	ocean.set("wave_speed_multiplier", 1.0)
	var started := false; var paused := false; var frozen := false
	var version := -1; var accepted: Array = []
	for i in 360:
		await physics_frame
		var ready := _advance(ocean, native)
		if not ready.is_empty():
			accepted.append(ready.serial)
			if not bool(ready.ok) or int(ready.serial) != newest: return {"passed": false, "accepted": accepted}
			started = true
			version = int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
		var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
		if started and not paused and int(info[3]) == version and int(info[5]) > 200000000:
			ocean.set("wave_speed_multiplier", 0.0)
			for _j in 40:
				await physics_frame
				_advance(ocean, native)
			var before: PackedInt64Array = native.call("get_dynamic_snapshot_info")
			var builds_before := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[3])
			for _j in 30:
				await physics_frame
				_advance(ocean, native)
			var after: PackedInt64Array = native.call("get_dynamic_snapshot_info")
			frozen = before[1] == after[1] and before[3] == after[3] and before[5] == after[5] \
				and builds_before == int((native.call("get_dynamic_async_stats") as PackedInt64Array)[3])
			paused = true
			ocean.set("wave_speed_multiplier", 1.0)
		if started and int(info[3]) == version and int(info[5]) == 1000000000:
			ocean.set("wave_speed_multiplier", 0.0)
			for _j in 15:
				await physics_frame
				_advance(ocean, native)
			var cpu: Array = native.call("get_dynamic_snapshot_spectrum")
			var gpu: Array = fft.call("get_phys2_band_spectrum_snapshots")
			var identity := cpu.size() == 3 and gpu.size() == 3
			for band in 3: identity = identity and cpu[band].h0_rgba32f == gpu[band].h0_rgba32f
			return {"passed": frozen and identity, "latest_serial": newest, "accepted": accepted,
				"pause_mid_transition": frozen, "resume_completed": true, "endpoint_gpu_identity": identity,
				"final_direction_degrees": rad_to_deg((cpu[0].wind_direction as Vector2).angle())}
	return {"passed": false, "accepted": accepted, "pause_mid_transition": frozen}

func _request_test_state(ocean: Node, direction: float, duration: float) -> int:
	var profile: Resource = (ocean.get("wave_profile") as Resource).duplicate(true)
	var configs: Array = profile.call("build_fft_configs", 2.0, 10.0, direction, ocean.get("swell"), ocean.get("long_wave_spacing"))
	return int(_weather.call("request", configs, {"seed": ocean.get("simulation_seed"), "overall_hs": 2.0,
		"profile_hs": profile.call("combined_significant_wave_height_m"), "wave_height_scale": 1.0,
		"band_scales": [1.0, 1.0, 1.0], "mid_fill": ocean.get("mid_fill_amount")}, duration))

func _on_gpu_probe_initialized(ok: bool, message: String) -> void:
	if not ok: _fail(message)
	_probe_ready = true

func _on_gpu_probe_readback(_request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	_gpu_result = {"bytes": bytes, "error": error}

func _stats(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	var sorted := values.duplicate(); sorted.sort()
	var sum := 0.0
	for value in values: sum += value
	return {"mean": sum / sorted.size(), "p95": sorted[int(ceil(sorted.size() * 0.95)) - 1],
		"p99": sorted[int(ceil(sorted.size() * 0.99)) - 1], "max": sorted.back()}

func _fail(message: String) -> void:
	if _weather != null: _weather.call("shutdown"); _weather = null
	printerr("PHYS_WEATHER_FAIL=" + message); quit(1)
