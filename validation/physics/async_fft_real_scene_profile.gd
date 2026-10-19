extends SceneTree
## Opt-in replay of the real saved scene. Never saves a scene or resource.
var extra_boats: Array[Node3D] = []
var fft_rows: Array = []
var scene: Node
var world: Node
var ocean: Ocean
var boat: RigidBody3D
var camera: Camera3D
var runtime: RefCounted
var planar: Node
var native: Object
var frames: Array = []
var ticks: Array = []
var renders: Array = []
var cases: Array = []
var case_name := "warmup"
var measured := false
var last_us := 0
var tick_us := 0
var process_us := 0
var captured_frame := -1
var timestamp_labels: Array = []
var target := Vector3.ZERO
var direction := Vector3.ZERO
var camera_yaw := 0.0
var turn_camera := false
var elapsed := 0.0
var camera_offset := Vector3(0,3.5,8)
var camera_basis := Basis.IDENTITY
var phase_start_tick := 0
var profile_mode := "full"
var diagnostic_shaders: Dictionary = {}
var waterline: Node
var spatial_rows: Array = []
var buoyant_motion := true
var hidden_particles: Array = []
signal barrier

func _initialize() -> void:
	call_deferred("run")

func option(key: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(key+"="): return arg.trim_prefix(key+"=")
	return fallback

func perf2_record_span(stage: int, frame_id: int, tick_id: int, started: int, finished: int, calls: int) -> void:
	if native != null: native.call("perf2_record_span",stage,frame_id,tick_id,started,finished,calls)
	# Stage 0 encloses the controller. Other stages are inclusive children and
	# must never be summed into its duration.
	if measured and stage == 0: runtime.metrics.record(&"controller.integrate",finished-started,calls,tick_id,frame_id)

func pose() -> void:
	var p := target+direction*elapsed
	if buoyant_motion:
		var position := boat.global_position
		position.x = p.x; position.z = p.z
		boat.global_position = position
		var velocity := boat.linear_velocity
		velocity.x = direction.x; velocity.z = direction.z
		boat.linear_velocity = velocity
	else:
		boat.global_transform = Transform3D(Basis.IDENTITY,p)
		boat.linear_velocity = direction
		boat.angular_velocity = Vector3.ZERO
	boat.sleeping = false

func begin_tick() -> void:
	for i in extra_boats.size():
		var extra := extra_boats[i] as RigidBody3D
		var p := target+direction*elapsed+Vector3((i%3-1)*5.5,0,(i/3+1)*5.5)
		var current := extra.global_position
		current.x = p.x; current.z = p.z
		extra.global_position = current
		var velocity := extra.linear_velocity
		velocity.x = direction.x; velocity.z = direction.z
		extra.linear_velocity = velocity
		extra.sleeping = false
	elapsed += 1.0/Engine.physics_ticks_per_second
	pose()
	tick_us = Time.get_ticks_usec()

func end_tick() -> void:
	if measured:
		ticks.append([Engine.get_physics_frames(),Engine.get_process_frames(),(Time.get_ticks_usec()-tick_us)/1000.0])
		var row := {"tick":Engine.get_physics_frames(),"base":native.call("get_dynamic_lite_profile"),
			"async":native.call("get_dynamic_lite_async_stats"),"locals":[]}
		var scheduled_states: Array = runtime.states
		var scheduler: Node = world.water.get("_async_fft_driver")
		if scheduler != null and int(world.water.get("fft_execution_mode")) != 0: scheduled_states = scheduler.get("_states")
		for state in scheduled_states:
			if state != null and state.native != null:
				row.locals.append({"profile":state.native.call("get_dynamic_lite_profile"),"async":state.native.call("get_dynamic_lite_async_stats")})
		fft_rows.append(row)

func frame() -> void:
	var now := Time.get_ticks_usec()
	# The interval ending here contains this frame's physics and the previous
	# frame's process/render tail. Preserve IDs rather than guessing alignment.
	if measured and last_us > 0:
		frames.append([Engine.get_process_frames(),Engine.get_physics_frames(),
			(now-last_us)/1000.0,Performance.get_monitor(Performance.TIME_PROCESS)*1000,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000,Engine.get_frames_drawn(),
			boat.global_position.x,boat.global_position.y,boat.global_position.z,
			camera.global_position.x,camera.global_position.y,camera.global_position.z,
			camera.global_rotation.x,camera.global_rotation.y,camera.global_rotation.z])
	if native != null: native.call("perf2_frame_boundary",Engine.get_process_frames(),Engine.get_frames_drawn(),1000000)
	last_us = now
	process_us = now

func end_process() -> void:
	# Runs after normal gameplay and reflection updates. Keep position and
	# orientation independent of the boat's wave-driven attitude.
	camera.global_position = boat.global_position+camera_offset
	camera.global_basis = Basis(Vector3.UP, elapsed*0.65 if turn_camera else camera_yaw)*camera_basis
	for particles in hidden_particles: particles.visible = false
	if measured:
		runtime.metrics.record(&"process.callbacks",Time.get_ticks_usec()-process_us)
		var row: Dictionary = {"frame":Engine.get_process_frames(),"tick":Engine.get_physics_frames(),
			"weights":[],"water_state":waterline.get("_runtime_water_state") if waterline != null else "unknown"}
		for entry in runtime.entries: row.weights.append(runtime.weight(entry,boat.global_position))
		if waterline != null: row.waterline = waterline.call("get_waterline_state")
		spatial_rows.append(row)
		RenderingServer.call_on_render_thread(read_render.bind(Engine.get_process_frames(),Engine.get_physics_frames(),Engine.get_frames_drawn()))

func read_render(frame_id: int, tick_id: int, draw_id: int) -> void:
	var rd := RenderingServer.get_rendering_device()
	var captured := rd.get_captured_timestamps_frame()
	var stamps: Array = []
	if captured != captured_frame:
		captured_frame = captured
		for i in rd.get_captured_timestamps_count():
			stamps.append([rd.get_captured_timestamp_name(i),rd.get_captured_timestamp_gpu_time(i),rd.get_captured_timestamp_cpu_time(i)])
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
	var planar_gpu := 0.0
	var planar_cpu := 0.0
	if is_instance_valid(planar) and is_instance_valid(planar.get("_viewport")):
		var rid: RID = planar.get("_viewport").get_viewport_rid()
		planar_gpu = RenderingServer.viewport_get_measured_render_time_gpu(rid)
		planar_cpu = RenderingServer.viewport_get_measured_render_time_cpu(rid)
	# A single marker joins completed RD frames to the originating process/tick.
	rd.capture_timestamp("RealScene.Process.%d.Tick.%d"%[frame_id,tick_id])
	store_render.call_deferred([frame_id,tick_id,draw_id,captured,cpu,gpu,planar_cpu,planar_gpu,stamps])

func store_render(row: Array) -> void:
	renders.append(row)

func flush_render() -> void:
	emit_barrier.call_deferred()
func emit_barrier() -> void: barrier.emit()

func wait_seconds(seconds: float) -> void:
	var finish := Time.get_ticks_usec()+int(seconds*1000000)
	while Time.get_ticks_usec() < finish: await process_frame

func measure(label: String, p: Vector3, velocity: Vector3, rotate: bool, seconds: float) -> void:
	case_name = label
	target = p
	direction = velocity
	turn_camera = rotate
	elapsed = 0
	boat.global_transform = Transform3D(Basis.IDENTITY,p)
	boat.linear_velocity = velocity
	boat.angular_velocity = Vector3.ZERO
	for i in extra_boats.size():
		var extra := extra_boats[i] as RigidBody3D
		extra.global_transform = Transform3D(Basis.IDENTITY,p+Vector3((i%3-1)*5.5,0,(i/3+1)*5.5))
		extra.linear_velocity = velocity
		extra.angular_velocity = Vector3.ZERO
	pose()
	await wait_seconds(float(option("--settle","1.0")))
	elapsed = 0
	pose()
	runtime.metrics.clear()
	frames.clear(); ticks.clear(); renders.clear(); spatial_rows.clear(); fft_rows.clear()
	measured = true
	var measurement_start := Time.get_unix_time_from_system()
	await wait_seconds(seconds)
	measured = false
	var measurement_end := Time.get_unix_time_from_system()
	RenderingServer.call_on_render_thread(flush_render)
	await barrier
	var row := {"measurement_start_unix":measurement_start,"measurement_end_unix":measurement_end,"fft":fft_rows.duplicate(true),"case":label,"frames":frames.duplicate(),"ticks":ticks.duplicate(),"render":renders.duplicate(),
		"viewport_size":str(root.size),"viewport_texture_size":str(root.get_texture().get_size()),
		"metrics_ticks":runtime.metrics.ticks.duplicate(true),"metrics_frames":runtime.metrics.frames.duplicate(true),"spatial":spatial_rows.duplicate(true),
		"native":native.call("get_perf2_capture") if native != null else {},
		"planar":planar.call("get_state") if planar != null else {"active":false,"captures":0}}
	if profile_mode == "fragment_control":
		var current_material: ShaderMaterial = ocean._open_ocean._surface.get("_material")
		row["fragment_control_active"] = diagnostic_shaders.has(current_material) and current_material.shader != diagnostic_shaders[current_material]
		assert(row.fragment_control_active)
	if profile_mode == "water_control":
		row["water_control_active"] = not ocean._open_ocean._surface.visible
		assert(row.water_control_active)
	cases.append(row)
	if option("--screenshots","false") == "true":
		DirAccess.make_dir_recursive_absolute("res://temp/async_fft/real/screenshots")
		root.get_texture().get_image().save_png("res://temp/async_fft/real/screenshots/"+option("--label","baseline")+"_"+label+".png")
	print("ASYNC_REAL_PROFILE ",label," frames=",frames.size()," ticks=",ticks.size())

func run() -> void:
	profile_mode = "mist_control"
	Engine.physics_ticks_per_second = 60
	buoyant_motion = option("--motion","buoyant") == "buoyant"
	var scene_path := option("--scene","res://validation/hull_wave_physics_playground.tscn")
	scene = load(scene_path).instantiate()
	root.add_child(scene)
	current_scene = scene
	world = scene.get_node("JetSkiOcean")
	while not world.ready_to_drive: await process_frame
	ocean = world.get_node("Production/Ocean")
	waterline = ocean.get("_underwater_medium")
	var resolution := option("--resolution","1920x1080")
	if not resolution.is_empty():
		var dimensions := resolution.split("x")
		root.size = Vector2i(int(dimensions[0]),int(dimensions[1]))
		DisplayServer.window_set_size(root.size)
	boat = world.ski
	camera = world.camera
	world.camera_rig.process_mode = Node.PROCESS_MODE_DISABLED
	camera_offset = camera.global_position-boat.global_position
	camera_basis = camera.global_basis
	world.water.set("fft_execution_mode",int(option("--workers","0")))
	# Explicit test fixture only: the user's saved scene currently enables one
	# footprint. Add an unsaved second footprint to exercise both local states
	# and their overlap identically in A/B/C. Saved scenes/resources stay intact.
	if option("--layout","saved") == "two_state_test":
		var area := OceanWaveArea3D.new()
		area.name = "AsyncValidationArea2"
		area.ocean = ocean
		area.sea_state = 1
		area.wave_priority = 1
		area.blend_distance_m = 145.5
		var shape_node := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(124.74054,60,290.1746)
		shape_node.shape = box
		area.add_child(shape_node)
		scene.add_child(area)
		area.global_position = Vector3(-5,0,-435)
	var count := clampi(int(option("--boats","1")),1,6)
	for i in range(1,count):
		var extra: Node3D = load(boat.scene_file_path).instantiate()
		for property in boat.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_STORAGE and int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				extra.set(property.name,boat.get(property.name))
		extra.name = "AsyncFleet%d"%i
		extra.call("configure_ocean",ocean)
		extra.position = boat.global_position+Vector3(i*5.5,0,5.5)
		scene.add_child(extra)
		var rig: Node = extra.get_node_or_null("CameraRig")
		if rig != null:
			rig.process_mode = Node.PROCESS_MODE_DISABLED
			var extra_camera: Camera3D = rig.get_node_or_null("Camera3D")
			if extra_camera != null: extra_camera.current = false
		extra_boats.append(extra)
	camera.current = true
	runtime = ocean.get_wave_area_runtime()
	runtime.profiling_enabled = true
	runtime.metrics.enabled = true
	if profile_mode == "water_control":
		# Diagnostic draw control only; all producers, contacts and underwater
		# effects keep running. This is never the normal profiling path.
		ocean._open_ocean._surface.visible = false
	if profile_mode == "spray_control": boat.get_node("BowSprayRoot").visible = false
	var particle_paths: Array = []
	var particle_settings: Array = []
	for particles in scene.find_children("*","GPUParticles3D",true,false):
		particle_paths.append(str(particles.get_path()))
		particle_settings.append({"path":str(particles.get_path()),"amount":particles.amount,"lifetime":particles.lifetime,"local_coords":particles.local_coords,"fixed_fps":particles.fixed_fps})
		if profile_mode == "particles_control": hidden_particles.append(particles)
		if "sternmist" in str(particles.get_path()).to_lower():
			hidden_particles.append(particles)
			particles.emitting = false
			particles.visible = false
	if profile_mode == "fragment_control":
		# Diagnostic counterfactual only: same real geometry/physics and FFTs,
		# omit the local normal composition in a private in-memory shader.
		# Production shader resources and presets are never written.
		var surface: Object = ocean._open_ocean._surface
		var material: ShaderMaterial = surface.get("_material")
		var shader := Shader.new()
		var source := material.shader.code
		var original := "vec4 area_wave = wave_areas_compose(vec3(wave_area_q.x, wave_area_sea_level, wave_area_q.y), vec4(wave_area_base_height, area_slope, 0.0));"
		assert(source.count(original) == 1)
		shader.code = source.replace(original,"vec4 area_wave = vec4(wave_area_base_height, area_slope, 0.0);")
		diagnostic_shaders[material] = material.shader
		material.shader = shader
	planar = ocean.find_child("OceanPlanarReflection",true,false)
	if planar != null:
		planar.set("diagnostic_metrics",runtime.metrics)
		RenderingServer.viewport_set_measure_render_time(planar.get("_viewport").get_viewport_rid(),true)
	native = world.water.get("native")
	if "diagnostic_controller_sink" in world.water: world.water.set("diagnostic_controller_sink",self)
	if native != null: native.call("perf1_set_enabled",false)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	var tail := preload("res://validation/physics/async_fft_profile_end.gd").new()
	tail.recorder = self
	tail.process_priority = 1000000
	tail.process_physics_priority = 1000000
	root.add_child(tail)
	physics_frame.connect(begin_tick)
	process_frame.connect(frame)
	var metadata := {"layout":option("--layout","saved"),"workers_mode":int(option("--workers","0")),"boats":count,"stern_mist":false,"commit":"081dd40+async-experiment","scene":scene_path,"scene_sha256":FileAccess.get_sha256(scene_path), "mode":profile_mode,"motion":"buoyant" if buoyant_motion else "fixed_pose",
		"driver":RenderingServer.get_current_rendering_driver_name(),"adapter":RenderingServer.get_video_adapter_name(),
		"root_size":str(root.size),"render_size":str(root.get_visible_rect()),"max_fps":Engine.max_fps,
		"viewport_texture_size":str(root.get_texture().get_size()),"engine":Engine.get_version_info().string,
		"physics_hz":Engine.physics_ticks_per_second,"reflection_mode":ocean.reflection_profile.reflection_mode,
		"planar_present":planar!=null,"camera_offset":str(camera_offset),"camera_basis":str(camera_basis),
		"particle_paths":particle_paths,
		"particle_settings":particle_settings,
		"area_entries":runtime.entries,"spectrum_resolution":"unchanged 128/128/128 CPU; GPU saved presets"}
	print("ASYNC_REAL_METADATA ",JSON.stringify(metadata))
	target = Vector3(0,0.5,0)
	await wait_seconds(float(option("--warmup","10")))
	metadata["measured_root_size"] = str(root.size)
	metadata["measured_viewport_texture_size"] = str(root.get_texture().get_size())
	metadata["vsync"] = DisplayServer.window_get_vsync_mode()
	var locations := [["exterior",Vector3(260,0.5,-63)],["inside0",Vector3(35,0.5,-100)],
		["edge0",Vector3(120,0.5,-63)],["overlap",Vector3(-5,0.5,-310)],
		["inside1",Vector3(-5,0.5,-435)],["edge1",Vector3(120,0.5,-435)]]
	var duration := float(option("--seconds","3"))
	var selected := option("--select","all")
	for repetition in int(option("--repeats","1")):
		var points := locations.duplicate()
		if repetition%2 == 1: points.reverse()
		for entry in points:
			if selected != "all" and not str(entry[0]) in selected.split(","): continue
			await measure("%d_%s_hold"%[repetition,entry[0]],entry[1],Vector3.ZERO,false,duration)
		if selected == "all" or "travel" in selected.split(","):
			await measure("%d_travel_x"%repetition,Vector3(210,0.5,-140),Vector3(-20,0,0),false,8.0)
			await measure("%d_travel_z"%repetition,Vector3(35,0.5,90),Vector3(0,0,-20),false,18.0)
			await measure("%d_jump_land"%repetition,Vector3(-5,6.0,-310),Vector3(12,0,-8),false,3.0)
	DirAccess.make_dir_recursive_absolute("res://temp/async_fft/real")
	var file := FileAccess.open("res://temp/async_fft/real/"+option("--label","baseline")+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"metadata":metadata,"cases":cases}))
	file.close()
	for material in diagnostic_shaders: material.shader = diagnostic_shaders[material]
	print("ASYNC_REAL_PROFILE_DONE")
	quit()
