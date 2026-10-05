class_name JetSkiSubmarineState
extends RefCounted

var water_mode: JetSkiTypes.RiderStuntWaterMode = JetSkiTypes.RiderStuntWaterMode.NORMAL
var entry_speed: float = 0.0
var entry_pitch_degrees: float = 0.0
var duration: float = 0.0
var current_depth: float = 0.0
var maximum_depth: float = 0.0
var buoyancy_factor_current: float = 1.0
var propulsion_factor_current: float = 1.0
var upright_factor_current: float = 1.0
var exit_blend: float = 1.0
var exit_start_buoyancy_factor: float = 1.0
var recovery_active: bool = false
var pre_contact_valid: bool = false
var pre_contact_transform: Transform3D = Transform3D.IDENTITY
var pre_contact_linear_velocity: Vector3 = Vector3.ZERO
var pre_contact_angular_velocity: Vector3 = Vector3.ZERO
var pre_contact_roll_degrees: float = 0.0
var pre_contact_pitch_degrees: float = 0.0
var pre_contact_horizontal_speed: float = 0.0


func reset_runtime_state() -> void:
	water_mode = JetSkiTypes.RiderStuntWaterMode.NORMAL
	entry_speed = 0.0
	entry_pitch_degrees = 0.0
	duration = 0.0
	current_depth = 0.0
	maximum_depth = 0.0
	buoyancy_factor_current = 1.0
	propulsion_factor_current = 1.0
	upright_factor_current = 1.0
	exit_blend = 1.0
	exit_start_buoyancy_factor = 1.0
	recovery_active = false
	pre_contact_valid = false
	pre_contact_transform = Transform3D.IDENTITY
	pre_contact_linear_velocity = Vector3.ZERO
	pre_contact_angular_velocity = Vector3.ZERO
	pre_contact_roll_degrees = 0.0
	pre_contact_pitch_degrees = 0.0
	pre_contact_horizontal_speed = 0.0
