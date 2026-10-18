#include "res://addons/ocean/areas/wave_area_math.gdshaderinc"
uniform int wave_area_count = 0;
uniform mat4 wave_area_inverse[8];
uniform vec4 wave_area_shape[8];
uniform vec4 wave_area_blend[8];
uniform vec4 wave_area_settings[8];
uniform vec4 wave_area_wind[8];
uniform vec4 wave_area_meta[8];
uniform vec4 wave_area_groups[8];
uniform vec4 wave_area_components0[256];
uniform vec4 wave_area_components1[256];
uniform float wave_area_detail_strength[8];
uniform float wave_area_time = 0.0;
uniform float wave_area_sea_level = 0.0;
varying float wave_area_base_height;

float wave_area_coverage(vec3 p) {
	float value = 0.0;
	for (int i = 0; i < wave_area_count; i++) {
		float w = wave_area_weight(p,wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])*wave_area_meta[i].z;
		value = mix(value,1.0,w);
	}
	return value;
}

float wave_area_detail_weight(vec3 p) {
	float value = 1.0;
	for (int i = 0; i < wave_area_count; i++) {
		float w = wave_area_weight(p,wave_area_inverse[i],wave_area_shape[i],wave_area_blend[i])*wave_area_meta[i].z;
		value = mix(value,wave_area_detail_strength[i],w);
	}
	return value;
}

vec4 wave_area_local(int index, vec2 p) {
	vec4 value = vec4(0.0);
	for (int j = 0; j < 32; j++) {
		if (j >= int(wave_area_meta[index].x)) { break; }
		int n = index*32+j;
		value += wave_area_component(p,wave_area_components0[n],wave_area_components1[n],wave_area_time);
	}
	return wave_area_group(p,value,wave_area_groups[index],wave_area_wind[index].w,wave_area_time);
}

float wave_area_foam_weight(vec3 p) {
	float result = 1.0;
	for (int i = 0; i < wave_area_count; i++) {
		float w = wave_area_weight(p, wave_area_inverse[i], wave_area_shape[i], wave_area_blend[i]) * wave_area_meta[i].z;
		float steepness = wave_area_settings[i].x * 3.14159265 / max(wave_area_settings[i].y, 0.1);
		result = mix(result, clamp(steepness / 0.25 * wave_area_meta[i].y, 0.0, 1.0), w);
	}
	return result;
}

vec4 wave_areas_compose(vec3 p, vec4 base) {
	vec4 value = base;
	for (int i = 0; i < wave_area_count; i++) {
		float w = wave_area_weight(p, wave_area_inverse[i], wave_area_shape[i], wave_area_blend[i]) * wave_area_meta[i].z;
		if (w <= 0.0) { continue; }
		float e = 0.05;
		vec2 dw = vec2(
			wave_area_weight(p + vec3(e,0.0,0.0), wave_area_inverse[i], wave_area_shape[i], wave_area_blend[i]) - wave_area_weight(p - vec3(e,0.0,0.0), wave_area_inverse[i], wave_area_shape[i], wave_area_blend[i]),
			wave_area_weight(p + vec3(0.0,0.0,e), wave_area_inverse[i], wave_area_shape[i], wave_area_blend[i]) - wave_area_weight(p - vec3(0.0,0.0,e), wave_area_inverse[i], wave_area_shape[i], wave_area_blend[i])) / (2.0 * e);
		dw *= wave_area_meta[i].z;
		vec4 local = wave_area_local(i,p.xz);
		value.yz = mix(value.yz, local.yz, w) + dw * (local.x - value.x);
		value.x = mix(value.x, local.x, w);
		value.w = mix(value.w, local.w, w);
	}
	return value;
}
