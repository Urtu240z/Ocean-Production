extends "res://validation/physics/phys_weather_velocity_runner.gd"
## Real Production spectra/bake; all contacts own their rows explicitly.
const CS := 27
const QX := 15
const QZ := 16
const STATUS := 17
const WT := 20
const DET := 25
var _trace: Array = []

func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var coastal: Dictionary = fft.call("get_phys3_coastal_snapshot")
	var states: Array = []
	for s in [[0.8, 4.0, 20.0, 0.8], [3.0, 18.0, 75.0, 2.0], [3.0, 18.0, 20.0, 2.0]]:
		var configs: Array = PROFILE.build_fft_configs(s[0], s[1], s[2], 0.8, 1.0)
		configs[0].choppiness = s[3]
		var builder: Object = ClassDB.instantiate("OceanQueryNative")
		var state: Dictionary = SPECTRUM_STATE.build(configs, 1, s[0], PROFILE.combined_significant_wave_height_m(),
			1.0, [1.0, 1.0, 1.0], 1.0, 7, builder)
		if state.is_empty() or not builder.call("prepare_production_spectrum", state.bands): _fail("branch endpoint preparation"); return
		state.native = builder; states.append(state)
	var native := _new_mirror(states[1].bands, coastal, 2.25)
	if native == null: return
	_make_points(coastal)
	var roots := _find_roots(native, coastal)
	if roots.is_empty(): _fail("no real multi-root case discovered"); return
	print("BRANCH_ROOTS=" + JSON.stringify(roots))
	var frozen_a := _frozen_branch(native, roots.a, roots.target, "A")
	var frozen_b := _frozen_branch(native, roots.b, roots.target, "B")
	var local := _local_probe(native, roots)
	var performance := _bench_contacts(native, roots)
	var lifecycle := _lifecycle(native, roots)
	var ownership := _batch_ownership(native, roots)
	var report := {"build_id": preload("res://validation/physics/phys_native_build_contract.gd").ID,
		"roots": roots, "frozen_A": frozen_a, "frozen_B": frozen_b,
		"local_probe": local, "performance": performance, "lifecycle": lifecycle, "batch_ownership": ownership}
	var passed: bool = frozen_a.failed == 0 and frozen_b.failed == 0 and frozen_a.jumps == 0 and frozen_b.jumps == 0 and lifecycle.passed and ownership.passed
	if not OS.get_cmdline_user_args().has("--smoke"):
		report.trajectories = await _trajectories(native, states, coastal, roots)
		passed = passed and report.trajectories.passed
	report.passed = passed
	var file := FileAccess.open("res://.godot/phys_branch_continuity.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t")); file.close()
	var trace_file := FileAccess.open("res://.godot/phys_branch_trace.json", FileAccess.WRITE)
	trace_file.store_string(JSON.stringify(_trace)); trace_file.close()
	native.call("clear")
	print("PHYS_BRANCH_COMPLETE=" + JSON.stringify(report)); quit(0 if passed else 1)

func _world(native: Object, q: Vector2) -> Vector2:
	var a: PackedFloat64Array = native.call("sample_dynamic_material_q", q.x, q.y)
	return q + Vector2(a[2], a[4])

func _state_at(native: Object, q: Vector2, target: Vector2) -> PackedFloat64Array:
	var a: PackedFloat64Array = native.call("sample_dynamic_material_q", q.x, q.y)
	var row := PackedFloat64Array(); row.resize(CS)
	for i in 15: row[i] = a[i]
	row[QX] = q.x; row[QZ] = q.y; row[18] = target.x; row[19] = target.y; row[DET] = a[11]
	var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	row[WT] = info[1] / 1e9; row[21] = info[3]; row[22] = info[2]
	return row

func _find_roots(native: Object, coastal: Dictionary) -> Dictionary:
	# Known prior source point plus actual bake coverage, then negative-det nodes.
	var candidates := PackedVector3Array([Vector3(37.13506, 0, 81.04028)])
	candidates.append_array(_points)
	for iz in 32:
		for ix in 32:
			var q: Vector2 = coastal.field_origin + coastal.field_extent * Vector2((ix + 0.5) / 32.0, (iz + 0.5) / 32.0)
			candidates.append(Vector3(q.x, 0, q.y))
	var values: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", candidates)
	for i in candidates.size():
		if i > _points.size() and values[i * 15 + 11] > 0.0: continue
		var q := Vector2(candidates[i].x, candidates[i].z)
		var target := q + Vector2(values[i * 15 + 2], values[i * 15 + 4])
		for radius in [0.05, 0.15, 0.3, 0.6, 1.2, 2.4]:
			for j in 12:
				var seed: Vector2 = q + Vector2.from_angle(j * TAU / 12.0) * radius
				var r: PackedFloat64Array = native.call("sample_dynamic_world", target.x, target.y, seed.x, seed.y, true)
				if r[0] < 0.5: continue
				var root_q := Vector2(r[15], r[16])
				if root_q.distance_to(q) > 0.12:
					return {"a": [q.x, q.y], "b": [root_q.x, root_q.y], "target": [target.x, target.y],
						"separation": q.distance_to(root_q), "residual_a": 0.0, "residual_b": r[13],
						"det_a": values[i * 15 + 11], "det_b": r[11], "seed": [seed.x, seed.y]}
	return {}

func _vec(a: Array) -> Vector2: return Vector2(a[0], a[1])

func _lifecycle(native: Object, roots: Dictionary) -> Dictionary:
	var w := _vec(roots.target)
	var cold: PackedFloat64Array = native.call("sample_dynamic_contact", w.x, w.y, PackedFloat64Array())
	var invalid := preload("res://addons/ocean/physics/dynamic_ocean_contact_contract.gd").invalidate(cold, 0)
	var reentry: PackedFloat64Array = native.call("sample_dynamic_contact", w.x, w.y, invalid)
	var failed: PackedFloat64Array = native.call("sample_dynamic_contact", NAN, w.y, reentry)
	return {"cold_status": cold[STATUS], "reentry_status": reentry[STATUS], "invalid_target_status": failed[STATUS],
		"passed": cold[STATUS] == 2 and reentry[STATUS] == 2 and failed[STATUS] == 3 and failed[0] == 0}

func _batch_ownership(native: Object, roots: Dictionary) -> Dictionary:
	var w := _vec(roots.target); var positions := PackedVector3Array(); var history := PackedFloat64Array()
	for i in 4:
		positions.append(Vector3(w.x, 0, w.y)); history.append_array(_state_at(native, _vec(roots.a if i % 2 == 0 else roots.b), w))
	var result: PackedFloat64Array = native.call("sample_dynamic_contact_batch", positions, history)
	var maximum := 0.0; var statuses: Array = []
	for i in 4:
		maximum = maxf(maximum, Vector2(result[i * CS + 15], result[i * CS + 16]).distance_to(_vec(roots.a if i % 2 == 0 else roots.b)))
		statuses.append(result[i * CS + 17])
	return {"order": ["A", "B", "A", "B"], "same_target": true, "q_error_max": maximum, "statuses": statuses,
		"passed": maximum < 0.001 and statuses == [0.0, 0.0, 0.0, 0.0]}

func _frozen_branch(native: Object, qa: Array, wa: Array, label: String) -> Dictionary:
	var q := _vec(qa); var w := _vec(wa)
	var state := _state_at(native, q, w)
	var counts := [0, 0, 0, 0]; var jumps := 0; var max_delta := 0.0; var residuals: Array = []; var iterations: Array = []
	for tick in 600:
		var target := w + Vector2(sin(tick * 0.03), cos(tick * 0.03) - 1.0) * 0.002
		var r: PackedFloat64Array = native.call("sample_dynamic_contact", target.x, target.y, state)
		counts[int(r[STATUS])] += 1
		var delta := Vector2(r[QX], r[QZ]).distance_to(q)
		if r[STATUS] == 0 and delta > 0.03: jumps += 1
		max_delta = maxf(max_delta, delta); residuals.append(r[13]); iterations.append(r[14])
		if tick < 3: _trace.append({"trajectory": "frozen_" + label, "tick": tick, "previous_q": [state[15], state[16]], "row": Array(r)})
		state = r
	return {"ticks": 600, "continued": counts[0], "local": counts[1], "global": counts[2], "failed": counts[3],
		"jumps": jumps, "q_delta_max": max_delta, "residual": _metrics(residuals), "iterations": _metrics(iterations)}

func _local_probe(native: Object, roots: Dictionary) -> Dictionary:
	var q := _vec(roots.a); var w := _vec(roots.target)
	var results: Array = []
	for dx in [0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0]:
		var state := _state_at(native, q + Vector2(dx, 0), w)
		# History sheet orientation belongs to the owned root, even if prediction is inaccurate.
		state[DET] = roots.det_a
		var started := Time.get_ticks_usec()
		var r: PackedFloat64Array = native.call("sample_dynamic_contact", w.x, w.y, state)
		results.append({"seed_offset": dx, "status": r[STATUS], "residual": r[13], "q": [r[15], r[16]], "ms": (Time.get_ticks_usec() - started) / 1000.0})
	return {"cases": results}

func _bench_contacts(native: Object, roots: Dictionary) -> Dictionary:
	var report := {}; var scalar_max := 0.0
	for label in ["ordinary", "coastal", "folded"]:
		var points := PackedVector3Array(); var history := PackedFloat64Array()
		for i in 4:
			var q := Vector2(2000.0 + i * 0.3, -2000.0) if label == "ordinary" else (Vector2(37.0 + i * 0.3, 81.0) if label == "coastal" else _vec(roots.a))
			var w := _world(native, q)
			points.append(Vector3(w.x, 0.0, w.y)); history.append_array(_state_at(native, q, w))
		var times: Array = []; var moving_times: Array = []; var counts := [0, 0, 0, 0]
		var material_points := PackedVector3Array(); var material_times: Array = []
		for i in 4: material_points.append(Vector3(history[i * CS + QX], 0.0, history[i * CS + QZ]))
		for repeat in 1000:
			var started := Time.get_ticks_usec()
			native.call("sample_dynamic_material_q_batch", material_points)
			material_times.append((Time.get_ticks_usec() - started) / 1000.0)
		for repeat in 1000:
			var started := Time.get_ticks_usec()
			var r: PackedFloat64Array = native.call("sample_dynamic_contact_batch", points, history)
			times.append((Time.get_ticks_usec() - started) / 1000.0)
			if repeat == 0:
				for i in 4:
					var scalar: PackedFloat64Array = native.call("sample_dynamic_contact", points[i].x, points[i].z, history.slice(i * CS, (i + 1) * CS))
					for f in CS: scalar_max = maxf(scalar_max, absf(scalar[f] - r[i * CS + f]))
		var base_targets := points.duplicate()
		for repeat in 1000:
			for i in 4:
				points[i] = base_targets[i] + Vector3(sin(repeat * 0.02), 0, cos(repeat * 0.02) - 1.0) * (0.002 if label == "folded" else 0.02)
			var started := Time.get_ticks_usec()
			var r: PackedFloat64Array = native.call("sample_dynamic_contact_batch", points, history)
			moving_times.append((Time.get_ticks_usec() - started) / 1000.0)
			for i in 4: counts[int(r[i * CS + STATUS])] += 1
			history = r
		report[label] = {"stationary": _metrics(times), "moving": _metrics(moving_times), "moving_status_counts": counts,
			"material_N4": _metrics(material_times)}
	report.scalar_batch_max = scalar_max
	return report

func _trajectories(native: Object, states: Array, coastal: Dictionary, roots: Dictionary) -> Dictionary:
	var definitions: Array = [
		{"name": "stationary", "q": Vector2(2000, -2000), "speed": Vector2.ZERO},
		{"name": "slow", "q": Vector2(2031, -2050), "speed": Vector2(0.5, 0.2)},
		{"name": "fast", "q": Vector2(2050, -2050), "speed": Vector2(15, 3)},
		{"name": "coastal", "q": Vector2(37.13506, 81.04028), "speed": Vector2(0.2, -0.15)},
		{"name": "fold_A", "q": _vec(roots.a), "speed": Vector2.ZERO},
		{"name": "border", "q": coastal.field_origin + Vector2(-0.2, coastal.field_extent.y * 0.4), "speed": Vector2(0.2, 0)},
		{"name": "fixed_world", "q": Vector2(2000, -2000), "speed": Vector2.ZERO, "fixed_world": true},
		{"name": "coastal_fixed_world", "q": Vector2(37.13506, 81.04028), "speed": Vector2.ZERO, "fixed_world": true},
		{"name": "folded_fixed_world", "q": _vec(roots.a), "speed": Vector2.ZERO, "fixed_world": true},
	]
	for b in 3:
		var domain: float = states[1].bands[b].domain_size_m
		definitions.append({"name": "wrap_%d" % b, "q": Vector2(-domain * 0.5 - 0.2, 2017), "speed": Vector2(0.4, 0)})
	var contacts: Array = []; var stats: Array = []
	for item in definitions:
		var q: Vector2 = item.q; item.initial_target = _world(native, q)
		contacts.append(_state_at(native, q, item.initial_target))
		stats.append({"name": item.name, "counts": [0,0,0,0], "jumps": 0, "q_error": [], "delta": [], "residual": [], "iterations": [], "timing": [], "orientation_changes": 0, "oracle_q_error": []})
	var same_target_b := _state_at(native, _vec(roots.b), _vec(roots.target))
	var b_stats := {"ticks": 0, "counts": [0,0,0,0], "jumps": 0, "oracle_available": 0, "delta": [], "residual": []}
	var pause := {}; var max_batch_error := 0.0; var coherent := true
	var time := 2.25; var tick := 0
	for stage in ["fixed", "storm_calm", "calm_storm", "direction"]:
		if stage != "fixed":
			var from: int = 1 if stage == "storm_calm" or stage == "direction" else 0
			var to: int = 0 if stage == "storm_calm" else (1 if stage == "calm_storm" else 2)
			if not native.call("transition_dynamic_spectrum", states[from].native, states[to].native, time, 3.0): _fail("branch weather transition"); return {"passed": false}
		for frame in (240 if stage == "fixed" else 180):
			time += DT; tick += 1
			if not await _at(native, time): return {"passed": false}
			var info: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
			coherent = coherent and info[0] == info[1] and info[1] == info[2]
			var targets := PackedVector3Array(); var history := PackedFloat64Array(); var expected: Array = []
			for i in definitions.size():
				var q: Vector2 = definitions[i].q + definitions[i].speed * ((tick - 1) * DT)
				expected.append(q)
				var w: Vector2 = definitions[i].initial_target if definitions[i].get("fixed_world", false) else _world(native, q)
				targets.append(Vector3(w.x, 0, w.y)); history.append_array(contacts[i])
			var started := Time.get_ticks_usec()
			var results: PackedFloat64Array = native.call("sample_dynamic_contact_batch", targets, history)
			var batch_ms := (Time.get_ticks_usec() - started) / 1000.0
			for i in definitions.size():
				var r := results.slice(i * CS, (i + 1) * CS)
				var s: Dictionary = stats[i]; var prior: PackedFloat64Array = contacts[i]
				var error := Vector2(r[15], r[16]).distance_to(expected[i])
				var source: PackedFloat64Array = native.call("sample_dynamic_material_q", expected[i].x, expected[i].y)
				if source[11] * prior[DET] <= 0.0: s.orientation_changes += 1
				# Controlled jump is relative to the contact's OWNED prior branch,
				# not to a source q after an explicitly reported reacquisition.
				var oracle := _owned_oracle(native, Vector2(targets[i].x, targets[i].z), prior)
				var oracle_error: float = Vector2(r[15], r[16]).distance_to(oracle.q) if not oracle.is_empty() else -1.0
				if oracle_error >= 0.0: s.oracle_q_error.append(oracle_error)
				if oracle_error > 0.03:
					s.jumps += 1
					_trace.append({"trajectory": s.name, "tick": tick, "controlled_jump": true,
						"oracle_q": [oracle.q.x, oracle.q.y], "previous_q": [prior[15], prior[16]], "row": Array(r)})
				s.counts[int(r[STATUS])] += 1; s.q_error.append(error); s.delta.append(r[24]); s.residual.append(r[13]); s.iterations.append(r[14]); s.timing.append(batch_ms)
				_trace.append({"trajectory": s.name, "stage": stage, "tick": tick, "target": [targets[i].x, targets[i].z],
					"previous_q": [prior[15], prior[16]], "expected_q": [expected[i].x, expected[i].y], "q_error": error,
					"prescribed_source": not definitions[i].get("fixed_world", false), "oracle_q_error": oracle_error,
					"per_band_wrapped_delta": _band_deltas(prior, r, states[1].bands), "row": Array(r)})
				if frame == 0:
					var scalar: PackedFloat64Array = native.call("sample_dynamic_contact", targets[i].x, targets[i].z, prior)
					for f in CS: max_batch_error = maxf(max_batch_error, absf(scalar[f] - r[f]))
				contacts[i] = r
			if stage == "fixed" and frame < 120:
				# Both initialized roots see the SAME evolving world target. The
				# legacy warm solver is an independent local-root candidate only.
				var w := Vector2(targets[4].x, targets[4].z)
				var oracle: PackedFloat64Array = native.call("sample_dynamic_world", w.x, w.y, same_target_b[15], same_target_b[16], true)
				var next_b: PackedFloat64Array = native.call("sample_dynamic_contact", w.x, w.y, same_target_b)
				var owned := _owned_oracle(native, w, same_target_b)
				if not owned.is_empty():
					b_stats.oracle_available += 1
					if Vector2(owned.q).distance_to(Vector2(next_b[15], next_b[16])) > 0.03:
						b_stats.jumps += 1; _trace.append({"trajectory": "same_target_B", "tick": tick, "controlled_jump": true,
							"oracle_q": [owned.q.x, owned.q.y], "previous_q": [same_target_b[15], same_target_b[16]], "row": Array(next_b)})
				b_stats.ticks += 1; b_stats.counts[int(next_b[STATUS])] += 1; b_stats.delta.append(next_b[24]); b_stats.residual.append(next_b[13]); same_target_b = next_b
			if stage == "fixed" and frame == 90:
				var before: PackedFloat64Array = contacts[4]; var frozen_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
				var changes := 0; var reacquire := 0
				for _p in 30:
					await physics_frame
					native.call("advance_dynamic_async", _packet_tick, time, time, DT)
					var r: PackedFloat64Array = native.call("sample_dynamic_contact", targets[4].x, targets[4].z, contacts[4])
					if r[15] != before[15] or r[16] != before[16] or r[WT] != before[WT]: changes += 1
					if r[STATUS] != 0: reacquire += 1
					contacts[4] = r
				pause = {"ticks": 30, "changes": changes, "reacquire": reacquire, "field_frozen": frozen_info == native.call("get_dynamic_snapshot_info")}
		print("BRANCH_STAGE=" + stage)
	var passed: bool = coherent and max_batch_error == 0.0 and b_stats.jumps == 0 and pause.changes == 0 and pause.reacquire == 0
	for s in stats:
		passed = passed and s.jumps == 0 and s.counts[3] == 0
		for field in ["q_error", "delta", "residual", "iterations", "timing", "oracle_q_error"]: s[field] = _metrics(s[field])
	for field in ["delta", "residual"]: b_stats[field] = _metrics(b_stats[field])
	var rapid := await _rapid_transition(native, states, contacts[0], time)
	passed = passed and rapid.passed
	return {"passed": passed, "ticks": tick, "contacts": stats, "same_target_B": b_stats, "pause": pause,
		"coherent": coherent, "scalar_batch_max": max_batch_error, "rapid": rapid}

func _band_deltas(prior: PackedFloat64Array, row: PackedFloat64Array, bands: Array) -> Array:
	var deltas: Array = []
	for band in bands:
		var domain: float = band.domain_size_m
		deltas.append(Vector2(fposmod(row[15] - prior[15] + domain * 0.5, domain) - domain * 0.5,
			fposmod(row[16] - prior[16] + domain * 0.5, domain) - domain * 0.5).length())
	return deltas

func _rapid_transition(native: Object, states: Array, prior: PackedFloat64Array, time: float) -> Dictionary:
	if not native.call("transition_dynamic_spectrum", states[0].native, states[1].native, time, 3.0): return {"passed": false}
	_packet_tick += 1
	native.call("advance_dynamic_async", _packet_tick, time + DT, time + DT, DT)
	if not native.call("transition_dynamic_spectrum", states[1].native, states[2].native, time, 3.0): return {"passed": false}
	var wanted := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
	if not await _at(native, time + DT): return {"passed": false}
	var q := Vector2(prior[15], prior[16]); var w := _world(native, q)
	var row: PackedFloat64Array = native.call("sample_dynamic_contact", w.x, w.y, prior)
	var times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
	return {"wanted_version": wanted, "row_version": row[21], "time": row[20], "status": row[17],
		"coherent": times[0] == times[1] and times[1] == times[2], "passed": row[0] == 1.0 and row[21] == wanted and times[0] == times[1] and times[1] == times[2]}

func _owned_oracle(native: Object, target: Vector2, prior: PackedFloat64Array) -> Dictionary:
	if prior[0] < 0.5: return {}
	var anchor := Vector2(prior[15], prior[16])
	# Independent legacy Newton, dense local seeds only when the first seed
	# fails. Reject candidates across orientation changes in the sampled path.
	for i in 9:
		var seed := anchor if i == 0 else anchor + Vector2.from_angle((i - 1) * TAU / 8.0) * 0.01
		var r: PackedFloat64Array = native.call("sample_dynamic_world", target.x, target.y, seed.x, seed.y, true)
		if r[0] < 0.5 or r[11] * prior[DET] <= 0.0: continue
		var q := Vector2(r[15], r[16])
		if q.distance_to(anchor) > 0.1: continue
		var connected := true
		for fraction in [0.0, 0.25, 0.5, 0.75]:
			var p: Vector2 = anchor.lerp(q, fraction)
			var sample: PackedFloat64Array = native.call("sample_dynamic_material_q", p.x, p.y)
			connected = connected and sample[11] * prior[DET] > 0.0
		if connected: return {"q": q, "residual": r[13]}
	return {}
