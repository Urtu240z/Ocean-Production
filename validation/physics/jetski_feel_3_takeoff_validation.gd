extends Node

const REQUIRED_VALID_PAIRS := 20
const TARGET_PAIRS_PER_CASE := 3
const MAX_CANDIDATES_PER_CASE := 8
const MAX_LAUNCH_WAIT_S := 1.75
const FLIGHT_SAMPLE_SECONDS := [0.1, 0.25, 0.5]
const GRID_STEP_M := 3.0
const GRID_RADIUS_M := 48.0
const CREST_CROSS_DISTANCE_M := 6.0
const START_IMMERSION_M := 0.10

const CASES := [
	{"name": "A STRAIGHT MEDIUM CREST", "speed_mps": 12.0, "steer": 0, "rider": Vector2.ZERO, "profile": "medium"},
	{"name": "B STRAIGHT LARGE CREST", "speed_mps": 18.0, "steer": 0, "rider": Vector2.ZERO, "profile": "large"},
	{"name": "C HIGH-SPEED CREST", "speed_mps": 22.0, "steer": 0, "rider": Vector2.ZERO, "profile": "large"},
	{"name": "D DIAGONAL CREST", "speed_mps": 15.0, "steer": 0, "rider": Vector2.ZERO, "profile": "diagonal"},
	{"name": "E TURNING CREST", "speed_mps": 15.0, "steer": -1, "rider": Vector2.ZERO, "profile": "medium"},
	{"name": "F RIDER BACK", "speed_mps": 15.0, "steer": 0, "rider": Vector2(0.0, 1.0), "profile": "shared"},
	{"name": "G RIDER FORWARD", "speed_mps": 15.0, "steer": 0, "rider": Vector2(0.0, -1.0), "profile": "shared"},
	{"name": "H RIDER LEFT", "speed_mps": 15.0, "steer": 0, "rider": Vector2(-1.0, 0.0), "profile": "shared"},
	{"name": "I RIDER RIGHT", "speed_mps": 15.0, "steer": 0, "rider": Vector2(1.0, 0.0), "profile": "shared"},
]

var _running := false
var _attempt_counts: Dictionary = {}
var _valid_mode_trials := {"OFF": [], "ON": []}
var _pair_release_deltas: Array[Dictionary] = []
var _case_valid_counts: Dictionary = {}
var _case_failed_counts: Dictionary = {}
var _case_profiles: Dictionary = {}
var _rider_intent_results: Dictionary = {}
var _extreme_trials: Array[Dictionary] = []
var _valid_launch_counts := {"OFF": 0, "ON": 0}
var _no_takeoff_counts := {"OFF": 0, "ON": 0}
var _phase_rejected_count := 0
var _rider_neutral_pitch_rates: Array[float] = []
var _rider_neutral_roll_rates: Array[float] = []
var _validation_started_usec := 0


func run(game_root: Node) -> void:
	print("FEEL3C ENTER")
	if _running:
		return
	_running = true
	_validation_started_usec = Time.get_ticks_usec()
	var ski: JetSkiController = game_root.ski
	var physics: JetSkiWaterPhysicsSystem = ski.water_physics_system
	var provider: Node = game_root.water
	var fft: Node = game_root.get_node_or_null("Production/Ocean/OpenOceanFFT")
	if ski == null or provider == null or fft == null:
		push_error("FEEL-3C validation could not find the Jetski, GAMEPLAY_SURFACE provider, or OpenOceanFFT.")
		queue_free()
		return

	var original_diagnostics := physics.diagnostics_enabled
	var original_fft_process := fft.is_processing()
	var original_fft_physics := fft.is_physics_processing()
	var original_transform := ski.global_transform
	var original_linear_velocity := ski.linear_velocity
	var original_angular_velocity := ski.angular_velocity
	var origin := ski.global_position
	physics.diagnostics_enabled = true
	physics.set_takeoff_assist_enabled(true)
	ski.freeze = true
	fft.set_process(false)
	fft.set_physics_process(false)
	await get_tree().physics_frame
	var fixed_wave_time := float(fft.call("get_wave_time"))
	print("FEEL3C SCAN BEGIN | wave=%.6f | sample_count=~1089 | surface=GAMEPLAY_SURFACE" % fixed_wave_time)
	var scan_started := Time.get_ticks_usec()
	var profiles := await _scan_surface_crests(provider, Vector2(origin.x, origin.z))
	var scan_ms := float(Time.get_ticks_usec() - scan_started) / 1000.0
	print("FEEL3C START | wave=%.6f | surface=GAMEPLAY_SURFACE | crest_profiles=%d | scan=%.1f ms" % [
		fixed_wave_time, profiles.size(), scan_ms])

	var shared_rider_profile: Dictionary = {}
	var case_index := 0
	for case_data in CASES.slice(0, 5):
		var chosen := await _run_case_with_profile_search(
			game_root, ski, physics, provider, case_data, profiles, case_index, fixed_wave_time
		)
		if case_data.name == "A STRAIGHT MEDIUM CREST" and not chosen.is_empty():
			shared_rider_profile = chosen
		case_index += 1

	if shared_rider_profile.is_empty():
		for case_name in _case_profiles:
			shared_rider_profile = _case_profiles[case_name]
			break
	if not shared_rider_profile.is_empty():
		var neutral_case := {
			"name": "RIDER NEUTRAL REFERENCE",
			"speed_mps": 15.0,
			"steer": 0,
			"rider": Vector2.ZERO,
			"profile": "shared"
		}
		await _run_fixed_profile_case(game_root, ski, physics, provider, neutral_case, shared_rider_profile, fixed_wave_time)
		for case_data in CASES.slice(5, 9):
			await _run_fixed_profile_case(game_root, ski, physics, provider, case_data, shared_rider_profile, fixed_wave_time)
	else:
		for case_data in CASES.slice(5, 9):
			_attempt_counts[case_data.name] = 0
			_case_failed_counts[case_data.name] = TARGET_PAIRS_PER_CASE

	await _run_extreme_probes(game_root, ski, physics, provider, profiles, fixed_wave_time)
	_print_summary(fixed_wave_time, scan_ms)

	_release_test_inputs()
	physics.set_takeoff_assist_enabled(true)
	physics.diagnostics_enabled = original_diagnostics
	fft.set_process(original_fft_process)
	fft.set_physics_process(original_fft_physics)
	ski.freeze = true
	ski.call("_teleport_and_reset", original_transform, &"feel_3c_validation_restore")
	ski.linear_velocity = original_linear_velocity if original_linear_velocity.is_finite() else Vector3.ZERO
	ski.angular_velocity = original_angular_velocity if original_angular_velocity.is_finite() else Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	ski.freeze = false
	print("FEEL3C END | cleaner=ON | wave restored | FPS=%d | elapsed=%.1f s" % [
		Engine.get_frames_per_second(), float(Time.get_ticks_usec() - _validation_started_usec) / 1000000.0])
	queue_free()


func _scan_surface_crests(provider: Node, center: Vector2) -> Array[Dictionary]:
	var cell_count := int(round(GRID_RADIUS_M * 2.0 / GRID_STEP_M)) + 1
	var half := floori(float(cell_count) * 0.5)
	var positions := PackedVector3Array()
	positions.resize(cell_count * cell_count)
	for zi in cell_count:
		for xi in cell_count:
			var x := center.x + float(xi - half) * GRID_STEP_M
			var z := center.y + float(zi - half) * GRID_STEP_M
			positions[zi * cell_count + xi] = Vector3(x, 0.0, z)
		if zi % 4 == 3:
			await get_tree().process_frame
	var backend := int(provider.get("backend"))
	var samples: Array = provider.call("sample_water_batch", positions, backend)
	if samples.size() != positions.size():
		push_warning("FEEL-3C surface scan returned an incomplete GAMEPLAY_SURFACE field.")
		return []

	var heights := PackedFloat32Array()
	var valid := PackedByteArray()
	heights.resize(samples.size())
	valid.resize(samples.size())
	for index in samples.size():
		var sample: WaterSample3D = samples[index]
		if sample != null and sample.valid and sample.surface_position.is_finite():
			heights[index] = sample.surface_position.y
			valid[index] = 1

	var profiles: Array[Dictionary] = []
	for zi in range(1, cell_count - 1):
		for xi in range(1, cell_count - 1):
			var index := zi * cell_count + xi
			if valid[index] == 0 or not _is_grid_local_peak(heights, valid, cell_count, xi, zi):
				continue
			var crest_height := float(heights[index])
			for direction_index in 16:
				var heading := TAU * float(direction_index) / 16.0
				var forward := Vector3(cos(heading), 0.0, sin(heading))
				var upstream := Vector2(
					center.x + float(xi - half) * GRID_STEP_M - forward.x * CREST_CROSS_DISTANCE_M,
					center.y + float(zi - half) * GRID_STEP_M - forward.z * CREST_CROSS_DISTANCE_M
				)
				var downstream := Vector2(
					center.x + float(xi - half) * GRID_STEP_M + forward.x * CREST_CROSS_DISTANCE_M,
					center.y + float(zi - half) * GRID_STEP_M + forward.z * CREST_CROSS_DISTANCE_M
				)
				var upstream_height := _sample_grid_height(heights, valid, cell_count, center, upstream)
				var downstream_height := _sample_grid_height(heights, valid, cell_count, center, downstream)
				if upstream_height == -INF or downstream_height == -INF:
					continue
				var rise := crest_height - upstream_height
				var fall := crest_height - downstream_height
				if rise < 0.12 or fall < 0.12:
					continue
				var score := minf(rise, fall) + 0.20 * (rise + fall)
				var yaw := atan2(-forward.x, -forward.z)
				var profile := {
					"crest_xz": Vector2(positions[index].x, positions[index].z),
					"forward": forward,
					"yaw": yaw,
					"crest_height": crest_height,
					"rise_m": rise,
					"fall_m": fall,
					"score": score,
					"cross_distance_m": CREST_CROSS_DISTANCE_M,
				}
				_add_profile_if_diverse(profiles, profile)
	profiles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.score) > float(b.score)
	)
	if profiles.size() > 120:
		profiles.resize(120)
	return profiles


func _is_grid_local_peak(heights: PackedFloat32Array, valid: PackedByteArray,
		cell_count: int, xi: int, zi: int) -> bool:
	var center_index := zi * cell_count + xi
	var center_height := float(heights[center_index])
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var neighbor_index := (zi + dz) * cell_count + xi + dx
			if valid[neighbor_index] == 0 or float(heights[neighbor_index]) > center_height:
				return false
	return true


func _sample_grid_height(heights: PackedFloat32Array, valid: PackedByteArray,
		cell_count: int, center: Vector2, point: Vector2) -> float:
	var half := floori(float(cell_count) * 0.5)
	var gx := (point.x - center.x) / GRID_STEP_M + float(half)
	var gz := (point.y - center.y) / GRID_STEP_M + float(half)
	var x0 := clampi(int(floor(gx)), 0, cell_count - 2)
	var z0 := clampi(int(floor(gz)), 0, cell_count - 2)
	var tx := clampf(gx - float(x0), 0.0, 1.0)
	var tz := clampf(gz - float(z0), 0.0, 1.0)
	var indices := [
		z0 * cell_count + x0,
		z0 * cell_count + x0 + 1,
		(z0 + 1) * cell_count + x0,
		(z0 + 1) * cell_count + x0 + 1
	]
	for index in indices:
		if valid[index] == 0:
			return -INF
	var top := lerpf(heights[indices[0]], heights[indices[1]], tx)
	var bottom := lerpf(heights[indices[2]], heights[indices[3]], tx)
	return lerpf(top, bottom, tz)


func _add_profile_if_diverse(profiles: Array[Dictionary], candidate: Dictionary) -> void:
	for existing in profiles:
		var existing_xz: Vector2 = existing.crest_xz
		var candidate_xz: Vector2 = candidate.crest_xz
		if existing_xz.distance_to(candidate_xz) < 5.0:
			var existing_forward: Vector3 = existing.forward
			var candidate_forward: Vector3 = candidate.forward
			if existing_forward.dot(candidate_forward) > 0.90:
				if float(candidate.score) > float(existing.score):
					existing.merge(candidate, true)
				return
	profiles.append(candidate)


func _run_case_with_profile_search(game_root: Node, ski: JetSkiController,
		physics: JetSkiWaterPhysicsSystem, provider: Node, case_data: Dictionary,
		profiles: Array[Dictionary], case_index: int, fixed_wave_time: float) -> Dictionary:
	var chosen: Dictionary = {}
	var profile_attempts := mini(MAX_CANDIDATES_PER_CASE, profiles.size())
	for profile_attempt in profile_attempts:
		var profile_index := posmod(case_index * 11 + profile_attempt * 7, profiles.size())
		var variant: Dictionary = profiles[profile_index].duplicate(true)
		var distances := [6.0, 8.0, 10.0]
		variant["start_distance_m"] = distances[profile_attempt % distances.size()]
		variant["start_immersion_m"] = START_IMMERSION_M if profile_attempt % 2 == 0 else 0.20
		var current_valid := int(_case_valid_counts.get(case_data.name, 0))
		for repetition in range(current_valid + 1, TARGET_PAIRS_PER_CASE + 1):
			var pair := await _run_pair(game_root, ski, physics, provider, case_data,
				variant, repetition, fixed_wave_time)
			if not bool(pair.get("matched", false)):
				break
			chosen = variant
			_case_profiles[case_data.name] = variant
		if int(_case_valid_counts.get(case_data.name, 0)) >= TARGET_PAIRS_PER_CASE:
			return chosen
	return chosen


func _run_fixed_profile_case(game_root: Node, ski: JetSkiController,
		physics: JetSkiWaterPhysicsSystem, provider: Node, case_data: Dictionary,
		profile: Dictionary, fixed_wave_time: float) -> void:
	_case_profiles[case_data.name] = profile
	for repetition in TARGET_PAIRS_PER_CASE:
		await _run_pair(game_root, ski, physics, provider, case_data, profile,
			repetition + 1, fixed_wave_time)


func _run_pair(_game_root: Node, ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		provider: Node, case_data: Dictionary, profile: Dictionary, repetition: int,
		fixed_wave_time: float) -> Dictionary:
	var attempt_key := str(case_data.name)
	_attempt_counts[attempt_key] = int(_attempt_counts.get(attempt_key, 0)) + 1
	var shared_pose := _build_trial_pose(provider, physics, profile)
	if not shared_pose.origin.is_finite():
		_no_takeoff_counts["OFF"] = int(_no_takeoff_counts.OFF) + 1
		_no_takeoff_counts["ON"] = int(_no_takeoff_counts.ON) + 1
		_case_failed_counts[attempt_key] = int(_case_failed_counts.get(attempt_key, 0)) + 1
		return {"matched": false, "off": {"valid": false, "classification": "NO_SURFACE_SAMPLE"},
			"on": {"valid": false, "classification": "NO_SURFACE_SAMPLE"}}
	var off := await _run_trial(ski, physics, case_data, profile, false, fixed_wave_time, shared_pose)
	var on := await _run_trial(ski, physics, case_data, profile, true, fixed_wave_time, shared_pose)
	var phase_locked := _same_start_state(off.get("initial", {}), on.get("initial", {}), fixed_wave_time)
	var both_valid := bool(off.get("valid", false)) and bool(on.get("valid", false))
	var matched := phase_locked and both_valid
	if not phase_locked:
		print("FEEL3C PHASE MISMATCH | OFF=%s | ON=%s" % [
			str(off.get("initial", {})), str(on.get("initial", {}))])
	var delta: Dictionary = {}
	for item in [{"mode": "OFF", "trial": off}, {"mode": "ON", "trial": on}]:
		var mode: String = item.mode
		var trial: Dictionary = item.trial
		if bool(trial.get("valid", false)):
			_valid_launch_counts[mode] = int(_valid_launch_counts[mode]) + 1
		else:
			_no_takeoff_counts[mode] = int(_no_takeoff_counts[mode]) + 1
	if not phase_locked:
		_phase_rejected_count += 1
	if matched:
		_valid_mode_trials["OFF"].append(off)
		_valid_mode_trials["ON"].append(on)
		_case_valid_counts[attempt_key] = int(_case_valid_counts.get(attempt_key, 0)) + 1
		delta = _release_delta(off, on)
		_pair_release_deltas.append(delta)
		if case_data.name == "RIDER NEUTRAL REFERENCE":
			_rider_neutral_pitch_rates.append(float(on.release.pitch_rate_rad_s))
			_rider_neutral_roll_rates.append(float(on.release.roll_rate_rad_s))
		elif case_data.name.begins_with("F ") or case_data.name.begins_with("G ") or case_data.name.begins_with("H ") or case_data.name.begins_with("I "):
			_append_rider_intent_result(case_data, on)
	else:
		_case_failed_counts[attempt_key] = int(_case_failed_counts.get(attempt_key, 0)) + 1
	print("FEEL3C PAIR | %s | rep=%d | phase_locked=%s | OFF=%s/%s ON=%s/%s | matched=%s" % [
		case_data.name, repetition, str(phase_locked),
		str(off.get("classification", "NO_TAKEOFF")), str(off.get("valid", false)),
		str(on.get("classification", "NO_TAKEOFF")), str(on.get("valid", false)), str(matched)])
	if matched:
		print("FEEL3C RELEASE DELTA | %s | pitch=%.3f° roll=%.3f° yaw=%.3f° | vertical=%.3f m/s forward=%.3f m/s" % [
			case_data.name, float(delta.pitch_deg), float(delta.roll_deg), float(delta.yaw_deg),
			float(delta.vertical_m_s), float(delta.forward_m_s)])
	return {"matched": matched, "off": off, "on": on}


func _build_trial_pose(provider: Node, physics: JetSkiWaterPhysicsSystem,
		profile: Dictionary) -> Transform3D:
	var forward: Vector3 = profile.forward
	var basis := Basis(Vector3.UP, float(profile.yaw))
	var crest_xz: Vector2 = profile.crest_xz
	var distance := float(profile.get("start_distance_m", CREST_CROSS_DISTANCE_M))
	var start_xz := crest_xz - Vector2(forward.x, forward.z) * distance
	var start_y := _vehicle_surface_height(provider, physics, basis, start_xz,
		float(profile.get("start_immersion_m", START_IMMERSION_M)))
	if not is_finite(start_y):
		return Transform3D(Basis.IDENTITY, Vector3(NAN, NAN, NAN))
	return Transform3D(basis, Vector3(start_xz.x, start_y, start_xz.y))


func _run_trial(ski: JetSkiController, physics: JetSkiWaterPhysicsSystem,
		case_data: Dictionary, profile: Dictionary, assist_enabled: bool,
		fixed_wave_time: float, pose: Transform3D) -> Dictionary:
	_release_test_inputs()
	var forward: Vector3 = profile.forward
	var basis := pose.basis
	var distance := float(profile.get("start_distance_m", CREST_CROSS_DISTANCE_M))
	var start_xz := Vector2(pose.origin.x, pose.origin.z)
	var initial_local_rates := Vector3(
		float(case_data.get("pitch_rate_seed", 0.0)),
		float(case_data.get("yaw_rate_seed", 0.0)),
		float(case_data.get("roll_rate_seed", 0.0))
	)
	var initial_angular := basis * initial_local_rates
	ski.freeze = true
	ski.call("_teleport_and_reset", pose, &"feel_3c_validation_trial")
	physics.reset_takeoff_validation_history()
	physics.set_takeoff_assist_enabled(assist_enabled)
	await get_tree().physics_frame
	ski.global_transform = pose
	ski.linear_velocity = forward * float(case_data.speed_mps)
	ski.angular_velocity = initial_angular
	ski.sleeping = false
	ski.reset_physics_interpolation()
	var initial := {
		"wave_time": fixed_wave_time,
		"transform": ski.global_transform,
		"linear_velocity": ski.linear_velocity,
		"angular_velocity": ski.angular_velocity,
		"throttle": true,
		"steer": int(case_data.steer),
		"rider": case_data.rider,
	}
	physics.takeoff_rider_shift = case_data.rider
	Input.action_press("throttle")
	if int(case_data.steer) < 0:
		Input.action_press("steer_left")
	elif int(case_data.steer) > 0:
		Input.action_press("steer_right")
	if case_data.rider.x < 0.0:
		Input.action_press("rider_shift_left")
	elif case_data.rider.x > 0.0:
		Input.action_press("rider_shift_right")
	if case_data.rider.y < 0.0:
		Input.action_press("rider_shift_forward")
	elif case_data.rider.y > 0.0:
		Input.action_press("rider_shift_back")
	var launch_serial_before := physics.takeoff_event_serial
	ski.freeze = false

	var saw_contact := false
	var elapsed := 0.0
	var step := 1.0 / float(Engine.physics_ticks_per_second)
	var nav_state = ski.navigation_system.state
	while elapsed < MAX_LAUNCH_WAIT_S and not bool(nav_state.has_confirmed_airborne):
		await get_tree().physics_frame
		elapsed += step
		if physics.state.raw_contact_mask != 0:
			saw_contact = true
		nav_state = ski.navigation_system.state

	var result := {
		"valid": false,
		"classification": "NO_TAKEOFF",
		"initial": initial,
		"wave_time": fixed_wave_time,
		"saw_contact": saw_contact,
		"attempted_cross_m": 0.0,
	}
	if bool(nav_state.has_confirmed_airborne):
		var progress := (Vector2(ski.global_position.x, ski.global_position.z) - start_xz).dot(Vector2(forward.x, forward.z))
		var geometric_clearance := physics.state.maximum_signed_point_depth <= -ski.navigation_system.airborne_minimum_clearance
		var true_airborne := str(ski.navigation_system.get_navigation_state_name(nav_state.navigation_state)) == "AIRBORNE"
		var contacted_water := saw_contact and bool(nav_state.has_ever_contacted_water)
		var crossed_crest := progress >= distance
		var diagnostic: Dictionary = physics.takeoff_last_diagnostic.duplicate(true)
		var event_happened := int(diagnostic.get("serial", -1)) > launch_serial_before
		result["attempted_cross_m"] = progress
		result["valid"] = true_airborne and contacted_water and geometric_clearance and crossed_crest and event_happened and physics.state.raw_contact_mask == 0
		result["classification"] = str(diagnostic.get("classification", "NORMAL")) if event_happened else "NO_TRANSITION_EVENT"
		result["launch_elapsed_s"] = elapsed
		result["progress_m"] = progress
		result["geometric_clearance"] = geometric_clearance
		result["true_airborne"] = true_airborne
		result["contacted_water"] = contacted_water
		result["crossed_crest"] = crossed_crest
		result["diagnostic"] = diagnostic
		if bool(result.valid):
			var release := _capture_state(ski)
			result["release"] = release
			result["release_orientation"] = {
				"pitch_deg": release.pitch_deg,
				"roll_deg": release.roll_deg,
				"yaw_deg": release.yaw_deg
			}
			result["pitch_at_100ms_deg"] = 0.0
			result["roll_at_100ms_deg"] = 0.0
			result["pitch_rate_at_100ms"] = 0.0
			result["roll_rate_at_100ms"] = 0.0
			result["pitch_at_250ms_deg"] = 0.0
			result["roll_at_250ms_deg"] = 0.0
			result["pitch_rate_at_250ms"] = 0.0
			result["roll_rate_at_250ms"] = 0.0
			result["pitch_at_500ms_deg"] = 0.0
			result["roll_at_500ms_deg"] = 0.0
			result["pitch_rate_at_500ms"] = 0.0
			result["roll_rate_at_500ms"] = 0.0
			result["max_pitch_change_500ms_deg"] = 0.0
			result["max_roll_change_500ms_deg"] = 0.0
			result["flip_like_in_progress"] = false
			result["flip_like_complete"] = false
			result["mode_on"] = assist_enabled
			var previous_pitch := float(release.pitch_deg)
			var previous_roll := float(release.roll_deg)
			var cumulative_pitch := 0.0
			var cumulative_roll := 0.0
			for sample_time in FLIGHT_SAMPLE_SECONDS:
				while elapsed < float(result.launch_elapsed_s) + float(sample_time):
					await get_tree().physics_frame
					elapsed += step
					var snapshot := _capture_state(ski)
					cumulative_pitch += _wrapped_angle_delta_degrees(previous_pitch, float(snapshot.pitch_deg))
					cumulative_roll += _wrapped_angle_delta_degrees(previous_roll, float(snapshot.roll_deg))
					previous_pitch = float(snapshot.pitch_deg)
					previous_roll = float(snapshot.roll_deg)
					var pitch_change := absf(cumulative_pitch)
					var roll_change := absf(cumulative_roll)
					result["max_pitch_change_500ms_deg"] = maxf(
						float(result.max_pitch_change_500ms_deg), pitch_change)
					result["max_roll_change_500ms_deg"] = maxf(
						float(result.max_roll_change_500ms_deg), roll_change)
					if maxf(pitch_change, roll_change) >= 90.0:
						result["flip_like_in_progress"] = true
					if maxf(pitch_change, roll_change) >= 300.0:
						result["flip_like_complete"] = true
				var sample := _capture_state(ski)
				var time_ms := int(round(float(sample_time) * 1000.0))
				result["pitch_at_%dms_deg" % time_ms] = sample.pitch_deg
				result["roll_at_%dms_deg" % time_ms] = sample.roll_deg
				result["pitch_rate_at_%dms" % time_ms] = sample.pitch_rate_rad_s
				result["roll_rate_at_%dms" % time_ms] = sample.roll_rate_rad_s
			_print_trial_record(case_data, assist_enabled, 1, result)
	_release_test_inputs()
	return result


func _vehicle_surface_height(provider: Node, physics: JetSkiWaterPhysicsSystem,
		basis: Basis, start_xz: Vector2, immersion: float) -> float:
	var minimum_origin_y := INF
	for local_point in physics.get_buoyancy_local_points():
		var offset: Vector3 = basis * local_point
		var query := Vector3(start_xz.x + offset.x, 0.0, start_xz.y + offset.z)
		var sample: WaterSample3D = provider.call("sample_water", query)
		if sample == null or not sample.valid:
			return NAN
		minimum_origin_y = minf(minimum_origin_y, sample.surface_position.y - offset.y)
	return minimum_origin_y + immersion


func _capture_state(ski: JetSkiController) -> Dictionary:
	var basis := ski.global_transform.basis.orthonormalized()
	var local_rates := basis.inverse() * ski.angular_velocity
	var forward := -basis.z
	return {
		"pitch_deg": rad_to_deg(_pitch_angle(ski.global_transform)),
		"roll_deg": rad_to_deg(_roll_angle(ski.global_transform)),
		"yaw_deg": rad_to_deg(_yaw_angle(ski.global_transform)),
		"pitch_rate_rad_s": local_rates.x,
		"yaw_rate_rad_s": local_rates.y,
		"roll_rate_rad_s": local_rates.z,
		"forward_speed_m_s": ski.linear_velocity.dot(forward),
		"vertical_speed_m_s": ski.linear_velocity.y,
		"position": ski.global_position,
	}


func _print_trial_record(case_data: Dictionary, assist_enabled: bool, repetition: int,
		result: Dictionary) -> void:
	var mode := "ON" if assist_enabled else "OFF"
	var diag: Dictionary = result.diagnostic
	var release: Dictionary = result.release
	print("FEEL3C TRIAL | %s | %s | rep=%d | class=%s | wave=%.6f | pos=%s | crossed=%.2f m | intent=%s | release P/R/Y=%.2f/%.2f/%.2f° rates P/R/Y=%.3f/%.3f/%.3f rad/s forward/vertical=%.3f/%.3f m/s | cleaner P/R/Y %.3f→%.3f / %.3f→%.3f / %.3f→%.3f | impulse=%s N·m·s" % [
		mode, case_data.name, repetition, str(result.classification), float(result.wave_time),
		str(release.position), float(result.progress_m), str(case_data.rider),
		float(release.pitch_deg), float(release.roll_deg), float(release.yaw_deg),
		float(release.pitch_rate_rad_s), float(release.roll_rate_rad_s), float(release.yaw_rate_rad_s),
		float(release.forward_speed_m_s), float(release.vertical_speed_m_s),
		float(diag.get("pitch_rate_before_rad_s", 0.0)), float(diag.get("pitch_rate_after_rad_s", 0.0)),
		float(diag.get("roll_rate_before_rad_s", 0.0)), float(diag.get("roll_rate_after_rad_s", 0.0)),
		float(diag.get("yaw_rate_before_rad_s", 0.0)), float(diag.get("yaw_rate_after_rad_s", 0.0)),
		str(diag.get("correction_angular_impulse_world_nms", Vector3.ZERO))])
	var flight_mode := "ON" if bool(result.get("mode_on", false)) else "OFF"
	print("FEEL3C FLIGHT | ", case_data.name, " | ", flight_mode,
		" | +100 P/R=", result.get("pitch_at_100ms_deg", 0.0), "/", result.get("roll_at_100ms_deg", 0.0),
		"° rates=", result.get("pitch_rate_at_100ms", 0.0), "/", result.get("roll_rate_at_100ms", 0.0), " rad/s",
		" | +250 P/R=", result.get("pitch_at_250ms_deg", 0.0), "/", result.get("roll_at_250ms_deg", 0.0),
		"° rates=", result.get("pitch_rate_at_250ms", 0.0), "/", result.get("roll_rate_at_250ms", 0.0), " rad/s",
		" | +500 P/R=", result.get("pitch_at_500ms_deg", 0.0), "/", result.get("roll_at_500ms_deg", 0.0),
		"° rates=", result.get("pitch_rate_at_500ms", 0.0), "/", result.get("roll_rate_at_500ms", 0.0), " rad/s",
		" | max-change P/R=", result.max_pitch_change_500ms_deg, "/", result.max_roll_change_500ms_deg,
		"° flips=", result.flip_like_in_progress, "/", result.flip_like_complete)


func _same_start_state(off: Dictionary, on: Dictionary, fixed_wave_time: float) -> bool:
	if off.is_empty() or on.is_empty():
		return false
	var a: Dictionary = off.get("initial", {})
	var b: Dictionary = on.get("initial", {})
	var ta: Transform3D = a.get("transform", Transform3D.IDENTITY)
	var tb: Transform3D = b.get("transform", Transform3D.IDENTITY)
	var va: Vector3 = a.get("linear_velocity", Vector3.ZERO)
	var vb: Vector3 = b.get("linear_velocity", Vector3.ZERO)
	var wa: Vector3 = a.get("angular_velocity", Vector3.ZERO)
	var wb: Vector3 = b.get("angular_velocity", Vector3.ZERO)
	var wave_a := float(a.get("wave_time", -1.0))
	var wave_b := float(b.get("wave_time", -1.0))
	var phase_match := (absf(wave_a - wave_b) <= 0.000001
		and absf(wave_a - fixed_wave_time) <= 0.000001
		and absf(wave_b - fixed_wave_time) <= 0.000001)
	var pose_match := ta.is_equal_approx(tb)
	var linear_match := va.distance_squared_to(vb) <= 0.000000000001
	var angular_match := wa.distance_squared_to(wb) <= 0.000000000001
	var controls_match := bool(a.get("throttle", false)) == bool(b.get("throttle", false)) and int(a.get("steer", 0)) == int(b.get("steer", 0)) and (a.get("rider", Vector2.ZERO) as Vector2).is_equal_approx(b.get("rider", Vector2.ZERO) as Vector2)
	if not (phase_match and pose_match and linear_match and angular_match and controls_match):
		print("FEEL3C PHASE FLAGS | wave=%.9f/%.9f diff=%.9f pose=%s lin_d2=%.12f ang_d2=%.12f controls=%s" % [
			wave_a, wave_b, absf(wave_a - wave_b), str(pose_match), va.distance_squared_to(vb),
			wa.distance_squared_to(wb), str(controls_match)])
	return phase_match and pose_match and linear_match and angular_match and controls_match


func _release_delta(off: Dictionary, on: Dictionary) -> Dictionary:
	var a: Dictionary = off.release
	var b: Dictionary = on.release
	return {
		"pitch_deg": absf(_wrapped_angle_delta_degrees(float(a.pitch_deg), float(b.pitch_deg))),
		"roll_deg": absf(_wrapped_angle_delta_degrees(float(a.roll_deg), float(b.roll_deg))),
		"yaw_deg": absf(_wrapped_angle_delta_degrees(float(a.yaw_deg), float(b.yaw_deg))),
		"vertical_m_s": absf(float(a.vertical_speed_m_s) - float(b.vertical_speed_m_s)),
		"forward_m_s": absf(float(a.forward_speed_m_s) - float(b.forward_speed_m_s)),
	}


func _append_rider_intent_result(case_data: Dictionary, on_trial: Dictionary) -> void:
	var signed_rate := 0.0
	if case_data.name == "F RIDER BACK":
		signed_rate = float(on_trial.release.pitch_rate_rad_s)
	elif case_data.name == "G RIDER FORWARD":
		signed_rate = -float(on_trial.release.pitch_rate_rad_s)
	elif case_data.name == "H RIDER LEFT":
		signed_rate = float(on_trial.release.roll_rate_rad_s)
	elif case_data.name == "I RIDER RIGHT":
		signed_rate = -float(on_trial.release.roll_rate_rad_s)
	var rows: Array = _rider_intent_results.get(case_data.name, [])
	rows.append(signed_rate)
	_rider_intent_results[case_data.name] = rows


func _run_extreme_probes(game_root: Node, ski: JetSkiController,
		physics: JetSkiWaterPhysicsSystem, provider: Node, profiles: Array[Dictionary],
		fixed_wave_time: float) -> void:
	var extreme_cases := [
		{"name": "EXTREME PITCH RATE", "speed_mps": 15.0, "steer": 0, "rider": Vector2.ZERO, "pitch_rate_seed": 5.2},
		{"name": "EXTREME ROLL RATE", "speed_mps": 15.0, "steer": 0, "rider": Vector2.ZERO, "roll_rate_seed": 6.2},
	]
	for index in extreme_cases.size():
		if profiles.is_empty():
			break
		var profile := profiles[index % profiles.size()]
		var case_data: Dictionary = extreme_cases[index]
		var profile_variant: Dictionary = profile.duplicate(true)
		profile_variant["start_distance_m"] = 8.0
		profile_variant["start_immersion_m"] = START_IMMERSION_M
		var pair := await _run_pair(game_root, ski, physics, provider, case_data,
			profile_variant, 1, fixed_wave_time)
		_extreme_trials.append({"case": case_data.name, "pair": pair})
		print("FEEL3C EXTREME | %s | matched=%s | OFF=%s ON=%s | flips OFF=%s/%s ON=%s/%s" % [
			case_data.name, str(pair.matched),
			str(pair.off.get("classification", "NO_TAKEOFF")),
			str(pair.on.get("classification", "NO_TAKEOFF")),
			str(pair.off.get("flip_like_in_progress", false)), str(pair.off.get("flip_like_complete", false)),
			str(pair.on.get("flip_like_in_progress", false)), str(pair.on.get("flip_like_complete", false))])


func _print_summary(fixed_wave_time: float, scan_ms: float) -> void:
	var attempts := int(_attempt_counts.values().reduce(func(a, b): return a + b, 0))
	var matched_count := _pair_release_deltas.size()
	print("FEEL3C COUNTS | pair_attempts=%d | valid launches OFF=%d ON=%d | matched=%d | no-takeoff OFF=%d ON=%d | rejected_phase=%d" % [
		attempts, int(_valid_launch_counts.OFF), int(_valid_launch_counts.ON), matched_count,
		int(_no_takeoff_counts.OFF), int(_no_takeoff_counts.ON), _phase_rejected_count])
	for mode in ["OFF", "ON"]:
		var trials: Array = _valid_mode_trials[mode]
		var normal_trials: Array = []
		var extreme_count := 0
		for trial in trials:
			if str(trial.get("classification", "NORMAL")) == "EXTREME":
				extreme_count += 1
			else:
				normal_trials.append(trial)
		var pitch_rates := PackedFloat32Array()
		var roll_rates := PackedFloat32Array()
		for trial in normal_trials:
			var release: Dictionary = trial.release
			pitch_rates.append(absf(float(release.pitch_rate_rad_s)))
			roll_rates.append(absf(float(release.roll_rate_rad_s)))
		print("FEEL3C PRIMARY | %s | NORMAL=%d EXTREME=%d | pitch |rate| median/p95/max=%.3f/%.3f/%.3f rad/s | roll=%.3f/%.3f/%.3f rad/s" % [
			mode, normal_trials.size(), extreme_count, _median(pitch_rates), _percentile(pitch_rates, 0.95),
			_maximum(pitch_rates), _median(roll_rates), _percentile(roll_rates, 0.95), _maximum(roll_rates)])
		var pitch60 := 0
		var pitch45 := 0
		var roll30 := 0
		var roll45 := 0
		var pitch_changes := PackedFloat32Array()
		var roll_changes := PackedFloat32Array()
		var flip_progress := 0
		var flip_complete := 0
		for trial in normal_trials:
			var pc := float(trial.max_pitch_change_500ms_deg)
			var rc := float(trial.max_roll_change_500ms_deg)
			pitch_changes.append(pc)
			roll_changes.append(rc)
			if pc > 45.0: pitch45 += 1
			if pc > 60.0: pitch60 += 1
			if rc > 30.0: roll30 += 1
			if rc > 45.0: roll45 += 1
			if bool(trial.flip_like_in_progress): flip_progress += 1
			if bool(trial.flip_like_complete): flip_complete += 1
		print("FEEL3C THRESHOLDS | %s | roll>30=%d roll>45=%d pitch>45=%d pitch>60=%d | median change P/R=%.2f/%.2f° | flip-like in-progress=%d complete=%d" % [
			mode, roll30, roll45, pitch45, pitch60, _median(pitch_changes), _median(roll_changes), flip_progress, flip_complete])
	print("FEEL3C PRESERVATION | matched=%d | mean release delta P/R/Y=%.3f/%.3f/%.3f° | vertical/forward=%.3f/%.3f m/s | wave=%.6f | scan_cost=%.1f ms" % [
		matched_count, _mean_pair_delta("pitch_deg"), _mean_pair_delta("roll_deg"),
		_mean_pair_delta("yaw_deg"), _mean_pair_delta("vertical_m_s"), _mean_pair_delta("forward_m_s"),
		fixed_wave_time, scan_ms])
	for case_name in _attempt_counts:
		print("FEEL3C CASE | %s | attempts=%d matched=%d failed=%d" % [
			case_name, int(_attempt_counts[case_name]), int(_case_valid_counts.get(case_name, 0)),
			int(_case_failed_counts.get(case_name, 0))])
	for case_name in _rider_intent_results:
		var values: Array = _rider_intent_results[case_name]
		var neutral: Array[float] = _rider_neutral_roll_rates if case_name.begins_with("H ") or case_name.begins_with("I ") else _rider_neutral_pitch_rates
		var signed_mean := _mean_variant_array(values)
		var neutral_mean := _mean_float_array(neutral)
		print("FEEL3C RIDER INTENT | %s | intentional signed rate=%.3f neutral=%.3f delta=%.3f rad/s n=%d" % [
			case_name, signed_mean, neutral_mean, signed_mean - neutral_mean, values.size()])
	print("FEEL3C TARGET | required_pairs=%d reached=%s" % [
		REQUIRED_VALID_PAIRS, str(matched_count >= REQUIRED_VALID_PAIRS)])


func _extreme_count(mode: String) -> int:
	var count := 0
	for trial in _valid_mode_trials[mode]:
		if str(trial.get("classification", "")) == "EXTREME":
			count += 1
	return count


func _mean_variant_array(values: Array) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += float(value)
	return total / float(values.size())


func _mean_float_array(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _mean_pair_delta(key: String) -> float:
	if _pair_release_deltas.is_empty():
		return 0.0
	var total := 0.0
	for delta in _pair_release_deltas:
		total += float(delta.get(key, 0.0))
	return total / float(_pair_release_deltas.size())


func _median(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var middle := floori(float(sorted.size()) * 0.5)
	if sorted.size() % 2 == 1:
		return sorted[middle]
	return (sorted[middle - 1] + sorted[middle]) * 0.5


func _percentile(values: PackedFloat32Array, percentile: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(ceil(percentile * float(sorted.size()))) - 1, 0, sorted.size() - 1)
	return sorted[index]


func _maximum(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 0.0
	var result := 0.0
	for value in values:
		result = maxf(result, value)
	return result


func _pitch_angle(body_transform: Transform3D) -> float:
	var forward := -body_transform.basis.z.normalized()
	return atan2(forward.y, maxf(Vector2(forward.x, forward.z).length(), 0.0001))


func _roll_angle(body_transform: Transform3D) -> float:
	var right := body_transform.basis.x.normalized()
	return atan2(right.y, maxf(Vector2(right.x, right.z).length(), 0.0001))


func _yaw_angle(body_transform: Transform3D) -> float:
	var forward := -body_transform.basis.z.normalized()
	return atan2(forward.x, -forward.z)


func _wrapped_angle_delta_degrees(from_degrees: float, to_degrees: float) -> float:
	return rad_to_deg(wrapf(deg_to_rad(to_degrees - from_degrees), -PI, PI))


func _release_test_inputs() -> void:
	Input.action_release("throttle")
	Input.action_release("steer_left")
	Input.action_release("steer_right")
	Input.action_release("rider_shift_left")
	Input.action_release("rider_shift_right")
	Input.action_release("rider_shift_forward")
	Input.action_release("rider_shift_back")
