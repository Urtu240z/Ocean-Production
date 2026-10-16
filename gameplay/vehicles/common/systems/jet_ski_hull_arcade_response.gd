extends RefCounted
## Selective assistance for normal HULL V1. No transforms or velocity resets.


static func plow_authority(basis: Basis, bow_depth: float, horizontal_speed: float,
		root_depth: float = 0.0) -> float:
	var forward := -basis.z.normalized()
	var nose_down := -atan2(forward.y, Vector2(forward.x, forward.z).length())
	var pitched_entry := smoothstep(deg_to_rad(6.0), deg_to_rad(22.0), nose_down) \
		* smoothstep(0.05, 0.30, bow_depth)
	# A wave covering the bow alone is not a buried craft: avoid cutting the
	# engine on a rising wave face while the body is still at the surface.
	var deep_entry := smoothstep(0.40, 0.75, bow_depth) * smoothstep(0.25, 0.55, root_depth)
	return maxf(pitched_entry, deep_entry) * smoothstep(1.5, 5.0, horizontal_speed)


static func plow_force_correction(water_force: Vector3, relative_velocity: Vector3,
		up: Vector3, mass_kg: float, braking_mps2: float, authority: float, dt: float) -> Vector3:
	var horizontal := relative_velocity.slide(up)
	var speed := horizontal.length()
	if speed < 0.001 or authority <= 0.0: return Vector3.ZERO
	# Brake along the incoming trajectory at the COM. Asymmetric bow immersion
	# must not convert drag into a sideways kick or an abrupt new heading.
	var deceleration := minf(maxf(braking_mps2, 0.0), speed * 0.6)
	deceleration = minf(deceleration, speed / maxf(dt, 0.000001))
	var desired_force := -horizontal / speed * mass_kg * deceleration
	return (desired_force - water_force.slide(up)) * clampf(authority, 0.0, 1.0)


static func plow_yaw_torque(water_torque: Vector3, angular_velocity: Vector3,
		inverse_inertia: Basis, up: Vector3, authority: float, steering: float,
		damping_rate: float, dt: float) -> Vector3:
	if authority <= 0.0 or not _valid_inertia(inverse_inertia): return Vector3.ZERO
	var pilot_release := 1.0 - smoothstep(0.05, 0.7, absf(steering))
	var decay := (1.0 - exp(-maxf(damping_rate, 0.0) * dt)) / maxf(dt, 0.000001)
	var unwanted_acceleration := (inverse_inertia * water_torque).dot(up)
	var correction := -unwanted_acceleration - angular_velocity.dot(up) * decay * pilot_release
	# Cancel world yaw acceleration, accounting for the complete tilted inertia
	# tensor. Pitch/roll and deliberate steering remain independent.
	return inverse_inertia.inverse() * (up * correction * clampf(authority, 0.0, 1.0))


static func rebound_force(relative_velocity: Vector3, up: Vector3, mass_kg: float,
		displaced_mass_kg: float, damping_rate: float, dt: float) -> Vector3:
	var ascending_speed := maxf(relative_velocity.dot(up), 0.0)
	var wet := smoothstep(0.0, 0.5, displaced_mass_kg / maxf(mass_kg, 0.001))
	var decay := (1.0 - exp(-maxf(damping_rate, 0.0) * dt)) / maxf(dt, 0.000001)
	# Only dissipate upward motion relative to the water while immersed. This
	# vanishes when dry and never adds suction or opposes a downward dive.
	return -up * mass_kg * ascending_speed * decay * wet


static func submarine_force(water_force: Vector3, relative_velocity: Vector3,
		up: Vector3, mass_kg: float, gravity: float, depth: float,
		target_depth: float, sink_speed: float, authority: float) -> Vector3:
	if authority <= 0.0: return Vector3.ZERO
	# This is an intentional arcade trick: translate the whole craft into the
	# water, rather than apply more pitch and lift its stern. Replace the net
	# vertical water response only during the dive. No position/velocity writes.
	var target_speed := -minf(maxf(sink_speed, 0.0), maxf(target_depth - depth, 0.0) * 4.0)
	var acceleration := clampf((target_speed - relative_velocity.dot(up)) * 5.0, -6.0, 6.0)
	return up * (mass_kg * (gravity + acceleration) - water_force.dot(up)) \
		* clampf(authority, 0.0, 1.0)


static func release_torque(basis: Basis, angular_velocity: Vector3, inverse_inertia: Basis,
		velocity: Vector3, rider_shift: Vector2, steering: float, authority: float,
		response_rate: float) -> Vector3:
	if authority <= 0.0 or basis.y.dot(Vector3.UP) < 0.15 \
			or not _valid_inertia(inverse_inertia): return Vector3.ZERO
	var forward := -basis.z.normalized()
	var right := basis.x.normalized()
	var horizontal := forward.slide(Vector3.UP)
	if horizontal.length_squared() < 0.000001: return Vector3.ZERO
	var pitch_axis := horizontal.normalized().cross(Vector3.UP)
	var pitch := atan2(forward.y, horizontal.length())
	var roll := atan2(right.y, basis.y.y)
	var trajectory := atan2(velocity.y, maxf(velocity.slide(Vector3.UP).length(), 0.1))
	var target_pitch := clampf(trajectory, deg_to_rad(-10.0), deg_to_rad(20.0))
	var pitch_free := 1.0 - smoothstep(0.02, 0.25, absf(rider_shift.y))
	var roll_free := 1.0 - smoothstep(0.02, 0.25, absf(rider_shift.x))
	var yaw_free := 1.0 - smoothstep(0.02, 0.25, absf(steering))
	var rate := clampf(response_rate, 0.0, 5.0)
	var acceleration := pitch_axis * ((target_pitch - pitch) * rate * rate \
		- 2.0 * rate * angular_velocity.dot(pitch_axis)) * pitch_free
	acceleration += forward * (roll * rate * rate \
		- 2.0 * rate * angular_velocity.dot(forward)) * roll_free
	var travel := velocity.slide(Vector3.UP)
	if travel.length_squared() > 4.0:
		var yaw_error := horizontal.signed_angle_to(travel.normalized(), Vector3.UP)
		acceleration += Vector3.UP * (clampf(yaw_error * rate, -0.8, 0.8) \
			- angular_velocity.y) * rate * yaw_free
	return (inverse_inertia.inverse() * (acceleration * authority)).limit_length(2500.0)


static func submarine_level_torque(basis: Basis, angular_velocity: Vector3,
		inverse_inertia: Basis, known_torque: Vector3, entry_pitch_degrees: float,
		horizontal_blend: float, response_rate: float) -> Vector3:
	if horizontal_blend <= 0.0 or not _valid_inertia(inverse_inertia): return Vector3.ZERO
	var forward := -basis.z.normalized()
	var flat_forward := forward.slide(Vector3.UP)
	if flat_forward.length_squared() < 0.000001: return Vector3.ZERO
	flat_forward = flat_forward.normalized()
	var pitch_axis := flat_forward.cross(Vector3.UP)
	var pitch := atan2(forward.y, forward.slide(Vector3.UP).length())
	var roll := atan2(basis.x.y, basis.y.y)
	var target_pitch := -deg_to_rad(entry_pitch_degrees) * (1.0 - horizontal_blend)
	var rate := clampf(response_rate, 1.0, 8.0)
	var desired_pitch := rate * rate * (target_pitch - pitch) - 2.0 * rate * angular_velocity.dot(pitch_axis)
	var desired_roll := rate * rate * roll - 2.0 * rate * angular_velocity.dot(flat_forward)
	var existing := inverse_inertia * known_torque
	var correction := pitch_axis * (desired_pitch - existing.dot(pitch_axis)) \
		+ flat_forward * (desired_roll - existing.dot(flat_forward))
	# Only pitch/roll acceleration: steering yaw is untouched. Count the
	# actual water/rider torques instead of fighting an unaccounted weight bias.
	return (inverse_inertia.inverse() * (correction * horizontal_blend)).limit_length(9000.0)


static func air_yaw_torque(angular_velocity: Vector3, inverse_inertia: Basis,
		steering: float, target_rate: float, max_torque_nm: float) -> Vector3:
	if absf(steering) < 0.02 or not _valid_inertia(inverse_inertia): return Vector3.ZERO
	var acceleration := (-steering * maxf(target_rate, 0.0) - angular_velocity.y) * 4.0
	return (inverse_inertia.inverse() * (Vector3.UP * acceleration)).limit_length(max_torque_nm)


static func _valid_inertia(inverse_inertia: Basis) -> bool:
	return inverse_inertia.is_finite() and absf(inverse_inertia.determinant()) > 1.0e-12
