extends SceneTree
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
const Response = preload("res://addons/jet_ski/common/systems/jet_ski_heavy_hull_response.gd")
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("UPRIGHT_SMOKE: " + message)

func _run() -> void:
	var force := Vector3(400.0, 3000.0, -200.0)
	var soft := Response.soften_normal_lateral(force, Vector3.UP, 0.1)
	_check(is_equal_approx(soft.y, force.y), "normal softening preserves vertical force")
	var basis := Basis(Vector3.FORWARD, 0.4)
	var raw := basis * Vector3(100.0, 900.0, 300.0)
	var response := Response.upright_response(basis, Vector3.ZERO, Vector3(520, 173, 157),
		Vector3.UP, 1.0, raw, 0.12, 2.4, Vector2.ZERO, 1.0 / 60.0)
	var resulting: Vector3 = basis.transposed() * (raw + response.wave_correction)
	_check(absf(resulting.y - 900.0) < 0.001, "wave yaw moment is preserved")
	_check(absf(resulting.x - 12.0) < 0.001 and absf(resulting.z - 36.0) < 0.001,
		"wave pitch and roll moments are softened to twelve percent")
	_check(absf((basis.transposed() * response.upright_torque).y) < 0.001, "upright assist does not command yaw")
	var dry := Response.upright_response(basis, Vector3.ONE, Vector3(520, 173, 157),
		Vector3.UP, 0.0, raw, 0.12, 2.4, Vector2.ZERO, 1.0 / 60.0)
	_check(dry.wave_correction.is_zero_approx() and dry.upright_torque.is_zero_approx(), "assist vanishes without wet support")
	var scene := Gameplay.instantiate()
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")):
			break
	_check(bool(scene.get("ready_to_drive")), "gameplay loads")
	var ski: JetSkiController = scene.get("ski")
	var physics := ski.water_physics_system
	physics.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	var pitch_max := 0.0
	var roll_max := 0.0
	var y_min := INF
	var y_max := -INF
	var maximum_thrust := 0.0
	for tick in 360:
		if tick == 120:
			Input.action_press("throttle", 0.4)
		await physics_frame
		var body_basis := ski.global_basis.orthonormalized()
		pitch_max = maxf(pitch_max, absf(asin(clampf((-body_basis.z).y, -1.0, 1.0))))
		roll_max = maxf(roll_max, absf(atan2(body_basis.x.y, body_basis.y.y)))
		y_min = minf(y_min, ski.position.y)
		y_max = maxf(y_max, ski.position.y)
		maximum_thrust = maxf(maximum_thrust, ski.drive_system.state.propulsion_force)
		_check(physics.heavy_upright_torque.is_finite(), "upright torque remains finite")
	_check(rad_to_deg(pitch_max) < 45.0 and rad_to_deg(roll_max) < 45.0, "short wave run stays upright")
	_check(y_max - y_min > 0.1, "vertical wave motion remains active")
	_check(maximum_thrust > 0.0, "throttle remains functional on waves")
	Input.action_release("throttle")
	print("UPRIGHT_WAVES: pitch_max=%.2f deg roll_max=%.2f deg vertical_span=%.3f m max_thrust=%.1f N" % [
		rad_to_deg(pitch_max), rad_to_deg(roll_max), y_max - y_min, maximum_thrust])
	ski.heavy_upright_enabled = false
	for tick in 3:
		await physics_frame
	_check(physics.heavy_upright_torque.is_zero_approx() and physics.heavy_wave_torque_correction.is_zero_approx(),
		"disabling assist restores prior heavy angular behavior")
	ski.heavy_upright_enabled = true
	ski.set_respawn_transform(Transform3D(Basis.IDENTITY, Vector3(0.0, 12.0, 0.0)))
	ski.reset_vehicle()
	for tick in 4:
		await physics_frame
	_check(physics.heavy_upright_torque.is_zero_approx() and physics.heavy_wave_torque_correction.is_zero_approx(),
		"no stabilizer torque in air")
	print("UPRIGHT_SMOKE: %s | errors=%d" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	if failures.is_empty():
		scene.call("_close_gracefully")
	else:
		quit(1)
