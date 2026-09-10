extends Node3D
## PERF CHECKPOINT 1C-A production render shell.
## This scene instantiates the real P0 authoring scene, removes only its
## validation island, and measures the production environment/ocean separately
## from validation/ocean_benchmark.gd.

const CASCADE_STATE := preload("res://addons/ocean/core/ocean_cascade_state.gd")
const COASTAL_BAKE_PATH := "res://validation/p4_paradise/coastal_bake.tres"
const RESULT_TXT := "user://production_benchmark_results.txt"
const RESULT_CSV := "user://production_benchmark_results.csv"
const TRANSITION_CSV := "user://water_transition_frames.csv"
const DEFAULT_RESOLUTION := Vector2i(1920, 1080)
const TRANSITION_SECONDS := 2.5
const ABOVE_SECONDS := 3.0
const UNDERWATER_SECONDS := 5.0
const MIN_SAMPLE_COUNT := 5

var _reference: Node3D
var _world: WorldEnvironment
var _sun: DirectionalLight3D
var _camera: Camera3D
var _ocean: Ocean
var _viewport_rid: RID
var _requested_resolution := DEFAULT_RESOLUTION
var _window_mode := "windowed"
var _run_mode := "all"
var _hud_enabled := false
var _text_lines: PackedStringArray = []
var _csv_rows: Array[String] = []
var _transition_rows: Array[String] = []
var _reference_environment: Environment
var _reference_camera_attributes: CameraAttributes
var _reference_shadows := true
var _initial_surface_y := 0.0
var _transition_frame := 0
var _previous_transition_usec := 0


func _ready() -> void:

	_parse_args()
	_reference = get_node_or_null(^"P0OpenOcean") as Node3D
	if _reference == null:
		_fail_and_quit("INVALID_REFERENCE_SCENE")
		return
	_reference.get_node_or_null(^"testisland").queue_free()
	var gate := _reference.get_node_or_null(^"FFTCascadeGate")
	if gate != null:
		gate.queue_free()
	_world = _reference.get_node_or_null(^"WorldEnvironment") as WorldEnvironment
	_sun = _reference.get_node_or_null(^"Sun") as DirectionalLight3D
	_camera = _reference.get_node_or_null(^"FreeCamera") as Camera3D
	_ocean = _reference.get_node_or_null(^"Ocean") as Ocean
	if _world == null or _sun == null or _camera == null or _ocean == null:
		_fail_and_quit("INVALID_REFERENCE_SCENE_NODES")
		return
	_camera.set_process(false)
	_camera.set_process_input(false)
	_camera.current = true
	_reference_environment = _world.environment
	_reference_camera_attributes = _world.camera_attributes
	_reference_shadows = _sun.shadow_enabled
	_viewport_rid = get_viewport().get_viewport_rid()
	_configure_window()
	_write_header()
	await get_tree().process_frame
	if not _validate_resolution():
		_fail_and_quit("INVALID_RESOLUTION")
		return
	if _run_mode == "environment" or _run_mode == "all":
		await _run_environment_matrix()
	if _run_mode == "production" or _run_mode == "all":
		await _run_production_matrix()
	if _run_mode == "underwater" or _run_mode == "all":
		await _run_underwater_matrix()
	_write_outputs()
	if _hud_enabled:
		print("PRODUCTION BENCHMARK COMPLETE | HUD mode: process remains open")
	else:
		get_tree().quit()


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ocean-resolution="):
			var parts := arg.trim_prefix("--ocean-resolution=").split("x")
			if parts.size() == 2:
				_requested_resolution = Vector2i(maxi(int(parts[0]), 1), maxi(int(parts[1]), 1))
		elif arg.begins_with("--ocean-production="):
			_run_mode = arg.trim_prefix("--ocean-production=").to_lower()
		elif arg.begins_with("--ocean-window="):
			_window_mode = arg.trim_prefix("--ocean-window=").to_lower()
		elif arg == "--ocean-hud=on" or arg == "--ocean-visual":
			_hud_enabled = true


func _configure_window() -> void:
	if _window_mode == "fullscreen":
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif _window_mode == "borderless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(_requested_resolution)
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	else:
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(_requested_resolution)


func _validate_resolution() -> bool:
	var actual_window: Vector2i = DisplayServer.window_get_size()
	var actual_viewport: Vector2i = get_viewport().size
	var ok: bool = actual_window == _requested_resolution and actual_viewport == _requested_resolution
	_log("RESOLUTION | requested=%s | actual_window=%s | actual_viewport=%s | actual_render_size=%s | display=%s | mode=%s | status=%s" % [_requested_resolution, actual_window, actual_viewport, actual_viewport, DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()), _window_mode, "OK" if ok else "INVALID_RESOLUTION"])
	return ok


func _write_header() -> void:
	var adapter := RenderingServer.get_video_adapter_name() if RenderingServer.has_method(&"get_video_adapter_name") else "unknown"
	var vendor := RenderingServer.get_video_adapter_vendor() if RenderingServer.has_method(&"get_video_adapter_vendor") else "unknown"
	var api := RenderingServer.get_video_adapter_api_version() if RenderingServer.has_method(&"get_video_adapter_api_version") else "unknown"
	var renderer: String = str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"))
	var driver: String = str(ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "default")) if OS.get_name() == "Windows" else "default"
	_log("PRODUCTION BENCHMARK | checkpoint=1C-A | platform=%s | renderer=%s | backend=%s | driver=%s | gpu=%s | vendor=%s" % [OS.get_name(), renderer, api, driver, adapter, vendor])
	_log("RESOLUTION | requested=%s | mode=%s | dynamic_resolution=OFF | upscaler=OFF" % [_requested_resolution, _window_mode])
	_log("REFERENCE | scene=res://validation/p0_open_ocean.tscn | hdr=Kloofendal 48d | island=REMOVED_FOR_PRODUCTION_SHELL")
	_log("REFERENCE | Environment, CameraAttributesPhysical, Sun and Ocean values are inherited from the real P0 scene")


func _run_environment_matrix() -> void:
	_log("\nE MATRIX | environment-only shell; no ocean feature delta is claimed")
	var cases := ["E0_ENV_ONLY", "E1_HDRI_SKY", "E2_CAMERA_EXPOSURE", "E3_GLOW_POST", "E4_SUN_SHADOWS"]
	for label in cases:
		_apply_environment_case(label)
		await get_tree().process_frame
		var result := await _measure(label, 1.5)
		_record(label, result)
	_restore_reference_environment()


func _apply_environment_case(label: String) -> void:
	var environment := _reference_environment.duplicate(true) as Environment
	var camera_attributes: CameraAttributes = _reference_camera_attributes.duplicate(true) if _reference_camera_attributes != null else null
	environment.background_mode = Environment.BG_COLOR
	environment.sky = null
	environment.glow_enabled = false
	_sun.shadow_enabled = false
	_world.camera_attributes = null
	if label == "E1_HDRI_SKY" or label == "E2_CAMERA_EXPOSURE" or label == "E3_GLOW_POST" or label == "E4_SUN_SHADOWS":
		environment = _reference_environment.duplicate(true) as Environment
	if label == "E2_CAMERA_EXPOSURE" or label == "E3_GLOW_POST" or label == "E4_SUN_SHADOWS":
		_world.camera_attributes = camera_attributes
	if label == "E3_GLOW_POST" or label == "E4_SUN_SHADOWS":
		environment.glow_enabled = true
	if label == "E4_SUN_SHADOWS":
		_sun.shadow_enabled = _reference_shadows
	_world.environment = environment


func _restore_reference_environment() -> void:
	_world.environment = _reference_environment
	_world.camera_attributes = _reference_camera_attributes
	_sun.shadow_enabled = _reference_shadows


func _run_production_matrix() -> void:
	_log("\nP MATRIX | production shell; cumulative feature enablement")
	_camera.position.y = 20.0
	var cases := [
		["P0_ENV_ONLY", 0, false, false, false, false, false, false, false, false, false],
		["P1_STATIC_FFT_OFF", 0, false, false, false, false, false, false, false, false, false],
		["P2_FULL_FFT", CASCADE_STATE.FULL, false, false, false, false, false, false, false, false, false],
		["P3_COASTAL", CASCADE_STATE.FULL, true, false, false, false, false, false, false, false, false],
		["P4_CREST_FOAM", CASCADE_STATE.FULL, true, true, false, false, false, false, false, false, false],
		["P5_SURFACE_FOAM", CASCADE_STATE.FULL, true, true, true, false, false, false, false, false, false],
		["P6_OPTICS", CASCADE_STATE.FULL, true, true, true, true, false, false, false, false, false],
		["P7_REFLECTIONS_SSPR", CASCADE_STATE.FULL, true, true, true, true, true, false, false, false, false],
		["P8_SURFACE_DETAIL", CASCADE_STATE.FULL, true, true, true, true, true, true, false, false, false],
		["P9_UNDERWATER_PREPARED", CASCADE_STATE.FULL, true, true, true, true, true, true, true, false, false],
		["P10_FULL", CASCADE_STATE.FULL, true, true, true, true, true, true, true, true, true],
	]
	for case_data in cases:
		var label: String = case_data[0]
		if label == "P0_ENV_ONLY":
			_ocean.enabled = false
			await get_tree().process_frame
			_record(label, await _measure(label, 1.0))
			continue
		if label == "P1_STATIC_FFT_OFF":
			_ocean.open_ocean_fft = false
			_ocean.enabled = false
			await get_tree().process_frame
			_record(label, await _measure(label, 1.0))
			continue
		_apply_production_case(case_data)
		await _restart_ocean()
		_record(label, await _measure(label, 1.5))


func _apply_production_case(case_data: Array) -> void:
	_ocean.open_ocean_fft = true
	_ocean.enabled = true
	_ocean.set_fft_cascade_mask(int(case_data[1]))
	_ocean.coastal_bake = load(COASTAL_BAKE_PATH)
	_ocean.coastal = bool(case_data[2])
	_ocean.crest_foam = bool(case_data[3])
	_ocean.surface_foam = bool(case_data[4])
	_ocean.optics = bool(case_data[5])
	_ocean.reflections = bool(case_data[6])
	_ocean.surface_detail = bool(case_data[7])
	_ocean.underwater_medium = bool(case_data[8])
	_ocean.underwater_bubbles = bool(case_data[9])
	_ocean.underwater_sunrays = bool(case_data[10])


func _restart_ocean() -> void:
	_ocean.shutdown()
	await get_tree().process_frame
	if _ocean.enabled and _ocean.open_ocean_fft:
		_ocean.initialize()
	await _wait_seconds(1.0)


func _run_underwater_matrix() -> void:
	_log("\nU MATRIX | one full FFT runtime; physical camera trajectory across GPU waterline")
	_apply_production_case(["U_FULL", CASCADE_STATE.FULL, true, true, true, true, true, true, true, true, true])
	_ocean.underwater_bubbles = true
	_ocean.underwater_sunrays = true
	await _restart_ocean()
	_ocean.set_waterline_state_readback_enabled(true)
	await _wait_for_waterline_state(5.0)
	var state := _ocean.get_waterline_state()
	if not bool(state.get("valid", false)):
		_log("U INVALID | GPU waterline state never became valid; U0-U3 are not reported as valid")
		return
	_initial_surface_y = float(state.get("water_surface_y", 0.0))
	_camera.position = Vector3(0.0, _initial_surface_y + 8.0, 16.0)
	var u0 := await _measure("U0_FULL_ABOVE", ABOVE_SECONDS)
	_record("U0_FULL_ABOVE", u0)
	await _run_trajectory("U1_ENTRY_TRANSITION", _initial_surface_y + 8.0, _initial_surface_y - 8.0, TRANSITION_SECONDS)
	_camera.position.y = _initial_surface_y - 8.0
	_record("U2_FULL_UNDERWATER", await _measure("U2_FULL_UNDERWATER", UNDERWATER_SECONDS))
	await _run_trajectory("U3_EXIT_TRANSITION", _initial_surface_y - 8.0, _initial_surface_y + 8.0, TRANSITION_SECONDS)
	_camera.position.y = _initial_surface_y + 8.0
	_record("U3_FULL_ABOVE_STABLE", await _measure("U3_FULL_ABOVE_STABLE", ABOVE_SECONDS))
	_log_transition_summary()


func _wait_for_waterline_state(seconds: float) -> void:
	var end_usec := Time.get_ticks_usec() + int(seconds * 1000000.0)
	while Time.get_ticks_usec() < end_usec:
		await get_tree().process_frame
		if bool(_ocean.get_waterline_state().get("valid", false)):
			return


func _run_trajectory(label: String, from_y: float, to_y: float, seconds: float) -> void:
	var start_usec := Time.get_ticks_usec()
	var duration_usec := int(seconds * 1000000.0)
	_previous_transition_usec = 0
	while Time.get_ticks_usec() - start_usec < duration_usec:
		await get_tree().process_frame
		var t := clampf(float(Time.get_ticks_usec() - start_usec) / float(duration_usec), 0.0, 1.0)
		_camera.position.y = lerpf(from_y, to_y, t)
		_record_transition_frame(label)


func _record_transition_frame(phase: String) -> void:
	var state := _ocean.get_waterline_state()
	var valid := bool(state.get("valid", false))
	var signed_distance := float(state.get("signed_distance_to_surface", NAN)) if valid else NAN
	var surface_y := float(state.get("water_surface_y", NAN)) if valid else NAN
	var state_label := _classify_water_state(signed_distance) if valid else "INVALID"
	var now_usec := Time.get_ticks_usec()
	var frame_ms := float(now_usec - _previous_transition_usec) / 1000.0 if _previous_transition_usec > 0 else NAN
	_previous_transition_usec = now_usec
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
	_transition_frame += 1
	_transition_rows.append("%d,%s,%.6f,%s,%s,%s,%s,%s,%s,%s" % [_transition_frame, phase, float(now_usec) / 1000000.0, state_label, _csv_value(signed_distance), _csv_value(_camera.position.y), _csv_value(surface_y), _csv_value(gpu_ms if gpu_ms > 0.0 else NAN), _csv_value(cpu_ms if cpu_ms > 0.0 else NAN), _csv_value(frame_ms)])


func _classify_water_state(signed_distance: float) -> String:
	var band := 0.25
	if _ocean.underwater_medium_profile != null:
		band = maxf(band, maxf(_ocean.underwater_medium_profile.enter_margin_m, _ocean.underwater_medium_profile.exit_margin_m) * 2.0)
	if signed_distance > band:
		return "ABOVE"
	if signed_distance < -band:
		return "UNDERWATER"
	return "TRANSITION"


func _measure(label: String, seconds: float) -> Dictionary:
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var frame: Array[float] = []
	var primitives: Array[float] = []
	var draws: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	var end_usec := previous_usec + int(seconds * 1000000.0)
	while Time.get_ticks_usec() < end_usec:
		await get_tree().process_frame
		var now_usec := Time.get_ticks_usec()
		var frame_ms := float(now_usec - previous_usec) / 1000.0
		previous_usec = now_usec
		if frame_ms > 0.0: frame.append(frame_ms)
		var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		if gpu_ms > 0.0: gpu.append(gpu_ms)
		if cpu_ms > 0.0: cpu.append(cpu_ms)
		var primitive: Variant = _rendering_info_value("primitives")
		var draw: Variant = _rendering_info_value("draws")
		if primitive != null: primitives.append(float(primitive))
		if draw != null: draws.append(float(draw))
	return {
		"label": label,
		"gpu": _stats(gpu),
		"cpu": _stats(cpu),
		"frame": _stats(frame),
		"primitives": _stats(primitives),
		"draws": _stats(draws),
		"sample_count": frame.size(),
	}


func _stats(values: Array[float]) -> Dictionary:
	if values.size() < MIN_SAMPLE_COUNT:
		return {"available": false, "count": values.size()}
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	return {"available": true, "count": sorted.size(), "median": _percentile(sorted, 0.50), "p95": _percentile(sorted, 0.95), "p99": _percentile(sorted, 0.99), "max": sorted.back()}


func _percentile(sorted: Array[float], fraction: float) -> float:
	if sorted.is_empty(): return NAN
	var index := clampi(int(ceil(fraction * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return float(sorted[index])


func _record(label: String, result: Dictionary) -> void:
	var gpu: Dictionary = result.get("gpu", {})
	var cpu: Dictionary = result.get("cpu", {})
	var frame: Dictionary = result.get("frame", {})
	var primitives: Dictionary = result.get("primitives", {})
	var draws: Dictionary = result.get("draws", {})
	_log("%s | GPU median/p95/p99/max=%s | CPU median/p95/p99/max=%s | frame median/p95/p99/max=%s | FPS=%s | primitives=%s | draws=%s" % [label, _stats_text(gpu), _stats_text(cpu), _stats_text(frame), _fps_text(frame), _stats_text(primitives), _stats_text(draws)])
	_csv_rows.append("%s,%s,%s,%s,%s,%s" % [label, _stats_csv(gpu), _stats_csv(cpu), _stats_csv(frame), _stats_value(primitives, "median"), _stats_value(draws, "median")])


func _log_transition_summary() -> void:
	var counts := {"ABOVE": 0, "TRANSITION": 0, "UNDERWATER": 0, "INVALID": 0}
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var frame: Array[float] = []
	var over_16_67 := 0
	var over_20 := 0
	var over_25 := 0
	var over_33_3 := 0
	for row in _transition_rows:
		var fields := row.split(",")
		var state := fields[3]
		counts[state] = int(counts.get(state, 0)) + 1
		if fields.size() >= 10:
			var gpu_ms := _float_or_nan(fields[7])
			var cpu_ms := _float_or_nan(fields[8])
			var frame_ms := _float_or_nan(fields[9])
			if not is_nan(gpu_ms): gpu.append(gpu_ms)
			if not is_nan(cpu_ms): cpu.append(cpu_ms)
			if not is_nan(frame_ms):
				frame.append(frame_ms)
				if frame_ms > 16.67: over_16_67 += 1
				if frame_ms > 20.0: over_20 += 1
				if frame_ms > 25.0: over_25 += 1
				if frame_ms > 33.3: over_33_3 += 1
	_log("TRANSITION | frames=%d | above=%d | transition=%d | underwater=%d | invalid=%d | GPU median/p95/p99/max=%s | CPU median/p95/p99/max=%s | frame median/p95/p99/max=%s | >16.67=%d | >20=%d | >25=%d | >33.3=%d | csv=%s" % [_transition_rows.size(), counts["ABOVE"], counts["TRANSITION"], counts["UNDERWATER"], counts["INVALID"], _stats_text(_stats(gpu)), _stats_text(_stats(cpu)), _stats_text(_stats(frame)), over_16_67, over_20, over_25, over_33_3, TRANSITION_CSV])


func _rendering_info_value(kind: String) -> Variant:
	if not RenderingServer.has_method(&"get_rendering_info"): return null
	var constant := RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME if kind == "primitives" else RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	return RenderingServer.get_rendering_info(constant)


func _stats_text(stats: Dictionary) -> String:
	if not bool(stats.get("available", false)): return "UNAVAILABLE(n=%d)" % int(stats.get("count", 0))
	return "%.3f/%.3f/%.3f/%.3f ms" % [stats["median"], stats["p95"], stats["p99"], stats["max"]]


func _stats_csv(stats: Dictionary) -> String:
	if not bool(stats.get("available", false)): return "NA,NA,NA,NA"
	return "%.6f,%.6f,%.6f,%.6f" % [stats["median"], stats["p95"], stats["p99"], stats["max"]]


func _stats_value(stats: Dictionary, key: String) -> String:
	return "%.3f" % float(stats[key]) if bool(stats.get("available", false)) else "NA"


func _fps_text(frame: Dictionary) -> String:
	if not bool(frame.get("available", false)) or float(frame.get("median", 0.0)) <= 0.0: return "UNAVAILABLE"
	return "%.2f" % (1000.0 / float(frame["median"]))


func _csv_value(value: float) -> String:
	return "NA" if is_nan(value) else "%.6f" % value


func _float_or_nan(value: String) -> float:
	return NAN if value == "NA" else float(value)


func _wait_seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _log(message: String) -> void:
	print(message)
	_text_lines.append(message)


func _write_outputs() -> void:
	var txt := FileAccess.open(RESULT_TXT, FileAccess.WRITE)
	if txt != null:
		txt.store_string("\n".join(_text_lines) + "\n")
	var csv := FileAccess.open(RESULT_CSV, FileAccess.WRITE)
	if csv != null:
		csv.store_line("label,gpu_median,gpu_p95,gpu_p99,gpu_max,cpu_median,cpu_p95,cpu_p99,cpu_max,frame_median,frame_p95,frame_p99,frame_max,primitives_median,draws_median")
		for row in _csv_rows: csv.store_line(row)
	var transition := FileAccess.open(TRANSITION_CSV, FileAccess.WRITE)
	if transition != null:
		transition.store_line("frame,phase,time_s,state,signed_distance_m,camera_y,water_surface_y,gpu_ms,cpu_ms,frame_ms")
		for row in _transition_rows: transition.store_line(row)


func _fail_and_quit(reason: String) -> void:
	_log("INVALID | %s" % reason)
	_write_outputs()
	get_tree().quit(2)
