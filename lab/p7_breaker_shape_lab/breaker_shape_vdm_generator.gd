class_name P7BreakerShapeVDMGenerator
extends RefCounted
## Synthetic, signed vector-displacement test shape for the isolated 2C1 lab.

const RESOLUTION := 256
const PROFILE: Array[Vector2] = [
	Vector2(-6.00, 0.00),
	Vector2(-5.10, 0.05),
	Vector2(-3.75, 0.25),
	Vector2(-2.25, 0.80),
	Vector2(-0.70, 1.75),
	Vector2(0.65, 2.75),
	Vector2(1.75, 3.35),
	Vector2(2.65, 3.45),
	Vector2(3.20, 2.90),
	Vector2(2.85, 2.10),
	Vector2(2.15, 1.25),
	Vector2(1.85, 0.65),
	Vector2(3.60, 0.20),
	Vector2(6.00, 0.00),
]
const PROFILE_V: Array[float] = [
	0.00, 0.12, 0.25, 0.38, 0.50, 0.60, 0.68, 0.74, 0.79, 0.84,
	0.89, 0.93, 0.96, 1.00,
]


static func build() -> ImageTexture:
	var image := Image.create(RESOLUTION, RESOLUTION, false, Image.FORMAT_RGBAH)
	for y in RESOLUTION:
		var v := (float(y) + 0.5) / float(RESOLUTION)
		var profile := _sample_plunging_profile(v)
		var source_s := (v - 0.5) * 12.0
		var propagation_displacement := profile.x - source_s
		var vertical_displacement := profile.y
		var rear_boundary := _smoothstep(0.00, 0.08, v)
		var front_boundary := 1.0 - _smoothstep(0.96, 1.00, v)
		for x in RESOLUTION:
			var u := (float(x) + 0.5) / float(RESOLUTION)
			var lateral := u * 2.0 - 1.0
			var lateral_authority := 1.0 - _smoothstep(0.78, 1.0, absf(lateral))
			var authority := lateral_authority * rear_boundary * front_boundary
			image.set_pixel(x, y, Color(0.0, vertical_displacement * authority, propagation_displacement * authority, authority))
	return ImageTexture.create_from_image(image)


static func _sample_plunging_profile(v: float) -> Vector2:
	var clamped_v := clampf(v, 0.0, 1.0)
	if clamped_v <= PROFILE_V[0]:
		return PROFILE[0]
	if clamped_v >= PROFILE_V[PROFILE_V.size() - 1]:
		return PROFILE[PROFILE.size() - 1]
	var segment := 0
	for index in range(PROFILE_V.size() - 1):
		if clamped_v <= PROFILE_V[index + 1]:
			segment = index
			break
	var t := (clamped_v - PROFILE_V[segment]) / (PROFILE_V[segment + 1] - PROFILE_V[segment])
	var p0 := PROFILE[maxi(segment - 1, 0)]
	var p1 := PROFILE[segment]
	var p2 := PROFILE[segment + 1]
	var p3 := PROFILE[mini(segment + 2, PROFILE.size() - 1)]
	var t2 := t * t
	var t3 := t2 * t
	var value := 0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
	return Vector2(
		clampf(value.x, minf(p1.x, p2.x), maxf(p1.x, p2.x)),
		clampf(value.y, minf(p1.y, p2.y), maxf(p1.y, p2.y))
	)


static func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
