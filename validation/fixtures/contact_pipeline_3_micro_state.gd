extends PhysicsDirectBodyState3DExtension
## Deterministic force consumer for interface microbench; never accesses Jolt.
var body_transform := Transform3D.IDENTITY
var body_linear := Vector3(5,-1,0.5)
var body_angular := Vector3(0.2,0.3,0.1)
var sum_force := Vector3.ZERO
var sum_torque := Vector3.ZERO
var recording := false
var force_order: Array = []
func reset_forces() -> void:
	sum_force = Vector3.ZERO
	sum_torque = Vector3.ZERO
	force_order.clear()
func _get_transform() -> Transform3D: return body_transform
func _get_total_gravity() -> Vector3: return Vector3(0,-9.8,0)
func _get_inverse_mass() -> float: return 1.0/350.0
func _get_center_of_mass_local() -> Vector3: return Vector3.ZERO
func _get_linear_velocity() -> Vector3: return body_linear
func _get_angular_velocity() -> Vector3: return body_angular
func _get_inverse_inertia_tensor() -> Basis: return Basis.from_scale(Vector3(0.003,0.002,0.004))
func _get_velocity_at_local_position(local_position: Vector3) -> Vector3: return body_linear+body_angular.cross(local_position)
func _get_step() -> float: return 1.0/60.0
func _get_contact_count() -> int: return 0
func _apply_force(force: Vector3, offset: Vector3) -> void:
	sum_force += force
	sum_torque += offset.cross(force)
	if recording: force_order.append([0,force,offset])
func _apply_central_force(force: Vector3) -> void:
	sum_force += force
	if recording: force_order.append([1,force])
func _apply_torque(torque: Vector3) -> void:
	sum_torque += torque
	if recording: force_order.append([2,torque])
