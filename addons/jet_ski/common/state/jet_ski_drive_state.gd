class_name JetSkiDriveState
extends RefCounted

var propulsion_depth: float = 0.0
var propulsion_contact_factor: float = 0.0

var steering_angle_degrees: float = 0.0

var forward_speed_factor: float = 0.0
var reverse_speed_factor: float = 0.0

var propulsion_force: float = 0.0
var propulsion_force_vector: Vector3 = Vector3.ZERO

var propulsion_world_position: Vector3 = Vector3.ZERO
var propulsion_force_application_offset: Vector3 = Vector3.ZERO
var coasting_steering_force_vector: Vector3 = Vector3.ZERO
var coasting_force_application_offset: Vector3 = Vector3.ZERO
var is_propelling: bool = false


func clear_frame_metrics() -> void:
	propulsion_depth = 0.0
	propulsion_contact_factor = 0.0
	steering_angle_degrees = 0.0
	forward_speed_factor = 0.0
	reverse_speed_factor = 0.0
	propulsion_force = 0.0
	propulsion_force_vector = Vector3.ZERO
	propulsion_force_application_offset = Vector3.ZERO
	coasting_steering_force_vector = Vector3.ZERO
	coasting_force_application_offset = Vector3.ZERO
	is_propelling = false


func reset_runtime_state() -> void:
	# Preserve propulsion_world_position: the previous controller kept the last
	# sampled world position until the next valid propulsion-point sample.
	clear_frame_metrics()
