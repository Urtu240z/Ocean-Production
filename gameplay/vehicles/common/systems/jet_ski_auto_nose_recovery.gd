extends RefCounted
## Wet-only, unilateral pitch assistance. Existing restoring torques are counted
## before adding any correction, including UPRIGHT and the rider soft limit.
const Pitch = preload("res://gameplay/vehicles/common/systems/jet_ski_nose_up_limit.gd")


static func response(basis: Basis, angular_velocity: Vector3, inverse_inertia: Basis,
		known_torque: Vector3, authority: float, start_degrees: float,
		response_rate: float, damping_ratio: float, max_torque: float, dt: float) -> Vector3:
	var excess := -Pitch.world_pitch(basis) - deg_to_rad(clampf(start_degrees, 3.0, 30.0))
	if authority <= 0.0 or excess <= 0.0 or max_torque <= 0.0 \
			or not inverse_inertia.is_finite() or absf(inverse_inertia.determinant()) < 1.0e-12:
		return Vector3.ZERO
	var forward := -basis.z.normalized()
	var axis := forward.cross(Vector3.UP)
	if axis.length_squared() < 0.000001:
		axis = basis.x - Vector3.UP * basis.x.y
	if axis.length_squared() < 0.000001: return Vector3.ZERO
	axis = axis.normalized()
	var rate := minf(clampf(response_rate, 1.0, 8.0), 0.2 / maxf(dt, 0.000001))
	var pitch_rate := angular_velocity.dot(axis)
	var target_acceleration := rate * rate * excess \
		- 2.0 * clampf(damping_ratio, 0.25, 2.0) * rate * pitch_rate
	# Never brake a rising nose with a downward assist. Angular damping reduces
	# the lift to zero as the craft recovers instead of fighting the other guards.
	if target_acceleration <= 0.0: return Vector3.ZERO
	var existing_acceleration := (inverse_inertia * known_torque).dot(axis)
	var correction := maxf(target_acceleration - existing_acceleration, 0.0)
	var blend := smoothstep(0.0, deg_to_rad(5.0), excess) * clampf(authority, 0.0, 1.0)
	var torque := inverse_inertia.inverse() * (axis * correction * blend)
	if not torque.is_finite(): return Vector3.ZERO
	return torque.limit_length(max_torque)
