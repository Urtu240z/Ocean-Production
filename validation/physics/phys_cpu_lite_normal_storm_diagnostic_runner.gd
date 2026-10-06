extends SceneTree

## Focused paired-contact attribution and local cubic-overshoot inspection for Normal/Storm.
const WORLD := preload("res://gameplay/jet_ski_ocean.tscn")
const PROVIDER := preload("res://gameplay/water/cpu_fft_water_provider.gd")
const LITE_128 := [128, 128, 128]
const LITE_256 := [256, 128, 128]
const BILINEAR := [0, 0, 0]
const CUBIC := [1, 1, 1]
const DOMAIN_M := [512.0, 137.0, 37.0]
const DENSE_CELL_STEPS := 8
var _world: Node

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var state := "storm" if OS.get_cmdline_user_args().has("--state=storm") else "normal"
	var trace_path := "res://.godot/phys_cpu_lite_contact_trace_%s.json" % state
	if not FileAccess.file_exists(trace_path): _fail("missing trace " + trace_path); return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(trace_path))
	if not parsed is Dictionary: _fail("invalid trace"); return
	var trace: Dictionary = parsed
	var groups := _group_rows(trace.get("rows", []))
	_world = WORLD.instantiate()
	_world.validation_sea_state = 2 if state == "storm" else 1
	_world.physics_water_backend = 1
	_world.compare_cpu_backends = false
	_world.contact_debug = false
	_world.follow_camera = false
	root.add_child(_world)
	for _frame in 360:
		await process_frame
		if bool(_world.get("ready_to_drive")): break
	if not bool(_world.get("ready_to_drive")): _fail("provider failed to initialize"); return
	_world.get("ski").freeze = true
	var provider: Node = _world.get_node("PhysicalWater")
	provider.set("wave_time_rate", 1.0)
	var native: Object = provider.get("native")
	var errors := {"height": [], "vertical_velocity": [], "normal": []}
	var paired := {"height_cubic_better": 0, "height_256_better": 0,
		"vertical_velocity_cubic_better": 0, "vertical_velocity_256_better": 0,
		"normal_cubic_better": 0, "normal_256_better": 0}
	var slope_rows: Array[Dictionary] = []
	var velocity_time_rows: Array[Dictionary] = []
	var worst := {"height": [], "vertical_velocity": [], "normal": []}
	var contact_count := 0
	for group: Dictionary in groups:
		var positions := _positions(group.rows)
		var time := float(group.time)
		if not bool(native.call("build_dynamic_physics_lite", time, PackedInt32Array(LITE_128))):
			_fail("128 field build failed"); return
		var cubic: Array[WaterSample3D] = provider.call("sample_water_batch", positions,
			PROVIDER.Backend.CPU_LITE_B, PackedInt32Array(CUBIC))
		if not bool(native.call("build_dynamic_physics_lite", time, PackedInt32Array(LITE_256))):
			_fail("256 field build failed"); return
		var dense: Array[WaterSample3D] = provider.call("sample_water_batch", positions,
			PROVIDER.Backend.CPU_LITE_B, PackedInt32Array(BILINEAR))
		if cubic.size() != positions.size() or dense.size() != positions.size():
			_fail("candidate batch returned wrong count"); return
		for i in positions.size():
			var record: Dictionary = group.rows[i]
			var full: Dictionary = record.full_sample
			var full_normal := _vec3(full.normal)
			var cubic_sample: WaterSample3D = cubic[i]
			var dense_sample: WaterSample3D = dense[i]
			var full_height := float(full.surface_y)
			var full_vy := float(full.vertical_velocity)
			var e := {
				"state": state, "tick": int(group.tick), "time": time, "contact_index": i,
				"scenario": String(group.scenario), "position": [positions[i].x, positions[i].z],
				"height_cubic": absf(cubic_sample.surface_position.y - full_height),
				"height_256": absf(dense_sample.surface_position.y - full_height),
				"vy_cubic": absf(cubic_sample.velocity.y - full_vy),
				"vy_256": absf(dense_sample.velocity.y - full_vy),
				"normal_cubic": rad_to_deg(cubic_sample.normal.angle_to(full_normal)),
				"normal_256": rad_to_deg(dense_sample.normal.angle_to(full_normal)),
				"full_slope": sqrt(full_normal.x * full_normal.x + full_normal.z * full_normal.z) / maxf(1.0e-6, full_normal.y),
				"full": {"height": full_height, "vertical_velocity": full_vy,
					"normal": [full_normal.x, full_normal.y, full_normal.z]},
				"cubic": _sample_dict(cubic_sample), "bilinear_256": _sample_dict(dense_sample),
				"world_position": [positions[i].x, positions[i].y, positions[i].z]}
			for metric in ["height", "vertical_velocity", "normal"]:
				var error_key: String = "vy" if metric == "vertical_velocity" else metric
				var cubic_error := float(e[error_key + "_cubic"])
				var dense_error := float(e[error_key + "_256"])
				errors[metric].append(cubic_error)
				paired[metric + "_cubic_better" if cubic_error < dense_error else metric + "_256_better"] += 1
				var candidate: Dictionary = e.duplicate(true)
				candidate["score"] = cubic_error
				candidate["worst_metric"] = metric
				worst[metric].append(candidate)
			slope_rows.append({"slope": float(e.full_slope), "cubic_normal": float(e.normal_cubic),
				"normal_256": float(e.normal_256), "cubic_height": float(e.height_cubic),
				"cubic_vy": float(e.vy_cubic)})
			velocity_time_rows.append({"contact_index": i, "tick": int(group.tick), "time": time,
				"full_vy": full_vy, "cubic_error": float(e.vy_cubic), "n256_error": float(e.vy_256)})
			contact_count += 1
	for metric in worst:
		(worst[metric] as Array).sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.score) > float(b.score))
	var worst_unique: Dictionary = {}
	for metric in worst:
		for i in mini(3, worst[metric].size()):
			var row: Dictionary = worst[metric][i]
			var key := "%s:%d:%d" % [row.state, row.tick, row.contact_index]
			if not worst_unique.has(key): worst_unique[key] = row
	var selected_cases: Array = worst_unique.values()
	var context: Array[Dictionary] = []
	for case: Dictionary in selected_cases:
		var point := Vector3(case.world_position[0], case.world_position[1], case.world_position[2])
		var details := await _inspect_contact(native, float(case.time), point, case)
		context.append(details)
	var slopes := slope_rows.duplicate()
	slopes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.slope) > float(b.slope))
	var top_slope_count := maxi(1, ceili(slopes.size() * 0.10))
	var top_slope := slopes.slice(0, top_slope_count)
	var lower_slope := slopes.slice(top_slope_count)
	velocity_time_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.contact_index) == int(b.contact_index): return float(a.time) < float(b.time)
		return int(a.contact_index) < int(b.contact_index))
	var velocity_gradient_rows: Array[Dictionary] = []
	var previous_by_contact: Dictionary = {}
	for row: Dictionary in velocity_time_rows:
		var contact_index := int(row.contact_index)
		if previous_by_contact.has(contact_index):
			var previous: Dictionary = previous_by_contact[contact_index]
			var dt := float(row.time) - float(previous.time)
			if dt > 0.0:
				velocity_gradient_rows.append({"gradient": absf(float(row.full_vy) - float(previous.full_vy)) / dt,
					"cubic_error": row.cubic_error, "n256_error": row.n256_error})
		previous_by_contact[contact_index] = row
	velocity_gradient_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.gradient) > float(b.gradient))
	var fast_vy_count := maxi(1, ceili(velocity_gradient_rows.size() * 0.10))
	var high_vy_change := velocity_gradient_rows.slice(0, fast_vy_count)
	var lower_vy_change := velocity_gradient_rows.slice(fast_vy_count)
	var output := {"status": "CAPTURED_REVIEW_REQUIRED", "state": state,
		"trace_contacts": contact_count, "paired_error_stats": {}, "paired_better_counts": paired,
		"slope_bucket_p90": {"contacts": top_slope.size(), "cubic_normal_error_degrees": _stats(top_slope, "cubic_normal"),
			"normal_256_error_degrees": _stats(top_slope, "normal_256"), "cubic_height_error_m": _stats(top_slope, "cubic_height"),
			"cubic_vy_error_mps": _stats(top_slope, "cubic_vy")},
		"lower_90_percent_slope": {"contacts": lower_slope.size(), "cubic_normal_error_degrees": _stats(lower_slope, "cubic_normal"),
			"normal_256_error_degrees": _stats(lower_slope, "normal_256"), "cubic_height_error_m": _stats(lower_slope, "cubic_height"),
			"cubic_vy_error_mps": _stats(lower_slope, "cubic_vy")}, "worst_contacts": context}
	output["encountered_vy_change_rate_top_decile"] = {"metric": "absolute change in Full CPU sampled VY for the same contact slot over adjacent trace ticks, divided by dt; includes the craft's movement through the field",
		"contacts": high_vy_change.size(), "cubic_vy_error_mps": _stats(high_vy_change, "cubic_error"),
		"bilinear_256_vy_error_mps": _stats(high_vy_change, "n256_error")}
	output["encountered_vy_change_rate_lower_90_percent"] = {"contacts": lower_vy_change.size(),
		"cubic_vy_error_mps": _stats(lower_vy_change, "cubic_error"),
		"bilinear_256_vy_error_mps": _stats(lower_vy_change, "n256_error")}
	for metric in errors: output.paired_error_stats[metric] = _stats_values(errors[metric])
	var file := FileAccess.open("res://validation/physics/results/phys_cpu_lite_extrema_%s.json" % state, FileAccess.WRITE)
	if file == null: _fail("could not write extrema report"); return
	file.store_string(JSON.stringify(output, "\t")); file.close()
	print("PHYS_CPU_LITE_EXTREMA=res://validation/physics/results/phys_cpu_lite_extrema_%s.json" % state)
	quit(0)

func _inspect_contact(native: Object, time: float, point: Vector3, case: Dictionary) -> Dictionary:
	if not bool(native.call("build_dynamic_physics_fields", time)):
		return {"case": case, "error": "full direct field build failed"}
	if not bool(native.call("build_dynamic_physics_lite", time, PackedInt32Array(LITE_128))):
		return {"case": case, "error": "lite field build failed"}
	var bands: Array = []
	for band in 3:
		var full: PackedFloat64Array = native.call("sample_dynamic_spectrum_oracle", band, point.x, point.z, false)
		var cubic: PackedFloat64Array = native.call("sample_dynamic_lite_surface", band, point.x, point.z, 0.0, 1)
		var bilinear: PackedFloat64Array = native.call("sample_dynamic_lite_surface", band, point.x, point.z, 0.0, 0)
		var d := _grid_detail(point.x, point.z, DOMAIN_M[band], 128)
		var stencil := _sample_stencil(native, band, DOMAIN_M[band], d)
		var range_scan := _scan_cell(native, band, time, DOMAIN_M[band], d)
		bands.append({"band": ["LONG", "MID", "SHORT"][band], "domain_m": DOMAIN_M[band],
			"cell_fraction_xz": [d.fx, d.fz], "full_direct": _four(full),
			"cubic": _surface_dict(cubic), "bilinear": _surface_dict(bilinear),
			"cubic_vs_full_height_m": cubic[0] - full[0], "cubic_vs_full_vy_mps": cubic[1] - full[1],
			"stencil_4x4_height_vy": stencil, "cell_9x9_range": range_scan})
	return {"case": case, "bands": bands}

func _grid_detail(x: float, z: float, domain: float, n: int) -> Dictionary:
	var dx := domain / n
	var offset := domain * 0.5 - dx * 0.5
	var gx := fposmod(x + offset, domain) / dx
	var gz := fposmod(z + offset, domain) / dx
	var ix := int(floor(gx)); var iz := int(floor(gz))
	return {"dx": dx, "offset": offset, "ix": ix % n, "iz": iz % n,
		"fx": gx - floor(gx), "fz": gz - floor(gz), "x0": ix * dx - offset,
		"z0": iz * dx - offset, "n": n}

func _sample_stencil(native: Object, band: int, domain: float, d: Dictionary) -> Array:
	var matrix: Array = []
	for row in 4:
		var samples: Array = []
		var iz := posmod(int(d.iz) + row - 1, int(d.n))
		var z := iz * float(d.dx) - float(d.offset)
		for col in 4:
			var ix := posmod(int(d.ix) + col - 1, int(d.n))
			var x := ix * float(d.dx) - float(d.offset)
			var sample: PackedFloat64Array = native.call("sample_dynamic_lite_surface", band, x, z, 0.0, 0)
			samples.append({"h": sample[0], "vy": sample[1]})
		matrix.append(samples)
	return matrix

func _scan_cell(native: Object, band: int, time: float, domain: float, d: Dictionary) -> Dictionary:
	var positions := PackedVector3Array()
	for iz in DENSE_CELL_STEPS + 1:
		for ix in DENSE_CELL_STEPS + 1:
			positions.append(Vector3(float(d.x0) + float(d.dx) * ix / DENSE_CELL_STEPS, 0.0,
				float(d.z0) + float(d.dx) * iz / DENSE_CELL_STEPS))
	var full: Array[float] = []
	var full_vy: Array[float] = []
	var full_h_min_uv := Vector2.ZERO; var full_h_max_uv := Vector2.ZERO
	var full_vy_min_uv := Vector2.ZERO; var full_vy_max_uv := Vector2.ZERO
	var full_h_min := INF; var full_h_max := -INF
	var full_vy_min := INF; var full_vy_max := -INF
	var grid_cubic: Array[float] = []
	var grid_cubic_vy: Array[float] = []
	var grid_bilinear: Array[float] = []
	var grid_bilinear_vy: Array[float] = []
	for sample_index in positions.size():
		var point: Vector3 = positions[sample_index]
		var reference: PackedFloat64Array = native.call("sample_dynamic_spectrum_oracle", band, point.x, point.z, false)
		var c: PackedFloat64Array = native.call("sample_dynamic_lite_surface", band, point.x, point.z, 0.0, 1)
		var b: PackedFloat64Array = native.call("sample_dynamic_lite_surface", band, point.x, point.z, 0.0, 0)
		full.append(reference[0]); full_vy.append(reference[1])
		var uv := Vector2(float(sample_index % (DENSE_CELL_STEPS + 1)) / DENSE_CELL_STEPS,
			float(sample_index / (DENSE_CELL_STEPS + 1)) / DENSE_CELL_STEPS)
		if reference[0] < full_h_min: full_h_min = reference[0]; full_h_min_uv = uv
		if reference[0] > full_h_max: full_h_max = reference[0]; full_h_max_uv = uv
		if reference[1] < full_vy_min: full_vy_min = reference[1]; full_vy_min_uv = uv
		if reference[1] > full_vy_max: full_vy_max = reference[1]; full_vy_max_uv = uv
		grid_cubic.append(c[0]); grid_cubic_vy.append(c[1])
		grid_bilinear.append(b[0]); grid_bilinear_vy.append(b[1])
	return {"samples": positions.size(), "full_h_minmax": _minmax(full), "cubic_h_minmax": _minmax(grid_cubic),
		"bilinear_h_minmax": _minmax(grid_bilinear), "full_vy_minmax": _minmax(full_vy),
		"full_h_min_uv": [full_h_min_uv.x, full_h_min_uv.y], "full_h_max_uv": [full_h_max_uv.x, full_h_max_uv.y],
		"full_vy_min_uv": [full_vy_min_uv.x, full_vy_min_uv.y], "full_vy_max_uv": [full_vy_max_uv.x, full_vy_max_uv.y],
		"cubic_vy_minmax": _minmax(grid_cubic_vy), "bilinear_vy_minmax": _minmax(grid_bilinear_vy),
		"cubic_h_outside_full_range_m": _outside_range(_minmax(grid_cubic), _minmax(full)),
		"cubic_vy_outside_full_range_mps": _outside_range(_minmax(grid_cubic_vy), _minmax(full_vy))}

func _outside_range(candidate: Dictionary, reference: Dictionary) -> Dictionary:
	return {"below": maxf(0.0, float(reference.min) - float(candidate.min)),
		"above": maxf(0.0, float(candidate.max) - float(reference.max))}

func _minmax(values: Array[float]) -> Dictionary:
	var low := INF; var high := -INF
	for value in values: low = minf(low, value); high = maxf(high, value)
	return {"min": low, "max": high}

func _positions(rows: Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for row: Dictionary in rows:
		var p: Array = row.world_position
		result.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	return result

func _sample_dict(sample: WaterSample3D) -> Dictionary:
	return {"height": sample.surface_position.y, "vy": sample.velocity.y,
		"normal": [sample.normal.x, sample.normal.y, sample.normal.z]}

func _surface_dict(sample: PackedFloat64Array) -> Dictionary:
	return {"height": sample[0], "vy": sample[1], "normal": [sample[2], sample[3], sample[4]],
		"gradient_x": -sample[2] / sample[3], "gradient_z": -sample[4] / sample[3]}

func _four(values: PackedFloat64Array) -> Dictionary:
	return {"height": values[0], "vy": values[1], "gradient_x": values[2], "gradient_z": values[3]}

func _vec3(values: Array) -> Vector3:
	return Vector3(float(values[0]), float(values[1]), float(values[2]))

func _group_rows(rows: Array) -> Array[Dictionary]:
	var by_tick: Dictionary = {}; var groups: Array[Dictionary] = []
	for row: Dictionary in rows:
		var tick := int(row.tick)
		if not by_tick.has(tick):
			by_tick[tick] = {"tick": tick, "time": float(row.simulation_time), "scenario": String(row.scenario), "rows": []}
			groups.append(by_tick[tick])
		by_tick[tick].rows.append(row)
	return groups

func _stats_values(source: Array) -> Dictionary:
	if source.is_empty(): return {"count": 0}
	var sorted: Array[float] = []
	var total := 0.0; var squares := 0.0
	for value in source:
		sorted.append(absf(float(value))); total += absf(float(value)); squares += float(value) * float(value)
	sorted.sort()
	return {"count": sorted.size(), "mean": total / sorted.size(), "p95": sorted[ceili(sorted.size() * 0.95) - 1], "max": sorted.back()}

func _stats(rows: Array, key: String) -> Dictionary:
	var values: Array = []
	for row in rows: values.append(row[key])
	return _stats_values(values)

func _fail(message: String) -> void:
	printerr("PHYS_CPU_LITE_NORMAL_STORM_DIAGNOSTIC_FAIL=" + message)
	quit(1)
