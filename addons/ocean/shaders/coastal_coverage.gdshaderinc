// PHYS-OPT-2I canonical coverage contract. Authored cells = extent/(size-1).
// Keep equivalent to coastal_coverage.h and coastal_coverage_contract.gd.
const float COASTAL_COVERAGE_FEATHER_TEXELS = 1.0;
float coastal_coverage_edge_weight(vec2 uv, ivec2 field_size) {
	vec2 cells = min(uv, vec2(1.0) - uv) * vec2(field_size - ivec2(1));
	float t = clamp(min(cells.x, cells.y) / COASTAL_COVERAGE_FEATHER_TEXELS, 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}
