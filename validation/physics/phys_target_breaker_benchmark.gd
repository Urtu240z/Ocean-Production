extends SceneTree
## Controlled target-hardware B0/B1/B2 breaker benchmark on the P0 scene.

const SCENE := preload("res://validation/p0_open_ocean.tscn")
const WARMUP_S := 5.0
const SAMPLE_S := 10.0
const REPEATS := 3

var _scene: Node
var _ocean: Node
var _viewport_rid: RID


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_scene = SCENE.instantiate()
	root.add_child(_scene)
	await process_frame
	if root.get_viewport().size != Vector2i(1920, 1080):
		_fail("Expected 1920x1080 viewport; got %s" % root.get_viewport().size)
		return
	_ocean = _scene.get_node_or_null("Ocean")
	if _ocean == null:
		_fail("P0 scene has no Ocean node.")
		return
	_viewport_rid = root.get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	var camera := _scene.get_node_or_null("FreeCamera") as Camera3D
	if camera != null:
		camera.set_process(false)
		camera.set_process_input(false)
		camera.set_process_unhandled_input(false)
	print("TARGET_BREAKER_ENV " + JSON.stringify({
		"scene": "validation/p0_open_ocean.tscn",
		"viewport": "%dx%d" % [root.get_viewport().size.x, root.get_viewport().size.y],
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"),
		"driver": ProjectSettings.get_setting("rendering/rendering_device/driver.windows", "unknown"),
		"debug_build": OS.is_debug_build(),
		"cpu": OS.get_processor_name(),
		"gpu": RenderingServer.get_video_adapter_name(),
		"vsync": DisplayServer.window_get_vsync_mode(),
		"max_fps": Engine.max_fps,
		"warmup_s": WARMUP_S,
		"sample_s": SAMPLE_S,
		"repeats": REPEATS,
		"camera_transform": str(camera.global_transform) if camera != null else "missing",
	}))
	for state in ["B0", "B1", "B2"]:
		for repeat_index in REPEATS:
			await _apply_state(state)
			await _wait_seconds(0.25)
			await _measure("%s_R%d" % [state, repeat_index + 1])
	print("TARGET_BREAKER_COMPLETE")
	_scene.queue_free()
	quit(0)


func _apply_state(state: String) -> void:
	_ocean.set("breakers", state != "B0")
	await process_frame
	if state == "B1":
		var open_ocean: Object = _ocean.get("_open_ocean")
		var surface: Object = open_ocean.get("_surface") if open_ocean != null else null
		if surface != null:
			surface.call("set_breakers", false, _ocean.get("breaker_profile"))
	await _wait_seconds(1.0)
	print("TARGET_BREAKER_STATE " + JSON.stringify({
		"state": state,
		"breaker_enabled": _ocean.get("breakers"),
		"surface_route": state == "B2",
		"wave_time": _ocean.call("get_wave_time"),
	}))


func _measure(label: String) -> void:
	await _wait_seconds(WARMUP_S)
	var gpu: Array[float] = []
	var cpu: Array[float] = []
	var frame: Array[float] = []
	var previous_usec := Time.get_ticks_usec()
	var finish_usec := previous_usec + int(SAMPLE_S * 1_000_000.0)
	while Time.get_ticks_usec() < finish_usec:
		await process_frame
		var now_usec := Time.get_ticks_usec()
		frame.append(float(now_usec - previous_usec) / 1000.0)
		previous_usec = now_usec
		var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid)
		if gpu_ms > 0.0:
			gpu.append(float(gpu_ms))
		if cpu_ms > 0.0:
			cpu.append(float(cpu_ms))
	print("TARGET_BREAKER_SAMPLE " + JSON.stringify({
		"label": label,
		"frames": frame.size(),
		"gpu_mean_ms": _mean(gpu),
		"gpu_p95_ms": _percentile(gpu, 0.95),
		"cpu_mean_ms": _mean(cpu),
		"cpu_p95_ms": _percentile(cpu, 0.95),
		"frame_mean_ms": _mean(frame),
		"frame_p95_ms": _percentile(frame, 0.95),
	}))


func _wait_seconds(duration_s: float) -> void:
	var finish_usec := Time.get_ticks_usec() + int(duration_s * 1_000_000.0)
	while Time.get_ticks_usec() < finish_usec:
		await process_frame


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _percentile(values: Array[float], percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array = values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil((sorted.size() - 1) * clampf(percentile, 0.0, 1.0))), 0, sorted.size() - 1)
	return float(sorted[index])


func _fail(message: String) -> void:
	printerr("TARGET_BREAKER_FAIL=" + message)
	quit(1)
