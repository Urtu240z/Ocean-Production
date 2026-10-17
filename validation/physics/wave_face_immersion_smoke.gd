extends "res://validation/physics/submerged_crest_release_smoke.gd"
## Compare the actual production solver over repeatable ascending wave faces.

func _run() -> void:
	var template := Vehicle.instantiate()
	hull_shape = template.get_node("CollisionShape3D")
	markers = template.get_node("BuoyancyPoints")
	var water := TestWater.new()
	water.amplitude = 2.0
	water.wavelength = 20.0
	root.add_child(water)
	var reference: Dictionary = {}
	for setup in [Vector3(8, 0, 0), Vector3(8, 0, 1), Vector3(12, 0, 0), Vector3(12, 0, 1),
		Vector3(18, 0, 0), Vector3(18, 0, 1), Vector3(8, 1, 0), Vector3(8, 1, 1),
		Vector3(12, 1, 0), Vector3(12, 1, 1), Vector3(18, 1, 0), Vector3(18, 1, 1)]:
		var speed: float = setup.x
		var start := water.wavelength * 0.25
		var body := make_body(water, Transform3D(Basis(Vector3.RIGHT, deg_to_rad(4.0)),
			Vector3(0, 0.2143, start)), Vector3(0, 0, -speed))
		body.lock_rotation = setup.y == 0.0
		body.solver.wave_face_support_enabled = setup.z == 1.0
		var peak_root_depth := -INF
		var peak_hull_depth := 0.0
		var peak_rise := 0.0
		for tick in 100:
			await physics_frame
			if body.position.z >= 0.0:
				var sample := water.sample_water(body.position)
				peak_root_depth = maxf(peak_root_depth, sample.signed_depth)
				peak_hull_depth = maxf(peak_hull_depth, body.solver.state.maximum_depth)
				peak_rise = maxf(peak_rise, body.linear_velocity.y)
		var key := "%s/%s" % [speed, setup.y]
		if setup.z == 0.0:
			reference[key] = {"depth": peak_root_depth, "hull": peak_hull_depth, "rise": peak_rise}
		else:
			check(peak_root_depth < float(reference[key].depth) - 0.02,
				"earlier wave support reduces hull immersion at speed=%.0f free_pitch=%s" % [speed, not body.lock_rotation])
			check(peak_rise < float(reference[key].rise) * 1.15 + 0.25, "no excessive upward launch")
		print("WAVE_FACE speed=%.0f free_pitch=%s support=%s root_depth=%.4f hull_depth=%.4f peak_vy=%.4f dry_s=%.3f" % [
			speed, not body.lock_rotation, body.solver.wave_face_support_enabled,
			peak_root_depth, peak_hull_depth, peak_rise, body.max_dry_time])
		check(body.position.is_finite() and body.linear_velocity.is_finite(), "finite wave crossing")
		body.queue_free()
		await physics_frame
	await _controller_cases(water)
	await _bypass_cases(water)
	water.queue_free()
	template.free()
	print("WAVE_FACE: %s errors=%d" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	quit(0 if failures.is_empty() else 1)

func _controller_cases(water: TestWater) -> void:
	var reference: Dictionary = {}
	for setup in [Vector2(12, 0), Vector2(12, 1), Vector2(18, 0), Vector2(18, 1)]:
		var ski: JetSkiController = Vehicle.instantiate()
		ski.configure_water_provider(water)
		ski.collision_layer = 0
		ski.collision_mask = 0
		ski.transform = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(4.0)), Vector3(0, 0.2143, 5))
		ski.linear_velocity = Vector3(0, 0, -setup.x)
		root.add_child(ski)
		ski.water_physics_system.wave_face_support_enabled = setup.y == 1.0
		Input.action_press("throttle", 1.0)
		var peak_depth := -INF
		var peak_rise := 0.0
		var peak_support := 0.0
		for tick in 100:
			await physics_frame
			if ski.position.z >= 0:
				peak_depth = maxf(peak_depth, water.sample_water(ski.position).signed_depth)
				peak_rise = maxf(peak_rise, ski.linear_velocity.y)
				peak_support = maxf(peak_support, ski.water_physics_system.wave_face_support_force.length())
		Input.action_release("throttle")
		if setup.y == 0.0:
			reference[setup.x] = {"depth": peak_depth, "rise": peak_rise}
		else:
			check(peak_depth < float(reference[setup.x].depth) - 0.02,
				"full controller/rider/engine also reduces climbing immersion")
			check(peak_rise < float(reference[setup.x].rise) * 1.15 + 0.25, "full controller has no excessive launch")
			check(peak_support > 0, "full controller engages dynamic wave support")
		print("WAVE_CONTROLLER speed=%.0f support=%s depth=%.4f peak_vy=%.4f force=%.1f" % [
			setup.x, setup.y == 1.0, peak_depth, peak_rise, peak_support])
		ski.queue_free()
		await physics_frame

func _bypass_cases(water: TestWater) -> void:
	for mode in ["dry", "flat", "downhill", "outgoing", "stationary", "heavy", "submarine", "rider_forward", "legacy"]:
		water.amplitude = 0.0 if mode == "flat" else 2.0
		var z := -2.5 if mode == "downhill" else 2.5
		var height := water.sample_water(Vector3(0, 0, z)).surface_position.y
		var body := make_body(water, Transform3D(Basis.IDENTITY,
			Vector3(0, height + (3.0 if mode == "dry" else 0.15), z)),
			Vector3(0, 10 if mode == "outgoing" else 0, 0 if mode == "stationary" else -12))
		body.solver.heavy_hull_enabled = mode == "heavy"
		if mode == "submarine":
			body.buoyancy_factor = 0.4
			body.solver.hull_submarine_authority = 1.0
		if mode == "rider_forward": body.solver.takeoff_rider_shift.y = -0.5
		if mode == "legacy": body.solver.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.LEGACY_4POINT)
		while body.ticks < 1: await physics_frame
		check(body.solver.wave_face_support_force.is_zero_approx(), mode + " receives no dynamic wave support")
		body.queue_free()
		await physics_frame
