extends SceneTree
## Standalone camera contract. No development gameplay scene or Ocean is loaded.
## Optional --oracle=<legacy script> --baseline=<before JSON> compares the refactor
## numerically with the preserved implementation, including impacts and recovery.

class FlatWater extends WaterSurfaceProvider3D:
	func sample_water(point: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
		var sample := out_sample if out_sample != null else WaterSample3D.new()
		sample.valid = true
		sample.surface_position = Vector3(point.x, 0.0, point.z)
		sample.normal = Vector3.UP
		sample.velocity = Vector3.ZERO
		sample.signed_depth = -point.y
		return sample

var _failures: Array[String] = []
var _result := {}
var _arguments := {}


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			_arguments[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error("JET_SKI_CAMERA: " + message)


func _run() -> void:
	# General vehicle input is an existing host contract, separate from this rig's
	# optional raw-key camera controls. The development integrator is not needed.
	for action in ["throttle", "brake", "steer_left", "steer_right", "rider_shift_left", "rider_shift_right", "rider_shift_forward", "rider_shift_back", "reset_vehicle", "recover_vehicle", "eject_rider"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
	var world := Node3D.new()
	world.name = "MinimalIndependentWorld"
	root.add_child(world)
	var water := FlatWater.new()
	water.name = "AnyWaterProvider"
	world.add_child(water)
	var packed := load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn") as PackedScene
	var vehicle := packed.instantiate() as JetSkiController
	vehicle.name = "RenamedVehicle"
	vehicle.water_provider_path = NodePath("../AnyWaterProvider")
	vehicle.freeze = true
	vehicle.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	world.add_child(vehicle)
	var rig := vehicle.get_node_or_null("CameraRig") as Node3D
	_check(rig != null, "Vehicle does not own its rig")
	if rig == null:
		_finish()
		return
	rig.set_process(false)
	rig.set_physics_process(false)
	var camera := rig.get_node("Camera3D") as Camera3D
	_check(camera.get_parent() == rig and rig.get_parent() == vehicle, "Camera hierarchy is not vehicle-local")
	_check(rig.top_level, "Hull transform would be applied twice")
	_check(rig.process_mode == Node.PROCESS_MODE_ALWAYS, "Paused camera policy changed")
	_check(camera.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "Camera interpolation changed")
	_check(camera.far == 4000.0, "Far clipping changed")
	_check(is_equal_approx(float(rig.get("camera_distance_m")), 2.7), "Production distance changed")
	_check(is_equal_approx(float(rig.get("camera_height_m")), 1.6), "Production height changed")
	_check(is_equal_approx(float(rig.get("camera_speed_pullback_m")), 2.0), "Serialized pullback was lost")
	_check(is_equal_approx(float(rig.get("camera_impact_distance_m")), 0.6), "Serialized impact distance was lost")
	_check(is_equal_approx(float(rig.get("camera_impact_recovery_seconds")), 0.9500000000000001), "Serialized recovery was lost")
	var impact: RefCounted = rig.get("_camera_impact")
	_check(vehicle.hard_landing.is_connected(Callable(rig, "_on_camera_hard_landing")), "Landing signal is not owned by rig")
	_check(vehicle.reset_completed.is_connected(Callable(rig, "_reset_camera_impact")), "Recovery signal is not owned by rig")

	var oracle: Node3D
	var baseline_settings := {}
	if _arguments.has("baseline"):
		baseline_settings = JSON.parse_string(FileAccess.get_file_as_string(_arguments.baseline)).camera_settings
		for key in baseline_settings:
			_check(rig.get(key) == baseline_settings[key], "Baseline parameter mismatch: " + key)
		_result["production_parameters_compared"] = baseline_settings.size()
	if _arguments.has("oracle"):
		var script := load(str(_arguments.oracle)) as Script
		oracle = script.new() as Node3D
		oracle.set("ski", vehicle)
		var old_camera := Camera3D.new()
		oracle.add_child(old_camera)
		oracle.set("camera", old_camera)
		world.add_child(oracle)
		oracle.set_process(false)
		oracle.set_physics_process(false)
		for key in baseline_settings:
			oracle.set(key, baseline_settings[key])
		vehicle.hard_landing.connect(Callable(oracle, "_on_camera_hard_landing"))
		vehicle.reset_completed.connect(Callable(oracle, "_reset_camera_impact"))

	# These poses and telemetry belong only to this isolated fixture. No production
	# tuning is changed. Both cameras read the SAME body and completed-tick state.
	vehicle.freeze = false
	var largest_error := 0.0
	var largest_impact := 0.0
	var phases: Array[String] = ["idle", "speed", "jump_pitch_roll", "submarine", "solid_impact", "water_landing_recovery"]
	for frame in 600:
		var phase: int = frame / 100
		var t := float(frame) / 60.0
		var dt: float = [1.0 / 60.0, 1.0 / 144.0, 0.08][frame % 3]
		vehicle.global_position = Vector3(sin(t) * 3.0, sin(t * 1.8) * 2.0, -t * 12.0)
		vehicle.global_basis = Basis.from_euler(Vector3(sin(t) * (1.5 if phase == 2 else 0.3), t * 0.3, cos(t) * 0.4))
		vehicle.linear_velocity = Vector3(4.0, -12.0 if phase == 2 else 0.0, -30.0 if phase > 0 else 0.0)
		var state = vehicle.water_physics_system.state
		state.raw_contact_mask = 0 if phase == 2 else 15
		state.support_normal = Vector3(0.1, 1.0, 0.2).normalized()
		state.total_forward_drag_force = 1800.0 if phase == 3 else 100.0
		vehicle.water_physics_system.hull_root_depth_m = 1.0 if phase == 3 else 0.0
		var nav = vehicle.navigation_system.state
		nav.physical_contact_count = 1 if phase == 4 else 0
		nav.physical_contact_impulse = Vector3(900.0, 1800.0, 1200.0) if frame == 402 else Vector3.ZERO
		rig.call("_physics_process", dt)
		if oracle != null: oracle.call("_physics_process", dt)
		if frame == 503: vehicle.hard_landing.emit(0.85, vehicle.global_position)
		if frame == 550:
			vehicle.reset_completed.emit(&"validation_recovery")
			_check(impact.position_offset_world == Vector3.ZERO, "Recovery retained an impact displacement")
		rig.call("update_camera", dt)
		largest_impact = maxf(largest_impact, impact.position_offset_world.length())
		_check(camera.global_position.is_finite() and camera.global_basis.is_finite(), "Non-finite camera transform")
		if oracle != null:
			oracle.call("update_camera", dt)
			var old_camera: Camera3D = oracle.get("camera")
			var error := camera.global_position.distance_to(old_camera.global_position)
			for axis in 3:
				error = maxf(error, camera.global_basis[axis].distance_to(old_camera.global_basis[axis]))
			largest_error = maxf(largest_error, error)
			_check(is_equal_approx(camera.fov, old_camera.fov), "FOV diverged from preserved implementation")
	vehicle.freeze = true
	_check(largest_impact > 0.0, "Impact/landing sequence did not exercise shake")
	if oracle != null:
		_check(largest_error <= 0.00001, "Camera diverged from preserved implementation: " + str(largest_error))
	_result["pose_phases"] = phases
	_result["pose_steps"] = 600
	_result["legacy_oracle_used"] = oracle != null
	_result["max_transform_error"] = largest_error
	_result["max_impact_offset"] = largest_impact
	_result["impact_events"] = impact.event_count

	# The optional input node is not needed to follow a vehicle or animate effects.
	var controls := rig.get_node("Controls")
	controls.set("controls_enabled", false)
	var previous := camera.global_position
	vehicle.global_position += Vector3(20.0, 0.0, 0.0)
	rig.call("update_camera", 1.0 / 60.0)
	_check(camera.global_position.distance_to(previous) > 10.0, "Follow depends on controls/HUD")
	_result["follows_without_controls_or_development_hud"] = camera.global_position.distance_to(previous) > 10.0
	controls.set("controls_enabled", true)
	var old_distance := float(rig.get("camera_distance_m"))
	var event := InputEventKey.new()
	event.keycode = KEY_EQUAL
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	_check(is_equal_approx(float(rig.get("camera_distance_m")), old_distance - 0.25), "Standalone key control failed")
	paused = true
	event = InputEventKey.new()
	event.keycode = KEY_MINUS
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	await process_frame
	_check(is_equal_approx(float(rig.get("camera_distance_m")), old_distance), "Camera controls stopped during pause")
	paused = false
	_finish()


func _finish() -> void:
	_result["passed"] = _failures.is_empty()
	_result["failures"] = _failures
	_result["no_development_gameplay_script_loaded"] = true
	if _arguments.has("result"):
		var file := FileAccess.open(str(_arguments.result), FileAccess.WRITE)
		file.store_string(JSON.stringify(_result, "\t"))
	print("JET_SKI_CAMERA_RIG_RESULT ", JSON.stringify(_result))
	quit(0 if _failures.is_empty() else 1)
