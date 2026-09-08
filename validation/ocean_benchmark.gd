extends Node3D

## Automated, editor-independent benchmark for Ocean Production.
## Run with:
##   godot --path . --scene res://validation/ocean_benchmark.tscn
## Optional user argument: -- --ocean-benchmark=smoke

const SCENE_PATH := "res://validation/ocean_benchmark.tscn"
const PROFILE_PATH := "res://validation/profiles/rough_validation.tres"
const COASTAL_BAKE_PATH := "res://validation/p4_paradise/coastal_bake.tres"
const WARMUP_SECONDS := 3.0
const MEASURE_SECONDS := 5.0
const SMOKE_WARMUP_SECONDS := 0.25
const SMOKE_MEASURE_SECONDS := 0.75
const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")

var _ocean: Ocean
var _camera: Camera3D
var _viewport: Viewport
var _viewport_rid: RID
var _warmup_seconds := WARMUP_SECONDS
var _measure_seconds := MEASURE_SECONDS
var _smoke := false
var _failures: Array[String] = []
var _block_results: Dictionary = {}


func _ready() -> void:
	_smoke = _has_user_argument("--ocean-benchmark=smoke")
	if _smoke:
		_warmup_seconds = SMOKE_WARMUP_SECONDS
		_measure_seconds = SMOKE_MEASURE_SECONDS
	call_deferred(&"_run")


func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_build_benchmark_world()
	await get_tree().process_frame
	_viewport = get_viewport()
	_viewport_rid = _viewport.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	await _wait_seconds(_warmup_seconds)
	_print_environment()

	await _run_fft_core()
	await _run_feature_isolation()
	await _run_production_priority()
	await _run_underwater_priority()
	await _run_full_minus_one()
	await _run_resolution_sensitivity()
	_print_summary()
	_shutdown_benchmark_world()
	await get_tree().process_frame
	get_tree().quit()


func _build_benchmark_world() -> void:
	var environment := Environment.new()
	environment.background_mode = 1
	environment.background_color = Color(0.04, 0.10, 0.16)
	environment.ambient_light_source = 3
	environment.ambient_light_color = Color(0.35, 0.48, 0.60)
	environment.ambient_light_energy = 0.8
	environment.tonemap_mode = 4
	var world := WorldEnvironment.new()
	world.name = &"WorldEnvironment"
	world.environment = environment
	add_child(world)

	var sun := DirectionalLight3D.new()
	sun.name = &"Sun"
	sun.rotation_degrees = Vector3(-42.0, -28.0, 0.0)
	sun.light_energy = 3.0
	sun.shadow_enabled = true
	add_child(sun)

	_camera = Camera3D.new()
	_camera.name = &"BenchmarkCamera"
	_camera.position = Vector3(0.0, 8.0, 16.0)
	_camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	_camera.current = true
	add_child(_camera)

	_ocean = Ocean.new()
	_ocean.name = &"Ocean"
	_ocean.quality_profile = load("res://addons/ocean/core/ocean_quality_profile.gd").new()
	_ocean.wave_profile = load(PROFILE_PATH)
	_ocean.coastal_bake = load(COASTAL_BAKE_PATH)
	_ocean.simulation_seed = 20260820
	_ocean.sea_state_mode = 0
	_ocean.significant_wave_height_m = 2.574
	_ocean.wave_height_scale = 1.0
	_ocean.wave_speed_multiplier = 1.0
	_ocean.long_band_scale = 1.0
	_ocean.mid_band_scale = 1.0
	_ocean.short_band_scale = 1.0
	_ocean.wind_speed_mps = 18.0
	_ocean.wind_direction_degrees = 5.71
	_ocean.swell = 0.80
	_ocean.long_wave_spacing = 1.0
	_ocean.mid_fill_amount = 1.0
	_ocean.optics = false
	_ocean.surface_detail = false
	_ocean.crest_foam = false
	_ocean.surface_foam = false
	_ocean.coastal = false
	_ocean.reflections = false
	_ocean.underwater_medium = false
	_ocean.underwater_sunrays = false
	_ocean.underwater_bubbles = false
	add_child(_ocean)
	_ocean.set_fft_cascade_mask(CascadeState.FULL)


func _run_fft_core() -> void:
	print("BLOCK FFT CORE")
	var cases := [
		["C0 ALL_FFT_OFF", 0],
		["C1 LONG_ONLY", CascadeState.LONG],
		["C2 LONG_MID", CascadeState.LONG | CascadeState.MID],
		["C3 FULL_FFT", CascadeState.FULL],
	]
	var results: Array[Dictionary] = []
	for item in cases:
		var result := await _run_case(item[0], {"mask": item[1]})
		results.append(result)
	_block_results["fft"] = results


func _run_feature_isolation() -> void:
	print("BLOCK FEATURE ISOLATION")
	var baseline := await _run_case("I0 BASE", {})
	var cases := [
		["I1 BASE+OPTICS", {"optics": true}],
		["I2 BASE+SURFACE_DETAIL", {"surface_detail": true}],
		["I3 BASE+CREST_FOAM", {"crest_foam": true}],
		["I4 BASE+COASTAL", {"coastal": true}],
		["I5 BASE+SSPR", {"reflections": true}],
		["I6 BASE+SURFACE_FOAM", {"surface_foam": true}],
		["I7 BASE+UNDERWATER", {"underwater": true}],
		["I8 BASE+SUNRAYS", {"underwater": true, "sunrays": true}],
		["I9 BASE+BUBBLES", {"underwater": true, "bubbles": true}],
	]
	var results: Array[Dictionary] = [baseline]
	for item in cases:
		var result := await _run_case(item[0], item[1], baseline)
		results.append(result)
	_block_results["isolation"] = results


func _run_production_priority() -> void:
	print("BLOCK PRODUCTION PRIORITY")
	var cases := [
		["P0 BASE", {}],
		["P1 +OPTICS", {"optics": true}],
		["P2 +SURFACE_DETAIL", {"optics": true, "surface_detail": true}],
		["P3 +CREST_FOAM", {"optics": true, "surface_detail": true, "crest_foam": true}],
		["P4 +COASTAL", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true}],
		["P5 +SSPR", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true}],
		["P6 +SURFACE_FOAM", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true}],
	]
	var results: Array[Dictionary] = []
	for item in cases:
		results.append(await _run_case(item[0], item[1], results[0] if not results.is_empty() else {}))
	_block_results["production"] = results
	_print_max_levels(results)


func _run_underwater_priority() -> void:
	print("BLOCK UNDERWATER PRIORITY")
	var cases := [
		["U0 BASE+UNDERWATER", {"underwater": true}],
		["U1 U0+OPTICS", {"underwater": true, "optics": true}],
		["U2 U1+SUNRAYS", {"underwater": true, "optics": true, "sunrays": true}],
		["U3 U2+BUBBLES", {"underwater": true, "optics": true, "sunrays": true, "bubbles": true}],
	]
	_set_underwater_camera(true)
	var results: Array[Dictionary] = []
	for item in cases:
		results.append(await _run_case(item[0], item[1], results[0] if not results.is_empty() else {}))
	_block_results["underwater"] = results
	_set_underwater_camera(false)


func _run_full_minus_one() -> void:
	print("BLOCK FULL MINUS ONE")
	_set_underwater_camera(true)
	var full_state := {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true, "underwater": true, "sunrays": true, "bubbles": true}
	var full := await _run_case("F0 FULL", full_state)
	var cases := [
		["F1 FULL-SHORT", {"mask": CascadeState.LONG | CascadeState.MID, "optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true, "underwater": true, "sunrays": true, "bubbles": true}],
		["F2 FULL-SSPR", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "surface_foam": true, "underwater": true, "sunrays": true, "bubbles": true}],
		["F3 FULL-SURFACE_FOAM", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "underwater": true, "sunrays": true, "bubbles": true}],
		["F4 FULL-BUBBLES", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true, "underwater": true, "sunrays": true}],
		["F5 FULL-SUNRAYS", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true, "underwater": true, "bubbles": true}],
		["F6 FULL-CREST_FOAM", {"optics": true, "surface_detail": true, "coastal": true, "reflections": true, "surface_foam": true, "underwater": true, "sunrays": true, "bubbles": true}],
		["F7 FULL-COASTAL", {"optics": true, "surface_detail": true, "crest_foam": true, "reflections": true, "surface_foam": true, "underwater": true, "sunrays": true, "bubbles": true}],
		["F8 FULL-SURFACE_DETAIL", {"optics": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true, "underwater": true, "sunrays": true, "bubbles": true}],
		["F9 FULL-OPTICS", {"surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true, "underwater": true, "sunrays": true, "bubbles": true}],
	]
	var results: Array[Dictionary] = [full]
	for item in cases:
		results.append(await _run_case(item[0], item[1], full))
	_block_results["full_minus"] = results
	_set_underwater_camera(false)


func _run_resolution_sensitivity() -> void:
	print("BLOCK RESOLUTION SENSITIVITY")
	var results: Dictionary = {}
	for scale in [1.0, 0.85, 0.70]:
		_set_render_scale(scale)
		var chain: Array[Dictionary] = []
		var cases := [
			["P0 BASE", {}],
			["P1 +OPTICS", {"optics": true}],
			["P2 +SURFACE_DETAIL", {"optics": true, "surface_detail": true}],
			["P3 +CREST_FOAM", {"optics": true, "surface_detail": true, "crest_foam": true}],
			["P4 +COASTAL", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true}],
			["P5 +SSPR", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true}],
			["P6 +SURFACE_FOAM", {"optics": true, "surface_detail": true, "crest_foam": true, "coastal": true, "reflections": true, "surface_foam": true}],
		]
		for item in cases:
			chain.append(await _run_case("S%.2f %s" % [scale, item[0]], item[1], chain[0] if not chain.is_empty() else {}))
		results[scale] = chain
	_block_results["resolution"] = results
	_set_render_scale(1.0)


func _run_case(label: String, state: Dictionary, baseline: Dictionary = {}) -> Dictionary:
	_apply_base_state()
	_apply_state(state)
	await _wait_seconds(_warmup_seconds)
	_validate_runtime(label, state)
	var result := await _measure(label)
	result["label"] = label
	if not baseline.is_empty():
		var delta_gpu: String = "NA"
		var delta_cpu: String = "NA"
		if result.gpu_valid and bool(baseline.get("gpu_valid", false)):
			delta_gpu = "%.3f" % (result.gpu_mean - float(baseline.gpu_mean))
		if result.cpu_valid and bool(baseline.get("cpu_valid", false)):
			delta_cpu = "%.3f" % (result.cpu_mean - float(baseline.cpu_mean))
		print("DELTA | %s | GPU=%s ms | CPU=%s ms" % [label, delta_gpu, delta_cpu])
	return result


func _apply_base_state() -> void:
	_ocean.optics = false
	_ocean.surface_detail = false
	_ocean.crest_foam = false
	_ocean.surface_foam = false
	_ocean.coastal = false
	_ocean.reflections = false
	_ocean.underwater_medium = false
	_ocean.underwater_sunrays = false
	_ocean.underwater_bubbles = false
	_ocean.set_fft_cascade_mask(CascadeState.FULL)


func _apply_state(state: Dictionary) -> void:
	var mask: int = int(state.get("mask", CascadeState.FULL))
	_ocean.set_fft_cascade_mask(mask)
	if bool(state.get("optics", false)): _ocean.optics = true
	if bool(state.get("surface_detail", false)): _ocean.surface_detail = true
	if bool(state.get("crest_foam", false)): _ocean.crest_foam = true
	if bool(state.get("coastal", false)): _ocean.coastal = true
	if bool(state.get("reflections", false)): _ocean.reflections = true
	if bool(state.get("surface_foam", false)): _ocean.surface_foam = true
	if bool(state.get("underwater", false)):
		_ocean.underwater_medium = true
		_ocean.underwater_sunrays = bool(state.get("sunrays", false))
		_ocean.underwater_bubbles = bool(state.get("bubbles", false))


func _validate_runtime(label: String, state: Dictionary) -> void:
	var open_ocean := _ocean.get_node_or_null(^"OpenOceanFFT")
	if open_ocean == null:
		_failures.append("%s: OpenOceanFFT missing" % label)
		return
	var runtime: Dictionary = open_ocean.get_cascade_runtime_state()
	var expected_mask: int = int(state.get("mask", CascadeState.FULL))
	var expected := [bool(expected_mask & CascadeState.LONG), bool(expected_mask & CascadeState.MID), bool(expected_mask & CascadeState.SHORT)]
	for index in 3:
		var band: Dictionary = runtime.bands[index]
		if bool(band.solver) != expected[index] or bool(band.dispatch) != expected[index]:
			_failures.append("%s: cascade %s runtime mismatch" % [label, band.name])
	var underwater_expected := bool(state.get("underwater", false))
	var medium := _ocean.get_node_or_null(^"OceanUnderwaterMedium")
	if (medium != null) != underwater_expected:
		_failures.append("%s: underwater lifecycle mismatch" % label)
	var bubble_object = null
	if medium != null:
		var effect = medium.get("_effect")
		if effect != null: bubble_object = effect.get("_bubbles")
	var bubbles_expected := underwater_expected and bool(state.get("bubbles", false))
	if (bubble_object != null) != bubbles_expected:
		_failures.append("%s: Bubble lifecycle mismatch" % label)
	var surface_foam_runtime: bool = bool(runtime.features.surface_foam.runtime_active)
	if surface_foam_runtime != bool(state.get("surface_foam", false)) and expected[1]:
		_failures.append("%s: Surface Foam lifecycle mismatch" % label)
	var coastal_runtime: bool = bool(runtime.features.coastal_waves.runtime_active)
	if coastal_runtime != (bool(state.get("coastal", false)) and expected[0]):
		_failures.append("%s: Coastal lifecycle mismatch" % label)
	var sspr_object = open_ocean.get("_sspr")
	if (sspr_object != null) != bool(state.get("reflections", false)):
		_failures.append("%s: SSPR lifecycle mismatch" % label)
	print("STATE | %s | mask=%s | solvers=%s/%s/%s | foam=%s | coastal=%s | sspr=%s | underwater=%s | bubbles=%s" % [label, runtime.mode, runtime.bands[0].solver, runtime.bands[1].solver, runtime.bands[2].solver, surface_foam_runtime, coastal_runtime, sspr_object != null, medium != null, bubble_object != null])


func _measure(label: String) -> Dictionary:
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var wall_fps: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	var end_usec := previous_usec + int(_measure_seconds * 1000000.0)
	while Time.get_ticks_usec() < end_usec:
		await get_tree().process_frame
		var now_usec := Time.get_ticks_usec()
		var frame_ms: float = float(now_usec - previous_usec) / 1000.0
		previous_usec = now_usec
		if frame_ms > 0.0: wall_fps.append(1000.0 / frame_ms)
		var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		if gpu_ms > 0.0: gpu.append(gpu_ms)
		if cpu_ms > 0.0: cpu.append(cpu_ms)
	var gpu_valid := not gpu.is_empty()
	var cpu_valid := not cpu.is_empty()
	var median_gpu := _median(gpu)
	var gpu_fps := 1000.0 / median_gpu if gpu_valid and median_gpu > 0.0 else 0.0
	var classification := _classify(gpu_fps) if gpu_valid else "UNAVAILABLE"
	var result := {
		"gpu_mean": _average(gpu),
		"gpu_median": median_gpu,
		"gpu_p95": _percentile(gpu, 0.95),
		"cpu_mean": _average(cpu),
		"cpu_median": _median(cpu),
		"gpu_fps": gpu_fps,
		"wall_fps": _average(wall_fps),
		"gpu_valid": gpu_valid,
		"cpu_valid": cpu_valid,
	}
	print("BENCH | %s | GPU=%.3f ms | medianGPU=%.3f ms | p95GPU=%.3f ms | CPU=%.3f ms | medianCPU=%.3f ms | FPS_GPU=%.1f | %s" % [label, result.gpu_mean, result.gpu_median, result.gpu_p95, result.cpu_mean, result.cpu_median, result.gpu_fps, classification])
	return result


func _print_environment() -> void:
	var window_size := DisplayServer.window_get_size()
	var viewport_size: Vector2i = _viewport.size
	var scale: float = float(_viewport.get("scaling_3d_scale"))
	var internal_size := Vector2i(Vector2(viewport_size) * scale)
	var method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "Forward+"))
	if method.is_empty(): method = "Forward+"
	var api := _rendering_server_value(&"get_video_adapter_api_version", "unknown")
	var gpu := _rendering_server_value(&"get_video_adapter_name", "unknown")
	var vendor := _rendering_server_value(&"get_video_adapter_vendor", "unknown")
	var driver := str(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "default"))
	var upscaler := _scaling_mode_name(_viewport.get("scaling_3d_mode"))
	var msaa := str(_viewport.get("msaa_3d"))
	var taa := str(_viewport.get("use_taa"))
	var vsync := str(DisplayServer.window_get_vsync_mode()) if DisplayServer.has_method(&"window_get_vsync_mode") else "unknown"
	print("BENCH ENV")
	print("platform=%s | gpu=%s | vendor=%s" % [OS.get_name(), gpu, vendor])
	print("api=%s | driver=%s | renderer=%s" % [api, driver, method])
	print("window=%s | viewport=%s | internal_3d=%s | render_scale=%.2f" % [window_size, viewport_size, internal_size, scale])
	print("upscaler=%s | TAA=%s | MSAA_3D=%s | VSync=%s | max_fps=%s" % [upscaler, taa, msaa, vsync, Engine.max_fps])
	print("protocol=warmup %.2fs | measure %.2fs | gpu_fps_source=median_gpu_frame_time" % [_warmup_seconds, _measure_seconds])


func _print_summary() -> void:
	print("SUMMARY")
	var fft: Array = _block_results.get("fft", [])
	if fft.size() >= 4:
		print("FFT: ALL_OFF=%.3f ms | LONG increment=%.3f ms | MID increment=%.3f ms | SHORT increment=%.3f ms" % [fft[0].gpu_mean, fft[1].gpu_mean - fft[0].gpu_mean, fft[2].gpu_mean - fft[1].gpu_mean, fft[3].gpu_mean - fft[2].gpu_mean])
	var isolation: Array = _block_results.get("isolation", [])
	if isolation.size() >= 10:
		print("ISOLATED FEATURE COST: Optics=%.3f | Detail=%.3f | Crest=%.3f | Coastal=%.3f | SSPR=%.3f | Surface Foam=%.3f | Underwater=%.3f | Sunrays=%.3f | Bubbles=%.3f GPU ms" % [isolation[1].gpu_mean - isolation[0].gpu_mean, isolation[2].gpu_mean - isolation[0].gpu_mean, isolation[3].gpu_mean - isolation[0].gpu_mean, isolation[4].gpu_mean - isolation[0].gpu_mean, isolation[5].gpu_mean - isolation[0].gpu_mean, isolation[6].gpu_mean - isolation[0].gpu_mean, isolation[7].gpu_mean - isolation[0].gpu_mean, isolation[8].gpu_mean - isolation[0].gpu_mean, isolation[9].gpu_mean - isolation[0].gpu_mean])
	var production: Array = _block_results.get("production", [])
	if not production.is_empty():
		print("PRODUCTION: MAX_60=%s | MAX_40=%s" % [_last_pass_level(production, "PASS_60"), _last_pass_level(production, "PASS_40")])
	var full_minus: Array = _block_results.get("full_minus", [])
	if full_minus.size() >= 2:
		var recoveries: Array[Dictionary] = []
		for index in full_minus.size() - 1:
			recoveries.append({"label": full_minus[index + 1].label, "gpu": full_minus[0].gpu_mean - full_minus[index + 1].gpu_mean})
		recoveries.sort_custom(func(a, b): return a.gpu > b.gpu)
		print("FULL MINUS ONE: best recovery=%s %.3f ms | second=%s %.3f ms" % [recoveries[0].label, recoveries[0].gpu, recoveries[1].label, recoveries[1].gpu])
	var resolution: Dictionary = _block_results.get("resolution", {})
	for scale in [1.0, 0.85, 0.70]:
		var chain: Array = resolution.get(scale, [])
		if not chain.is_empty(): print("RESOLUTION SENSITIVITY: scale=%.2f | P0=%.3f ms | P6=%.3f ms" % [scale, chain[0].gpu_mean, chain[6].gpu_mean])
	if _failures.is_empty():
		print("LIFECYCLE VALIDATION: PASS")
	else:
		print("LIFECYCLE VALIDATION: FAIL | %s" % "; ".join(_failures))
	print("BENCHMARK RESULT: %s" % ("PASS" if _failures.is_empty() else "FAIL"))


func _print_max_levels(results: Array) -> void:
	print("PRODUCTION THRESHOLDS | MAX_60=%s | MAX_40=%s" % [_last_pass_level(results, "PASS_60"), _last_pass_level(results, "PASS_40")])


func _last_pass_level(results: Array, classification: String) -> String:
	var last := "NONE"
	for result in results:
		var fps: float = result.gpu_fps
		if classification == "PASS_60" and fps >= 60.0: last = result.label
		elif classification == "PASS_40" and fps >= 40.0: last = result.label
	return last


func _classify(fps: float) -> String:
	if fps >= 60.0: return "PASS_60"
	if fps >= 40.0: return "PASS_40"
	return "FAIL_40"


func _set_render_scale(value: float) -> void:
	if _viewport != null and _viewport.get("scaling_3d_scale") != null:
		_viewport.set("scaling_3d_scale", value)
		await get_tree().process_frame


func _set_underwater_camera(underwater: bool) -> void:
	if underwater:
		_camera.position = Vector3(0.0, -2.0, 16.0)
		_camera.rotation_degrees = Vector3(12.0, 0.0, 0.0)
	else:
		_camera.position = Vector3(0.0, 8.0, 16.0)
		_camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)


func _shutdown_benchmark_world() -> void:
	if _ocean != null:
		_ocean.enabled = false


func _rendering_server_value(method: StringName, fallback: String) -> String:
	if RenderingServer.has_method(method): return str(RenderingServer.call(method))
	return fallback


func _scaling_mode_name(value: Variant) -> String:
	var mode := int(value)
	return ["BILINEAR", "FSR", "FSR2"][mode] if mode >= 0 and mode < 3 else str(value)


func _has_user_argument(value: String) -> bool:
	return value in OS.get_cmdline_user_args() or value in OS.get_cmdline_args()


func _wait_seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _average(values: Array[float]) -> float:
	if values.is_empty(): return 0.0
	var total := 0.0
	for value in values: total += value
	return total / float(values.size())


func _median(values: Array[float]) -> float:
	if values.is_empty(): return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1: return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) * 0.5


func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty(): return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(float(sorted.size() - 1) * fraction)), 0, sorted.size() - 1)
	return sorted[index]
