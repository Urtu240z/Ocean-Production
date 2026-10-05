class_name JetSkiWaterPhysicsSystem
extends Node

const BUOYANCY_POINT_COUNT: int = 4
const FRONT_POINT_COUNT: int = 2
const POINT_NAMES: Array[StringName] = [
	&"FrontLeft",
	&"FrontRight",
	&"RearLeft",
	&"RearRight",
]

@export_range(0.05, 0.5, 0.01) var equilibrium_depth := 0.15
@export_range(0.8, 1.0, 0.01) var damping_ratio := 0.9

var state: JetSkiWaterState = JetSkiWaterState.new()

var buoyancy_strength_per_point: float = 5500.0
var buoyancy_damping_per_point: float = 2500.0
var max_submersion_depth: float = 0.8
var deep_buoyancy_start_depth: float = 1.0
var deep_buoyancy_strength_per_point: float = 3500.0
var deep_buoyancy_force_limit_per_meter: float = 5000.0
var max_buoyancy_force_per_point: float = 5500.0

var forward_drag_linear_per_point: float = 15.0
var forward_drag_quadratic_per_point: float = 1.5
var lateral_drag_linear_per_point: float = 80.0
var lateral_drag_quadratic_per_point: float = 7.0
var drag_depth_exponent: float = 1.0
var maximum_forward_drag_force_per_point: float = 3500.0
var maximum_lateral_drag_force_per_point: float = 7000.0

var point_depths: PackedFloat32Array:
	get:
		return _point_depths
var point_normal_forces: PackedFloat32Array:
	get:
		return _point_normal_forces
var point_buoyancy_force_vectors: PackedVector3Array:
	get:
		return _point_buoyancy_force_vectors
var point_water_normals: PackedVector3Array:
	get:
		return _point_water_normals
var point_world_positions: PackedVector3Array:
	get:
		return _point_world_positions
var point_water_surface_positions: PackedVector3Array:
	get:
		return _point_water_surface_positions
var point_water_velocities: PackedVector3Array:
	get:
		return _point_water_velocities
var point_physical_velocities: PackedVector3Array:
	get:
		return _point_physical_velocities
var point_relative_velocities: PackedVector3Array:
	get:
		return _point_relative_velocities
var point_relative_normal_speeds: PackedFloat32Array:
	get:
		return _point_relative_normal_speeds
var point_sample_valid: Array[bool]:
	get:
		return _point_sample_valid
var point_forward_drag_forces: PackedVector3Array:
	get:
		return _point_forward_drag_forces
var point_lateral_drag_forces: PackedVector3Array:
	get:
		return _point_lateral_drag_forces

var _buoyancy_local_points: PackedVector3Array = PackedVector3Array()
var _point_depths: PackedFloat32Array = PackedFloat32Array()
var _point_normal_forces: PackedFloat32Array = PackedFloat32Array()
var _point_buoyancy_force_vectors: PackedVector3Array = PackedVector3Array()
var _point_water_normals: PackedVector3Array = PackedVector3Array()
var _point_world_positions: PackedVector3Array = PackedVector3Array()
var _point_water_surface_positions: PackedVector3Array = PackedVector3Array()
var _point_water_velocities: PackedVector3Array = PackedVector3Array()
var _point_physical_velocities: PackedVector3Array = PackedVector3Array()
var _point_relative_velocities: PackedVector3Array = PackedVector3Array()
var _point_relative_normal_speeds: PackedFloat32Array = PackedFloat32Array()
var _point_sample_valid: Array[bool] = []
var _point_forward_drag_forces: PackedVector3Array = PackedVector3Array()
var _point_lateral_drag_forces: PackedVector3Array = PackedVector3Array()
var _water_sample_scratch: WaterSample3D = WaterSample3D.new()

var _point_warning_emitted: bool = false
var _invalid_sample_warning_emitted: bool = false
var _invalid_drag_warning_emitted: bool = false
var _degenerate_axis_warning_emitted: bool = false
var _runtime_array_resize_count: int = 0


func configure(buoyancy_points_root: Node3D) -> void:
	_resize_runtime_arrays()
	_buoyancy_local_points.clear()
	if buoyancy_points_root == null:
		_warn_about_missing_points_once()
		reset_runtime_state()
		return
	for point_name in POINT_NAMES:
		var marker := buoyancy_points_root.get_node_or_null(
			NodePath(point_name)
		) as Marker3D
		if marker == null:
			_buoyancy_local_points.clear()
			_warn_about_missing_points_once()
			reset_runtime_state()
			return
		_buoyancy_local_points.append(
			(buoyancy_points_root.transform * marker.transform).origin
		)
	reset_runtime_state()


func has_valid_buoyancy_points() -> bool:
	return _buoyancy_local_points.size() == BUOYANCY_POINT_COUNT


func step(
	body_state: PhysicsDirectBodyState3D,
	water_provider: WaterSurfaceProvider3D,
	submarine_buoyancy_factor: float
) -> JetSkiWaterState:
	reset_runtime_state()
	if water_provider == null or not is_instance_valid(water_provider):
		return state
	if not has_valid_buoyancy_points():
		_warn_about_missing_points_once()
		return state
	if water_provider.has_method("has_usable_contacts") and not water_provider.has_usable_contacts(): return state
	var depth_sum: float = 0.0
	var maximum_signed_depth: float = -INF
	var active_water_normal_sum := Vector3.ZERO
	var active_water_velocity_sum := Vector3.ZERO
	var body_forward := -body_state.transform.basis.z.normalized()
	state.sampled_body_forward = body_forward
	state.sampled_body_linear_velocity = body_state.linear_velocity
	for index in BUOYANCY_POINT_COUNT:
		var local_point := _buoyancy_local_points[index]
		var world_point := body_state.transform * local_point
		var world_offset := world_point - body_state.transform.origin
		_point_world_positions[index] = world_point
		var water_sample := water_provider.sample_water(
			world_point,
			_water_sample_scratch
		)
		if not water_sample.valid:
			_warn_about_invalid_sample_once()
			continue
		_point_water_surface_positions[index] = water_sample.surface_position
		_point_sample_valid[index] = true
		_point_water_normals[index] = water_sample.normal
		_point_water_velocities[index] = water_sample.velocity
		var depth := water_sample.signed_depth
		_point_depths[index] = depth
		maximum_signed_depth = maxf(maximum_signed_depth, depth)
		if depth <= 0.0:
			continue
		state.raw_contact_mask |= 1 << index
		var water_normal := water_sample.normal
		var water_velocity := water_sample.velocity
		if not water_normal.is_finite() or not water_velocity.is_finite():
			_warn_about_invalid_sample_once()
			continue
		if water_normal.length_squared() <= 0.000001:
			_warn_about_invalid_sample_once()
			continue
		water_normal = water_normal.normalized()
		if water_normal.y < 0.0:
			water_normal = -water_normal
		var point_velocity := body_state.get_velocity_at_local_position(
			world_offset
		)
		var relative_velocity := point_velocity - water_velocity
		var normal_speed := relative_velocity.y
		_point_water_velocities[index] = water_velocity
		_point_physical_velocities[index] = point_velocity
		_point_relative_velocities[index] = relative_velocity
		_point_relative_normal_speeds[index] = normal_speed
		_point_sample_valid[index] = true
		var depth_ratio := clampf(depth / max_submersion_depth, 0.0, 1.0)
		var effective_mass := 1.0 / body_state.inverse_mass / 4.0
		var gravity := body_state.total_gravity.length()
		var spring := effective_mass * gravity / equilibrium_depth
		var damping := damping_ratio * 2.0 * sqrt(spring * effective_mass)
		# Fade damping at the surface so entry starts continuously at zero force.
		var normal_force := maxf(0.0, spring * depth - damping * relative_velocity.y * clampf(depth / equilibrium_depth, 0.0, 1.0))
		if not is_finite(normal_force):
			push_error("Non-finite heightfield support"); continue
		_point_normal_forces[index] = normal_force
		_point_water_normals[index] = water_normal
		var support_up := -body_state.total_gravity.normalized()
		var buoyancy_force := support_up * normal_force
		_point_buoyancy_force_vectors[index] = buoyancy_force
		state.total_buoyancy_force += buoyancy_force.length()
		state.maximum_point_buoyancy_force = maxf(
			state.maximum_point_buoyancy_force,
			buoyancy_force.length()
		)
		body_state.apply_force(buoyancy_force, world_offset)
		_apply_point_hydrodynamic_drag(
			body_state,
			index,
			world_offset,
			body_forward,
			water_normal,
			relative_velocity,
			depth_ratio
		)
		active_water_normal_sum += water_normal
		active_water_velocity_sum += water_velocity
		state.submerged_point_count += 1
		depth_sum += depth
		state.maximum_depth = maxf(state.maximum_depth, depth)
		if index < FRONT_POINT_COUNT:
			state.front_submerged_count += 1
		else:
			state.rear_submerged_count += 1
	if state.submerged_point_count > 0:
		state.average_depth = (
			depth_sum / float(state.submerged_point_count)
		)
	_update_hydrodynamic_speed_metrics(
		body_state,
		body_forward,
		active_water_normal_sum,
		active_water_velocity_sum
	)
	state.maximum_signed_point_depth = maximum_signed_depth
	_update_ratios()
	if state.total_buoyancy_force > 0.0 and water_provider.has_method("record_force_application"):
		water_provider.record_force_application(Engine.get_physics_frames())
	return state


func reset_runtime_state() -> void:
	state.reset()
	for index in _point_depths.size():
		_point_depths[index] = 0.0
		_point_normal_forces[index] = 0.0
		_point_buoyancy_force_vectors[index] = Vector3.ZERO
		_point_water_normals[index] = Vector3.UP
		_point_world_positions[index] = Vector3.ZERO
		_point_water_surface_positions[index] = Vector3.ZERO
		_point_water_velocities[index] = Vector3.ZERO
		_point_physical_velocities[index] = Vector3.ZERO
		_point_relative_velocities[index] = Vector3.ZERO
		_point_relative_normal_speeds[index] = 0.0
		_point_sample_valid[index] = false
		_point_forward_drag_forces[index] = Vector3.ZERO
		_point_lateral_drag_forces[index] = Vector3.ZERO


func get_buoyancy_local_points() -> PackedVector3Array:
	return _buoyancy_local_points.duplicate()


func get_buoyancy_point_depths() -> PackedFloat32Array:
	return _point_depths.duplicate()


func get_buoyancy_point_normal_forces() -> PackedFloat32Array:
	return _point_normal_forces.duplicate()


func get_buoyancy_point_normal_force_vectors() -> PackedVector3Array:
	return _point_buoyancy_force_vectors.duplicate()


func get_buoyancy_point_water_normals() -> PackedVector3Array:
	return _point_water_normals.duplicate()


func get_point_forward_drag_forces() -> PackedVector3Array:
	return _point_forward_drag_forces.duplicate()


func get_point_lateral_drag_forces() -> PackedVector3Array:
	return _point_lateral_drag_forces.duplicate()


func get_point_physical_velocities() -> PackedVector3Array:
	return _point_physical_velocities.duplicate()


func get_point_relative_velocities() -> PackedVector3Array:
	return _point_relative_velocities.duplicate()


func get_point_relative_normal_speeds() -> PackedFloat32Array:
	return _point_relative_normal_speeds.duplicate()


func get_point_sample_valid() -> Array[bool]:
	return _point_sample_valid.duplicate()


func get_signed_point_depth(index: int) -> float:
	if index < 0 or index >= _point_depths.size():
		return 0.0
	return _point_depths[index]


func get_point_world_position(index: int) -> Vector3:
	if index < 0 or index >= _point_world_positions.size():
		return Vector3.ZERO
	return _point_world_positions[index]


func get_point_relative_normal_speed(index: int) -> float:
	if index < 0 or index >= _point_relative_normal_speeds.size():
		return 0.0
	return _point_relative_normal_speeds[index]


func is_point_sample_valid(index: int) -> bool:
	if index < 0 or index >= _point_sample_valid.size():
		return false
	return _point_sample_valid[index]


func get_degenerate_drag_axis_count() -> int:
	return state.degenerate_drag_axis_count


func get_runtime_array_resize_count() -> int:
	return _runtime_array_resize_count


func _resize_runtime_arrays() -> void:
	_runtime_array_resize_count += 1
	_point_depths.resize(BUOYANCY_POINT_COUNT)
	_point_normal_forces.resize(BUOYANCY_POINT_COUNT)
	_point_buoyancy_force_vectors.resize(BUOYANCY_POINT_COUNT)
	_point_water_normals.resize(BUOYANCY_POINT_COUNT)
	_point_world_positions.resize(BUOYANCY_POINT_COUNT)
	_point_water_surface_positions.resize(BUOYANCY_POINT_COUNT)
	_point_water_velocities.resize(BUOYANCY_POINT_COUNT)
	_point_physical_velocities.resize(BUOYANCY_POINT_COUNT)
	_point_relative_velocities.resize(BUOYANCY_POINT_COUNT)
	_point_relative_normal_speeds.resize(BUOYANCY_POINT_COUNT)
	_point_sample_valid.resize(BUOYANCY_POINT_COUNT)
	_point_forward_drag_forces.resize(BUOYANCY_POINT_COUNT)
	_point_lateral_drag_forces.resize(BUOYANCY_POINT_COUNT)


func _update_ratios() -> void:
	state.submerged_ratio = (
		float(state.submerged_point_count)
		/ float(BUOYANCY_POINT_COUNT)
	)
	state.front_submerged_ratio = (
		float(state.front_submerged_count)
		/ float(FRONT_POINT_COUNT)
	)
	state.rear_submerged_ratio = (
		float(state.rear_submerged_count)
		/ float(FRONT_POINT_COUNT)
	)


func _apply_point_hydrodynamic_drag(
	body_state: PhysicsDirectBodyState3D,
	point_index: int,
	world_offset: Vector3,
	body_forward: Vector3,
	water_normal: Vector3,
	relative_velocity: Vector3,
	depth_ratio: float
) -> void:
	var normal_component := (
		water_normal * relative_velocity.dot(water_normal)
	)
	var tangential_velocity := relative_velocity - normal_component
	var forward_tangent := (
		body_forward - water_normal * body_forward.dot(water_normal)
	)
	if forward_tangent.length_squared() <= 0.000001:
		state.degenerate_drag_axis_count += 1
		_warn_about_degenerate_axis_once()
		return
	forward_tangent = forward_tangent.normalized()
	var right_tangent := forward_tangent.cross(water_normal)
	if right_tangent.length_squared() <= 0.000001:
		state.degenerate_drag_axis_count += 1
		_warn_about_degenerate_axis_once()
		return
	right_tangent = right_tangent.normalized()
	var forward_speed := tangential_velocity.dot(forward_tangent)
	var lateral_speed := tangential_velocity.dot(right_tangent)
	var immersion_factor := pow(depth_ratio, drag_depth_exponent)
	var forward_drag_scalar := clampf(
		_drag_scalar(
			forward_speed,
			forward_drag_linear_per_point,
			forward_drag_quadratic_per_point
		) * immersion_factor,
		-maximum_forward_drag_force_per_point,
		maximum_forward_drag_force_per_point
	)
	var lateral_drag_scalar := clampf(
		_drag_scalar(
			lateral_speed,
			lateral_drag_linear_per_point,
			lateral_drag_quadratic_per_point
		) * immersion_factor,
		-maximum_lateral_drag_force_per_point,
		maximum_lateral_drag_force_per_point
	)
	var forward_drag := -forward_tangent * forward_drag_scalar
	var lateral_drag := -right_tangent * lateral_drag_scalar
	var drag_force := forward_drag + lateral_drag
	if not drag_force.is_finite():
		_warn_about_invalid_drag_once()
		return
	_point_forward_drag_forces[point_index] = forward_drag
	_point_lateral_drag_forces[point_index] = lateral_drag
	state.total_forward_drag_force += absf(forward_drag_scalar)
	state.total_lateral_drag_force += absf(lateral_drag_scalar)
	state.maximum_point_forward_drag = maxf(
		state.maximum_point_forward_drag,
		absf(forward_drag_scalar)
	)
	state.maximum_point_lateral_drag = maxf(
		state.maximum_point_lateral_drag,
		absf(lateral_drag_scalar)
	)
	state.hydrodynamic_active_point_count += 1
	body_state.apply_force(drag_force, world_offset)


func _update_hydrodynamic_speed_metrics(
	body_state: PhysicsDirectBodyState3D,
	body_forward: Vector3,
	water_normal_sum: Vector3,
	water_velocity_sum: Vector3
) -> void:
	if state.hydrodynamic_active_point_count <= 0:
		return
	var average_water_normal := water_normal_sum.normalized()
	var average_water_velocity := (
		water_velocity_sum
		/ float(state.hydrodynamic_active_point_count)
	)
	state.support_normal = average_water_normal
	state.average_water_velocity = average_water_velocity
	var forward_tangent := (
		body_forward
		- average_water_normal * body_forward.dot(average_water_normal)
	)
	if forward_tangent.length_squared() <= 0.000001:
		return
	forward_tangent = forward_tangent.normalized()
	var right_tangent := (
		forward_tangent.cross(average_water_normal).normalized()
	)
	var relative_center_velocity := (
		body_state.linear_velocity - average_water_velocity
	)
	var tangential_center_velocity := (
		relative_center_velocity
		- average_water_normal
		* relative_center_velocity.dot(average_water_normal)
	)
	state.water_relative_forward_speed = (
		tangential_center_velocity.dot(forward_tangent)
	)
	state.water_relative_lateral_speed = (
		tangential_center_velocity.dot(right_tangent)
	)


func _drag_scalar(
	speed: float,
	linear_coefficient: float,
	quadratic_coefficient: float
) -> float:
	return (
		linear_coefficient * speed
		+ quadratic_coefficient * speed * absf(speed)
	)


func _warn_about_missing_points_once() -> void:
	if _point_warning_emitted:
		return
	_point_warning_emitted = true
	push_warning(
		"JetSki buoyancy is disabled because exactly four "
		+ "buoyancy markers are required."
	)


func _warn_about_invalid_sample_once() -> void:
	if _invalid_sample_warning_emitted:
		return
	_invalid_sample_warning_emitted = true
	push_warning("JetSki water sampling returned a non-finite or invalid value.")


func _warn_about_invalid_drag_once() -> void:
	if _invalid_drag_warning_emitted:
		return
	_invalid_drag_warning_emitted = true
	push_warning("JetSki hydrodynamic drag produced a non-finite force.")


func _warn_about_degenerate_axis_once() -> void:
	if _degenerate_axis_warning_emitted:
		return
	_degenerate_axis_warning_emitted = true
	push_warning("JetSki hydrodynamic drag skipped a degenerate tangent axis.")
