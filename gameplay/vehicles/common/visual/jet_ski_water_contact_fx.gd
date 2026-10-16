extends Node3D
## Low-cost contact spray, landing splash, and trailing wake driven by the
## water physics system's already sampled buoyancy contacts.

const WATER_COLOR := Color(0.72, 0.91, 1.0, 0.62)

var _vehicle: JetSkiController
var _physics: JetSkiWaterPhysicsSystem
var _ocean: Ocean
var _contact_spray: GPUParticles3D
var _landing_splash: GPUParticles3D
var _wake: GPUParticles3D
var _foam_ring: MeshInstance3D
var _foam_material: StandardMaterial3D
var _last_landing_event_serial := 0
var _wake_stamp_accumulator := 0.0
var _last_wake_stamp_position := Vector3.ZERO
var _has_last_wake_stamp := false


func configure_ocean(ocean: Ocean) -> void:
	_ocean = ocean


func _ready() -> void:
	_vehicle = get_parent() as JetSkiController
	if _vehicle == null:
		set_process(false)
		return
	_physics = _vehicle.water_physics_system
	_last_landing_event_serial = _physics.contact_landing_event_serial
	_contact_spray = _make_particles("HullContactSpray", 36, 0.75, false,
		Vector3(0.0, 1.0, 0.0), 42.0, 1.0, 2.3, Vector3(0.75, -2.4, 0.0),
		Vector3(0.85, 0.10, 1.45), WATER_COLOR, Vector2(0.06, 0.12))
	add_child(_contact_spray)
	_wake = _make_particles("TrailingWake", 60, 1.35, false,
		Vector3(0.0, 0.0, 1.0), 18.0, 0.6, 1.8, Vector3(0.0, -0.15, 0.0),
		Vector3(0.42, 0.035, 0.10), Color(0.78, 0.94, 1.0, 0.42), Vector2(0.035, 0.075))
	add_child(_wake)
	_landing_splash = _make_particles("LandingSplash", 72, 0.82, true,
		Vector3(0.0, 1.0, 0.0), 68.0, 2.4, 5.6, Vector3(0.0, -0.2, 0.0),
		Vector3(0.72, 0.08, 1.35), Color(0.82, 0.96, 1.0, 0.75), Vector2(0.07, 0.16))
	add_child(_landing_splash)
	_landing_splash.emitting = false
	_create_foam_ring()


func _process(delta: float) -> void:
	if not is_instance_valid(_vehicle) or _physics == null:
		return
	var wet_count: int = _physics.wet_contact_count
	var supported_count: int = _physics.supported_contact_count
	var supported := _physics.contact_is_supported and not _physics.contact_is_airborne
	var wet := _physics.contact_is_wet and not _physics.contact_is_airborne
	var relative_velocity := _water_relative_velocity()
	var speed := Vector2(relative_velocity.x, relative_velocity.z).length()
	var surface_position := _contact_surface_position()
	_set_emitter_transform(_contact_spray, surface_position)
	_set_emitter_transform(_wake, surface_position + _vehicle.global_transform.basis.z * 1.45)
	_contact_spray.emitting = wet
	_contact_spray.amount_ratio = clampf(
		0.12 + float(wet_count) * 0.11 + speed * 0.012, 0.0, 0.78
	) if wet else 0.0
	_wake.emitting = supported and speed >= 3.5
	_wake.amount_ratio = clampf((speed - 2.5) / 18.0, 0.0, 0.9) * clampf(float(supported_count) / 3.0, 0.0, 1.0)
	_foam_ring.global_position = surface_position
	_foam_ring.visible = wet
	var foam_alpha := clampf(0.10 + float(wet_count) * 0.045, 0.10, 0.28) if wet else 0.0
	_foam_material.albedo_color = Color(0.72, 0.94, 1.0, foam_alpha)
	_update_persistent_foam(delta, supported, surface_position, relative_velocity, speed)
	if _physics.contact_landing_event_serial != _last_landing_event_serial:
		_last_landing_event_serial = _physics.contact_landing_event_serial
		_emit_landing_splash(surface_position, _physics.contact_landing_downward_speed_mps)
		if is_instance_valid(_ocean) and _ocean.is_landing_ripple_enabled():
			_ocean.submit_foam_stamp(surface_position, relative_velocity, clampf(_physics.contact_landing_downward_speed_mps / 5.0, 0.35, 1.6), true)


func _water_relative_velocity() -> Vector3:
	var velocities := _physics.get_point_relative_velocities()
	var total := Vector3.ZERO
	var samples := 0
	for index in mini(velocities.size(), _physics.point_sample_valid.size()):
		if not _physics.point_sample_valid[index]: continue
		total += velocities[index]
		samples += 1
	if samples > 0: return total / float(samples)
	return _vehicle.linear_velocity


func _update_persistent_foam(delta: float, supported: bool, surface_position: Vector3, velocity: Vector3, speed: float) -> void:
	if not supported or not is_instance_valid(_ocean) \
			or not _ocean.is_persistent_foam_enabled() or speed < 0.6:
		_wake_stamp_accumulator = 0.0
		_has_last_wake_stamp = false
		return
	_wake_stamp_accumulator += delta
	if _wake_stamp_accumulator < 0.045: return
	_wake_stamp_accumulator = fmod(_wake_stamp_accumulator, 0.045)
	var current := surface_position - Vector3(velocity.x, 0.0, velocity.z).normalized() * 1.25
	if not _has_last_wake_stamp:
		_last_wake_stamp_position = current
		_has_last_wake_stamp = true
	var distance_m := Vector2(current.x - _last_wake_stamp_position.x, current.z - _last_wake_stamp_position.z).length()
	var stamp_count := clampi(ceili(distance_m / 1.1), 1, 20)
	var strength := clampf(0.18 + speed / 15.0, 0.0, 1.0)
	for index in range(1, stamp_count + 1):
		var t := float(index) / float(stamp_count)
		_ocean.submit_foam_stamp(_last_wake_stamp_position.lerp(current, t), velocity, strength, false)
	_last_wake_stamp_position = current


func _contact_surface_position() -> Vector3:
	var emitter_position := _vehicle.global_position
	var surface_height_sum := 0.0
	var samples := 0
	for index in JetSkiWaterPhysicsSystem.BUOYANCY_POINT_COUNT:
		if _physics.point_sample_valid[index] and _physics.point_depths[index] > 0.0:
			surface_height_sum += _physics.point_water_surface_positions[index].y
			samples += 1
	if samples > 0:
		emitter_position.y = surface_height_sum / float(samples) + 0.015
	else:
		emitter_position.y -= 0.24
	return emitter_position


func _set_emitter_transform(emitter: GPUParticles3D, world_position: Vector3) -> void:
	var vehicle_basis := _vehicle.global_transform.basis
	emitter.global_transform = Transform3D(vehicle_basis, world_position)


func _emit_landing_splash(world_position: Vector3, downward_speed: float) -> void:
	_set_emitter_transform(_landing_splash, world_position)
	var process_material := _landing_splash.process_material as ParticleProcessMaterial
	var intensity := clampf(downward_speed, 1.0, 8.0)
	process_material.initial_velocity_min = 1.5 + intensity * 0.25
	process_material.initial_velocity_max = 3.0 + intensity * 0.45
	_landing_splash.emitting = true
	_landing_splash.restart()


func _create_foam_ring() -> void:
	_foam_ring = MeshInstance3D.new()
	_foam_ring.name = "HullContactFoam"
	var torus := TorusMesh.new()
	torus.inner_radius = 0.72
	torus.outer_radius = 0.78
	_foam_ring.mesh = torus
	_foam_ring.scale = Vector3(1.0, 1.0, 1.7)
	_foam_material = StandardMaterial3D.new()
	_foam_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_foam_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_foam_material.albedo_color = Color(0.72, 0.94, 1.0, 0.18)
	_foam_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_foam_ring.material_override = _foam_material
	_foam_ring.visible = false
	add_child(_foam_ring)


func _make_particles(
	particle_name: String,
	particle_amount: int,
	particle_lifetime: float,
	one_shot: bool,
	direction: Vector3,
	spread_degrees: float,
	minimum_speed: float,
	maximum_speed: float,
	gravity: Vector3,
	emission_extents: Vector3,
	color: Color,
	quad_size: Vector2
) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = particle_name
	particles.amount = particle_amount
	particles.lifetime = particle_lifetime
	particles.one_shot = one_shot
	particles.explosiveness = 1.0 if one_shot else 0.0
	particles.local_coords = false
	particles.emitting = not one_shot
	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process_material.emission_box_extents = emission_extents
	process_material.direction = direction
	process_material.spread = spread_degrees
	process_material.initial_velocity_min = minimum_speed
	process_material.initial_velocity_max = maximum_speed
	process_material.gravity = gravity
	process_material.scale_min = 0.8
	process_material.scale_max = 1.25
	process_material.color = color
	particles.process_material = process_material
	var quad := QuadMesh.new()
	quad.size = quad_size
	var particle_material := StandardMaterial3D.new()
	particle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	particle_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	particle_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	particle_material.albedo_color = color
	quad.material = particle_material
	particles.draw_pass_1 = quad
	return particles
