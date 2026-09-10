extends Node3D

## Reproducible performance matrix for Ocean Production.
##
## Editor:
##   Godot_v4.7.1-stable_win64_console.exe --path . --scene res://validation/ocean_benchmark.tscn -- --ocean-benchmark=matrix --ocean-resolution=1920x1080
## Standalone benchmark build:
##   "..\\Ocean Production Benchmark.exe" -- --ocean-benchmark=matrix --ocean-resolution=1920x1080
##
## The benchmark never changes production defaults. It changes only the runtime
## state of this isolated benchmark scene and writes results to user://.

const PROFILE_PATH := "res://validation/profiles/rough_validation.tres"
const COASTAL_BAKE_PATH := "res://validation/p4_paradise/coastal_bake.tres"
const ISLAND_PATH := "res://validation/testisland.glb"
const WARMUP_SECONDS := 3.0
const MEASURE_SECONDS := 5.0
const SMOKE_WARMUP_SECONDS := 0.25
const SMOKE_MEASURE_SECONDS := 0.75
const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")

var _ocean: Ocean
var _camera: Camera3D
var _sun: DirectionalLight3D
var _viewport: Viewport
var _viewport_rid: RID
var _island: Node3D
var _warmup_seconds := WARMUP_SECONDS
var _measure_seconds := MEASURE_SECONDS
var _resolution := Vector2i(1920, 1080)
var _mode := "matrix"
var _results: Array[Dictionary] = []
var _previous_result: Dictionary = {}
var _output_path := "user://benchmark_results.txt"
var _csv_output_path := "user://benchmark_results.csv"


func _ready() -> void:
	_read_arguments()
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(_resolution)
	call_deferred(&"_run")


func _read_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--ocean-benchmark="):
			_mode = argument.get_slice("=", 1).to_lower()
		elif argument.begins_with("--ocean-resolution="):
			var size_text := argument.get_slice("=", 1)
			var size_parts := size_text.split("x")
			if size_parts.size() == 2:
				_resolution = Vector2i(maxi(320, int(size_parts[0])), maxi(240, int(size_parts[1])))
		elif argument.begins_with("--ocean-output="):
			_output_path = argument.get_slice("=", 1)
			_csv_output_path = _output_path.get_basename() + ".csv"
		elif argument.begins_with("--ocean-csv="):
			_csv_output_path = argument.get_slice("=", 1)
	if _mode == "smoke":
		_warmup_seconds = SMOKE_WARMUP_SECONDS
		_measure_seconds = SMOKE_MEASURE_SECONDS
	if _mode != "matrix" and _mode != "baseline" and _mode != "geometry" and _mode != "smoke":
		_mode = "matrix"


func _run() -> void:
	_build_base_world()
	await get_tree().process_frame
	_viewport = get_viewport()
	_viewport_rid = _viewport.get_viewport_rid()
	if RenderingServer.has_method(&"viewport_set_measure_render_time"):
		RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	_print_environment()

	if _mode == "geometry":
		_ensure_ocean()
		await _run_geometry_gates()
	else:
		await _run_feature_gates()
		if _mode == "matrix" or _mode == "smoke":
			await _run_geometry_gates()

	_write_outputs()
	_shutdown_benchmark_world()
	await get_tree().process_frame
	get_tree().quit()


func _build_base_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.04, 0.10, 0.16)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.35, 0.48, 0.60)
	environment.ambient_light_energy = 0.8
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world := WorldEnvironment.new()
	world.name = &"WorldEnvironment"
	world.environment = environment
	add_child(world)

	_sun = DirectionalLight3D.new()
	_sun.name = &"Sun"
	_sun.rotation_degrees = Vector3(-42.0, -28.0, 0.0)
	_sun.light_energy = 3.0
	_sun.shadow_enabled = true
	_sun.directional_shadow_split_1 = 0.05
	_sun.directional_shadow_split_2 = 0.15
	_sun.directional_shadow_split_3 = 0.4
	_sun.directional_shadow_blend_splits = true
	_sun.directional_shadow_max_distance = 2500.0
	add_child(_sun)

	_camera = Camera3D.new()
	_camera.name = &"BenchmarkCamera"
	_camera.position = Vector3(0.0, 8.0, 16.0)
	_camera.rotation_degrees = Vector3(-12.0, 0.0, 0.0)
	_camera.current = true
	add_child(_camera)


func _ensure_ocean() -> void:
	if _ocean != null:
		return
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


func _run_feature_gates() -> void:
	print("BLOCK B FEATURE MATRIX")
	_previous_result = {}
	await _run_case("B0 FLOOR", {"mask": 0}, "Environment, camera and light only; no Ocean node.")
	_ensure_ocean()
	var cases := [
		["B1 STATIC_SURFACE", {"mask": 0}, "Ocean surface geometry with all FFT bands and optional features disabled."],
		["B2 LONG_ONLY", {"mask": CascadeState.LONG}, "Long FFT band only."],
		["B3 LONG_MID", {"mask": CascadeState.LONG | CascadeState.MID}, "Long and Mid FFT bands."],
		["B4 LONG_MID_SHORT", {"mask": CascadeState.FULL}, "All three FFT bands."],
		["B5 + COASTAL", {"mask": CascadeState.FULL, "coastal": true}, "B4 plus Coastal."],
		["B6 + CREST_FOAM", {"mask": CascadeState.FULL, "coastal": true, "crest_foam": true}, "B5 plus Crest Foam."],
		["B7 + SURFACE_FOAM", {"mask": CascadeState.FULL, "coastal": true, "crest_foam": true, "surface_foam": true}, "B6 plus Surface Foam."],
		["B8 + OPTICS", {"mask": CascadeState.FULL, "coastal": true, "crest_foam": true, "surface_foam": true, "optics": true}, "B7 plus Optics; Coastal remains enabled as its dependency."],
		["B9 + REFLECTIONS_SSPR", {"mask": CascadeState.FULL, "coastal": true, "crest_foam": true, "surface_foam": true, "optics": true, "reflections": true}, "B8 plus Ocean-owned SSPR."],
		["B10 + SURFACE_DETAIL", {"mask": CascadeState.FULL, "coastal": true, "crest_foam": true, "surface_foam": true, "optics": true, "reflections": true, "surface_detail": true}, "B9 plus Surface Detail."],
		["B11 + UNDERWATER", {"mask": CascadeState.FULL, "coastal": true, "crest_foam": true, "surface_foam": true, "optics": true, "reflections": true, "surface_detail": true, "underwater": true}, "B10 plus Underwater Medium. Camera remains above water for cumulative comparability."],
		["B12 FULL", {"mask": CascadeState.FULL, "coastal": true, "crest_foam": true, "surface_foam": true, "optics": true, "reflections": true, "surface_detail": true, "underwater": true, "sunrays": true, "bubbles": true}, "B11 plus Sunrays and Bubbles."],
	]
	for item in cases:
		await _run_case(item[0], item[1], item[2])


func _run_geometry_gates() -> void:
	print("BLOCK G GEOMETRY AND SHADOW MATRIX")
	if _ocean == null:
		_ensure_ocean()
	_apply_base_state()
	_apply_state({"mask": CascadeState.FULL})
	_previous_result = {}
	await _run_case("G0 OCEAN ONLY", {"mask": CascadeState.FULL}, "Ocean with full FFT; no island instance.")
	_ensure_island()
	_set_island_shadow(false)
	_sun.shadow_enabled = false
	await _run_case("G1 OCEAN+ISLAND SHADOWS OFF", {"mask": CascadeState.FULL, "island": true, "shadows": false}, "Ocean plus test island; island and directional shadows disabled for this gate.")
	_set_island_shadow(true)
	_sun.shadow_enabled = true
	await _run_case("G2 OCEAN+ISLAND NORMAL SHADOWS", {"mask": CascadeState.FULL, "island": true, "shadows": true}, "Ocean plus test island with normal directional and island shadow settings.")


func _run_case(label: String, state: Dictionary, notes: String) -> Dictionary:
	if _ocean != null:
		_apply_base_state()
		_apply_state(state)
	await _wait_seconds(_warmup_seconds)
	var result := await _measure()
	result["test_name"] = label
	result["resolution"] = "%dx%d" % [_resolution.x, _resolution.y]
	result["warmup_s"] = _warmup_seconds
	result["measure_s"] = _measure_seconds
	result["features"] = _feature_summary(state)
	result["fft_active_cascades"] = _active_cascade_count(int(state.get("mask", 0)))
	result["notes"] = notes
	result["delta_gpu_median_ms"] = null
	result["delta_cpu_median_ms"] = null
	if not _previous_result.is_empty():
		if bool(result.get("gpu_available", false)) and bool(_previous_result.get("gpu_available", false)):
			result["delta_gpu_median_ms"] = float(result["gpu_median_ms"]) - float(_previous_result["gpu_median_ms"])
		if bool(result.get("cpu_available", false)) and bool(_previous_result.get("cpu_available", false)):
			result["delta_cpu_median_ms"] = float(result["cpu_median_ms"]) - float(_previous_result["cpu_median_ms"])
	_results.append(result)
	_previous_result = result
	_print_result(result)
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
	_ocean.set_fft_cascade_mask(int(state.get("mask", CascadeState.FULL)))
	_ocean.optics = bool(state.get("optics", false))
	_ocean.surface_detail = bool(state.get("surface_detail", false))
	_ocean.crest_foam = bool(state.get("crest_foam", false))
	_ocean.coastal = bool(state.get("coastal", false))
	_ocean.reflections = bool(state.get("reflections", false))
	_ocean.surface_foam = bool(state.get("surface_foam", false))
	_ocean.underwater_medium = bool(state.get("underwater", false))
	_ocean.underwater_sunrays = bool(state.get("sunrays", false))
	_ocean.underwater_bubbles = bool(state.get("bubbles", false))


func _measure() -> Dictionary:
	var gpu_samples: Array[float] = []
	var cpu_samples: Array[float] = []
	var wall_samples: Array[float] = []
	var primitive_samples: Array[float] = []
	var draw_samples: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	var end_usec := previous_usec + int(_measure_seconds * 1000000.0)
	while Time.get_ticks_usec() < end_usec:
		await get_tree().process_frame
		var now_usec := Time.get_ticks_usec()
		var frame_ms := float(now_usec - previous_usec) / 1000.0
		previous_usec = now_usec
		if frame_ms > 0.0:
			wall_samples.append(1000.0 / frame_ms)
		var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		if gpu_ms > 0.0:
			gpu_samples.append(gpu_ms)
		if cpu_ms > 0.0:
			cpu_samples.append(cpu_ms)
		var primitives = _rendering_info_value("RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME")
		if primitives != null and float(primitives) >= 0.0:
			primitive_samples.append(float(primitives))
		var draws = _rendering_info_value("RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME")
		if draws != null and float(draws) >= 0.0:
			draw_samples.append(float(draws))
	var gpu_available := not gpu_samples.is_empty()
	var cpu_available := not cpu_samples.is_empty()
	var wall_median := _median(wall_samples)
	var gpu_median := _median(gpu_samples)
	var cpu_median := _median(cpu_samples)
	var derived_fps := 1000.0 / gpu_median if gpu_available and gpu_median > 0.0 else wall_median
	return {
		"gpu_available": gpu_available,
		"cpu_available": cpu_available,
		"gpu_median_ms": gpu_median if gpu_available else null,
		"cpu_median_ms": cpu_median if cpu_available else null,
		"derived_fps": derived_fps,
		"fps_source": "gpu_median" if gpu_available else "wall_frame_fallback",
		"wall_fps_median": wall_median,
		"primitive_available": not primitive_samples.is_empty(),
		"primitive_median": _median(primitive_samples) if not primitive_samples.is_empty() else null,
		"draw_calls_available": not draw_samples.is_empty(),
		"draw_calls_median": _median(draw_samples) if not draw_samples.is_empty() else null,
	}


func _print_result(result: Dictionary) -> void:
	var gpu_text := _value_text(result.get("gpu_median_ms"))
	var cpu_text := _value_text(result.get("cpu_median_ms"))
	var fps_text := _value_text(result.get("derived_fps"))
	var delta_gpu := _value_text(result.get("delta_gpu_median_ms"))
	var delta_cpu := _value_text(result.get("delta_cpu_median_ms"))
	print("BENCH | %s | GPU median=%s ms | CPU median=%s ms | FPS=%s (%s) | delta GPU=%s ms | delta CPU=%s ms | primitives=%s | draws=%s" % [result["test_name"], gpu_text, cpu_text, fps_text, result["fps_source"], delta_gpu, delta_cpu, _value_text(result.get("primitive_median")), _value_text(result.get("draw_calls_median"))])


func _print_environment() -> void:
	var window_size := DisplayServer.window_get_size()
	var viewport_size: Vector2i = _viewport.size
	var method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "Forward+"))
	var api := _rendering_server_method_value(&"get_video_adapter_api_version", "unknown")
	var gpu := _rendering_server_method_value(&"get_video_adapter_name", "unknown")
	var vendor := _rendering_server_method_value(&"get_video_adapter_vendor", "unknown")
	print("BENCH ENV | platform=%s | gpu=%s | vendor=%s | api=%s | driver=%s | renderer=%s" % [OS.get_name(), gpu, vendor, api, _platform_driver_setting(), method])
	print("BENCH ENV | requested=%dx%d | window=%s | viewport=%s | warmup=%.2fs | measure=%.2fs | dynamic_resolution=OFF | upscaler=OFF" % [_resolution.x, _resolution.y, window_size, viewport_size, _warmup_seconds, _measure_seconds])
	print("BENCH ENV | primitive/draw counters=%s" % ("available" if _rendering_info_value("RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME") != null else "UNAVAILABLE"))


func _ensure_island() -> void:
	if _island != null:
		return
	var island_scene := load(ISLAND_PATH) as PackedScene
	if island_scene == null:
		print("GEOMETRY | test island unavailable: %s" % ISLAND_PATH)
		return
	_island = island_scene.instantiate()
	_island.name = &"testisland"
	_island.position = Vector3(-445.245, 400.0, -25.284)
	add_child(_island)


func _set_island_shadow(enabled: bool) -> void:
	if _island == null:
		return
	_set_shadow_recursive(_island, enabled)


func _set_shadow_recursive(node: Node, enabled: bool) -> void:
	if node is GeometryInstance3D:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for child in node.get_children():
		_set_shadow_recursive(child, enabled)


func _rendering_info_value(constant_name: String) -> Variant:
	if not RenderingServer.has_method(&"get_rendering_info"):
		return null
	var constant := -1
	if constant_name == "RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME":
		constant = RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
	elif constant_name == "RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME":
		constant = RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
	else:
		return null
	return RenderingServer.get_rendering_info(constant)


func _rendering_server_method_value(method: StringName, fallback: String) -> String:
	if RenderingServer.has_method(method):
		return str(RenderingServer.call(method))
	return fallback


func _platform_driver_setting() -> String:
	var key := ""
	match OS.get_name():
		"Windows": key = "rendering/rendering_device/driver.windows"
		"Linux": key = "rendering/rendering_device/driver.linuxbsd"
		"macOS": key = "rendering/rendering_device/driver.macos"
		_:
			return "unknown"
	if not ProjectSettings.has_setting(key):
		return "unknown"
	var value := str(ProjectSettings.get_setting(key))
	return value if not value.is_empty() else "unknown"


func _feature_summary(state: Dictionary) -> String:
	var parts: Array[String] = []
	var mask := int(state.get("mask", 0))
	if mask == 0:
		parts.append("FFT_OFF")
	else:
		if mask & CascadeState.LONG: parts.append("LONG")
		if mask & CascadeState.MID: parts.append("MID")
		if mask & CascadeState.SHORT: parts.append("SHORT")
	for key in ["coastal", "crest_foam", "surface_foam", "optics", "reflections", "surface_detail", "underwater", "sunrays", "bubbles", "island", "shadows"]:
		if bool(state.get(key, false)): parts.append(key.to_upper())
	return "+".join(parts)


func _active_cascade_count(mask: int) -> int:
	var count := 0
	if mask & CascadeState.LONG: count += 1
	if mask & CascadeState.MID: count += 1
	if mask & CascadeState.SHORT: count += 1
	return count


func _write_outputs() -> void:
	var text_file := FileAccess.open(_output_path, FileAccess.WRITE)
	if text_file != null:
		text_file.store_line("Ocean Production PERF CHECKPOINT 1B")
		text_file.store_line("resolution=%dx%d | warmup=%.2fs | measure=%.2fs | dynamic_resolution=OFF | upscaler=OFF" % [_resolution.x, _resolution.y, _warmup_seconds, _measure_seconds])
		text_file.store_line("GPU median/CPU median are unavailable when Godot does not expose measured render time; derived FPS then uses wall-frame median.")
		text_file.store_line("")
		for result in _results:
			text_file.store_line("%s | GPU=%s ms | CPU=%s ms | FPS=%s [%s] | dGPU=%s ms | dCPU=%s ms | primitives=%s | draws=%s | FFT=%s | features=%s | %s" % [result["test_name"], _value_text(result.get("gpu_median_ms")), _value_text(result.get("cpu_median_ms")), _value_text(result.get("derived_fps")), result["fps_source"], _value_text(result.get("delta_gpu_median_ms")), _value_text(result.get("delta_cpu_median_ms")), _value_text(result.get("primitive_median")), _value_text(result.get("draw_calls_median")), result["fft_active_cascades"], result["features"], result["notes"]])
		text_file.close()
	var csv_file := FileAccess.open(_csv_output_path, FileAccess.WRITE)
	if csv_file != null:
		csv_file.store_line("test_name,resolution,warmup_s,measure_s,gpu_median_ms,cpu_median_ms,derived_fps,fps_source,wall_fps_median,primitive_median,draw_calls_median,gpu_available,cpu_available,primitive_available,draw_calls_available,fft_active_cascades,features,delta_gpu_median_ms,delta_cpu_median_ms,notes")
		for result in _results:
			var row: Array[Variant] = [result["test_name"], result["resolution"], result["warmup_s"], result["measure_s"], result.get("gpu_median_ms"), result.get("cpu_median_ms"), result.get("derived_fps"), result.get("fps_source"), result.get("wall_fps_median"), result.get("primitive_median"), result.get("draw_calls_median"), result.get("gpu_available"), result.get("cpu_available"), result.get("primitive_available"), result.get("draw_calls_available"), result["fft_active_cascades"], result["features"], result.get("delta_gpu_median_ms"), result.get("delta_cpu_median_ms"), result["notes"]]
			csv_file.store_line(",".join(row.map(func(value): return _csv_value(value))))
		csv_file.close()
	print("RESULTS | txt=%s | csv=%s" % [ProjectSettings.globalize_path(_output_path), ProjectSettings.globalize_path(_csv_output_path)])


func _csv_value(value: Variant) -> String:
	if value == null:
		return "UNAVAILABLE"
	var text := str(value)
	if text.contains(",") or text.contains("\""):
		return "\"" + text.replace("\"", "\"\"") + "\""
	return text


func _value_text(value: Variant) -> String:
	if value == null:
		return "UNAVAILABLE"
	if value is float or value is int:
		return "%.3f" % float(value)
	return str(value)


func _shutdown_benchmark_world() -> void:
	if _ocean != null:
		_ocean.enabled = false


func _wait_seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) * 0.5
