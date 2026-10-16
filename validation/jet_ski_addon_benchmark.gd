extends SceneTree
## D3 versus D2 direct integration. --vehicles=1|2|12, or --bench=AA|AB|BA
## --fixtures=<absolute probe directory> --result=<JSON>. No production tuning.
var args := {}
var failures: Array[String] = []
var world: Node
var report := {}

func _initialize():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	run.call_deferred()

func check(ok: bool, label: String):
	if not ok and not failures.has(label):
		failures.append(label)
		push_error(label)

func body(provider: WaterSurfaceProvider3D, index: int, scene: String) -> JetSkiController:
	var ski := load(scene).instantiate() as JetSkiController
	ski.name = "Consumer%d" % index
	ski.freeze = true
	var legacy := scene.get_file() == "vehicle_a.tscn"
	if legacy: ski.trick_preload_enabled = false
	ski.collision_layer = 0
	ski.collision_mask = 0
	ski.position = Vector3(index * 20, 1, 60)
	ski.configure_water_provider(provider)
	world.add_child(ski)
	if legacy:
		ski.water_physics_system.diagnostics_enabled = false
		ski.water_physics_system.buoyancy_torque_scale = 1.0
		ski.set_ballast_mode(JetSkiController.BallastMode.STOCK)
		ski.set_draft_mode(JetSkiController.DraftMode.STANDARD)
		ski.set_drive_mode(JetSkiController.DriveMode.RACE)
		ski.water_physics_system.water_race_mode = true
		ski.water_physics_system.stabilized_angular_mode = true
		ski.set_combined_rider_inertia(true)
		var fx: Node = load("res://addons/jet_ski/common/visual/jet_ski_water_contact_fx.gd").new()
		fx.call("configure_ocean", world.get_node("Production/Ocean"))
		ski.add_child(fx)
	else:
		ski.get_node("WaterContactFx").call("configure_ocean", world.get_node("Production/Ocean"))
		if args.has("bench"):
			# Equalize optional debug rendering in A/A and A/B; never required by B.
			ski.add_child(load("res://addons/jet_ski/debug/jet_ski_buoyancy_hud.gd").new())
	return ski

func stats(raw: PackedInt64Array, count: int) -> Dictionary:
	var values := raw.slice(0, count)
	values.sort()
	return {"count": count, "p50_us": values[int((count - 1) * 0.50)],
		"p95_us": values[int((count - 1) * 0.95)], "p99_us": values[int((count - 1) * 0.99)],
		"raw_us": Array(raw.slice(0, count))} if count > 0 else {"count": 0}

func run():
	var fixtures: String = args.get("fixtures", "")
	var bench: String = args.get("bench", "")
	world = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	var ocean: Ocean = world.get_node("Production/Ocean")
	var shared: CpuFftWaterProvider = load(fixtures.path_join("provider_b.gd")).new()
	shared.name = "PhysicalWater"
	ocean.add_child(shared)
	ocean.set("_cpu_water_provider", shared)
	root.add_child(world)
	for frame in 600:
		await process_frame
		if bool(world.get("ready_to_drive")): break
	check(bool(world.get("ready_to_drive")), "production readiness")
	(world.get("ski") as JetSkiController).freeze = true
	check(world.get("water") == shared and ocean.get_water_provider() == shared, "single provider factory")
	var native_id: int = shared.native.get_instance_id()
	var vehicles: Array[JetSkiController] = []
	var providers: Array[Node] = []
	var labels: Array[String] = []
	if bench.is_empty():
		for i in int(args.get("vehicles", 1)):
			vehicles.append(body(shared, i, "res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn"))
		providers.append(shared)
	else:
		for i in 2:
			var label := bench.substr(i, 1).to_lower()
			var water: Node = shared
			if label == "a":
				water = load(fixtures.path_join("provider_a.gd")).new()
				for property in ["wave_drift_enabled", "wave_drift_strength", "wave_drift_max_speed_mps"]:
					water.set(property, shared.get(property))
				check(bool(water.call("configure", ocean, 1, false)), "D2 oracle configuration")
				water.call("set_query_mode", 0)
				water.call("set_water_race_mode", true)
				world.add_child(water)
			providers.append(water)
			vehicles.append(body(water, i, fixtures.path_join("vehicle_%s.tscn" % label)))
			vehicles[-1].position = Vector3(0, 1, 60)
			labels.append(label)
	shared.fft.set("_wave_time", 1.25)
	for ski in vehicles:
		ski.reset_physics_interpolation()
		ski.freeze = false
	var max_speed := 0.0
	var max_wet := 0.0
	var max_spray := 0.0
	var pair_error := 0.0
	var ticks := 1080 if not bench.is_empty() else 360
	for tick in ticks:
		Input.action_press("throttle", 0.85) if tick > 60 else Input.action_release("throttle")
		Input.action_press("steer_left", 0.35) if tick >= 420 and tick < 540 else Input.action_release("steer_left")
		Input.action_press("rider_shift_forward", 1.0) if tick >= 660 and tick < 780 else Input.action_release("rider_shift_forward")
		if tick == 180 or (bench.is_empty() and tick == 30):
			for water in providers: water.set("recording", true)
			if not bench.is_empty():
				for ski in vehicles: ski.set("recording", true)
		await physics_frame
		for ski in vehicles:
			check(ski.global_transform.is_finite() and ski.linear_velocity.is_finite(), "finite vehicle trajectory")
			max_speed = maxf(max_speed, ski.linear_velocity.length())
			max_wet = maxf(max_wet, ski.water_contact_ratio)
			max_spray = maxf(max_spray, float(ski.get_node("BowSprayRoot").get("speed_factor")))
		if not bench.is_empty(): pair_error = maxf(pair_error, vehicles[0].global_position.distance_to(vehicles[1].global_position))
	for action in ["throttle", "steer_left", "rider_shift_forward"]: Input.action_release(action)
	for water in providers: water.set("recording", false)
	if not bench.is_empty():
		for ski in vehicles: ski.set("recording", false)
	check(max_speed > 3.0 and max_wet > 0.0, "actual flotation and propulsion")
	check(max_spray > 0.0, "bow spray remains active")
	check(shared.native.get_instance_id() == native_id, "native field not duplicated/replaced")
	check(shared.field_update_failures == 0, "no field failures")
	if bench.is_empty():
		var seen_contexts := {}
		var seen_samples := {}
		var inspected := 0
		for ski in vehicles:
			var context: RefCounted = ski.get("_water_consumer_context")
			check(not seen_contexts.has(context.get_instance_id()), "distinct consumer contexts")
			seen_contexts[context.get_instance_id()] = true
			var owner: Object = shared if context == shared.get("_active_consumer") else context
			var points: PackedVector3Array = owner.get("_contact_positions")
			var samples: Array = owner.get("_selected_contact_cache")
			check(points.size() == samples.size() and points.size() > 0, "consumer cache cardinality")
			for i in samples.size():
				check(not seen_samples.has(samples[i].get_instance_id()), "no sample aliases between consumers")
				seen_samples[samples[i].get_instance_id()] = true
				check(Vector2(points[i].x - ski.global_position.x, points[i].z - ski.global_position.z).length() < 6.0, "contact cache follows its own vehicle")
				if samples[i].valid:
					check(Vector2(samples[i].surface_position.x - points[i].x, samples[i].surface_position.z - points[i].z).length() < 0.001, "cached sample belongs to its contact")
				inspected += 1
			if owner == shared: check(context.get("_contact_positions") == null, "active PackedArray context slot released")
		var seen_ticks := {}
		for i in shared.get("fi"):
			var physics_tick: int = shared.get("build_ticks")[i]
			check(not seen_ticks.has(physics_tick), "one FFT construction per physical tick")
			seen_ticks[physics_tick] = true
		report = {"vehicles": vehicles.size(), "physics_ticks": ticks, "observed_builds": shared.get("fi"), "unique_build_ticks": seen_ticks.size(),
			"native_objects": 1, "distinct_contexts": seen_contexts.size(), "contact_samples_verified": inspected,
			"max_speed_mps": max_speed, "max_contact": max_wet, "max_spray": max_spray}
	else:
		check(pair_error == 0.0, "exact paired benchmark trajectory")
		var rows := []
		for i in 2:
			var water: Node = providers[i]
			var ski: Node = vehicles[i]
			rows.append({"variant": labels[i], "prepare": stats(water.get("prepare_us"), water.get("pi")),
				"batch": stats(water.get("batch_us"), water.get("bi")), "integrate": stats(ski.get("integrate_us"), ski.get("ii")),
				"builds": water.get("fi")})
		report = {"order": bench, "ticks": ticks, "warmup_ticks": 180, "pair_position_error_m": pair_error, "variants": rows}
	report["failures"] = failures
	report["passed"] = failures.is_empty()
	var out := FileAccess.open(str(args.result), FileAccess.WRITE)
	out.store_string(JSON.stringify(report, "\t"))
	out.close()
	print("OCEAN_DIRECT_RESULT=" + str(report.passed))
	await world.call("_close_gracefully")
