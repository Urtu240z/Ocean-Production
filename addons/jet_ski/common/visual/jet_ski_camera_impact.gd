extends RefCounted
## Reads completed physics ticks; all response state belongs to the camera.
## An inertial kick follows the motion stopped by the collision (-delta-v).
var enabled := true
var position_amplitude_m := 0.20
var rotation_amplitude_degrees := 2.5
var acceleration_threshold_mps2 := 22.0
var recovery_seconds := 0.45
var position_offset_world := Vector3.ZERO
var rotation_offset_radians := Vector3.ZERO
var event_count := 0
var last_direction_world := Vector3.ZERO
var last_source: StringName = &""
var previous_velocity := Vector3.ZERO

var _initialized := false
var _background_acceleration := Vector3.ZERO
var _spring_position := Vector3.ZERO
var _spring_velocity := Vector3.ZERO
var _cooldown := 0.0


func reset() -> void:
	_initialized = false
	_background_acceleration = Vector3.ZERO
	_spring_position = Vector3.ZERO
	_spring_velocity = Vector3.ZERO
	_cooldown = 0.0
	position_offset_world = Vector3.ZERO
	rotation_offset_radians = Vector3.ZERO
	last_direction_world = Vector3.ZERO
	last_source = &""


func sample_physics(delta: float, velocity: Vector3, gravity: Vector3,
		has_contact: bool, solid_impulse: Vector3, mass_kg: float) -> void:
	if not enabled or delta <= 0.0 or not velocity.is_finite():
		reset()
		return
	_cooldown = maxf(_cooldown - delta, 0.0)
	if not _initialized:
		previous_velocity = velocity
		_initialized = true
		return
	var acceleration := (velocity - previous_velocity) / delta - gravity
	var abrupt_acceleration := acceleration - _background_acceleration
	# Learn ordinary thrust, gravity support and sustained drag slowly enough
	# to leave a short collision impulse visible. Free fall itself is not a hit.
	_background_acceleration = _background_acceleration.lerp(acceleration, 1.0 - exp(-delta * 5.0))
	var moving := maxf(velocity.length(), previous_velocity.length()) > 1.5
	previous_velocity = velocity
	if not has_contact: return
	var direction := -abrupt_acceleration
	var strength := 0.0
	var source: StringName = &"water_force"
	var threshold := maxf(acceleration_threshold_mps2, 1.0)
	if moving:
		strength = clampf((abrupt_acceleration.length() - threshold) / maxf(80.0 - threshold, 1.0), 0.0, 1.0)
	# Contact impulses also catch a wall/ramp hit between velocity samples.
	var solid_delta_v := solid_impulse.length() / maxf(mass_kg, 1.0)
	var solid_strength := clampf((solid_delta_v - 1.5) / 4.5, 0.0, 1.0)
	if solid_strength > strength:
		strength = solid_strength
		direction = -solid_impulse
		source = &"solid"
	elif solid_delta_v > 0.3:
		source = &"solid"
	kick(direction, strength, source)


func kick(direction_world: Vector3, strength: float, source: StringName) -> void:
	if not enabled or _cooldown > 0.0 or strength <= 0.0 \
			or not direction_world.is_finite() or direction_world.length_squared() < 0.000001:
		return
	var omega := 6.0 / maxf(recovery_seconds, 0.1)
	last_direction_world = direction_world.normalized()
	_spring_velocity += last_direction_world * clampf(strength, 0.0, 1.0) * omega * 2.0
	_spring_velocity = _spring_velocity.limit_length(omega * 2.5)
	_cooldown = 0.18
	last_source = source
	event_count += 1


func update(delta: float, camera_basis: Basis) -> void:
	if not enabled:
		reset()
		return
	# Exact damped spring integration stays stable through a slow render frame.
	var omega := 6.0 / maxf(recovery_seconds, 0.1)
	var damping := omega * 0.6
	var frequency := omega * 0.8
	var dt := maxf(delta, 0.0)
	var decay := exp(-damping * dt)
	var c := cos(frequency * dt)
	var s := sin(frequency * dt)
	var old_position := _spring_position
	var old_velocity := _spring_velocity
	_spring_position = ((old_position * c + (old_velocity + old_position * damping) / frequency * s) * decay).limit_length(1.0)
	_spring_velocity = (old_velocity * c - (old_velocity * damping + old_position * omega * omega) / frequency * s) * decay
	position_offset_world = _spring_position * position_amplitude_m
	var local := camera_basis.transposed() * _spring_position
	# Pitch/yaw shake the whole image, including sky; fore/aft hits add a nod.
	rotation_offset_radians = Vector3(local.y - local.z * 0.35, -local.x, -local.x * 0.25) \
		* deg_to_rad(rotation_amplitude_degrees)
