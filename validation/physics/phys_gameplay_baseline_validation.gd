extends Node

const OUTPUT_PATH := "res://validation/physics/debug_output/jetski_inertia_1b_ab_report.json"
const ACTIONS := [
	"throttle", "brake", "steer_left", "steer_right",
	"rider_shift_left", "rider_shift_right", "rider_shift_forward", "rider_shift_back",
]
const START_TRANSFORM := Transform3D(Basis.IDENTITY, Vector3(0.0, 1.0, 0.0))


func run(host: Node3D) -> void:
	var ski: JetSkiController = host.get("ski")
	var provider: Node = host.get("water")
	var physics: JetSkiWaterPhysicsSystem = ski.water_physics_system
	var ocean: Node = host.get_node("Production/Ocean")
	var fft: Node = ocean.get_node("OpenOceanFFT")
	provider.set("backend", 1)
	provider.set("compare_other_cpu_backend", false)
	provider.call("set_water_race_mode", true)
	ski.buoyancy_torque_scale = 1.0
	ski.wet_pitch_damping = 20.0
	ski.wet_roll_damping = 80.0
	ski.wet_yaw_damping = 15.0
	ski.max_buoyancy_force_rise_N_per_s = 0.0
	ski.buoyancy_reentry_torque_ramp_seconds = 0.0
	ski._configure_water_physics_system()
	physics.stabilized_angular_mode = true
	var scenarios: Array[Dictionary] = [
		{"name": "stationary", "seconds": 1.0, "actions": []},
		{"name": "diagonal_wave", "seconds": 1.5, "actions": ["throttle", "steer_right"]},
		{"name": "medium_wave_head_on", "seconds": 1.5, "actions": ["throttle"]},
		{"name": "landing_reentry", "seconds": 1.5, "actions": []},
		{"name": "rider_lean_left", "seconds": 1.2, "actions": ["throttle", "rider_shift_left"]},
		{"name": "rider_lean_right", "seconds": 1.2, "actions": ["throttle", "rider_shift_right"]},
	]
	var original_time_scale := float(fft.call("get_simulation_time_scale"))
	var locked_wave_time := float(fft.call("get_wave_time"))
	fft.call("set_wave_speed_multiplier", 0.0)
	await get_tree().process_frame
	var auto_result := await _run_mode(host, ski, provider, physics, scenarios, false, locked_wave_time)
	var combined_result := await _run_mode(host, ski, provider, physics, scenarios, true, locked_wave_time)
	var auto_inertia: Vector3 = ski.get("_auto_inertia_local")
	var combined_inertia: Vector3 = ski.get("inertia")
	var profile: Dictionary = provider.call("get_provider_profile")
	var report := {
		"validation": "JETSKI-INERTIA-1",
		"phase_locked": true,
		"locked_ocean_time_s": locked_wave_time,
		"ocean_time_scale_restored": original_time_scale,
		"surface_unchanged": true,
		"mass_total_kg": ski.mass,
		"hull_mass_kg": ski.mass - ski.rider_inertia_mass_kg,
		"rider_mass_kg": ski.rider_inertia_mass_kg,
		"rider_com_offset_from_hull_com_m": ski.rider_inertia_offset_from_hull_com_m,
		"rider_reference_audit": "No separate rider physics body/mesh is present. Existing rider dynamics use a virtual rider with horizontal weight-shift offsets; this point-mass reference places seated rider COM 0.85 m above and 0.55 m aft of the hull COM, at the broad mid-rear seat region indicated by the collision hull. Existing virtual weight-shift torques remain enabled.",
		"auto_inertia_local_kg_m2": auto_inertia,
		"gameplay_center_of_mass_local_m": ski.center_of_mass,
		"modeled_combined_com_local_m": ski.inertia_measurement.get("modeled_combined_com_local_m", Vector3.ZERO),
		"combined_inertia_local_kg_m2": combined_inertia,
		"axes": {"Ixx": "pitch, local +X", "Iyy": "yaw, local +Y", "Izz": "roll, local +Z"},
		"buoyancy_torque_scale": ski.buoyancy_torque_scale,
		"wet_angular_damping_Nm_s_per_rad": {"pitch": ski.wet_pitch_damping,
			"roll": ski.wet_roll_damping, "yaw": ski.wet_yaw_damping},
		"angular_rate_clamps": false,
		"auto": auto_result,
		"combined_rider": combined_result,
		"comparison": _compare_modes(auto_result.diagnostics, combined_result.diagnostics),
		"performance": {"fps": Engine.get_frames_per_second(),
			"auto_physics_ms": auto_result.physics_ms,
			"combined_physics_ms": combined_result.physics_ms,
			"provider_profile": profile},
		"no_nan_or_explosion": auto_result.all_states_finite and combined_result.all_states_finite,
	}
	var absolute_dir := ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir())
	DirAccess.make_dir_recursive_absolute(absolute_dir)
	var file := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	print("JETSKI INERTIA 1 A/B REPORT: ", JSON.stringify(report))
	fft.call("set_wave_speed_multiplier", original_time_scale)
	ski.set_combined_rider_inertia(true)
	for action in ACTIONS: Input.action_release(action)
	ski.freeze = true
	ski.global_transform = START_TRANSFORM
	ski.linear_velocity = Vector3.ZERO
	ski.angular_velocity = Vector3.ZERO
	ski.reset_physics_interpolation()
	physics.reset_runtime_state()
	physics.reset_diagnostics()
	await get_tree().physics_frame
	ski.freeze = false
	host.set("alignment_validation_running", false)
	queue_free()


func _run_mode(host: Node3D, ski: JetSkiController, provider: Node,
		physics: JetSkiWaterPhysicsSystem, scenarios: Array[Dictionary],
		combined_rider: bool, locked_wave_time: float) -> Dictionary:
	for action in ACTIONS: Input.action_release(action)
	ski.set_combined_rider_inertia(combined_rider)
	physics.reset_diagnostics()
	var phase_start_tick := Engine.get_physics_frames()
	var physics_ms := PackedFloat32Array()
	var scenario_rows: Array[Dictionary] = []
	var hard_landings: Array[Dictionary] = []
	var all_states_finite := true
	var hard_landing_callable := _on_hard_landing.bind(hard_landings)
	if not ski.hard_landing.is_connected(hard_landing_callable):
		ski.hard_landing.connect(hard_landing_callable)
	for scenario in scenarios:
		for action in ACTIONS: Input.action_release(action)
		ski.freeze = true
		ski.global_transform = START_TRANSFORM
		ski.linear_velocity = Vector3.ZERO
		ski.angular_velocity = Vector3.ZERO
		ski.reset_physics_interpolation()
		physics.reset_runtime_state()
		ski.apply_inertia_mode()
		await get_tree().physics_frame
		ski.freeze = false
		await get_tree().physics_frame
		var start_transform := ski.global_transform
		var start_linear_velocity := ski.linear_velocity
		var start_angular_velocity := ski.angular_velocity
		for action in scenario.actions: Input.action_press(action)
		physics.diagnostic_scenario_name = scenario.name
		var frame_count := int(ceil(float(scenario.seconds) * Engine.physics_ticks_per_second))
		var support_frames := 0
		var airborne_frames := 0
		var max_speed := 0.0
		var max_rider_control_torque := 0.0
		var max_rider_shift_input := 0.0
		var finite_state := true
		for _frame in frame_count:
			await get_tree().physics_frame
			var finite_now := ski.linear_velocity.is_finite() and ski.angular_velocity.is_finite() and ski.global_transform.is_finite()
			finite_state = finite_state and finite_now
			all_states_finite = all_states_finite and finite_now
			max_speed = maxf(max_speed, ski.linear_velocity.length())
			max_rider_control_torque = maxf(max_rider_control_torque,
				ski.rider_dynamics_system.state.manual_applied_torque.length())
			max_rider_shift_input = maxf(max_rider_shift_input,
				ski.input_system.state.rider_shift_smoothed.length())
			if bool(ski.get("has_water_support")): support_frames += 1
			else: airborne_frames += 1
			physics_ms.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
		for action in ACTIONS: Input.action_release(action)
		scenario_rows.append({"scenario": scenario.name,
			"duration_s": float(frame_count) / Engine.physics_ticks_per_second,
			"wave_time_s": locked_wave_time, "start_transform": start_transform,
			"start_linear_velocity_mps": start_linear_velocity,
			"start_angular_velocity_rad_s": start_angular_velocity,
			"finish_transform": ski.global_transform,
			"max_speed_mps": max_speed, "support_frames": support_frames,
			"max_rider_control_torque_nm": max_rider_control_torque,
			"max_rider_shift_input": max_rider_shift_input,
			"airborne_frames": airborne_frames, "finite_state": finite_state})
	var diagnostics: Dictionary = physics.get_gameplay_force_diagnostics().duplicate(true)
	if ski.hard_landing.is_connected(hard_landing_callable):
		ski.hard_landing.disconnect(hard_landing_callable)
	return {"mode": "COMBINED RIDER INERTIA" if combined_rider else "AUTO INERTIA",
		"start_tick": phase_start_tick, "all_states_finite": all_states_finite,
		"scenarios": scenario_rows, "hard_landing_count": hard_landings.size(),
		"hard_landing_events": hard_landings, "diagnostics": diagnostics,
		"physics_ms": _stats(physics_ms)}


func _compare_modes(auto: Dictionary, combined: Dictionary) -> Dictionary:
	var comparisons := {}
	var keys := {
		"pitch_rate": ["angular_velocity_pitch_rad_s", "p95", "max"],
		"roll_rate": ["angular_velocity_roll_rad_s", "p95", "max"],
		"pitch_acceleration": ["angular_acceleration_pitch_rad_s2", "p95", "max"],
		"roll_acceleration": ["angular_acceleration_roll_rad_s2", "p95", "max"],
		"buoyancy_torque": ["total_buoyancy_torque_stats_nm", "p95", "max"],
	}
	for name in keys:
		var descriptor: Array = keys[name]
		var metric: String = descriptor[0]
		for stat in ["p95", "max"]:
			var auto_value := float(auto.get(metric, {}).get(stat, 0.0))
			var combined_value := float(combined.get(metric, {}).get(stat, 0.0))
			comparisons[name + "_" + stat] = {"auto": auto_value, "combined": combined_value,
				"change_percent": (100.0 * (combined_value - auto_value) / auto_value if auto_value > 0.0 else 0.0)}
	return comparisons


func _stats(values: PackedFloat32Array) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var ordered := values.duplicate()
	ordered.sort()
	var total := 0.0
	for value in values: total += value
	return {"mean": total / values.size(),
		"p95": ordered[mini(ordered.size() - 1, int(ceil((ordered.size() - 1) * 0.95)))],
		"max": ordered[ordered.size() - 1]}


func _on_hard_landing(intensity: float, position: Vector3,
		output: Array[Dictionary]) -> void:
	output.append({"intensity": intensity, "position": position,
		"tick": Engine.get_physics_frames()})
