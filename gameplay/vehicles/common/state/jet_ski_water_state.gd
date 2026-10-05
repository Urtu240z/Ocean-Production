class_name JetSkiWaterState
extends RefCounted

var raw_contact_mask: int = 0

var submerged_point_count: int = 0
var front_submerged_count: int = 0
var rear_submerged_count: int = 0

var submerged_ratio: float = 0.0
var front_submerged_ratio: float = 0.0
var rear_submerged_ratio: float = 0.0

var average_depth: float = 0.0
var maximum_depth: float = 0.0
var maximum_signed_point_depth: float = 0.0

var water_relative_forward_speed: float = 0.0
var water_relative_lateral_speed: float = 0.0

var total_buoyancy_force: float = 0.0
var total_forward_drag_force: float = 0.0
var total_lateral_drag_force: float = 0.0

var maximum_point_buoyancy_force: float = 0.0
var maximum_point_forward_drag: float = 0.0
var maximum_point_lateral_drag: float = 0.0

var hydrodynamic_active_point_count: int = 0
var degenerate_drag_axis_count: int = 0

var support_normal: Vector3 = Vector3.UP
var average_water_velocity: Vector3 = Vector3.ZERO
var sampled_body_forward: Vector3 = Vector3.FORWARD
var sampled_body_linear_velocity: Vector3 = Vector3.ZERO


func reset() -> void:
	raw_contact_mask = 0
	submerged_point_count = 0
	front_submerged_count = 0
	rear_submerged_count = 0
	submerged_ratio = 0.0
	front_submerged_ratio = 0.0
	rear_submerged_ratio = 0.0
	average_depth = 0.0
	maximum_depth = 0.0
	maximum_signed_point_depth = 0.0
	water_relative_forward_speed = 0.0
	water_relative_lateral_speed = 0.0
	total_buoyancy_force = 0.0
	total_forward_drag_force = 0.0
	total_lateral_drag_force = 0.0
	maximum_point_buoyancy_force = 0.0
	maximum_point_forward_drag = 0.0
	maximum_point_lateral_drag = 0.0
	hydrodynamic_active_point_count = 0
	degenerate_drag_axis_count = 0
	support_normal = Vector3.UP
	average_water_velocity = Vector3.ZERO
	sampled_body_forward = Vector3.FORWARD
	sampled_body_linear_velocity = Vector3.ZERO
