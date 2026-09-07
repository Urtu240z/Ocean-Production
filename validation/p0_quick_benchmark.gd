extends SceneTree

## Temporal graphical benchmark for validation/p0_open_ocean.tscn.
## Delete this file after a manual run; it does not change the scene on disk.

const SCENE_PATH := "res://validation/p0_open_ocean.tscn"
const WARMUP_S := 3.0
const MEASURE_S := 5.0

var _scene: Node
var _ocean: Node
var _camera: Camera3D
var _viewport_rid: RID
var _surface_transform: Transform3D
var _bubble_profile: Resource
var _sunray_profile: Resource


func _initialize() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	_scene = load(SCENE_PATH).instantiate()
	root.add_child(_scene)
	await process_frame
	_ocean = _scene.get_node("Ocean")
	_camera = _scene.get_node("FreeCamera") as Camera3D
	_surface_transform = _camera.transform
	_bubble_profile = _ocean.underwater_bubble_profile
	_sunray_profile = _ocean.underwater_sunray_profile
	_viewport_rid = root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	var viewport_size: Vector2i = root.get_viewport().size
	print("BENCH CONFIG | scene=validation/p0_open_ocean.tscn | resolution=%dx%d | warmup=%.1fs | measure=%.1fs" % [viewport_size.x, viewport_size.y, WARMUP_S, MEASURE_S])
	print("BENCH PROFILE | bubble_macro=%.2f | bubble_micro=%.2f | shadow=%.2f | shadow_steps=%d | sunray_strength=%.2f" % [_bubble_profile.macro_erosion_strength, _bubble_profile.micro_detail_strength, _bubble_profile.shadow_strength, _bubble_profile.shadow_steps, _sunray_profile.strength])

	await _run_underwater_block()
	await _run_surface_block()
	print("BENCH COMPLETE | GPU timing must be non-zero for a valid table")
	quit()


func _run_underwater_block() -> void:
	_set_underwater_camera()
	print("BENCH BLOCK | A underwater | camera=(%.2f, %.2f, %.2f)" % [_camera.position.x, _camera.position.y, _camera.position.z])
	var results: Dictionary = {}
	results["A0 P6_BASE"] = await _measure("A0 P6_BASE", _apply_underwater.bind(false, false, false, false))
	results["A1 BUBBLE_BASE"] = await _measure("A1 BUBBLE_BASE", _apply_underwater.bind(true, false, false, false))
	results["A2 BUBBLE_NOISE"] = await _measure("A2 BUBBLE_NOISE", _apply_underwater.bind(true, true, false, false))
	results["A3 BUBBLE_FULL"] = await _measure("A3 BUBBLE_FULL", _apply_underwater.bind(true, true, true, false))
	results["A4 SUNRAYS_ONLY"] = await _measure("A4 SUNRAYS_ONLY", _apply_underwater.bind(false, false, false, true))
	results["A5 FULL_UNDERWATER"] = await _measure("A5 FULL_UNDERWATER", _apply_underwater.bind(true, true, true, true))
	_print_underwater_deltas(results)


func _run_surface_block() -> void:
	_camera.transform = _surface_transform
	print("BENCH BLOCK | B surface | camera=(%.2f, %.2f, %.2f)" % [_camera.position.x, _camera.position.y, _camera.position.z])
	var results: Dictionary = {}
	results["B0 FULL"] = await _measure("B0 FULL", _apply_surface.bind(""))
	results["B1 CREST_FOAM_OFF"] = await _measure("B1 CREST_FOAM_OFF", _apply_surface.bind("crest"))
	results["B2 SURFACE_FOAM_OFF"] = await _measure("B2 SURFACE_FOAM_OFF", _apply_surface.bind("surface_foam"))
	results["B3 OPTICS_OFF"] = await _measure("B3 OPTICS_OFF", _apply_surface.bind("optics"))
	results["B4 REFLECTIONS_OFF"] = await _measure("B4 REFLECTIONS_OFF", _apply_surface.bind("reflections"))
	results["B5 SURFACE_DETAIL_OFF"] = await _measure("B5 SURFACE_DETAIL_OFF", _apply_surface.bind("surface_detail"))
	if bool(_ocean.coastal):
		results["B6 COASTAL_OFF"] = await _measure("B6 COASTAL_OFF", _apply_surface.bind("coastal"))
	else:
		print("BENCH | B6 COASTAL_OFF | SKIP | scene already has Coastal OFF")
	print("BENCH NOTE | FFT/CORE omitted | existing gate is input-driven and no new architecture was added")


func _apply_underwater(bubbles: bool, noise: bool, shadow: bool, sunrays: bool) -> void:
	_camera.transform = _underwater_transform()
	var profile: Resource = _bubble_profile.duplicate(true)
	if bubbles and not noise:
		profile.macro_erosion_strength = 0.0
		profile.micro_detail_strength = 0.0
	if bubbles and not shadow:
		profile.shadow_strength = 0.0
	_ocean.underwater_bubble_profile = profile
	_ocean.underwater_medium = true
	_ocean.underwater_bubbles = bubbles
	_ocean.underwater_sunrays = sunrays


func _apply_surface(off_gate: String) -> void:
	_camera.transform = _surface_transform
	_ocean.crest_foam = off_gate != "crest"
	_ocean.surface_foam = off_gate != "surface_foam"
	_ocean.optics = off_gate != "optics"
	_ocean.reflections = off_gate != "reflections"
	_ocean.surface_detail = off_gate != "surface_detail"
	_ocean.coastal = off_gate != "coastal"
	# Keep the current underwater configuration constant across surface gates.
	_ocean.underwater_medium = true
	_ocean.underwater_bubbles = true
	_ocean.underwater_sunrays = true


func _set_underwater_camera() -> void:
	_camera.transform = _underwater_transform()


func _underwater_transform() -> Transform3D:
	var transform := _surface_transform
	transform.origin = Vector3(0.0, -2.0, 16.0)
	transform.basis = Basis.from_euler(Vector3(0.20, 0.0, 0.0))
	return transform


func _measure(label: String, apply_case: Callable) -> Dictionary:
	apply_case.call()
	await _wait_seconds(WARMUP_S)
	var gpu_samples: Array[float] = []
	var cpu_sum := 0.0
	var fps_sum := 0.0
	var frame_samples := 0
	var previous_usec := Time.get_ticks_usec()
	var end_usec := previous_usec + int(MEASURE_S * 1000000.0)
	while Time.get_ticks_usec() < end_usec:
		await process_frame
		var now_usec := Time.get_ticks_usec()
		var frame_delta_ms := float(now_usec - previous_usec) / 1000.0
		previous_usec = now_usec
		if frame_delta_ms > 0.0:
			fps_sum += 1000.0 / frame_delta_ms
		var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		if gpu_ms > 0.0:
			gpu_samples.append(gpu_ms)
		if cpu_ms > 0.0:
			cpu_sum += cpu_ms
		frame_samples += 1
	var result := {
		"gpu": _average(gpu_samples),
		"median_gpu": _median(gpu_samples),
		"cpu": cpu_sum / maxf(float(frame_samples), 1.0),
		"fps": fps_sum / maxf(float(frame_samples), 1.0),
		"gpu_valid": not gpu_samples.is_empty()
	}
	var gpu_text := "%.3f" % result.gpu if result.gpu_valid else "NA"
	print("BENCH | %s | GPU=%s ms | CPU=%.3f ms | FPS=%.1f | medianGPU=%s" % [label, gpu_text, result.cpu, result.fps, ("%.3f" % result.median_gpu) if result.gpu_valid else "NA"])
	return result


func _print_underwater_deltas(results: Dictionary) -> void:
	var base: Dictionary = results["A0 P6_BASE"]
	var a1: Dictionary = results["A1 BUBBLE_BASE"]
	var a2: Dictionary = results["A2 BUBBLE_NOISE"]
	var a3: Dictionary = results["A3 BUBBLE_FULL"]
	var a4: Dictionary = results["A4 SUNRAYS_ONLY"]
	var a5: Dictionary = results["A5 FULL_UNDERWATER"]
	if not base.gpu_valid or not a1.gpu_valid or not a2.gpu_valid or not a3.gpu_valid or not a4.gpu_valid or not a5.gpu_valid:
		print("BENCH DELTAS | GPU=NA | RenderingServer GPU timing unavailable")
		return
	print("BENCH DELTAS | noise=%.3f ms | shadow=%.3f ms | sunrays=%.3f ms | bubble_full=%.3f ms | full_combined=%.3f ms" % [a2.gpu - a1.gpu, a3.gpu - a2.gpu, a4.gpu - base.gpu, a3.gpu - base.gpu, a5.gpu - base.gpu])


func _wait_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout


func _average(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _median(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var middle := sorted.size() / 2
	if sorted.size() % 2 == 1:
		return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) * 0.5
