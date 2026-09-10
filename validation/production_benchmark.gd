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
const TRANSITION_COLUMN_COUNT := 20
const TRANSITION_CSV_HEADER := "frame,phase,time_s,benchmark_geometric_state,gpu_signed_distance_m,current_camera_y,water_surface_y,gpu_ms,cpu_ms,frame_ms,camera_frame_id,water_query_frame_id,gpu_readback_frame_id,query_age_frames,source_process_frame_id,query_camera_y,geometric_signed_distance_m,gpu_waterline_state,benchmark_state_domain,geometric_gpu_aligned"
const DEFAULT_RESOLUTION := Vector2i(1920, 1080)
const TRANSITION_SECONDS := 2.5
const SLOW_CROSS_BAND_SECONDS := 0.85
const SLOW_APPROACH_SECONDS := 1.50
const SLOW_DEPARTURE_SECONDS := 1.50
const ABOVE_SECONDS := 3.0
const UNDERWATER_SECONDS := 5.0
const MIN_SAMPLE_COUNT := 5
const TIMING_DETECTION_SAMPLES := 10
const TIMING_SUSPECT_RATIO := 4.0

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
var _last_state_verify_valid := true
var _timing_probe_sample := 0
var _timing_probe_gpu_raw: Array[float] = []
var _timing_probe_cpu_raw: Array[float] = []
var _timing_probe_frame_delta: Array[float] = []
var _timing_gpu_mode := "undetermined"
var _timing_cpu_mode := "undetermined"
var _timing_mode_locked := false


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
	if RenderingServer.has_method(&"viewport_set_measure_render_time"):
		RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
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
	_log("TIMING | GPU_RAW/CPU_RAW are sampled directly; per-frame values use raw samples or successive deltas when the backend exposes an accumulated counter; wall frame time remains separate")
	_log("WATERLINE | BENCHMARK_GEOMETRIC_STATE=query_camera_y-water_surface_y from one source-aligned P6 sample; GPU_WATERLINE_STATE=signed_distance_to_surface; source render/process frames and readback sequence are logged separately")


func _run_environment_matrix() -> void:
	_log("\nE MATRIX | environment-only shell; no ocean feature delta is claimed")
	# The reference scene initializes its Ocean before this shell's _ready().
	# E must explicitly retire that runtime; otherwise its counters measure P0
	# surface geometry, not the environment-only shell.
	_ocean.enabled = false
	_ocean.open_ocean_fft = false
	await get_tree().process_frame
	var cases := ["E0_ENV_ONLY", "E1_HDRI_SKY", "E2_CAMERA_EXPOSURE", "E3_GLOW_POST", "E4_SUN_SHADOWS"]
	for label in cases:
		_apply_environment_case(label)
		await get_tree().process_frame
		var result := await _measure(label, 1.5, 0)
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
			_ocean.open_ocean_fft = false
			_last_state_verify_valid = true
			await get_tree().process_frame
			_record(label, await _measure(label, 1.0, 0))
			continue
		_apply_production_case(case_data)
		await _restart_ocean(label)
		_record(label, await _measure(label, 1.5, 1))


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



func _restart_ocean(label := "") -> void:
	var setup_start_usec := Time.get_ticks_usec()
	_ocean.shutdown()
	await get_tree().process_frame
	if _ocean.enabled and _ocean.open_ocean_fft:
		var initialized := _ocean.initialize()
		_log("SETUP | case=%s | initialize=%s | setup_ms=%.3f" % [label, initialized, float(Time.get_ticks_usec() - setup_start_usec) / 1000.0])
	else:
		_log("SETUP | case=%s | initialize=false | setup_ms=%.3f" % [label, float(Time.get_ticks_usec() - setup_start_usec) / 1000.0])
	await _wait_seconds(1.0)
	_state_verify(label)


func _run_underwater_matrix() -> void:
	_log("\nU MATRIX | one full FFT runtime; physical camera trajectory across GPU waterline")
	_apply_production_case(["U_FULL", CASCADE_STATE.FULL, true, true, true, true, true, true, true, true, true])
	_ocean.underwater_bubbles = true
	_ocean.underwater_sunrays = true
	await _restart_ocean("U_FULL")
	_state_verify("U_FULL")
	_ocean.set_waterline_state_readback_enabled(true)
	await _wait_for_waterline_state(5.0)
	var state := _ocean.get_waterline_state()
	if not bool(state.get("valid", false)):
		_log("U INVALID | GPU waterline state never became valid; U0-U3 are not reported as valid")
		return
	_initial_surface_y = float(state.get("water_surface_y", 0.0))
	_camera.position = Vector3(0.0, _initial_surface_y + 8.0, 16.0)
	var u0_state_valid := await _state_verify_water_position("U0_FULL_ABOVE", "ABOVE")
	if not u0_state_valid:
		_log("CASE_INVALID | U0_FULL_ABOVE | waterline state did not confirm ABOVE")
	var u0 := await _measure("U0_FULL_ABOVE", ABOVE_SECONDS, 1)
	_record("U0_FULL_ABOVE", u0)
	await _run_trajectory("U1_FAST_ENTRY", _initial_surface_y + 8.0, _initial_surface_y - 8.0, TRANSITION_SECONDS)
	_camera.position.y = _initial_surface_y - 8.0
	var u2_state_valid := await _state_verify_water_position("U2_FULL_UNDERWATER", "UNDERWATER")
	if not u2_state_valid:
		_log("CASE_INVALID | U2_FULL_UNDERWATER | waterline state did not confirm UNDERWATER")
	_record("U2_FULL_UNDERWATER", await _measure("U2_FULL_UNDERWATER", UNDERWATER_SECONDS, 1))
	await _run_trajectory("U3_FAST_EXIT", _initial_surface_y - 8.0, _initial_surface_y + 8.0, TRANSITION_SECONDS)
	_camera.position.y = _initial_surface_y + 8.0
	var u3_state_valid := await _state_verify_water_position("U3_FULL_ABOVE_STABLE", "ABOVE")
	if not u3_state_valid:
		_log("CASE_INVALID | U3_FULL_ABOVE_STABLE | waterline state did not confirm ABOVE")
	_record("U3_FULL_ABOVE_STABLE", await _measure("U3_FULL_ABOVE_STABLE", ABOVE_SECONDS, 1))
	await _run_slow_cross("U1_SLOW_ENTRY", true)
	_camera.position.y = _initial_surface_y - 8.0
	var u1_slow_state_valid := await _state_verify_water_position("U1_SLOW_ENTRY_UNDERWATER", "UNDERWATER")
	if not u1_slow_state_valid:
		_log("CASE_INVALID | U1_SLOW_ENTRY_UNDERWATER | waterline state did not confirm UNDERWATER")
	_record("U1_SLOW_ENTRY_UNDERWATER_STABLE", await _measure("U1_SLOW_ENTRY_UNDERWATER_STABLE", UNDERWATER_SECONDS, 1))
	await _run_slow_cross("U3_SLOW_EXIT", false)
	_camera.position.y = _initial_surface_y + 8.0
	var u3_slow_state_valid := await _state_verify_water_position("U3_SLOW_EXIT_ABOVE", "ABOVE")
	if not u3_slow_state_valid:
		_log("CASE_INVALID | U3_SLOW_EXIT_ABOVE | waterline state did not confirm ABOVE")
	_record("U3_SLOW_EXIT_ABOVE_STABLE", await _measure("U3_SLOW_EXIT_ABOVE_STABLE", ABOVE_SECONDS, 1))
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
	_begin_timing_probe(label)
	while Time.get_ticks_usec() - start_usec < duration_usec:
		await get_tree().process_frame
		var t := clampf(float(Time.get_ticks_usec() - start_usec) / float(duration_usec), 0.0, 1.0)
		_camera.position.y = lerpf(from_y, to_y, t)
		_record_transition_frame(label)


func _run_slow_cross(label: String, entering: bool) -> void:
	# The camera remains continuous throughout. Only the segment from +0.25 m
	# to -0.25 m (or the reverse) is deliberately slowed to ~0.85 s; the
	# diagnostic band and the GPU waterline query are unchanged.
	var direction := -1.0 if entering else 1.0
	var approach_y := _initial_surface_y + direction * 0.5
	var band_start_y := _initial_surface_y + direction * 0.25
	var band_end_y := _initial_surface_y - direction * 0.25
	var destination_y := _initial_surface_y - direction * 8.0
	_previous_transition_usec = 0
	_begin_timing_probe(label)
	await _run_trajectory_segment(label, _camera.position.y, approach_y, SLOW_APPROACH_SECONDS)
	await _run_trajectory_segment(label, approach_y, band_start_y, 0.35)
	await _run_trajectory_segment(label, band_start_y, band_end_y, SLOW_CROSS_BAND_SECONDS)
	await _run_trajectory_segment(label, band_end_y, destination_y, SLOW_DEPARTURE_SECONDS)


func _run_trajectory_segment(label: String, from_y: float, to_y: float, seconds: float) -> void:
	var start_usec := Time.get_ticks_usec()
	var duration_usec := int(seconds * 1000000.0)
	while Time.get_ticks_usec() - start_usec < duration_usec:
		await get_tree().process_frame
		var t := clampf(float(Time.get_ticks_usec() - start_usec) / float(duration_usec), 0.0, 1.0)
		var smooth_t := t * t * (3.0 - 2.0 * t)
		_camera.position.y = lerpf(from_y, to_y, smooth_t)
		_record_transition_frame(label)


func _record_transition_frame(phase: String) -> void:
	var state := _ocean.get_waterline_state()
	var valid := bool(state.get("valid", false))
	var gpu_signed_distance := float(state.get("signed_distance_to_surface", NAN)) if valid else NAN
	var surface_y := float(state.get("water_surface_y", NAN)) if valid else NAN
	var query_camera_y := float(state.get("query_camera_y", NAN)) if valid else NAN
	var geometric_signed_distance := query_camera_y - surface_y if valid and is_finite(query_camera_y) and is_finite(surface_y) else NAN
	var state_label := _classify_water_state(geometric_signed_distance) if is_finite(geometric_signed_distance) else "INVALID"
	var gpu_state_label := _classify_water_state(gpu_signed_distance) if valid and is_finite(gpu_signed_distance) else "INVALID"
	var aligned := is_finite(geometric_signed_distance) and is_finite(gpu_signed_distance) and absf(geometric_signed_distance - gpu_signed_distance) <= 0.01
	var now_usec := Time.get_ticks_usec()
	var frame_ms := float(now_usec - _previous_transition_usec) / 1000.0 if _previous_transition_usec > 0 else NAN
	_previous_transition_usec = now_usec
	var timing := _read_render_timing(frame_ms, phase)
	_transition_frame += 1
	var camera_frame_id := Engine.get_frames_drawn()
	var query_frame_id := int(state.get("source_render_frame_id", state.get("water_query_frame_id", state.get("query_frame_id", 0))))
	var source_process_frame_id := int(state.get("source_process_frame_id", 0))
	var query_age_frames := camera_frame_id - query_frame_id if query_frame_id > 0 else -1
	var current_state_aligned := query_frame_id > 0 and query_age_frames <= 1 and is_finite(query_camera_y) and absf(query_camera_y - _camera.position.y) <= 0.01
	var state_domain := "CURRENT_BENCHMARK_STATE" if current_state_aligned else "HISTORICAL_GPU_WATERLINE_SAMPLE"
	var row_values: Array[String] = [
		str(_transition_frame), phase, "%.6f" % (float(now_usec) / 1000000.0), state_label,
		_csv_value(gpu_signed_distance), _csv_value(_camera.position.y), _csv_value(surface_y),
		_csv_value(float(timing["gpu_ms"])), _csv_value(float(timing["cpu_ms"])), _csv_value(frame_ms),
		str(camera_frame_id), str(query_frame_id), str(int(state.get("gpu_readback_frame_id", state.get("frame", 0)))),
		str(query_age_frames), str(source_process_frame_id), _csv_value(query_camera_y), _csv_value(geometric_signed_distance), gpu_state_label, state_domain, "YES" if aligned else "NO"]
	_transition_rows.append(",".join(row_values))
	var gpu_history: Array = timing["gpu_samples"]
	var cpu_history: Array = timing["cpu_samples"]
	if gpu_history.size() > 1 or cpu_history.size() > 1:
		_patch_transition_timing(gpu_history, cpu_history)


func _patch_transition_timing(gpu_samples: Array, cpu_samples: Array) -> void:
	var sample_count := mini(gpu_samples.size(), cpu_samples.size())
	var first_row := _transition_rows.size() - sample_count
	for offset in range(sample_count):
		var row_index := first_row + offset
		if row_index < 0 or row_index >= _transition_rows.size(): continue
		var fields := _transition_rows[row_index].split(",")
		if fields.size() < 10: continue
		fields[7] = _csv_value(float(gpu_samples[offset]))
		fields[8] = _csv_value(float(cpu_samples[offset]))
		_transition_rows[row_index] = ",".join(fields)


func _classify_water_state(signed_distance: float) -> String:
	var band := 0.25
	if _ocean.underwater_medium_profile != null:
		band = maxf(band, maxf(_ocean.underwater_medium_profile.enter_margin_m, _ocean.underwater_medium_profile.exit_margin_m) * 2.0)
	if signed_distance > band:
		return "ABOVE"
	if signed_distance < -band:
		return "UNDERWATER"
	return "TRANSITION"


func _runtime_surface_present() -> bool:
	var runtime_state := _ocean.get_runtime_feature_state() if _ocean != null and _ocean.has_method(&"get_runtime_feature_state") else {}
	return bool(runtime_state.get("surface_present", false))


func _state_verify(label: String) -> bool:
	var requested_mask := _ocean.get_fft_cascade_mask()
	var open := _ocean.find_child("OpenOceanFFT", true, false)
	var graph: Dictionary = open.get_cascade_runtime_state() if open != null and open.has_method(&"get_cascade_runtime_state") else {}
	var effective_mask := int(graph.get("effective_mask", -1))
	var active_bands := "UNAVAILABLE"
	if graph.has("bands"):
		var active: Array[String] = []
		for band in graph["bands"]:
			if bool(band.get("effective", false)):
				active.append(str(band.get("name", "?")))
		active_bands = "+".join(active) if not active.is_empty() else "OFF"
	var runtime_state: Dictionary = _ocean.get_runtime_feature_state()
	var graph_features: Dictionary = graph.get("features", {})
	var coastal_features: Dictionary = graph_features.get("coastal_waves", {})
	var coastal_runtime := bool(coastal_features.get("runtime_active", false))
	var state_valid := effective_mask == requested_mask
	state_valid = state_valid and bool(_ocean.coastal) == coastal_runtime
	state_valid = state_valid and bool(_ocean.crest_foam) == bool(runtime_state.get("crest_foam", false))
	state_valid = state_valid and bool(_ocean.surface_foam) == bool(runtime_state.get("surface_foam", false))
	state_valid = state_valid and bool(_ocean.optics) == bool(runtime_state.get("optics", false))
	state_valid = state_valid and bool(_ocean.reflections) == bool(runtime_state.get("sspr", false))
	state_valid = state_valid and bool(_ocean.surface_detail) == bool(runtime_state.get("surface_detail", false))
	state_valid = state_valid and bool(_ocean.underwater_medium) == bool(runtime_state.get("underwater", false))
	state_valid = state_valid and bool(_ocean.underwater_bubbles) == bool(runtime_state.get("bubbles", false))
	state_valid = state_valid and bool(_ocean.underwater_sunrays) == bool(runtime_state.get("sunrays", false))
	_last_state_verify_valid = state_valid
	_log("STATE VERIFY | case=%s | status=%s | FFT requested=%d effective=%d bands=%s | coastal=%s/%s | crest=%s/%s | surface_foam=%s/%s | optics=%s/%s | SSPR=%s/%s | surface_detail=%s/%s | underwater=%s/%s | bubbles=%s/%s | sunrays=%s/%s" % [label, "OK" if state_valid else "MISMATCH", requested_mask, effective_mask, active_bands, _ocean.coastal, coastal_runtime, _ocean.crest_foam, runtime_state.get("crest_foam", false), _ocean.surface_foam, runtime_state.get("surface_foam", false), _ocean.optics, runtime_state.get("optics", false), _ocean.reflections, runtime_state.get("sspr", false), _ocean.surface_detail, runtime_state.get("surface_detail", false), _ocean.underwater_medium, runtime_state.get("underwater", false), _ocean.underwater_bubbles, runtime_state.get("bubbles", false), _ocean.underwater_sunrays, runtime_state.get("sunrays", false)])
	return state_valid


func _state_verify_water_position(label: String, expected: String) -> bool:
	var deadline_usec := Time.get_ticks_usec() + 3000000
	var waterline: Dictionary = {}
	var camera_frame_id := 0
	var query_frame_id := 0
	var query_age_frames := -1
	var current_sample_match := false
	while Time.get_ticks_usec() < deadline_usec:
		waterline = _ocean.get_waterline_state()
		camera_frame_id = Engine.get_frames_drawn()
		query_frame_id = int(waterline.get("source_render_frame_id", waterline.get("water_query_frame_id", waterline.get("query_frame_id", 0))))
		query_age_frames = camera_frame_id - query_frame_id if query_frame_id > 0 else -1
		var candidate_camera_y := float(waterline.get("query_camera_y", NAN))
		current_sample_match = bool(waterline.get("valid", false)) and is_finite(candidate_camera_y) and absf(candidate_camera_y - _camera.position.y) <= 0.01 and query_age_frames >= 0 and query_age_frames <= 1
		if current_sample_match: break
		await get_tree().process_frame
	var actual := "INVALID"
	var gpu_signed_distance := float(waterline.get("signed_distance_to_surface", NAN))
	var surface_y := float(waterline.get("water_surface_y", NAN))
	var query_camera_y := float(waterline.get("query_camera_y", NAN))
	var geometric_signed_distance := query_camera_y - surface_y if bool(waterline.get("valid", false)) and is_finite(query_camera_y) and is_finite(surface_y) else NAN
	if is_finite(geometric_signed_distance):
		actual = _classify_water_state(geometric_signed_distance)
	var gpu_state := _classify_water_state(gpu_signed_distance) if is_finite(gpu_signed_distance) else "INVALID"
	var aligned := is_finite(geometric_signed_distance) and is_finite(gpu_signed_distance) and absf(geometric_signed_distance - gpu_signed_distance) <= 0.01
	var state_domain := "CURRENT_BENCHMARK_STATE" if current_sample_match else "HISTORICAL_GPU_WATERLINE_SAMPLE"
	_log("STATE VERIFY | case=%s | expected_water_state=%s actual_water_state=%s | state_domain=%s | GPU_WATERLINE_STATE=%s | current_camera_y=%.6f | query_camera_y=%s | water_surface_y=%s | geometric_signed_distance_m=%s | gpu_signed_distance_m=%s | camera_frame_id=%d | source_query_frame_id=%d | source_process_frame_id=%d | readback_frame_id=%d | readback_age_frames=%d | aligned=%s" % [label, expected, actual, state_domain, gpu_state, _camera.position.y, _csv_value(query_camera_y), _csv_value(surface_y), _csv_value(geometric_signed_distance), _csv_value(gpu_signed_distance), camera_frame_id, query_frame_id, int(waterline.get("source_process_frame_id", 0)), int(waterline.get("gpu_readback_frame_id", waterline.get("frame", 0))), query_age_frames, "YES" if aligned else "NO"])
	return current_sample_match and actual == expected


func _measure(label: String, seconds: float, expected_surface := -1) -> Dictionary:
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var frame: Array[float] = []
	var primitives: Array[float] = []
	var draws: Array[float] = []
	_begin_timing_probe(label)
	var previous_usec := Time.get_ticks_usec()
	var end_usec := previous_usec + int(seconds * 1000000.0)
	while Time.get_ticks_usec() < end_usec:
		await get_tree().process_frame
		var now_usec := Time.get_ticks_usec()
		var frame_ms := float(now_usec - previous_usec) / 1000.0
		previous_usec = now_usec
		if frame_ms > 0.0: frame.append(frame_ms)
		var timing := _read_render_timing(frame_ms, label)
		for sample in timing["gpu_samples"]:
			if float(sample) > 0.0: gpu.append(float(sample))
		for sample in timing["cpu_samples"]:
			if float(sample) > 0.0: cpu.append(float(sample))
		var primitive: Variant = _rendering_info_value("primitives")
		var draw: Variant = _rendering_info_value("draws")
		if primitive != null: primitives.append(float(primitive))
		if draw != null: draws.append(float(draw))
	var surface_present := _runtime_surface_present()
	var primitive_stats: Dictionary = _stats(primitives)
	var draw_stats: Dictionary = _stats(draws)
	var gpu_stats: Dictionary = _stats(gpu)
	var cpu_stats: Dictionary = _stats(cpu)
	var frame_stats: Dictionary = _stats(frame)
	var primitive_median: float = float(primitive_stats.get("median", 0.0))
	var draw_median: float = float(draw_stats.get("median", 0.0))
	var case_valid := _last_state_verify_valid
	var invalid_reason := "" if case_valid else "STATE_VERIFY_MISMATCH"
	if expected_surface == 1 and (not surface_present or primitive_median <= 0.0 or draw_median <= 0.0):
		case_valid = false
		invalid_reason = "REQUIRED_OCEAN_SURFACE_MISSING_OR_ZERO_COUNTERS"
	elif expected_surface == 0 and (surface_present or primitive_median > 0.0 or draw_median > 0.0):
		case_valid = false
		invalid_reason = "ENVIRONMENT_ONLY_COUNTERS_INCLUDE_OCEAN_OR_STALE_FRAME"
	return {
		"label": label,
		"gpu": gpu_stats,
		"cpu": cpu_stats,
		"frame": frame_stats,
		"primitives": primitive_stats,
		"draws": draw_stats,
		"sample_count": frame.size(),
		"surface_present": surface_present,
		"case_valid": case_valid,
		"invalid_reason": invalid_reason,
		"timing_suspect": _timing_suspect(gpu_stats, cpu_stats, frame_stats),
	}


func _begin_timing_probe(label: String) -> void:
	_timing_probe_sample = 0
	_timing_probe_gpu_raw.clear()
	_timing_probe_cpu_raw.clear()
	_timing_probe_frame_delta.clear()
	_timing_gpu_mode = "undetermined"
	_timing_cpu_mode = "undetermined"
	_timing_mode_locked = false
	_log("TIMING PROBE BEGIN | label=%s | raw_units=milliseconds | wall_frame=separate" % label)


func _read_render_timing(frame_delta_ms: float, label: String) -> Dictionary:
	var gpu_raw: float = RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
	var cpu_raw: float = RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
	_timing_probe_sample += 1
	_timing_probe_gpu_raw.append(gpu_raw)
	_timing_probe_cpu_raw.append(cpu_raw)
	_timing_probe_frame_delta.append(frame_delta_ms)
	var gpu_samples: Array[float] = []
	var cpu_samples: Array[float] = []
	if not _timing_mode_locked and _timing_probe_sample >= TIMING_DETECTION_SAMPLES:
		_timing_gpu_mode = _detect_timing_mode(_timing_probe_gpu_raw, _timing_probe_frame_delta)
		_timing_cpu_mode = _detect_timing_mode(_timing_probe_cpu_raw, _timing_probe_frame_delta)
		_timing_mode_locked = true
		for index in range(_timing_probe_sample):
			gpu_samples.append(_timing_sample_value(_timing_probe_gpu_raw, index, _timing_gpu_mode))
			cpu_samples.append(_timing_sample_value(_timing_probe_cpu_raw, index, _timing_cpu_mode))
	elif _timing_mode_locked:
		var last_index: int = _timing_probe_sample - 1
		gpu_samples.append(_timing_sample_value(_timing_probe_gpu_raw, last_index, _timing_gpu_mode))
		cpu_samples.append(_timing_sample_value(_timing_probe_cpu_raw, last_index, _timing_cpu_mode))
	var gpu_ms: float = float(gpu_samples.back()) if not gpu_samples.is_empty() else NAN
	var cpu_ms: float = float(cpu_samples.back()) if not cpu_samples.is_empty() else NAN
	if _timing_probe_sample <= TIMING_DETECTION_SAMPLES:
		_log("TIMING RAW | label=%s | sample=%d | GPU_RAW=%s | CPU_RAW=%s | FRAME_DELTA=%s | GPU_FRAME=%s | CPU_FRAME=%s" % [label, _timing_probe_sample, _csv_value(gpu_raw), _csv_value(cpu_raw), _csv_value(frame_delta_ms), _csv_value(gpu_ms), _csv_value(cpu_ms)])
	if _timing_probe_sample == TIMING_DETECTION_SAMPLES:
		_log("TIMING MODE | label=%s | GPU=%s | CPU=%s | detection_samples=%d | mode_locked=true" % [label, _timing_gpu_mode, _timing_cpu_mode, TIMING_DETECTION_SAMPLES])
	return {"gpu_ms": gpu_ms, "cpu_ms": cpu_ms, "gpu_samples": gpu_samples, "cpu_samples": cpu_samples, "gpu_raw": gpu_raw, "cpu_raw": cpu_raw}


func _detect_timing_mode(raw_values: Array[float], frame_deltas: Array[float]) -> String:
	var valid_raw: Array[float] = []
	for value in raw_values:
		if is_finite(value) and value > 0.0: valid_raw.append(value)
	if valid_raw.size() < 5: return "raw_is_per_frame"
	var successive_deltas: Array[float] = []
	var monotonic_steps := 0
	for index in range(1, raw_values.size()):
		var previous: float = float(raw_values[index - 1])
		var current: float = float(raw_values[index])
		if is_finite(previous) and is_finite(current):
			if current >= previous: monotonic_steps += 1
			if current > previous: successive_deltas.append(current - previous)
	var valid_wall: Array[float] = []
	for value in frame_deltas:
		if is_finite(value) and value > 0.0: valid_wall.append(value)
	if successive_deltas.size() < 4 or valid_wall.size() < 4: return "raw_is_per_frame"
	valid_raw.sort()
	successive_deltas.sort()
	valid_wall.sort()
	var raw_median: float = _percentile(valid_raw, 0.50)
	var delta_median: float = _percentile(successive_deltas, 0.50)
	var wall_median: float = _percentile(valid_wall, 0.50)
	var monotonic_ratio: float = float(monotonic_steps) / float(maxi(raw_values.size() - 1, 1))
	var first_raw: float = float(valid_raw[0])
	var last_raw: float = float(valid_raw[valid_raw.size() - 1])
	var raw_growth: float = last_raw - first_raw
	var delta_to_wall: float = delta_median / wall_median if wall_median > 0.0 else INF
	var raw_to_wall: float = raw_median / wall_median if wall_median > 0.0 else INF
	if monotonic_ratio >= 0.8 and raw_growth > maxf(2.0 * wall_median, 1.0) and delta_to_wall >= 0.25 and delta_to_wall <= 4.0 and raw_to_wall >= 3.0:
		return "successive_delta_from_accumulated_raw"
	return "raw_is_per_frame"


func _timing_sample_value(raw_values: Array[float], index: int, mode: String) -> float:
	if index < 0 or index >= raw_values.size(): return NAN
	var raw: float = float(raw_values[index])
	if not is_finite(raw) or raw <= 0.0: return NAN
	if mode == "successive_delta_from_accumulated_raw":
		if index == 0: return NAN
		var previous: float = float(raw_values[index - 1])
		if not is_finite(previous): return NAN
		return maxf(raw - previous, 0.0)
	return raw


func _timing_suspect(gpu: Dictionary, cpu: Dictionary, frame: Dictionary) -> bool:
	if not bool(frame.get("available", false)) or float(frame.get("median", 0.0)) <= 0.0:
		return false
	var wall_median := float(frame["median"])
	var gpu_suspect := bool(gpu.get("available", false)) and float(gpu.get("median", 0.0)) > wall_median * TIMING_SUSPECT_RATIO
	var cpu_suspect := bool(cpu.get("available", false)) and float(cpu.get("median", 0.0)) > wall_median * TIMING_SUSPECT_RATIO
	return gpu_suspect or cpu_suspect


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
	var timing_suspect := bool(result.get("timing_suspect", false))
	var validity := "CASE_VALID" if bool(result.get("case_valid", true)) else "CASE_INVALID:%s" % result.get("invalid_reason", "UNKNOWN")
	if timing_suspect: validity += "|TIMING_SUSPECT"
	_log("%s | %s | surface_present=%s | GPU median/p95/p99/max=%s | CPU median/p95/p99/max=%s | frame median/p95/p99/max=%s | FPS=%s | primitives=%s | draws=%s" % [label, validity, result.get("surface_present", "UNKNOWN"), _stats_text(gpu), _stats_text(cpu), _stats_text(frame), _fps_text(frame), _stats_text(primitives), _stats_text(draws)])
	_csv_rows.append("%s,%s,%s,%s,%s,%s,%s,%s" % [label, validity, result.get("surface_present", "UNKNOWN"), _stats_csv(gpu), _stats_csv(cpu), _stats_csv(frame), _stats_value(primitives, "median"), _stats_value(draws, "median")])


func _log_transition_summary() -> void:
	var counts := {"ABOVE": 0, "TRANSITION": 0, "UNDERWATER": 0, "INVALID": 0}
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var frame: Array[float] = []
	var query_age_frames: Array[float] = []
	var over_16_67 := 0
	var over_20 := 0
	var over_25 := 0
	var over_33_3 := 0
	var phase_windows := {}
	for row in _transition_rows:
		var fields := row.split(",")
		var phase: String = fields[1]
		var state := fields[3]
		counts[state] = int(counts.get(state, 0)) + 1
		if not phase_windows.has(phase):
			phase_windows[phase] = {"first": float(fields[2]), "last": float(fields[2]), "frames": 0, "counts": {"ABOVE": 0, "TRANSITION": 0, "UNDERWATER": 0, "INVALID": 0}, "transition_frame_ms": 0.0}
		phase_windows[phase]["last"] = float(fields[2])
		phase_windows[phase]["frames"] += 1
		var phase_counts: Dictionary = phase_windows[phase]["counts"]
		phase_counts[state] = int(phase_counts.get(state, 0)) + 1
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
				if state == "TRANSITION": phase_windows[phase]["transition_frame_ms"] += frame_ms
		if fields.size() >= 14:
			var age := _float_or_nan(fields[13])
			if not is_nan(age) and age >= 0.0: query_age_frames.append(age)
	_log("TRANSITION | windows=U1_FAST_ENTRY+U3_FAST_EXIT+U1_SLOW_ENTRY+U3_SLOW_EXIT only | frames=%d | above=%d | transition=%d | underwater=%d | invalid=%d | GPU median/p95/p99/max=%s | CPU median/p95/p99/max=%s | frame median/p95/p99/max=%s | readback_latency_frames=%s | >16.67=%d | >20=%d | >25=%d | >33.3=%d | csv=%s" % [_transition_rows.size(), counts["ABOVE"], counts["TRANSITION"], counts["UNDERWATER"], counts["INVALID"], _stats_text(_stats(gpu)), _stats_text(_stats(cpu)), _stats_text(_stats(frame)), _stats_frames_text(_stats(query_age_frames)), over_16_67, over_20, over_25, over_33_3, TRANSITION_CSV])
	for phase in phase_windows:
		var window: Dictionary = phase_windows[phase]
		var phase_counts: Dictionary = window["counts"]
		_log("TRANSITION WINDOW | phase=%s | frames=%d | ABOVE=%d | TRANSITION=%d | UNDERWATER=%d | INVALID=%d | duration_ms=%.3f | effective_transition_frame_ms=%.3f | band_definition=+/-0.25m" % [phase, window["frames"], phase_counts["ABOVE"], phase_counts["TRANSITION"], phase_counts["UNDERWATER"], phase_counts["INVALID"], maxf(0.0, (window["last"] - window["first"]) * 1000.0), window["transition_frame_ms"]])


func _rendering_info_value(kind: String) -> Variant:
	if not RenderingServer.has_method(&"get_rendering_info"): return null
	var constant := RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME if kind == "primitives" else RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	return RenderingServer.get_rendering_info(constant)


func _stats_text(stats: Dictionary) -> String:
	if not bool(stats.get("available", false)): return "UNAVAILABLE(n=%d)" % int(stats.get("count", 0))
	return "%.3f/%.3f/%.3f/%.3f ms" % [stats["median"], stats["p95"], stats["p99"], stats["max"]]


func _stats_frames_text(stats: Dictionary) -> String:
	if not bool(stats.get("available", false)): return "UNAVAILABLE(n=%d)" % int(stats.get("count", 0))
	return "%.3f/%.3f/%.3f/%.3f frames" % [stats["median"], stats["p95"], stats["p99"], stats["max"]]


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
	if not _validate_transition_csv_schema():
		_log("TRANSITION_CSV_SCHEMA_ERROR | expected_columns=%d" % TRANSITION_COLUMN_COUNT)
	var txt := FileAccess.open(RESULT_TXT, FileAccess.WRITE)
	if txt != null:
		txt.store_string("\n".join(_text_lines) + "\n")
	var csv := FileAccess.open(RESULT_CSV, FileAccess.WRITE)
	if csv != null:
		csv.store_line("label,validity,surface_present,gpu_median,gpu_p95,gpu_p99,gpu_max,cpu_median,cpu_p95,cpu_p99,cpu_max,frame_median,frame_p95,frame_p99,frame_max,primitives_median,draws_median")
		for row in _csv_rows: csv.store_line(row)
	var transition := FileAccess.open(TRANSITION_CSV, FileAccess.WRITE)
	if transition != null:
		transition.store_line(TRANSITION_CSV_HEADER)
		for row in _transition_rows: transition.store_line(row)


func _validate_transition_csv_schema() -> bool:
	for row in _transition_rows:
		if row.split(",").size() != TRANSITION_COLUMN_COUNT:
			return false
	return true


func _fail_and_quit(reason: String) -> void:
	_log("INVALID | %s" % reason)
	_write_outputs()
	get_tree().quit(2)
