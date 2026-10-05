class_name JetSkiRiderDynamicsSystem
extends Node

const BUOYANCY_POINT_COUNT: int = 4
const FRONT_POINT_COUNT: int = 2
const FRONT_CONTACT_MASK: int = 3
const REAR_CONTACT_MASK: int = 12
const TURN_LEAN_STEERING_EXPONENT: float = 0.9
const TURN_LEAN_DAMPING_RATE_REDUCTION_LIMIT: float = 0.5
const HALF_LIFE_LOG_TWO: float = 0.6931471805599453
const RIDER_SOFT_LIMIT_BLEND_DEGREES: float = 8.0
const SUBMARINE_MANUAL_DAMPING_FACTOR: float = 0.35
const DIRECTION_EPSILON_SQUARED: float = 0.000001

var state: JetSkiRiderDynamicsState = JetSkiRiderDynamicsState.new()

var turn_lean_enabled: bool = true
var turn_lean_max_angle_degrees: float = 18.0
var turn_lean_start_speed: float = 3.0
var turn_lean_full_speed: float = 16.0
var turn_lean_stiffness: float = 16000.0
var turn_lean_damping: float = 4200.0
var turn_lean_max_torque: float = 8500.0
var turn_lean_reverse_factor: float = 0.35
var turn_lean_landing_ramp_time: float = 0.12
var turn_lean_support_normal_half_life: float = 0.08

var rider_weight_shift_enabled: bool = true
var rider_shift_input_half_life: float = 0.10
var rider_shift_release_half_life: float = 0.20
var rider_effective_mass: float = 85.0
var rider_lateral_shift_distance: float = 0.48
var rider_longitudinal_shift_distance: float = 0.72
var rider_weight_torque_multiplier: float = 6.0
var rider_roll_rate_damping: float = 1800.0
var rider_pitch_rate_damping: float = 2200.0
var rider_shift_standstill_authority: float = 1.0
var rider_shift_full_speed: float = 9.0
var rider_shift_deep_submerged_authority: float = 0.65
var rider_shift_landing_ramp_time: float = 0.15
var rider_shift_auto_upright_factor: float = 0.20
var rider_manual_roll_max_angle_degrees: float = 16.0
var rider_wheelie_throttle_boost: float = 0.85
var rider_nose_dive_speed_boost: float = 0.55
var rider_roll_soft_limit_degrees: float = 32.0
var rider_nose_up_soft_limit_degrees: float = 34.0
var rider_nose_down_soft_limit_degrees: float = 38.0
var rider_soft_limit_stiffness: float = 12000.0
var rider_soft_limit_damping: float = 3000.0
var rider_air_max_roll_rate: float = 12.0
var rider_air_max_pitch_rate: float = 10.0
var rider_air_overspeed_damping: float = 1800.0
var air_correction_roll_torque: float = 1000.0
var air_correction_pitch_torque: float = 1300.0
var air_correction_target_roll_rate: float = 1.8
var air_correction_target_pitch_rate: float = 1.6
var air_counter_input_brake_multiplier: float = 1.8

var buoyancy_strength_per_point: float = 5500.0
var max_submersion_depth: float = 0.8

var _water_point_source: JetSkiWaterPhysicsSystem
var _prepared_vehicle_basis: Basis = Basis.IDENTITY
var _prepared_body_forward: Vector3 = Vector3.FORWARD
var _prepared_body_right: Vector3 = Vector3.RIGHT
var _body_axes_valid: bool = false
var _warning_emitted: bool = false
var _air_warning_emitted: bool = false
var _warning_emission_count: int = 0


func configure(water_point_source: JetSkiWaterPhysicsSystem) -> void:
	_water_point_source = water_point_source


func begin_physics_tick() -> void:
	state.clear_frame_metrics()


func prepare_mode(
	body_state: PhysicsDirectBodyState3D,
	navigation_state: JetSkiNavigationState
) -> bool:
	state.using_air_control = not navigation_state.has_any_support
	state.turn_lean_airborne_disabled = state.using_air_control
	state.rider_shift_airborne = state.using_air_control
	_prepared_vehicle_basis = body_state.transform.basis.orthonormalized()
	var vehicle_up := _prepared_vehicle_basis.y
	var vehicle_forward := -_prepared_vehicle_basis.z
	_prepared_body_forward = vehicle_forward
	_prepared_body_right = _prepared_vehicle_basis.x
	_body_axes_valid = (
		vehicle_up.is_finite()
		and vehicle_forward.is_finite()
	)
	if not _body_axes_valid:
		_warn_once("Rider weight-shift body axes are not finite.")
	return state.using_air_control


func has_valid_body_axes() -> bool:
	return _body_axes_valid


func update_air_rotation_metrics(
	body_state: PhysicsDirectBodyState3D
) -> void:
	if not state.using_air_control:
		state.air_unlimited_rotation = false
		state.air_roll_rate = 0.0
		state.air_pitch_rate = 0.0
		state.air_tracking_active = false
		return
	if not state.air_tracking_active:
		state.air_accumulated_roll_degrees = 0.0
		state.air_accumulated_pitch_degrees = 0.0
		state.air_tracking_active = true
	state.air_unlimited_rotation = true
	state.air_roll_rate = body_state.angular_velocity.dot(
		_prepared_body_forward
	)
	state.air_pitch_rate = body_state.angular_velocity.dot(
		_prepared_body_right
	)
	if (
		not is_finite(state.air_roll_rate)
		or not is_finite(state.air_pitch_rate)
	):
		_warn_air_once("Rider air rotation rates are not finite.")
	state.air_accumulated_roll_degrees += rad_to_deg(
		state.air_roll_rate * body_state.step
	)
	state.air_accumulated_pitch_degrees += rad_to_deg(
		state.air_pitch_rate * body_state.step
	)


func prepare_common_metrics(
	input_state: JetSkiInputState,
	water_state: JetSkiWaterState,
	navigation_state: JetSkiNavigationState,
	drive_state: JetSkiDriveState,
	submarine_dive_active: bool
) -> void:
	_update_rider_shift_speed_authority(water_state)
	_update_rider_shift_contact_metrics(
		navigation_state,
		submarine_dive_active
	)
	_update_rider_shift_obsolete_target_metrics()
	if (
		rider_weight_shift_enabled
		and not input_state.rider_shift_smoothed.is_zero_approx()
		and absf(input_state.steering) <= 0.0001
	):
		state.arrow_only_steering_input = input_state.steering
		state.arrow_only_steering_angle = drive_state.steering_angle_degrees


func prepare_air_metrics(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState
) -> bool:
	var air_attitude := calculate_world_attitude(
		body_state.transform
	)
	state.turn_lean_current_roll = air_attitude.x
	state.rider_shift_current_pitch = air_attitude.y
	if not air_attitude.is_finite():
		_warn_air_once("Rider air attitude is not finite.")
		return false
	if not rider_weight_shift_enabled:
		return false
	state.rider_shift_air_authority_active = 1.0
	if (
		not _prepared_body_forward.is_finite()
		or not _prepared_body_right.is_finite()
		or _prepared_body_forward.length_squared()
		<= DIRECTION_EPSILON_SQUARED
		or _prepared_body_right.length_squared()
		<= DIRECTION_EPSILON_SQUARED
	):
		_warn_air_once("Rider weight-shift air axes are degenerate.")
		return false
	state.virtual_offset_local = Vector3(
		input_state.rider_shift_raw.x * rider_lateral_shift_distance,
		0.0,
		input_state.rider_shift_raw.y
		* rider_longitudinal_shift_distance
	)
	state.virtual_offset_world = (
		_prepared_vehicle_basis * state.virtual_offset_local
	)
	return true


func apply_air_torque(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState,
	external_trick_release_torque: Vector3
) -> JetSkiRiderDynamicsState:
	# Air control uses normalized raw input so releasing the arrows produces
	# zero correction torque in the same physics tick.
	state.air_correction_roll_torque_current = (
		_calculate_air_rate_correction_torque(
			state.air_roll_rate,
			input_state.rider_shift_raw.x,
			air_correction_target_roll_rate,
			air_correction_roll_torque
		)
	)
	state.air_correction_pitch_torque_current = (
		_calculate_air_rate_correction_torque(
			state.air_pitch_rate,
			input_state.rider_shift_raw.y,
			air_correction_target_pitch_rate,
			air_correction_pitch_torque
		)
	)
	var air_torque := (
		external_trick_release_torque
		+ _prepared_body_forward
		* state.air_correction_roll_torque_current
		+ _prepared_body_right
		* state.air_correction_pitch_torque_current
		+ _prepared_body_forward
		* _calculate_rider_air_overspeed_torque(
			state.air_roll_rate,
			input_state.rider_shift_raw.x,
			rider_air_max_roll_rate
		)
		+ _prepared_body_right
		* _calculate_rider_air_overspeed_torque(
			state.air_pitch_rate,
			input_state.rider_shift_raw.y,
			rider_air_max_pitch_rate
		)
	)
	if not air_torque.is_finite():
		state.rider_shift_roll_torque = 0.0
		state.rider_shift_pitch_torque = 0.0
		_warn_air_once("Rider weight-shift air torque is not finite.")
		return state
	state.rider_shift_roll_torque = air_torque.dot(
		_prepared_body_forward
	)
	state.rider_shift_pitch_torque = air_torque.dot(
		_prepared_body_right
	)
	state.manual_applied_torque = air_torque
	state.total_applied_torque_vector = air_torque
	if not air_torque.is_zero_approx():
		body_state.apply_torque(air_torque)
	return state


func get_prepared_body_forward() -> Vector3:
	return _prepared_body_forward


func get_prepared_body_right() -> Vector3:
	return _prepared_body_right


func calculate_world_attitude(
	vehicle_transform: Transform3D
) -> Vector2:
	var vehicle_basis := vehicle_transform.basis.orthonormalized()
	var vehicle_forward := -vehicle_basis.z
	var vehicle_up := vehicle_basis.y
	var pitch := asin(clampf(vehicle_forward.y, -1.0, 1.0))
	var horizontal_forward := vehicle_forward.slide(Vector3.UP)
	var reference_right := vehicle_basis.x
	if (
		horizontal_forward.length_squared()
		> DIRECTION_EPSILON_SQUARED
	):
		horizontal_forward = horizontal_forward.normalized()
		reference_right = horizontal_forward.cross(
			Vector3.UP
		).normalized()
	var roll := atan2(
		vehicle_up.dot(reference_right),
		vehicle_up.dot(Vector3.UP)
	)
	return Vector2(roll, pitch)


func prepare_supported(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState,
	water_state: JetSkiWaterState,
	navigation_state: JetSkiNavigationState,
	drive_state: JetSkiDriveState
) -> bool:
	_update_turn_lean_support_normal(body_state.step)
	_update_turn_lean_reference_axes(body_state.transform)
	_update_turn_lean_landing_authority(
		body_state.step,
		navigation_state
	)
	_update_rider_shift_landing_authority(
		body_state.step,
		navigation_state
	)
	if (
		not state.smoothed_support_normal.is_finite()
		or not state.reference_forward.is_finite()
		or not state.reference_right.is_finite()
	):
		_warn_once("Rider weight-shift reference axes are not finite.")
		return false
	var vehicle_up := _prepared_vehicle_basis.y
	var vehicle_forward := -_prepared_vehicle_basis.z
	state.turn_lean_current_roll = atan2(
		vehicle_up.dot(state.reference_right),
		vehicle_up.dot(state.smoothed_support_normal)
	)
	state.rider_shift_current_pitch = atan2(
		vehicle_forward.dot(state.smoothed_support_normal),
		vehicle_forward.dot(state.reference_forward)
	)
	if (
		not is_finite(state.turn_lean_current_roll)
		or not is_finite(state.rider_shift_current_pitch)
	):
		_warn_once("Rider weight-shift attitude angles are not finite.")
		return false
	state.turn_lean_roll_rate = body_state.angular_velocity.dot(
		state.reference_forward
	)
	state.turn_lean_speed_factor = smoothstep(
		turn_lean_start_speed,
		turn_lean_full_speed,
		absf(water_state.water_relative_forward_speed)
	)
	state.turn_lean_contact_factor = _calculate_turn_lean_contact_factor(
		water_state,
		navigation_state,
		drive_state
	)
	var drive_direction_sign := _turn_lean_drive_direction_sign(
		input_state,
		water_state
	)
	var steering_lean_factor := (
		signf(input_state.steering)
		* pow(
			absf(input_state.steering),
			TURN_LEAN_STEERING_EXPONENT
		)
	)
	var reverse_authority := (
		turn_lean_reverse_factor
		if drive_direction_sign < 0.0
		else 1.0
	)
	state.turn_lean_target_roll = 0.0
	if turn_lean_enabled:
		state.turn_lean_target_roll = (
			drive_direction_sign
			* deg_to_rad(turn_lean_max_angle_degrees)
			* steering_lean_factor
			* state.turn_lean_speed_factor
			* state.turn_lean_contact_factor
			* reverse_authority
		)
	_update_rider_shift_obsolete_target_metrics()
	state.rider_shift_manual_roll_target = (
		deg_to_rad(rider_manual_roll_max_angle_degrees)
		* input_state.rider_shift_smoothed.x
		* state.rider_manual_medium_authority
	)
	state.rider_shift_total_roll_target = clampf(
		state.turn_lean_target_roll
		+ state.rider_shift_manual_roll_target,
		-deg_to_rad(rider_roll_soft_limit_degrees),
		deg_to_rad(rider_roll_soft_limit_degrees)
	)
	state.turn_lean_roll_error = wrapf(
		state.rider_shift_total_roll_target
		- state.turn_lean_current_roll,
		-PI,
		PI
	)
	return true


func apply_supported_torque(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState,
	submarine_upright_factor: float,
	submarine_control_blend: float,
	external_submarine_pitch_torque: Vector3
) -> JetSkiRiderDynamicsState:
	var combined_torque := Vector3.ZERO
	if turn_lean_enabled:
		combined_torque += _calculate_turn_lean_pd_torque(
			body_state,
			submarine_upright_factor
		)
	if (
		rider_weight_shift_enabled
		and not input_state.rider_shift_smoothed.is_zero_approx()
	):
		combined_torque += _calculate_virtual_rider_weight_torque(
			body_state,
			input_state,
			submarine_control_blend,
			external_submarine_pitch_torque
		)
	if not combined_torque.is_finite():
		state.turn_lean_requested_torque = 0.0
		state.turn_lean_applied_torque_vector = Vector3.ZERO
		state.rider_shift_roll_torque = 0.0
		state.rider_shift_pitch_torque = 0.0
		state.total_applied_torque_vector = Vector3.ZERO
		_warn_once("Rider weight-shift torque is not finite.")
		return state
	state.total_applied_torque_vector = combined_torque
	if not combined_torque.is_zero_approx():
		body_state.apply_torque(combined_torque)
	return state


func reset_runtime_state() -> void:
	state.reset_runtime_state()
	_prepared_vehicle_basis = Basis.IDENTITY
	_prepared_body_forward = Vector3.FORWARD
	_prepared_body_right = Vector3.RIGHT
	_body_axes_valid = false


func get_warning_emission_count() -> int:
	return _warning_emission_count


func _calculate_air_rate_correction_torque(
	axis_rate: float,
	axis_input: float,
	target_rate: float,
	maximum_torque: float
) -> float:
	var input_magnitude := absf(axis_input)
	if input_magnitude <= 0.0001:
		return 0.0
	var input_direction := signf(axis_input)
	if axis_rate * input_direction < 0.0:
		return (
			input_direction
			* maximum_torque
			* input_magnitude
			* air_counter_input_brake_multiplier
		)
	var desired_rate_magnitude := input_magnitude * target_rate
	if absf(axis_rate) >= desired_rate_magnitude:
		return 0.0
	var rate_deficit_factor := clampf(
		(desired_rate_magnitude - absf(axis_rate))
		/ maxf(desired_rate_magnitude, 0.0001),
		0.0,
		1.0
	)
	return (
		input_direction
		* maximum_torque
		* input_magnitude
		* rate_deficit_factor
	)


func _calculate_rider_air_overspeed_torque(
	axis_rate: float,
	axis_input: float,
	maximum_rate: float
) -> float:
	if (
		absf(axis_input) <= 0.0001
		or signf(axis_rate) != signf(axis_input)
		or absf(axis_rate) <= maximum_rate
	):
		return 0.0
	return (
		-signf(axis_rate)
		* (absf(axis_rate) - maximum_rate)
		* rider_air_overspeed_damping
	)


func _update_rider_shift_obsolete_target_metrics() -> void:
	state.rider_shift_manual_roll_target = 0.0
	state.rider_shift_manual_pitch_target = 0.0
	state.rider_shift_base_pitch_target = 0.0
	state.rider_shift_total_roll_target = state.turn_lean_target_roll
	state.rider_shift_total_pitch_target = 0.0


func _calculate_turn_lean_pd_torque(
	body_state: PhysicsDirectBodyState3D,
	submarine_upright_factor: float
) -> Vector3:
	if state.turn_lean_contact_factor <= 0.0:
		return Vector3.ZERO
	var effective_stiffness := (
		turn_lean_stiffness * submarine_upright_factor
	)
	var effective_damping := (
		turn_lean_damping
		* submarine_upright_factor
		* state.turn_lean_speed_factor
	)
	var stiffness_torque := (
		state.turn_lean_roll_error * effective_stiffness
	)
	var damping_torque := (
		-state.turn_lean_roll_rate * effective_damping
	)
	var axis_inverse_inertia := state.reference_forward.dot(
		body_state.inverse_inertia_tensor * state.reference_forward
	)
	damping_torque = _limit_turn_lean_damping_torque(
		damping_torque,
		state.turn_lean_roll_rate,
		axis_inverse_inertia,
		body_state.step,
		state.turn_lean_contact_factor
	)
	state.turn_lean_requested_torque = clampf(
		stiffness_torque + damping_torque,
		-turn_lean_max_torque,
		turn_lean_max_torque
	)
	state.turn_lean_applied_torque_vector = (
		state.reference_forward
		* state.turn_lean_requested_torque
		* state.turn_lean_contact_factor
	)
	return state.turn_lean_applied_torque_vector


func _limit_turn_lean_damping_torque(
	requested_damping_torque: float,
	roll_rate: float,
	axis_inverse_inertia: float,
	delta: float,
	contact_factor: float
) -> float:
	if (
		is_zero_approx(requested_damping_torque)
		or absf(roll_rate) <= 0.000001
		or axis_inverse_inertia <= 0.000001
		or delta <= 0.000001
		or contact_factor <= 0.000001
	):
		return requested_damping_torque
	# Prevent damping from reversing the roll rate in one physics tick.
	# The half-step limit remains stable when scene scale changes inertia.
	var maximum_non_reversing_torque := (
		absf(roll_rate)
		* TURN_LEAN_DAMPING_RATE_REDUCTION_LIMIT
		/ (axis_inverse_inertia * delta * contact_factor)
	)
	return clampf(
		requested_damping_torque,
		-maximum_non_reversing_torque,
		maximum_non_reversing_torque
	)


func _calculate_virtual_rider_weight_torque(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState,
	submarine_control_blend: float,
	external_submarine_pitch_torque: Vector3
) -> Vector3:
	var vehicle_basis := body_state.transform.basis.orthonormalized()
	var body_forward := -vehicle_basis.z
	var body_right := vehicle_basis.x
	if (
		not body_forward.is_finite()
		or not body_right.is_finite()
		or body_forward.length_squared() <= DIRECTION_EPSILON_SQUARED
		or body_right.length_squared() <= DIRECTION_EPSILON_SQUARED
	):
		_warn_once("Virtual rider axes are degenerate.")
		return Vector3.ZERO
	state.virtual_offset_local = Vector3(
		input_state.rider_shift_smoothed.x
		* rider_lateral_shift_distance,
		0.0,
		input_state.rider_shift_smoothed.y
		* rider_longitudinal_shift_distance
	)
	state.virtual_offset_world = vehicle_basis * state.virtual_offset_local
	var gravity_acceleration: Vector3 = body_state.total_gravity
	if (
		not gravity_acceleration.is_finite()
		or gravity_acceleration.length_squared()
		<= DIRECTION_EPSILON_SQUARED
	):
		gravity_acceleration = Vector3.DOWN * 9.81
	var virtual_weight_force := (
		gravity_acceleration * rider_effective_mass
	)
	var raw_weight_torque := (
		state.virtual_offset_world.cross(virtual_weight_force)
		* rider_weight_torque_multiplier
	)
	var pitch_weight_torque := raw_weight_torque.dot(body_right)
	var back_input := maxf(
		input_state.rider_shift_smoothed.y,
		0.0
	)
	var forward_input := maxf(
		-input_state.rider_shift_smoothed.y,
		0.0
	)
	state.dynamic_pitch_multiplier = 1.0
	if back_input > 0.0:
		state.dynamic_pitch_multiplier += (
			input_state.throttle
			* back_input
			* rider_wheelie_throttle_boost
		)
	elif forward_input > 0.0:
		state.dynamic_pitch_multiplier += (
			state.rider_shift_speed_factor
			* forward_input
			* rider_nose_dive_speed_boost
		)
	pitch_weight_torque *= state.dynamic_pitch_multiplier
	state.virtual_weight_torque = (
		body_right
		* pitch_weight_torque
		* state.rider_manual_medium_authority
	)
	var pitch_rate := body_state.angular_velocity.dot(body_right)
	var manual_damping_factor := lerpf(
		1.0,
		SUBMARINE_MANUAL_DAMPING_FACTOR,
		submarine_control_blend
	)
	state.roll_damping_torque = Vector3.ZERO
	state.pitch_damping_torque = (
		-body_right
		* pitch_rate
		* rider_pitch_rate_damping
		* absf(input_state.rider_shift_smoothed.y)
		* state.rider_manual_medium_authority
		* manual_damping_factor
	)
	var soft_limit_torque := _calculate_rider_shift_soft_limit_torque(
		body_state,
		input_state,
		body_forward,
		body_right,
		rider_roll_soft_limit_degrees,
		rider_nose_up_soft_limit_degrees,
		rider_nose_down_soft_limit_degrees
	)
	var manual_torque := (
		state.virtual_weight_torque
		+ state.roll_damping_torque
		+ state.pitch_damping_torque
		+ soft_limit_torque
		+ external_submarine_pitch_torque
	)
	state.rider_shift_roll_torque = manual_torque.dot(body_forward)
	state.rider_shift_pitch_torque = manual_torque.dot(body_right)
	state.manual_applied_torque = manual_torque
	return manual_torque


func _calculate_rider_shift_soft_limit_torque(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState,
	body_forward: Vector3,
	body_right: Vector3,
	roll_limit_degrees: float,
	nose_up_limit_degrees: float,
	nose_down_limit_degrees: float
) -> Vector3:
	var limit_torque := Vector3.ZERO
	var blend_range := deg_to_rad(RIDER_SOFT_LIMIT_BLEND_DEGREES)
	if absf(input_state.rider_shift_smoothed.x) > 0.0005:
		var roll_limit := deg_to_rad(roll_limit_degrees)
		var roll_excess := 0.0
		if state.turn_lean_current_roll > roll_limit:
			roll_excess = state.turn_lean_current_roll - roll_limit
		elif state.turn_lean_current_roll < -roll_limit:
			roll_excess = state.turn_lean_current_roll + roll_limit
		if not is_zero_approx(roll_excess):
			var roll_direction := signf(roll_excess)
			var roll_rate := body_state.angular_velocity.dot(
				body_forward
			)
			var outward_roll_rate := maxf(
				roll_rate * roll_direction,
				0.0
			)
			state.roll_soft_limit_factor = clampf(
				absf(roll_excess)
				/ maxf(blend_range, 0.0001),
				0.0,
				1.0
			)
			limit_torque += (
				-body_forward
				* roll_direction
				* (
					absf(roll_excess)
					* rider_soft_limit_stiffness
					+ outward_roll_rate
					* rider_soft_limit_damping
				)
			)
	if absf(input_state.rider_shift_smoothed.y) > 0.0005:
		var nose_up_limit := deg_to_rad(nose_up_limit_degrees)
		var nose_down_limit := deg_to_rad(nose_down_limit_degrees)
		var pitch_excess := 0.0
		if state.rider_shift_current_pitch > nose_up_limit:
			pitch_excess = (
				state.rider_shift_current_pitch - nose_up_limit
			)
		elif (
			state.rider_shift_current_pitch < -nose_down_limit
		):
			pitch_excess = (
				state.rider_shift_current_pitch + nose_down_limit
			)
		if not is_zero_approx(pitch_excess):
			var pitch_direction := signf(pitch_excess)
			var pitch_rate := body_state.angular_velocity.dot(body_right)
			var outward_pitch_rate := maxf(
				pitch_rate * pitch_direction,
				0.0
			)
			state.pitch_soft_limit_factor = clampf(
				absf(pitch_excess)
				/ maxf(blend_range, 0.0001),
				0.0,
				1.0
			)
			limit_torque += (
				-body_right
				* pitch_direction
				* (
					absf(pitch_excess)
					* rider_soft_limit_stiffness
					+ outward_pitch_rate
					* rider_soft_limit_damping
				)
			)
	return limit_torque


func _update_rider_shift_speed_authority(
	water_state: JetSkiWaterState
) -> void:
	state.rider_shift_speed_factor = smoothstep(
		0.0,
		maxf(rider_shift_full_speed, 0.001),
		absf(water_state.water_relative_forward_speed)
	)
	state.rider_shift_speed_authority = lerpf(
		rider_shift_standstill_authority,
		1.0,
		state.rider_shift_speed_factor
	)
	state.rider_shift_speed_authority = clampf(
		state.rider_shift_speed_authority,
		0.0,
		1.0
	)


func _update_rider_shift_contact_metrics(
	navigation_state: JetSkiNavigationState,
	submarine_dive_active: bool
) -> void:
	state.rider_shift_front_contact_ratio = (
		float(_count_contact_bits(
			navigation_state.current_contact_mask
			& FRONT_CONTACT_MASK
		))
		/ float(FRONT_POINT_COUNT)
	)
	state.rider_shift_rear_contact_ratio = (
		float(_count_contact_bits(
			navigation_state.current_contact_mask
			& REAR_CONTACT_MASK
		))
		/ float(FRONT_POINT_COUNT)
	)
	if state.using_air_control:
		state.rider_shift_contact_authority = 0.0
		state.rider_manual_medium_authority = 0.0
		return
	var medium_authority := 1.0
	if submarine_dive_active:
		medium_authority = 1.0
	elif (
		navigation_state.navigation_state
		== JetSkiTypes.NavigationState.DEEP_SUBMERGED
	):
		medium_authority = rider_shift_deep_submerged_authority
	elif (
		navigation_state.navigation_state
		== JetSkiTypes.NavigationState.LANDING
	):
		medium_authority = lerpf(
			0.35,
			1.0,
			state.rider_shift_landing_ramp
		)
	medium_authority *= state.rider_shift_speed_authority
	state.rider_manual_medium_authority = clampf(
		medium_authority,
		0.0,
		1.0
	)
	state.rider_shift_contact_authority = (
		state.rider_manual_medium_authority
	)


func _update_rider_shift_landing_authority(
	physics_delta: float,
	navigation_state: JetSkiNavigationState
) -> void:
	if navigation_state.current_contact_mask == 0:
		state.rider_shift_landing_ramp = 0.0
		return
	if (
		navigation_state.previous_contact_mask == 0
		and navigation_state.current_contact_mask != 0
	):
		state.rider_shift_landing_ramp = 0.0
		return
	if rider_shift_landing_ramp_time <= 0.0:
		state.rider_shift_landing_ramp = 1.0
		return
	state.rider_shift_landing_ramp = minf(
		state.rider_shift_landing_ramp
		+ maxf(physics_delta, 0.0)
		/ rider_shift_landing_ramp_time,
		1.0
	)


func _update_turn_lean_support_normal(physics_delta: float) -> void:
	var weighted_normal_sum := Vector3.ZERO
	var total_weight: float = 0.0
	if _water_point_source != null:
		for index in BUOYANCY_POINT_COUNT:
			if (
				not _water_point_source.point_sample_valid[index]
				or _water_point_source.point_depths[index] <= 0.0
			):
				continue
			var point_normal := (
				_water_point_source.point_water_normals[index]
			)
			if (
				not point_normal.is_finite()
				or point_normal.length_squared()
				<= DIRECTION_EPSILON_SQUARED
			):
				continue
			var depth_weight := (
				_water_point_source.point_depths[index]
				* buoyancy_strength_per_point
			)
			var point_weight := maxf(
				_water_point_source.point_normal_forces[index],
				maxf(depth_weight, 1.0)
			)
			weighted_normal_sum += point_normal * point_weight
			total_weight += point_weight
	var target_support_normal := Vector3.UP
	if (
		total_weight > 0.0
		and weighted_normal_sum.length_squared()
		> DIRECTION_EPSILON_SQUARED
	):
		target_support_normal = weighted_normal_sum.normalized()
	if target_support_normal.y < 0.0:
		target_support_normal = -target_support_normal
	var blend_weight := 1.0 - exp(
		-HALF_LIFE_LOG_TWO
		* physics_delta
		/ maxf(turn_lean_support_normal_half_life, 0.0001)
	)
	var blended_normal := state.smoothed_support_normal.lerp(
		target_support_normal,
		clampf(blend_weight, 0.0, 1.0)
	)
	if (
		blended_normal.is_finite()
		and blended_normal.length_squared()
		> DIRECTION_EPSILON_SQUARED
	):
		state.smoothed_support_normal = blended_normal.normalized()
	else:
		state.smoothed_support_normal = Vector3.UP


func _update_turn_lean_reference_axes(
	vehicle_transform: Transform3D
) -> void:
	var vehicle_forward := -vehicle_transform.basis.z.normalized()
	var projected_forward := vehicle_forward.slide(
		state.smoothed_support_normal
	)
	if projected_forward.length_squared() <= DIRECTION_EPSILON_SQUARED:
		var vehicle_right := vehicle_transform.basis.x.normalized()
		projected_forward = state.smoothed_support_normal.cross(
			vehicle_right
		)
	if projected_forward.length_squared() <= DIRECTION_EPSILON_SQUARED:
		projected_forward = Vector3.FORWARD.slide(
			state.smoothed_support_normal
		)
	state.reference_forward = projected_forward.normalized()
	var reference_right := state.reference_forward.cross(
		state.smoothed_support_normal
	)
	if reference_right.length_squared() <= DIRECTION_EPSILON_SQUARED:
		reference_right = vehicle_transform.basis.x.normalized()
	state.reference_right = reference_right.normalized()


func _update_turn_lean_landing_authority(
	physics_delta: float,
	navigation_state: JetSkiNavigationState
) -> void:
	if (
		navigation_state.current_contact_mask == 0
		or navigation_state.navigation_state
		== JetSkiTypes.NavigationState.AIRBORNE
	):
		state.turn_lean_landing_ramp = 0.0
		return
	if turn_lean_landing_ramp_time <= 0.0:
		state.turn_lean_landing_ramp = 1.0
		return
	state.turn_lean_landing_ramp = minf(
		state.turn_lean_landing_ramp
		+ physics_delta / turn_lean_landing_ramp_time,
		1.0
	)


func _calculate_turn_lean_contact_factor(
	water_state: JetSkiWaterState,
	navigation_state: JetSkiNavigationState,
	drive_state: JetSkiDriveState
) -> float:
	if (
		navigation_state.navigation_state
		== JetSkiTypes.NavigationState.AIRBORNE
	):
		return 0.0
	var contact_count := _count_contact_bits(
		navigation_state.current_contact_mask
	)
	var point_support: float = 0.0
	match contact_count:
		1:
			point_support = 0.15
		2:
			point_support = 0.55
		3:
			point_support = 0.8
		4:
			point_support = 1.0
	var full_depth := maxf(max_submersion_depth * 0.2, 0.01)
	var depth_support := lerpf(
		0.5,
		1.0,
		smoothstep(
			0.0,
			full_depth,
			water_state.average_depth
		)
	)
	var propulsor_support := lerpf(
		0.25,
		1.0,
		clampf(
			drive_state.propulsion_contact_factor,
			0.0,
			1.0
		)
	)
	var navigation_support := (
		0.35
		if navigation_state.navigation_state
		== JetSkiTypes.NavigationState.DEEP_SUBMERGED
		else 1.0
	)
	return clampf(
		point_support
		* depth_support
		* propulsor_support
		* navigation_support
		* state.turn_lean_landing_ramp,
		0.0,
		1.0
	)


func _turn_lean_drive_direction_sign(
	input_state: JetSkiInputState,
	water_state: JetSkiWaterState
) -> float:
	var net_propulsion_input := (
		input_state.throttle - input_state.brake
	)
	if absf(net_propulsion_input) > 0.001:
		return signf(net_propulsion_input)
	var relative_forward_speed := (
		water_state.water_relative_forward_speed
	)
	if absf(relative_forward_speed) > 0.01:
		return signf(relative_forward_speed)
	return 0.0


func _count_contact_bits(mask: int) -> int:
	var count := 0
	var remaining_mask := mask & 15
	while remaining_mask != 0:
		count += remaining_mask & 1
		remaining_mask >>= 1
	return count


func _warn_once(message: String) -> void:
	if _warning_emitted:
		return
	_warning_emitted = true
	_warning_emission_count += 1
	push_warning(message)


func _warn_air_once(message: String) -> void:
	if _air_warning_emitted:
		return
	_air_warning_emitted = true
	_warning_emission_count += 1
	push_warning(message)
