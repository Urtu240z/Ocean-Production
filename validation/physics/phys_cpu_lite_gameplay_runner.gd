extends SceneTree

## Controlled full-vs-lite test on the existing JetSkiController and Jolt body.
## Run once with --backend=full and once with --backend=lite. Both CPU fields are
## built at each same physics tick; the selected backend alone applies forces.
const WORLD := preload("res://gameplay/jet_ski_ocean.tscn")
const CASES := [
	{"name": "A_stationary_float", "ticks": 180, "throttle": 0.0, "steer": 0.0},
	{"name": "B_straight_low", "ticks": 180, "throttle": 0.25, "steer": 0.0},
	{"name": "C_straight_medium", "ticks": 180, "throttle": 0.55, "steer": 0.0},
	{"name": "D_high_speed", "ticks": 240, "throttle": 0.9, "steer": 0.0},
	{"name": "E_left_turn", "ticks": 180, "throttle": 0.6, "steer": -0.8},
	{"name": "F_right_turn", "ticks": 180, "throttle": 0.6, "steer": 0.8},
	{"name": "G_drop_reentry", "ticks": 180, "throttle": 0.0, "steer": 0.0, "drop": true},
]
var _world: Node
var _report: Dictionary = {"status": "PARTIAL", "scenarios": [], "sampling_scalability": [], "contact_comparisons": []}
var _test_wave_ticks := 0
var _trace_state_name := "current_production"

func _initialize() -> void:
	call_deferred("_run")

func _fail(reason: String) -> void:
	_report.status = "FAILED"
	_report.error = reason
	_write_report()
	printerr("PHYS_CPU_LITE_GAMEPLAY_FAIL=" + reason)
	quit(1)

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var backend_name := "lite" if args.has("--backend=lite") else "full"
	var storm_fixture := args.has("--state=storm")
	var normal_fixture := args.has("--state=normal")
	_trace_state_name = "storm" if storm_fixture else ("normal" if normal_fixture else "current_production")
	var compare_backends := not args.has("--single")
	var capture_trace := args.has("--capture-trace")
	var backend_value := 2 if backend_name == "lite" else 1
	_world = WORLD.instantiate()
	_world.physics_water_backend = backend_value
	_world.compare_cpu_backends = compare_backends
	_world.contact_debug = false
	_world.follow_camera = false
	var ocean: Node = _world.get_node("Production/Ocean")
	ocean.set("coastal", false)
	ocean.set("breakers", false)
	if normal_fixture or storm_fixture:
		ocean.set("sea_state_mode", 1)
		ocean.set("significant_wave_height_m", 3.0 if storm_fixture else 1.8)
		ocean.set("wind_speed_mps", 18.0 if storm_fixture else 8.0)
		ocean.set("wind_direction_degrees", 75.0 if storm_fixture else 35.0)
		ocean.set("wave_height_scale", 1.16 if storm_fixture else 1.0)
		ocean.set("swell", 0.8 if storm_fixture else 1.0)
	root.add_child(_world)
	for _frame in 360:
		await process_frame
		if bool(_world.get("ready_to_drive")): break
	if not bool(_world.get("ready_to_drive")):
		_fail("Jetski scene or selected CPU provider did not become ready"); return
	var fft: Node = _world.get_node("Production/Ocean/OpenOceanFFT")
	var provider: Node = _world.get_node("PhysicalWater")
	var ski: RigidBody3D = _world.get("ski")
	provider.set("capture_contact_trace", capture_trace)
	if ski == null or not provider.call("has_usable_contacts"):
		_fail("initial synchronous CPU field was not ready"); return
	# Decouple the test clock from renderer startup and wall-clock scheduling.
	# Every run starts at the same phase and advances exactly one fixed step per
	# physics tick, while OpenOceanFFT remains the sole source of field time.
	fft.set("_wave_speed_multiplier", 0.0)
	fft.set("_wave_time", 0.5)
	provider.set("wave_time_rate_override", 1.0)
	var authored_state := {
		"simulation_seed": int(ocean.get("simulation_seed")),
		"sea_state_mode": int(ocean.get("sea_state_mode")),
		"significant_wave_height_m": float(ocean.get("significant_wave_height_m")),
		"wind_speed_mps": float(ocean.get("wind_speed_mps")),
		"wind_direction_degrees": float(ocean.get("wind_direction_degrees")),
		"wave_height_scale": float(ocean.get("wave_height_scale")),
		"swell": float(ocean.get("swell")),
		"coastal_enabled": false, "breakers_enabled": false,
		"storm_fixture": storm_fixture,
	}
	_report["machine"] = {"cpu": OS.get_processor_name(), "renderer": RenderingServer.get_current_rendering_method(),
		"driver": RenderingServer.get_current_rendering_driver_name(), "gpu": RenderingServer.get_video_adapter_name()}
	_report["selected_backend"] = backend_name.to_upper()
	_report["comparison_backend"] = ("CPU_LITE_B" if backend_name == "full" else "FULL_CPU") if compare_backends else "DISABLED"
	_report["environment"] = authored_state
	_report["tick_rate_hz"] = Engine.physics_ticks_per_second
	_report["start_wave_time"] = float(fft.call("get_wave_time"))
	_report["initial_transform"] = [0.0, 1.0, 0.0]
	_report["vehicle_constants"] = {"equilibrium_depth": _world.ski.water_physics_system.equilibrium_depth,
		"damping_ratio": _world.ski.water_physics_system.damping_ratio,
		"body_mass_kg": ski.mass,
		"gravity_mps2": float(ProjectSettings.get_setting("physics/3d/default_gravity")),
		"buoyancy_point_count": 4,
		"buoyancy_strength_per_point": _world.ski.buoyancy_strength_per_point,
		"buoyancy_damping_per_point": _world.ski.buoyancy_damping_per_point,
		"contact_local_points": _world.ski.water_physics_system.get_buoyancy_local_points()}
	for scenario: Dictionary in CASES:
		await _run_case(scenario, ski, provider)
	if storm_fixture:
		await _run_case({"name": "H_storm_traversal", "ticks": 300, "throttle": 0.7, "steer": 0.0}, ski, provider)
	if not capture_trace: await _run_sampling_benchmarks(provider)
	_report["provider_profile"] = provider.call("get_provider_profile")
	_report["contact_comparisons"] = provider.get("comparison_rows")
	if capture_trace:
		_report["contact_trace"] = "res://.godot/phys_cpu_lite_contact_trace_%s.json" % _trace_state_name
		_write_contact_trace(provider.get("contact_trace_rows"))
	_report["field_time_clock_contract"] = "Both CPU fields are built from OpenOceanFFT.get_wave_time once per physics tick; the runner starts at 0.5 s and advances that clock by exactly 1/physics_ticks_per_second after each tick while holding physical wave-speed scale at 1.0; CPU Lite uses q=worldXZ and zero horizontal physical displacement."
	_report["waterforce_contract"] = "The selected provider alone drives the unchanged JetSkiWaterPhysicsSystem. Paired mode also samples the other CPU field at the same contact/time and recomputes observer support force with existing constants."
	_report.status = "CAPTURED_REVIEW_REQUIRED"
	_write_report()
	print("PHYS_CPU_LITE_GAMEPLAY_RESULT=" + _output_path(backend_name, storm_fixture))
	if _world.has_method("_close_gracefully"):
		await _world.call("_close_gracefully")
	else:
		quit(0)

func _run_case(scenario: Dictionary, ski: RigidBody3D, provider: Node) -> void:
	_release_controls()
	_reset_vehicle(ski, bool(scenario.get("drop", false)))
	provider.set("trace_scenario", String(scenario.name))
	provider.call("reset_comparison_metrics")
	var wave_time_start := float(_world.get_node("Production/Ocean/OpenOceanFFT").call("get_wave_time"))
	var metric_rows: Array[Dictionary] = []
	var ticks := int(scenario.ticks)
	Input.action_press("throttle", float(scenario.throttle)) if float(scenario.throttle) > 0.0 else Input.action_release("throttle")
	Input.action_press("steer_right", float(scenario.steer)) if float(scenario.steer) > 0.0 else Input.action_release("steer_right")
	Input.action_press("steer_left", -float(scenario.steer)) if float(scenario.steer) < 0.0 else Input.action_release("steer_left")
	for _tick in ticks:
		await physics_frame
		var physics = ski.water_physics_system
		var depths: PackedFloat32Array = physics.point_depths
		var valid: Array[bool] = physics.point_sample_valid
		var wet := 0
		for i in 4:
			if i < valid.size() and valid[i] and depths[i] > 0.0: wet += 1
		metric_rows.append({
			"body_y": ski.global_position.y,
			"pitch_rad": ski.global_rotation.x,
			"roll_rad": ski.global_rotation.z,
			"speed_mps": ski.linear_velocity.length(),
			"buoyancy_force_n": physics.state.total_buoyancy_force,
			"average_depth_m": physics.state.average_depth,
			"wet_contacts": wet,
			"valid_contacts": valid.count(true),
		})
		_test_wave_ticks += 1
		_world.get_node("Production/Ocean/OpenOceanFFT").set("_wave_time",
			0.5 + float(_test_wave_ticks) / float(Engine.physics_ticks_per_second))
	_release_controls()
	var compare_rows: Array = provider.get("comparison_rows")
	var comparison: Array = compare_rows.duplicate(true)
	var summary := {"name": scenario.name, "ticks": ticks, "throttle": scenario.throttle, "steer": scenario.steer,
		"wave_time_start": wave_time_start,
		"wave_time_end": _world.get_node("Production/Ocean/OpenOceanFFT").call("get_wave_time"),
		"vehicle": _summarize_vehicle(metric_rows), "water_contact": _summarize_contacts(comparison),
		"input_schedule": "constant throttle/steer for each fixed-duration segment; other actions released"}
	if bool(scenario.get("drop", false)): summary["initial_drop"] = {"world_y": 5.0, "vertical_velocity_mps": -7.0}
	_report.scenarios.append(summary)
	# Preserve the real contact coordinates and per-sample errors for later review.
	_report.contact_comparisons.append_array(comparison)

func _reset_vehicle(ski: RigidBody3D, drop: bool) -> void:
	ski.freeze = true
	ski.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 5.0 if drop else 1.0, 0.0))
	ski.linear_velocity = Vector3(0.0, -7.0 if drop else 0.0, 0.0)
	ski.angular_velocity = Vector3.ZERO
	ski.sleeping = false
	ski.reset_physics_interpolation()
	ski.freeze = false

func _release_controls() -> void:
	for action in ["throttle", "brake", "steer_left", "steer_right", "rider_shift_left", "rider_shift_right", "rider_shift_forward", "rider_shift_back"]:
		Input.action_release(action)

func _run_sampling_benchmarks(provider: Node) -> void:
	provider.call("reset_sample_metrics")
	var layouts := [
		{"label": "1 craft x4", "contacts": 4, "contacts_per_batch": 4},
		{"label": "10 craft x4, batched globally", "contacts": 40, "contacts_per_batch": 40},
		{"label": "10 craft x4, per-craft calls", "contacts": 40, "contacts_per_batch": 4},
		{"label": "10 craft x6, batched globally", "contacts": 60, "contacts_per_batch": 60},
		{"label": "10 craft x6, per-craft calls", "contacts": 60, "contacts_per_batch": 6},
		{"label": "100 contacts, batched globally", "contacts": 100, "contacts_per_batch": 100},
		{"label": "100 contacts, 10-craft calls", "contacts": 100, "contacts_per_batch": 10},
	]
	for layout: Dictionary in layouts:
		var contact_count := int(layout.contacts)
		var points := PackedVector3Array()
		for index in contact_count:
			var x := float(index % 10) * 2.75 - 13.75
			var z := float(index / 10) * 2.25 - 6.75
			points.append(Vector3(x, 0.0, z))
		var points_per_batch := int(layout.contacts_per_batch)
		var batches: Array[PackedVector3Array] = []
		for start_index in range(0, contact_count, points_per_batch):
			var batch := PackedVector3Array()
			for index in range(start_index, mini(start_index + points_per_batch, contact_count)):
				batch.append(points[index])
			batches.append(batch)
		var repeats := 20
		var native_before := int(provider.get("contact_query_native_us"))
		var overhead_before := int(provider.get("contact_query_provider_overhead_us"))
		var start := Time.get_ticks_usec()
		for _round in repeats:
			for batch_points in batches:
				var batch: Array[WaterSample3D] = provider.call("sample_water_batch", batch_points)
				if batch.size() != batch_points.size():
					_fail("synthetic native contact batch returned an invalid result size"); return
				for sample in batch:
					if not sample.valid:
						_fail("synthetic native contact batch returned an invalid sample"); return
		var elapsed := Time.get_ticks_usec() - start
		var native_us := int(provider.get("contact_query_native_us")) - native_before
		var overhead_us := int(provider.get("contact_query_provider_overhead_us")) - overhead_before
		_report.sampling_scalability.append({"layout": layout.label, "contacts": contact_count,
			"contacts_per_batch": points_per_batch, "batches_per_round": batches.size(), "rounds": repeats,
			"equivalent_craft": 1 if contact_count == 4 else 10,
			"contacts_per_craft": points_per_batch if batches.size() > 1 else contact_count,
			"total_samples": contact_count * repeats, "wall_us": elapsed,
			"mean_round_us": float(elapsed) / repeats,
			"mean_contact_us": float(elapsed) / (contact_count * repeats),
			"native_total_us": native_us, "mean_native_batch_us": float(native_us) / (repeats * batches.size()),
			"mean_native_contact_us": float(native_us) / (contact_count * repeats),
			"provider_overhead_total_us": overhead_us, "mean_provider_overhead_batch_us": float(overhead_us) / (repeats * batches.size()),
			"mean_provider_overhead_contact_us": float(overhead_us) / (contact_count * repeats)})

func _summarize_vehicle(rows: Array[Dictionary]) -> Dictionary:
	if rows.is_empty(): return {"samples": 0}
	var summary := {"samples": rows.size()}
	for key in ["body_y", "pitch_rad", "roll_rad", "speed_mps", "buoyancy_force_n", "average_depth_m", "wet_contacts", "valid_contacts"]:
		var values: Array[float] = []
		for row in rows: values.append(float(row[key]))
		summary[key] = _stats(values)
	return summary

func _summarize_contacts(rows: Array[Dictionary]) -> Dictionary:
	var any_wet: Array[Dictionary] = []
	var both_wet: Array[Dictionary] = []
	var buoyancy_rows: Array[Dictionary] = []
	var propulsion_rows: Array[Dictionary] = []
	var summary := {"samples": rows.size()}
	for row in rows:
		if String(row.get("sample_kind", "buoyancy_contact")) == "propulsion_point": propulsion_rows.append(row)
		else: buoyancy_rows.append(row)
		if bool(row.selected_wet) or bool(row.comparison_wet): any_wet.append(row)
		if bool(row.selected_wet) and bool(row.comparison_wet): both_wet.append(row)
	for key in ["height_delta_m", "normal_delta_degrees", "vertical_velocity_delta_mps", "signed_depth_delta_m", "support_force_delta_n"]:
		var values: Array[float] = []
		for row in rows: values.append(float(row[key]))
		summary[key] = _stats(values)
	summary["at_least_one_backend_wet"] = _summarize_contact_subset(any_wet)
	summary["both_backends_wet"] = _summarize_contact_subset(both_wet)
	summary["buoyancy_contacts"] = _summarize_contact_subset(buoyancy_rows)
	summary["propulsion_point"] = _summarize_contact_subset(propulsion_rows)
	return summary

func _summarize_contact_subset(rows: Array[Dictionary]) -> Dictionary:
	var summary := {"samples": rows.size()}
	for key in ["height_delta_m", "normal_delta_degrees", "vertical_velocity_delta_mps", "signed_depth_delta_m", "support_force_delta_n"]:
		var values: Array[float] = []
		for row in rows: values.append(float(row[key]))
		summary[key] = _stats(values)
	return summary

func _stats(source: Array[float]) -> Dictionary:
	if source.is_empty(): return {"count": 0}
	var values := source.duplicate(); values.sort()
	var sum := 0.0; var square_sum := 0.0
	for value in values:
		sum += value
		square_sum += value * value
	var absolute_values: Array[float] = []
	for value in values: absolute_values.append(absf(value))
	absolute_values.sort()
	return {"count": values.size(), "mean": sum / values.size(), "rms": sqrt(square_sum / values.size()),
		"p95": values[ceili(values.size() * 0.95) - 1], "p99": values[ceili(values.size() * 0.99) - 1],
		"p95_abs": absolute_values[ceili(absolute_values.size() * 0.95) - 1],
		"p99_abs": absolute_values[ceili(absolute_values.size() * 0.99) - 1],
		"max_abs": absolute_values[absolute_values.size() - 1]}

func _output_path(backend_name: String, storm_fixture: bool) -> String:
	var suffix := "_storm" if storm_fixture else ""
	if OS.get_cmdline_user_args().has("--state=normal"): suffix = "_normal"
	if OS.get_cmdline_user_args().has("--single"): suffix += "_single"
	return "res://.godot/phys_cpu_lite_gameplay_%s%s.json" % [backend_name, suffix]

func _write_report() -> void:
	var backend_name := "lite" if OS.get_cmdline_user_args().has("--backend=lite") else "full"
	var storm_fixture := OS.get_cmdline_user_args().has("--state=storm")
	var output := FileAccess.open(_output_path(backend_name, storm_fixture), FileAccess.WRITE)
	if output == null: return
	output.store_string(JSON.stringify(_report, "\t")); output.close()

func _write_contact_trace(rows: Array) -> void:
	var path := "res://.godot/phys_cpu_lite_contact_trace_%s.json" % _trace_state_name
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null: return
	output.store_string(JSON.stringify({"source_backend": "FULL_CPU", "state": _trace_state_name, "seed": 20260820,
		"physics_hz": Engine.physics_ticks_per_second, "start_wave_time": 0.5,
		"vehicle_constants": _report.get("vehicle_constants", {}), "rows": rows}, "\t"))
	output.close()
