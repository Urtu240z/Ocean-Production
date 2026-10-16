extends RefCounted
## Gameplay approximation of local wave transport, not a full fluid velocity.
## For h=A*sin(k.dot(x)-omega*t), -h_t*grad(h) follows the travelling wave
## on both flanks. The normal supplies a bounded slope direction; h_t comes
## from the existing CPU wave sample. No wind heading or world direction.


static func velocity(normal: Vector3, vertical_wave_speed: float,
		strength: float, max_speed_mps: float) -> Vector3:
	if not normal.is_finite() or not is_finite(vertical_wave_speed) \
			or normal.length_squared() < 0.000001 or strength <= 0.0 or max_speed_mps <= 0.0:
		return Vector3.ZERO
	var up_normal := normal.normalized()
	if up_normal.y < 0.0: up_normal = -up_normal
	var flow := Vector3(up_normal.x, 0.0, up_normal.z) * vertical_wave_speed * strength
	# Added flow stays tangent to the water: no new normal velocity/damping.
	return flow.limit_length(max_speed_mps).slide(up_normal)
