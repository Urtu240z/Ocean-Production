class_name JetSkiDriveSystem
extends Node

const DIRECTION_EPSILON_SQUARED: float = 0.000001
const MINIMUM_COASTING_STEERING_INPUT: float = 0.001
const MINIMUM_COASTING_FORWARD_SPEED: float = 0.01

var state: JetSkiDriveState = JetSkiDriveState.new()

var forward_engine_force: float = 4200.0
var reverse_engine_force: float = 1800.0
var propulsion_full_contact_depth: float = 0.3
var forward_thrust_falloff_start_speed: float = 18.0
var forward_thrust_falloff_end_speed: float = 28.0
var reverse_thrust_falloff_start_speed: float = 5.0
var reverse_thrust_falloff_end_speed: float = 9.0

var maximum_steering_angle_degrees: float = 12.0
var steering_reduction_start_speed: float = 12.0
var steering_reduction_end_speed: float = 25.0
var high_speed_steering_factor: float = 0.45
var coasting_steering_force_per_speed_squared: float = 2.0
var max_coasting_steering_force: float = 1500.0

var _propulsion_local_point: Vector3 = Vector3.ZERO
var _has_propulsion_point: bool = false
var _missing_marker_warning_emitted: bool = false
var _invalid_ocean_warning_emitted: bool = false
var _invalid_sample_warning_emitted: bool = false
var _degenerate_direction_warning_emitted: bool = false
var _invalid_force_warning_emitted: bool = false
var _warning_emission_count: int = 0
var _water_sample_scratch: WaterSample3D = WaterSample3D.new()
var _comparison_water_scratch: WaterSample3D = WaterSample3D.new()


func configure(propulsion_marker: Marker3D) -> void:
	if propulsion_marker == null:
		_propulsion_local_point = Vector3.ZERO
		_has_propulsion_point = false
		_warn_about_missing_propulsion_point_once()
		return
	_propulsion_local_point = propulsion_marker.transform.origin
	_has_propulsion_point = true


func begin_physics_tick() -> void:
	state.clear_frame_metrics()


func step(
	body_state: PhysicsDirectBodyState3D,
	water_provider: WaterSurfaceProvider3D,
	input_state: JetSkiInputState,
	submarine_propulsion_factor: float
) -> JetSkiDriveState:
	if not _has_propulsion_point:
		_warn_about_missing_propulsion_point_once()
		return state
	if water_provider == null or not is_instance_valid(water_provider):
		_warn_about_invalid_water_provider_once()
		return state
	if water_provider.has_method("has_usable_contacts") and not water_provider.has_usable_contacts(): return state
	var body_forward := -body_state.transform.basis.z.normalized()
	var propulsion_world_position := (
		body_state.transform * _propulsion_local_point
	)
	state.propulsion_world_position = propulsion_world_position
	var propulsion_world_offset := (
		propulsion_world_position - body_state.transform.origin
	)
	var water_sample := water_provider.sample_propulsion_water(
		propulsion_world_position,
		_water_sample_scratch
	)
	if not water_sample.valid:
		_warn_about_invalid_sample_once()
		return state
	if water_provider.has_method("sample_comparison_water"):
		var comparison_sample: WaterSample3D = water_provider.call("sample_comparison_water",
			propulsion_world_position, _comparison_water_scratch) as WaterSample3D
		if comparison_sample != null and comparison_sample.valid and water_provider.has_method("record_contact_comparison"):
			water_provider.call("record_contact_comparison", 4, propulsion_world_position,
				water_sample, comparison_sample, 0.0, 0.0)
	var water_normal := water_sample.normal
	var water_velocity := water_sample.velocity
	if (
		not water_normal.is_finite()
		or not water_velocity.is_finite()
	):
		_warn_about_invalid_sample_once()
		return state
	if water_normal.length_squared() <= DIRECTION_EPSILON_SQUARED:
		_warn_about_invalid_sample_once()
		return state
	water_normal = water_normal.normalized()
	if water_normal.y < 0.0:
		water_normal = -water_normal
	state.propulsion_depth = water_sample.signed_depth
	state.propulsion_contact_factor = clampf(
		state.propulsion_depth / propulsion_full_contact_depth,
		0.0,
		1.0
	)
	if state.propulsion_contact_factor <= 0.0:
		return state
	var base_propulsion_direction := (
		body_forward
		- water_normal * body_forward.dot(water_normal)
	)
	if (
		not base_propulsion_direction.is_finite()
		or base_propulsion_direction.length_squared()
		<= DIRECTION_EPSILON_SQUARED
	):
		_warn_about_degenerate_direction_once()
		return state
	base_propulsion_direction = base_propulsion_direction.normalized()
	var point_velocity := body_state.get_velocity_at_local_position(
		propulsion_world_offset
	)
	var relative_velocity := point_velocity - water_velocity
	var longitudinal_speed := relative_velocity.dot(
		base_propulsion_direction
	)
	var absolute_longitudinal_speed := absf(longitudinal_speed)
	var steering_speed_factor := lerpf(
		1.0,
		high_speed_steering_factor,
		_inverse_lerp_clamped(
			steering_reduction_start_speed,
			steering_reduction_end_speed,
			absolute_longitudinal_speed
		)
	)
	state.steering_angle_degrees = (
		input_state.steering
		* maximum_steering_angle_degrees
		* steering_speed_factor
	)
	var propulsion_direction := base_propulsion_direction.rotated(
		water_normal,
		deg_to_rad(state.steering_angle_degrees)
	).normalized()
	var forward_speed_factor := 1.0 - _inverse_lerp_clamped(
		forward_thrust_falloff_start_speed,
		forward_thrust_falloff_end_speed,
		maxf(longitudinal_speed, 0.0)
	)
	var reverse_speed_factor := 1.0 - _inverse_lerp_clamped(
		reverse_thrust_falloff_start_speed,
		reverse_thrust_falloff_end_speed,
		maxf(-longitudinal_speed, 0.0)
	)
	var net_input := input_state.throttle - input_state.brake
	var propulsion_force := Vector3.ZERO
	if net_input > 0.0:
		state.forward_speed_factor = forward_speed_factor
		propulsion_force = (
			propulsion_direction
			* forward_engine_force
			* net_input
			* state.propulsion_contact_factor
			* forward_speed_factor
		)
	elif net_input < 0.0:
		state.reverse_speed_factor = reverse_speed_factor
		propulsion_force = (
			-propulsion_direction
			* reverse_engine_force
			* -net_input
			* state.propulsion_contact_factor
			* reverse_speed_factor
		)
	propulsion_force *= submarine_propulsion_factor
	if not propulsion_force.is_finite():
		_warn_about_invalid_force_once()
	elif not propulsion_force.is_zero_approx():
		state.propulsion_force_vector = propulsion_force
		state.propulsion_force = propulsion_force.length()
		state.propulsion_force_application_offset = (
			propulsion_world_offset
		)
		state.is_propelling = true
		body_state.apply_force(
			propulsion_force,
			propulsion_world_offset
		)
	if is_zero_approx(net_input):
		_apply_coasting_steering(
			body_state,
			input_state.steering,
			base_propulsion_direction,
			propulsion_direction,
			absolute_longitudinal_speed,
			propulsion_world_offset
		)
	return state


func reset_runtime_state() -> void:
	state.reset_runtime_state()


func get_propulsion_local_point() -> Vector3:
	return _propulsion_local_point


func has_valid_propulsion_point() -> bool:
	return _has_propulsion_point


func get_warning_emission_count() -> int:
	return _warning_emission_count


func _apply_coasting_steering(
	body_state: PhysicsDirectBodyState3D,
	steering_input: float,
	forward_direction: Vector3,
	steered_direction: Vector3,
	forward_speed: float,
	world_offset: Vector3
) -> void:
	if (
		absf(steering_input) <= MINIMUM_COASTING_STEERING_INPUT
		or forward_speed <= MINIMUM_COASTING_FORWARD_SPEED
	):
		return
	var lateral_direction := steered_direction - forward_direction
	if lateral_direction.length_squared() <= DIRECTION_EPSILON_SQUARED:
		return
	var steering_force_magnitude := minf(
		forward_speed * forward_speed
		* coasting_steering_force_per_speed_squared
		* absf(steering_input)
		* state.propulsion_contact_factor,
		max_coasting_steering_force
	)
	var coasting_force := (
		lateral_direction.normalized() * steering_force_magnitude
	)
	if not coasting_force.is_finite():
		_warn_about_invalid_force_once()
		return
	state.coasting_steering_force_vector = coasting_force
	state.coasting_force_application_offset = world_offset
	body_state.apply_force(coasting_force, world_offset)


func _inverse_lerp_clamped(from: float, to: float, value: float) -> float:
	if to <= from:
		return 1.0 if value >= to else 0.0
	return clampf(inverse_lerp(from, to, value), 0.0, 1.0)


func _warn_about_missing_propulsion_point_once() -> void:
	if _missing_marker_warning_emitted:
		return
	_missing_marker_warning_emitted = true
	_warning_emission_count += 1
	push_warning(
		"JetSki propulsion is disabled because PropulsionPoint is missing."
	)


func _warn_about_invalid_water_provider_once() -> void:
	if _invalid_ocean_warning_emitted:
		return
	_invalid_ocean_warning_emitted = true
	_warning_emission_count += 1
	push_warning(
		"JetSki propulsion is disabled because its water provider reference is invalid."
	)


func _warn_about_invalid_sample_once() -> void:
	if _invalid_sample_warning_emitted:
		return
	_invalid_sample_warning_emitted = true
	_warning_emission_count += 1
	push_warning(
		"JetSki propulsion ignored a non-finite or degenerate water sample."
	)


func _warn_about_degenerate_direction_once() -> void:
	if _degenerate_direction_warning_emitted:
		return
	_degenerate_direction_warning_emitted = true
	_warning_emission_count += 1
	push_warning(
		"JetSki propulsion ignored a degenerate tangential direction."
	)


func _warn_about_invalid_force_once() -> void:
	if _invalid_force_warning_emitted:
		return
	_invalid_force_warning_emitted = true
	_warning_emission_count += 1
	push_warning("JetSki propulsion ignored a non-finite drive force.")
