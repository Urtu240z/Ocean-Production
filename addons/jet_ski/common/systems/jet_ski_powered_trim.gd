extends RefCounted
## Small unilateral pitch floor under throttle; no linear force or air adhesion.
const Pitch = preload("res://addons/jet_ski/common/systems/jet_ski_nose_up_limit.gd")


static func response(basis: Basis, angular_velocity: Vector3, inverse_inertia: Basis,
		known_torque: Vector3, authority: float, minimum_degrees: float,
		response_rate: float, max_torque_nm: float, dt: float) -> Vector3:
	if authority <= 0.0 or minimum_degrees <= 0.0 or dt <= 0.0 \
			or basis.y.dot(Vector3.UP) < 0.25 or not inverse_inertia.is_finite() \
			or absf(inverse_inertia.determinant()) < 1.0e-12:
		return Vector3.ZERO
	var axis := (-basis.z).cross(Vector3.UP).normalized()
	if axis.length_squared() < 0.000001: return Vector3.ZERO
	var pitch := Pitch.world_pitch(basis)
	var pitch_rate := angular_velocity.dot(axis)
	var target := deg_to_rad(clampf(minimum_degrees, 0.0, 10.0))
	# Start braking a small downward rate before crossing the running trim.
	if pitch + minf(pitch_rate, 0.0) * 0.10 >= target: return Vector3.ZERO
	var rate := minf(clampf(response_rate, 1.0, 8.0), 0.2 / dt)
	var desired := rate * rate * (target - pitch) - 2.0 * rate * pitch_rate
	var existing := (inverse_inertia * known_torque).dot(axis)
	var correction := maxf(desired - existing, 0.0) * clampf(authority, 0.0, 1.0)
	var torque := inverse_inertia.inverse() * (axis * correction)
	return torque.limit_length(maxf(max_torque_nm, 0.0)) if torque.is_finite() else Vector3.ZERO
