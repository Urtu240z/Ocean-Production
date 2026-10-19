extends SceneTree
## Run one process, sequential cases. Production resources are never saved.
const AreaScene = preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
const BoatScene = preload("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn")
var world: Node3D
var ocean: Node3D
var camera: Camera3D
var boats: Array = []
var areas: Array = []
var runtime: RefCounted
var measured := false
var frame_rows: Array = []
var render_rows: Array = []
var last_frame_us := 0
var path_tick := 0
var path_origin := Vector3.ZERO
var report: Dictionary = {}
var timestamp_debug: Dictionary = {}
var gpu_rows: Array = []
var _captured_frame := -1
signal render_barrier

func _initialize() -> void:
	Engine.max_fps = 0
	call_deferred("run")

func option(key: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(key+"="): return arg.substr(key.length()+1)
	return fallback

func distribution(values: Array) -> Dictionary:
	if values.is_empty(): return {"n":0}
	var sorted := values.duplicate()
	sorted.sort()
	return {"n":sorted.size(),"p50":sorted[int((sorted.size()-1)*0.5)],"p95":sorted[int((sorted.size()-1)*0.95)]}

func metric_summary(buckets: Dictionary, first: int, last: int) -> Dictionary:
	var keys: Dictionary = {}
	for index in buckets:
		if int(index) < first or int(index) >= last: continue
		for metric in buckets[index]: keys[metric] = true
	var result := {}
	for metric in keys:
		var calls: Array = []
		var times: Array = []
		for index in range(first,last):
			var value: Vector2i = buckets.get(index,{}).get(metric,Vector2i.ZERO)
			calls.append(value.x)
			times.append(value.y/1000.0)
		result[metric] = {"count":distribution(calls),"inclusive_ms":distribution(times)}
	return result

func trajectory() -> void:
	path_tick += 1
	# Fixed 60 Hz, same spatial path in every case. Bodies still run production forces/queries.
	var t := path_tick/float(Engine.physics_ticks_per_second)
	for i in boats.size():
		var boat: RigidBody3D = boats[i]
		boat.global_transform = Transform3D(Basis.IDENTITY,path_origin+Vector3((i%3-1)*4.0,0.25,-8.0+4.0*sin(t*0.4)+int(i/3)*6.0))
		boat.linear_velocity = Vector3(0,0,1.6*cos(t*0.4))
		boat.angular_velocity = Vector3.ZERO
		boat.sleeping = false

func frame() -> void:
	var now := Time.get_ticks_usec()
	if measured and last_frame_us > 0:
		frame_rows.append([Engine.get_process_frames(),Engine.get_physics_frames(),
			(now-last_frame_us)/1000.0,
			Performance.get_monitor(Performance.TIME_PROCESS)*1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0])
		RenderingServer.call_on_render_thread(read_render.bind(Engine.get_process_frames()))
	last_frame_us = now

func read_render(index: int) -> void:
	var viewport := root.get_viewport_rid()
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(viewport)
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(viewport)
	var rd := RenderingServer.get_rendering_device()
	var captured := rd.get_captured_timestamps_frame()
	var durations: Array = []
	if captured != _captured_frame:
		_captured_frame = captured
		var starts := {}
		for i in rd.get_captured_timestamps_count():
			var label := rd.get_captured_timestamp_name(i)
			if not label.begins_with("Ocean.LocalFFT."): continue
			if label.ends_with(".begin"): starts[label.trim_suffix(".begin")] = rd.get_captured_timestamp_gpu_time(i)
			elif label.ends_with(".end"):
				var prefix := label.trim_suffix(".end")
				if starts.has(prefix):
					durations.append([int(prefix.get_slice(".",3)),float(rd.get_captured_timestamp_gpu_time(i)-starts[prefix])/1000.0])
	store_render.call_deferred(index,cpu,gpu,durations)

func store_render(index: int, cpu: float, gpu: float, durations: Array) -> void:
	render_rows.append([index,cpu,gpu])
	for duration in durations: gpu_rows.append(duration)

func flush_render() -> void:
	var rd := RenderingServer.get_rendering_device()
	var names: Array = []
	for i in rd.get_captured_timestamps_count(): names.append(rd.get_captured_timestamp_name(i))
	timestamp_debug = {"frame":rd.get_captured_timestamps_frame(),"labels":names}
	emit_barrier.call_deferred()

func emit_barrier() -> void: render_barrier.emit()

func wait_ticks(count: int, minimum_frames := 0) -> void:
	var end := Engine.get_physics_frames()+count
	var end_frame := Engine.get_process_frames()+minimum_frames
	while Engine.get_physics_frames() < end or Engine.get_process_frames() < end_frame: await process_frame

func run() -> void:
	preload("res://addons/jet_ski/resources/default_input_bindings.tres").install_missing_actions()
	root.size = Vector2i(1280,720)
	DisplayServer.window_set_size(root.size)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	world = Node3D.new()
	root.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.22,0.32,0.44)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.6
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40,-30,0)
	world.add_child(sun)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0,6,16)
	camera.look_at(Vector3(0,0,-8))
	camera.current = true
	ocean = load("res://addons/ocean/ocean.tscn").instantiate()
	if option("--diagnostic","false") == "true":
		var diagnostic := preload("res://validation/fixtures/local_sea_diagnostic_runtime.gd").new()
		diagnostic.local_render = option("--local-render","on") == "on"
		diagnostic.local_physics = option("--local-physics","on") == "on"
		ocean._wave_area_runtime = diagnostic
	# Component fixture: identical exterior FFT; expensive unrelated systems held off.
	for property in ["coastal","reflections","enable_spindrift","underwater_bubbles","underwater_sunrays","underwater_medium"]:
		ocean.set(property,false)
	world.add_child(ocean)
	ocean.visible = option("--water","on") == "on"
	for i in 2:
		var area = AreaScene.instantiate()
		area.ocean = ocean
		area.enabled = false
		area.name = "AuditArea%d"%i
		world.add_child(area)
		areas.append(area)
	for i in 120: await process_frame
	runtime = ocean.get_wave_area_runtime()
	runtime.profiling_enabled = true
	physics_frame.connect(trajectory)
	process_frame.connect(frame)
	report = {"base":"234c1f4917","phase":option("--phase","phase1"),
		"local_render":option("--local-render","on"),"local_physics":option("--local-physics","on"),
		"gpu":RenderingServer.get_video_adapter_name(),"cpu":OS.get_processor_name(),
		"driver":RenderingServer.get_current_rendering_driver_name(),"engine":Engine.get_version_info().string,
		"resolution":[1280,720],"physics_hz":Engine.physics_ticks_per_second,
		"warmup_ticks":int(option("--warmup","180")),"measured_ticks":int(option("--ticks","300")),
		"notes":["Inclusive timers must not be added together.","TIME_PROCESS and TIME_PHYSICS_PROCESS are distinct engine monitors.",
		"Viewport GPU is total water scene incl boats; no claim of isolated water draw time.",
		"Real boats are moved onto a fixed path before each step; production force/query code is unchanged.",
		"Metric capture is opt-in. Per-frame monitors can repeat the latest physics tick."],"cases":[]}
	var selected := option("--case","all")
	var counts := [0,1,4,6]
	var scenarios := ["none","one_outside","one_inside","two_same","two_separate"]
	if option("--reverse","false") == "true":
		counts.reverse()
		scenarios.reverse()
	for count in counts:
		if count == 0 and option("--boats","all") != "0": continue
		if option("--boats","all") != "all" and int(option("--boats","all")) != count: continue
		for boat in boats: boat.queue_free()
		boats.clear()
		await process_frame
		for i in count:
			var boat = BoatScene.instantiate()
			boat.name = "AuditBoat%d"%i
			boat.ocean = ocean
			boat.can_sleep = false
			world.add_child(boat)
			boat.get_node("CameraRig").process_mode = Node.PROCESS_MODE_DISABLED
			boat.get_node("CameraRig/Camera3D").current = false
			boats.append(boat)
		camera.current = true
		for scenario in scenarios:
			if selected != "all" and selected != scenario: continue
			for i in 2:
				areas[i].enabled = scenario != "none" and (i == 0 or scenario.begins_with("two"))
				areas[i].sea_state = i if scenario == "two_separate" else 0
				areas[i].position = Vector3(0,0,-8) if scenario != "one_outside" else Vector3(1000,0,0)
			path_tick = 0
			await wait_ticks(report.warmup_ticks)
			runtime.metrics.clear()
			frame_rows.clear()
			render_rows.clear()
			gpu_rows.clear()
			var first_tick := Engine.get_physics_frames()+1
			var first_frame := Engine.get_process_frames()+1
			path_tick = 0
			runtime.metrics.enabled = true
			measured = true
			await wait_ticks(report.measured_ticks,int(option("--minframes","240")))
			measured = false
			runtime.metrics.enabled = false
			var last_tick := Engine.get_physics_frames()
			var last_frame := Engine.get_process_frames()
			RenderingServer.call_on_render_thread(flush_render)
			await render_barrier
			var row := {"boats":count,"scenario":scenario,
				"ticks":metric_summary(runtime.metrics.ticks,first_tick,last_tick),
				"frames":metric_summary(runtime.metrics.frames,first_frame,last_frame)}
			for column in [2,3,4]:
				var values: Array = []
				for entry in frame_rows: values.append(entry[column])
				row[["wall_ms","TIME_PROCESS_ms","TIME_PHYSICS_PROCESS_ms"][column-2]] = distribution(values)
			var fps: Array = []
			for entry in frame_rows: fps.append(1000.0/maxf(entry[2],0.00001))
			row.fps = distribution(fps)
			for column in [1,2]:
				var values: Array = []
				for entry in render_rows:
					if entry[column] > 0: values.append(entry[column])
				row[["viewport_cpu_ms","viewport_gpu_ms"][column-1]] = distribution(values)
			row.local_gpu_us = []
			row.timestamp_debug = timestamp_debug.duplicate(true)
			for slot in 2:
				var values: Array = []
				for entry in gpu_rows:
					if entry[0] == slot: values.append(entry[1])
				row.local_gpu_us.append(distribution(values))
			report.cases.append(row)
			print("LOCAL_SEA_CASE ",count," ",scenario," wall=",row.wall_ms," physics=",row.TIME_PHYSICS_PROCESS_ms)
			save()
	physics_frame.disconnect(trajectory)
	boats.clear()
	world.queue_free()
	for i in 20: await process_frame
	quit()

func save() -> void:
	DirAccess.make_dir_recursive_absolute("res://temp/local_sea_audit")
	var file := FileAccess.open("res://temp/local_sea_audit/"+report.phase+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
