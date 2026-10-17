extends SceneTree
## Real Jolt integration with the production hull and water-force solver.
## A stationary analytic wave makes submerged crest crossings repeatable.

const Vehicle = preload("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn")

class TestWater extends WaterSurfaceProvider3D:
	var amplitude := 0.0
	var wavelength := 20.0
	var water_velocity := Vector3.ZERO
	var cross_slope := 0.0

	func sample_water(position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
		var sample := out_sample.reset() if out_sample != null else WaterSample3D.new()
		var k := TAU / wavelength
		var travel := -position.z
		var height := amplitude * cos(k * travel) + cross_slope * position.x
		var slope := -amplitude * k * sin(k * travel)
		sample.valid = true
		sample.surface_position = Vector3(position.x, height, position.z)
		sample.normal = Vector3(-cross_slope, 1.0, slope).normalized()
		sample.velocity = water_velocity
		sample.signed_depth = height - position.y
		return sample

class TestBody extends RigidBody3D:
	var water: TestWater
	var solver: JetSkiWaterPhysicsSystem
	var first_force := Vector3.ZERO
	var first_volume := 0.0
	var first_damping := 0.0
	var first_hydro := 0.0
	var minimum_contact_force := INF
	var peak_rebound_speed := 0.0
	var recovery_seen := false
	var ticks := 0
	var max_dry_time := 0.0
	var dry_time := 0.0
	var release_speed := 0.0
	var wet_at_crest := false
	var buoyancy_factor := 1.0

	func _integrate_forces(body_state: PhysicsDirectBodyState3D) -> void:
		solver.step(body_state, water, buoyancy_factor)
		if ticks == 0:
			first_force = solver.total_buoyancy_force_vector
			first_volume = solver.hull_buoyancy.submerged_volume_m3
			for damping in solver.point_damping_forces: first_damping += damping
			for hydro in solver.point_spring_forces: first_hydro += hydro
			for index in 4:
				minimum_contact_force = minf(minimum_contact_force,
					solver.point_buoyancy_force_vectors[index].dot(solver.point_water_normals[index]))
		ticks += 1
		peak_rebound_speed = maxf(peak_rebound_speed, body_state.linear_velocity.y)
		recovery_seen = recovery_seen or not solver.hull_rebound_force.is_zero_approx()
		if absf(body_state.transform.origin.z) < 1.0 and solver.state.raw_contact_mask != 0:
			wet_at_crest = true
		if solver.hull_buoyancy.submerged_volume_m3 <= 0.000000001:
			if dry_time == 0.0: release_speed = body_state.linear_velocity.y
			dry_time += body_state.step
			max_dry_time = maxf(max_dry_time, dry_time)
		else:
			dry_time = 0.0

var failures: Array[String] = []
var hull_shape: CollisionShape3D
var markers: Node3D

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("CREST_RELEASE: " + message)

func make_body(water: TestWater, pose: Transform3D, velocity: Vector3) -> TestBody:
	var body := TestBody.new()
	body.mass = 300.0
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = Vector3(0.0, -0.22, 0.0)
	body.lock_rotation = true # Isolate heave from rider/steering torques.
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	body.collision_layer = 0
	body.collision_mask = 0
	body.transform = pose
	body.linear_velocity = velocity
	body.water = water
	body.add_child(hull_shape.duplicate())
	body.solver = JetSkiWaterPhysicsSystem.new()
	body.add_child(body.solver)
	body.solver.configure(markers)
	body.solver.configure_hull_buoyancy(body.get_child(0) as CollisionShape3D)
	body.solver.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	body.solver.hull_arcade_enabled = true
	root.add_child(body)
	return body

func _run() -> void:
	var template := Vehicle.instantiate()
	hull_shape = template.get_node("CollisionShape3D")
	markers = template.get_node("BuoyancyPoints")
	var water := TestWater.new()
	root.add_child(water)
	for depth in [0.05, 0.15, 0.30]:
		var body := make_body(water, Transform3D(Basis.IDENTITY, Vector3(0, 0.30 - depth, 0)),
			Vector3(0, 5, -16))
		while body.ticks < 1: await physics_frame
		print("CREST_FORCE depth=%.2f wet=%.4f force_y=%.2f damping_y=%.2f" % [
			depth, body.first_volume, body.first_force.y, body.first_damping])
		check(body.first_volume > 0.0, "outgoing force case is genuinely submerged")
		check(body.first_force.y >= -0.01, "submerged outgoing hull cannot pull into the water depth=%.2f" % depth)
		check(body.first_force.y <= body.first_hydro + 0.01,
			"release only removes damping; it adds no launch force")
		check(absf(body.first_hydro - 1000.0 * 9.8 * body.first_volume) < 0.1,
			"hydrostatic displacement remains rho*g*V")
		body.queue_free()
		await physics_frame
	# The release condition uses the complete relative normal velocity, including
	# downward-moving water and oblique wave normals, rather than world ascent.
	water.water_velocity = Vector3(0, -3, 0)
	water.cross_slope = 0.35
	var separating := make_body(water, Transform3D(Basis.IDENTITY, Vector3(0, 0.15, 0)),
		Vector3(0, -1, -16))
	while separating.ticks < 1: await physics_frame
	check(separating.minimum_contact_force >= -0.01,
		"falling and tilted water cannot retain a hull separating along its normal")
	separating.queue_free()
	await physics_frame
	water.water_velocity = Vector3.ZERO
	water.cross_slope = 0.0
	for mode in ["entry", "heavy", "submarine"]:
		var body := make_body(water, Transform3D(Basis.IDENTITY, Vector3(0, 0.15, 0)),
			Vector3(0, -5 if mode == "entry" else 5, -16))
		body.solver.heavy_hull_enabled = mode == "heavy"
		if mode == "submarine":
			body.buoyancy_factor = 0.4
			body.solver.hull_submarine_authority = 1.0
		while body.ticks < 1: await physics_frame
		if mode == "entry":
			check(body.first_damping > 0.0 and body.first_force.y > body.first_hydro,
				"incoming hull keeps its full positive entry resistance")
		else:
			check(body.first_damping < -body.first_hydro,
				mode + " retains its original immersed damping law")
		print("CREST_CONTROL mode=%s hydro=%.2f damping=%.2f" % [mode, body.first_hydro, body.first_damping])
		body.queue_free()
		await physics_frame
	var resting := make_body(water, Transform3D(Basis.IDENTITY, Vector3(0, 0.15, 0)), Vector3.ZERO)
	for tick in 240: await physics_frame
	check(absf(resting.linear_velocity.y) < 0.05 and resting.max_dry_time == 0.0,
		"flat-water equilibrium remains stable without spontaneous hops")
	print("CREST_REST vy=%.4f y=%.4f" % [resting.linear_velocity.y, resting.position.y])
	resting.queue_free()
	await physics_frame
	var landing := make_body(water, Transform3D(Basis.IDENTITY, Vector3(0, 5, 0)), Vector3.ZERO)
	for tick in 480: await physics_frame
	check(landing.peak_rebound_speed < 8.0 and absf(landing.linear_velocity.y) < 0.15,
		"deep landing settles without an explosive rebound")
	print("CREST_LANDING recovery=%s peak_vy=%.3f final_vy=%.4f" % [
		landing.recovery_seen, landing.peak_rebound_speed, landing.linear_velocity.y])
	landing.queue_free()
	await physics_frame
	var recovering := make_body(water, Transform3D(Basis.IDENTITY, Vector3(0, -0.8, 0)), Vector3(0, 3, 0))
	for tick in 360: await physics_frame
	check(recovering.recovery_seen, "fully submerged ascent still activates dedicated recovery damping")
	check(recovering.peak_rebound_speed < 8.0 and absf(recovering.linear_velocity.y) < 0.15,
		"deep recovery returns to stable flotation")
	print("CREST_RECOVERY active=%s peak_vy=%.3f final_vy=%.4f" % [
		recovering.recovery_seen, recovering.peak_rebound_speed, recovering.linear_velocity.y])
	recovering.queue_free()
	await physics_frame
	water.amplitude = 1.0
	water.wavelength = 16.0
	for depth in [0.10, 0.25, 0.40]:
		var start_travel := -0.75
		var k := TAU / water.wavelength
		var height := water.amplitude * cos(k * start_travel)
		var slope := -water.amplitude * k * sin(k * start_travel)
		var pitch := atan(slope)
		var body := make_body(water,
			Transform3D(Basis(Vector3.RIGHT, pitch), Vector3(0, height + 0.30 - depth, -start_travel)),
			Vector3(0, slope * 16.0, -16.0))
		for tick in 100: await physics_frame
		print("CREST_FLIGHT depth=%.2f wet_crest=%s air_s=%.3f release_vy=%.3f" % [
			depth, body.wet_at_crest, body.max_dry_time, body.release_speed])
		check(body.wet_at_crest, "crosses crest while still partially submerged depth=%.2f" % depth)
		check(body.max_dry_time >= 0.20 and body.release_speed > 1.0,
			"submerged crest crossing produces a real jump depth=%.2f" % depth)
		body.queue_free()
		await physics_frame
	water.queue_free()
	template.free()
	print("CREST_RELEASE: %s errors=%d" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(0 if failures.is_empty() else 1)
