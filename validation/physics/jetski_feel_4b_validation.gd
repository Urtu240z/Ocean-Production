extends Node

## Phase-locked Water Race spring/damping comparison. Water/query architecture is read-only.
const STIFFNESSES := [5500.0, 4250.0, 3500.0]
const BASE_DAMPING := 2500.0
const BASE_NORMAL_INFLUENCE := 0.50
const BASE_STIFFNESS := 5500.0
const RUN_SECONDS := 1.5
const WAVE_SPEED_MULTIPLIER := 0.5

var _running := false

func run(game_root: Node, requested_wave_speed := -1.0, verify_selected := false) -> void:
	if _running: return
	_running = true
	var ski: JetSkiController = game_root.ski
	var physics: JetSkiWaterPhysicsSystem = ski.water_physics_system
	var provider: WaterSurfaceProvider3D = game_root.water
	var fft: Node = game_root.get_node_or_null("Production/Ocean/OpenOceanFFT")
	if ski == null or provider == null or fft == null:
		push_error("FEEL-4B needs the Jetski, gameplay water provider, and OpenOceanFFT.")
		queue_free()
		return
	var saved_transform := ski.global_transform
	var saved_linear := ski.linear_velocity
	var saved_angular := ski.angular_velocity
	var saved_speed := float(fft.call("get_simulation_time_scale"))
	var saved_process := fft.is_processing()
	var saved_physics_process := fft.is_physics_processing()
	var saved_k := physics.buoyancy_strength_per_point
	var saved_c := physics.buoyancy_damping_per_point
	var saved_influence := physics.buoyancy_normal_influence
	var saved_raw := physics.use_raw_buoyancy_direction
	var saved_diag := physics.diagnostics_enabled
	var saved_force_debug := physics.force_debug_enabled
	var points: PackedVector3Array = physics.get_buoyancy_local_points()
	var avg_point_y := 0.0
	for point in points: avg_point_y += point.y
	avg_point_y /= maxf(float(points.size()), 1.0)
	physics.diagnostics_enabled = false
	physics.force_debug_enabled = false
	physics.use_raw_buoyancy_direction = false
	physics.buoyancy_normal_influence = BASE_NORMAL_INFLUENCE
	ski.freeze = true
	_release_inputs()
	var wave_speed := WAVE_SPEED_MULTIPLIER if requested_wave_speed < 0.0 else clampf(requested_wave_speed, 0.0, 3.0)
	var candidates: Array = [4250.0] if verify_selected else STIFFNESSES.duplicate()
	fft.call("set_wave_speed_multiplier", wave_speed)
	await get_tree().physics_frame
	var phase := float(fft.call("get_wave_time"))
	fft.set_process(false)
	fft.set_physics_process(false)
	# The provider advances the authoritative clock from its own physics tick,
	# so stop its time scale after capturing the phase to keep every trial exact.
	fft.call("set_wave_speed_multiplier", 0.0)
	print("FEEL4B BEGIN | wave=%.6f | captured_speed=%.2f | trial_clock=held | influence=%.2f | verify_selected=%s | candidates=%s" % [
		phase, wave_speed, BASE_NORMAL_INFLUENCE, str(verify_selected), str(candidates)])
	var cases := [
		{"name":"STATIONARY", "slope":0.02, "speed":0.0, "heading":"slope", "throttle":false, "rider":Vector2.ZERO, "landing":false},
		{"name":"SMALL LATERAL", "slope":0.12, "speed":5.0, "heading":"lateral", "throttle":true, "rider":Vector2.ZERO, "landing":false},
		{"name":"MEDIUM LATERAL", "slope":0.22, "speed":9.0, "heading":"lateral", "throttle":true, "rider":Vector2.ZERO, "landing":false},
		{"name":"MEDIUM HEAD-ON", "slope":0.22, "speed":12.0, "heading":"slope", "throttle":true, "rider":Vector2.ZERO, "landing":false},
		{"name":"LARGE HEAD-ON", "slope":0.32, "speed":15.0, "heading":"slope", "throttle":true, "rider":Vector2.ZERO, "landing":false},
		{"name":"DIAGONAL", "slope":0.18, "speed":10.0, "heading":"diagonal", "throttle":true, "rider":Vector2.ZERO, "landing":false},
		{"name":"HIGH-SPEED CROSSING", "slope":0.18, "speed":22.0, "heading":"lateral", "throttle":true, "rider":Vector2.ZERO, "landing":false},
		{"name":"LANDING RE-ENTRY", "slope":0.02, "speed":0.0, "heading":"slope", "throttle":false, "rider":Vector2.ZERO, "landing":true},
		{"name":"LANDING RE-ENTRY 2", "slope":0.02, "speed":0.0, "heading":"slope", "throttle":false, "rider":Vector2.ZERO, "landing":true},
		{"name":"LANDING RE-ENTRY 3", "slope":0.02, "speed":0.0, "heading":"slope", "throttle":false, "rider":Vector2.ZERO, "landing":true},
	]
	if verify_selected:
		cases = [cases[1], cases[4], cases[7]] # small lateral, large head-on, landing
	var all_locked := true
	var rows := 0
	var origin := Vector2(saved_transform.origin.x, saved_transform.origin.z)
	for case_index in cases.size():
		var scenario: Dictionary = cases[case_index]
		var site := _find_site(provider, origin + Vector2(float(case_index) * 17.0, -float(case_index) * 11.0), float(scenario.slope))
		if not bool(site.get("valid", false)):
			print("FEEL4B SKIP | %s | no valid water sample" % scenario.name)
			continue
		var n: Vector3 = site.normal
		var forward := Vector3(-n.x, 0.0, -n.z)
		if forward.length_squared() < 0.0001: forward = Vector3.FORWARD
		forward = forward.normalized()
		if str(scenario.heading) == "lateral": forward = Vector3(-forward.z, 0.0, forward.x)
		elif str(scenario.heading) == "diagonal": forward = (forward + Vector3(-forward.z, 0.0, forward.x)).normalized()
		var pose := Transform3D(Basis(Vector3.UP, atan2(-forward.x, -forward.z)),
			Vector3(site.position.x, float(site.surface_y) - 0.14 - avg_point_y, site.position.y))
		var velocity := forward * float(scenario.speed)
		if bool(scenario.landing): velocity.y = -4.0
		var first: Dictionary = {}
		for stiffness in candidates:
			var damping := _matched_damping(stiffness)
			var row: Dictionary = await _run_case(ski, physics, scenario, pose, velocity, stiffness, damping, phase)
			row["scenario"] = scenario.name
			row["stiffness"] = stiffness
			row["damping"] = damping
			row["phase_locked"] = first.is_empty() or (
				is_equal_approx(float(row.wave_time), float(first.wave_time))
				and row.initial_transform.is_equal_approx(first.initial_transform)
				and row.initial_linear_velocity.is_equal_approx(first.initial_linear_velocity)
				and row.initial_angular_velocity.is_equal_approx(first.initial_angular_velocity))
			if first.is_empty(): first = row.duplicate(true)
			if not bool(row.phase_locked):
				all_locked = false
				push_error("FEEL-4B phase lock failed: %s, K=%.0f" % [scenario.name, stiffness])
				break
			rows += 1
			print("FEEL4B RESULT | %s | K=%.0f C=%.1f | pitch_rate_p95=%.3f roll_rate_p95=%.3f | pitch_accel_p95=%.3f roll_accel_p95=%.3f | peak_pitch=%.3f peak_roll=%.3f | torque_p95=%.1f | total_force_peak=%.1f | contact_delta_p95=%.1f | raw_depth=%.3f support_depth=%.3f COM_waterline=%.3f | max_depth=%.3f | response_delay=%.3f recovery=%.3f peak_down_vy=%.3f" % [
				str(scenario.name), stiffness, damping, row.pitch_rate_p95, row.roll_rate_p95,
				row.pitch_accel_p95, row.roll_accel_p95, row.pitch_rate_max, row.roll_rate_max,
				row.buoyancy_torque_p95_nm, row.force_peak_n, row.contact_force_spread_p95_n,
				row.raw_depth_mean_m, row.support_depth_mean_m, row.com_waterline_m,
				row.max_raw_depth_m, row.response_delay_s, row.recovery_time_s, row.landing_vertical_speed_mps])
			await get_tree().physics_frame
			if not is_equal_approx(float(fft.call("get_wave_time")), phase):
				all_locked = false
				push_error("FEEL-4B phase lock failed: FFT time drifted during comparison.")
				break
	_release_inputs()
	physics.buoyancy_strength_per_point = saved_k
	physics.buoyancy_damping_per_point = saved_c
	physics.buoyancy_normal_influence = saved_influence
	physics.use_raw_buoyancy_direction = saved_raw
	fft.call("set_wave_speed_multiplier", saved_speed)
	fft.set_process(saved_process)
	fft.set_physics_process(saved_physics_process)
	physics.diagnostics_enabled = saved_diag
	physics.force_debug_enabled = saved_force_debug
	ski.freeze = true
	ski.call("_teleport_and_reset", saved_transform, &"feel_4b_restore")
	ski.linear_velocity = saved_linear if saved_linear.is_finite() else Vector3.ZERO
	ski.angular_velocity = saved_angular if saved_angular.is_finite() else Vector3.ZERO
	ski.reset_physics_interpolation()
	ski.freeze = false
	print("FEEL4B END | rows=%d/%d | phase=%.6f | phase_lock=%s | FPS=%d | candidate defaults restored" % [
		rows, cases.size() * candidates.size(), phase, "PASS" if all_locked and rows == cases.size() * candidates.size() else "FAIL", Engine.get_frames_per_second()])
	queue_free()

func _matched_damping(stiffness: float) -> float:
	# Preserve the current effective damping ratio at shallow equilibrium. Contact
	# damping is faded by depth/0.8; equilibrium depth varies inversely with K.
	return BASE_DAMPING * pow(stiffness / BASE_STIFFNESS, 1.5)

func _run_case(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem, scenario: Dictionary,
		pose: Transform3D, velocity: Vector3, stiffness: float, damping: float, phase: float) -> Dictionary:
	_release_inputs()
	ski.freeze = true
	ski.call("_teleport_and_reset", pose, &"feel_4b_trial")
	physics.buoyancy_strength_per_point = stiffness
	physics.buoyancy_damping_per_point = damping
	physics.buoyancy_normal_influence = BASE_NORMAL_INFLUENCE
	physics.use_raw_buoyancy_direction = false
	physics.reset_runtime_state()
	await get_tree().physics_frame
	ski.global_transform = pose
	ski.linear_velocity = velocity
	ski.angular_velocity = Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	if bool(scenario.throttle): Input.action_press("throttle")
	var pitch_rates: Array[float] = []
	var roll_rates: Array[float] = []
	var pitch_accels: Array[float] = []
	var roll_accels: Array[float] = []
	var torque: Array[float] = []
	var depths: Array[float] = []
	var max_depth := 0.0
	var force_spreads: Array[float] = []
	var total_force: Array[float] = []
	var raw_depths: Array[float] = []
	var com_waterlines: Array[float] = []
	var max_landing_vy := 0.0
	var first_change_time := -1.0
	var peak_accel_time := 0.0
	var peak_accel := 0.0
	var recovery_time := -1.0
	var initial_surface_heights := PackedFloat32Array()
	var prev := Vector2.ZERO
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var count := maxi(1, int(round(RUN_SECONDS / dt)))
	ski.freeze = false
	for tick in count:
		await get_tree().physics_frame
		var surfaces: PackedVector3Array = physics.point_water_surface_positions
		var depths_now: PackedFloat32Array = physics.get_buoyancy_point_depths()
		var surface_height_sum := 0.0
		for i in mini(surfaces.size(), 4):
			surface_height_sum += surfaces[i].y
			if tick == 0: initial_surface_heights.append(surfaces[i].y)
			elif first_change_time < 0.0 and i < initial_surface_heights.size() and absf(surfaces[i].y - initial_surface_heights[i]) >= 0.02:
				first_change_time = float(tick + 1) * dt
		if surfaces.size() > 0:
			var com_world := ski.global_transform * ski.center_of_mass
			com_waterlines.append(com_world.y - surface_height_sum / float(surfaces.size()))
		var valid_depth_sum := 0.0
		var valid_depth_count := 0
		for depth in depths_now:
			if depth > 0.0:
				valid_depth_sum += depth
				valid_depth_count += 1
		if valid_depth_count > 0: raw_depths.append(valid_depth_sum / float(valid_depth_count))
		var basis := ski.global_transform.basis.orthonormalized()
		var rates := basis.inverse() * ski.angular_velocity
		pitch_rates.append(absf(rates.x)); roll_rates.append(absf(rates.z))
		if tick > 0:
			var accel := maxf(absf(rates.x - prev.x), absf(rates.z - prev.y)) / dt
			pitch_accels.append(absf(rates.x - prev.x) / dt)
			roll_accels.append(absf(rates.z - prev.y) / dt)
			if accel > peak_accel:
				peak_accel = accel
				peak_accel_time = float(tick + 1) * dt
		prev = Vector2(rates.x, rates.z)
		torque.append(physics._last_applied_buoyancy_torque.length())
		total_force.append(physics.total_buoyancy_force_vector.length())
		depths.append(physics.state.average_effective_support_depth)
		max_depth = maxf(max_depth, physics.state.maximum_depth)
		max_landing_vy = maxf(max_landing_vy, absf(minf(ski.linear_velocity.y, 0.0)))
		if recovery_time < 0.0 and tick > 0 and absf(ski.linear_velocity.y) < 0.2 and ski.angular_velocity.length() < 0.2:
			recovery_time = float(tick + 1) * dt
		var forces: PackedFloat32Array = physics.get_buoyancy_point_normal_forces()
		var sorted: Array[float] = []
		for f in forces: sorted.append(f)
		sorted.sort()
		if sorted.size() == 4: force_spreads.append(sorted[3] - sorted[0])
	_release_inputs()
	return {"wave_time":phase, "initial_transform":pose, "initial_linear_velocity":velocity,
		"initial_angular_velocity":Vector3.ZERO, "pitch_rate_p95":_percentile(pitch_rates, .95),
		"roll_rate_p95":_percentile(roll_rates, .95), "pitch_rate_max":_max(pitch_rates),
		"roll_rate_max":_max(roll_rates), "pitch_accel_p95":_percentile(pitch_accels, .95),
		"roll_accel_p95":_percentile(roll_accels, .95), "buoyancy_torque_p95_nm":_percentile(torque, .95),
		"contact_force_spread_p95_n":_percentile(force_spreads, .95), "force_peak_n":_max(total_force),
		"support_depth_mean_m":_mean(depths), "raw_depth_mean_m":_mean(raw_depths),
		"com_waterline_m":_mean(com_waterlines), "response_delay_s":maxf(0.0, peak_accel_time - first_change_time) if first_change_time >= 0.0 else -1.0,
		"recovery_time_s":recovery_time if recovery_time >= 0.0 else RUN_SECONDS,
		"max_raw_depth_m":max_depth, "landing_vertical_speed_mps":max_landing_vy}

func _find_site(provider: WaterSurfaceProvider3D, center: Vector2, slope_target: float) -> Dictionary:
	var best: Dictionary = {}
	var score_best := INF
	for x in range(-4, 5):
		for z in range(-4, 5):
			var pos := center + Vector2(float(x) * 12.0, float(z) * 12.0)
			var sample := provider.sample_water(Vector3(pos.x, 0.0, pos.y), WaterSample3D.new())
			if sample == null or not sample.valid: continue
			var normal := sample.normal.normalized()
			if normal.y < 0.0: normal = -normal
			var slope := Vector2(normal.x, normal.z).length()
			var score := absf(slope - slope_target) + absf(sample.signed_depth) * .005
			if score < score_best:
				score_best = score
				best = {"valid":true, "position":pos, "surface_y":sample.surface_position.y, "normal":normal}
	return best

func _release_inputs() -> void:
	for action in ["throttle", "brake", "steer_left", "steer_right", "rider_shift_left", "rider_shift_right", "rider_shift_forward", "rider_shift_back"]: Input.action_release(action)

func _percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty(): return 0.0
	var copy := values.duplicate(); copy.sort()
	return copy[clampi(int(ceil(fraction * float(copy.size()))) - 1, 0, copy.size() - 1)]

func _mean(values: Array[float]) -> float:
	if values.is_empty(): return 0.0
	var total := 0.0
	for value in values: total += value
	return total / float(values.size())

func _max(values: Array[float]) -> float:
	var value := 0.0
	for item in values: value = maxf(value, item)
	return value
