extends RefCounted
## Unilateral supported pitch barrier. No transforms, velocity writes or linear forces.


static func world_pitch(basis: Basis) -> float:
	var forward := -basis.z.normalized()
	return atan2(forward.y, Vector2(forward.x, forward.z).length())


static func response(basis: Basis, angular_velocity: Vector3, inverse_inertia: Basis,
		known_torque: Vector3, authority: float, max_degrees: float, soft_zone_degrees: float,
		response_rate: float, delta: float) -> Dictionary:
	var pitch := world_pitch(basis)
	var result := {"pitch_degrees": rad_to_deg(pitch), "torque": Vector3.ZERO,
		"active": false, "blend": 0.0, "correction_acceleration": 0.0}
	if authority <= 0.0 or pitch <= 0.0 or delta <= 0.0 or not is_finite(pitch) \
			or not inverse_inertia.is_finite() or absf(inverse_inertia.determinant()) < 1.0e-12:
		return result
	var forward := -basis.z.normalized()
	var axis := forward.cross(Vector3.UP)
	if axis.length_squared() < 1.0e-8:
		axis = Vector3(basis.x.x, 0.0, basis.x.z)
	if axis.length_squared() < 1.0e-8: return result
	axis = axis.normalized()
	var rate := minf(clampf(response_rate, 2.0, 16.0), 0.2 / delta)
	var limit := deg_to_rad(clampf(max_degrees, 10.0, 45.0))
	var zone := deg_to_rad(clampf(soft_zone_degrees, 1.0, minf(15.0, max_degrees - 1.0)))
	var start := limit - zone
	var pitch_rate := angular_velocity.dot(axis)
	var upward_rate := maxf(pitch_rate, 0.0)
	var existing_acceleration := axis.dot(inverse_inertia * known_torque)
	# Look ahead only for stopping distance; there is no delayed attitude target.
	var lookahead := minf(0.12, 1.0 / rate)
	var predicted := pitch + upward_rate * lookahead \
		+ 0.5 * maxf(existing_acceleration, 0.0) * lookahead * lookahead
	var blend := smoothstep(start, limit, maxf(pitch, predicted)) * clampf(authority, 0.0, 1.0)
	if blend <= 0.0: return result
	var target_acceleration := -rate * rate * maxf(pitch - start, 0.0) - 2.0 * rate * upward_rate
	var correction := minf((target_acceleration - existing_acceleration) * blend, 0.0)
	# Semi-implicit one-step guard for an intense powered acceleration near the
	# ceiling. It is still a finite applied torque, never an angular-velocity clamp.
	var margin := maxf(limit - deg_to_rad(0.5) - pitch, 0.0)
	if pitch_rate + (existing_acceleration + correction) * delta > margin / delta:
		var safety_correction := (margin / delta - pitch_rate) / delta - existing_acceleration
		correction = minf(correction, safety_correction * clampf(authority, 0.0, 1.0))
	if correction >= 0.0 or not is_finite(correction): return result
	# Convert a pitch-only angular acceleration through the actual world tensor.
	# This avoids introducing roll/yaw acceleration when the craft is banked.
	var torque := inverse_inertia.inverse() * (axis * correction)
	if not torque.is_finite(): return result
	result.torque = torque
	result.active = true
	result.blend = blend
	result.correction_acceleration = correction
	return result
