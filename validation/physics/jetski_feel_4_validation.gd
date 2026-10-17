extends Node

const NORMAL_INFLUENCES := [1.0, 0.5, 0.25, 0.1]
const RUN_SECONDS := 1.5
const WAVE_SPEED_MULTIPLIER := 0.5

var _running := false

func run(game_root: Node) -> void:
	if _running: return
	_running = true
	var ski: JetSkiController = game_root.ski
	var physics: JetSkiWaterPhysicsSystem = ski.water_physics_system
	var provider: WaterSurfaceProvider3D = game_root.water
	var fft: Node = game_root.get_node_or_null("Production/Ocean/OpenOceanFFT")
	if ski == null or provider == null or fft == null:
		push_error("FEEL-4 validation needs the Jetski, GAMEPLAY_SURFACE provider, and OpenOceanFFT.")
		queue_free()
		return

	var original_transform := ski.global_transform
	var original_linear_velocity := ski.linear_velocity
	var original_angular_velocity := ski.angular_velocity
	var original_speed_multiplier := float(fft.call("get_simulation_time_scale"))
	var original_fft_process := fft.is_processing()
	var original_fft_physics := fft.is_physics_processing()
	var original_diagnostics := physics.diagnostics_enabled
	var original_force_debug := physics.force_debug_enabled
	var original_raw_mode := physics.use_raw_buoyancy_direction
	var original_influence := physics.buoyancy_normal_influence
	var original_takeoff := physics.takeoff_assist_enabled
	var local_points: PackedVector3Array = physics.get_buoyancy_local_points()
	var average_point_y := 0.0
	for point in local_points: average_point_y += point.y
	average_point_y /= maxf(float(local_points.size()), 1.0)

	physics.diagnostics_enabled = false
	physics.force_debug_enabled = false
	physics.set_takeoff_assist_enabled(true)
	ski.freeze = true
	_release_inputs()
	fft.call("set_wave_speed_multiplier", WAVE_SPEED_MULTIPLIER)
	await get_tree().physics_frame
	var fixed_wave_time := float(fft.call("get_wave_time"))
	fft.set_process(false)
	fft.set_physics_process(false)
	print("FEEL4 BEGIN | wave=%.6f | wave_speed_multiplier=%.2f | influences=%s" % [
		fixed_wave_time, WAVE_SPEED_MULTIPLIER, str(NORMAL_INFLUENCES)])

	var scenarios := [
		{"name":"STATIONARY", "slope":0.02, "speed":0.0, "heading":"slope", "throttle":false, "steer":0, "rider":Vector2.ZERO},
		{"name":"GENTLE WAVE", "slope":0.06, "speed":3.0, "heading":"slope", "throttle":true, "steer":0, "rider":Vector2.ZERO},
		{"name":"SMALL LATERAL", "slope":0.12, "speed":5.0, "heading":"lateral", "throttle":true, "steer":0, "rider":Vector2(-0.25, 0.0)},
		{"name":"MEDIUM LATERAL", "slope":0.22, "speed":9.0, "heading":"lateral", "throttle":true, "steer":0, "rider":Vector2(0.25, 0.0)},
		{"name":"MEDIUM HEAD-ON", "slope":0.22, "speed":12.0, "heading":"slope", "throttle":true, "steer":0, "rider":Vector2.ZERO},
		{"name":"DIAGONAL", "slope":0.18, "speed":10.0, "heading":"diagonal", "throttle":true, "steer":0, "rider":Vector2.ZERO},
		{"name":"HIGH-SPEED CROSSING", "slope":0.18, "speed":22.0, "heading":"lateral", "throttle":true, "steer":0, "rider":Vector2.ZERO},
	]
	var rows: Array[Dictionary] = []
	var all_rows_phase_locked := true
	var origin_xz := Vector2(original_transform.origin.x, original_transform.origin.z)
	for scenario_index in scenarios.size():
		var scenario: Dictionary = scenarios[scenario_index]
		var site := _find_site(provider, origin_xz + Vector2(float(scenario_index) * 17.0, -float(scenario_index) * 11.0), float(scenario.slope))
		if not bool(site.get("valid", false)):
			print("FEEL4 SKIP | %s | no valid surface site" % scenario.name)
			continue
		var normal: Vector3 = site.normal
		var slope_forward := Vector3(normal.x, 0.0, normal.z)
		if slope_forward.length_squared() < 0.0001: slope_forward = Vector3.FORWARD
		slope_forward = slope_forward.normalized()
		var forward := slope_forward
		match str(scenario.heading):
			"lateral": forward = Vector3(-slope_forward.z, 0.0, slope_forward.x)
			"diagonal": forward = (slope_forward + Vector3(-slope_forward.z, 0.0, slope_forward.x)).normalized()
		var yaw := atan2(-forward.x, -forward.z)
		var scenario_transform := Transform3D(Basis(Vector3.UP, yaw), Vector3(
			float(site.position.x), float(site.surface_y) - 0.14 - average_point_y, float(site.position.y)))
		var initial_velocity := forward * float(scenario.speed)
		var matched_start: Dictionary = {}
		for influence in NORMAL_INFLUENCES:
			var row := await _run_case(ski, physics, scenario, scenario_transform,
				initial_velocity, float(influence), fixed_wave_time)
			row["input_scenario"] = {"throttle": scenario.throttle, "steer": scenario.steer, "rider": scenario.rider}
			row["phase_locked"] = matched_start.is_empty() or (
				is_equal_approx(float(row.wave_time), float(matched_start.wave_time))
				and row.initial_transform.is_equal_approx(matched_start.initial_transform)
				and row.initial_linear_velocity.is_equal_approx(matched_start.initial_linear_velocity)
				and row.initial_angular_velocity.is_equal_approx(matched_start.initial_angular_velocity)
				and row.input_scenario == matched_start.input_scenario)
			if matched_start.is_empty(): matched_start = row.duplicate(true)
			if not bool(row.phase_locked):
				all_rows_phase_locked = false
				push_error("FEEL-4 phase lock failed for %s at NORMAL_%03d; excluding this comparison." % [
					str(scenario.name), int(round(float(influence) * 100.0))])
				break
			row["scenario"] = str(scenario.name)
			row["site_slope"] = float(site.slope)
			row["site_normal"] = normal
			rows.append(row)
			print("FEEL4 RESULT | %s | NORMAL_%03d | pitch_rate_p95=%.3f roll_rate_p95=%.3f rad/s | pitch_accel_p95=%.3f roll_accel_p95=%.3f rad/s2 | force_h/v=%.3f | torque_p95=%.1f Nm | force_p95=%.1f N | depth=%.3f m" % [
				str(scenario.name), int(round(float(influence) * 100.0)),
				float(row.pitch_rate_p95), float(row.roll_rate_p95),
				float(row.pitch_accel_p95), float(row.roll_accel_p95),
				float(row.horizontal_vertical_force_ratio), float(row.buoyancy_torque_p95_nm),
				float(row.buoyancy_force_p95_n), float(row.support_depth_mean_m)])
			await get_tree().physics_frame
			fft.call("set_wave_speed_multiplier", WAVE_SPEED_MULTIPLIER)
			if not is_equal_approx(float(fft.call("get_wave_time")), fixed_wave_time):
				push_error("FEEL-4 phase lock failed: ocean wave time advanced between cases.")
				break

	_release_inputs()
	fft.call("set_wave_speed_multiplier", original_speed_multiplier)
	fft.set_process(original_fft_process)
	fft.set_physics_process(original_fft_physics)
	physics.diagnostics_enabled = original_diagnostics
	physics.force_debug_enabled = original_force_debug
	physics.use_raw_buoyancy_direction = original_raw_mode
	physics.buoyancy_normal_influence = original_influence
	physics.set_takeoff_assist_enabled(original_takeoff)
	ski.freeze = true
	ski.call("_teleport_and_reset", original_transform, &"feel_4_validation_restore")
	ski.linear_velocity = original_linear_velocity if original_linear_velocity.is_finite() else Vector3.ZERO
	ski.angular_velocity = original_angular_velocity if original_angular_velocity.is_finite() else Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	ski.freeze = false
	print("FEEL4 END | rows=%d | phase=%.6f | phase_lock=%s | raw/candidate state restored | FPS=%d" % [
		rows.size(), fixed_wave_time, "PASS" if all_rows_phase_locked and rows.size() == 28 else "FAIL",
		Engine.get_frames_per_second()])
	queue_free()

func _run_case(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem, scenario: Dictionary,
		pose: Transform3D, linear_velocity: Vector3, influence: float,
		fixed_wave_time: float) -> Dictionary:
	_release_inputs()
	ski.freeze = true
	ski.call("_teleport_and_reset", pose, &"feel_4_validation_trial")
	physics.use_raw_buoyancy_direction = false
	physics.buoyancy_normal_influence = influence
	physics.reset_runtime_state()
	await get_tree().physics_frame
	ski.global_transform = pose
	ski.linear_velocity = linear_velocity
	ski.angular_velocity = Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	physics.takeoff_rider_shift = scenario.rider
	if bool(scenario.throttle): Input.action_press("throttle")
	if int(scenario.steer) < 0: Input.action_press("steer_left")
	if int(scenario.steer) > 0: Input.action_press("steer_right")
	if scenario.rider.x < 0.0: Input.action_press("rider_shift_left")
	if scenario.rider.x > 0.0: Input.action_press("rider_shift_right")
	var pitch_rates: Array[float] = []
	var roll_rates: Array[float] = []
	var pitch_accels: Array[float] = []
	var roll_accels: Array[float] = []
	var torque_samples: Array[float] = []
	var force_samples: Array[float] = []
	var depth_samples: Array[float] = []
	var ratios: Array[float] = []
	var previous_rates := Vector2.ZERO
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	var tick_count := maxi(1, int(round(RUN_SECONDS / step)))
	ski.freeze = false
	for tick in tick_count:
		await get_tree().physics_frame
		var basis := ski.global_transform.basis.orthonormalized()
		var local_rates := basis.inverse() * ski.angular_velocity
		pitch_rates.append(absf(local_rates.x))
		roll_rates.append(absf(local_rates.z))
		if tick > 0:
			pitch_accels.append(absf(local_rates.x - previous_rates.x) / step)
			roll_accels.append(absf(local_rates.z - previous_rates.y) / step)
		previous_rates = Vector2(local_rates.x, local_rates.z)
		torque_samples.append(physics._last_applied_buoyancy_torque.length())
		force_samples.append(physics.total_buoyancy_force_vector.length())
		depth_samples.append(physics.state.average_effective_support_depth)
		var force := physics.total_buoyancy_force_vector
		ratios.append((Vector2(force.x, force.z).length()) / maxf(absf(force.y), 0.001))
	_release_inputs()
	return {
		"wave_time": fixed_wave_time,
		"initial_transform": pose,
		"initial_linear_velocity": linear_velocity,
		"initial_angular_velocity": Vector3.ZERO,
		"influence": influence,
		"pitch_rate_p95": _percentile(pitch_rates, 0.95),
		"roll_rate_p95": _percentile(roll_rates, 0.95),
		"pitch_accel_p95": _percentile(pitch_accels, 0.95),
		"roll_accel_p95": _percentile(roll_accels, 0.95),
		"buoyancy_torque_p95_nm": _percentile(torque_samples, 0.95),
		"buoyancy_force_p95_n": _percentile(force_samples, 0.95),
		"support_depth_mean_m": _mean(depth_samples),
		"horizontal_vertical_force_ratio": _mean(ratios),
	}

func _find_site(provider: WaterSurfaceProvider3D, center: Vector2, target_slope: float) -> Dictionary:
	var best: Dictionary = {}
	var best_score := INF
	for x_index in range(-4, 5):
		for z_index in range(-4, 5):
			var position := center + Vector2(float(x_index) * 12.0, float(z_index) * 12.0)
			var sample := provider.sample_water(Vector3(position.x, 0.0, position.y), WaterSample3D.new())
			if sample == null or not sample.valid or not sample.normal.is_finite(): continue
			var normal := sample.normal.normalized()
			if normal.y < 0.0: normal = -normal
			var slope := Vector2(normal.x, normal.z).length()
			var score := absf(slope - target_slope) + absf(float(sample.signed_depth)) * 0.005
			if score < best_score:
				best_score = score
				best = {"valid": true, "position": position, "surface_y": sample.surface_position.y,
					"normal": normal, "slope": slope}
	return best

func _release_inputs() -> void:
	for action in ["throttle", "steer_left", "steer_right", "rider_shift_left", "rider_shift_right", "rider_shift_forward", "rider_shift_back"]:
		Input.action_release(action)

func _mean(values: Array[float]) -> float:
	if values.is_empty(): return 0.0
	var total := 0.0
	for value in values: total += value
	return total / float(values.size())

func _percentile(values: Array[float], percentile: float) -> float:
	if values.is_empty(): return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(float(sorted.size()) * percentile)) - 1, 0, sorted.size() - 1)
	return sorted[index]
