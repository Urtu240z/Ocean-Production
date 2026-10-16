extends Node

const RUN_SECONDS := 30.0
const TEST_SPEED_MPS := 18.0
const PRE_WINDOW_SECONDS := 0.2
const POST_WINDOW_SECONDS := 0.5

var _running := false


func run(game_root: Node, requested_phase_1 := -1.0, requested_phase_2 := -1.0) -> void:
	if _running:
		return
	_running = true
	var ski: JetSkiController = game_root.ski
	var physics: JetSkiWaterPhysicsSystem = ski.water_physics_system
	var ocean: Node = game_root.get_node_or_null("Production/Ocean/OpenOceanFFT")
	if ski == null or physics == null or ocean == null:
		push_error("FEEL-5 validation requires the Jetski, water physics, and OpenOceanFFT.")
		game_root.alignment_validation_running = false
		queue_free()
		return
	var saved_transform := ski.global_transform
	var saved_linear := ski.linear_velocity
	var saved_angular := ski.angular_velocity
	var saved_clock_state: Dictionary = ocean.call("get_physics_wave_time_state")
	var saved_speed := float(saved_clock_state.get("wave_speed_multiplier", 1.0))
	var saved_wave_time := float(ocean.call("get_wave_time"))
	var saved_ocean_process := ocean.is_processing()
	var saved_ocean_physics_process := ocean.is_physics_processing()
	var saved_k := physics.buoyancy_strength_per_point
	var saved_c := physics.buoyancy_damping_per_point
	var saved_influence := physics.buoyancy_normal_influence
	var saved_takeoff_cleaner := physics.takeoff_assist_enabled
	var saved_anti_hop := physics.anti_hop_enabled
	var initial_basis := saved_transform.basis.orthonormalized()
	var forward := -initial_basis.z
	var initial_pose := saved_transform
	var initial_velocity := forward * TEST_SPEED_MPS
	var run_rows: Array[Dictionary] = []
	var requested_phases := [requested_phase_1, requested_phase_2]
	physics.diagnostics_enabled = false
	physics.force_debug_enabled = false
	_release_inputs()
	ski.freeze = true
	for rate_index in 2:
		var wave_rate := 1.0 if rate_index == 0 else 2.0
		ocean.call("set_wave_speed_multiplier", 0.0)
		await get_tree().physics_frame
		var phase := float(requested_phases[rate_index]) if float(requested_phases[rate_index]) >= 0.0 else float(ocean.call("get_wave_time"))
		ocean.set("_wave_time", phase)
		ocean.set("_previous_physics_wave_time", phase)
		ocean.call("set_wave_speed_multiplier", wave_rate)
		var baseline := await _run_pass(ski, physics, ocean, initial_pose, initial_velocity, phase, wave_rate, false)
		var candidate := await _run_pass(ski, physics, ocean, initial_pose, initial_velocity, phase, wave_rate, true)
		baseline["mode"] = "OFF"
		candidate["mode"] = "ON"
		run_rows.append({"baseline": baseline, "candidate": candidate})
		print("FEEL5 AB | wave_rate=%.1f | phase=%.6f | OFF %s | ON %s | FPS=%d" % [
			wave_rate, phase, JSON.stringify(_brief_pass(baseline)), JSON.stringify(_brief_pass(candidate)),
			Engine.get_frames_per_second()])
		var file := FileAccess.open("user://jetski_feel5_ab_wave_%.1f.json" % wave_rate, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(run_rows[-1], "\t"))
			file.close()
	_release_inputs()
	physics.buoyancy_strength_per_point = saved_k
	physics.buoyancy_damping_per_point = saved_c
	physics.buoyancy_normal_influence = saved_influence
	physics.takeoff_assist_enabled = saved_takeoff_cleaner
	physics.anti_hop_enabled = saved_anti_hop
	ocean.set("_wave_time", saved_wave_time)
	ocean.set("_previous_physics_wave_time", saved_wave_time)
	ocean.call("set_wave_speed_multiplier", saved_speed)
	ocean.set_process(saved_ocean_process)
	ocean.set_physics_process(saved_ocean_physics_process)
	ski.freeze = true
	ski.call("_teleport_and_reset", saved_transform, &"feel_5_restore")
	ski.linear_velocity = saved_linear if saved_linear.is_finite() else Vector3.ZERO
	ski.angular_velocity = saved_angular if saved_angular.is_finite() else Vector3.ZERO
	ski.reset_physics_interpolation()
	ski.freeze = false
	print("FEEL5 BASELINE END | passes=%d | physics parameters restored | transform and velocities restored" % run_rows.size())
	game_root.alignment_validation_running = false
	queue_free()


func _run_pass(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		ocean: Node, pose: Transform3D, velocity: Vector3, phase: float,
		wave_rate: float, candidate: bool) -> Dictionary:
	_release_inputs()
	ski.freeze = true
	ski.call("_teleport_and_reset", pose, &"feel_5_baseline")
	physics.reset_runtime_state()
	physics.reset_takeoff_validation_history()
	physics.set_anti_hop_enabled(candidate)
	ocean.set("_wave_time", phase)
	ocean.set("_previous_physics_wave_time", phase)
	ocean.call("set_wave_speed_multiplier", wave_rate)
	await get_tree().physics_frame
	ski.global_transform = pose
	ski.linear_velocity = velocity
	ski.angular_velocity = Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	ski.freeze = false
	Input.action_press("throttle")
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var tick_count := int(round(RUN_SECONDS / dt))
	var prior_velocity_y := ski.linear_velocity.y
	var pre_window: Array[Dictionary] = []
	var active_event: Dictionary = {}
	var events: Array[Dictionary] = []
	var last_mask := physics.state.raw_contact_mask
	var airborne_ticks := 0
	var average_speed_sum := 0.0
	var speed_samples := 0
	var frame_times_ms: Array[float] = []
	var started_msec := Time.get_ticks_msec()
	for tick in tick_count:
		await get_tree().physics_frame
		var sample := _sample_tick(ski, physics, dt, prior_velocity_y)
		prior_velocity_y = ski.linear_velocity.y
		average_speed_sum += absf(float(sample.forward_speed_mps))
		speed_samples += 1
		if int(sample.raw_contact_mask) == 0:
			airborne_ticks += 1
		if active_event.is_empty() and int(sample.raw_contact_mask) == 0 and last_mask != 0:
			active_event = {"start_tick": tick, "pre_supported_200ms": pre_window.duplicate(true),
				"flight_samples": [], "post_supported_500ms": [], "airtime_s": 0.0,
				"touched_down": false, "post_ticks": 0, "max_clearance_m": 0.0,
				"max_vertical_acceleration_mps2": 0.0, "last_contact_force_n": 0.0,
				"last_contact_impulse_n_s": 0.0, "launch_vertical_velocity_mps": float(ski.linear_velocity.y),
				"pre_forward_speed_mps": _window_mean(pre_window, "forward_speed_mps"),
				"peak_pitch_deg": 0.0}
			if not pre_window.is_empty():
				active_event.last_contact_impulse_n_s = pre_window[-1].last_contact_buoyancy_impulse_n_s
		if not active_event.is_empty():
			if not bool(active_event.touched_down):
				active_event.flight_samples.append(sample)
				active_event.max_clearance_m = maxf(float(active_event.max_clearance_m), float(sample.clearance_m))
				active_event.max_vertical_acceleration_mps2 = maxf(float(active_event.max_vertical_acceleration_mps2), float(sample.vertical_acceleration_mps2))
				active_event.peak_pitch_deg = maxf(float(active_event.peak_pitch_deg), absf(float(sample.pitch_deg)))
				if int(sample.raw_contact_mask) != 0:
					active_event.touched_down = true
					active_event.airtime_s = (tick - int(active_event.start_tick) + 1) * dt
					active_event.touchdown_forward_speed_mps = sample.forward_speed_mps
			else:
				active_event.post_supported_500ms.append(sample)
				active_event.post_ticks = int(active_event.post_ticks) + 1
				if int(active_event.post_ticks) >= int(round(POST_WINDOW_SECONDS / dt)):
					var event := _finish_event(active_event, dt)
					events.append(event)
					active_event = {}
		if int(sample.raw_contact_mask) != 0:
			pre_window.append(sample)
			while pre_window.size() > int(round(PRE_WINDOW_SECONDS / dt)):
				pre_window.pop_front()
		last_mask = int(sample.raw_contact_mask)
		frame_times_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_release_inputs()
	if not active_event.is_empty():
		if not bool(active_event.touched_down):
			active_event.airtime_s = (tick_count - int(active_event.start_tick)) * dt
		active_event["incomplete_post_window"] = true
		events.append(_finish_event(active_event, dt))
	var total_msec := maxi(1, Time.get_ticks_msec() - started_msec)
	var classified := _classify_events(events)
	return {"wave_rate": wave_rate, "phase": phase, "duration_s": RUN_SECONDS,
		"event_count": events.size(), "airborne_percent": 100.0 * float(airborne_ticks) / float(tick_count),
		"average_forward_speed_mps": average_speed_sum / maxf(float(speed_samples), 1.0),
		"micro_hops": classified.micro, "small_jumps": classified.small, "large_jumps": classified.large,
		"events": events, "physics_time_ms": _stats(frame_times_ms),
		"wall_duration_s": float(total_msec) / 1000.0,
		"fps": Engine.get_frames_per_second(),
		"anti_hop_interventions": physics.anti_hop_intervention_count,
		"propulsion_grace_ticks": physics.propulsion_grace_intervention_count}


func _sample_tick(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		dt: float, prior_velocity_y: float) -> Dictionary:
	var basis := ski.global_transform.basis.orthonormalized()
	var local_points: PackedVector3Array = physics.get_buoyancy_local_points()
	var depths: PackedFloat32Array = physics.get_buoyancy_point_depths()
	var points: PackedVector3Array = physics.point_water_surface_positions
	var water_v: PackedVector3Array = physics.point_water_velocities
	var forces: PackedFloat32Array = physics.point_normal_forces
	var force_vectors: PackedVector3Array = physics.point_buoyancy_force_vectors
	var relative_vertical := 0.0
	var water_vertical := 0.0
	var hull_vertical := 0.0
	var maximum_upward_water_velocity := 0.0
	var front_force := 0.0
	var rear_force := 0.0
	var front_vertical_force := 0.0
	var rear_vertical_force := 0.0
	var clearance := 0.0
	var n := mini(4, mini(local_points.size(), mini(points.size(), mini(water_v.size(), depths.size()))))
	for i in n:
		var world_point := ski.global_transform * local_points[i]
		var hull_velocity := ski.linear_velocity + ski.angular_velocity.cross(world_point - ski.global_position)
		water_vertical += water_v[i].y
		maximum_upward_water_velocity = maxf(maximum_upward_water_velocity, water_v[i].y)
		hull_vertical += hull_velocity.y
		relative_vertical += hull_velocity.y - water_v[i].y
		clearance = maxf(clearance, -depths[i])
		if i < forces.size():
			if i < 2:
				front_force += forces[i]
				front_vertical_force += force_vectors[i].y
			else:
				rear_force += forces[i]
				rear_vertical_force += force_vectors[i].y
	if n > 0:
		water_vertical /= n
		hull_vertical /= n
		relative_vertical /= n
	var body_vertical_accel := (ski.linear_velocity.y - prior_velocity_y) / maxf(dt, 0.000001)
	return {"position": ski.global_position, "forward_speed_mps": ski.linear_velocity.dot(-basis.z),
		"vertical_velocity_mps": ski.linear_velocity.y, "vertical_acceleration_mps2": body_vertical_accel,
		"relative_water_vehicle_vertical_mps": relative_vertical,
		"water_vertical_velocity_mps": water_vertical, "vehicle_contact_vertical_velocity_mps": hull_vertical,
		"maximum_upward_water_velocity_mps": maximum_upward_water_velocity,
		"front_buoyancy_force_n": front_force, "rear_buoyancy_force_n": rear_force,
		"front_vertical_buoyancy_force_n": front_vertical_force,
		"rear_vertical_buoyancy_force_n": rear_vertical_force,
		"wet_contact_count": physics.wet_contact_count, "supported_contact_count": physics.supported_contact_count,
		"raw_contact_mask": physics.state.raw_contact_mask,
		"clearance_m": maxf(clearance, 0.0), "signed_max_point_depth_m": physics.state.maximum_signed_point_depth,
		"pitch_deg": rad_to_deg(atan2((-basis.z).y, maxf(Vector2(basis.z.x, basis.z.z).length(), 0.0001))),
		"angular_velocity_local_rad_s": basis.inverse() * ski.angular_velocity,
		"last_contact_buoyancy_impulse_n_s": (front_force + rear_force) * dt,
		"takeoff_serial": physics.takeoff_event_serial}


func _finish_event(event: Dictionary, dt: float) -> Dictionary:
	var flight: Array = event.flight_samples
	var pre: Array = event.pre_supported_200ms
	var post: Array = event.post_supported_500ms
	var peak_launch_accel := maxf(_array_max(flight, "vertical_acceleration_mps2"),
		_array_max(pre, "vertical_acceleration_mps2"))
	var max_up_speed := _array_max(flight, "vertical_velocity_mps")
	var front_force_peak := _array_max(flight, "front_buoyancy_force_n")
	var rear_force_peak := _array_max(flight, "rear_buoyancy_force_n")
	var all_forces := _array_max(pre, "front_buoyancy_force_n") + _array_max(pre, "rear_buoyancy_force_n")
	var classification := "MICRO_HOP" if float(event.max_clearance_m) <= 0.30 and float(event.airtime_s) <= 0.08 else (
		"LARGE_JUMP" if float(event.max_clearance_m) >= 1.0 or float(event.airtime_s) >= 0.65 else "SMALL_JUMP")
	return {"start_tick": event.start_tick, "type": classification, "airtime_s": event.airtime_s,
		"max_clearance_m": event.max_clearance_m, "pre_supported_200ms": pre,
		"flight_and_next_500ms": flight + post, "peak_upward_acceleration_mps2": maxf(0.0, peak_launch_accel),
		"peak_upward_acceleration_predeparture_mps2": maxf(0.0, _array_max(pre, "vertical_acceleration_mps2")),
		"peak_upward_water_velocity_predeparture_mps": _array_max(pre, "maximum_upward_water_velocity_mps"),
		"peak_upward_velocity_mps": max_up_speed, "front_force_peak_during_flight_n": front_force_peak,
		"rear_force_peak_during_flight_n": rear_force_peak, "supported_force_peak_predeparture_n": all_forces,
		"last_contact_buoyancy_impulse_n_s": event.last_contact_impulse_n_s,
		"relative_water_vehicle_vertical_mps_peak": _array_max_abs(flight, "relative_water_vehicle_vertical_mps"),
		"pre_forward_speed_mps": event.pre_forward_speed_mps,
		"touchdown_forward_speed_mps": event.get("touchdown_forward_speed_mps", 0.0),
		"speed_lost_during_event_mps": maxf(0.0, float(event.pre_forward_speed_mps) - float(event.get("touchdown_forward_speed_mps", 0.0))),
		"peak_pitch_deg": event.peak_pitch_deg,
		"wet_contact_count_min": _array_min(flight, "wet_contact_count"),
		"contact_impulse_200ms_supported": _sum(pre, "last_contact_buoyancy_impulse_n_s"),
		"vertical_buoyancy_impulse_200ms_supported_n_s": (
			_sum(pre, "front_vertical_buoyancy_force_n") +
			_sum(pre, "rear_vertical_buoyancy_force_n")) * dt,
		"post_window_samples": post.size(), "incomplete_post_window": event.get("incomplete_post_window", false)}


func _classify_events(events: Array[Dictionary]) -> Dictionary:
	var counts := {"micro": 0, "small": 0, "large": 0}
	for event in events:
		match str(event.type):
			"MICRO_HOP": counts.micro += 1
			"SMALL_JUMP": counts.small += 1
			"LARGE_JUMP": counts.large += 1
	return counts


func _brief_event(event: Dictionary) -> Dictionary:
	var brief := event.duplicate(false)
	brief.erase("pre_supported_200ms")
	brief.erase("flight_and_next_500ms")
	return brief


func _brief_pass(row: Dictionary) -> Dictionary:
	var large_airtimes: Array[float] = []
	var speed_loss_sum := 0.0
	for event in row.events:
		speed_loss_sum += float(event.speed_lost_during_event_mps)
		if str(event.type) == "LARGE_JUMP": large_airtimes.append(float(event.airtime_s))
	return {"events_30s": row.event_count, "airborne_percent": row.airborne_percent,
		"micro_hops": row.micro_hops, "small_jumps": row.small_jumps, "large_jumps": row.large_jumps,
		"avg_speed_mps": row.average_forward_speed_mps,
		"avg_speed_lost_per_event_mps": speed_loss_sum / maxf(float(row.event_count), 1.0),
		"large_jump_airtime_mean_s": _mean(large_airtimes), "physics_time_ms": row.physics_time_ms,
		"fps": row.fps, "anti_hop_interventions": row.anti_hop_interventions,
		"propulsion_grace_ticks": row.propulsion_grace_ticks}


func _mean(values: Array[float]) -> float:
	if values.is_empty(): return 0.0
	var total := 0.0
	for value in values: total += value
	return total / float(values.size())


func _window_mean(window: Array[Dictionary], metric: String) -> float:
	if window.is_empty(): return 0.0
	var total := 0.0
	for sample in window: total += float(sample.get(metric, 0.0))
	return total / float(window.size())


func _array_max(rows: Array, metric: String) -> float:
	var result := -INF
	for row in rows: result = maxf(result, float(row.get(metric, 0.0)))
	return result if result > -INF else 0.0


func _array_max_abs(rows: Array, metric: String) -> float:
	var result := 0.0
	for row in rows: result = maxf(result, absf(float(row.get(metric, 0.0))))
	return result


func _array_min(rows: Array, metric: String) -> float:
	var result := INF
	for row in rows: result = minf(result, float(row.get(metric, INF)))
	return result if result < INF else 0.0


func _sum(rows: Array, metric: String) -> float:
	var result := 0.0
	for row in rows: result += float(row.get(metric, 0.0))
	return result


func _stats(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in values: total += value
	return {"mean": total / float(values.size()), "p95": ordered[mini(ordered.size() - 1, int(ceil((ordered.size() - 1) * 0.95)))], "max": ordered[-1]}


func _release_inputs() -> void:
	for action in ["throttle", "brake", "steer_left", "steer_right", "rider_shift_left", "rider_shift_right"]:
		if InputMap.has_action(action):
			Input.action_release(action)
