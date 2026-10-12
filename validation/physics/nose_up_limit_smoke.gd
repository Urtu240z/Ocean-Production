extends SceneTree
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
const Limit = preload("res://gameplay/vehicles/common/systems/jet_ski_nose_up_limit.gd")
var failures: Array[String] = []
var scene: Node
var ocean: Node
var ski: JetSkiController
var provider: Node


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("NOSE_UP_SMOKE: " + message)


func _math_checks() -> void:
	for yaw in [-170.0, 0.0, 120.0]:
		for roll in [-35.0, 0.0, 35.0]:
			var basis := Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3.RIGHT, deg_to_rad(23.0)) \
				* Basis(Vector3.BACK, deg_to_rad(roll))
			var inverse := basis * Basis.from_scale(Vector3(1.0 / 520.0, 1.0 / 173.0, 1.0 / 157.0)) * basis.transposed()
			var axis := (-basis.z).cross(Vector3.UP).normalized()
			var upward_torque := inverse.inverse() * (axis * 25.0)
			var response: Dictionary = Limit.response(basis, axis * 2.0, inverse, upward_torque,
				1.0, 25.0, 8.0, 8.0, 1.0 / 60.0)
			check(absf(response.pitch_degrees - 23.0) < 0.0001, "world pitch independent of yaw and roll")
			check(response.active and response.torque.is_finite(), "brakes an intense upward acceleration")
			var acceleration: Vector3 = inverse * response.torque
			check(acceleration.dot(axis) < 0.0, "unilateral downward correction")
			check(absf(acceleration.dot(Vector3.UP)) < 0.0001 and absf(acceleration.dot(-basis.z)) < 0.0001,
				"correction does not accelerate yaw or roll")
			var dry: Dictionary = Limit.response(basis, axis * 2.0, inverse, upward_torque,
				0.0, 25.0, 8.0, 8.0, 1.0 / 60.0)
			check(dry.torque == Vector3.ZERO, "no dry correction")
	var inverse := Basis.from_scale(Vector3(1.0 / 520.0, 1.0 / 173.0, 1.0 / 157.0))
	var down: Dictionary = Limit.response(Basis(Vector3.RIGHT, deg_to_rad(-20.0)), Vector3.RIGHT * 2.0,
		inverse, Vector3.RIGHT * 12000.0, 1.0, 25.0, 8.0, 8.0, 1.0 / 60.0)
	check(down.torque == Vector3.ZERO, "negative pitch unrestricted")
	var settled: Dictionary = Limit.response(Basis(Vector3.RIGHT, deg_to_rad(10.0)), Vector3.ZERO,
		inverse, Vector3.ZERO, 1.0, 25.0, 8.0, 8.0, 1.0 / 60.0)
	check(settled.torque == Vector3.ZERO, "below the soft zone no artificial pitch torque")
	var already_stable: Dictionary = Limit.response(Basis(Vector3.RIGHT, deg_to_rad(23.0)), Vector3.ZERO,
		inverse, Vector3.LEFT * 12000.0, 1.0, 25.0, 8.0, 8.0, 1.0 / 60.0)
	check(already_stable.torque == Vector3.ZERO, "existing stronger restoring torque is not duplicated")
	# The pure barrier is also bounded under sustained high power at inspector endpoints.
	for ceiling in [10.0, 25.0, 45.0]:
		var pitch := 0.0
		var speed := 0.0
		var maximum := 0.0
		for tick in 120:
			var response: Dictionary = Limit.response(Basis(Vector3.RIGHT, pitch), Vector3.RIGHT * speed,
				inverse, Vector3.RIGHT * 12000.0, 1.0, ceiling, 8.0, 8.0, 1.0 / 60.0)
			speed += (12000.0 / 520.0 + (inverse * response.torque).x) / 60.0
			pitch += speed / 60.0
			maximum = maxf(maximum, rad_to_deg(pitch))
		check(maximum <= ceiling + 0.1, "sustained powered ceiling " + str(ceiling))
		print("NOSE_UP_BARRIER: limit=%.0f max=%.3f deg" % [ceiling, maximum])


func _powered_phase(label: String, ticks: int) -> void:
	var maximum := -90.0
	var maximum_supported := -90.0
	var maximum_thrust := 0.0
	var active_ticks := 0
	for tick in ticks:
		await physics_frame
		var angle := rad_to_deg(Limit.world_pitch(ski.global_basis))
		maximum = maxf(maximum, angle)
		if ski.nose_up_contact_authority > 0.95: maximum_supported = maxf(maximum_supported, angle)
		if ski.nose_up_limit_active: active_ticks += 1
		maximum_thrust = maxf(maximum_thrust, ski.drive_system.state.propulsion_force)
		if ski.drive_system.state.is_propelling:
			var expected := ski.drive_system.forward_engine_force \
				* maxf(float(ski.drive_system.get("_throttle_output")) - ski.input_system.state.brake, 0.0) \
				* ski.drive_system.state.propulsion_contact_factor * ski.drive_system.state.forward_speed_factor \
				* ski.submarine_system.state.propulsion_factor_current * float(ski.drive_system.get("_airborne_authority"))
			check(absf(ski.drive_system.state.propulsion_force - expected) < maxf(0.01, expected * 0.00001),
				label + ": original thrust formula has no limiter reduction")
		check(ski.global_transform.is_finite() and ski.linear_velocity.is_finite() and ski.angular_velocity.is_finite(),
			label + ": finite physical motion")
	check(maximum_supported <= ski.nose_up_max_angle_degrees + 2.0, label + ": powered supported ceiling holds")
	check(maximum < 70.0, label + ": no near-vertical bow under acceleration")
	check(maximum_thrust > 0.0, label + ": propulsion active")
	print("NOSE_UP_PHASE: %s | max=%.3f supported=%.3f deg | guard ticks=%d | peak thrust=%.1f N" % [
		label, maximum, maximum_supported, active_ticks, maximum_thrust])
	if label == "NEAR_LIMIT":
		check(active_ticks > 0, "actual Jolt limiter exercised")
		check(maximum_thrust >= ski.drive_system.forward_engine_force * 0.99, "full original engine thrust is preserved near the ceiling")


func _run() -> void:
	_math_checks()
	scene = Gameplay.instantiate()
	ocean = scene.get_node("Production/Ocean")
	ocean.set("wave_height_scale", 0.0)
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")): break
	check(bool(scene.get("ready_to_drive")), "gameplay initializes")
	if not bool(scene.get("ready_to_drive")): quit(1); return
	ski = scene.get("ski")
	provider = scene.get("water")
	ski.water_physics_system.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	for tick in 120: await physics_frame
	var mass := ski.mass
	var inertia := ski.inertia
	var engine := ski.drive_system.forward_engine_force
	check(ski.nose_up_limit_enabled and ski.nose_up_max_angle_degrees == 25.0, "conservative initial inspector ceiling")
	Input.action_press("throttle", 1.0)
	await _powered_phase("FROM_REST", 180)
	# Test setup only: a near-ceiling initial attitude/rate exercises the actual Jolt callback.
	Input.action_release("throttle")
	ski.reset_vehicle()
	for tick in 30: await physics_frame
	ski.global_basis = Basis(Vector3.UP, deg_to_rad(80.0)) * Basis(Vector3.RIGHT, deg_to_rad(22.0))
	ski.angular_velocity = ski.global_basis.x * 1.2
	Input.action_press("throttle", 1.0)
	await _powered_phase("NEAR_LIMIT", 45)
	ocean.call("set_sea_state", {"sea_state_mode": 0, "wind_speed_mps": 18.0, "swell": 0.4, "wave_height_scale": 1.0})
	for frame in 240:
		await process_frame
		if provider.call("get_water_sync_status").status == "OK": break
	await _powered_phase("WAVES", 150)
	check(ski.mass == mass and ski.inertia == inertia and ski.drive_system.forward_engine_force == engine,
		"mass, inertia and engine power unchanged")
	# Setup an airborne pose with active input: the new protection must remain exactly zero.
	ski.global_position.y = 12.0
	ski.angular_velocity = Vector3.RIGHT
	for tick in 10:
		await physics_frame
		await process_frame
		check(ski.nose_up_limit_torque == Vector3.ZERO and not ski.rider_dynamics_system.external_nose_up_limit_active,
			"airborne throttle and rotation remain unrestricted")
	Input.action_release("throttle")
	print("NOSE_UP_SMOKE: %s | errors=%d" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	if failures.is_empty(): scene.call("_close_gracefully")
	else: quit(1)
