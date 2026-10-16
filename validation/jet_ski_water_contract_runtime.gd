extends SceneTree
## --mode=flat (default), --mode=integration, or
## --mode=ocean --oracle=<preserved CPU provider.gd>
## --result=<JSON>. Oracle is an external exact snapshot from the pre-D1 HEAD.
var _args := {}
var _failures: Array[String] = []
var _report := {}
var _world: Node

class FoamProbe extends Node3D:
	var persistent_foam_enabled := true
	var landing_ripples_enabled := true
	var stamps: Array = []
	func submit_interaction_foam_stamp(position: Vector3, velocity: Vector3, strength: float, landing: bool) -> void:
		stamps.append([position, velocity, strength, landing])

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			_args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	_run.call_deferred()

func _check(ok: bool, label: String) -> void:
	if not ok:
		_failures.append(label)
		push_error("WATER_CONTRACT: " + label)

func _run() -> void:
	if str(_args.get("mode", "flat")) == "ocean":
		await _ocean()
	elif str(_args.get("mode", "flat")) == "integration":
		await _integration()
	else:
		await _flat()
	_report["failures"] = _failures
	_report["passed"] = _failures.is_empty()
	if _args.has("result"):
		var file := FileAccess.open(str(_args.result), FileAccess.WRITE)
		file.store_string(JSON.stringify(_report, "\t"))
	print("WATER_CONTRACT_RESULT=" + str(_report.passed))
	if is_instance_valid(_world) and _world.has_method("_close_gracefully"):
		await _world.call("_close_gracefully")
	else:
		quit(0 if _failures.is_empty() else 1)

func _flat() -> void:
	_world = load("res://validation/jet_ski_flat_water.tscn").instantiate()
	root.add_child(_world)
	var water := _world.get_node("Water") as FlatWaterProvider3D
	var ski := _world.get_node("JetSki") as JetSkiController
	var positions := PackedVector3Array([Vector3(2, -0.5, 3), Vector3(-2, 1, -3)])
	water.water_height = 0.25
	water.water_velocity = Vector3(0.1, 0.2, -0.3)
	water.prepare_water_queries(Transform3D.IDENTITY, positions, PackedVector3Array(), 1.0 / 60.0)
	var batch := water.sample_surface_batch(positions)
	_check(batch.size() == 2, "flat batch cardinality")
	for i in batch.size():
		var sample: WaterSample3D = batch[i]
		_check(sample.valid and sample.surface_position == Vector3(positions[i].x, 0.25, positions[i].z), "flat height")
		_check(sample.normal == Vector3.UP and sample.velocity == water.water_velocity, "flat normal and velocity")
		_check(sample.signed_depth == 0.25 - positions[i].y, "flat signed depth")
		_check(is_finite(sample.sample_time_seconds) and sample.sample_physics_tick >= 0, "flat publication metadata")
		_compare(sample, water.sample_propulsion_water(positions[i]), "flat propulsion")
	var scratch := WaterSample3D.new()
	water.sample_water(Vector3.ZERO, scratch)
	water.water_enabled = false
	water.sample_water(Vector3.ZERO, scratch)
	_check(not scratch.valid and is_nan(scratch.sample_time_seconds) and scratch.sample_physics_tick == -1, "invalid scratch resets metadata")
	_check(water.sample_surface_batch(positions).size() == positions.size(), "invalid source keeps batch shape")
	water.water_enabled = true
	water.water_height = 0.0
	water.water_velocity = Vector3.ZERO
	var max_speed := 0.0
	var max_spray := 0.0
	var max_wet := 0.0
	var camera_start: Vector3 = ski.get_node("CameraRig/Camera3D").global_position
	for tick in 600:
		Input.action_press("throttle", 0.8) if tick >= 120 else Input.action_release("throttle")
		Input.action_press("steer_left", 0.3) if tick >= 360 and tick < 420 else Input.action_release("steer_left")
		await physics_frame
		max_speed = maxf(max_speed, Vector2(ski.linear_velocity.x, ski.linear_velocity.z).length())
		max_spray = maxf(max_spray, float(ski.get_node("BowSprayRoot").get("speed_factor")))
		max_wet = maxf(max_wet, ski.water_contact_ratio)
		_check(ski.global_transform.is_finite() and ski.linear_velocity.is_finite(), "finite flat vehicle tick %d" % tick)
	Input.action_release("throttle")
	Input.action_release("steer_left")
	var camera: Camera3D = ski.get_node("CameraRig/Camera3D")
	_check(max_speed > 3.0 and max_wet > 0.0, "flat buoyancy and propulsion")
	_check(max_spray > 0.0, "standalone bow spray")
	_check(camera.global_position.distance_to(camera_start) > 2.0, "standalone camera follows")
	_check(not ResourceLoader.has_cached("res://gameplay/jet_ski_ocean.gd"), "no development integrator loaded")
	# Historical flat fixture remains useful for physics tests. D2 deliberately
	# makes Ocean's types a mandatory dependency of Jet Ski.
	_report.merge({"mode": "flat", "physics_ticks": 600, "max_speed_mps": max_speed,
		"max_contact_ratio": max_wet, "max_spray": max_spray, "camera_travel_m": camera.global_position.distance_to(camera_start),
		"no_development_integrator_loaded": true, "historical_flat_fixture": true})

func _ocean() -> void:
	if not _args.has("oracle"):
		_check(false, "provide the exact pre-D1 provider via --oracle")
		return
	_world = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	root.add_child(_world)
	for frame in 600:
		await process_frame
		if bool(_world.get("ready_to_drive")): break
	if not bool(_world.get("ready_to_drive")):
		_check(false, "production scene readiness")
		return
	var ski: JetSkiController = _world.get("ski")
	ski.freeze = true
	var water: WaterSurfaceProvider3D = _world.get("water")
	var old: Node = load(str(_args.oracle)).new()
	old.name = "PreD1OracleOnly"
	old.set("wave_drift_enabled", water.get("wave_drift_enabled"))
	old.set("wave_drift_strength", water.get("wave_drift_strength"))
	old.set("wave_drift_max_speed_mps", water.get("wave_drift_max_speed_mps"))
	_check(bool(old.call("configure", _world.get_node("Production/Ocean"), 1, false)), "oracle configured")
	# Configure the oracle off-tree: it must not start a second PERF capture writer.
	_world.add_child(old)
	old.call("set_query_mode", 0)
	old.call("set_water_race_mode", true)
	var fft: Node = water.get("fft")
	# Deterministic query replay only: fixed initial phase and scripted contact poses.
	# Production clock implementation and authored simulation rate stay unchanged.
	fft.set("_wave_time", 1.25)
	var local_points := ski.water_physics_system.get_water_query_local_points()
	var extra := PackedVector3Array([Vector3.ZERO, ski.drive_system.get_propulsion_local_point()])
	var builds_before := int(water.get("field_update_count"))
	var checked := 0
	for tick in 120:
		await physics_frame
		var initial_builds := int(water.get("field_update_count"))
		var before_time := float(fft.call("get_wave_time"))
		for consumer in 2:
			var t := float(tick) / 60.0
			var pose := Transform3D(Basis.from_euler(Vector3(sin(t) * 0.15, t * 0.1, cos(t) * 0.12)),
				Vector3(t * 3.0 + float(consumer) * 20.0, 0.2 * sin(t), -t * 6.0))
			water.prepare_water_queries(pose, local_points, extra, 1.0 / 60.0)
			old.call("begin_gameplay_contacts", pose, local_points, extra, 1.0 / 60.0)
			var all_points := local_points.duplicate()
			all_points.append_array(extra)
			for point in all_points:
				var p := pose * point
				var sample := water.sample_water(p)
				_compare(sample, old.call("sample_water", p), "prefetch %d/%d" % [tick, consumer])
				_check(sample.sample_time_seconds == float(water.get("current_field_time")) and sample.sample_physics_tick == int(water.get("last_build_tick")), "prefetch timestamp")
				checked += 1
			var queries := PackedVector3Array([pose.origin + Vector3(1.7, -0.4, 2.3), pose.origin + Vector3(-2.1, 0.9, 4.7)])
			var batch := water.sample_surface_batch(queries)
			var legacy: Array = old.call("sample_water_batch", queries)
			_check(batch.size() == queries.size() and legacy.size() == batch.size(), "Ocean batch cardinality")
			for i in mini(batch.size(), legacy.size()):
				_compare(batch[i], legacy[i], "batch %d/%d/%d" % [tick, consumer, i])
				_check(batch[i].sample_time_seconds == float(water.get("current_field_time")), "batch timestamp")
				checked += 1
			_compare(water.sample_propulsion_water(pose.origin), old.call("sample_propulsion_water", pose.origin), "Ocean propulsion")
		_check(int(water.get("field_update_count")) - initial_builds == 1, "two consumers share exactly one build at tick %d" % tick)
		_check(is_equal_approx(float(fft.call("get_wave_time")) - before_time, (1.0 / 60.0) * float(fft.call("get_simulation_time_scale"))), "clock advances exactly once per tick")
	_check(int(water.get("field_update_failures")) == 0, "no native field failures")
	var empty := water.sample_surface_batch(PackedVector3Array())
	_check(empty.is_empty(), "empty batch")
	_report.merge({"mode": "ocean", "exact_comparisons": checked, "consumers": 2,
		"physics_ticks": 120, "shared_field_builds": int(water.get("field_update_count")) - builds_before,
		"max_height_normal_velocity_depth_error": 0.0 if _failures.is_empty() else -1.0,
		"oracle_has_separate_native_fields_for_validation_only": true})
	if _args.has("controller-oracle"):
		await _paired_physics(water, old)
	old.queue_free()

func _paired_physics(water: WaterSurfaceProvider3D, old: Node) -> void:
	# Two identical fresh bodies in the same world/time, excluded from all solid
	# collisions. B uses the exact pre-D1 force dispatcher and old CPU provider.
	var vehicles: Array[JetSkiController] = []
	for index in 2:
		var ski := load("res://gameplay/vehicles/jet_ski_01/jet_ski_01.tscn").instantiate() as JetSkiController
		if index == 1:
			# Replacing a script resets its exported values. Preserve the prefab's
			# serialized overrides rather than comparing it against code defaults.
			var settings := {}
			for prop in ski.get_property_list():
				if int(prop.usage) & PROPERTY_USAGE_EDITOR and int(prop.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE:
					settings[prop.name] = ski.get(prop.name)
			ski.set_script(load(str(_args["controller-oracle"])))
			for key in settings: ski.set(key, settings[key])
		ski.name = "ParityBody%d" % index
		ski.freeze = true
		ski.trick_preload_enabled = false
		ski.collision_layer = 0
		ski.collision_mask = 0
		ski.position = Vector3(0, 1, 60)
		ski.configure_water_provider(water if index == 0 else old)
		_world.add_child(ski)
		ski.water_physics_system.diagnostics_enabled = false
		ski.water_physics_system.buoyancy_torque_scale = 1.0
		ski.set_ballast_mode(JetSkiController.BallastMode.STOCK)
		ski.set_draft_mode(JetSkiController.DraftMode.STANDARD)
		ski.set_drive_mode(JetSkiController.DriveMode.RACE)
		ski.water_physics_system.water_race_mode = true
		ski.water_physics_system.stabilized_angular_mode = true
		ski.set_combined_rider_inertia(true)
		vehicles.append(ski)
	for ski in vehicles:
		ski.reset_physics_interpolation()
		ski.freeze = false
	var position_error := 0.0
	var velocity_error := 0.0
	var angular_error := 0.0
	var basis_error := 0.0
	var max_speed := 0.0
	for tick in 480:
		Input.action_press("throttle", 0.85) if tick > 60 else Input.action_release("throttle")
		Input.action_press("steer_left", 0.4) if tick > 160 and tick < 220 else Input.action_release("steer_left")
		Input.action_press("brake", 0.7) if tick >= 220 and tick < 250 else Input.action_release("brake")
		Input.action_press("rider_shift_forward", 1.0) if tick >= 300 and tick < 400 else Input.action_release("rider_shift_forward")
		if tick == 250:
			for ski in vehicles:
				ski.global_position = Vector3(0, 6, 60)
				ski.linear_velocity = Vector3(0, -5, -12)
				ski.angular_velocity = Vector3.ZERO
		await physics_frame
		position_error = maxf(position_error, vehicles[0].global_position.distance_to(vehicles[1].global_position))
		velocity_error = maxf(velocity_error, vehicles[0].linear_velocity.distance_to(vehicles[1].linear_velocity))
		angular_error = maxf(angular_error, vehicles[0].angular_velocity.distance_to(vehicles[1].angular_velocity))
		for axis in 3:
			basis_error = maxf(basis_error, vehicles[0].global_basis[axis].distance_to(vehicles[1].global_basis[axis]))
		max_speed = maxf(max_speed, vehicles[0].linear_velocity.length())
	for action in ["throttle", "steer_left", "brake", "rider_shift_forward"]:
		Input.action_release(action)
	_check(max_speed > 3.0, "paired bodies actually drive")
	_check(position_error == 0.0 and velocity_error == 0.0 and angular_error == 0.0 and basis_error == 0.0, "deterministic pre-D1 physics trajectory")
	_report["paired_physics"] = {"ticks": 480, "max_position_error_m": position_error,
		"max_linear_velocity_error_mps": velocity_error, "max_angular_velocity_error_radps": angular_error,
		"max_basis_error": basis_error, "max_speed_mps": max_speed,
		"phases": ["float", "accelerate", "turn", "brake", "drop_reentry", "lean_front_submarine"]}
	for ski in vehicles: ski.queue_free()

func _compare(a: WaterSample3D, b: WaterSample3D, label: String) -> void:
	_check(a.valid == b.valid, label + " validity")
	if a.valid and b.valid:
		_check(a.surface_position == b.surface_position, label + " surface position")
		_check(a.normal == b.normal, label + " normal")
		_check(a.velocity == b.velocity, label + " velocity")
		_check(a.signed_depth == b.signed_depth, label + " signed depth")

func _integration() -> void:
	_world = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	root.add_child(_world)
	for frame in 600:
		await process_frame
		if bool(_world.get("ready_to_drive")): break
	if not bool(_world.get("ready_to_drive")):
		_check(false, "integration readiness")
		return
	var ski: JetSkiController = _world.get("ski")
	var water: WaterSurfaceProvider3D = _world.get("water")
	var ocean: Node = _world.get_node("Production/Ocean")
	var before_serial := ski.water_physics_system.contact_landing_event_serial
	# Controlled drop is test input, not a tuning change. Start away from the ramp.
	ski.global_position = Vector3(0, 7, 60)
	ski.linear_velocity = Vector3(0, -5, -8)
	ski.angular_velocity = Vector3.ZERO
	ski.reset_physics_interpolation()
	var airborne := false
	var supported := false
	var drift_speed := 0.0
	for tick in 180:
		await physics_frame
		airborne = airborne or ski.water_physics_system.contact_is_airborne
		supported = supported or ski.water_physics_system.contact_is_supported
		var sample := water.sample_water(ski.global_position + Vector3(3, 0, 0))
		if sample.valid: drift_speed = maxf(drift_speed, Vector2(sample.velocity.x, sample.velocity.z).length())
	_check(airborne and supported, "airborne and water reentry")
	_check(ski.water_physics_system.contact_landing_event_serial > before_serial, "water landing event")
	_check(drift_speed > 0.0, "wave-dependent horizontal water velocity preserved")
	var rig: Node3D = ski.get_node("CameraRig")
	rig.set_process(false)
	rig.set_physics_process(false)
	ski.freeze = true
	var camera: Camera3D = rig.get_node("Camera3D")
	var medium: Node = ocean.get("_underwater_medium")
	_check(is_instance_valid(medium), "underwater medium exists")
	var states: Array[String] = []
	if is_instance_valid(medium):
		for y in [6.0, -6.0, 6.0]:
			camera.global_position = Vector3(0, y, 60)
			camera.look_at(Vector3(0, y, 40), Vector3.UP)
			for frame in 80: await process_frame
			var state: Dictionary = medium.call("get_runtime_feature_state")
			states.append(str(state.get("runtime_water_state", "")))
			_check(bool(state.get("readback_valid", false)), "waterline readback valid")
		_check(states == ["AIR_SAFE", "UNDERWATER_SAFE", "AIR_SAFE"], "air/underwater/air transition")
	# The direct Ocean API forwards the original payload without an adapter.
	var host := Ocean.new()
	var probe := FoamProbe.new()
	host.add_child(probe)
	host.set("_open_ocean", probe)
	_check(host.is_persistent_foam_enabled() and host.is_landing_ripple_enabled(), "direct interaction capabilities")
	host.submit_foam_stamp(Vector3.ONE, Vector3.UP, 0.75, true)
	_check(probe.stamps == [[Vector3.ONE, Vector3.UP, 0.75, true]], "exact interaction payload")
	host.remove_child(probe)
	probe.free()
	_check(not host.is_persistent_foam_enabled(), "retired Ocean is safe")
	probe = FoamProbe.new()
	host.add_child(probe)
	host.set("_open_ocean", probe)
	host.submit_foam_stamp(Vector3.ZERO, Vector3.FORWARD, 0.25, false)
	_check(probe.stamps.size() == 1, "direct API follows replacement Ocean")
	host.free()
	_report.merge({"mode": "integration", "drop_physics_ticks": 180, "airborne": airborne,
		"supported": supported, "new_landing_events": ski.water_physics_system.contact_landing_event_serial - before_serial,
		"max_wave_drift_velocity_mps": drift_speed, "underwater_states": states,
		"interaction_payload_and_rebind_verified": true})
