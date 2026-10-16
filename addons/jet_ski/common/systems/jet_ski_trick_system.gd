class_name JetSkiTrickSystem
extends Node

signal trick_launched(
	launch_type: JetSkiTypes.RiderTrickLaunchType,
	launch_charge: Vector2,
	release_strength: Vector2
)

const TrickPreloadState = JetSkiTypes.TrickPreloadState
const RiderTrickLaunchType = JetSkiTypes.RiderTrickLaunchType

const TRICK_PRE_TAKEOFF_OPTIMAL_TIME: float = 0.22
const TRICK_PRE_TAKEOFF_MINIMUM_TIMING: float = 0.65
const TRICK_POST_TAKEOFF_OPTIMAL_TIME: float = 0.10
const TRICK_POST_TAKEOFF_MINIMUM_TIMING: float = 0.50

var state: JetSkiTrickState = JetSkiTrickState.new()

var trick_preload_min_hold_time: float = 0.10
var trick_preload_full_charge_time: float = 0.35
var trick_preload_min_input: float = 0.55
var trick_reversal_min_input: float = 0.65
var trick_reversal_takeoff_window: float = 0.35
var trick_takeoff_coyote_time: float = 0.18
var trick_preload_decay_rate: float = 1.5
var trick_minimum_launch_speed: float = 5.0
var trick_full_launch_speed: float = 15.0
var trick_roll_release_torque: float = 7000.0
var trick_pitch_release_torque: float = 8500.0
var trick_release_duration: float = 0.16
var trick_minimum_release_charge: float = 0.15
var trick_release_curve_power: float = 0.85
var max_submersion_depth: float = 0.8


func begin_physics_tick() -> void:
	state.release_roll_torque = 0.0
	state.release_pitch_torque = 0.0


func get_reversal_time_remaining() -> float:
	return maxf(
		maxf(
			state.roll_reversal_time_remaining,
			state.pitch_reversal_time_remaining
		),
		0.0
	)


func get_launch_type_name(
	trick_type: JetSkiTypes.RiderTrickLaunchType
) -> StringName:
	match trick_type:
		RiderTrickLaunchType.BARREL_LEFT:
			return &"BARREL_L"
		RiderTrickLaunchType.BARREL_RIGHT:
			return &"BARREL_R"
		RiderTrickLaunchType.BACKFLIP:
			return &"BACKFLIP"
		RiderTrickLaunchType.FRONTFLIP:
			return &"FRONTFLIP"
		RiderTrickLaunchType.COMBINED:
			return &"COMBINED"
	return &"NONE"


func update_state(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState,
	water_state: JetSkiWaterState,
	navigation_state: JetSkiNavigationState,
	rider_weight_shift_enabled: bool,
	trick_preload_enabled: bool,
	submarine_active: bool,
	physics_delta: float
) -> void:
	var gained_support := (
		not navigation_state.previous_has_any_support
		and navigation_state.has_any_support
	)
	if gained_support:
		_reset_for_new_support_contact()
	if (
		not rider_weight_shift_enabled
		or not trick_preload_enabled
		or navigation_state.navigation_state
		== JetSkiTypes.NavigationState.DEEP_SUBMERGED
		or submarine_active
	):
		cancel_for_incompatible_medium()
		return
	_update_reversal_timers(physics_delta)
	var horizontal_speed := Vector2(
		body_state.linear_velocity.x,
		body_state.linear_velocity.z
	).length()
	var launch_speed_factor := smoothstep(
		trick_minimum_launch_speed,
		maxf(
			trick_full_launch_speed,
			trick_minimum_launch_speed + 0.001
		),
		horizontal_speed
	)
	if navigation_state.has_any_support:
		if navigation_state.has_water_support:
			state.last_contact_average_depth = water_state.average_depth
		elif navigation_state.has_solid_support:
			# A solid ramp has no buoyancy depth. Use the neutral midpoint of the
			# small 0.95-1.05 depth modifier instead of penalizing it.
			state.last_contact_average_depth = max_submersion_depth * 0.25
		state.takeoff_pending = false
		state.time_since_takeoff = 0.0
		_update_roll_preload(
			input_state.rider_shift_raw.x,
			physics_delta,
			false
		)
		_update_pitch_preload(
			input_state.rider_shift_raw.y,
			physics_delta,
			false
		)
	if navigation_state.true_takeoff_this_tick:
		_prepare_takeoff_context(
			body_state,
			launch_speed_factor,
			horizontal_speed >= trick_minimum_launch_speed
		)
		_try_start_release(false)
		if not state.launch_consumed:
			_detect_coyote_reversals(input_state)
			_try_start_release(true)
	elif state.takeoff_pending and not state.launch_consumed:
		state.time_since_takeoff += maxf(physics_delta, 0.0)
		if state.time_since_takeoff <= trick_takeoff_coyote_time:
			_detect_coyote_reversals(input_state)
			_try_start_release(true)
		else:
			_cancel_expired_takeoff()
	_update_preload_state_metric()


func calculate_release_torque(
	body_forward: Vector3,
	body_right: Vector3,
	physics_delta: float
) -> Vector3:
	if not state.release_active:
		return Vector3.ZERO
	var safe_duration := maxf(trick_release_duration, 0.001)
	var sampled_release_time := minf(
		state.release_elapsed + maxf(physics_delta, 0.0) * 0.5,
		safe_duration
	)
	var normalized_release_time := clampf(
		sampled_release_time / safe_duration,
		0.0,
		1.0
	)
	var release_envelope := sin(normalized_release_time * PI)
	state.release_roll_torque = (
		state.release_strength.x
		* trick_roll_release_torque
		* release_envelope
	)
	state.release_pitch_torque = (
		state.release_strength.y
		* trick_pitch_release_torque
		* release_envelope
	)
	var release_torque := (
		body_forward * state.release_roll_torque
		+ body_right * state.release_pitch_torque
	)
	state.release_elapsed = minf(
		state.release_elapsed + maxf(physics_delta, 0.0),
		safe_duration
	)
	state.release_time_remaining = maxf(
		safe_duration - state.release_elapsed,
		0.0
	)
	if state.release_elapsed >= safe_duration:
		state.release_active = false
		_update_preload_state_metric()
	return release_torque


func cancel_for_submarine() -> void:
	cancel_for_incompatible_medium()


func cancel_for_incompatible_medium() -> void:
	state.takeoff_pending = false
	state.pending_launch_speed_valid = false
	state.release_active = false
	state.release_elapsed = 0.0
	state.release_time_remaining = 0.0
	state.release_strength = Vector2.ZERO
	state.release_charge = Vector2.ZERO
	state.release_roll_torque = 0.0
	state.release_pitch_torque = 0.0
	state.launch_consumed = true
	_clear_roll_preload()
	_clear_pitch_preload()
	_update_preload_state_metric()


func reset_runtime_state() -> void:
	state.reset_runtime_state()


func classify_launch(
	release_strength: Vector2
) -> JetSkiTypes.RiderTrickLaunchType:
	var has_roll := absf(release_strength.x) > 0.0001
	var has_pitch := absf(release_strength.y) > 0.0001
	if has_roll and has_pitch:
		return RiderTrickLaunchType.COMBINED
	if release_strength.x > 0.0:
		return RiderTrickLaunchType.BARREL_RIGHT
	if release_strength.x < 0.0:
		return RiderTrickLaunchType.BARREL_LEFT
	if release_strength.y > 0.0:
		return RiderTrickLaunchType.BACKFLIP
	if release_strength.y < 0.0:
		return RiderTrickLaunchType.FRONTFLIP
	return RiderTrickLaunchType.NONE


func _update_roll_preload(
	axis_input: float,
	physics_delta: float,
	allow_air_reversal: bool
) -> void:
	if state.roll_reversal_armed:
		return
	var input_magnitude := absf(axis_input)
	var input_sign := signf(axis_input)
	if (
		input_magnitude >= trick_reversal_min_input
		and input_sign == -state.roll_preload_sign
		and state.roll_preload_sign != 0.0
		and state.roll_hold_time >= trick_preload_min_hold_time
		and state.roll_charge >= trick_minimum_release_charge
	):
		state.roll_reversal_armed = true
		state.roll_reversal_direction = input_sign
		state.roll_armed_charge = state.roll_charge
		state.roll_reversal_time_remaining = (
			trick_takeoff_coyote_time - state.time_since_takeoff
			if allow_air_reversal
			else trick_reversal_takeoff_window
		)
		return
	if allow_air_reversal:
		return
	if input_magnitude >= trick_preload_min_input:
		if state.roll_preload_sign == 0.0:
			state.roll_preload_sign = input_sign
		if input_sign == state.roll_preload_sign:
			state.roll_hold_time += maxf(physics_delta, 0.0)
			state.roll_charge = minf(
				state.roll_charge
				+ maxf(physics_delta, 0.0)
				/ maxf(trick_preload_full_charge_time, 0.001)
				* input_magnitude,
				1.0
			)
			return
	_decay_roll_preload(physics_delta)


func _update_pitch_preload(
	axis_input: float,
	physics_delta: float,
	allow_air_reversal: bool
) -> void:
	if state.pitch_reversal_armed:
		return
	var input_magnitude := absf(axis_input)
	var input_sign := signf(axis_input)
	if (
		input_magnitude >= trick_reversal_min_input
		and input_sign == -state.pitch_preload_sign
		and state.pitch_preload_sign != 0.0
		and state.pitch_hold_time >= trick_preload_min_hold_time
		and state.pitch_charge >= trick_minimum_release_charge
	):
		state.pitch_reversal_armed = true
		state.pitch_reversal_direction = input_sign
		state.pitch_armed_charge = state.pitch_charge
		state.pitch_reversal_time_remaining = (
			trick_takeoff_coyote_time - state.time_since_takeoff
			if allow_air_reversal
			else trick_reversal_takeoff_window
		)
		return
	if allow_air_reversal:
		return
	if input_magnitude >= trick_preload_min_input:
		if state.pitch_preload_sign == 0.0:
			state.pitch_preload_sign = input_sign
		if input_sign == state.pitch_preload_sign:
			state.pitch_hold_time += maxf(physics_delta, 0.0)
			state.pitch_charge = minf(
				state.pitch_charge
				+ maxf(physics_delta, 0.0)
				/ maxf(trick_preload_full_charge_time, 0.001)
				* input_magnitude,
				1.0
			)
			return
	_decay_pitch_preload(physics_delta)


func _detect_coyote_reversals(input_state: JetSkiInputState) -> void:
	_update_roll_preload(
		input_state.rider_shift_raw.x,
		0.0,
		true
	)
	_update_pitch_preload(
		input_state.rider_shift_raw.y,
		0.0,
		true
	)


func _prepare_takeoff_context(
	body_state: PhysicsDirectBodyState3D,
	launch_speed_factor: float,
	launch_speed_valid: bool
) -> void:
	state.takeoff_pending = true
	state.time_since_takeoff = 0.0
	state.takeoff_quality = 0.0
	state.takeoff_timing_factor = 0.0
	state.pending_speed_factor = launch_speed_factor
	state.pending_launch_speed_valid = launch_speed_valid
	state.pending_upward_factor = smoothstep(
		0.0,
		6.0,
		maxf(body_state.linear_velocity.y, 0.0)
	)
	state.pending_depth_factor = smoothstep(
		0.0,
		maxf(max_submersion_depth * 0.5, 0.001),
		state.last_contact_average_depth
	)


func _try_start_release(using_coyote_time: bool) -> void:
	if state.launch_consumed or state.release_active:
		return
	if not state.pending_launch_speed_valid:
		return
	var roll_charge := (
		state.roll_armed_charge
		if state.roll_reversal_armed
		else 0.0
	)
	var pitch_charge := (
		state.pitch_armed_charge
		if state.pitch_reversal_armed
		else 0.0
	)
	if (
		roll_charge < trick_minimum_release_charge
		and pitch_charge < trick_minimum_release_charge
	):
		return
	var roll_timing_factor := (
		_reversal_timing_factor(
			state.roll_reversal_time_remaining,
			using_coyote_time
		)
		if state.roll_reversal_armed
		else 0.0
	)
	var pitch_timing_factor := (
		_reversal_timing_factor(
			state.pitch_reversal_time_remaining,
			using_coyote_time
		)
		if state.pitch_reversal_armed
		else 0.0
	)
	state.takeoff_timing_factor = maxf(
		roll_timing_factor,
		pitch_timing_factor
	)
	var roll_quality := _calculate_takeoff_quality(roll_timing_factor)
	var pitch_quality := _calculate_takeoff_quality(pitch_timing_factor)
	var release_strength := Vector2(
		state.roll_reversal_direction
			* pow(roll_charge, trick_release_curve_power)
			* roll_quality,
		state.pitch_reversal_direction
			* pow(pitch_charge, trick_release_curve_power)
			* pitch_quality
	)
	if release_strength.length_squared() > 1.0:
		release_strength = release_strength.normalized()
	if release_strength.is_zero_approx():
		return
	state.takeoff_quality = maxf(roll_quality, pitch_quality)
	_start_release(
		release_strength,
		Vector2(
			state.roll_preload_sign * roll_charge,
			state.pitch_preload_sign * pitch_charge
		)
	)


func _reversal_timing_factor(
	reversal_time_remaining: float,
	using_coyote_time: bool
) -> float:
	if using_coyote_time:
		if trick_takeoff_coyote_time <= 0.0:
			return 1.0 if state.time_since_takeoff <= 0.0 else 0.0
		if state.time_since_takeoff <= TRICK_POST_TAKEOFF_OPTIMAL_TIME:
			return 1.0
		var post_takeoff_blend := smoothstep(
			TRICK_POST_TAKEOFF_OPTIMAL_TIME,
			maxf(
				trick_takeoff_coyote_time,
				TRICK_POST_TAKEOFF_OPTIMAL_TIME + 0.001
			),
			state.time_since_takeoff
		)
		return lerpf(
			1.0,
			TRICK_POST_TAKEOFF_MINIMUM_TIMING,
			post_takeoff_blend
		)
	var reversal_age := maxf(
		trick_reversal_takeoff_window - reversal_time_remaining,
		0.0
	)
	if reversal_age <= TRICK_PRE_TAKEOFF_OPTIMAL_TIME:
		return 1.0
	var pre_takeoff_blend := smoothstep(
		TRICK_PRE_TAKEOFF_OPTIMAL_TIME,
		maxf(
			trick_reversal_takeoff_window,
			TRICK_PRE_TAKEOFF_OPTIMAL_TIME + 0.001
		),
		reversal_age
	)
	return lerpf(
		1.0,
		TRICK_PRE_TAKEOFF_MINIMUM_TIMING,
		pre_takeoff_blend
	)


func _calculate_takeoff_quality(
	reversal_timing_factor: float
) -> float:
	var speed_quality := lerpf(
		0.65,
		1.0,
		state.pending_speed_factor
	)
	var upward_bonus := lerpf(
		0.90,
		1.05,
		state.pending_upward_factor
	)
	var depth_bonus := lerpf(
		0.95,
		1.05,
		state.pending_depth_factor
	)
	return clampf(
		reversal_timing_factor
		* speed_quality
		* upward_bonus
		* depth_bonus,
		0.0,
		1.1
	)


func _start_release(
	release_strength: Vector2,
	launch_charge: Vector2
) -> void:
	state.release_active = true
	state.release_elapsed = 0.0
	state.release_time_remaining = trick_release_duration
	state.release_strength = release_strength
	state.release_charge = launch_charge
	state.launch_consumed = true
	state.takeoff_pending = false
	state.pending_launch_speed_valid = false
	state.last_launch_type = classify_launch(release_strength)
	state.last_launch_charge = launch_charge
	state.last_release_strength = release_strength
	_clear_roll_preload()
	_clear_pitch_preload()
	state.preload_state = TrickPreloadState.RELEASE_ACTIVE
	trick_launched.emit(
		state.last_launch_type,
		launch_charge,
		release_strength
	)


func _update_reversal_timers(physics_delta: float) -> void:
	if state.roll_reversal_armed:
		state.roll_reversal_time_remaining = (
			state.roll_reversal_time_remaining - maxf(physics_delta, 0.0)
		)
		if state.roll_reversal_time_remaining < -0.0001:
			_clear_roll_preload()
	if state.pitch_reversal_armed:
		state.pitch_reversal_time_remaining = (
			state.pitch_reversal_time_remaining - maxf(physics_delta, 0.0)
		)
		if state.pitch_reversal_time_remaining < -0.0001:
			_clear_pitch_preload()


func _decay_roll_preload(physics_delta: float) -> void:
	state.roll_charge = move_toward(
		state.roll_charge,
		0.0,
		maxf(physics_delta, 0.0) * trick_preload_decay_rate
	)
	if state.roll_charge <= 0.0001:
		_clear_roll_preload()


func _decay_pitch_preload(physics_delta: float) -> void:
	state.pitch_charge = move_toward(
		state.pitch_charge,
		0.0,
		maxf(physics_delta, 0.0) * trick_preload_decay_rate
	)
	if state.pitch_charge <= 0.0001:
		_clear_pitch_preload()


func _clear_roll_preload() -> void:
	state.roll_preload_sign = 0.0
	state.roll_hold_time = 0.0
	state.roll_charge = 0.0
	state.roll_reversal_armed = false
	state.roll_reversal_direction = 0.0
	state.roll_armed_charge = 0.0
	state.roll_reversal_time_remaining = 0.0


func _clear_pitch_preload() -> void:
	state.pitch_preload_sign = 0.0
	state.pitch_hold_time = 0.0
	state.pitch_charge = 0.0
	state.pitch_reversal_armed = false
	state.pitch_reversal_direction = 0.0
	state.pitch_armed_charge = 0.0
	state.pitch_reversal_time_remaining = 0.0


func _cancel_expired_takeoff() -> void:
	state.takeoff_pending = false
	state.pending_launch_speed_valid = false
	state.launch_consumed = true
	_clear_roll_preload()
	_clear_pitch_preload()


func _reset_for_new_support_contact() -> void:
	state.launch_consumed = false
	state.takeoff_pending = false
	state.time_since_takeoff = 0.0
	state.pending_launch_speed_valid = false
	state.release_active = false
	state.release_elapsed = 0.0
	state.release_time_remaining = 0.0
	state.release_strength = Vector2.ZERO
	state.release_charge = Vector2.ZERO
	state.release_roll_torque = 0.0
	state.release_pitch_torque = 0.0
	_clear_roll_preload()
	_clear_pitch_preload()


func _update_preload_state_metric() -> void:
	if state.release_active:
		state.preload_state = TrickPreloadState.RELEASE_ACTIVE
	elif state.roll_reversal_armed or state.pitch_reversal_armed:
		state.preload_state = TrickPreloadState.REVERSAL_ARMED
	elif state.roll_charge > 0.0 or state.pitch_charge > 0.0:
		state.preload_state = TrickPreloadState.CHARGING
	else:
		state.preload_state = TrickPreloadState.IDLE
