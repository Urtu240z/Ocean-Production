@tool
extends RefCounted
## Apply to every surface source, including the foam director's preserved variants.
const INCLUDE := '#include "res://addons/ocean/areas/wave_area_surface.gdshaderinc"'
const VERTEX := '''
	wave_area_base_height = surface_displacement.y * max(length(MODEL_MATRIX[1].xyz), 0.001);
	wave_area_q = wave_sample_xz;
	if (wave_area_count > 0) {
		surface_displacement = wave_areas_displacement(vec3(wave_sample_xz.x, wave_area_sea_level, wave_sample_xz.y), surface_displacement);
		surface_foam_displacement_xz = surface_displacement.xz;
	}
'''
const NORMAL := '''
	if (wave_area_count > 0 && wave_area_coverage(vec3(wave_area_q.x, wave_area_sea_level, wave_area_q.y)) > 0.0) {
		vec2 area_slope = -shading_normal_world.xz / max(shading_normal_world.y, 0.01);
		vec4 area_wave = wave_areas_compose(vec3(wave_area_q.x, wave_area_sea_level, wave_area_q.y), vec4(wave_area_base_height, area_slope, 0.0));
		shading_normal_world = normalize(vec3(-area_wave.y, 1.0, -area_wave.z));
	}
'''

static func inject(source: String) -> String:
	if source.contains(INCLUDE): return source
	source = source.replace("void vertex() {", INCLUDE + "\nvoid vertex() {")
	var vertex_anchor := "\tif (hull_waves_enabled) { surface_displacement.y +="
	if not source.contains(vertex_anchor): vertex_anchor = "\tVERTEX += surface_displacement;"
	source = source.replace(vertex_anchor, VERTEX + vertex_anchor)
	var normal_anchor := "\tif (hull_waves_enabled) { vec2 slope="
	if not source.contains(normal_anchor): normal_anchor = "\tvec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);"
	source = source.replace(normal_anchor, NORMAL + normal_anchor)
	var crest_anchor := "\t\tif (crest_filigree_enabled) {"
	source = source.replace(crest_anchor, "\t\tcrest *= wave_area_foam_weight(vec3(ocean_world_position.x, wave_area_sea_level, ocean_world_position.z));\n" + crest_anchor)
	var foam_anchor := "\t\tmask *= mid_gate * clamp(surface_air_blend, 0.0, 1.0);"
	source = source.replace(foam_anchor, foam_anchor + "\n\t\tmask *= wave_area_foam_weight(vec3(ocean_world_position.x, wave_area_sea_level, ocean_world_position.z));")
	return source
