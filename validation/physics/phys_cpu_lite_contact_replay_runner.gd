extends SceneTree

## Replays one recorded Full CPU Jetski contact trajectory through Lite spectra.
## No vehicle physics is advanced by this runner.
const WORLD := preload("res://gameplay/jet_ski_ocean.tscn")
const PROVIDER := preload("res://gameplay/water/cpu_fft_water_provider.gd")
const NORMAL_EPSILON := 0.01
const VARIANTS := [
	{"name": "A_128_128_64_BILINEAR", "resolutions": [128, 128, 64], "interpolation": [0, 0, 0]},
	{"name": "B_128_128_128_BILINEAR", "resolutions": [128, 128, 128], "interpolation": [0, 0, 0]},
	{"name": "LONG256_SHORT128_BILINEAR", "resolutions": [256, 128, 128], "interpolation": [0, 0, 0]},
	{"name": "C_128_128_128_ALL_CUBIC", "resolutions": [128, 128, 128], "interpolation": [1, 1, 1]},
	{"name": "D_128_128_CUBIC_SHORT_BILINEAR", "resolutions": [128, 128, 128], "interpolation": [1, 1, 0]},
	{"name": "B_PLUS_LONG_256_128_64", "resolutions": [256, 128, 64], "interpolation": [0, 0, 0]},
	{"name": "B_PLUS_MID_128_256_64", "resolutions": [128, 256, 64], "interpolation": [0, 0, 0]},
	{"name": "B_PLUS_SHORT_128_128_128", "resolutions": [128, 128, 128], "interpolation": [0, 0, 0]},
]

var _world: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var state := "storm" if OS.get_cmdline_user_args().has("--state=storm") else (
		"normal" if OS.get_cmdline_user_args().has("--state=normal") else "current_production")
	var trace_path := "res://.godot/phys_cpu_lite_contact_trace_%s.json" % state
	if not FileAccess.file_exists(trace_path):
		_fail("missing Full CPU contact trace: " + trace_path); return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(trace_path))
	if not parsed is Dictionary or not parsed.get("rows", []) is Array:
		_fail("contact trace is not a valid JSON capture"); return
	var trace: Dictionary = parsed
	var rows: Array = trace.rows
	if rows.is_empty():
		_fail("contact trace has no samples"); return
	_world = WORLD.instantiate()
	_world.physics_water_backend = 1
	_world.compare_cpu_backends = false
	_world.contact_debug = false
	_world.follow_camera = false
	var ocean: Node = _world.get_node("Production/Ocean")
	ocean.set("coastal", false)
	ocean.set("breakers", false)
	if state != "current_production":
		ocean.set("sea_state_mode", 1)
		ocean.set("significant_wave_height_m", 3.0 if state == "storm" else 1.8)
		ocean.set("wind_speed_mps", 18.0 if state == "storm" else 8.0)
		ocean.set("wind_direction_degrees", 75.0 if state == "storm" else 35.0)
		ocean.set("wave_height_scale", 1.16 if state == "storm" else 1.0)
		ocean.set("swell", 0.8 if state == "storm" else 1.0)
	root.add_child(_world)
	for _frame in 360:
		await process_frame
		if bool(_world.get("ready_to_drive")): break
	if not bool(_world.get("ready_to_drive")):
		_fail("CPU provider failed to initialize for trace replay"); return
	var ski: RigidBody3D = _world.get("ski")
	ski.freeze = true
	var provider: Node = _world.get_node("PhysicalWater")
	provider.set("wave_time_rate", 1.0)
	var groups := _group_trace_rows(rows)
	var vehicle_constants: Dictionary = trace.get("vehicle_constants", {})
	var output: Dictionary = {
		"status": "PARTIAL", "state": state, "source_backend": "FULL_CPU",
		"trace_path": trace_path, "trace_rows": rows.size(), "trace_ticks": groups.size(),
		"same_contact_replay": true, "vehicle_physics_advanced": false,
		"vehicle_constants": vehicle_constants, "variants": [],
		"normal_semantics_validation": {},
		"lookup_contract": "one native call per contact batch; per position and band, periodic bilinear loads 4 or Catmull-Rom cubic loads 16 packed complex texels; both compute H, VY, and analytical dH/dx,dH/dz",
	}
	var native: Object = provider.get("native")
	for variant: Dictionary in VARIANTS:
		var resolutions := PackedInt32Array(variant.resolutions)
		var scenario_metrics: Dictionary = {}
		var overall_metrics := _new_metrics()
		var build_wall_us := 0
		var build_native_us := 0
		var build_wall_samples: Array[float] = []
		var build_native_samples: Array[float] = []
		var band_ifft_samples: Array = [[], [], []]
		var support_force_compute_us := 0
		var support_force_compute_calls := 0
		provider.call("reset_sample_metrics")
		var build_failed := false
		for group: Dictionary in groups:
			var simulation_time := float(group.time)
			var build_started := Time.get_ticks_usec()
			if not bool(native.call("build_dynamic_physics_lite", simulation_time, resolutions)):
				build_failed = true; break
			var build_elapsed_us := Time.get_ticks_usec() - build_started
			build_wall_us += build_elapsed_us
			var profile: Dictionary = native.call("get_dynamic_lite_profile")
			var native_update_us := int(profile.get("update_us", 0))
			build_native_us += native_update_us
			build_wall_samples.append(float(build_elapsed_us))
			build_native_samples.append(float(native_update_us))
			var band_ifft: PackedInt64Array = profile.get("ifft_us", PackedInt64Array())
			for band in mini(3, band_ifft.size()): band_ifft_samples[band].append(float(band_ifft[band]))
			var contacts: Array = group.rows
			var positions := PackedVector3Array()
			for record: Dictionary in contacts:
				var p: Array = record.world_position
				positions.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
			var modes := PackedInt32Array(variant.interpolation)
			var samples: Array[WaterSample3D] = provider.call("sample_water_batch", positions,
				PROVIDER.Backend.CPU_LITE_B, modes)
			if samples.size() != contacts.size():
				build_failed = true; break
			var scenario := String(group.scenario)
			if not scenario_metrics.has(scenario): scenario_metrics[scenario] = _new_metrics()
			for index in samples.size():
				var candidate: WaterSample3D = samples[index]
				if not candidate.valid:
					build_failed = true; break
				var record: Dictionary = contacts[index]
				var full: Dictionary = record.full_sample
				var full_position := Vector3(record.world_position[0], record.world_position[1], record.world_position[2])
				var full_normal := Vector3(full.normal[0], full.normal[1], full.normal[2])
				var contact_velocity := Vector3(record.contact_velocity[0], record.contact_velocity[1], record.contact_velocity[2])
				var height_error := candidate.surface_position.y - float(full.surface_y)
				var vy_error := candidate.velocity.y - float(full.vertical_velocity)
				var depth_error := candidate.signed_depth - float(full.signed_depth)
				var normal_error := rad_to_deg(candidate.normal.angle_to(full_normal))
				var parameters := vehicle_constants
				var support_force_started := Time.get_ticks_usec()
				var full_force := _support_force(float(full.signed_depth), float(full.vertical_velocity),
					contact_velocity.y, parameters)
				var height_only_force := _support_force(candidate.signed_depth, float(full.vertical_velocity),
					contact_velocity.y, parameters)
				var lite_force := _support_force(candidate.signed_depth, candidate.velocity.y,
					contact_velocity.y, parameters)
				support_force_compute_us += Time.get_ticks_usec() - support_force_started
				support_force_compute_calls += 3
				var sample_metrics := {
					"height_error_m": height_error, "vertical_velocity_error_mps": vy_error,
					"normal_error_degrees": normal_error, "signed_depth_error_m": depth_error,
					"support_force_error_n": lite_force - full_force,
					"force_height_component_n": height_only_force - full_force,
					"force_velocity_component_n": lite_force - height_only_force,
				}
				_record_metrics(overall_metrics, sample_metrics)
				_record_metrics(scenario_metrics[scenario], sample_metrics)
				if candidate.signed_depth > 0.0 and float(full.signed_depth) > 0.0:
					_record_metrics(overall_metrics.both_wet, sample_metrics)
					_record_metrics(scenario_metrics[scenario].both_wet, sample_metrics)
			if build_failed: break
		var profile_metrics: Dictionary = provider.call("get_provider_profile")
		var sixty_contact_query := _benchmark_sixty_contact_batch(provider, native, groups,
			PackedInt32Array(variant.interpolation))
		var scenario_results: Dictionary = {}
		for scenario in scenario_metrics:
			scenario_results[scenario] = _finish_metrics(scenario_metrics[scenario])
		var variant_result := {
			"name": variant.name, "resolutions": variant.resolutions,
			"interpolation_modes": variant.interpolation,
			"build_failures": 1 if build_failed else 0,
			"field_build_wall_total_us": build_wall_us,
			"field_build_native_total_us": build_native_us,
			"field_build_mean_native_us": float(build_native_us) / groups.size(),
			"field_build_wall_stats_us": _absolute_stats(build_wall_samples),
			"field_build_native_stats_us": _absolute_stats(build_native_samples),
			"per_band_ifft_stats_us": [
				_absolute_stats(band_ifft_samples[0]), _absolute_stats(band_ifft_samples[1]),
				_absolute_stats(band_ifft_samples[2])],
			"sixty_contact_query": sixty_contact_query,
			"shared_field_plus_sixty_contact_mean_us": float(build_native_us) / groups.size() +
				float(sixty_contact_query.get("wall_mean_us", 0.0)),
			"contact_query_profile": {
				"batch_calls": profile_metrics.contact_query_batch_count,
				"contacts": profile_metrics.contact_query_count,
				"wall_total_us": profile_metrics.contact_query_wall_us,
				"native_total_us": profile_metrics.contact_query_native_us,
				"provider_overhead_total_us": profile_metrics.contact_query_provider_overhead_us,
				"mean_wall_us_per_contact": float(profile_metrics.contact_query_wall_us) / maxi(1, profile_metrics.contact_query_count),
				"mean_native_us_per_contact": float(profile_metrics.contact_query_native_us) / maxi(1, profile_metrics.contact_query_count),
				"mean_provider_overhead_us_per_contact": float(profile_metrics.contact_query_provider_overhead_us) / maxi(1, profile_metrics.contact_query_count),
			},
			"support_force_compute": {"calls": support_force_compute_calls,
				"total_us": support_force_compute_us,
				"mean_us_per_call": float(support_force_compute_us) / maxi(1, support_force_compute_calls),
				"mean_us_per_contact": float(support_force_compute_us) / maxi(1, profile_metrics.contact_query_count)},
			"overall": _finish_metrics(overall_metrics), "scenarios": scenario_results,
		}
		output.variants.append(variant_result)
		if build_failed:
			_fail("trace replay failed for " + String(variant.name)); return
		if variant.name == "B_128_128_128_BILINEAR":
			output.normal_semantics_validation = await _compare_bilinear_gradient_to_finite_difference(
				provider, native, groups, resolutions)
	output["cubic_derivative_validation"] = await _validate_cubic_derivatives(native, groups)
	output["status"] = "CAPTURED_REVIEW_REQUIRED"
	output["conclusion"] = "No candidate selected by this runner; compare per-scenario contact errors and field/query cost."
	var out_file := FileAccess.open("res://.godot/phys_cpu_lite_contact_replay_%s.json" % state, FileAccess.WRITE)
	if out_file == null:
		_fail("could not write replay result"); return
	out_file.store_string(JSON.stringify(output, "\t")); out_file.close()
	print("PHYS_CPU_LITE_CONTACT_REPLAY= " + "res://.godot/phys_cpu_lite_contact_replay_%s.json" % state)
	if _world.has_method("_close_gracefully"):
		await _world.call("_close_gracefully")
	else:
		quit(0)

func _group_trace_rows(rows: Array) -> Array[Dictionary]:
	var groups: Array[Dictionary] = []
	var by_tick: Dictionary = {}
	for row: Dictionary in rows:
		var tick := int(row.tick)
		if not by_tick.has(tick):
			var group := {"tick": tick, "scenario": String(row.scenario),
				"time": float(row.simulation_time), "rows": []}
			by_tick[tick] = group
			groups.append(group)
		by_tick[tick].rows.append(row)
	return groups

func _new_metrics() -> Dictionary:
	return {"height_error_m": [], "vertical_velocity_error_mps": [], "normal_error_degrees": [],
		"signed_depth_error_m": [], "support_force_error_n": [], "force_height_component_n": [],
		"force_velocity_component_n": [], "both_wet": {"height_error_m": [],
		"vertical_velocity_error_mps": [], "normal_error_degrees": [], "signed_depth_error_m": [],
		"support_force_error_n": [], "force_height_component_n": [], "force_velocity_component_n": []}}

func _record_metrics(target: Dictionary, values: Dictionary) -> void:
	for key in values: target[key].append(absf(float(values[key])))

func _finish_metrics(metrics: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for key in ["height_error_m", "vertical_velocity_error_mps", "normal_error_degrees", "signed_depth_error_m",
		"support_force_error_n", "force_height_component_n", "force_velocity_component_n"]:
		result[key] = _absolute_stats(metrics[key])
	result["both_wet"] = {}
	for key in metrics.both_wet:
		result.both_wet[key] = _absolute_stats(metrics.both_wet[key])
	return result

func _absolute_stats(source: Array) -> Dictionary:
	if source.is_empty(): return {"count": 0}
	var values: Array[float] = []
	var sum := 0.0
	var square_sum := 0.0
	for value in source:
		var v := absf(float(value))
		values.append(v); sum += v; square_sum += v * v
	values.sort()
	return {"count": values.size(), "mean": sum / values.size(), "rms": sqrt(square_sum / values.size()),
		"p50": values[ceili(values.size() * 0.50) - 1],
		"p90": values[ceili(values.size() * 0.90) - 1], "p95": values[ceili(values.size() * 0.95) - 1],
		"p99": values[ceili(values.size() * 0.99) - 1], "max": values.back()}

func _benchmark_sixty_contact_batch(provider: Node, native: Object, groups: Array[Dictionary],
		modes: PackedInt32Array) -> Dictionary:
	var positions := PackedVector3Array()
	for group: Dictionary in groups:
		for record: Dictionary in group.rows:
			var p: Array = record.world_position
			positions.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
			if positions.size() == 60: break
		if positions.size() == 60: break
	if positions.size() < 60: return {"contacts": positions.size(), "error": "trace has fewer than 60 contacts"}
	provider.call("reset_sample_metrics")
	for _warmup in 20: provider.call("sample_water_batch", positions, PROVIDER.Backend.CPU_LITE_B, modes)
	var wall_samples: Array[float] = []
	for _iteration in 200:
		var started := Time.get_ticks_usec()
		var samples: Array[WaterSample3D] = provider.call("sample_water_batch", positions,
			PROVIDER.Backend.CPU_LITE_B, modes)
		wall_samples.append(float(Time.get_ticks_usec() - started))
		if samples.size() != 60: return {"contacts": 60, "error": "batch returned an unexpected contact count"}
	var profile: Dictionary = provider.call("get_provider_profile")
	return {"contacts": 60, "iterations": wall_samples.size(),
		"wall_stats_us": _absolute_stats(wall_samples),
		"wall_mean_us": _mean(wall_samples), "native_total_us": profile.contact_query_native_us,
		"mean_native_us_per_batch": float(profile.contact_query_native_us) / maxi(1, int(profile.contact_query_batch_count)),
		"mean_wall_us_per_batch": _mean(wall_samples), "mode": modes}

func _mean(values: Array) -> float:
	if values.is_empty(): return 0.0
	var total := 0.0
	for value in values: total += float(value)
	return total / values.size()

func _support_force(depth: float, surface_vy: float, contact_vy: float, parameters: Dictionary) -> float:
	if depth <= 0.0: return 0.0
	var equilibrium_depth := float(parameters.get("equilibrium_depth", 0.15))
	var damping_ratio := float(parameters.get("damping_ratio", 0.9))
	var mass := float(parameters.get("body_mass_kg", 1.0))
	var gravity := float(parameters.get("gravity_mps2", 9.8))
	var point_count := float(parameters.get("buoyancy_point_count", 4))
	var effective_mass := mass / point_count
	var spring := effective_mass * gravity / equilibrium_depth
	var damping := damping_ratio * 2.0 * sqrt(spring * effective_mass)
	return maxf(0.0, spring * depth - damping * (contact_vy - surface_vy) * clampf(depth / equilibrium_depth, 0.0, 1.0))

func _compare_bilinear_gradient_to_finite_difference(provider: Node, native: Object,
		groups: Array[Dictionary], resolutions: PackedInt32Array) -> Dictionary:
	var direct_vs_fd: Array[float] = []
	var full_cpu_vs_fd: Array[float] = []
	var query_count := 0
	for group: Dictionary in groups:
		if not bool(native.call("build_dynamic_physics_lite", float(group.time), resolutions)): continue
		var records: Array = group.rows
		var points := PackedVector3Array()
		for row: Dictionary in records:
			var p: Array = row.world_position
			points.append(Vector3(p[0], p[1], p[2]))
		var expanded := PackedVector3Array()
		for point in points:
			expanded.append(point)
			expanded.append(point + Vector3(NORMAL_EPSILON, 0.0, 0.0))
			expanded.append(point - Vector3(NORMAL_EPSILON, 0.0, 0.0))
			expanded.append(point + Vector3(0.0, 0.0, NORMAL_EPSILON))
			expanded.append(point - Vector3(0.0, 0.0, NORMAL_EPSILON))
		var samples: Array[WaterSample3D] = provider.call("sample_water_batch", expanded, PROVIDER.Backend.CPU_LITE_B)
		if samples.size() != expanded.size(): continue
		for index in points.size():
			var base := index * 5
			var center := samples[base]
			var dhx := (samples[base + 1].surface_position.y - samples[base + 2].surface_position.y) / (2.0 * NORMAL_EPSILON)
			var dhz := (samples[base + 3].surface_position.y - samples[base + 4].surface_position.y) / (2.0 * NORMAL_EPSILON)
			var finite_difference_normal := Vector3(-dhx, 1.0, -dhz).normalized()
			direct_vs_fd.append(rad_to_deg(center.normal.angle_to(finite_difference_normal)))
			var full_normal: Array = records[index].full_sample.normal
			var gpu_contract_normal := Vector3(full_normal[0], full_normal[1], full_normal[2])
			full_cpu_vs_fd.append(rad_to_deg(finite_difference_normal.angle_to(gpu_contract_normal)))
		query_count += points.size()
	return {"samples": query_count, "epsilon_m": NORMAL_EPSILON,
		"bilinear_gradient_vs_lite_centered_1cm_fd_deg": _absolute_stats(direct_vs_fd),
		"lite_centered_1cm_fd_vs_full_cpu_gpu_contract_deg": _absolute_stats(full_cpu_vs_fd),
		"interpretation": "Full CPU normal is the validated 1 cm centered heightfield operator used by GPU PHYSICAL_HEIGHTFIELD; the Lite direct normal is the exact gradient of its periodic bilinear field."}

func _validate_cubic_derivatives(native: Object, groups: Array[Dictionary]) -> Dictionary:
	const EPSILON := 0.001
	var dx_errors: Array[float] = []
	var dz_errors: Array[float] = []
	var normal_errors: Array[float] = []
	var checked := 0
	var resolutions := PackedInt32Array([128, 128, 128])
	var modes := PackedInt32Array([1, 1, 1])
	var stride := maxi(1, int(groups.size() / 8))
	for group_index in range(0, groups.size(), stride):
		var group: Dictionary = groups[group_index]
		if not bool(native.call("build_dynamic_physics_lite", float(group.time), resolutions)): continue
		var points := PackedVector3Array()
		for row: Dictionary in group.rows: points.append(_world_position(row))
		var base: PackedFloat64Array = native.call("sample_dynamic_lite_bands", points, modes)
		var expanded := PackedVector3Array()
		for point in points:
			expanded.append(point + Vector3(EPSILON, 0.0, 0.0))
			expanded.append(point - Vector3(EPSILON, 0.0, 0.0))
			expanded.append(point + Vector3(0.0, 0.0, EPSILON))
			expanded.append(point - Vector3(0.0, 0.0, EPSILON))
		var offsets: PackedFloat64Array = native.call("sample_dynamic_lite_bands", expanded, modes)
		if base.size() != 1 + points.size() * 13 or offsets.size() != 1 + expanded.size() * 13: continue
		for index in points.size():
			var row_offset := 1 + index * 13
			var analytic_dx := 0.0
			var analytic_dz := 0.0
			for band in 3:
				analytic_dx += base[row_offset + 3 + band * 4]
				analytic_dz += base[row_offset + 4 + band * 4]
			var ex := 1 + (index * 4) * 13
			var hx_plus := _sum_band_heights(offsets, ex)
			var hx_minus := _sum_band_heights(offsets, ex + 13)
			var hz_plus := _sum_band_heights(offsets, ex + 26)
			var hz_minus := _sum_band_heights(offsets, ex + 39)
			var finite_dx := (hx_plus - hx_minus) / (2.0 * EPSILON)
			var finite_dz := (hz_plus - hz_minus) / (2.0 * EPSILON)
			dx_errors.append(absf(analytic_dx - finite_dx))
			dz_errors.append(absf(analytic_dz - finite_dz))
			var analytic_normal := Vector3(-analytic_dx, 1.0, -analytic_dz).normalized()
			var finite_normal := Vector3(-finite_dx, 1.0, -finite_dz).normalized()
			normal_errors.append(rad_to_deg(analytic_normal.angle_to(finite_normal)))
			checked += 1
	return {"method": "periodic 4x4 Catmull-Rom analytic derivative vs centered finite difference of the same cubic height polynomial",
		"epsilon_m": EPSILON, "contacts": checked,
		"abs_dh_dx_error": _absolute_stats(dx_errors), "abs_dh_dz_error": _absolute_stats(dz_errors),
		"normal_angle_error_degrees": _absolute_stats(normal_errors)}

func _sum_band_heights(samples: PackedFloat64Array, offset: int) -> float:
	var height := 0.0
	for band in 3: height += samples[offset + 1 + band * 4]
	return height

func _world_position(row: Dictionary) -> Vector3:
	var p: Array = row.world_position
	return Vector3(float(p[0]), float(p[1]), float(p[2]))

func _fail(reason: String) -> void:
	printerr("PHYS_CPU_LITE_CONTACT_REPLAY_FAIL=" + reason)
	quit(1)
