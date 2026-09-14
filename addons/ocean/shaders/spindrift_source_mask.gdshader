shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D crest_foam_long : repeat_enable, filter_linear;
uniform sampler2D crest_foam_mid : repeat_enable, filter_linear;
uniform sampler2D crest_foam_short : repeat_enable, filter_linear;
uniform vec2 mask_origin = vec2(0.0);
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform float crest_threshold = 0.58;
uniform float crest_softness = 0.16;
uniform float min_wave_strength = 0.12;
uniform float storm_strength = 0.85;
uniform float wave_height_reference_m = 2.5;
uniform int source_debug_stage = 0;

varying float source_value;

vec2 ocean_uv(vec2 world_xz, float domain_m) { return world_xz / max(domain_m, 0.001) + vec2(0.5); }

void vertex() {
	vec2 world_xz = mask_origin + VERTEX.xz;
	vec3 displacement = texture(displacement_long, ocean_uv(world_xz, domain_long_m)).xyz * 0.55
		+ texture(displacement_mid, ocean_uv(world_xz, domain_mid_m)).xyz * 0.30
		+ texture(displacement_short, ocean_uv(world_xz, domain_short_m)).xyz * 0.15;
	VERTEX.y = sea_level + displacement.y + 0.035;
	float long_crest = texture(crest_foam_long, ocean_uv(world_xz, domain_long_m)).r;
	float mid_crest = texture(crest_foam_mid, ocean_uv(world_xz, domain_mid_m)).r;
	float short_crest = texture(crest_foam_short, ocean_uv(world_xz, domain_short_m)).r;
	float crest = 1.0 - (1.0 - long_crest) * (1.0 - mid_crest) * (1.0 - short_crest);
	vec3 normal = normalize(texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz * 0.55
		+ texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz * 0.30
		+ texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz * 0.15);
	float steepness = length(normal.xz) / max(abs(normal.y), 0.08);
	float steep_gate = smoothstep(0.12, 0.72, steepness);
	float height_gate = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), abs(displacement.y) / max(wave_height_reference_m, 0.01));
	float crest_gate = smoothstep(crest_threshold, crest_threshold + max(crest_softness, 0.01), crest);
	if (source_debug_stage == 1) {
		source_value = clamp(height_gate * storm_strength, 0.0, 1.0);
	} else if (source_debug_stage == 2) {
		source_value = clamp(steep_gate * storm_strength, 0.0, 1.0);
	} else if (source_debug_stage == 3) {
		source_value = clamp(crest_gate * storm_strength, 0.0, 1.0);
	} else {
		source_value = clamp(crest_gate * mix(0.45, 1.0, steep_gate) * mix(0.35, 1.0, height_gate) * storm_strength, 0.0, 1.0);
	}
}

void fragment() {
	ALBEDO = vec3(source_value);
	ALPHA = 1.0;
}
