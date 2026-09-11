class_name P7BreakerShapeVDMGenerator
extends RefCounted
## Synthetic, signed vector-displacement test shape for the isolated 2C1 lab.

const RESOLUTION := 256
const SECTION_A: Array[Vector2] = [Vector2(-6.00, 0.00), Vector2(-4.50, 0.00), Vector2(-2.30, 0.65), Vector2(-0.80, 1.80)]
const SECTION_B: Array[Vector2] = [Vector2(-0.80, 1.80), Vector2(0.35, 2.85), Vector2(1.85, 3.75), Vector2(2.85, 3.20)]
const SECTION_C: Array[Vector2] = [Vector2(2.85, 3.20), Vector2(3.45, 2.75), Vector2(3.00, 1.55), Vector2(1.60, 0.95)]
const SECTION_D: Array[Vector2] = [Vector2(1.60, 0.95), Vector2(1.20, 0.65), Vector2(3.20, 0.15), Vector2(6.00, 0.00)]


static func build() -> ImageTexture:
	var image := Image.create(RESOLUTION, RESOLUTION, false, Image.FORMAT_RGBAH)
	for y in RESOLUTION:
		var v := (float(y) + 0.5) / float(RESOLUTION)
		var rear_boundary := _smoothstep(0.00, 0.08, v)
		var front_boundary := 1.0 - _smoothstep(0.96, 1.00, v)
		var source_s := (v - 0.5) * 12.0
		for x in RESOLUTION:
			var u := (float(x) + 0.5) / float(RESOLUTION)
			var lateral := u * 2.0 - 1.0
			var lateral_authority := 1.0 - _smoothstep(0.82, 1.0, absf(lateral))
			var authority := lateral_authority * rear_boundary * front_boundary
			var phase_shift_v := 0.010 * sin(lateral * PI * 2.0) + 0.004 * sin(lateral * PI * 5.0 + 0.7)
			var shaped_v := clampf(v + phase_shift_v, 0.0, 1.0)
			var profile := _sample_bezier_profile(shaped_v)
			var crest_scale := 1.0 + 0.035 * sin(lateral * PI * 3.0 + 1.2)
			var crest_influence := _smoothstep(1.0, 2.0, profile.y)
			var target_y := lerpf(profile.y, profile.y * crest_scale, crest_influence)
			var tangent_displacement := 0.11 * sin(lateral * PI * 2.0) * lateral_authority
			var propagation_displacement := profile.x - source_s
			image.set_pixel(x, y, Color(tangent_displacement * authority, target_y * authority, propagation_displacement * authority, authority))
	return ImageTexture.create_from_image(image)


static func _sample_bezier_profile(v: float) -> Vector2:
	var clamped_v := clampf(v, 0.0, 1.0)
	if clamped_v < 0.40:
		return _cubic_bezier(SECTION_A, clamped_v / 0.40)
	if clamped_v < 0.65:
		return _cubic_bezier(SECTION_B, (clamped_v - 0.40) / 0.25)
	if clamped_v < 0.84:
		return _cubic_bezier(SECTION_C, (clamped_v - 0.65) / 0.19)
	return _cubic_bezier(SECTION_D, (clamped_v - 0.84) / 0.16)


static func _cubic_bezier(points: Array[Vector2], t: float) -> Vector2:
	var p0: Vector2 = points[0]
	var p1: Vector2 = points[1]
	var p2: Vector2 = points[2]
	var p3: Vector2 = points[3]
	var one_minus_t := 1.0 - t
	return one_minus_t * one_minus_t * one_minus_t * p0 \
		+ 3.0 * one_minus_t * one_minus_t * t * p1 \
		+ 3.0 * one_minus_t * t * t * p2 \
		+ t * t * t * p3


static func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
