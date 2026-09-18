shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D breaking_activity_long : repeat_enable, filter_linear;
uniform vec2 mask_origin = vec2(0.0);
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform float ocean_surface_scale = 1.0;
uniform float clipmap_geometry_scale = 1.0;
uniform float long_fade_start_m = 768.0;
uniform float long_fade_end_m = 2500.0;
uniform float active_radius_m = 48.0;
uniform float event_trigger_threshold = 0.72;
// 0 = raw authority, 1 = trigger visualization, 2 = active-region gated,
// 3 = active-radius fade. Every non-forced value starts from Crest G.
uniform int debug_output = 0;
// 0 = real source, 1 = forced black, 2 = forced white.
uniform int source_override = 0;

varying float source_value;

vec2 ocean_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

float fade_weight(float distance_m, float start_m, float end_m) {
	return 1.0 - smoothstep(start_m, max(end_m, start_m + 0.001), distance_m);
}

float breaking_activity(vec2 world_xz) {
	// This is the same semantic source consumed by the sensor shader. Crest R
	// is residual foam and is intentionally not part of the debug source.
	return clamp(texture(breaking_activity_long, ocean_uv(world_xz, domain_long_m)).g, 0.0, 1.0);
}

vec3 ocean_space_displacement(vec3 authored) {
	return vec3(
		authored.x * clipmap_geometry_scale,
		authored.y * ocean_surface_scale,
		authored.z * clipmap_geometry_scale
	);
}

void vertex() {
	vec2 world_xz = mask_origin + VERTEX.xz;
	float distance_m = distance(world_xz, mask_origin);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	float mid_weight = 1.0 - smoothstep(96.0, 280.0, distance_m);
	float short_weight = 1.0 - smoothstep(0.0, 55.0, distance_m);
	vec3 authored = texture(displacement_long, ocean_uv(world_xz, domain_long_m)).xyz * long_weight;
	authored += texture(displacement_mid, ocean_uv(world_xz, domain_mid_m)).xyz * mid_weight;
	authored += texture(displacement_short, ocean_uv(world_xz, domain_short_m)).xyz * short_weight;
	vec3 displacement = ocean_space_displacement(authored);
	if (source_override != 0) displacement = vec3(0.0);
	VERTEX.xz += displacement.xz;
	VERTEX.y = sea_level + displacement.y + 0.035;

	if (source_override == 1) {
		source_value = 0.0;
	} else if (source_override == 2) {
		source_value = 1.0;
	} else {
		float activity = breaking_activity(world_xz);
		float radius_fade = 1.0 - smoothstep(active_radius_m * 0.82, max(active_radius_m, active_radius_m * 0.82 + 0.001), distance_m);
		float trigger_gate = smoothstep(event_trigger_threshold, min(event_trigger_threshold + 0.02, 1.0), activity);
		if (debug_output == 1) {
			source_value = trigger_gate;
		} else if (debug_output == 2) {
			source_value = activity * radius_fade;
		} else if (debug_output == 3) {
			source_value = radius_fade;
		} else {
			source_value = activity;
		}
	}
}

void fragment() {
	ALBEDO = vec3(source_value);
	ALPHA = 1.0;
}
