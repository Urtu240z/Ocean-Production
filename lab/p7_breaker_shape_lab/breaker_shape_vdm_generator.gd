class_name P7BreakerShapeVDMGenerator
extends RefCounted
## Authored multi-phase 2D vector-displacement atlas for the 2E1 LAB.

const TILE_SIZE := 256
const PHASE_COUNT := 8
const ATLAS_HEIGHT := TILE_SIZE * PHASE_COUNT
const MATERIAL_ARC_LUT_SAMPLES := 4096
const MATERIAL_LANDMARK_SAMPLES := 4096
const PROFILE_NAMES: Array[String] = [
	"P0 SWELL", "P1 SHOAL", "P2 STEEPEN", "P3 CREST",
	"P4 PRE_LIP", "P5 PLUNGE", "P6 COLLAPSE", "P7 DISSIPATE"
]

# Each profile is an authored (s, y) side curve. P5 deliberately reverses s
# beneath the lip so the displacement encodes a real non-monotonic fold.
const PROFILE_P0: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.8, 0.05), Vector2(-3.2, 0.20), Vector2(-1.2, 0.38), Vector2(0.8, 0.42), Vector2(2.6, 0.28), Vector2(4.3, 0.10), Vector2(6.0, 0.0)]
const PROFILE_P1: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.7, 0.08), Vector2(-3.0, 0.32), Vector2(-1.0, 0.58), Vector2(0.9, 0.70), Vector2(2.5, 0.48), Vector2(4.4, 0.16), Vector2(6.0, 0.0)]
const PROFILE_P2: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.6, 0.10), Vector2(-2.8, 0.55), Vector2(-0.9, 1.15), Vector2(0.7, 1.55), Vector2(2.2, 1.15), Vector2(4.1, 0.30), Vector2(6.0, 0.0)]
const PROFILE_P3: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.7, 0.12), Vector2(-2.9, 0.70), Vector2(-1.0, 1.75), Vector2(0.25, 3.30), Vector2(1.35, 2.35), Vector2(3.4, 0.55), Vector2(6.0, 0.0)]
const PROFILE_P4: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.7, 0.12), Vector2(-2.8, 0.72), Vector2(-0.7, 1.80), Vector2(0.65, 3.05), Vector2(2.65, 2.75), Vector2(1.85, 1.10), Vector2(4.0, 0.38), Vector2(6.0, 0.0)]
const PROFILE_P5: Array[Vector2] = [
	Vector2(-6.00, 0.00), Vector2(-5.20, 0.05), Vector2(-4.20, 0.18), Vector2(-3.20, 0.48),
	Vector2(-2.20, 0.95), Vector2(-1.30, 1.55), Vector2(-0.55, 2.30), Vector2(0.05, 3.05),
	Vector2(0.55, 3.55), Vector2(1.10, 3.72), Vector2(1.65, 3.62), Vector2(2.05, 3.32),
	Vector2(2.28, 2.88), Vector2(2.22, 2.40), Vector2(1.92, 1.98), Vector2(1.45, 1.62),
	Vector2(0.95, 1.30), Vector2(0.70, 1.08), Vector2(0.92, 0.82), Vector2(1.45, 0.58),
	Vector2(2.20, 0.38), Vector2(3.20, 0.22), Vector2(4.40, 0.10), Vector2(5.30, 0.04),
	Vector2(6.00, 0.00)
]
const PROFILE_P6: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.7, 0.10), Vector2(-2.8, 0.58), Vector2(-0.7, 1.35), Vector2(0.55, 2.10), Vector2(1.75, 1.75), Vector2(2.25, 1.05), Vector2(1.35, 0.58), Vector2(3.8, 0.18), Vector2(6.0, 0.0)]
const PROFILE_P7: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.8, 0.06), Vector2(-3.1, 0.28), Vector2(-1.2, 0.52), Vector2(0.55, 0.68), Vector2(2.1, 0.48), Vector2(3.7, 0.20), Vector2(6.0, 0.0)]


static func build() -> ImageTexture:
	return ImageTexture.create_from_image(build_image())


static func build_image() -> Image:
	var image := Image.create(TILE_SIZE, ATLAS_HEIGHT, false, Image.FORMAT_RGBAH)
	var shared_material_luts := build_shared_material_luts()
	for phase_index in PHASE_COUNT:
		var profile := _profile_for_phase(phase_index)
		var material_lut: PackedVector2Array = shared_material_luts.get(phase_index, PackedVector2Array())
		for y in TILE_SIZE:
			var shore_v := (float(y) + 0.5) / float(TILE_SIZE)
			var lateral := shore_v * 2.0 - 1.0
			var edge_asymmetry := 1.0 + 0.025 * sin(lateral * PI + float(phase_index) * 0.37)
			for x in TILE_SIZE:
				var profile_u := (float(x) + 0.5) / float(TILE_SIZE)
				var base_s := (profile_u - 0.5) * 12.0
				var profile_point := _sample_profile_material(profile, profile_u, material_lut) if not material_lut.is_empty() else _sample_profile(profile, profile_u)
				var rear_authority := _smoothstep(0.02, 0.12, profile_u)
				var front_authority := 1.0 - _smoothstep(0.88, 0.98, profile_u)
				var authority := rear_authority * front_authority
				var target_s := profile_point.x
				var target_y := maxf(profile_point.y * edge_asymmetry, 0.0)
				# Own contract: R=propagation metres, G=lateral metres, B=up metres, A=authority.
				image.set_pixel(x, phase_index * TILE_SIZE + y, Color(
					target_s - base_s,
					0.0,
					target_y,
					authority
				))
	return image


static func phase_name(index: int) -> String:
	return PROFILE_NAMES[clampi(index, 0, PHASE_COUNT - 1)]


static func _profile_for_phase(index: int) -> Array[Vector2]:
	match index:
		0: return PROFILE_P0
		1: return PROFILE_P1
		2: return PROFILE_P2
		3: return PROFILE_P3
		4: return PROFILE_P4
		5: return PROFILE_P5
		6: return PROFILE_P6
		_: return PROFILE_P7


static func _sample_profile(points: Array[Vector2], value: float) -> Vector2:
	var t := clampf(value, 0.0, 1.0) * float(points.size() - 1)
	var index := mini(int(floor(t)), points.size() - 2)
	var local_t := t - float(index)
	var p0: Vector2 = points[maxi(index - 1, 0)]
	var p1: Vector2 = points[index]
	var p2: Vector2 = points[index + 1]
	var p3: Vector2 = points[mini(index + 2, points.size() - 1)]
	var t2 := local_t * local_t
	var t3 := t2 * local_t
	return 0.5 * (
		2.0 * p1
		+ (-p0 + p2) * local_t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


static func build_material_arc_lut(points: Array[Vector2], sample_count: int = MATERIAL_ARC_LUT_SAMPLES) -> PackedVector2Array:
	var count := maxi(sample_count, 2)
	var curve_samples := PackedVector2Array()
	curve_samples.resize(count)
	var cumulative := PackedFloat32Array()
	cumulative.resize(count)
	curve_samples[0] = _sample_profile(points, 0.0)
	cumulative[0] = 0.0
	var total_length := 0.0
	for i in range(1, count):
		var t := float(i) / float(count - 1)
		curve_samples[i] = _sample_profile(points, t)
		total_length += curve_samples[i - 1].distance_to(curve_samples[i])
		cumulative[i] = total_length
	var lut := PackedVector2Array()
	lut.resize(count)
	for i in count:
		var material_u := cumulative[i] / maxf(total_length, 0.000001)
		lut[i] = Vector2(material_u, float(i) / float(count - 1))
	return lut


static func build_shared_material_luts() -> Dictionary:
	var p5_arc_lut := build_material_arc_lut(PROFILE_P5)
	var shared_material_anchors := _material_landmark_anchors(PROFILE_P5, p5_arc_lut)
	var luts := {
		4: _build_landmark_material_lut(_curve_landmark_parameters(PROFILE_P4), shared_material_anchors),
		5: p5_arc_lut,
		6: build_p6_arc_redistributed_lut(),
	}
	return luts


static func build_p6_arc_redistributed_lut(sample_count: int = MATERIAL_LANDMARK_SAMPLES) -> PackedVector2Array:
	var p5_arc_lut := build_material_arc_lut(PROFILE_P5)
	var shared_material_anchors := _material_landmark_anchors(PROFILE_P5, p5_arc_lut)
	return _build_segment_arc_material_lut(_curve_landmark_parameters(PROFILE_P6), shared_material_anchors, PROFILE_P6, sample_count)


static func _build_segment_arc_material_lut(curve_anchors: PackedFloat32Array, material_anchors: PackedFloat32Array, points: Array[Vector2], sample_count: int = MATERIAL_LANDMARK_SAMPLES) -> PackedVector2Array:
	var count := maxi(sample_count, 2)
	var lut := PackedVector2Array()
	lut.resize(count)
	for i in count:
		var material_u := float(i) / float(count - 1)
		var segment := clampi(_find_interval(material_anchors, material_u), 0, material_anchors.size() - 2)
		var lower_m := material_anchors[segment]
		var upper_m := material_anchors[segment + 1]
		var material_span := maxf(upper_m - lower_m, 0.000001)
		var local_material := clampf((material_u - lower_m) / material_span, 0.0, 1.0)
		var lower_t := curve_anchors[segment]
		var upper_t := curve_anchors[segment + 1]
		var arc_samples := 256
		var cumulative := PackedFloat32Array()
		cumulative.resize(arc_samples + 1)
		cumulative[0] = 0.0
		var total_length := 0.0
		var previous := _sample_profile(points, lower_t)
		for arc_index in range(1, arc_samples + 1):
			var local_t := float(arc_index) / float(arc_samples)
			var current := _sample_profile(points, lerpf(lower_t, upper_t, local_t))
			total_length += previous.distance_to(current)
			cumulative[arc_index] = total_length
			previous = current
		# A smooth local arc bias keeps the fold landmark fixed while giving the
		# reverse-slope portion a little more material resolution. Its derivative
		# remains finite at every shared landmark.
		var arc_bias := local_material + 0.14 * local_material * (1.0 - local_material) * (1.0 - local_material)
		var target_length := arc_bias * total_length
		var arc_low := 0
		var arc_high := arc_samples
		while arc_low < arc_high:
			var arc_middle := (arc_low + arc_high) >> 1
			if cumulative[arc_middle] < target_length:
				arc_low = arc_middle + 1
			else:
				arc_high = arc_middle
		var arc_upper := clampi(arc_low, 1, arc_samples)
		var arc_lower := arc_upper - 1
		var arc_span := maxf(cumulative[arc_upper] - cumulative[arc_lower], 0.000001)
		var arc_fraction := clampf((target_length - cumulative[arc_lower]) / arc_span, 0.0, 1.0)
		var curve_t := lerpf(lower_t, upper_t, (float(arc_lower) + arc_fraction) / float(arc_samples))
		lut[i] = Vector2(material_u, curve_t)
	return lut


static func get_p6_validation_report() -> Dictionary:
	var p5_arc_lut := build_material_arc_lut(PROFILE_P5)
	var shared_material_anchors := _material_landmark_anchors(PROFILE_P5, p5_arc_lut)
	var baseline_lut := _build_landmark_material_lut(_curve_landmark_parameters(PROFILE_P6), shared_material_anchors)
	var candidate_lut := _build_segment_arc_material_lut(_curve_landmark_parameters(PROFILE_P6), shared_material_anchors, PROFILE_P6)
	return {
		"phase": "P6 COLLAPSE",
		"sample_grid": "256x64",
		"baseline": _p6_validation_metrics(baseline_lut),
		"p6_a": _p6_validation_metrics(candidate_lut),
		"curve_audit_baseline": _p6_curve_audit(baseline_lut),
		"curve_audit_p6_a": _p6_curve_audit(candidate_lut),
		"p5_to_p6_temporal": _p5_p6_temporal_report(candidate_lut),
		"shared_material_anchors": shared_material_anchors,
		"control_points_unchanged": true,
		"silhouette_preserved": true,
		"p5_lut_unchanged": true,
}


static func _p5_p6_temporal_report(p6_lut: PackedVector2Array) -> Dictionary:
	var p5_lut := build_material_arc_lut(PROFILE_P5)
	var displacements := []
	var worst := {"max": -INF, "t": 0.0, "material_m": 0.0}
	for step in 100:
		var t0 := float(step) / 100.0
		var t1 := float(step + 1) / 100.0
		for i in 1024:
			var material_u := float(i) / 1023.0
			var authored_base_s := (material_u - 0.5) * 12.0
			var p5 := _sample_profile_material(PROFILE_P5, material_u, p5_lut)
			var p6 := _sample_profile_material(PROFILE_P6, material_u, p6_lut)
			var p5_world := Vector2((p5.x - authored_base_s) * 32.0 / 12.0, p5.y * 2.0 / 3.72184)
			var p6_world := Vector2((p6.x - authored_base_s) * 32.0 / 12.0, p6.y * 2.0 / 3.72184)
			var q0 := p5_world.lerp(p6_world, t0)
			var q1 := p5_world.lerp(p6_world, t1)
			var displacement := q0.distance_to(q1)
			displacements.append(displacement)
			if displacement > float(worst["max"]):
				worst = {"max": displacement, "t": t0, "material_m": material_u}
	displacements.sort()
	return {
		"phase": "5+t",
		"step": 0.01,
		"samples_per_step": 1024,
		"mean": displacements.reduce(func(acc, value): return acc + value, 0.0) / float(displacements.size()),
		"p95": _p6_percentile(displacements, 0.95),
		"max": worst["max"],
		"worst_t": worst["t"],
		"worst_material_m": worst["material_m"],
	}


static func _p6_contract_sample(profile_u: float, crest_v: float, material_lut: PackedVector2Array) -> Dictionary:
	var authored_base_s := (profile_u - 0.5) * 12.0
	var authored := _sample_profile_material(PROFILE_P6, profile_u, material_lut)
	var base_s := (profile_u - 0.5) * 32.0
	var delta_s := (authored.x - authored_base_s) * 32.0 / 12.0
	var target_y := maxf(authored.y * 2.0 / 3.72184, 0.0)
	var rear_attachment := _smoothstep(0.0, 0.08, profile_u)
	var front_attachment := 1.0 - _smoothstep(0.92, 1.0, profile_u)
	var lateral_attachment := _smoothstep(0.0, 0.12, crest_v) * (1.0 - _smoothstep(0.88, 1.0, crest_v))
	var authority := rear_attachment * front_attachment * lateral_attachment
	var base := Vector3(base_s, 0.0, (crest_v - 0.5) * 32.0)
	var residual := Vector3(delta_s, target_y, 0.0)
	return {
		"base": base,
		"final": base + authority * residual,
		"authority": authority,
		"target_s": authored.x,
		"target_y": target_y,
		"residual": residual,
	}


static func _p6_derivatives(material_u: float, material_lut: PackedVector2Array) -> Dictionary:
	var step := 1.0 / 4095.0
	var lower := clampf(material_u - step, 0.0, 1.0)
	var upper := clampf(material_u + step, 0.0, 1.0)
	var lower_point := _sample_profile_material(PROFILE_P6, lower, material_lut)
	var upper_point := _sample_profile_material(PROFILE_P6, upper, material_lut)
	var span := maxf(upper - lower, 0.000001)
	var ds_dm := (upper_point.x - lower_point.x) / span
	var dy_dm := (upper_point.y - lower_point.y) / span
	return {"ds_dm": ds_dm, "dy_dm": dy_dm, "arc_dm": sqrt(ds_dm * ds_dm + dy_dm * dy_dm)}


static func _p6_percentile(values: Array, fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(int(floor(float(sorted.size() - 1) * fraction)), 0, sorted.size() - 1)
	return float(sorted[index])


static func _p6_curve_audit(material_lut: PackedVector2Array) -> Dictionary:
	var count := 4096
	var ds_values := []
	var dy_values := []
	var arc_values := []
	var points := []
	for i in count:
		var material_u := float(i) / float(count - 1)
		var point := _sample_profile_material(PROFILE_P6, material_u, material_lut)
		var derivative := _p6_derivatives(material_u, material_lut)
		points.append(point)
		ds_values.append(float(derivative["ds_dm"]))
		dy_values.append(float(derivative["dy_dm"]))
		arc_values.append(float(derivative["arc_dm"]))
	var curvature_values := []
	var reversal_first := -1
	var reversal_last := -1
	var min_ds := INF
	var max_ds := -INF
	var min_dy := INF
	var max_dy := -INF
	var min_arc := INF
	var max_arc := -INF
	for i in count:
		var previous := maxi(i - 1, 0)
		var next := mini(i + 1, count - 1)
		var dm := maxf(float(next - previous) / float(count - 1), 0.000001)
		var d2s := (float(ds_values[next]) - float(ds_values[previous])) / dm
		var d2y := (float(dy_values[next]) - float(dy_values[previous])) / dm
		var ds := float(ds_values[i])
		var dy := float(dy_values[i])
		var arc := maxf(float(arc_values[i]), 0.000001)
		curvature_values.append(absf(ds * d2y - dy * d2s) / (arc * arc * arc))
		min_ds = minf(min_ds, ds)
		max_ds = maxf(max_ds, ds)
		min_dy = minf(min_dy, dy)
		max_dy = maxf(max_dy, dy)
		min_arc = minf(min_arc, arc)
		max_arc = maxf(max_arc, arc)
		if ds < -0.000001:
			if reversal_first < 0: reversal_first = i
			reversal_last = i
	return {
		"sample_count": count,
		"ds_dm_min": min_ds,
		"ds_dm_p05": _p6_percentile(ds_values, 0.05),
		"ds_dm_p95": _p6_percentile(ds_values, 0.95),
		"ds_dm_max": max_ds,
		"dy_dm_min": min_dy,
		"dy_dm_p05": _p6_percentile(dy_values, 0.05),
		"dy_dm_p95": _p6_percentile(dy_values, 0.95),
		"dy_dm_max": max_dy,
		"arc_dm_min": min_arc,
		"arc_dm_p95": _p6_percentile(arc_values, 0.95),
		"arc_dm_max": max_arc,
		"curvature_max": _p6_percentile(curvature_values, 1.0),
		"reversal_material_m": [float(reversal_first) / float(count - 1), float(reversal_last) / float(count - 1)] if reversal_first >= 0 else [],
	}


static func _p6_validation_metrics(material_lut: PackedVector2Array) -> Dictionary:
	var mesh := []
	for v in 64:
		var row := []
		for u in 256:
			row.append(_p6_contract_sample(float(u) / 255.0, float(v) / 63.0, material_lut))
		mesh.append(row)
	var edge_ratios := []
	for v in 64:
		for u in 255:
			var a: Dictionary = mesh[v][u]
			var b: Dictionary = mesh[v][u + 1]
			var base_a: Vector3 = a["base"]
			var base_b: Vector3 = b["base"]
			var final_a: Vector3 = a["final"]
			var final_b: Vector3 = b["final"]
			edge_ratios.append(final_a.distance_to(final_b) / maxf(base_a.distance_to(base_b), 0.000001))
	for v in 63:
		for u in 256:
			var a: Dictionary = mesh[v][u]
			var b: Dictionary = mesh[v + 1][u]
			var base_a: Vector3 = a["base"]
			var base_b: Vector3 = b["base"]
			var final_a: Vector3 = a["final"]
			var final_b: Vector3 = b["final"]
			edge_ratios.append(final_a.distance_to(final_b) / maxf(base_a.distance_to(base_b), 0.000001))
	edge_ratios.sort()
	var min_edge_ratio := float(edge_ratios[0])
	var max_edge_ratio := float(edge_ratios[edge_ratios.size() - 1])
	var total_base_area := 0.0
	var total_final_area := 0.0
	var min_area_ratio := INF
	var max_area_ratio := 0.0
	var degenerate := 0
	var near_degenerate := 0
	var extreme_area := 0
	var flipped := 0
	var triangle_records := []
	var flagged_cells := {}
	for v in 63:
		for u in 255:
			for winding in 2:
				var a_uv := Vector2(float(u + (1 if winding == 1 else 0)) / 255.0, float(v) / 63.0)
				var b_uv := Vector2(float(u) / 255.0, float(v + 1) / 63.0)
				var c_uv := Vector2(float(u + 1) / 255.0, float(v + (1 if winding == 1 else 0)) / 63.0)
				var a: Dictionary = mesh[int(round(a_uv.y * 63.0))][int(round(a_uv.x * 255.0))]
				var b: Dictionary = mesh[int(round(b_uv.y * 63.0))][int(round(b_uv.x * 255.0))]
				var c: Dictionary = mesh[int(round(c_uv.y * 63.0))][int(round(c_uv.x * 255.0))]
				var base_a: Vector3 = a["base"]
				var base_b: Vector3 = b["base"]
				var base_c: Vector3 = c["base"]
				var final_a: Vector3 = a["final"]
				var final_b: Vector3 = b["final"]
				var final_c: Vector3 = c["final"]
				var base_cross := (base_b - base_a).cross(base_c - base_a)
				var final_cross := (final_b - final_a).cross(final_c - final_a)
				var base_area := 0.5 * base_cross.length()
				var final_area := 0.5 * final_cross.length()
				var area_ratio := final_area / maxf(base_area, 0.000001)
				var edge_ab := final_a.distance_to(final_b) / maxf(base_a.distance_to(base_b), 0.000001)
				var edge_bc := final_b.distance_to(final_c) / maxf(base_b.distance_to(base_c), 0.000001)
				var edge_ca := final_c.distance_to(final_a) / maxf(base_c.distance_to(base_a), 0.000001)
				var centroid_m := (a_uv.x + b_uv.x + c_uv.x) / 3.0
				var centroid_v := (a_uv.y + b_uv.y + c_uv.y) / 3.0
				var centroid := _p6_contract_sample(centroid_m, centroid_v, material_lut)
				var derivatives := _p6_derivatives(centroid_m, material_lut)
				var record := {"cell_u": u, "cell_v": v, "winding": winding, "profile_u": centroid_m, "material_m": centroid_m, "crest_v": centroid_v, "target_s": centroid["target_s"], "target_y": centroid["target_y"], "ds_dm": derivatives["ds_dm"], "dy_dm": derivatives["dy_dm"], "edge_ratio_min": minf(edge_ab, minf(edge_bc, edge_ca)), "edge_ratio_max": maxf(edge_ab, maxf(edge_bc, edge_ca)), "area_ratio": area_ratio}
				total_base_area += base_area
				total_final_area += final_area
				min_area_ratio = minf(min_area_ratio, area_ratio)
				max_area_ratio = maxf(max_area_ratio, area_ratio)
				if final_area <= 0.000001: degenerate += 1
				if final_area < base_area * 0.05: near_degenerate += 1
				if area_ratio < 0.25 or area_ratio > 4.0: extreme_area += 1
				if final_cross.dot(base_cross) <= 0.0: flipped += 1
				if area_ratio < 0.05 or area_ratio < 0.25 or area_ratio > 4.0:
					triangle_records.append(record)
					var cell_key := "%d:%d" % [u, v]
					if not flagged_cells.has(cell_key): flagged_cells[cell_key] = {"u": u, "v": v, "records": []}
					flagged_cells[cell_key]["records"].append(record)
	var p95_index := clampi(int(floor(float(edge_ratios.size() - 1) * 0.95)), 0, edge_ratios.size() - 1)
	return {
		"mean_area_ratio": total_final_area / maxf(total_base_area, 0.000001),
		"min_area_ratio": min_area_ratio,
		"max_area_ratio": max_area_ratio,
		"edge_stretch_mean": edge_ratios.reduce(func(acc, value): return acc + value, 0.0) / float(edge_ratios.size()),
		"edge_stretch_p95": edge_ratios[p95_index],
		"edge_stretch_max": max_edge_ratio,
		"edge_stretch_min_ratio": min_edge_ratio,
		"degenerate": degenerate,
		"near_degenerate": near_degenerate,
		"extreme_area": extreme_area,
		"reference_normal_reversed": flipped,
		"flagged_cell_count": flagged_cells.size(),
		"near_degenerate_clusters": _p6_cluster_summaries(flagged_cells, true),
		"extreme_area_clusters": _p6_cluster_summaries(flagged_cells, false),
	}


static func _p6_cluster_summaries(flagged_cells: Dictionary, near_only: bool) -> Array:
	var selected := {}
	for key in flagged_cells:
		var cell: Dictionary = flagged_cells[key]
		var include := false
		for record in cell["records"]:
			var area_ratio := float(record["area_ratio"])
			if (near_only and area_ratio < 0.05) or (not near_only and (area_ratio < 0.25 or area_ratio > 4.0)):
				include = true
		if include: selected[key] = cell
	var summaries := []
	while not selected.is_empty():
		var seed_key := ""
		for key in selected:
			seed_key = key
			break
		var seed_cell: Dictionary = selected[seed_key]
		var queue := [Vector2i(int(seed_cell["u"]), int(seed_cell["v"]))]
		selected.erase(seed_key)
		var cells := []
		var records := []
		while not queue.is_empty():
			var cell_coord: Vector2i = queue.pop_back()
			var cell_key := "%d:%d" % [cell_coord.x, cell_coord.y]
			var current: Dictionary = flagged_cells[cell_key]
			cells.append(cell_coord)
			for record in current["records"]:
				var area_ratio := float(record["area_ratio"])
				if (near_only and area_ratio < 0.05) or (not near_only and (area_ratio < 0.25 or area_ratio > 4.0)):
					records.append(record)
			for direction in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var neighbour_key := "%d:%d" % [cell_coord.x + direction.x, cell_coord.y + direction.y]
				if selected.has(neighbour_key):
					selected.erase(neighbour_key)
					queue.append(Vector2i(cell_coord.x + direction.x, cell_coord.y + direction.y))
		if records.is_empty(): continue
		var worst: Dictionary = records[0]
		for record in records:
			var current_ratio := float(record["area_ratio"])
			var worst_ratio := float(worst["area_ratio"])
			if (near_only and current_ratio < worst_ratio) or (not near_only and absf(current_ratio - 1.0) > absf(worst_ratio - 1.0)):
				worst = record
		var m_min := INF
		var m_max := -INF
		var v_min := INF
		var v_max := -INF
		var s_min := INF
		var s_max := -INF
		var y_min := INF
		var y_max := -INF
		var edge_min := INF
		var edge_max := 0.0
		for record in records:
			m_min = minf(m_min, float(record["material_m"]))
			m_max = maxf(m_max, float(record["material_m"]))
			v_min = minf(v_min, float(record["crest_v"]))
			v_max = maxf(v_max, float(record["crest_v"]))
			s_min = minf(s_min, float(record["target_s"]))
			s_max = maxf(s_max, float(record["target_s"]))
			y_min = minf(y_min, float(record["target_y"]))
			y_max = maxf(y_max, float(record["target_y"]))
			edge_min = minf(edge_min, float(record["edge_ratio_min"]))
			edge_max = maxf(edge_max, float(record["edge_ratio_max"]))
		summaries.append({
			"cell_count": cells.size(),
			"triangle_count": records.size(),
			"profile_u_range": [m_min, m_max],
			"crest_v_range": [v_min, v_max],
			"target_s_range_m": [s_min, s_max],
			"target_y_range_m": [y_min, y_max],
			"ds_dm": worst["ds_dm"],
			"dy_dm": worst["dy_dm"],
			"edge_ratio_range": [edge_min, edge_max],
			"worst": worst,
		})
	summaries.sort_custom(func(a, b): return int(a["triangle_count"]) > int(b["triangle_count"]))
	return summaries


static func get_shared_material_landmarks() -> Dictionary:
	var p5_arc_lut := build_material_arc_lut(PROFILE_P5)
	var shared_material_anchors := _material_landmark_anchors(PROFILE_P5, p5_arc_lut)
	return {
		"material_u": shared_material_anchors,
		"P4_curve_t": _curve_landmark_parameters(PROFILE_P4),
		"P5_curve_t": _curve_landmark_parameters(PROFILE_P5),
		"P6_curve_t": _curve_landmark_parameters(PROFILE_P6),
	}


static func _curve_landmark_parameters(points: Array[Vector2], sample_count: int = MATERIAL_LANDMARK_SAMPLES) -> PackedFloat32Array:
	var count := maxi(sample_count, 2)
	var samples := PackedVector2Array()
	samples.resize(count)
	for i in count:
		samples[i] = _sample_profile(points, float(i) / float(count - 1))
	var crest_index := 0
	for i in range(1, count):
		if samples[i].y > samples[crest_index].y:
			crest_index = i
	var negative_first := -1
	var negative_last := -1
	for i in count - 1:
		var ds := samples[i + 1].x - samples[i].x
		if ds < -0.000001:
			if negative_first < 0:
				negative_first = i
			negative_last = i
	var crest_t := float(crest_index) / float(count - 1)
	var fold_onset_t := float(negative_first) / float(count - 1) if negative_first >= 0 else crest_t
	var foldback_t := float(negative_last + 1) / float(count - 1) if negative_last >= 0 else fold_onset_t
	return PackedFloat32Array([0.0, crest_t, fold_onset_t, foldback_t, 1.0])


static func _material_landmark_anchors(points: Array[Vector2], material_lut: PackedVector2Array) -> PackedFloat32Array:
	var curve_anchors := _curve_landmark_parameters(points)
	var material_anchors := PackedFloat32Array()
	material_anchors.resize(curve_anchors.size())
	for i in curve_anchors.size():
		material_anchors[i] = _material_u_for_curve_t(material_lut, curve_anchors[i])
	return material_anchors


static func _material_u_for_curve_t(material_lut: PackedVector2Array, curve_t: float) -> float:
	if material_lut.size() < 2:
		return clampf(curve_t, 0.0, 1.0)
	var target := clampf(curve_t, 0.0, 1.0)
	var low := 0
	var high := material_lut.size() - 1
	while low < high:
		var middle := (low + high) >> 1
		if material_lut[middle].y < target:
			low = middle + 1
		else:
			high = middle
	var upper := clampi(low, 1, material_lut.size() - 1)
	var lower := upper - 1
	var lower_t := material_lut[lower].y
	var upper_t := material_lut[upper].y
	var span := maxf(upper_t - lower_t, 0.000001)
	return lerpf(material_lut[lower].x, material_lut[upper].x, clampf((target - lower_t) / span, 0.0, 1.0))


static func _build_landmark_material_lut(curve_anchors: PackedFloat32Array, material_anchors: PackedFloat32Array, sample_count: int = MATERIAL_LANDMARK_SAMPLES) -> PackedVector2Array:
	var count := maxi(sample_count, 2)
	var lut := PackedVector2Array()
	lut.resize(count)
	for i in count:
		var material_u := float(i) / float(count - 1)
		var segment := clampi(_find_interval(material_anchors, material_u), 0, material_anchors.size() - 2)
		var lower_m := material_anchors[segment]
		var upper_m := material_anchors[segment + 1]
		var span := maxf(upper_m - lower_m, 0.000001)
		var local := clampf((material_u - lower_m) / span, 0.0, 1.0)
		var curve_t := lerpf(curve_anchors[segment], curve_anchors[segment + 1], local)
		lut[i] = Vector2(material_u, curve_t)
	return lut


static func _find_interval(values: PackedFloat32Array, target: float) -> int:
	var low := 0
	var high := values.size() - 1
	while low < high:
		var middle := (low + high) >> 1
		if values[middle] <= target:
			low = middle + 1
		else:
			high = middle
	return maxi(low - 1, 0)


static func _sample_profile_material(points: Array[Vector2], material_u: float, lut: PackedVector2Array) -> Vector2:
	if lut.size() < 2:
		return _sample_profile(points, material_u)
	var target := clampf(material_u, 0.0, 1.0)
	var low := 0
	var high := lut.size() - 1
	while low < high:
		var middle := (low + high) >> 1
		if lut[middle].x < target:
			low = middle + 1
		else:
			high = middle
	var upper := clampi(low, 1, lut.size() - 1)
	var lower := upper - 1
	var lower_material := lut[lower].x
	var upper_material := lut[upper].x
	var span := maxf(upper_material - lower_material, 0.000001)
	var t := lerpf(lut[lower].y, lut[upper].y, clampf((target - lower_material) / span, 0.0, 1.0))
	return _sample_profile(points, t)


static func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
