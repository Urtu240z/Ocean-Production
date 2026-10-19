extends "res://validation/physics/async_fft_real_scene_profile.gd"
## Deterministic physics replay. Separate from the timed benchmark: resets only
## these private test instances and compares actual body/force/contact outputs.
var replay_rows: Array = []
var replay_bodies: Array = []
var replay_start_tick := 0
var recording := false
var tsunami_state: RefCounted

func _initialize() -> void: call_deferred("run")

func run() -> void:
	Engine.physics_ticks_per_second = 60
	scene = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	world = scene.get_node("JetSkiOcean")
	while not world.ready_to_drive: await process_frame
	ocean = world.get_node("Production/Ocean")
	boat = world.ski
	camera = world.camera
	world.camera_rig.process_mode = Node.PROCESS_MODE_DISABLED
	root.size = Vector2i(1920,1080)
	DisplayServer.window_set_size(root.size)
	var area := OceanWaveArea3D.new()
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
	replay_bodies.append(boat)
	for i in range(1,count):
		var extra: Node3D = load(boat.scene_file_path).instantiate()
		for property in boat.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_STORAGE and int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
				extra.set(property.name,boat.get(property.name))
		extra.call("configure_ocean",ocean)
		extra.name = "ReplayFleet%d"%i
		scene.add_child(extra)
		extra.get_node("CameraRig").process_mode = Node.PROCESS_MODE_DISABLED
		extra.get_node("CameraRig/Camera3D").current = false
		replay_bodies.append(extra)
	camera.current = true
	for body in replay_bodies: body.freeze = true
	for particles in scene.find_children("*","GPUParticles3D",true,false):
		if "sternmist" in str(particles.get_path()).to_lower():
			if "style" in particles and particles.get("style") != null:
				var private_style: Resource = particles.get("style").duplicate(true)
				private_style.set("enabled",false)
				particles.set("style",private_style)
			particles.emitting = false
			particles.visible = false
	# Fresh CPU epoch using exactly the already-published production H0.
	var fft: Node = ocean.get_node("OpenOceanFFT")
	for property in ["_wave_time","_previous_physics_wave_time","_visual_wave_time","_last_dispatched_visual_wave_time","_physics_wave_time_step"]:
		fft.set(property,0.0)
	fft.set("_last_authoritative_physics_tick",Engine.get_physics_frames())
	world.water.set("_metrics_physics_tick",-1)
	world.water.set("fft_execution_mode",0)
	assert(world.water.configure(ocean,CpuFftWaterProvider.Backend.CPU_LITE_B,false))
	world.water.set_query_mode(CpuFftWaterProvider.QueryMode.DIRECT)
	world.water.set_water_race_mode(true)
	runtime = ocean.get_wave_area_runtime()
	runtime.set("_clock",0.0)
	runtime.set("_clock_tick",Engine.get_physics_frames())
	runtime.time_s = 0.0
	for state in runtime.states:
		if state == null: continue
		state.time_s = 0.0
		state.set("_last_clock",0.0)
		state.set("_field_time",-INF)
		state.set("_physics_field_tick",-1)
		var fresh: Object = ClassDB.instantiate("OceanQueryNative")
		fresh.call("set_gameplay_min_wavelength_m",0.0)
		assert(fresh.call("set_production_spectrum",state.spectrum.bands))
		state.native = fresh
	ocean.set("_physical_hull_waves",null)
	# Use the production tsunami sampler with authored settings held privately;
	# its analytic sweep is identical at each replay tick in every mode.
	ocean.set("_boundary_tsunami_source",null)
	tsunami_state = ocean.get_boundary_tsunami_state()
	tsunami_state.clear()
	for i in replay_bodies.size():
		var body: RigidBody3D = replay_bodies[i]
		body.global_transform = Transform3D(Basis.IDENTITY,Vector3(260+i*5.5,0.5,-63))
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.sleeping = false
		for property in ["water_physics_system","navigation_system","drive_system","rider_dynamics_system","trick_system"]:
			body.get(property).reset_runtime_state()
		body.get("submarine_system").reset_runtime_state(false)
		body.get("arcade_handling_system").reset_turn_continuity_state()
		body.reset_physics_interpolation()
		body.freeze = false
	world.water.invalidate_contacts()
	world.water.fft_execution_mode = int(option("--workers","0"))
	replay_start_tick = Engine.get_physics_frames()+1
	physics_frame.connect(begin_tick)
	var tail := preload("res://validation/physics/async_fft_profile_end.gd").new()
	tail.recorder = self
	tail.process_physics_priority = 1000000
	root.add_child(tail)
	recording = true
	while replay_rows.size() < int(option("--ticks","720")): await process_frame
	recording = false
	DirAccess.make_dir_recursive_absolute("res://temp/async_fft/deterministic")
	var file := FileAccess.open("res://temp/async_fft/deterministic/"+option("--label","replay")+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"mode":int(option("--workers","0")),"boats":count,"rows":replay_rows}))
	file.close()
	print("ASYNC_DETERMINISTIC_DONE rows=",replay_rows.size()," boats=",count)
	quit()

func begin_tick() -> void:
	if not recording: return
	var tick := Engine.get_physics_frames()-replay_start_tick
	var points := [Vector3(260,0,-63),Vector3(35,0,-100),Vector3(120,0,-63),Vector3(-5,0,-310),Vector3(-5,0,-435),Vector3(120,0,-435),Vector3(260,0,-63)]
	var segment := clampi(tick/120,0,5)
	var progress := clampf(float(tick%120-90)/30.0,0.0,1.0)
	var p: Vector3 = points[segment].lerp(points[segment+1],progress)
	var speed: Vector3 = (points[segment+1]-points[segment])*2.0 if progress > 0.0 else Vector3.ZERO
	for i in replay_bodies.size():
		var body: RigidBody3D = replay_bodies[i]
		var position := body.global_position
		position.x = p.x+(i%3-1)*5.5
		position.z = p.z+(i/3)*5.5
		if tick == 300: position.y += 6.0
		body.global_position = position
		var velocity := body.linear_velocity
		velocity.x = speed.x; velocity.z = speed.z
		if tick == 300: velocity.y = 0.0
		body.linear_velocity = velocity
		body.sleeping = false
	tsunami_state.center_radius = Vector4(0,-250,100+tick*0.3,1.5 if tick >= 200 and tick < 600 else 0.0)
	tsunami_state.motion = Vector4(18,0,0.25,-PI*0.5)

func vector(v: Vector3) -> Array: return [v.x,v.y,v.z]

func vectors(values: PackedVector3Array) -> Array:
	var out: Array = []
	for value in values: out.append(vector(value))
	return out

func end_tick() -> void:
	if not recording or replay_rows.size() >= int(option("--ticks","720")): return
	var bodies: Array = []
	for body in replay_bodies:
		var physics: Node = body.get("water_physics_system")
		var water_state: RefCounted = physics.get("state")
		var submarine_state: RefCounted = body.get("submarine_system").state
		var transform: Transform3D = body.global_transform
		bodies.append({"position":vector(body.global_position),"basis":[vector(transform.basis.x),vector(transform.basis.y),vector(transform.basis.z)],
			"linear_velocity":vector(body.linear_velocity),"angular_velocity":vector(body.angular_velocity),
			"buoyancy":vector(physics.total_buoyancy_force_vector),"depths":Array(physics.point_depths),
			"point_forces":vectors(physics.point_buoyancy_force_vectors),"point_normals":vectors(physics.get_buoyancy_point_water_normals()),
			"sample_valid":Array(physics.get_point_sample_valid()),
			"submerged_ratio":water_state.submerged_ratio,"maximum_signed_depth":water_state.maximum_signed_point_depth,
			"water_velocity":vector(water_state.average_water_velocity),"drag_forward":water_state.total_forward_drag_force,
			"drag_lateral":water_state.total_lateral_drag_force,"submarine_mode":submarine_state.water_mode,
			"contact_is_wet":physics.contact_is_wet,"contact_is_supported":physics.contact_is_supported,
			"contact_is_airborne":physics.contact_is_airborne,"contact_is_landing":physics.contact_is_landing})
	replay_rows.append({"tick":Engine.get_physics_frames()-replay_start_tick,"wave_time":world.water.current_field_time,
		"local_clock":runtime.time_s,"bodies":bodies})

func end_process() -> void: pass
