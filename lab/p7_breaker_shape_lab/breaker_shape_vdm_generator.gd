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
		6: _build_landmark_material_lut(_curve_landmark_parameters(PROFILE_P6), shared_material_anchors),
	}
	return luts


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
