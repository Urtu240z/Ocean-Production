extends Node

const DRAFT_TEST_SECONDS := 8.0
const DRIVE_TEST_SECONDS := 30.0
const DRIVE_MODES := [
	JetSkiController.DriveMode.STOCK,
	JetSkiController.DriveMode.SPORT,
	JetSkiController.DriveMode.RACE,
]
const DRAFT_MODES := [
	JetSkiController.DraftMode.STANDARD,
	JetSkiController.DraftMode.LOW,
	JetSkiController.DraftMode.DEEP,
	JetSkiController.DraftMode.VERY_DEEP,
]

var _running := false
var _water_provider: Node
var _maximum_builds_per_tick := 0
var _maximum_query_positions_per_tick := 0


func run(game_root: Node) -> void:
	if _running:
		return
	_running = true
	var ski: JetSkiController = game_root.ski
	if ski == null:
		push_error("FEEL-2B validation requires the gameplay Jetski.")
		queue_free()
		return
	var original_draft := ski.draft_mode
	var original_drive := ski.drive_mode
	_water_provider = game_root.water
	ski.reset_vehicle(&"feel_2b_validation_start")
	await get_tree().physics_frame
	var start_transform := ski.global_transform
	print("FEEL2B VALIDATION START | draft modes 0/5/10/15 cm | drive STOCK/SPORT/RACE")
	print("FEEL2B DRIVE AUDIT | STOCK %.0f N forward / %.0f N reverse | falloff %.1f-%.1f m/s | application %s | drag forward %.1f + %.1f*v|v| N/point, lateral %.1f + %.1f*v|v| N/point | no hard speed cap" % [
		ski.forward_engine_force, ski.reverse_engine_force,
		ski.forward_thrust_falloff_start_speed, ski.forward_thrust_falloff_end_speed,
		str(ski.drive_system.get_propulsion_local_point()),
		ski.forward_drag_linear_per_point, ski.forward_drag_quadratic_per_point,
		ski.lateral_drag_linear_per_point, ski.lateral_drag_quadratic_per_point])
	for mode in DRAFT_MODES:
		_reset_vehicle(ski, start_transform)
		ski.set_draft_mode(mode)
		var sample := await _measure_draft(ski, DRAFT_TEST_SECONDS)
		print("FEEL2B DRAFT | %s %.2fm | y=%.3fm raw=%.3fm support=%.3fm force=%.0fN wet=%d/4" % [
			ski.get_draft_mode_name(), ski.get_draft_offset_m(), sample.y,
			sample.raw_depth, sample.support_depth, sample.buoyancy_force, sample.wet_count])
	for mode in DRIVE_MODES:
		_reset_vehicle(ski, start_transform)
		ski.set_draft_mode(JetSkiController.DraftMode.STANDARD)
		ski.set_drive_mode(mode)
		var result := await _measure_drive(ski, DRIVE_TEST_SECONDS)
		print("FEEL2B DRIVE | %s | max_supported=%.2fm/s (%.1fkm/h) | t50=%s t80=%s | peak_accel=%.2fm/s2 | airborne_thrust_max=%.0fN | supported_thrust_max=%.0fN | landing=%s" % [
			ski.get_drive_mode_name(), result.max_supported_speed,
			result.max_supported_speed * 3.6, _format_time(result.t50), _format_time(result.t80),
			result.peak_forward_accel, result.airborne_thrust_max,
			result.supported_thrust_max, str(result.landing_seen)])
		Input.action_release("throttle")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
	_reset_vehicle(ski, start_transform)
	ski.set_ballast_mode(JetSkiController.BallastMode.STOCK)
	ski.set_draft_mode(original_draft)
	ski.set_drive_mode(original_drive)
	print("FEEL2B QUERY AUDIT | max field builds/tick=%d | max sampled query positions/tick=%d" % [
		_maximum_builds_per_tick, _maximum_query_positions_per_tick])
	print("FEEL2B VALIDATION END | mode restored to %s / %s | mass %.0fkg" % [
		ski.get_draft_mode_name(), ski.get_drive_mode_name(), ski.mass])
	queue_free()


func run_drive_profiles(game_root: Node) -> void:
	if _running:
		return
	_running = true
	var ski: JetSkiController = game_root.ski
	if ski == null:
		push_error("FEEL-2B drive validation requires the gameplay Jetski.")
		queue_free()
		return
	_water_provider = game_root.water
	ski.reset_vehicle(&"feel_2b_drive_start")
	await get_tree().physics_frame
	var start_transform := ski.global_transform
	print("FEEL2B DRIVE RETEST START | identical start transform and zero start velocities per profile")
	for mode in DRIVE_MODES:
		await _reset_vehicle(ski, start_transform)
		ski.set_draft_mode(JetSkiController.DraftMode.STANDARD)
		ski.set_drive_mode(mode)
		var result := await _measure_drive(ski, DRIVE_TEST_SECONDS)
		print("FEEL2B DRIVE | %s | max_supported=%.2fm/s (%.1fkm/h) | t50=%s t80=%s | peak_accel=%.2fm/s2 | airborne_thrust_max=%.0fN | supported_thrust_max=%.0fN | landing=%s" % [
			ski.get_drive_mode_name(), result.max_supported_speed,
			result.max_supported_speed * 3.6, _format_time(result.t50), _format_time(result.t80),
			result.peak_forward_accel, result.airborne_thrust_max,
			result.supported_thrust_max, str(result.landing_seen)])
		Input.action_release("throttle")
		Input.action_release("steer_left")
		Input.action_release("steer_right")
	await _reset_vehicle(ski, start_transform)
	ski.set_ballast_mode(JetSkiController.BallastMode.STOCK)
	ski.set_draft_mode(JetSkiController.DraftMode.STANDARD)
	ski.set_drive_mode(JetSkiController.DriveMode.RACE)
	print("FEEL2B QUERY AUDIT | max field builds/tick=%d | max sampled query positions/tick=%d" % [
		_maximum_builds_per_tick, _maximum_query_positions_per_tick])
	print("FEEL2B DRIVE RETEST END | %s / %s | mass %.0fkg" % [
		ski.get_draft_mode_name(), ski.get_drive_mode_name(), ski.mass])
	queue_free()


func _reset_vehicle(ski: JetSkiController, start_transform: Transform3D) -> void:
	Input.action_release("throttle")
	Input.action_release("steer_left")
	Input.action_release("steer_right")
	ski.freeze = true
	ski.global_transform = start_transform
	ski.linear_velocity = Vector3.ZERO
	ski.angular_velocity = Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	ski.freeze = false
	await get_tree().physics_frame
	await get_tree().physics_frame


func _measure_draft(ski: JetSkiController, seconds: float) -> Dictionary:
	var frame_count := int(ceil(seconds / maxf(get_physics_process_delta_time(), 0.001)))
	var raw_total := 0.0
	var support_total := 0.0
	var y_total := 0.0
	var force_total := 0.0
	var wet_total := 0.0
	var measurements := 0
	for frame in frame_count:
		await get_tree().physics_frame
		if frame < frame_count * 0.5:
			continue
		_record_provider_load()
		var state := ski.water_physics_system.state
		raw_total += state.average_depth
		support_total += state.average_effective_support_depth
		y_total += ski.global_position.y
		force_total += state.total_buoyancy_force
		wet_total += float(ski.water_physics_system.wet_contact_count)
		measurements += 1
	return {
		"raw_depth": raw_total / maxf(float(measurements), 1.0),
		"support_depth": support_total / maxf(float(measurements), 1.0),
		"y": y_total / maxf(float(measurements), 1.0),
		"buoyancy_force": force_total / maxf(float(measurements), 1.0),
		"wet_count": int(round(wet_total / maxf(float(measurements), 1.0))),
	}


func _measure_drive(ski: JetSkiController, seconds: float) -> Dictionary:
	Input.action_press("throttle")
	var frame_count := int(ceil(seconds / maxf(get_physics_process_delta_time(), 0.001)))
	var elapsed := 0.0
	var previous_ground_speed := 0.0
	var maximum_speed := 0.0
	var peak_acceleration := 0.0
	var has_previous_speed := false
	var previous_supported := false
	var t50 := -1.0
	var t80 := -1.0
	var airborne_thrust_max := 0.0
	var supported_thrust_max := 0.0
	var landing_seen := false
	for frame in frame_count:
		await get_tree().physics_frame
		var step := maxf(get_physics_process_delta_time(), 0.001)
		elapsed += step
		_record_provider_load()
		var water_state := ski.water_physics_system.state
		var speed := maxf(water_state.water_relative_forward_speed, 0.0)
		var ground_speed := maxf(ski.linear_velocity.dot(-ski.global_transform.basis.z), 0.0)
		var supported := water_state.raw_contact_mask != 0 and not ski.water_physics_system.contact_is_airborne
		if supported:
			maximum_speed = maxf(maximum_speed, speed)
			if t50 < 0.0 and ground_speed >= 50.0 / 3.6:
				t50 = elapsed
			if t80 < 0.0 and ground_speed >= 80.0 / 3.6:
				t80 = elapsed
			if has_previous_speed and previous_supported:
				peak_acceleration = maxf(peak_acceleration, (ground_speed - previous_ground_speed) / step)
			supported_thrust_max = maxf(supported_thrust_max, ski.drive_system.state.propulsion_force)
		else:
			airborne_thrust_max = maxf(airborne_thrust_max, ski.drive_system.state.propulsion_force)
		previous_supported = supported
		if ski.water_physics_system.contact_is_landing:
			landing_seen = true
		previous_ground_speed = ground_speed
		has_previous_speed = true
	Input.action_release("throttle")
	return {
		"max_supported_speed": maximum_speed,
		"t50": t50,
		"t80": t80,
		"peak_forward_accel": peak_acceleration,
		"airborne_thrust_max": airborne_thrust_max,
		"supported_thrust_max": supported_thrust_max,
		"landing_seen": landing_seen,
	}


func _record_provider_load() -> void:
	if _water_provider == null:
		return
	_maximum_builds_per_tick = maxi(_maximum_builds_per_tick,
		int(_water_provider.get("field_builds_this_physics_tick")))
	_maximum_query_positions_per_tick = maxi(_maximum_query_positions_per_tick,
		int(_water_provider.get("native_query_positions_this_physics_tick")))


func _format_time(seconds: float) -> String:
	return "n/a" if seconds < 0.0 else "%.2fs" % seconds
