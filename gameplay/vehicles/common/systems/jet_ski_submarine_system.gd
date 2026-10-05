class_name JetSkiSubmarineSystem
extends Node

signal dive_started
signal dive_ended(duration: float, maximum_depth: float)

const SUBMARINE_MAX_ENTRY_ROLL_DEGREES: float = 45.0
const SUBMARINE_MIN_EXIT_SPEED: float = 3.0
const SUBMARINE_SAFETY_DEPTH: float = 3.0
const SUBMARINE_CLEAR_NOSE_UP_DEGREES: float = 10.0
const SUBMARINE_ENTRY_BUOYANCY_BLEND_TIME: float = 0.12
const FRONT_CONTACT_MASK: int = 3
const REAR_CONTACT_MASK: int = 12

var state: JetSkiSubmarineState = JetSkiSubmarineState.new()
var dive_enabled: bool = true
var entry_min_nose_down_degrees: float = 25.0
var entry_max_nose_down_degrees: float = 48.0
var entry_min_speed: float = 8.0
var target_nose_down_degrees: float = 38.0
var maximum_duration: float = 1.25
var upright_factor: float = 0.12
var buoyancy_factor: float = 0.72
var propulsion_factor: float = 0.75
var exit_blend_time: float = 0.30
var rider_soft_limit_stiffness: float = 12000.0
var rider_soft_limit_damping: float = 3000.0


func is_dive_active() -> bool:
	return state.water_mode == JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE


func get_control_blend() -> float:
	if is_dive_active():
		return 1.0
	if state.recovery_active:
		return 1.0 - state.exit_blend
	return 0.0


func capture_pre_contact_state(body_state: PhysicsDirectBodyState3D, attitude: Vector2) -> void:
	state.pre_contact_valid = body_state.transform.is_finite() and body_state.linear_velocity.is_finite() and body_state.angular_velocity.is_finite() and attitude.is_finite()
	if not state.pre_contact_valid:
		return
	state.pre_contact_transform = body_state.transform
	state.pre_contact_linear_velocity = body_state.linear_velocity
	state.pre_contact_angular_velocity = body_state.angular_velocity
	state.pre_contact_roll_degrees = rad_to_deg(attitude.x)
	state.pre_contact_pitch_degrees = rad_to_deg(attitude.y)
	state.pre_contact_horizontal_speed = Vector2(body_state.linear_velocity.x, body_state.linear_velocity.z).length()


func update_before_forces(body_state: PhysicsDirectBodyState3D, input_state: JetSkiInputState, current_attitude: Vector2, physics_delta: float) -> void:
	if is_dive_active():
		state.duration += maxf(physics_delta, 0.0)
		var forward_input := maxf(-input_state.rider_shift_raw.y, 0.0)
		var horizontal_speed := Vector2(body_state.linear_velocity.x, body_state.linear_velocity.z).length()
		if not dive_enabled or forward_input < 0.60 or state.duration >= maximum_duration or horizontal_speed < SUBMARINE_MIN_EXIT_SPEED or rad_to_deg(current_attitude.y) > SUBMARINE_CLEAR_NOSE_UP_DEGREES or state.current_depth >= SUBMARINE_SAFETY_DEPTH:
			_end_dive()
	if is_dive_active():
		state.buoyancy_factor_current = move_toward(state.buoyancy_factor_current, buoyancy_factor, maxf(physics_delta, 0.0) * absf(1.0 - buoyancy_factor) / SUBMARINE_ENTRY_BUOYANCY_BLEND_TIME)
		state.propulsion_factor_current = propulsion_factor
		state.upright_factor_current = upright_factor
		state.exit_blend = 0.0
		state.recovery_active = false
		return
	if state.recovery_active:
		state.exit_blend = minf(state.exit_blend + maxf(physics_delta, 0.0) / maxf(exit_blend_time, 0.0001), 1.0)
		var weight := smoothstep(0.0, 1.0, state.exit_blend)
		state.buoyancy_factor_current = lerpf(state.exit_start_buoyancy_factor, 1.0, weight)
		state.propulsion_factor_current = lerpf(propulsion_factor, 1.0, weight)
		state.upright_factor_current = lerpf(upright_factor, 1.0, weight)
		if state.exit_blend >= 1.0:
			state.recovery_active = false
		return
	state.buoyancy_factor_current = 1.0
	state.propulsion_factor_current = 1.0
	state.upright_factor_current = 1.0
	state.exit_blend = 1.0


func update_after_contacts(input_state: JetSkiInputState, water_state: JetSkiWaterState, navigation_state: JetSkiNavigationState, water_system: JetSkiWaterPhysicsSystem) -> void:
	var first_contact := navigation_state.previous_contact_mask == 0 and navigation_state.current_contact_mask != 0
	if first_contact:
		_try_start_dive(input_state, water_state, navigation_state, water_system)
		state.pre_contact_valid = false
	if is_dive_active() or state.recovery_active:
		state.current_depth = maxf(water_state.average_depth, 0.0)
		state.maximum_depth = maxf(state.maximum_depth, state.current_depth)
	elif navigation_state.current_contact_mask == 0:
		state.current_depth = 0.0


func _try_start_dive(input_state: JetSkiInputState, water_state: JetSkiWaterState, navigation_state: JetSkiNavigationState, water_system: JetSkiWaterPhysicsSystem) -> void:
	if not dive_enabled or not state.pre_contact_valid or state.water_mode != JetSkiTypes.RiderStuntWaterMode.NORMAL or state.recovery_active:
		return
	var forward_input := maxf(-input_state.rider_shift_raw.y, 0.0)
	var nose_down := -state.pre_contact_pitch_degrees
	var vehicle_up := state.pre_contact_transform.basis.y.normalized()
	if forward_input < 0.60 or state.pre_contact_horizontal_speed < entry_min_speed or nose_down < entry_min_nose_down_degrees or nose_down > entry_max_nose_down_degrees or absf(state.pre_contact_roll_degrees) >= SUBMARINE_MAX_ENTRY_ROLL_DEGREES or vehicle_up.dot(Vector3.UP) <= 0.25 or not _front_leads_entry(navigation_state, water_system):
		return
	state.water_mode = JetSkiTypes.RiderStuntWaterMode.SUBMARINE_DIVE
	state.entry_speed = state.pre_contact_horizontal_speed
	state.entry_pitch_degrees = state.pre_contact_pitch_degrees
	state.duration = 0.0
	state.current_depth = maxf(water_state.average_depth, 0.0)
	state.maximum_depth = state.current_depth
	state.exit_blend = 0.0
	state.recovery_active = false
	state.propulsion_factor_current = propulsion_factor
	state.upright_factor_current = upright_factor
	dive_started.emit()


func _front_leads_entry(navigation_state: JetSkiNavigationState, water_system: JetSkiWaterPhysicsSystem) -> bool:
	var front_contacts: int = _count_contact_bits(
		navigation_state.new_contact_mask & FRONT_CONTACT_MASK
	)
	var rear_contacts: int = _count_contact_bits(
		navigation_state.new_contact_mask & REAR_CONTACT_MASK
	)
	var front_depth := (water_system.point_depths[0] + water_system.point_depths[1]) * 0.5
	var rear_depth := (water_system.point_depths[2] + water_system.point_depths[3]) * 0.5
	return front_contacts > 0 and (front_contacts > rear_contacts or front_depth > rear_depth + 0.05)


func _count_contact_bits(contact_mask: int) -> int:
	var contact_count: int = 0
	for bit_index in 4:
		if (contact_mask & (1 << bit_index)) != 0:
			contact_count += 1
	return contact_count


func calculate_pitch_target_torque(body_state: PhysicsDirectBodyState3D, rider_state: JetSkiRiderDynamicsState, body_right: Vector3) -> Vector3:
	if not is_dive_active():
		return Vector3.ZERO
	var pitch_error := wrapf(-deg_to_rad(target_nose_down_degrees) - rider_state.rider_shift_current_pitch, -PI, PI)
	var pitch_rate := body_state.angular_velocity.dot(body_right)
	var maximum_torque := rider_soft_limit_stiffness * deg_to_rad(20.0)
	var torque := clampf(pitch_error * rider_soft_limit_stiffness * 0.30 - pitch_rate * rider_soft_limit_damping * 0.20, -maximum_torque, maximum_torque)
	return body_right * torque * rider_state.rider_manual_medium_authority


func _end_dive() -> void:
	if not is_dive_active():
		return
	state.water_mode = JetSkiTypes.RiderStuntWaterMode.NORMAL
	state.recovery_active = true
	state.exit_start_buoyancy_factor = state.buoyancy_factor_current
	state.exit_blend = 0.0
	dive_ended.emit(state.duration, state.maximum_depth)


func reset_runtime_state(emit_end_signal: bool) -> void:
	if emit_end_signal and is_dive_active():
		dive_ended.emit(state.duration, state.maximum_depth)
	state.reset_runtime_state()


func apply_world_rebase(horizontal_shift: Vector3) -> void:
	if state.pre_contact_valid:
		state.pre_contact_transform.origin -= horizontal_shift
