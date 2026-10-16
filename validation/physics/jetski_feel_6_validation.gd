extends Node

const RUN_SECONDS := 30.0
const SETTLE_SECONDS := 10.0
const SETTLE_REVIEW_SECONDS := 5.0
const PRE_TAKEOFF_SECONDS := 0.25
const BASELINE_K := 4250.0
const CANDIDATE_K := 3500.0
const DAMPING_C := 1698.2
const TEST_SPEED_MPS := 18.0

var _running := false


func run(game_root: Node, requested_phase := -1.0) -> void:
	if _running:
		return
	_running = true
	var ski: JetSkiController = game_root.ski
	var physics: JetSkiWaterPhysicsSystem = ski.water_physics_system
	var ocean: Node = game_root.get_node_or_null("Production/Ocean/OpenOceanFFT")
	var authoring_ocean: Node = game_root.get_node_or_null("Production/Ocean")
	if ski == null or physics == null or ocean == null or authoring_ocean == null:
		push_error("FEEL-6 requires the Jetski, Water Race physics, Ocean, and OpenOceanFFT.")
		game_root.alignment_validation_running = false
		queue_free()
		return

	var saved_transform: Transform3D = ski.global_transform
	var saved_linear: Vector3 = ski.linear_velocity
	var saved_angular: Vector3 = ski.angular_velocity
	var saved_mass := ski.mass
	var saved_com := ski.center_of_mass
	var saved_inertia := ski.inertia
	var saved_c := physics.buoyancy_damping_per_point
	var saved_influence := physics.buoyancy_normal_influence
	var saved_takeoff_cleaner := physics.takeoff_assist_enabled
	var saved_anti_hop := physics.anti_hop_enabled
	var saved_deep_start := physics.deep_buoyancy_start_depth
	var saved_deep_strength := physics.deep_buoyancy_strength_per_point
	var saved_deep_limit := physics.deep_buoyancy_force_limit_per_meter
	var saved_force_cap := physics.max_buoyancy_force_per_point
	var saved_force_rise_cap := physics.max_buoyancy_force_rise_N_per_s
	var saved_diagnostics := physics.diagnostics_enabled
	var saved_force_debug := physics.force_debug_enabled
	var saved_advanced_diagnostics: bool = bool(game_root.get("advanced_diagnostics_enabled"))
	var saved_contact_debug: bool = bool(game_root.get("contact_debug"))
	var saved_wave_state: Dictionary = ocean.call("get_physics_wave_time_state")
	var saved_wave_time := float(ocean.call("get_wave_time"))
	var saved_wave_rate := float(saved_wave_state.get("wave_speed_multiplier", 1.0))
	var wind := float(authoring_ocean.get("wind_speed_mps"))
	var basis := saved_transform.basis.orthonormalized()
	var start_velocity := -basis.z * TEST_SPEED_MPS
	var phase := float(requested_phase) if requested_phase >= 0.0 else saved_wave_time
	var dt := 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	var config_errors := _baseline_config_errors(ski, physics, wind, saved_wave_rate)
	var run_results: Array[Dictionary] = []
	var accepted_12 := false
	var accepted_2x := false

	physics.diagnostics_enabled = false
	physics.force_debug_enabled = false
	_release_inputs()
	if config_errors.is_empty():
		var baseline := await _run_case(game_root, ski, physics, ocean, saved_transform,
			Vector3.ZERO, start_velocity, phase, 1.0, BASELINE_K, dt, "BASELINE")
		run_results.append(baseline)
		print("FEEL6 BASELINE PEAK FORCE LEDGER | " + JSON.stringify(baseline.get("peak_force_ledger", {})))
		print("FEEL6 BASELINE SUMMARY | " + JSON.stringify(_brief(baseline)))
		var candidate := await _run_case(game_root, ski, physics, ocean, saved_transform,
			Vector3.ZERO, start_velocity, phase, 1.0, CANDIDATE_K, dt, "CANDIDATE")
		run_results.append(candidate)
		accepted_12 = _candidate_passes(baseline, candidate)
		print("FEEL6 K A/B | " + JSON.stringify({
			"wave_speed": 1.0,
			"phase": phase,
			"baseline": _brief(baseline),
			"candidate": _brief(candidate),
			"candidate_passes": accepted_12,
			"acceptance_checks": _acceptance_checks(baseline, candidate),
		}))
		if accepted_12:
			var high_speed := await _run_case(game_root, ski, physics, ocean, saved_transform,
				Vector3.ZERO, start_velocity, phase, 2.0, CANDIDATE_K, dt, "CANDIDATE_WAVE2")
			run_results.append(high_speed)
			accepted_2x = _high_speed_case_passes(candidate, high_speed)
			print("FEEL6 CANDIDATE WAVE2 | " + JSON.stringify({
				"candidate_wave1": _brief(candidate),
				"candidate_wave2": _brief(high_speed),
				"no_serious_regression": accepted_2x,
			}))
	else:
		push_warning("FEEL-6 skipped: baseline contract mismatch: " + ", ".join(config_errors))

	var final_k := CANDIDATE_K if accepted_12 and accepted_2x else BASELINE_K
	_release_inputs()
	physics.buoyancy_strength_per_point = final_k
	physics.buoyancy_damping_per_point = saved_c
	physics.buoyancy_normal_influence = saved_influence
	physics.deep_buoyancy_start_depth = saved_deep_start
	physics.deep_buoyancy_strength_per_point = saved_deep_strength
	physics.deep_buoyancy_force_limit_per_meter = saved_deep_limit
	physics.max_buoyancy_force_per_point = saved_force_cap
	physics.max_buoyancy_force_rise_N_per_s = saved_force_rise_cap
	physics.takeoff_assist_enabled = saved_takeoff_cleaner
	physics.anti_hop_enabled = saved_anti_hop
	physics.diagnostics_enabled = saved_diagnostics
	physics.force_debug_enabled = saved_force_debug
	game_root.advanced_diagnostics_enabled = saved_advanced_diagnostics
	game_root.contact_debug = saved_contact_debug
	ocean.set("_wave_time", saved_wave_time)
	ocean.set("_previous_physics_wave_time", saved_wave_time)
	ocean.call("set_wave_speed_multiplier", saved_wave_rate)
	ski.freeze = true
	ski.call("_teleport_and_reset", saved_transform, &"feel_6_restore")
	ski.mass = saved_mass
	ski.center_of_mass = saved_com
	ski.inertia = saved_inertia
	ski.linear_velocity = saved_linear if saved_linear.is_finite() else Vector3.ZERO
	ski.angular_velocity = saved_angular if saved_angular.is_finite() else Vector3.ZERO
	ski.reset_physics_interpolation()
	ski.freeze = false
	var final_report := {
		"config_errors": config_errors,
		"wind_speed_mps": wind,
		"phase": phase,
		"wave_speed_1_candidate_passes": accepted_12,
		"wave_speed_2_candidate_passes": accepted_2x,
		"final_k": final_k,
		"damping_c": saved_c,
		"runs": run_results,
	}
	_write_results(run_results, final_report)
	print("FEEL6 FINAL | " + JSON.stringify({"candidate_accepted": accepted_12 and accepted_2x,
		"final_k": final_k, "c": saved_c, "report": final_report}))
	game_root.alignment_validation_running = false
	queue_free()


func _baseline_config_errors(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		wind: float, wave_rate: float) -> Array[String]:
	var errors: Array[String] = []
	if not is_equal_approx(ski.mass, 300.0): errors.append("mass is not 300 kg")
	if not ski.center_of_mass.is_equal_approx(Vector3(0.0, -0.22, 0.0)): errors.append("Water Race COM differs")
	if not ski.inertia.is_equal_approx(Vector3(208.087, 172.687, 62.884)): errors.append("combined inertia differs")
	if not physics.water_race_mode: errors.append("Water Race hull law is inactive")
	if not is_equal_approx(wind, 12.0): errors.append("wind is not 12 m/s")
	if not is_equal_approx(wave_rate, 1.0): errors.append("wave rate is not 1.0")
	if not is_equal_approx(physics.buoyancy_strength_per_point, BASELINE_K): errors.append("baseline K is not 4250")
	if not is_equal_approx(physics.buoyancy_damping_per_point, DAMPING_C): errors.append("damping is not 1698.2")
	if not is_equal_approx(physics.buoyancy_normal_influence, 0.50): errors.append("normal influence is not 0.50")
	if not physics.takeoff_assist_enabled: errors.append("takeoff cleaner is off")
	if physics.anti_hop_enabled: errors.append("anti-hop is on")
	return errors


func _run_case(game_root: Node, ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		ocean: Node, pose: Transform3D, _settled_velocity: Vector3, start_velocity: Vector3,
		phase: float, wave_rate: float, stiffness: float, dt: float, case_name: String) -> Dictionary:
	physics.buoyancy_strength_per_point = stiffness
	physics.buoyancy_damping_per_point = DAMPING_C
	var equilibrium := await _measure_equilibrium(game_root, ski, physics, ocean,
		pose, phase, wave_rate, dt)
	await _reset_test_state(ski, physics, ocean, pose, start_velocity, phase, wave_rate)
	game_root.begin_gameplay_audit_capture()
	_release_inputs()
	var tick_count := int(round(RUN_SECONDS / dt))
	var tick_rows: Array[Dictionary] = []
	var previous_velocity_y := ski.linear_velocity.y
	var previous_mask := physics.state.raw_contact_mask
	var pre_window: Array[Dictionary] = []
	var events: Array[Dictionary] = []
	var active_event: Dictionary = {}
	Input.action_press("throttle")
	for tick in tick_count:
		await get_tree().physics_frame
		var row := _sample_tick(ski, physics, dt, previous_velocity_y, tick)
		previous_velocity_y = ski.linear_velocity.y
		tick_rows.append(row)
		var mask := int(row.raw_contact_mask)
		if active_event.is_empty() and mask == 0 and previous_mask != 0:
			active_event = {"start_index": tick, "flight_rows": [], "pre_250ms": pre_window.duplicate(true),
				"maximum_clearance_m": 0.0, "airtime_s": 0.0}
		if not active_event.is_empty():
			if mask == 0:
				var flight: Array = active_event.flight_rows
				flight.append(row)
				active_event.flight_rows = flight
				active_event.maximum_clearance_m = maxf(float(active_event.maximum_clearance_m),
					float(row.maximum_contact_clearance_m))
			else:
				active_event.airtime_s = float(flight_count(active_event)) * dt
				events.append(_finish_event(active_event, dt))
				active_event = {}
		if mask != 0:
			pre_window.append(row)
			var pre_limit := maxi(1, int(round(PRE_TAKEOFF_SECONDS / dt)))
			while pre_window.size() > pre_limit: pre_window.pop_front()
		previous_mask = mask
	_release_inputs()
	if not active_event.is_empty():
		active_event.airtime_s = float(flight_count(active_event)) * dt
		events.append(_finish_event(active_event, dt))
	game_root.end_gameplay_audit_capture()
	var hull_rows: Array = game_root._gameplay_audit_rendered_hull_rows.duplicate(true)
	var body_metrics := _summarize_run(case_name, wave_rate, stiffness, tick_rows, events, hull_rows, dt)
	body_metrics["equilibrium"] = equilibrium
	body_metrics["tick_rows"] = tick_rows
	return body_metrics


func _measure_equilibrium(game_root: Node, ski: JetSkiController,
		physics: JetSkiWaterPhysicsSystem, ocean: Node, pose: Transform3D,
		phase: float, wave_rate: float, dt: float) -> Dictionary:
	await _reset_test_state(ski, physics, ocean, pose, Vector3.ZERO, phase, wave_rate)
	game_root.begin_gameplay_audit_capture()
	_release_inputs()
	var count := int(round(SETTLE_SECONDS / dt))
	var review_start := int(round((SETTLE_SECONDS - SETTLE_REVIEW_SECONDS) / dt))
	var mean_depths: Array[float] = []
	var maximum_depths: Array[float] = []
	for tick in count:
		await get_tree().physics_frame
		if tick >= review_start and physics.state.submerged_point_count > 0:
			mean_depths.append(physics.state.average_depth)
			maximum_depths.append(physics.state.maximum_depth)
	game_root.end_gameplay_audit_capture()
	var hull_rows: Array = game_root._gameplay_audit_rendered_hull_rows.duplicate(true)
	var all_hull_clearances := _hull_clearance_values(hull_rows)
	var hull_clearances: Array[float] = []
	var clearance_start := int(all_hull_clearances.size() * 0.5)
	for clearance_index in range(clearance_start, all_hull_clearances.size()):
		hull_clearances.append(all_hull_clearances[clearance_index])
	return {
		"window_seconds": SETTLE_REVIEW_SECONDS,
		"mean_supported_depth_m": _metrics(mean_depths),
		"maximum_contact_depth_m": _metrics(maximum_depths),
		"rendered_hull_signed_clearance_m": _metrics(hull_clearances),
		"rendered_hull_max_penetration_m": _maximum_penetration(hull_clearances),
	}


func _reset_test_state(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		ocean: Node, pose: Transform3D, velocity: Vector3, phase: float, wave_rate: float) -> void:
	_release_inputs()
	ski.freeze = true
	ski.call("_teleport_and_reset", pose, &"feel_6_phase_lock")
	physics.reset_runtime_state()
	physics.reset_takeoff_validation_history()
	ocean.call("set_wave_speed_multiplier", 0.0)
	await get_tree().physics_frame
	ocean.set("_wave_time", phase)
	ocean.set("_previous_physics_wave_time", phase)
	ocean.call("set_wave_speed_multiplier", wave_rate)
	ski.global_transform = pose
	ski.linear_velocity = velocity
	ski.angular_velocity = Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	ski.freeze = false


func _sample_tick(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		dt: float, previous_velocity_y: float, elapsed_tick: int) -> Dictionary:
	var acceleration := (ski.linear_velocity.y - previous_velocity_y) / maxf(dt, 0.000001)
	var raw_spring := 0.0
	var raw_shallow_spring := 0.0
	var raw_damping := 0.0
	var raw_deep_support := 0.0
	var shallow_post_clamp := 0.0
	var deep_post_clamp := 0.0
	var damping_post_clamp := 0.0
	var support_final := 0.0
	var force_cap_count := 0
	var deep_contact_count := 0
	var contacts: Array[Dictionary] = []
	for index in physics.point_spring_forces.size():
		var spring := float(physics.point_spring_forces[index])
		var damping := float(physics.point_damping_forces[index])
		var depth := float(physics.effective_point_depths[index]) if index < physics.effective_point_depths.size() else 0.0
		var deep_depth := maxf(depth - physics.deep_buoyancy_start_depth, 0.0)
		var deep := minf(physics.deep_buoyancy_strength_per_point * deep_depth,
			physics.deep_buoyancy_force_limit_per_meter * deep_depth)
		var shallow := maxf(spring - deep, 0.0)
		var uncapped := spring + damping
		var final_force := float(physics.point_normal_forces[index])
		var scale_after_caps := final_force / uncapped if uncapped > 0.0001 else 0.0
		var post_shallow := shallow * scale_after_caps
		var post_deep := deep * scale_after_caps
		var post_damping := damping * scale_after_caps
		raw_spring += spring
		raw_shallow_spring += shallow
		raw_damping += damping
		raw_deep_support += deep
		shallow_post_clamp += post_shallow
		deep_post_clamp += post_deep
		damping_post_clamp += post_damping
		support_final += final_force
		if index < physics.point_force_clamp_reached.size() and physics.point_force_clamp_reached[index]: force_cap_count += 1
		if deep > 0.0: deep_contact_count += 1
		contacts.append({"contact": physics.POINT_NAMES[index], "support_depth_m": depth,
			"raw_shallow_spring_n": shallow, "raw_deep_support_n": deep,
			"raw_water_relative_damping_n": damping, "raw_uncapped_total_n": uncapped,
			"force_cap_reached": index < physics.point_force_clamp_reached.size() and physics.point_force_clamp_reached[index],
			"post_clamp_shallow_spring_n": post_shallow, "post_clamp_deep_support_n": post_deep,
			"post_clamp_damping_n": post_damping, "actual_post_clamp_support_n": final_force})
	var gravity_force_y := physics.audit_last_total_gravity.y * ski.mass
	var buoyancy_force_y := physics.total_buoyancy_force_vector.y
	var drag_force_y: float = _sum_drag_force_y(physics)
	var propulsion_y := ski.drive_system.state.propulsion_force_vector.y
	var coasting_y := ski.drive_system.state.coasting_steering_force_vector.y
	var constant_force_y := ski.constant_force.y
	var linear_damping_force_y := -ski.mass * ski.linear_damp * ski.linear_velocity.y
	var contact_impulse: Vector3 = ski.navigation_system.state.physical_contact_impulse
	var contact_force_equivalent_y := contact_impulse.y / maxf(dt, 0.000001)
	var required_net_force_y := ski.mass * acceleration
	var accounted_force_y: float = gravity_force_y + buoyancy_force_y + drag_force_y + propulsion_y + coasting_y + constant_force_y + linear_damping_force_y + contact_force_equivalent_y
	var max_clearance := 0.0
	for depth in physics.point_depths:
		max_clearance = maxf(max_clearance, maxf(-float(depth), 0.0))
	var forward := -ski.global_transform.basis.z.normalized()
	return {
		"tick": Engine.get_physics_frames(), "elapsed_tick": elapsed_tick, "elapsed_s": float(elapsed_tick) * dt, "mass_kg": ski.mass,
		"vertical_velocity_mps": ski.linear_velocity.y, "vertical_acceleration_mps2": acceleration,
		"forward_speed_mps": ski.linear_velocity.dot(forward), "raw_contact_mask": physics.state.raw_contact_mask,
		"wet_contacts": physics.wet_contact_count, "supported_contacts": physics.supported_contact_count,
		"average_depth_m": physics.state.average_depth, "maximum_depth_m": physics.state.maximum_depth,
		"maximum_contact_clearance_m": max_clearance,
		"raw_spring_n": raw_spring, "raw_shallow_spring_n": raw_shallow_spring,
		"raw_deep_support_n": raw_deep_support, "post_clamp_shallow_spring_n": shallow_post_clamp,
		"post_clamp_deep_support_n": deep_post_clamp, "raw_damping_n": raw_damping,
		"post_clamp_damping_n": damping_post_clamp, "final_support_magnitude_n": support_final,
		"buoyancy_force_y_n": buoyancy_force_y, "hydrodynamic_drag_force_y_n": drag_force_y,
		"propulsion_force_y_n": propulsion_y, "coasting_steering_force_y_n": coasting_y,
		"constant_force_y_n": constant_force_y, "linear_damping_force_y_n": linear_damping_force_y, "gravity_force_y_n": gravity_force_y,
		"contact_impulse_n_s": contact_impulse, "contact_force_equivalent_y_n": contact_force_equivalent_y,
		"physical_contact_count": ski.physical_contact_count,
		"physical_contact_delta_velocity_mps": ski.physical_contact_delta_velocity,
		"required_net_force_y_n": required_net_force_y,
		"force_balance_residual_y_n": required_net_force_y - accounted_force_y,
		"force_cap_contact_count": force_cap_count, "deep_support_contact_count": deep_contact_count,
		"deep_support_frame_active": deep_contact_count > 0, "contacts": contacts,
		"linear_damp": ski.linear_damp, "arcade_continuity_enabled": ski.use_arcade_turn_continuity,
	}


func _sum_drag_force_y(physics: JetSkiWaterPhysicsSystem) -> float:
	var total := 0.0
	for force in physics.point_forward_drag_forces:
		total += force.y
	for force in physics.point_lateral_drag_forces:
		total += force.y
	return total


func _finish_event(event: Dictionary, dt: float) -> Dictionary:
	var flight: Array = event.flight_rows
	var maximum_clearance := float(event.maximum_clearance_m)
	var airtime := float(event.airtime_s)
	var pre: Array = event.pre_250ms
	var raw_spring_impulse := _sum_rows(pre, "raw_spring_n") * dt
	var deep_support_impulse := _sum_rows(pre, "raw_deep_support_n") * dt
	var actual_spring_impulse := _sum_rows(pre, "post_clamp_shallow_spring_n") * dt
	actual_spring_impulse += _sum_rows(pre, "post_clamp_deep_support_n") * dt
	var raw_damping_signed_impulse := _sum_rows(pre, "raw_damping_n") * dt
	var actual_damping_signed_impulse := _sum_rows(pre, "post_clamp_damping_n") * dt
	var positive_damping_impulse := 0.0
	for row in pre: positive_damping_impulse += maxf(float(row.get("post_clamp_damping_n", 0.0)), 0.0) * dt
	var classification := "MICRO_HOP" if maximum_clearance <= 0.30 and airtime <= 0.08 else (
		"LARGE_JUMP" if maximum_clearance >= 1.0 or airtime >= 0.65 else "SMALL_JUMP")
	return {"start_tick": event.start_index, "airtime_s": airtime,
		"maximum_clearance_m": maximum_clearance, "classification": classification,
		"unwanted": maximum_clearance >= 0.5 and airtime >= 0.25,
		"raw_spring_impulse_Ns": raw_spring_impulse,
		"actual_spring_impulse_Ns": actual_spring_impulse,
		"deep_support_impulse_Ns": deep_support_impulse,
		"raw_damping_signed_impulse_Ns": raw_damping_signed_impulse,
		"actual_damping_signed_impulse_Ns": actual_damping_signed_impulse,
		"positive_damping_impulse_Ns": positive_damping_impulse,
		"peak_upward_acceleration_mps2": _array_max(flight, "vertical_acceleration_mps2"),
		"force_cap_ticks_pre_takeoff": _sum_rows(pre, "force_cap_contact_count"),
		"deep_support_ticks_pre_takeoff": _count_positive(pre, "deep_support_contact_count"),
		"pre_250ms": pre}


func _summarize_run(case_name: String, wave_rate: float, stiffness: float, rows: Array[Dictionary],
		events: Array[Dictionary], hull_rows: Array, dt: float) -> Dictionary:
	var upward_acceleration: Array[float] = []
	var signed_acceleration: Array[float] = []
	var forward_speeds: Array[float] = []
	var supported_depths: Array[float] = []
	var maximum_depths: Array[float] = []
	var cap_contacts := 0
	var deep_frames := 0
	var airborne_count := 0
	var worst: Dictionary = {}
	for row in rows:
		var acceleration := float(row.vertical_acceleration_mps2)
		signed_acceleration.append(acceleration)
		upward_acceleration.append(maxf(acceleration, 0.0))
		forward_speeds.append(float(row.forward_speed_mps))
		if int(row.raw_contact_mask) == 0: airborne_count += 1
		if int(row.wet_contacts) > 0: supported_depths.append(float(row.average_depth_m))
		maximum_depths.append(float(row.maximum_depth_m))
		cap_contacts += int(row.force_cap_contact_count)
		if bool(row.deep_support_frame_active): deep_frames += 1
		if worst.is_empty() or acceleration > float(worst.get("vertical_acceleration_mps2", -INF)):
			worst = row
	var unwanted := 0
	var micro := 0
	var small := 0
	var large := 0
	var large_clearances: Array[float] = []
	var spring_impulses: Array[float] = []
	var damping_impulses: Array[float] = []
	for event in events:
		if bool(event.unwanted): unwanted += 1
		match str(event.classification):
			"MICRO_HOP": micro += 1
			"SMALL_JUMP": small += 1
			"LARGE_JUMP":
				large += 1
				large_clearances.append(float(event.maximum_clearance_m))
		if bool(event.unwanted):
			spring_impulses.append(float(event.actual_spring_impulse_Ns))
			damping_impulses.append(float(event.actual_damping_signed_impulse_Ns))
	var hull_clearances := _hull_clearance_values(hull_rows)
	var sustained_speeds: Array[float] = []
	var tail_start := maxi(0, rows.size() - int(round(5.0 / dt)))
	for i in range(tail_start, rows.size()): sustained_speeds.append(float(rows[i].forward_speed_mps))
	return {
		"name": case_name, "wave_speed": wave_rate, "K": stiffness, "C": DAMPING_C,
		"ticks": rows.size(), "airborne_transitions": events.size(),
		"unwanted_jumps": unwanted, "micro_hops": micro, "small_jumps": small, "large_jumps": large,
		"airborne_percent": 100.0 * float(airborne_count) / maxf(float(rows.size()), 1.0),
		"maximum_clearance_m": _array_max(events, "maximum_clearance_m"),
		"largest_legitimate_jump_clearance_m": _max_float_array(large_clearances),
		"upward_acceleration_mps2": _metrics(upward_acceleration),
		"signed_vertical_acceleration_mps2": _metrics(signed_acceleration),
		"average_forward_speed_mps": _metrics(forward_speeds),
		"sustained_forward_speed_last5s_mps": _metrics(sustained_speeds),
		"supported_mean_depth_m": _metrics(supported_depths),
		"maximum_contact_depth_m": _metrics(maximum_depths),
		"rendered_hull_signed_clearance_m": _metrics(hull_clearances),
		"rendered_hull_max_penetration_m": _maximum_penetration(hull_clearances),
		"rendered_hull_samples": hull_clearances.size(),
		"deep_support_active_frames": deep_frames,
		"deep_support_active_percent": 100.0 * float(deep_frames) / maxf(float(rows.size()), 1.0),
		"force_cap_contact_samples": cap_contacts,
		"unwanted_pre_takeoff_actual_spring_impulse_Ns": _metrics(spring_impulses),
		"unwanted_pre_takeoff_actual_damping_signed_impulse_Ns": _metrics(damping_impulses),
		"peak_force_ledger": _peak_force_ledger(worst),
		"events": events,
	}


func _peak_force_ledger(row: Dictionary) -> Dictionary:
	if row.is_empty(): return {}
	return {"tick": row.tick, "elapsed_s": row.elapsed_s,
		"vertical_velocity_mps": row.vertical_velocity_mps,
		"vertical_acceleration_mps2": row.vertical_acceleration_mps2,
		"mass_kg": row.mass_kg,
		"required_net_force_y_n": row.required_net_force_y_n,
		"gravity_force_y_n": row.gravity_force_y_n,
		"raw_spring_n": row.raw_spring_n,
		"raw_shallow_spring_n": row.raw_shallow_spring_n,
		"raw_deep_support_n": row.raw_deep_support_n,
		"raw_damping_n": row.raw_damping_n,
		"post_clamp_shallow_spring_n": row.post_clamp_shallow_spring_n,
		"post_clamp_deep_support_n": row.post_clamp_deep_support_n,
		"post_clamp_damping_n": row.post_clamp_damping_n,
		"actual_buoyancy_force_y_n": row.buoyancy_force_y_n,
		"hydrodynamic_drag_force_y_n": row.hydrodynamic_drag_force_y_n,
		"propulsion_force_y_n": row.propulsion_force_y_n,
		"coasting_steering_force_y_n": row.coasting_steering_force_y_n,
		"constant_force_y_n": row.constant_force_y_n, "linear_damping_force_y_n": row.linear_damping_force_y_n,
		"physical_contact_count": row.physical_contact_count,
		"physical_contact_impulse_n_s": row.contact_impulse_n_s,
		"contact_force_equivalent_y_n": row.contact_force_equivalent_y_n,
		"force_balance_residual_y_n": row.force_balance_residual_y_n,
		"force_cap_contact_count": row.force_cap_contact_count,
		"deep_support_contact_count": row.deep_support_contact_count,
		"average_depth_m": row.average_depth_m,
		"maximum_depth_m": row.maximum_depth_m,
		"contacts": row.contacts}


func _candidate_passes(baseline: Dictionary, candidate: Dictionary) -> bool:
	var checks := _acceptance_checks(baseline, candidate)
	for key in checks:
		if not bool(checks[key]): return false
	return true


func _acceptance_checks(baseline: Dictionary, candidate: Dictionary) -> Dictionary:
	var base_unwanted := int(baseline.get("unwanted_jumps", 0))
	var candidate_unwanted := int(candidate.get("unwanted_jumps", 0))
	var base_accel: Dictionary = baseline.get("upward_acceleration_mps2", {})
	var candidate_accel: Dictionary = candidate.get("upward_acceleration_mps2", {})
	var base_speed := float(baseline.get("average_forward_speed_mps", {}).get("mean", 0.0))
	var candidate_speed := float(candidate.get("average_forward_speed_mps", {}).get("mean", 0.0))
	var base_depth := float(baseline.get("supported_mean_depth_m", {}).get("mean", 0.0))
	var candidate_depth := float(candidate.get("supported_mean_depth_m", {}).get("mean", 0.0))
	var base_penetration := float(baseline.get("rendered_hull_max_penetration_m", 0.0))
	var candidate_penetration := float(candidate.get("rendered_hull_max_penetration_m", 0.0))
	var base_deep_percent := float(baseline.get("deep_support_active_percent", 0.0))
	var candidate_deep_percent := float(candidate.get("deep_support_active_percent", 0.0))
	var base_large := int(baseline.get("large_jumps", 0))
	var candidate_large := int(candidate.get("large_jumps", 0))
	var base_large_clearance := float(baseline.get("largest_legitimate_jump_clearance_m", 0.0))
	var candidate_large_clearance := float(candidate.get("largest_legitimate_jump_clearance_m", 0.0))
	return {
		"unwanted_jumps_reduced_at_least_25_percent": base_unwanted > 0 and candidate_unwanted <= int(floor(float(base_unwanted) * 0.75)),
		"micro_hops_not_increased": int(candidate.get("micro_hops", 0)) <= int(baseline.get("micro_hops", 0)),
		"upward_acceleration_p95_not_higher": float(candidate_accel.get("p95", 0.0)) <= float(base_accel.get("p95", 0.0)) + 0.1,
		"upward_acceleration_max_not_higher": float(candidate_accel.get("max", 0.0)) <= float(base_accel.get("max", 0.0)) + 0.1,
		"large_jumps_preserved": candidate_large >= maxi(0, base_large - 1) and (base_large == 0 or candidate_large_clearance >= base_large_clearance * 0.8),
		"average_forward_speed_within_5_percent": candidate_speed >= base_speed * 0.95,
		"mean_immersion_increase_at_most_0_15m": candidate_depth <= base_depth + 0.15,
		"maximum_hull_penetration_increase_at_most_0_15m": candidate_penetration <= base_penetration + 0.15,
		"deep_support_engagement_increase_at_most_10_points": candidate_deep_percent <= base_deep_percent + 10.0,
	}


func _high_speed_case_passes(wave1: Dictionary, wave2: Dictionary) -> bool:
	var a1: Dictionary = wave1.get("upward_acceleration_mps2", {})
	var a2: Dictionary = wave2.get("upward_acceleration_mps2", {})
	var speed1 := float(wave1.get("average_forward_speed_mps", {}).get("mean", 0.0))
	var speed2 := float(wave2.get("average_forward_speed_mps", {}).get("mean", 0.0))
	return (float(a2.get("max", 0.0)) <= maxf(float(a1.get("max", 0.0)) * 1.5, float(a1.get("max", 0.0)) + 5.0)
		and speed2 >= speed1 * 0.90
		and float(wave2.get("rendered_hull_max_penetration_m", 0.0)) <= float(wave1.get("rendered_hull_max_penetration_m", 0.0)) + 0.30)


func _brief(row: Dictionary) -> Dictionary:
	return {"name": row.get("name"), "wave_speed": row.get("wave_speed"), "K": row.get("K"),
		"airborne_transitions": row.get("airborne_transitions"), "unwanted_jumps": row.get("unwanted_jumps"),
		"micro_hops": row.get("micro_hops"), "large_jumps": row.get("large_jumps"),
		"airborne_percent": row.get("airborne_percent"), "maximum_clearance_m": row.get("maximum_clearance_m"),
		"upward_acceleration_mps2": row.get("upward_acceleration_mps2"),
		"average_forward_speed_mps": row.get("average_forward_speed_mps"),
		"sustained_forward_speed_last5s_mps": row.get("sustained_forward_speed_last5s_mps"),
		"supported_mean_depth_m": row.get("supported_mean_depth_m"),
		"rendered_hull_max_penetration_m": row.get("rendered_hull_max_penetration_m"),
		"deep_support_active_percent": row.get("deep_support_active_percent"),
		"force_cap_contact_samples": row.get("force_cap_contact_samples"),
		"unwanted_pre_takeoff_actual_spring_impulse_Ns": row.get("unwanted_pre_takeoff_actual_spring_impulse_Ns"),
		"unwanted_pre_takeoff_actual_damping_signed_impulse_Ns": row.get("unwanted_pre_takeoff_actual_damping_signed_impulse_Ns"),
		"peak_force_ledger": row.get("peak_force_ledger"), "equilibrium": row.get("equilibrium")}


func _write_results(runs: Array[Dictionary], report: Dictionary) -> void:
	var summary_file := FileAccess.open("res://validation/physics/FEEL6_RESULTS.json", FileAccess.WRITE)
	if summary_file != null:
		var compact_runs: Array[Dictionary] = []
		for run_row in runs: compact_runs.append(_brief(run_row))
		summary_file.store_string(JSON.stringify({"report": report, "runs": compact_runs}, "\t"))
		summary_file.close()
	var csv := FileAccess.open("res://validation/physics/FEEL6_FORCE_TRACE.csv", FileAccess.WRITE)
	if csv == null: return
	csv.store_line("mode,wave_speed,K,tick,elapsed_s,vertical_velocity_mps,vertical_acceleration_mps2,forward_speed_mps,raw_spring_n,raw_deep_support_n,raw_damping_n,post_clamp_shallow_spring_n,post_clamp_deep_support_n,post_clamp_damping_n,final_support_n,buoyancy_y_n,hydrodynamic_drag_y_n,propulsion_y_n,gravity_y_n,contact_count,contact_impulse_y_n_s,contact_force_equivalent_y_n,required_net_force_y_n,force_balance_residual_y_n,average_depth_m,maximum_depth_m,deep_contacts,force_cap_contacts,raw_contact_mask,contacts_json")
	for run_row in runs:
		for row in run_row.get("tick_rows", []):
			var contact_impulse: Vector3 = row.get("contact_impulse_n_s", Vector3.ZERO)
			var contacts_json := JSON.stringify(row.get("contacts", [])).replace("\"", "\"\"")
			csv.store_line(",".join([
				str(run_row.get("name")), str(run_row.get("wave_speed")), str(run_row.get("K")), str(row.get("tick")),
				"%.6f" % float(row.get("elapsed_s", 0.0)), "%.6f" % float(row.get("vertical_velocity_mps", 0.0)),
				"%.6f" % float(row.get("vertical_acceleration_mps2", 0.0)), "%.6f" % float(row.get("forward_speed_mps", 0.0)),
				"%.3f" % float(row.get("raw_spring_n", 0.0)), "%.3f" % float(row.get("raw_deep_support_n", 0.0)),
				"%.3f" % float(row.get("raw_damping_n", 0.0)), "%.3f" % float(row.get("post_clamp_shallow_spring_n", 0.0)),
				"%.3f" % float(row.get("post_clamp_deep_support_n", 0.0)), "%.3f" % float(row.get("post_clamp_damping_n", 0.0)),
				"%.3f" % float(row.get("final_support_magnitude_n", 0.0)), "%.3f" % float(row.get("buoyancy_force_y_n", 0.0)),
				"%.3f" % float(row.get("hydrodynamic_drag_force_y_n", 0.0)), "%.3f" % float(row.get("propulsion_force_y_n", 0.0)),
				"%.3f" % float(row.get("gravity_force_y_n", 0.0)), str(row.get("physical_contact_count", 0)),
				"%.6f" % contact_impulse.y,
				"%.3f" % float(row.get("contact_force_equivalent_y_n", 0.0)), "%.3f" % float(row.get("required_net_force_y_n", 0.0)),
				"%.3f" % float(row.get("force_balance_residual_y_n", 0.0)), "%.4f" % float(row.get("average_depth_m", 0.0)),
				"%.4f" % float(row.get("maximum_depth_m", 0.0)), str(row.get("deep_support_contact_count", 0)),
				str(row.get("force_cap_contact_count", 0)), str(row.get("raw_contact_mask", 0)), "\"%s\"" % contacts_json,
			]))
	csv.close()


func _hull_clearance_values(rows: Array) -> Array[float]:
	var values: Array[float] = []
	for row in rows:
		if row is Dictionary and row.has("hull_minus_direct_m"):
			values.append(float(row.hull_minus_direct_m))
	return values


func _maximum_penetration(clearances: Array[float]) -> float:
	var result := 0.0
	for value in clearances: result = maxf(result, -value)
	return maxf(result, 0.0)


func _metrics(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0, "min": 0.0, "count": 0}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in values: total += value
	var p95_index := mini(ordered.size() - 1, int(ceil(float(ordered.size() - 1) * 0.95)))
	return {"mean": total / float(values.size()), "p95": ordered[p95_index],
		"max": ordered[-1], "min": ordered[0], "count": values.size()}


func _array_max(rows: Array, key: String) -> float:
	var value := 0.0
	for row in rows: value = maxf(value, float(row.get(key, 0.0)))
	return value


func _max_float_array(values: Array[float]) -> float:
	var value := 0.0
	for item in values: value = maxf(value, item)
	return value


func _sum_rows(rows: Array, key: String) -> float:
	var value := 0.0
	for row in rows: value += float(row.get(key, 0.0))
	return value


func _count_positive(rows: Array, key: String) -> int:
	var count := 0
	for row in rows:
		if float(row.get(key, 0.0)) > 0.0: count += 1
	return count


func flight_count(event: Dictionary) -> int:
	return (event.flight_rows as Array).size()


func _release_inputs() -> void:
	for action in ["throttle", "brake", "steer_left", "steer_right", "rider_shift_left", "rider_shift_right"]:
		if InputMap.has_action(action): Input.action_release(action)

