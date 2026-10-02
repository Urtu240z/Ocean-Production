extends "res://validation/physics/phys_branch_boundary_runner.gd"
## Width experiments reconstruct unchanged dynamic FFT bands + retained bake.
## Micrometre diagnostics pass scalar doubles; Vector2 would round them away.
var _coverage: Dictionary

func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	_coverage = fft.call("get_phys3_coastal_snapshot")
	var states: Array = [{"name": "current", "bands": fft.call("get_phys2_band_spectrum_snapshots")}]
	for s in [["calm", 0.8, 4.0, 20.0, 0.8], ["storm", 3.0, 18.0, 75.0, 2.0]]:
		var configs: Array = PROFILE.build_fft_configs(s[1], s[2], s[3], 0.8, 1.0)
		configs[0].choppiness = s[4]
		var builder: Object = ClassDB.instantiate("OceanQueryNative")
		var state: Dictionary = SPECTRUM_STATE.build(configs, 1, s[1], PROFILE.combined_significant_wave_height_m(),
			1.0, [1.0, 1.0, 1.0], 1.0, 7, builder)
		states.append({"name": s[0], "bands": state.bands}); builder.call("clear")
	var edges: Array = []
	var internal: Array = []
	var internal_only := OS.get_cmdline_user_args().has("--internal-only")
	if OS.get_cmdline_user_args().has("--captures-only"): states.clear()
	for state in states:
		var native := _coverage_native(state.bands)
		if native == null: return
		for time in [0.36, 2.25, 16.89]:
			if not native.call("build_dynamic_physics_fields", time): _fail("coverage field build"); return
			if internal_only:
				internal.append(_measure_internal_masks(native, state.name, time))
			else:
				for width in [0.0, 1.0, 2.0, 4.0]:
					edges.append(_measure_edges(native, state.name, time, width))
			await process_frame
		native.call("clear")
	var captures: Array = []
	for name in DirAccess.get_files_at("res://.godot"):
		if internal_only: break
		if not name.begins_with("branch_failure_") or not name.ends_with(".bin"): continue
		var f := FileAccess.open("res://.godot/" + name, FileAccess.READ); var cap: Dictionary = f.get_var(); f.close()
		var native := _coverage_native(cap.bands)
		var time: float = cap.bands[0].wave_time
		if not native.call("build_dynamic_physics_fields", time): _fail("capture build"); return
		for i in 4:
			if cap.rows[i * CS] > 0.5: continue
			var w: Vector3 = cap.targets[i]
			var row := {"file": name, "time": time, "world": [w.x, w.z], "widths": []}
			for width in [0.0, 1.0, 2.0, 4.0]:
				var seed_x: float = cap.history[i * CS + QX]; var seed_z: float = cap.history[i * CS + QZ]
				if cap.history[i * CS] <= 0.5: seed_x = w.x; seed_z = w.z
				var solved := _candidate_newton(native, w.x, w.z, seed_x, seed_z, width)
				row.widths.append({"width": width, "root": solved, "accepted": solved[0] <= 0.001})
			captures.append(row)
		native.call("clear")
	var out := {"field_resolution": _coverage.field_resolution, "field_extent": _coverage.field_extent,
		"cell_spacing": _coverage.field_extent / Vector2(_coverage.field_resolution - Vector2i.ONE),
		"edges": edges, "internal_masks": internal, "captures": captures,
		"capture_note": "Optional local CPU failure captures; not required for the four-edge width sweep.",
		"build_id": preload("res://validation/physics/phys_native_build_contract.gd").ID}
	out.geometry_checks_passed = _geometry_checks(edges, internal, captures)
	var output := "phys_coastal_coverage_captures.json" if states.is_empty() else "phys_coastal_coverage.json"
	if internal_only: output = "phys_coastal_coverage_internal.json"
	var file := FileAccess.open("res://.godot/" + output, FileAccess.WRITE)
	file.store_string(JSON.stringify(out, "\t")); file.close()
	print("COASTAL_COVERAGE_COMPLETE=" + JSON.stringify({"edge_packets": edges.size(), "captures": captures.size(), "passed": out.geometry_checks_passed}))
	if not out.geometry_checks_passed: _fail("coverage continuity/replay check"); return
	quit(0)

func _geometry_checks(edges: Array, internal: Array, captures: Array) -> bool:
	# Test convergence, not a larger replacement for the unchanged 1 mm root gate.
	# Reducing diagnostic separation by 100x must reduce the position difference.
	for packet in edges:
		if packet.width != 1.0: continue
		for edge in packet.edges.values():
			var gap: Dictionary = edge.displacement_gap_by_epsilon
			if gap["0.000001"].max > gap["0.0001"].max * 0.02: return false
	for packet in internal:
		for source in packet.sources.values():
			if source.tested == 0: continue
			var gap: Dictionary = source.displacement_gap_by_epsilon
			if gap["0.000001"].max > gap["0.0001"].max * 0.02: return false
			if not source.unchanged_interior.is_empty() and source.unchanged_interior.max != 0.0: return false
	for capture in captures:
		for candidate in capture.widths:
			if candidate.width == 1.0 and not candidate.accepted: return false
	return true

func _measure_internal_masks(native: Object, state: String, time: float) -> Dictionary:
	var result := {"state": state, "time": time, "sources": {}}
	for source in ["field", "warp"]:
		var size: Vector2i = _coverage[source + "_resolution"]
		var origin: Vector2 = _coverage[source + "_origin"]
		var extent: Vector2 = _coverage[source + "_extent"]
		var mask: PackedByteArray = _coverage[source + "_valid"]
		var transitions: Array = []
		for y in range(1, size.y - 2):
			for x in range(1, size.x - 2):
				var index := y * size.x + x
				if mask[index] != mask[index + 1]: transitions.append([x + 1.0, y + 0.5, 1.0, 0.0])
				if mask[index] != mask[index + size.x]: transitions.append([x + 0.5, y + 1.0, 0.0, 1.0])
		var gaps := {"0.001": [], "0.0001": [], "0.000001": []}
		var interior_deltas: Array = []
		var count: int = mini(128, transitions.size())
		for i in count:
			var p: Array = transitions[(i * transitions.size()) / count]
			var x: float = float(origin.x) + float(extent.x) * p[0] / size.x
			var z: float = float(origin.y) + float(extent.y) * p[1] / size.y
			for epsilon in [0.001, 0.0001, 0.000001]:
				gaps[str(epsilon)].append(_distance(
					_candidate_position(native, x - p[2] * epsilon, z - p[3] * epsilon, 1.0),
					_candidate_position(native, x + p[2] * epsilon, z + p[3] * epsilon, 1.0)))
			var weight: PackedFloat64Array = native.call("sample_coastal_bake", x, z, 1.0)
			if weight[7] == 1.0:
				interior_deltas.append(_distance(_candidate_position(native, x, z, 0.0), _candidate_position(native, x, z, 1.0)))
		for key in gaps: gaps[key] = _metrics(gaps[key])
		result.sources[source] = {"adjacent_mask_transitions": transitions.size(), "tested": count,
			"displacement_gap_by_epsilon": gaps, "unchanged_interior": _metrics(interior_deltas)}
	return result

func _coverage_native(bands: Array) -> Object:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if not native.has_method("sample_coastal_bake") or not native.call("prepare_production_spectrum", bands):
		_fail("coverage native source/build"); return null
	native.call("set_dynamic_worker_count", 4)
	if not ADAPTER.configure_coastal(native, _coverage).ok: _fail("coverage bake"); return null
	return native

func _candidate_position(native: Object, x: float, z: float, width: float) -> Array:
	var bake: PackedFloat64Array = native.call("sample_coastal_bake", x, z, width)
	var a: PackedFloat64Array = native.call("sample_dynamic_band_material_q", 0, x, z)
	var deep := a
	if bake[6] > 0.0: deep = native.call("sample_dynamic_band_material_q", 0, bake[2], bake[3])
	var mid: PackedFloat64Array = native.call("sample_dynamic_band_material_q", 1, x, z)
	var short: PackedFloat64Array = native.call("sample_dynamic_band_material_q", 2, x, z)
	var result: Array = []
	for field in [1, 0, 2, 10, 9, 11]:
		var value: float = lerpf(a[field], deep[field], bake[6])
		if field in [0, 9]: value *= lerpf(1.0, bake[0], bake[6])
		result.append(value + mid[field] + short[field])
	return result

func _distance(a: Array, b: Array, first: int = 0) -> float:
	return sqrt(pow(a[first] - b[first], 2) + pow(a[first + 1] - b[first + 1], 2) + pow(a[first + 2] - b[first + 2], 2))

func _measure_edges(native: Object, state: String, time: float, width: float) -> Dictionary:
	var origin: Vector2 = _coverage.field_origin; var extent: Vector2 = _coverage.field_extent
	var dx: Vector2 = extent / Vector2(_coverage.field_resolution - Vector2i.ONE)
	var result := {"state": state, "time": time, "width": width, "edges": {}}
	for edge in 4:
		var gaps := {}; var deltas: Array = []; var slope_jumps: Array = []; var normal_jumps: Array = []
		var determinant_jumps: Array = []; var determinants: Array = []; var velocity_gaps: Array = []
		var native_normal_error: Array = []; var native_position_error: Array = []
		for epsilon in [0.01, 0.001, 0.0001, 0.000001]: gaps[str(epsilon)] = []
		for i in 65:
			var x: float = origin.x + extent.x * (i / 64.0)
			var z: float = origin.y + extent.y * (i / 64.0)
			var nx := 0.0; var nz := 0.0
			if edge == 0: x = origin.x; nx = 1.0
			elif edge == 1: x = float(origin.x) + float(extent.x); nx = -1.0
			elif edge == 2: z = origin.y; nz = 1.0
			else: z = float(origin.y) + float(extent.y); nz = -1.0
			for epsilon in [0.01, 0.001, 0.0001, 0.000001]:
				var a := _candidate_position(native, x - nx * epsilon, z - nz * epsilon, width)
				var b := _candidate_position(native, x + nx * epsilon, z + nz * epsilon, width)
				gaps[str(epsilon)].append(_distance(a, b))
				if epsilon == 0.000001: velocity_gaps.append(_distance(a, b, 3))
			var e := 0.0001
			var a0 := _candidate_position(native, x, z, width)
			var am := _candidate_position(native, x - nx * e, z - nz * e, width)
			var ap := _candidate_position(native, x + nx * e, z + nz * e, width)
			var slopes: Array = []
			for k in 3: slopes.append((ap[k] + am[k] - 2.0 * a0[k]) / e)
			slope_jumps.append(sqrt(pow(slopes[0], 2) + pow(slopes[1], 2) + pow(slopes[2], 2)))
			var outside := _candidate_properties(native, x - nx * 0.000001, z - nz * 0.000001, width)
			var inside := _candidate_properties(native, x + nx * 0.000001, z + nz * 0.000001, width)
			normal_jumps.append((outside.normal - inside.normal).length())
			determinant_jumps.append(absf(outside.det - inside.det))
			var inside_distance: float = (dx.x if nx != 0.0 else dx.y) * maxf(width, 1.0)
			for step in 17:
				var px: float = x + nx * inside_distance * step / 16.0
				var pz: float = z + nz * inside_distance * step / 16.0
				deltas.append(_distance(_candidate_position(native, px, pz, width), _candidate_position(native, px, pz, 0.0)))
				if step % 4 == 0:
					var props := _candidate_properties(native, px, pz, width); determinants.append(props.det)
					if width == 1.0:
						var actual: PackedFloat64Array = native.call("sample_dynamic_material_q", px, pz)
						native_normal_error.append((Vector3(actual[5], actual[6], actual[7]) - props.normal).length())
						native_position_error.append(_distance([actual[2], actual[3], actual[4]], _candidate_position(native, px, pz, width)))
		for key in gaps: gaps[key] = _metrics(gaps[key])
		result.edges[["left", "right", "top", "bottom"][edge]] = {"displacement_gap_by_epsilon": gaps,
			"velocity_gap_1um": _metrics(velocity_gaps), "slope_one_sided_difference_100um": _metrics(slope_jumps),
			"difference_from_old_inside_zone": _metrics(deltas), "normal_gap_1um": _metrics(normal_jumps),
			"determinant_gap_1um": _metrics(determinant_jumps), "determinant_min": determinants.min(), "determinant_max": determinants.max(),
			"native_normal_reconstruction_error": _metrics(native_normal_error), "native_position_reconstruction_error": _metrics(native_position_error)}
	return result

func _candidate_properties(native: Object, x: float, z: float, width: float) -> Dictionary:
	var e := 0.01 # Existing final physical derivative contract, unchanged.
	var xp := _candidate_position(native, x + e, z, width); var xm := _candidate_position(native, x - e, z, width)
	var zp := _candidate_position(native, x, z + e, width); var zm := _candidate_position(native, x, z - e, width)
	var tx := Vector3(1.0 + (xp[0] - xm[0]) / (2 * e), (xp[1] - xm[1]) / (2 * e), (xp[2] - xm[2]) / (2 * e))
	var tz := Vector3((zp[0] - zm[0]) / (2 * e), (zp[1] - zm[1]) / (2 * e), 1.0 + (zp[2] - zm[2]) / (2 * e))
	var normal := tz.cross(tx).normalized()
	if normal.y < 0.0: normal = -normal # Existing native upward-normal policy, including folds.
	return {"normal": normal, "det": float(tx.x) * float(tz.z) - float(tz.x) * float(tx.z)}

func _candidate_newton(native: Object, wx: float, wz: float, x: float, z: float, width: float) -> Array:
	var residual := INF
	for iteration in 40:
		var a := _candidate_position(native, x, z, width)
		var rx: float = x + a[0] - wx; var rz: float = z + a[2] - wz
		residual = sqrt(rx * rx + rz * rz)
		if residual < 0.000001: return [residual, x, z, iteration]
		var e := 0.0003125
		var xp := _candidate_position(native, x + e, z, width); var xm := _candidate_position(native, x - e, z, width)
		var zp := _candidate_position(native, x, z + e, width); var zm := _candidate_position(native, x, z - e, width)
		var j00: float = 1.0 + (xp[0] - xm[0]) / (2 * e); var j01: float = (zp[0] - zm[0]) / (2 * e)
		var j10: float = (xp[2] - xm[2]) / (2 * e); var j11: float = 1.0 + (zp[2] - zm[2]) / (2 * e)
		var det: float = j00 * j11 - j01 * j10
		if absf(det) < 1e-10: break
		var sx: float = (j11 * rx - j01 * rz) / det; var sz: float = (-j10 * rx + j00 * rz) / det
		var scale: float = minf(1.0, 0.1 / maxf(0.1, sqrt(sx * sx + sz * sz)))
		var accepted := false
		for _k in 16:
			var tx: float = x - sx * scale; var tz: float = z - sz * scale
			var b := _candidate_position(native, tx, tz, width)
			if sqrt(pow(tx + b[0] - wx, 2) + pow(tz + b[2] - wz, 2)) < residual:
				x = tx; z = tz; accepted = true; break
			scale *= 0.5
		if not accepted: break
	return [residual, x, z, 40]
