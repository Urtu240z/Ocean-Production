#include "res://addons/ocean/surface/foam2d/hull_wave_sampling.gdshaderinc"
uniform bool hull_waves_enabled = false;
uniform bool hull_waves_physical = false;
uniform sampler2D hull_waves_texture : filter_linear, repeat_disable;
uniform sampler2D hull_waves_previous_texture : filter_linear, repeat_disable;
uniform vec2 hull_waves_origin = vec2(0.0);
uniform vec2 hull_waves_previous_origin = vec2(0.0);
uniform float hull_waves_blend = 1.0;
uniform float hull_waves_max_height = 2.0;
uniform int hull_waves_debug = 0;
vec3 hull_wave_sample(vec2 world) {
	if (!hull_waves_enabled) { return vec3(0.0); }
	return hull_wave_projected_sample(hull_waves_texture, hull_waves_previous_texture,
		world, hull_waves_origin, hull_waves_previous_origin, hull_waves_blend,
		hull_waves_max_height, hull_waves_physical, camera_world_xz);
}
