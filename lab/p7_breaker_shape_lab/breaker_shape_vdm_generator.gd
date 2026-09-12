class_name P7BreakerShapeVDMGenerator
extends RefCounted
## Authored multi-phase 2D vector-displacement atlas for the 2E1 LAB.

const TILE_SIZE := 256
const PHASE_COUNT := 8
const ATLAS_HEIGHT := TILE_SIZE * PHASE_COUNT
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
const PROFILE_P5: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.7, 0.12), Vector2(-2.9, 0.75), Vector2(-0.8, 1.95), Vector2(0.80, 3.55), Vector2(2.75, 3.15), Vector2(3.45, 2.35), Vector2(1.70, 1.45), Vector2(0.45, 0.72), Vector2(1.35, 0.28), Vector2(3.9, 0.12), Vector2(6.0, 0.0)]
const PROFILE_P6: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.7, 0.10), Vector2(-2.8, 0.58), Vector2(-0.7, 1.35), Vector2(0.55, 2.10), Vector2(1.75, 1.75), Vector2(2.25, 1.05), Vector2(1.35, 0.58), Vector2(3.8, 0.18), Vector2(6.0, 0.0)]
const PROFILE_P7: Array[Vector2] = [Vector2(-6.0, 0.0), Vector2(-4.8, 0.06), Vector2(-3.1, 0.28), Vector2(-1.2, 0.52), Vector2(0.55, 0.68), Vector2(2.1, 0.48), Vector2(3.7, 0.20), Vector2(6.0, 0.0)]


static func build() -> ImageTexture:
	var image := Image.create(TILE_SIZE, ATLAS_HEIGHT, false, Image.FORMAT_RGBAH)
	for phase_index in PHASE_COUNT:
		var profile := _profile_for_phase(phase_index)
		for y in TILE_SIZE:
			var shore_v := (float(y) + 0.5) / float(TILE_SIZE)
			var lateral := shore_v * 2.0 - 1.0
			var edge_asymmetry := 1.0 + 0.025 * sin(lateral * PI + float(phase_index) * 0.37)
			for x in TILE_SIZE:
				var profile_u := (float(x) + 0.5) / float(TILE_SIZE)
				var base_s := (profile_u - 0.5) * 12.0
				var profile_point := _sample_profile(profile, profile_u)
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
	return ImageTexture.create_from_image(image)


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


static func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
