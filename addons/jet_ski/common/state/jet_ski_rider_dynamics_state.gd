class_name JetSkiRiderDynamicsState
extends RefCounted

var using_air_control: bool = false
var turn_lean_airborne_disabled: bool = false
var rider_shift_airborne: bool = false
var air_unlimited_rotation: bool = false
var air_roll_rate: float = 0.0
var air_pitch_rate: float = 0.0
var air_accumulated_roll_degrees: float = 0.0
var air_accumulated_pitch_degrees: float = 0.0
var air_tracking_active: bool = false
var air_correction_roll_torque_current: float = 0.0
var air_correction_pitch_torque_current: float = 0.0

var turn_lean_target_roll: float = 0.0
var turn_lean_current_roll: float = 0.0
var turn_lean_roll_error: float = 0.0
var turn_lean_speed_factor: float = 0.0
var turn_lean_contact_factor: float = 0.0
var turn_lean_roll_rate: float = 0.0
var turn_lean_requested_torque: float = 0.0
var turn_lean_applied_torque_vector: Vector3 = Vector3.ZERO

var smoothed_support_normal: Vector3 = Vector3.UP
var reference_forward: Vector3 = Vector3.FORWARD
var reference_right: Vector3 = Vector3.RIGHT
var turn_lean_landing_ramp: float = 0.0

var rider_shift_speed_authority: float = 0.0
var rider_shift_speed_factor: float = 0.0
var rider_shift_contact_authority: float = 0.0
var rider_shift_air_authority_active: float = 0.0
var rider_manual_medium_authority: float = 0.0

var rider_shift_manual_roll_target: float = 0.0
var rider_shift_total_roll_target: float = 0.0
var rider_shift_base_pitch_target: float = 0.0
var rider_shift_manual_pitch_target: float = 0.0
var rider_shift_total_pitch_target: float = 0.0
var rider_shift_current_pitch: float = 0.0

var rider_shift_roll_torque: float = 0.0
var rider_shift_pitch_torque: float = 0.0
var rider_shift_front_contact_ratio: float = 0.0
var rider_shift_rear_contact_ratio: float = 0.0
var rider_shift_landing_ramp: float = 0.0

var virtual_offset_local: Vector3 = Vector3.ZERO
var virtual_offset_world: Vector3 = Vector3.ZERO
var virtual_weight_torque: Vector3 = Vector3.ZERO
var manual_applied_torque: Vector3 = Vector3.ZERO
var roll_damping_torque: Vector3 = Vector3.ZERO
var pitch_damping_torque: Vector3 = Vector3.ZERO
var dynamic_pitch_multiplier: float = 1.0

var arrow_only_steering_input: float = 0.0
var arrow_only_steering_angle: float = 0.0
var roll_soft_limit_factor: float = 0.0
var pitch_soft_limit_factor: float = 0.0
var total_applied_torque_vector: Vector3 = Vector3.ZERO


func clear_frame_metrics() -> void:
	using_air_control = false
	turn_lean_airborne_disabled = false
	rider_shift_airborne = false
	air_unlimited_rotation = false
	air_roll_rate = 0.0
	air_pitch_rate = 0.0
	air_correction_roll_torque_current = 0.0
	air_correction_pitch_torque_current = 0.0
	turn_lean_target_roll = 0.0
	turn_lean_current_roll = 0.0
	turn_lean_roll_error = 0.0
	turn_lean_speed_factor = 0.0
	turn_lean_contact_factor = 0.0
	turn_lean_roll_rate = 0.0
	turn_lean_requested_torque = 0.0
	turn_lean_applied_torque_vector = Vector3.ZERO
	rider_shift_speed_authority = 0.0
	rider_shift_speed_factor = 0.0
	rider_shift_contact_authority = 0.0
	rider_shift_air_authority_active = 0.0
	rider_manual_medium_authority = 0.0
	rider_shift_manual_roll_target = 0.0
	rider_shift_total_roll_target = 0.0
	rider_shift_base_pitch_target = 0.0
	rider_shift_manual_pitch_target = 0.0
	rider_shift_total_pitch_target = 0.0
	rider_shift_current_pitch = 0.0
	rider_shift_roll_torque = 0.0
	rider_shift_pitch_torque = 0.0
	rider_shift_front_contact_ratio = 0.0
	rider_shift_rear_contact_ratio = 0.0
	virtual_offset_local = Vector3.ZERO
	virtual_offset_world = Vector3.ZERO
	virtual_weight_torque = Vector3.ZERO
	manual_applied_torque = Vector3.ZERO
	roll_damping_torque = Vector3.ZERO
	pitch_damping_torque = Vector3.ZERO
	dynamic_pitch_multiplier = 1.0
	arrow_only_steering_input = 0.0
	arrow_only_steering_angle = 0.0
	roll_soft_limit_factor = 0.0
	pitch_soft_limit_factor = 0.0
	total_applied_torque_vector = Vector3.ZERO


func reset_runtime_state() -> void:
	clear_frame_metrics()
	air_accumulated_roll_degrees = 0.0
	air_accumulated_pitch_degrees = 0.0
	air_tracking_active = false
	smoothed_support_normal = Vector3.UP
	reference_forward = Vector3.FORWARD
	reference_right = Vector3.RIGHT
	turn_lean_landing_ramp = 0.0
	rider_shift_landing_ramp = 0.0
