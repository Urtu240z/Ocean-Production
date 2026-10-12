extends SceneTree
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
const Recovery = preload("res://gameplay/vehicles/common/systems/jet_ski_auto_nose_recovery.gd")
const Pitch = preload("res://gameplay/vehicles/common/systems/jet_ski_nose_up_limit.gd")
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
		push_error("NOSE_RECOVERY_SMOKE: " + message)


func _math_checks() -> void:
	for yaw in [-150.0, 0.0, 90.0]:
		for roll in [-35.0, 0.0, 35.0]:
			var previous := 0.0
			for nose_down in [9.0, 11.0, 15.0, 25.0, 45.0]:
				var basis := Basis(Vector3.UP, deg_to_rad(yaw)) * Basis(Vector3.RIGHT, deg_to_rad(-nose_down)) \
					* Basis(Vector3.BACK, deg_to_rad(roll))
				var inverse := basis * Basis.from_scale(Vector3(1.0 / 520.0, 1.0 / 173.0, 1.0 / 157.0)) * basis.transposed()
				var axis := (-basis.z).cross(Vector3.UP).normalized()
				var torque: Vector3 = Recovery.response(basis, Vector3.ZERO, inverse, Vector3.ZERO, 1.0, 10.0, 5.0, 1.0, 6000.0, 1.0 / 60.0)
				var acceleration: Vector3 = inverse * torque
				check(torque.is_finite() and torque.length() <= 6000.001, "finite capped torque")
				check(acceleration.dot(axis) >= -0.0001, "only nose-up angular acceleration")
				check(absf(acceleration.dot(Vector3.UP)) < 0.0001 and absf(acceleration.dot(-basis.z)) < 0.0001,
					"yaw and roll angular acceleration unchanged")
				check(torque.length() >= previous - 0.001, "progressive angle response")
				previous = torque.length()
				if nose_down <= 10.0: check(torque == Vector3.ZERO, "no correction inside the allowed nose-down angle")
				var dry: Vector3 = Recovery.response(basis, -axis, inverse, Vector3.ZERO, 0.0, 10.0, 5.0, 1.0, 6000.0, 1.0 / 60.0)
				check(dry == Vector3.ZERO, "no torque without water authority")
				var stable: Vector3 = Recovery.response(basis, Vector3.ZERO, inverse, inverse.inverse() * (axis * 100.0), 1.0, 10.0, 5.0, 1.0, 6000.0, 1.0 / 60.0)
				check(stable == Vector3.ZERO, "existing stronger UPRIGHT/rider correction is not duplicated")
	var inverse := Basis.from_scale(Vector3(1.0 / 520.0, 1.0 / 173.0, 1.0 / 157.0))
	var basis := Basis(Vector3.RIGHT, deg_to_rad(-25.0))
	var falling: Vector3 = Recovery.response(basis, Vector3.LEFT, inverse, Vector3.ZERO, 1.0, 10.0, 5.0, 1.0, 6000.0, 1.0 / 60.0)
	var rising: Vector3 = Recovery.response(basis, Vector3.RIGHT, inverse, Vector3.ZERO, 1.0, 10.0, 5.0, 1.0, 6000.0, 1.0 / 60.0)
	check(falling.length() > rising.length() and rising == Vector3.ZERO, "angular damping avoids rebounding lift")


func _tick() -> void:
	await physics_frame
	await process_frame


func _weather(flat: bool) -> void:
	ocean.call("set_sea_state", {"sea_state_mode": 0, "wind_speed_mps": 18.0, "swell": 0.4,
		"wave_height_scale": 0.0 if flat else 1.0})
	# Let a deferred rebuild start before accepting its ready status.
	for frame in 8: await process_frame
	for frame in 240:
		await process_frame
		if provider.call("get_water_sync_status").status == "OK": break
	check(provider.call("get_water_sync_status").status == "OK", "water spectrum synchronized")


func _pose(pitch_degrees: float, height: float, speed: float, pitch_rate: float) -> void:
	# Initial conditions for a bounded contact test; production never writes transforms.
	ski.reset_vehicle()
	ski.global_basis = Basis(Vector3.RIGHT, deg_to_rad(pitch_degrees))
	ski.global_position = Vector3(0.0, height, 0.0)
	ski.linear_velocity = Vector3(0.0, -0.5, -speed)
	ski.angular_velocity = Vector3.RIGHT * pitch_rate


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
	for tick in 90: await _tick()
	var mass := ski.mass
	var inertia := ski.inertia
	var engine := ski.drive_system.forward_engine_force
	var recovery_ticks := 0
	var peak_torque := 0.0
	var peak_front_drag := 0.0
	var minimum_front_pitch_drag := 0.0
	await _weather(false)
	_pose(-25.0, 0.25, 18.0, -3.0)
	Input.action_press("throttle", 1.0)
	var initial_pitch := rad_to_deg(Pitch.world_pitch(ski.global_basis))
	var best_pitch := initial_pitch
	var max_thrust := 0.0
	for tick in 150:
		await _tick()
		if tick < 12:
			print("NOSE_RECOVERY_CONTACT: tick=%d pitch=%.2f authority=%.3f torque=%.1f mask=%d" % [tick,
				rad_to_deg(Pitch.world_pitch(ski.global_basis)), ski.nose_recovery_authority,
				ski.nose_recovery_torque.length(), ski.water_physics_system.state.raw_contact_mask])
		best_pitch = maxf(best_pitch, rad_to_deg(Pitch.world_pitch(ski.global_basis)))
		if not ski.nose_recovery_torque.is_zero_approx(): recovery_ticks += 1
		peak_torque = maxf(peak_torque, ski.nose_recovery_torque.length())
		max_thrust = maxf(max_thrust, ski.drive_system.state.propulsion_force)
		var front_drag := Vector3.ZERO
		var front_torque := Vector3.ZERO
		var center := ski.global_transform * ski.center_of_mass
		for index in 2:
			var force: Vector3 = ski.water_physics_system.point_forward_drag_forces[index]
			front_drag += force
			front_torque += (ski.water_physics_system.get_point_world_position(index) - center).cross(force)
		peak_front_drag = maxf(peak_front_drag, front_drag.length())
		var axis := (-ski.global_basis.z).cross(Vector3.UP).normalized()
		minimum_front_pitch_drag = minf(minimum_front_pitch_drag, front_torque.dot(axis))
		check(ski.global_transform.is_finite() and ski.angular_velocity.is_finite(), "finite wave motion")
	check(recovery_ticks > 0 and best_pitch > -10.0, "wet nose recovers while crossing waves")
	check(peak_torque <= ski.nose_recovery_max_torque_nm + 0.01 and max_thrust > 0.0, "capped assistance and live propulsion")
	print("NOSE_RECOVERY_WAVES: active=%d peak=%.1f Nm best pitch=%.2f thrust=%.1f N front drag=%.1f N nose-down drag moment=%.1f Nm" % [recovery_ticks, peak_torque, best_pitch, max_thrust, peak_front_drag, minimum_front_pitch_drag])
	# Immediate override while wet, before a Submarine can be entered.
	Input.action_press("rider_shift_forward", 1.0)
	await _tick()
	check(ski.nose_recovery_overridden and ski.nose_recovery_torque == Vector3.ZERO and ski.nose_recovery_authority == 0.0,
		"Lean Front suppresses recovery in its first physics step")
	Input.action_press("rider_shift_back", 1.0)
	await _tick()
	check(is_zero_approx(ski.input_system.state.rider_shift_raw.y) and ski.nose_recovery_overridden \
		and ski.nose_recovery_torque == Vector3.ZERO, "held Lean Front wins even when opposite inputs cancel")
	Input.action_release("rider_shift_back")
	Input.action_release("throttle")
	await _weather(true)
	# An actual air-to-bow-water entry exercises the existing Submarine detector.
	# The local gameplay setup disables this trick explicitly. Enable it only in
	# this fixture, preserving that scene configuration and all entry thresholds.
	ski.submarine_dive_enabled = true
	ski.call("_configure_submarine_system")
	var entry_basis := Basis(Vector3.RIGHT, deg_to_rad(-32.0))
	var lowest := INF
	for cell in ski.water_physics_system.hull_buoyancy.cells:
		for vertex in cell.tetrahedra:
			lowest = minf(lowest, (entry_basis * vertex).y)
	_pose(-32.0, -lowest + 0.5, 12.0, 0.0)
	ski.linear_velocity.y = -2.0
	var dive_seen := false
	for tick in 60:
		await _tick()
		if tick < 12:
			print("NOSE_RECOVERY_ENTRY: tick=%d pitch=%.2f speed=%.2f mask=%d prevalid=%s dive=%s" % [tick,
				rad_to_deg(Pitch.world_pitch(ski.global_basis)), ski.linear_velocity.length(),
				ski.water_physics_system.state.raw_contact_mask, ski.submarine_system.state.pre_contact_valid,
				ski.submarine_system.is_dive_active()])
		check(ski.nose_recovery_torque == Vector3.ZERO and ski.nose_recovery_authority == 0.0, "entry/held Lean Front has zero assistance")
		if ski.submarine_system.is_dive_active(): dive_seen = true; break
	check(dive_seen, "Submarine still enters through actual front-first water contact")
	print("NOSE_RECOVERY_DIVE: entered=%s pitch=%.2f" % [dive_seen, rad_to_deg(Pitch.world_pitch(ski.global_basis))])
	for tick in 8:
		await _tick()
		check(ski.nose_recovery_torque == Vector3.ZERO, "active Submarine remains unassisted")
	Input.action_release("rider_shift_forward")
	await _tick()
	check(not ski.submarine_system.is_dive_active() and not ski.nose_recovery_overridden, "release exits the trick and unblocks assistance")
	var first_resume := float(ski.get("_nose_recovery_resume"))
	check(first_resume > 0.0 and first_resume < 0.15, "assistance resumes gradually after release")
	var last_resume := first_resume
	for tick in 90:
		await _tick()
		var resume := float(ski.get("_nose_recovery_resume"))
		check(resume >= last_resume and ski.nose_recovery_torque.length() <= ski.nose_recovery_max_torque_nm + 0.01, "progressive bounded return")
		last_resume = resume
	check(last_resume == 1.0 and not ski.submarine_system.state.recovery_active, "assistance fully returns after trick exit")
	check(ski.nose_recovery_torque == Vector3.ZERO and absf(rad_to_deg(Pitch.world_pitch(ski.global_basis))) < 10.0,
		"flat-water rest needs no residual recovery torque")
	print("NOSE_RECOVERY_RELEASE: first blend=%.4f final=%.2f pitch=%.2f" % [first_resume, last_resume, rad_to_deg(Pitch.world_pitch(ski.global_basis))])
	_pose(-30.0, 12.0, 10.0, -0.5)
	for tick in 8:
		await _tick()
		check(ski.nose_recovery_torque == Vector3.ZERO and ski.nose_recovery_authority == 0.0, "no airborne correction")
	check(ski.mass == mass and ski.inertia == inertia and ski.drive_system.forward_engine_force == engine, "mass, inertia and engine unchanged")
	ski.water_physics_system.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.LEGACY_4POINT)
	_pose(-25.0, 0.1, 12.0, -1.0)
	for tick in 15:
		await _tick()
		check(ski.global_transform.is_finite() and ski.nose_recovery_torque.length() <= 6000.01,
			"LEGACY remains compatible with bounded wet assistance")
	print("NOSE_RECOVERY_SMOKE: %s errors=%d" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	if failures.is_empty(): scene.call("_close_gracefully")
	else: quit(1)
