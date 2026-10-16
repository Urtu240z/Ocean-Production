extends SceneTree
## Copied as main.gd into an otherwise empty project with addons/ocean only.
## Optional --joint=yes adds the existing Jet Ski tree, without extracting D3.
var args := {}
var failures: Array[String] = []
var world: Node3D

func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	run.call_deferred()

func check(ok: bool, label: String):
	if not ok:
		failures.append(label)
		push_error(label)

func run():
	world = Node3D.new()
	root.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.35, 0.55, 0.7)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.8, 0.85, 1.0)
	environment.environment.ambient_light_energy = 0.8
	world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -30, 0)
	world.add_child(sun)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 6, 10)
	camera.look_at(Vector3(0, 0, -10))
	camera.current = true
	var ocean: Ocean = load("res://addons/ocean/ocean.tscn").instantiate()
	# Test host enables the existing optional medium; packaged defaults unchanged.
	ocean.underwater_medium = true
	ocean.underwater_sun_light = sun
	world.add_child(ocean)
	for frame in 120: await process_frame
	check(ClassDB.class_exists("OceanQueryNative"), "native DLL registered")
	var source: Dictionary = ocean.get_physics_source_state()
	check(str(source.get("status", "")) == "OK", "Ocean physical source ready")
	var water := ocean.get_water_provider()
	water.lite_resolutions = PackedInt32Array([128, 128, 128])
	water.lite_interpolation_modes = PackedInt32Array([1, 1, 1])
	check(water.configure(ocean, 1, false), "CPU Lite initializes without development scene")
	water.set_water_race_mode(true)
	var points := PackedVector3Array([Vector3(-0.4, 0, -1), Vector3(0.4, 0, -1), Vector3(-0.4, 0, 1), Vector3(0.4, 0, 1)])
	var contexts := [water.create_consumer_context(), water.create_consumer_context()]
	var builds := water.field_update_count
	var valid_samples := 0
	var time_begin := float(water.fft.call("get_wave_time"))
	for tick in 180:
		await physics_frame
		var count_before := water.field_update_count
		for i in 2:
			water.select_consumer(contexts[i])
			var pose := Transform3D(Basis.IDENTITY, Vector3(i * 20, 0, -tick * 0.1))
			water.prepare_water_queries(pose, points, PackedVector3Array(), 1.0 / 60.0)
			var queries := PackedVector3Array([pose.origin + Vector3(0.5, -0.2, 0.7), pose.origin - Vector3(0.3, 0.4, 0.8)])
			var batch := water.sample_water_batch(queries)
			check(batch.size() == 2, "batch cardinality")
			for sample in batch:
				check(sample.valid and sample.surface_position.is_finite() and sample.normal.is_finite() and sample.velocity.is_finite(), "finite valid native result")
				check(sample.sample_time_seconds == water.current_field_time and sample.sample_physics_tick == water.last_build_tick, "synchronized sample metadata")
				valid_samples += int(sample.valid)
		check(water.field_update_count - count_before == 1, "one shared construction per tick")
	var query_builds := water.field_update_count - builds
	var joint := str(args.get("joint", "no")) == "yes"
	var vehicle_report := {}
	if joint:
		# Runtime load keeps the Ocean-only fixture free of Jet Ski class symbols.
		var host: Node = load("res://validation/jet_ski_flat_water.gd").new()
		world.add_child(host)
		var ski: RigidBody3D = load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
		ski.set("trick_preload_enabled", false)
		ski.position = Vector3(0, 1, 60)
		ski.call("configure_water_provider", water)
		world.add_child(ski)
		var system: Node = ski.get("water_physics_system")
		system.set("diagnostics_enabled", false)
		system.set("buoyancy_torque_scale", 1.0)
		system.set("water_race_mode", true)
		system.set("stabilized_angular_mode", true)
		ski.call("set_combined_rider_inertia", true)
		ski.get_node("WaterContactFx").call("configure_ocean", ocean)
		var speed := 0.0
		var spray := 0.0
		var wet := 0.0
		var camera_start: Vector3 = ski.get_node("CameraRig/Camera3D").global_position
		var before_landing: int = system.get("contact_landing_event_serial")
		var airborne := false
		for tick in 480:
			Input.action_press("throttle", 0.85) if tick > 60 else Input.action_release("throttle")
			Input.action_press("steer_left", 0.3) if tick >= 160 and tick < 220 else Input.action_release("steer_left")
			Input.action_press("rider_shift_forward", 1.0) if tick >= 360 and tick < 430 else Input.action_release("rider_shift_forward")
			if tick == 250:
				ski.global_position = Vector3(0, 7, 60)
				ski.linear_velocity = Vector3(0, -5, -8)
				ski.angular_velocity = Vector3.ZERO
				ski.reset_physics_interpolation()
			await physics_frame
			check(ski.global_transform.is_finite() and ski.linear_velocity.is_finite(), "finite clean-install vehicle")
			speed = maxf(speed, ski.linear_velocity.length())
			spray = maxf(spray, float(ski.get_node("BowSprayRoot").get("speed_factor")))
			wet = maxf(wet, float(ski.get("water_contact_ratio")))
			airborne = airborne or bool(system.get("contact_is_airborne"))
		for action in ["throttle", "steer_left", "rider_shift_forward"]: Input.action_release(action)
		var rig: Node = ski.get_node("CameraRig")
		camera = rig.get_node("Camera3D")
		var travel := camera.global_position.distance_to(camera_start)
		check(speed > 3 and wet > 0 and spray > 0 and travel > 2, "clean-install drive, flotation, camera and spray")
		check(airborne and int(system.get("contact_landing_event_serial")) > before_landing, "jump and landing camera input")
		vehicle_report = {"max_speed_mps": speed, "max_spray": spray, "max_contact": wet, "camera_travel_m": travel,
			"airborne": airborne, "landing_events": int(system.get("contact_landing_event_serial")) - before_landing}
		ski.freeze = true
		rig.set_process(false)
		rig.set_physics_process(false)
	var medium: Node = ocean.get("_underwater_medium")
	check(is_instance_valid(medium), "medium exists")
	var states: Array[String] = []
	for y in [6.0, -6.0, 6.0]:
		camera.global_position = Vector3(0, y, 10)
		camera.look_at(Vector3(0, y, -10))
		camera.make_current()
		for frame in 80: await process_frame
		var state: Dictionary = medium.call("get_runtime_feature_state")
		states.append(str(state.get("runtime_water_state", "")))
		check(bool(state.get("readback_valid", false)), "waterline publication")
	check(states == ["AIR_SAFE", "UNDERWATER_SAFE", "AIR_SAFE"], "air underwater air")
	check(RenderingServer.get_current_rendering_method() == "forward_plus", "Forward+ active")
	await RenderingServer.frame_post_draw
	if args.has("screenshot"):
		root.get_texture().get_image().save_png(str(args.screenshot))
	var report := {"passed": failures.is_empty(), "failures": failures, "joint": joint,
		"render_method": RenderingServer.get_current_rendering_method(), "native_registered": ClassDB.class_exists("OceanQueryNative"),
		"valid_samples": valid_samples, "query_ticks": 180, "query_builds": query_builds,
		"wave_time_advanced": float(water.fft.call("get_wave_time")) > time_begin, "underwater_states": states, "vehicle": vehicle_report,
		"development_integrator_loaded": ResourceLoader.has_cached("res://gameplay/jet_ski_ocean.gd")}
	var out := FileAccess.open(str(args.result), FileAccess.WRITE)
	out.store_string(JSON.stringify(report, "\t"))
	out.close()
	print("CLEAN_INSTALL_RESULT=" + str(report.passed))
	world.queue_free()
	for frame in 5: await process_frame
	quit(0 if failures.is_empty() else 1)
