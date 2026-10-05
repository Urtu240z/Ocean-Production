class_name JetSkiArcadeHandling
extends Node

## Adds selective arcade grip to the JetSki without replacing its water physics.
## The legacy path remains unchanged while the controller's
## use_arcade_turn_continuity toggle is disabled.

const DIRECTION_EPSILON_SQUARED: float = 0.000001

@export_group("Arcade Handling - Legacy")
@export var arcade_handling_enabled: bool = true
@export_range(0.0, 12.0, 0.1, "suffix:1/s") var lateral_grip_rate: float = 3.5
@export_range(0.0, 1.0, 0.01) var lateral_grip_while_steering: float = 0.35
@export_range(0.0, 50.0, 0.5, "suffix:m/s²") var maximum_lateral_acceleration: float = 18.0
@export_range(0.0, 12.0, 0.1, "suffix:1/s") var yaw_damping_rate: float = 3.0
@export_range(0.0, 1.0, 0.01) var yaw_damping_while_steering: float = 0.12
@export_range(0.0, 5.0, 0.1, "suffix:m/s") var minimum_handling_speed: float = 1.5
@export_range(0.0, 0.5, 0.01) var steering_dead_zone: float = 0.08

@export_group("Arcade Turn Continuity - A/B")
@export var use_effective_water_contact: bool = true
@export var use_yaw_rate_controller: bool = true
@export var use_progressive_lateral_grip: bool = true
@export var use_landing_blend: bool = true

@export_group("Arcade Turn Continuity - Contact")
@export_range(0.01, 0.5, 0.01, "suffix:s") var water_contact_rise_time: float = 0.06
@export_range(0.01, 1.0, 0.01, "suffix:s") var water_contact_release_time: float = 0.22
@export_range(0.0, 1.0, 0.01) var micro_air_steering_ratio: float = 0.30

@export_group("Arcade Turn Continuity - Yaw Rate")
@export_range(0.5, 6.0, 0.1, "suffix:m") var yaw_rate_reference_length: float = 2.4
@export_range(0.1, 4.0, 0.05, "suffix:rad/s") var maximum_desired_yaw_rate: float = 1.4
@export_range(0.0, 30000.0, 100.0, "suffix:N*m/(rad/s)") var yaw_rate_steering_strength: float = 6500.0
@export_range(0.0, 12000.0, 100.0, "suffix:N*m/(rad/s)") var yaw_rate_damping: float = 1200.0
@export_range(0.0, 30000.0, 100.0, "suffix:N*m") var maximum_yaw_torque: float = 8000.0

@export_group("Arcade Turn Continuity - Landing")
@export_range(0.01, 0.5, 0.01, "suffix:s") var landing_blend_time: float = 0.14

var water_contact_ratio: float = 0.0
var effective_water_contact: float = 0.0
var airborne_time: float = 0.0
var steering_input: float = 0.0
var desired_yaw_rate: float = 0.0
var actual_yaw_rate: float = 0.0
var lateral_speed: float = 0.0
var landing_blend: float = 1.0
var landing_timer: float = 0.0

var _vehicle: JetSkiController
var _previous_had_water_contact: bool = false
var _drive_input: JetSkiInputState = JetSkiInputState.new()
var _frame_water_normal: Vector3 = Vector3.UP
var _frame_forward_tangent: Vector3 = Vector3.FORWARD
var _frame_right_tangent: Vector3 = Vector3.RIGHT
var _frame_tangential_velocity: Vector3 = Vector3.ZERO
var _water_sample_scratch: WaterSample3D = WaterSample3D.new()


func _ready() -> void:
	_vehicle = get_parent() as JetSkiController
	if _vehicle == null:
		push_warning("JetSkiArcadeHandling must be a child of a JetSkiController.")
		set_physics_process(false)


func _physics_process(delta: float) -> void:
	if not arcade_handling_enabled or not is_instance_valid(_vehicle):
		return
	if _vehicle.use_arcade_turn_continuity:
		return
	if _vehicle.freeze or get_tree().paused:
		return
	if _vehicle.submerged_ratio <= 0.0:
		return
	if _vehicle.submarine_dive_active:
		return
	if _vehicle.navigation_state == JetSkiController.NavigationState.DEEP_SUBMERGED:
		return

	var water_provider := _vehicle.get_water_provider()
	if not is_instance_valid(water_provider):
		return

	var water_sample := water_provider.sample_water(
		_vehicle.global_position,
		_water_sample_scratch
	)
	if not water_sample.valid:
		return
	var water_normal := water_sample.normal
	var water_velocity := water_sample.velocity

	if not water_normal.is_finite() or water_normal.length_squared() <= 0.000001:
		water_normal = Vector3.UP
	else:
		water_normal = water_normal.normalized()

	if water_normal.y < 0.0:
		water_normal = -water_normal
	if not water_velocity.is_finite():
		water_velocity = Vector3.ZERO

	var body_forward := -_vehicle.global_basis.z
	var forward_tangent := body_forward - water_normal * body_forward.dot(water_normal)

	if forward_tangent.length_squared() <= 0.000001:
		return

	forward_tangent = forward_tangent.normalized()
	var right_tangent := forward_tangent.cross(water_normal)

	if right_tangent.length_squared() <= 0.000001:
		return

	right_tangent = right_tangent.normalized()

	var relative_velocity := _vehicle.linear_velocity - water_velocity
	var tangential_velocity := relative_velocity - water_normal * relative_velocity.dot(water_normal)
	var tangential_speed := tangential_velocity.length()

	var steering_amount := clampf(absf(_vehicle.steering_input), 0.0, 1.0)
	var steering_blend := smoothstep(steering_dead_zone, 1.0, steering_amount)
	var centered_blend := 1.0 - steering_blend
	var contact_factor := smoothstep(0.0, 0.75, _vehicle.submerged_ratio)
	var speed_factor := smoothstep(
		minimum_handling_speed,
		minimum_handling_speed + 3.0,
		tangential_speed
	)
	var handling_authority := contact_factor * speed_factor

	if handling_authority <= 0.0:
		return

	_apply_lateral_grip(
		delta,
		right_tangent,
		tangential_velocity,
		centered_blend,
		handling_authority
	)
	_apply_yaw_damping(
		delta,
		water_normal,
		centered_blend,
		handling_authority
	)


func step_turn_continuity(
	body_state: PhysicsDirectBodyState3D,
	input_state: JetSkiInputState,
	water_state: JetSkiWaterState,
	water_provider: WaterSurfaceProvider3D,
	delta: float
) -> void:
	steering_input = clampf(input_state.steering, -1.0, 1.0)
	water_contact_ratio = clampf(water_state.submerged_ratio, 0.0, 1.0)
	_update_landing_blend(delta)
	_update_contact_memory(delta)

	if not _sample_handling_frame(
		body_state.transform,
		body_state.linear_velocity,
		water_provider
	):
		_clear_dynamic_telemetry()
		return

	var water_normal := _frame_water_normal
	var right_tangent := _frame_right_tangent
	var tangential_velocity := _frame_tangential_velocity
	var forward_speed: float = tangential_velocity.dot(
		_frame_forward_tangent
	)
	lateral_speed = tangential_velocity.dot(right_tangent)
	actual_yaw_rate = body_state.angular_velocity.dot(water_normal)
	desired_yaw_rate = _calculate_desired_yaw_rate(forward_speed)

	if not arcade_handling_enabled:
		return
	if _vehicle.submarine_dive_active:
		return
	if _vehicle.navigation_state == JetSkiController.NavigationState.DEEP_SUBMERGED:
		return

	var tangential_speed := tangential_velocity.length()
	var speed_factor := _speed_factor(tangential_speed)
	var contact_authority := _get_turn_contact_authority()
	var force_authority := contact_authority * speed_factor
	if use_landing_blend:
		force_authority *= lerpf(
			micro_air_steering_ratio,
			1.0,
			landing_blend
		)
	if force_authority <= 0.0:
		return

	var centered_blend := _centered_steering_blend(steering_input)
	if water_contact_ratio > 0.0:
		if use_progressive_lateral_grip:
			_apply_continuity_lateral_grip(
				delta,
				right_tangent,
				tangential_velocity,
				centered_blend,
				force_authority,
				body_state
			)
		else:
			var legacy_contact := smoothstep(
				0.0,
				0.75,
				water_contact_ratio
			)
			_apply_continuity_lateral_grip(
				delta,
				right_tangent,
				tangential_velocity,
				centered_blend,
				legacy_contact * speed_factor,
				body_state
			)

	if use_yaw_rate_controller:
		_apply_yaw_rate_controller(
			body_state,
			water_normal,
			force_authority
		)
	else:
		_apply_continuity_yaw_damping(
			delta,
			water_normal,
			centered_blend,
			force_authority,
			body_state
		)


func get_drive_input(input_state: JetSkiInputState) -> JetSkiInputState:
	_drive_input.throttle = input_state.throttle
	_drive_input.brake = input_state.brake
	_drive_input.steering = (
		0.0 if arcade_handling_enabled and use_yaw_rate_controller
		else input_state.steering
	)
	_drive_input.rider_shift_raw = input_state.rider_shift_raw
	_drive_input.rider_shift_smoothed = input_state.rider_shift_smoothed
	return _drive_input


func reset_turn_continuity_state() -> void:
	water_contact_ratio = 0.0
	effective_water_contact = 0.0
	airborne_time = 0.0
	steering_input = 0.0
	desired_yaw_rate = 0.0
	actual_yaw_rate = 0.0
	lateral_speed = 0.0
	landing_blend = 1.0
	landing_timer = 0.0
	_previous_had_water_contact = false
	_drive_input.reset()


func get_turn_continuity_debug_status() -> Dictionary:
	return {
		&"water_contact_ratio": water_contact_ratio,
		&"effective_water_contact": effective_water_contact,
		&"airborne_time": airborne_time,
		&"steering_input": steering_input,
		&"desired_yaw_rate": desired_yaw_rate,
		&"actual_yaw_rate": actual_yaw_rate,
		&"lateral_speed": lateral_speed,
		&"landing_blend": landing_blend,
		&"landing_timer": landing_timer,
	}


func _update_contact_memory(delta: float) -> void:
	var safe_delta := maxf(delta, 0.0)
	var has_water_contact := water_contact_ratio > 0.0
	if has_water_contact:
		airborne_time = 0.0
		if use_effective_water_contact:
			effective_water_contact = move_toward(
				effective_water_contact,
				1.0,
				safe_delta / maxf(water_contact_rise_time, 0.001)
			)
		else:
			effective_water_contact = water_contact_ratio
	else:
		airborne_time += safe_delta
		if use_effective_water_contact:
			effective_water_contact = move_toward(
				effective_water_contact,
				0.0,
				safe_delta / maxf(water_contact_release_time, 0.001)
			)
		else:
			effective_water_contact = 0.0
	effective_water_contact = clampf(effective_water_contact, 0.0, 1.0)


func _update_landing_blend(delta: float) -> void:
	var has_water_contact := water_contact_ratio > 0.0
	if (
		use_landing_blend
		and has_water_contact
		and not _previous_had_water_contact
		and airborne_time > 0.0
	):
		landing_timer = landing_blend_time
	if use_landing_blend and landing_timer > 0.0:
		landing_timer = maxf(landing_timer - maxf(delta, 0.0), 0.0)
		landing_blend = 1.0 - clampf(
			landing_timer / maxf(landing_blend_time, 0.001),
			0.0,
			1.0
		)
	else:
		landing_timer = 0.0
		landing_blend = 1.0
	_previous_had_water_contact = has_water_contact


func _get_turn_contact_authority() -> float:
	if not use_effective_water_contact:
		return smoothstep(0.0, 0.75, water_contact_ratio)
	if water_contact_ratio > 0.0:
		var physical_contact_authority := smoothstep(
			0.0,
			0.75,
			water_contact_ratio
		)
		return effective_water_contact * lerpf(
			micro_air_steering_ratio,
			1.0,
			physical_contact_authority
		)
	return effective_water_contact * micro_air_steering_ratio


func _calculate_desired_yaw_rate(forward_speed: float) -> float:
	var absolute_speed := absf(forward_speed)
	var steering_speed_factor := lerpf(
		1.0,
		_vehicle.high_speed_steering_factor,
		_inverse_lerp_clamped(
			_vehicle.steering_reduction_start_speed,
			_vehicle.steering_reduction_end_speed,
			absolute_speed
		)
	)
	var steering_angle := deg_to_rad(
		steering_input
		* _vehicle.maximum_steering_angle_degrees
		* steering_speed_factor
	)
	var yaw_speed_basis := maxf(absolute_speed, minimum_handling_speed)
	var target := (
		-yaw_speed_basis
		* tan(steering_angle)
		/ maxf(yaw_rate_reference_length, 0.01)
	)
	return clampf(
		target,
		-maximum_desired_yaw_rate,
		maximum_desired_yaw_rate
	)


func _apply_yaw_rate_controller(
	body_state: PhysicsDirectBodyState3D,
	water_normal: Vector3,
	authority: float
) -> void:
	var yaw_error := desired_yaw_rate - actual_yaw_rate
	var requested_torque := (
		yaw_error * yaw_rate_steering_strength
		- actual_yaw_rate * yaw_rate_damping
	)
	requested_torque = clampf(
		requested_torque,
		-maximum_yaw_torque,
		maximum_yaw_torque
	)
	var torque := water_normal * requested_torque * authority
	if torque.is_finite() and not torque.is_zero_approx():
		body_state.apply_torque(torque)


func _sample_handling_frame(
	body_transform: Transform3D,
	body_linear_velocity: Vector3,
	water_provider: WaterSurfaceProvider3D
) -> bool:
	if not is_instance_valid(water_provider):
		return false
	var water_sample := water_provider.sample_water(
		body_transform.origin,
		_water_sample_scratch
	)
	if not water_sample.valid:
		return false
	var water_normal := water_sample.normal
	var water_velocity := water_sample.velocity
	if not water_normal.is_finite() or water_normal.length_squared() <= DIRECTION_EPSILON_SQUARED:
		water_normal = Vector3.UP
	else:
		water_normal = water_normal.normalized()
	if water_normal.y < 0.0:
		water_normal = -water_normal
	if not water_velocity.is_finite():
		water_velocity = Vector3.ZERO

	var body_forward := -body_transform.basis.z
	var forward_tangent := body_forward - water_normal * body_forward.dot(water_normal)
	if forward_tangent.length_squared() <= DIRECTION_EPSILON_SQUARED:
		return false
	forward_tangent = forward_tangent.normalized()
	var right_tangent := forward_tangent.cross(water_normal)
	if right_tangent.length_squared() <= DIRECTION_EPSILON_SQUARED:
		return false
	right_tangent = right_tangent.normalized()
	var relative_velocity := body_linear_velocity - water_velocity
	var tangential_velocity := (
		relative_velocity
		- water_normal * relative_velocity.dot(water_normal)
	)
	_frame_water_normal = water_normal
	_frame_forward_tangent = forward_tangent
	_frame_right_tangent = right_tangent
	_frame_tangential_velocity = tangential_velocity
	return true


func _clear_dynamic_telemetry() -> void:
	desired_yaw_rate = 0.0
	actual_yaw_rate = 0.0
	lateral_speed = 0.0


func _centered_steering_blend(raw_steering: float) -> float:
	var steering_amount := clampf(absf(raw_steering), 0.0, 1.0)
	var steering_blend := smoothstep(
		steering_dead_zone,
		1.0,
		steering_amount
	)
	return 1.0 - steering_blend


func _speed_factor(tangential_speed: float) -> float:
	return smoothstep(
		minimum_handling_speed,
		minimum_handling_speed + 3.0,
		tangential_speed
	)


func _apply_lateral_grip(
	delta: float,
	right_tangent: Vector3,
	tangential_velocity: Vector3,
	centered_blend: float,
	handling_authority: float
) -> void:
	var current_lateral_speed := tangential_velocity.dot(right_tangent)

	if absf(current_lateral_speed) <= 0.001:
		return

	var steering_grip := lerpf(lateral_grip_while_steering, 1.0, centered_blend)
	var effective_grip_rate := lateral_grip_rate * steering_grip * handling_authority
	var safe_delta := maxf(delta, 0.0001)
	var removal_fraction := 1.0 - exp(-effective_grip_rate * safe_delta)
	var correction_velocity := (
		-right_tangent * current_lateral_speed * removal_fraction
	)
	var correction_acceleration := correction_velocity / safe_delta

	if correction_acceleration.length() > maximum_lateral_acceleration:
		correction_acceleration = (
			correction_acceleration.normalized() * maximum_lateral_acceleration
		)

	_vehicle.apply_central_force(correction_acceleration * _vehicle.mass)


func _apply_yaw_damping(
	delta: float,
	water_normal: Vector3,
	centered_blend: float,
	handling_authority: float
) -> void:
	var yaw_speed := _vehicle.angular_velocity.dot(water_normal)

	if absf(yaw_speed) <= 0.0001:
		return

	var steering_damping := lerpf(yaw_damping_while_steering, 1.0, centered_blend)
	var effective_damping_rate := yaw_damping_rate * steering_damping * handling_authority
	var removal_fraction := 1.0 - exp(-effective_damping_rate * maxf(delta, 0.0001))

	_vehicle.angular_velocity -= water_normal * yaw_speed * removal_fraction


func _apply_continuity_lateral_grip(
	delta: float,
	right_tangent: Vector3,
	tangential_velocity: Vector3,
	centered_blend: float,
	handling_authority: float,
	body_state: PhysicsDirectBodyState3D
) -> void:
	var current_lateral_speed := tangential_velocity.dot(right_tangent)
	if absf(current_lateral_speed) <= 0.001:
		return
	var steering_grip := lerpf(
		lateral_grip_while_steering,
		1.0,
		centered_blend
	)
	var effective_grip_rate := (
		lateral_grip_rate * steering_grip * handling_authority
	)
	var safe_delta := maxf(delta, 0.0001)
	var removal_fraction := 1.0 - exp(-effective_grip_rate * safe_delta)
	var correction_velocity := (
		-right_tangent * current_lateral_speed * removal_fraction
	)
	var correction_acceleration := correction_velocity / safe_delta
	if correction_acceleration.length() > maximum_lateral_acceleration:
		correction_acceleration = (
			correction_acceleration.normalized()
			* maximum_lateral_acceleration
		)
	body_state.apply_central_force(correction_acceleration * _vehicle.mass)


func _apply_continuity_yaw_damping(
	delta: float,
	water_normal: Vector3,
	centered_blend: float,
	handling_authority: float,
	body_state: PhysicsDirectBodyState3D
) -> void:
	var angular_velocity := body_state.angular_velocity
	var yaw_speed := angular_velocity.dot(water_normal)
	if absf(yaw_speed) <= 0.0001:
		return
	var steering_damping := lerpf(
		yaw_damping_while_steering,
		1.0,
		centered_blend
	)
	var effective_damping_rate := (
		yaw_damping_rate * steering_damping * handling_authority
	)
	var removal_fraction := 1.0 - exp(
		-effective_damping_rate * maxf(delta, 0.0001)
	)
	angular_velocity -= water_normal * yaw_speed * removal_fraction
	body_state.angular_velocity = angular_velocity


func _inverse_lerp_clamped(from: float, to: float, value: float) -> float:
	if to <= from:
		return 1.0 if value >= to else 0.0
	return clampf(inverse_lerp(from, to, value), 0.0, 1.0)
