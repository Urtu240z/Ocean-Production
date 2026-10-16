extends SceneTree
## D3/D2 oracle replay. --fixtures=<preserved D2 probes> --result=<JSON>.
var args := {}
var failures: Array[String] = []
var report := {}
var world: Node
var sample_count := 0
var max_sample_error := 0.0

func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	run.call_deferred()

func check(ok: bool, label: String):
	if not ok and not failures.has(label):
		failures.append(label)
		push_error("D3_REGRESSION: " + label)

func compare(a: WaterSample3D, b: WaterSample3D):
	check(a.valid == b.valid, "sample validity")
	if a.valid and b.valid:
		max_sample_error = maxf(max_sample_error, a.surface_position.distance_to(b.surface_position))
		max_sample_error = maxf(max_sample_error, a.normal.distance_to(b.normal))
		max_sample_error = maxf(max_sample_error, a.velocity.distance_to(b.velocity))
		max_sample_error = maxf(max_sample_error, absf(a.signed_depth - b.signed_depth))
		check(a.surface_position == b.surface_position and a.normal == b.normal and a.velocity == b.velocity and a.signed_depth == b.signed_depth, "exact height normal velocity depth")
		check(a.sample_time_seconds == b.sample_time_seconds and a.sample_physics_tick == b.sample_physics_tick, "exact sample time and tick")
	sample_count += 1

func editor_settings(node: Object, camera_only := false) -> Dictionary:
	var settings := {}
	for prop in node.get_property_list():
		if not (int(prop.usage) & PROPERTY_USAGE_EDITOR and int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE): continue
		var key := str(prop.name)
		if camera_only and not (key.begins_with("camera_") or key == "follow_camera"): continue
		var value: Variant = node.get(prop.name)
		if value == null or value is Object or value is Array or value is Dictionary: continue
		settings[key] = str(value)
	return settings

func make_body(provider: WaterSurfaceProvider3D, legacy: bool) -> JetSkiController:
	var scene: String = str(args.fixtures).path_join("oracle_vehicle.tscn") if legacy else "res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn"
	var ski := load(scene).instantiate() as JetSkiController
	ski.freeze = true
	ski.collision_layer = 0
	ski.collision_mask = 0
	ski.position = Vector3(0, 1, 60)
	if legacy: ski.trick_preload_enabled = false
	ski.configure_water_provider(provider)
	world.add_child(ski)
	if legacy:
		# Exact D2 integrator setup. B must not receive these host overrides.
		ski.water_physics_system.diagnostics_enabled = false
		ski.water_physics_system.buoyancy_torque_scale = 1.0
		ski.set_ballast_mode(JetSkiController.BallastMode.STOCK)
		ski.set_draft_mode(JetSkiController.DraftMode.STANDARD)
		ski.set_drive_mode(JetSkiController.DriveMode.RACE)
		ski.water_physics_system.water_race_mode = true
		ski.water_physics_system.stabilized_angular_mode = true
		ski.set_combined_rider_inertia(true)
		var fx := load("res://addons/jet_ski/common/visual/jet_ski_water_contact_fx.gd").new() as Node3D
		fx.call("configure_ocean", world.get_node("Production/Ocean"))
		ski.add_child(fx)
	else:
		ski.get_node("WaterContactFx").call("configure_ocean", world.get_node("Production/Ocean"))
	return ski

func run():
	world = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	root.add_child(world)
	for frame in 600:
		await process_frame
		if bool(world.get("ready_to_drive")): break
	check(bool(world.get("ready_to_drive")), "production readiness")
	if not bool(world.get("ready_to_drive")):
		await finish()
		return
	var original: JetSkiController = world.get("ski")
	original.freeze = true
	var water: CpuFftWaterProvider = world.get("water")
	var ocean: Ocean = world.get_node("Production/Ocean")
	var old: WaterSurfaceProvider3D = load(str(args.fixtures).path_join("oracle_provider.gd")).new()
	for property in ["wave_drift_enabled", "wave_drift_strength", "wave_drift_max_speed_mps"]:
		old.set(property, water.get(property))
	check(bool(old.call("configure", ocean, 1, false)), "D2 native oracle configuration")
	# Configure off-tree to avoid starting a second PERF disk writer.
	world.add_child(old)
	old.call("set_query_mode", 0)
	old.call("set_water_race_mode", true)
	water.fft.set("_wave_time", 1.25)
	var contexts := [water.create_consumer_context(), water.create_consumer_context()]
	var oracle_contexts := [old.create_consumer_context(), old.create_consumer_context()]
	var points := original.water_physics_system.get_water_query_local_points()
	var extra := PackedVector3Array([Vector3.ZERO, original.drive_system.get_propulsion_local_point()])
	var builds_before := water.field_update_count
	for tick in 120:
		await physics_frame
		var before := water.field_update_count
		var wave_before: float = water.fft.call("get_wave_time")
		for consumer in 2:
			water.select_consumer(contexts[consumer])
			old.select_consumer(oracle_contexts[consumer])
			var t := float(tick) / 60.0
			var pose := Transform3D(Basis.from_euler(Vector3(sin(t) * 0.15, t * 0.1, cos(t) * 0.12)), Vector3(t * 3 + consumer * 20, 0.2 * sin(t), -t * 6))
			water.prepare_water_queries(pose, points, extra, 1.0 / 60.0)
			old.prepare_water_queries(pose, points, extra, 1.0 / 60.0)
			var all_points := points.duplicate()
			all_points.append_array(extra)
			for point in all_points:
				compare(water.sample_water(pose * point), old.sample_water(pose * point))
			var queries := PackedVector3Array([pose.origin + Vector3(1.7, -0.4, 2.3), pose.origin + Vector3(-2.1, 0.9, 4.7)])
			var batch := water.sample_surface_batch(queries)
			var prior := old.sample_surface_batch(queries)
			for i in batch.size(): compare(batch[i], prior[i])
			compare(water.sample_propulsion_water(pose.origin), old.sample_propulsion_water(pose.origin))
		check(water.field_update_count - before == 1, "one FFT build for two consumer query replays")
		check(is_equal_approx(float(water.fft.call("get_wave_time")) - wave_before, (1.0 / 60.0) * float(water.fft.call("get_simulation_time_scale"))), "unchanged single wave clock advance")
	report["samples"] = {"comparisons": sample_count, "max_error": max_sample_error, "ticks": 120, "shared_builds": water.field_update_count - builds_before}
	var vehicles: Array[JetSkiController] = [make_body(old, true), make_body(water, false)]
	await process_frame
	var a := vehicles[0]
	var b := vehicles[1]
	var settings_a := editor_settings(a)
	var settings_b := editor_settings(b)
	check(settings_a == settings_b, "all authored controller exports preserved")
	for key in settings_a:
		if settings_a[key] != settings_b.get(key):
			report["different_controller_setting_" + key] = [settings_a[key], settings_b.get(key)]
	var camera_settings := editor_settings(a.get_node("CameraRig"), true)
	check(camera_settings.size() == 23 and camera_settings == editor_settings(b.get_node("CameraRig"), true), "23 camera production settings")
	for key in ["water_race_mode", "stabilized_angular_mode", "buoyancy_torque_scale", "diagnostics_enabled"]:
		check(a.water_physics_system.get(key) == b.water_physics_system.get(key), "startup water setting " + key)
	check(a.inertia_mode_combined_rider == b.inertia_mode_combined_rider and b.inertia_mode_combined_rider, "production combined rider inertia")
	check(a.inertia == b.inertia and a.mass == b.mass and a.center_of_mass == b.center_of_mass, "mass inertia and center of mass")
	check(b.get_node_or_null("ProductionSetup") != null and b.get_node_or_null("WaterContactFx") != null, "vehicle-owned setup and contact effects")
	check(not b.has_node("JetSkiBuoyancyHud"), "no mandatory debug HUD")
	for ski in vehicles:
		ski.reset_physics_interpolation()
		ski.freeze = false
	var position_error := 0.0
	var velocity_error := 0.0
	var angular_error := 0.0
	var basis_error := 0.0
	var max_speed := 0.0
	var reverse_speed := 0.0
	var max_spray := 0.0
	var max_submerged := 0.0
	var airborne := false
	var landings := 0
	var recoveries := 0
	for tick in 1140:
		Input.action_press("throttle", 0.85) if (tick >= 60 and tick < 270) or (tick >= 550 and tick < 800) else Input.action_release("throttle")
		Input.action_press("steer_left", 0.4) if tick >= 160 and tick < 220 else Input.action_release("steer_left")
		Input.action_press("steer_right", 0.35) if tick >= 230 and tick < 260 else Input.action_release("steer_right")
		Input.action_press("brake", 0.9) if tick >= 270 and tick < 550 else Input.action_release("brake")
		Input.action_press("rider_shift_forward", 1.0) if tick >= 660 and tick < 760 else Input.action_release("rider_shift_forward")
		if tick == 800:
			for ski in vehicles:
				# A controlled upright drop, independent of the preceding submarine pose.
				ski.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 7, 60))
				ski.linear_velocity = Vector3(0, -5, -8)
				ski.angular_velocity = Vector3.ZERO
				ski.reset_physics_interpolation()
		if tick == 1040:
			for ski in vehicles: ski.recover_vehicle()
			recoveries += 1
		await physics_frame
		position_error = maxf(position_error, a.global_position.distance_to(b.global_position))
		velocity_error = maxf(velocity_error, a.linear_velocity.distance_to(b.linear_velocity))
		angular_error = maxf(angular_error, a.angular_velocity.distance_to(b.angular_velocity))
		for axis in 3: basis_error = maxf(basis_error, a.global_basis[axis].distance_to(b.global_basis[axis]))
		max_speed = maxf(max_speed, b.linear_velocity.length())
		if tick >= 450 and tick < 550: reverse_speed = minf(reverse_speed, b.linear_velocity.dot(-b.global_basis.z))
		max_spray = maxf(max_spray, float(b.get_node("BowSprayRoot").get("speed_factor")))
		max_submerged = maxf(max_submerged, b.submerged_ratio)
		airborne = airborne or b.water_physics_system.contact_is_airborne
		landings = maxi(landings, b.water_physics_system.contact_landing_event_serial)
	for action in ["throttle", "steer_left", "steer_right", "brake", "rider_shift_forward"]: Input.action_release(action)
	check(position_error == 0 and velocity_error == 0 and angular_error == 0 and basis_error == 0, "exact D2/D3 physics trajectory")
	check(max_speed > 3.0 and reverse_speed < -1.0 and max_spray > 0, "acceleration reverse and spray exercised")
	check(airborne and landings > 0 and recoveries == 1 and max_submerged > 0.0, "jump landing recovery and submersion exercised")
	report["trajectory"] = {"steps": 1140, "max_position_error_m": position_error, "max_velocity_error_mps": velocity_error,
		"max_angular_error_radps": angular_error, "max_basis_error": basis_error, "max_speed_mps": max_speed,
		"reverse_forward_speed_mps": reverse_speed, "max_spray": max_spray, "max_submerged": max_submerged,
		"airborne": airborne, "landing_events": landings, "recoveries": recoveries}
	report["controller_settings_compared"] = settings_a.size()
	report["camera_settings"] = camera_settings
	await finish()

func finish():
	report["passed"] = failures.is_empty()
	report["failures"] = failures
	var out := FileAccess.open(str(args.result), FileAccess.WRITE)
	out.store_string(JSON.stringify(report, "\t"))
	out.close()
	print("D3_REGRESSION_RESULT=" + str(report.passed))
	await world.call("_close_gracefully")
