class_name P7BreakerShapeVDMGenerator
extends RefCounted
## Synthetic, signed vector-displacement test shape for the isolated 2C1 lab.

const RESOLUTION := 256


static func build() -> ImageTexture:
	var image := Image.create(RESOLUTION, RESOLUTION, false, Image.FORMAT_RGBAH)
	for y in RESOLUTION:
		var v := (float(y) + 0.5) / float(RESOLUTION)
		var rear_fade := _smoothstep(0.08, 0.22, v)
		var front_fade := 1.0 - _smoothstep(0.92, 1.0, v)
		for x in RESOLUTION:
			var u := (float(x) + 0.5) / float(RESOLUTION)
			var lateral := u * 2.0 - 1.0
			var lateral_mask := 1.0 - _smoothstep(0.70, 1.0, absf(lateral))
			var envelope := lateral_mask * rear_fade * front_fade
			var crest := exp(-pow((v - 0.62) / 0.16, 2.0))
			var nose := exp(-pow((v - 0.74) / 0.10, 2.0))
			var falling_tip := _smoothstep(0.70, 0.84, v) * (1.0 - _smoothstep(0.90, 0.99, v))
			var tangent_displacement := 0.0
			var vertical_displacement := (2.8 * crest - 1.4 * falling_tip) * envelope
			var propagation_displacement := (3.0 * nose - 0.8 * _smoothstep(0.84, 0.98, v)) * envelope
			image.set_pixel(x, y, Color(tangent_displacement, vertical_displacement, propagation_displacement, envelope))
	return ImageTexture.create_from_image(image)


static func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
