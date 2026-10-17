extends RefCounted
## Same authored-cell contract as coastal_coverage.h / coastal_coverage.gdshaderinc.
const FEATHER_TEXELS := 1.0

static func edge_weight(uv: Vector2, resolution: Vector2i) -> float:
	var cells := Vector2(minf(uv.x, 1.0 - uv.x), minf(uv.y, 1.0 - uv.y)) * Vector2(resolution - Vector2i.ONE)
	var t := clampf(minf(cells.x, cells.y) / FEATHER_TEXELS, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
