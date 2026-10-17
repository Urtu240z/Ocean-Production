extends SceneTree
## Bounded flat-water equilibrium, A/B, propulsion and dry-force checks.
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
const HeavyResponse = preload("res://addons/jet_ski/common/systems/jet_ski_heavy_hull_response.gd")
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("HEAVY_HULL_SMOKE: " + message)


func _run() -> void:
	var rest := HeavyResponse.heave_response(300.0, 300.0, 0.0, 0.0, 0.35, 1.5, 1.0 / 60.0)
	_check(is_equal_approx(rest.added_mass_kg, 105.0) and is_zero_approx(rest.force_n),
		"added water inertia leaves hydrostatic equilibrium unchanged")
	var acceleration := HeavyResponse.heave_response(300.0, 300.0, 900.0, 0.0, 0.35, 1.5, 1.0 / 60.0)
	_check(absf((900.0 + float(acceleration.force_n)) / 300.0 - 900.0 / 405.0) < 0.00001,
		"wet water-driven acceleration uses effective heave mass")
	var dry := HeavyResponse.heave_response(300.0, 0.0, -2940.0, -10.0, 0.35, 1.5, 1.0 / 60.0)
	_check(is_zero_approx(dry.force_n) and is_zero_approx(dry.added_mass_kg), "no added force without contact")
	var scene := Gameplay.instantiate()
	# Temporary validation weather only; no saved scene/FFT/shader changes.
	var ocean: Node = scene.get_node("Production/Ocean")
	ocean.call("set_sea_state", {"sea_state_mode": 0, "wind_speed_mps": 1.0,
		"swell": 0.0, "wave_height_scale": 0.0})
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")):
			break
	_check(bool(scene.get("ready_to_drive")), "gameplay loads with flat CPU Lite water")
	if not bool(scene.get("ready_to_drive")):
		quit(1)
		return
	var ski: JetSkiController = scene.get("ski")
	var physics := ski.water_physics_system
	var nozzle := ski.drive_system.get_propulsion_local_point()
	var engine_force := ski.drive_system.forward_engine_force
	var steering := ski.maximum_steering_angle_degrees
	var com := ski.center_of_mass
	var draft := ski.get_draft_offset_m()
	physics.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	ski.set_hull_response_mode(JetSkiController.HullResponseMode.HEAVY_HULL)
	var minimum_y := INF
	var maximum_y := -INF
	for tick in 240:
		await physics_frame
		if tick >= 210:
			minimum_y = minf(minimum_y, ski.position.y)
			maximum_y = maxf(maximum_y, ski.position.y)
	var base_inertia: Vector3 = ski.inertia_measurement.get("base_response_inertia_local_kg_m2", Vector3.ZERO)
	var heavy_inertia := ski.inertia
	_check(is_equal_approx(ski.mass, 300.0), "real mass remains 300 kg")
	_check(is_equal_approx(float(ski.inertia_measurement.get("rider_mass_kg", 0.0)), 80.0),
		"existing seated rider is included without extra weight")
	_check(absf(heavy_inertia.x / base_inertia.x - 2.5) < 0.0001 \
		and absf(heavy_inertia.z / base_inertia.z - 2.5) < 0.0001,
		"pitch and roll inertia are multiplied by 2.5")
	_check(is_equal_approx(heavy_inertia.y, base_inertia.y), "yaw inertia is unchanged")
	_check(maximum_y - minimum_y < 0.015 and absf(ski.linear_velocity.y) < 0.10,
		"flat-water equilibrium is stable")
	_check(absf(physics.hull_buoyancy.submerged_volume_m3 - 0.300) < 0.015,
		"resting displacement preserves 300 kg hydrostatics")
	print("HEAVY_HULL_EQUILIBRIUM: I=%s base=%s volume=%.4f added=%.1f kg y_span=%.5f m vy=%.5f m/s" % [
		str(heavy_inertia), str(base_inertia), physics.hull_buoyancy.submerged_volume_m3,
		physics.heavy_heave_added_mass_kg, maximum_y - minimum_y, ski.linear_velocity.y])
	var hud: Node
	for child in ski.get_children():
		if child.get_script() == load("res://addons/jet_ski/debug/jet_ski_buoyancy_hud.gd"):
			hud = child
	_check(hud != null, "A/B HUD is present")
	var toggle := InputEventKey.new()
	toggle.keycode = KEY_J
	toggle.pressed = true
	hud.call("_unhandled_key_input", toggle)
	for tick in 4:
		await physics_frame
	_check(not ski.is_heavy_hull_active() and ski.inertia.is_equal_approx(base_inertia),
		"J restores the previous rider/hull inertia without compounded scaling")
	_check(physics.heavy_heave_force.is_zero_approx(), "previous HULL V1 has no heavy correction")
	_check(physics.buoyancy_mode == JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1
		and is_equal_approx(ski.get_draft_offset_m(), draft), "A/B preserves HULL V1 and draft corrections")
	hud.call("_unhandled_key_input", toggle)
	for tick in 4:
		await physics_frame
	_check(ski.is_heavy_hull_active() and ski.inertia.is_equal_approx(heavy_inertia), "J restores heavy response")
	_check(str(hud.get("_mode_label").text).contains("HEAVY HULL"), "HUD shows heavy mode")
	_check(ski.drive_system.get_propulsion_local_point().is_equal_approx(nozzle)
		and is_equal_approx(ski.drive_system.forward_engine_force, engine_force)
		and is_equal_approx(ski.maximum_steering_angle_degrees, steering)
		and ski.center_of_mass.is_equal_approx(com), "motor, controls, intake and COM remain intact")
	Input.action_press("throttle", 0.4)
	for tick in 12:
		await physics_frame
	_check(ski.drive_system.state.propulsion_force > 0.0, "existing throttle produces propulsion")
	print("HEAVY_HULL_PROPULSION: force=%.1f N nozzle=%s" % [
		ski.drive_system.state.propulsion_force, str(nozzle)])
	Input.action_release("throttle")
	ski.set_respawn_transform(Transform3D(Basis.IDENTITY, Vector3(0.0, 12.0, 0.0)))
	ski.reset_vehicle()
	for tick in 4:
		await physics_frame
	_check(physics.total_buoyancy_force_vector.is_zero_approx()
		and physics.total_buoyancy_torque.is_zero_approx()
		and physics.heavy_heave_force.is_zero_approx()
		and is_zero_approx(physics.heavy_heave_added_mass_kg), "no residual water force or torque in air")
	physics.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.LEGACY_4POINT)
	for tick in 3:
		await physics_frame
	_check(not physics.heavy_hull_enabled and ski.inertia.is_equal_approx(base_inertia),
		"legacy four-point mode retains its prior inertia")
	print("HEAVY_HULL_SMOKE: %s | errors=%d" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	if failures.is_empty():
		scene.call("_close_gracefully")
	else:
		quit(1)
