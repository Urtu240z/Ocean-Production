extends SceneTree
## Real vehicles/physics/FX, storm waves, moving chase camera. Render GPU is the
## SUM of measured active viewports, not root-only and not a claim of total GPU.
const VEHICLE := preload("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn")
var scene: Node3D
var ocean: Ocean
var camera: Camera3D
var profile: OceanReflectionProfile
var vehicles: Array[JetSkiController] = []
var rows: Array[Dictionary] = []
var samples := 120
var warmup := 60
var rounds := 2
var phase := 0.0
var output := "res://validation/reports/planar_benchmark_2026_10_18.json"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--samples="): samples = maxi(20, int(arg.get_slice("=", 1)))
		if arg.begins_with("--warmup="): warmup = maxi(10, int(arg.get_slice("=", 1)))
		if arg.begins_with("--rounds="): rounds = maxi(1, int(arg.get_slice("=", 1)))
		if arg.begins_with("--result="): output = arg.get_slice("=", 1)
	call_deferred(&"run")

func percentile(values: Array, fraction := 0.5) -> float:
	if values.is_empty(): return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[int((sorted.size() - 1) * fraction)])

func stats(values: Array) -> Dictionary:
	return {"p50": percentile(values), "p95": percentile(values, 0.95), "samples": values.size()}

func normalize(raw: Array, wall: Array) -> Dictionary:
	var differences: Array[float] = []
	var positive := 0
	for index in range(1, raw.size()):
		if float(raw[index]) >= float(raw[index - 1]): positive += 1
		differences.append(maxf(0.0, float(raw[index]) - float(raw[index - 1])))
	var accumulated: bool = positive > raw.size() * 0.8 and not raw.is_empty() and float(raw.back()) - float(raw.front()) > maxf(1.0, 2.0 * percentile(wall)) and percentile(raw) > 3.0 * percentile(wall)
	return {"mode": "successive_delta" if accumulated else "per_frame", "values": differences if accumulated else raw}

func move_camera() -> void:
	phase += 1.0 / 60.0
	var focus := vehicles[0].global_position
	camera.global_position = focus + Vector3(sin(phase * 0.7) * 5.0, 7.0 + sin(phase) * 0.6, 14.0)
	camera.look_at(focus + Vector3(0, 0.5, -12.0), Vector3.UP)
	camera.current = true

func render_frame() -> void:
	move_camera()
	await process_frame
	await RenderingServer.frame_post_draw

func spawn(count: int) -> void:
	for ski in vehicles: ski.queue_free()
	vehicles.clear()
	await process_frame
	for index in count:
		var ski := VEHICLE.instantiate() as JetSkiController
		ski.name = "BenchmarkJet%d" % index
		ski.configure_ocean(ocean)
		ski.freeze = true
		ski.collision_layer = 0
		ski.collision_mask = 0
		ski.position = Vector3((float(index) - (count - 1) * 0.5) * 7.0, 1.5, 0)
		scene.add_child(ski)
		ski.get_node("CameraRig").process_mode = Node.PROCESS_MODE_DISABLED
		ski.get_node("WaterContactFx").call("configure_ocean", ocean)
		vehicles.append(ski)
	for frame in 30: await render_frame()
	for ski in vehicles: ski.freeze = false

func measure(count: int, mode: int, scale: float, repeat_index: int) -> void:
	profile.reflection_mode = mode as OceanReflectionProfile.ReflectionMode
	profile.planar_resolution_scale = scale
	phase = 0.0
	for index in vehicles.size():
		var ski := vehicles[index]
		ski.position = Vector3((float(index) - (count - 1) * 0.5) * 7.0, 1.5, 0)
		ski.rotation = Vector3.ZERO
		ski.linear_velocity = Vector3(0, 0, -18)
		ski.angular_velocity = Vector3.ZERO
		ski.reset_physics_interpolation()
	for frame in warmup: await render_frame()
	var owner := ocean.get_node(^"OpenOceanFFT/OceanSSPR")
	var planar: Node = owner.get("_planar")
	var capture: SubViewport = planar.get("_viewport") if planar != null else null
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	if capture != null: RenderingServer.viewport_set_measure_render_time(capture.get_viewport_rid(), true)
	var main_raw: Array[float] = []
	var capture_raw: Array[float] = []
	var wall: Array[float] = []
	var cpu: Array[float] = []
	var speed: Array[float] = []
	var before := Time.get_ticks_usec()
	for frame in samples:
		await render_frame()
		var now := Time.get_ticks_usec()
		wall.append(float(now - before) / 1000.0)
		before = now
		main_raw.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		capture_raw.append(RenderingServer.viewport_get_measured_render_time_gpu(capture.get_viewport_rid()) if mode == 1 and capture != null else 0.0)
		cpu.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		speed.append(vehicles[0].linear_velocity.length())
	var main := normalize(main_raw, wall)
	var secondary := normalize(capture_raw, wall)
	var combined: Array[float] = []
	for index in mini(main.values.size(), secondary.values.size()):
		combined.append(float(main.values[index]) + float(secondary.values[index]))
	var row := {"vehicles": count, "method": "SSPR" if mode == 0 else "PLANAR", "scale": profile.sspr_resolution_scale if mode == 0 else scale, "round": repeat_index,
		"wall_ms": stats(wall), "process_ms": stats(cpu), "main_render_gpu_ms": stats(main.values), "capture_render_gpu_ms": stats(secondary.values), "summed_render_gpu_ms": stats(combined),
		"main_timing_mode": main.mode, "capture_timing_mode": secondary.mode, "speed_mps": stats(speed), "capture_state": planar.get_state() if planar != null else {},
		"raw": {"main_gpu": main_raw, "capture_gpu": capture_raw, "wall": wall}}
	rows.append(row)
	print("REFLECTION_BENCH_ROW ", JSON.stringify(row).substr(0, JSON.stringify(row).find('"raw"')))
	write_report()

func write_report() -> void:
	var report := {"godot": Engine.get_version_info(), "gpu": RenderingServer.get_video_adapter_name(), "backend": RenderingServer.get_video_adapter_api_version(), "resolution": root.size,
		"scope": "Live production jet skis with shared CPU physics and FX, 3m storm waves, moving camera. No collisions or AI. P0 island retained; not a complete race. Summed per-viewport GPU excludes unscoped global compute; wall time includes the full application. Kawase disabled for equivalent method cost.",
		"wave_height_scale": ocean.wave_height_scale, "crest_foam": ocean.crest_foam, "surface_foam": ocean.surface_foam, "distortion": profile.distortion_strength, "rows": rows}
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var file := FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))

func run() -> void:
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	for action in [&"throttle", &"brake", &"steer_right", &"steer_left"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	scene = load("res://validation/p0_open_ocean.tscn").instantiate()
	ocean = scene.get_node(^"Ocean")
	ocean.coastal = false
	ocean.sea_state_mode = 1
	ocean.significant_wave_height_m = 3.0
	ocean.wind_speed_mps = 18.0
	profile = OceanReflectionProfile.new()
	profile.sspr_resolution_scale = 0.5
	profile.planar_resolution_scale = 0.5
	profile.kawase_enabled = false
	ocean.reflections = true
	ocean.reflection_profile = profile
	root.add_child(scene)
	for path in [^"OceanDevPanel", ^"FFTCascadeGate", ^"FreeCamera"]:
		var node := scene.get_node_or_null(path)
		if node != null: node.queue_free()
	camera = Camera3D.new()
	scene.add_child(camera)
	for frame in 25: await process_frame
	var provider := ocean.get_water_provider()
	provider.set("lite_resolutions", PackedInt32Array([128, 128, 128]))
	provider.set("lite_interpolation_modes", PackedInt32Array([1, 1, 1]))
	provider.call("configure", ocean, 1, false)
	provider.call("set_query_mode", 0)
	provider.call("set_water_race_mode", true)
	Input.action_press(&"throttle", 0.8)
	for count in [1, 4, 6]:
		await spawn(count)
		for repeat_index in rounds:
			var cases := [[0, 0.5], [1, 0.5], [1, 0.35]]
			if repeat_index % 2 == 1: cases.reverse()
			for case in cases: await measure(count, int(case[0]), float(case[1]), repeat_index)
	Input.action_release(&"throttle")
	print("REFLECTION_BENCH_PASS rows=", rows.size(), " report=", output)
	scene.queue_free()
	for frame in 4: await process_frame
	quit()
