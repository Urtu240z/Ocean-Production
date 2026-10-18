extends SceneTree
## Isolated production-scene validation. Never saves authoring resources.
var args := {}
var world: Node3D
var ocean: Ocean
var water: CpuFftWaterProvider
var vehicles: Array[JetSkiController] = []
var rows: Array[Dictionary] = []

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and argument.contains("="):
			args[argument.get_slice("=",0).trim_prefix("--")] = argument.substr(argument.find("=")+1)
	run.call_deferred()

func stats(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	values.sort()
	var total := 0.0
	for value in values: total += float(value)
	return {"mean":total/values.size(),"median":values[values.size()/2],"p95":values[mini(values.size()-1,int(values.size()*0.95))],"max":values[-1]}

func run() -> void:
	seed(24017)
	var enabled: bool = args.get("physical","on")=="on"
	var mode: String = args.get("mode","runtime")
	var count := int(args.get("boats","2"))
	Engine.max_fps=0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	ProjectSettings.set_setting("jet_ski/hull_spray_enabled",false)
	world=load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	world.development_window_size=Vector2i(1280,720)
	world.validation_sea_state=0
	ocean=world.get_node("Production/Ocean")
	ocean.hull_foam_settings=ocean.get_hull_foam_settings().duplicate(true)
	ocean.set("foam_enabled",true)
	ocean.wind_speed_mps=3.0 if mode=="response" else 18.0
	if mode=="response": ocean.wave_height_scale=0.0
	ocean.set("foam_wave_physics_enabled",enabled)
	ocean.set("foam_deformation_enabled",true)
	root.add_child(world)
	for frame in 1800:
		await process_frame
		if world.ready_to_drive: break
	assert(world.ready_to_drive,"Production scene did not initialize")
	water=world.water
	# Development journals copy long captures; exclude them identically from
	# both timing cases, as in the existing foam/spray performance harness.
	var recorder: Node=water.get("_perf1_capture")
	if is_instance_valid(recorder):
		recorder.queue_free()
		await process_frame
	water.perf2_stage_measurements_enabled=false
	water.native.call("perf1_set_enabled",false)
	water.wave_drift_enabled=false if mode=="response" else water.wave_drift_enabled
	vehicles.append(world.ski)
	for i in range(1,count):
		var ski:=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate() as JetSkiController
		ski.position=world.ski.global_position+Vector3((i%4)*7.0,0,(i/4)*7.0)
		ski.configure_ocean(ocean)
		world.add_child(ski)
		ski.get_node("CameraRig").process_mode=Node.PROCESS_MODE_DISABLED
		vehicles.append(ski)
	for ski in vehicles:
		ski.collision_layer=0
		ski.collision_mask=0
	assert(water._active_consumer==null or water._active_consumer.provider_id==water.get_instance_id())
	for frame in 120: await physics_frame
	if mode=="response":
		await response()
		await finish()
		return
	Input.action_press("throttle",0.65)
	var warmup_end:=Time.get_ticks_msec()+int(args.get("warmup","5"))*1000
	while Time.get_ticks_msec()<warmup_end: await process_frame
	var director: Node=ocean.get_hull_foam_runtime()
	assert(director!=null)
	director.metrics_active=true
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	var output: String=args.get("out","res://temp/hull_wave_physics/runtime")
	DirAccess.make_dir_recursive_absolute(output)
	FileAccess.open(output.path_join("measure_started.json"),FileAccess.WRITE).store_string(JSON.stringify({"pid":OS.get_process_id()}))
	var begin:=Time.get_ticks_usec()
	var previous:=begin
	var last_tick:=-1
	var overlay_queries:=0
	var publish_times: Array=[]
	var max_packets:=0
	while Time.get_ticks_usec()-begin<int(args.get("seconds","10"))*1000000:
		await process_frame
		var now:=Time.get_ticks_usec()
		var state: RefCounted=ocean.get_physical_hull_wave_state()
		if enabled:
			assert(state!=null,"Physical wave snapshot unavailable")
			assert(state.tick==Engine.get_physics_frames())
			var updates: int=state.updates
			assert(ocean.get_physical_hull_wave_state()==state and state.updates==updates,"Snapshot advanced twice in a tick")
			if state.tick!=last_tick:
				publish_times.append(state.publication_us)
				last_tick=state.tick
			max_packets=maxi(max_packets,state.emitter.packets.size())
			overlay_queries=state.query_count
		for ski in vehicles:
			assert(ski.global_transform.is_finite() and ski.linear_velocity.is_finite())
			assert(absf(ski.global_position.y)<30.0 and ski.linear_velocity.length()<70.0,"Unstable vehicle")
		rows.append({"wall_ms":float(now-previous)/1000.0,
			"physics_ms":Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0,
			"process_ms":Performance.get_monitor(Performance.TIME_PROCESS)*1000.0,
			"render_cpu_ms":RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()),
			"render_gpu_ms":RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()),
			"ram_static":Performance.get_monitor(Performance.MEMORY_STATIC),
			"fft_builds":water.field_builds_this_physics_tick})
		previous=now
	Input.action_release("throttle")
	director.metrics_active=false
	FileAccess.open(output.path_join("measure_ended.json"),FileAccess.WRITE).store_string("{}")
	var summary: Dictionary={"physical":enabled,"boats":count,"samples":rows.size(),"mode":mode,
		"resolution":"1280x720","seed":24017,"wind":18.0,"vsync":false,"development_journals":false,
		"max_packets":max_packets,"overlay_query_points":overlay_queries,"publication_us":stats(publish_times),
		"wave_gpu_ms":stats(director.wave_gpu_ms.duplicate()),"static_ram_growth_bytes":rows[-1].ram_static-rows[0].ram_static}
	for key in ["wall_ms","physics_ms","process_ms","render_cpu_ms","render_gpu_ms","fft_builds"]:
		var values: Array=[]
		for row in rows: values.append(row[key])
		summary[key]=stats(values)
	if mode=="runtime": summary.lifecycle=await lifecycle_checks()
	FileAccess.open(output.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify(summary,"\t"))
	FileAccess.open(output.path_join("frames.json"),FileAccess.WRITE).store_string(JSON.stringify(rows))
	print("HULL_WAVE_PHYSICS_RUNTIME_PASS ",JSON.stringify(summary))
	await finish()

func lifecycle_checks() -> Dictionary:
	var before: RefCounted=ocean.get_physical_hull_wave_state()
	assert(before!=null and before.emitter.packets.size()>0)
	# Cached per-point reads must not add the overlay for a second time.
	var position: Vector3=water._contact_positions[0]
	var expected: WaterSample3D=water._selected_contact_cache[0]
	water._contact_cache_cursor=0
	var copy:=water.sample_water(position)
	assert(copy.surface_position==expected.surface_position and copy.velocity==expected.velocity)
	var points:=PackedVector3Array([vehicles[0].global_position+Vector3(2,0,8)])
	var first: PackedFloat64Array=before.sample(points,ocean.hull_foam_settings)
	var camera: Camera3D=root.get_camera_3d()
	var old_transform:=camera.global_transform
	camera.global_position+=Vector3(2000,0,2000)
	assert(before.sample(points,ocean.hull_foam_settings)==first,"Physics depends on the camera")
	camera.global_transform=old_transform
	ocean.set("foam_enabled",false)
	for frame in 10: await process_frame
	assert(ocean.get_physical_hull_wave_state()==before and director_waves_ready(),"Disabling foam disabled wave physics")
	ocean.set("foam_enabled",true)
	ocean.wind_speed_mps=3.0
	for frame in 300: await process_frame
	assert(ocean.get_physical_hull_wave_state()==before,"Wind rebuild discarded hull history")
	assert(ocean.get_physics_source_state().status=="OK")
	assert(not ocean.get_hull_foam_runtime()._surface_pending)
	return {"one_snapshot_per_tick":true,"cached_overlay_once":true,"camera_independent":true,
		"foam_independent":true,"wind_rebuild_preserved_state":true}

func director_waves_ready() -> bool:
	var director: Node=ocean.get_hull_foam_runtime()
	return director!=null and director.wave_field!=null and director.wave_field.ready

func response() -> void:
	assert(vehicles.size()==2)
	for ski in vehicles:
		ski.freeze=true
		ski.linear_velocity=Vector3.ZERO
		ski.angular_velocity=Vector3.ZERO
	var receiver:=vehicles[1]
	receiver.global_transform=Transform3D(Basis.IDENTITY,Vector3(10,0.3,60))
	receiver.reset_physics_interpolation()
	var state: RefCounted=ocean.get_physical_hull_wave_state()
	assert(state!=null)
	state.emitter.packets.clear()
	var amplitude:=0.6 if args.get("response","wave")=="wave" else 0.0
	state.emitter.packets.append({"owner":vehicles[0].get_instance_id(),"position":Vector2(7,60),"forward":Vector2(0,-1),
		"born":state.clock,"life":6.0,"amplitude":amplitude,"speed":1.2,"width":1.3,"wavelength":5.0,
		"half_length":1.0,"impact":true,"start_radius":0.0,"rise":0.45,"fade":2.0})
	receiver.freeze=false
	var sample_rows: Array=[]
	for frame in 360:
		await physics_frame
		var attitude:=receiver.global_basis.get_euler()
		sample_rows.append({"tick":frame,"y":receiver.global_position.y,"vy":receiver.linear_velocity.y,
			"pitch":attitude.x,"roll":attitude.z})
		assert(receiver.global_transform.is_finite() and receiver.linear_velocity.length()<25.0)
	var output: String=args.get("out","res://temp/hull_wave_physics/response")
	DirAccess.make_dir_recursive_absolute(output)
	FileAccess.open(output.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify({"amplitude":amplitude,"trajectory":sample_rows},"\t"))
	print("HULL_WAVE_RESPONSE_PASS amplitude=",amplitude," samples=",sample_rows.size())

func finish() -> void:
	Input.action_release("throttle")
	root.remove_child(world)
	world.queue_free()
	for frame in 20: await process_frame
	quit()
