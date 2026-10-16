extends SceneTree
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
const Landing = preload("res://addons/jet_ski/common/systems/jet_ski_landing_penetration.gd")
var scene: Node
var ski: JetSkiController
var phase := ""
var tick_count := 0
var impact_tick := -1
var impact_speed := 0.0
var deepest := 0.0
var settled_tick := -1
var stable_ticks := 0
var peak_upward_speed := 0.0
var peak_hydro := 0.0
var peak_damping := 0.0
var peak_drag_up := 0.0
var rest_height := 0.0
var removed_damping := 0.0
var minimum_multiplier := 1.0
var hydro_error := 0.0
var samples: Array[Dictionary] = []
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("DEEP_LANDING_SMOKE: " + message)


func _observe() -> void:
	if phase.is_empty() or ski == null: return
	tick_count += 1
	var water := ski.water_physics_system
	var wet := water.hull_buoyancy.submerged_volume_m3 > 0.00000001
	var hydro := 0.0
	var damping := 0.0
	var drag_up := 0.0
	for index in 4:
		hydro += water.point_spring_forces[index]
		damping += water.point_damping_forces[index]
		drag_up += (water.point_forward_drag_forces[index] + water.point_lateral_drag_forces[index]).y
	if wet and impact_tick < 0:
		impact_tick = tick_count
		impact_speed = -water.state.sampled_body_linear_velocity.y
	if impact_tick >= 0:
		deepest = maxf(deepest, water.state.maximum_depth)
		peak_upward_speed = maxf(peak_upward_speed, ski.linear_velocity.y)
		peak_hydro = maxf(peak_hydro, hydro)
		peak_damping = maxf(peak_damping, damping)
		peak_drag_up = maxf(peak_drag_up, drag_up)
		removed_damping = maxf(removed_damping, water.landing_removed_upward_damping_n)
		minimum_multiplier = minf(minimum_multiplier, water.landing_current_damping_multiplier)
		var expected_hydro := 1000.0 * water.audit_last_total_gravity.length() * water.hull_buoyancy.submerged_volume_m3
		hydro_error = maxf(hydro_error, absf(hydro - expected_hydro))
		if samples.size() < 18:
			samples.append({"time": (tick_count - impact_tick) / 60.0, "depth": water.state.maximum_depth,
				"vy": water.state.sampled_body_linear_velocity.y, "hydro": hydro, "damping": damping, "drag_up": drag_up})
		var resting := absf(ski.linear_velocity.y) < 0.15 and absf(ski.global_position.y - rest_height) < 0.08
		stable_ticks = stable_ticks + 1 if resting else 0
		if stable_ticks >= 30 and settled_tick < 0: settled_tick = tick_count - 29
	if not ski.global_transform.is_finite() or not ski.linear_velocity.is_finite():
		check(false, "finite physical motion"); phase = ""


func _drop(label: String) -> Dictionary:
	ski.reset_vehicle()
	for tick in 2: await physics_frame
	# Initial drop setup only: raise the same resting pose by 5 m, with zero velocity.
	ski.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, rest_height + 5.0, 0.0))
	ski.linear_velocity = Vector3.ZERO
	ski.angular_velocity = Vector3.ZERO
	tick_count = 0; impact_tick = -1; impact_speed = 0.0; deepest = 0.0
	settled_tick = -1; stable_ticks = 0; peak_upward_speed = 0.0
	peak_hydro = 0.0; peak_damping = 0.0; peak_drag_up = 0.0; samples.clear()
	removed_damping = 0.0; minimum_multiplier = 1.0; hydro_error = 0.0
	phase = label
	for tick in 540:
		await physics_frame
		if settled_tick >= 0: break
	phase = ""
	var result := {"mode": label, "impact_mps": impact_speed, "depth_m": deepest,
		"recovery_s": (settled_tick - impact_tick) / 60.0 if settled_tick >= 0 else -1.0,
		"upward_mps": peak_upward_speed, "hydro_N": peak_hydro, "damping_N": peak_damping,
		"drag_up_N": peak_drag_up, "removed_damping_N": removed_damping, "minimum_multiplier": minimum_multiplier,
		"hydro_error_N": hydro_error}
	print("DEEP_LANDING_RESULT: ", JSON.stringify(result))
	print("DEEP_LANDING_ENTRY: ", JSON.stringify(samples))
	check(impact_tick >= 0 and impact_speed > 7.0, label + ": real high-speed water impact")
	check(settled_tick >= 0, label + ": returns to stable surface within nine seconds")
	check(peak_upward_speed < 8.0, label + ": no explosive upward rebound")
	return result


func _latch_checks() -> void:
	var response := Landing.new()
	response.begin_tick(true)
	check(response.damping_multiplier(true, 10.0, 3.0, 0.4) == 1.0, "fast wave descent alone does not arm a landing")
	response.end_tick(false, 0.0, 3.0, 0.1)
	check(response.damping_multiplier(true, 10.0, 3.0, 0.4) == 0.4, "dry-to-wet hard entry uses the configured multiplier")
	check(response.damping_multiplier(true, 3.75, 3.0, 0.4) > 0.4, "normal resistance returns as descent slows")
	check(response.damping_multiplier(true, 3.0, 3.0, 0.4) == 1.0, "full resistance below threshold")
	response.end_tick(true, 0.0, 3.0, 1.0 / 60.0)
	check(not response.active and response.damping_multiplier(true, 10.0, 3.0, 0.4) == 1.0, "landing latch ends on recovery")
	response.end_tick(false, 0.0, 3.0, 0.1)
	response.begin_tick(false)
	check(response.damping_multiplier(false, 10.0, 3.0, 0.4) == 1.0, "disabled/HEAVY/Submarine bypass is exact")
	# An unchanged moment is required even for an asymmetric landing.
	var lever := Vector3(-0.5, -0.6, -1.2)
	var original_damping := Vector3(200.0, 12000.0, -150.0)
	var removed := Vector3.UP * original_damping.y * 0.6
	check(((lever.cross(original_damping - removed) + lever.cross(removed)) \
		- lever.cross(original_damping)).length() < 0.001, "heave reduction preserves the original angular moment")


func _run() -> void:
	_latch_checks()
	scene = Gameplay.instantiate()
	scene.get_node("Production/Ocean").set("wave_height_scale", 0.0)
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")): break
	check(bool(scene.get("ready_to_drive")), "gameplay initializes")
	if not bool(scene.get("ready_to_drive")): quit(1); return
	ski = scene.get("ski")
	ski.landing_penetration_enabled = false
	ski.set_hull_response_mode(JetSkiController.HullResponseMode.HULL_V1_PREVIOUS)
	ski.water_physics_system.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	for tick in 180: await physics_frame
	check(not ski.is_heavy_hull_active() and not ski.water_physics_system.heavy_hull_enabled, "reference uses PREVIOUS, never HEAVY")
	check(ski.mass == 300.0 and ski.rider_weight_shift_enabled, "300 kg and existing Wheelie controls")
	rest_height = ski.global_position.y
	print("DEEP_LANDING_REFERENCE: HULL_BUOYANCY_V1 + existing Wheelie + HULL_V1_PREVIOUS | rest y=%.4f mass=%.0f inertia=%s hull volume=%.4f" % [
		rest_height, ski.mass, ski.inertia, ski.water_physics_system.hull_buoyancy.total_volume_m3])
	physics_frame.connect(_observe)
	var baseline: Dictionary = await _drop("OFF")
	# Use the actual HUD key route for A/B; only this flag is allowed to change.
	var old_response := ski.hull_response_mode
	var old_engine := ski.drive_system.forward_engine_force
	var old_inertia := ski.inertia
	var old_query_mode: int = int(scene.get("water").get("query_mode"))
	for child in ski.get_children():
		if child is CanvasLayer and child.has_method("_unhandled_key_input"):
			var event := InputEventKey.new()
			event.keycode = KEY_G; event.pressed = true
			child.call("_unhandled_key_input", event)
	check(ski.landing_penetration_enabled, "G selects landing tuning ON")
	var adjusted: Dictionary = await _drop("ON")
	check(adjusted.removed_damping_N > 0.0 and adjusted.minimum_multiplier <= 0.40001, "actual Jolt hard landing applies reduced dynamic resistance")
	check(adjusted.depth_m > baseline.depth_m + 0.15, "strong landing clearly penetrates farther")
	check(absf(adjusted.impact_mps - baseline.impact_mps) < 0.2, "A/B initial impact speed unchanged")
	check(adjusted.hydro_error_N < 0.02 and baseline.hydro_error_N < 0.02, "rho*g*volume hydrostatic lift is unchanged in every sampled tick")
	check(ski.hull_response_mode == old_response and ski.inertia == old_inertia \
		and ski.drive_system.forward_engine_force == old_engine and int(scene.get("water").get("query_mode")) == old_query_mode,
		"A/B keeps response, inertia, engine and water contact mode intact")
	check(absf(ski.global_position.y - rest_height) < 0.08 and ski.water_physics_system.landing_removed_upward_damping_n == 0.0,
		"same rest flotation and zero residual tuning force")
	print("DEEP_LANDING_SMOKE: %s errors=%d" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	if failures.is_empty(): scene.call("_close_gracefully")
	else: quit(1)
