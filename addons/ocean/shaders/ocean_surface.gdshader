render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D crest_foam_long : repeat_enable, filter_linear;
uniform sampler2D crest_foam_mid : repeat_enable, filter_linear;
uniform sampler2D crest_foam_short : repeat_enable, filter_linear;
uniform sampler2D crest_breakup_texture : repeat_enable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 short_fade_range_m = vec2(0.0, 55.0);
uniform vec2 mid_fade_range_m = vec2(96.0, 280.0);
uniform vec2 long_fade_range_m = vec2(768.0, 2500.0);
uniform vec2 camera_world_xz;
uniform vec3 deep_water_color = vec3(0.019474017, 0.0909042, 0.088472255);
uniform vec3 horizon_water_color = vec3(0.0075189536, 0.07750165, 0.04554274);
uniform int debug_view = 0;
uniform bool coastal_enabled = false;
uniform sampler2D coastal_field : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics : repeat_disable, filter_linear;
uniform sampler2D coastal_phase : repeat_disable, filter_linear;
uniform sampler2D coastal_warp : repeat_disable, filter_linear;
uniform sampler2D coastal_jacobian : repeat_disable, filter_linear;
uniform vec2 coastal_origin = vec2(0.0);
uniform vec2 coastal_extent = vec2(1.0);
uniform vec2 coastal_warp_origin = vec2(0.0);
uniform vec2 coastal_warp_extent = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;

// P2 Crest V3 Core. Surface Foam and Direct-J topology are intentionally absent.
uniform bool crest_foam_enabled = true;
uniform float crest_foam_intensity = 0.96;
uniform float crest_foam_contrast = 1.19;
uniform vec2 crest_foam_distance_fade_range_m = vec2(0.0, 5000.0);
uniform float crest_foam_detail_contribution = 0.35;
uniform float crest_foam_breakup_strength = 0.45;
uniform float crest_foam_breakup_world_size_m = 14.0;
uniform float crest_foam_edge_softness = 0.32;
uniform vec3 crest_foam_residual_color : source_color = vec3(1.84945);
uniform float crest_foam_residual_roughness = 0.88;
uniform float crest_foam_residual_specular = 0.18;

varying vec2 ocean_base_xz;

float fade_weight(float distance_m, vec2 range_m) { return 1.0 - smoothstep(range_m.x, range_m.y, distance_m); }
vec2 world_uv(vec2 world_xz, float domain_m) { return world_xz / domain_m + vec2(0.5); }
vec2 coastal_uv(vec2 world_xz, vec2 origin, vec2 extent) { return (world_xz - origin) / max(extent, vec2(0.001)); }
float coastal_confidence(vec4 warp) { return smoothstep(0.0, coastal_warp_detj_safe, warp.z) * warp.w; }

float crest_breakup_mask(vec2 base_xz) {
	float noise = texture(crest_breakup_texture, base_xz / crest_foam_breakup_world_size_m).r;
	float softness = clamp(crest_foam_edge_softness, 0.01, 0.49);
	float breakup = mix(0.25, 1.0, smoothstep(0.5 - softness, 0.5 + softness, noise));
	return mix(1.0, breakup, crest_foam_breakup_strength);
}

void vertex() {
	vec2 world_xz = MODEL_MATRIX[3].xz + VERTEX.xz;
	ocean_base_xz = world_xz;
	float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m);
	float mid_weight = fade_weight(distance_m, mid_fade_range_m);
	float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 long_displacement = texture(displacement_long, world_uv(world_xz, domain_long_m)).xyz;
	if (coastal_enabled) {
		vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
		if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
			vec4 field = texture(coastal_field, coast_uv);
			vec4 warp = texture(coastal_warp, clamp(coastal_uv(world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
			float confidence = field.a * coastal_confidence(warp);
			long_displacement = mix(long_displacement, texture(displacement_long, world_uv(warp.xy, domain_long_m)).xyz, confidence);
			long_displacement.y *= mix(1.0, field.g, confidence);
		}
	}
	VERTEX += long_displacement * long_weight + texture(displacement_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight + texture(displacement_short, world_uv(world_xz, domain_short_m)).xyz * short_weight;
}

void fragment() {
	vec2 world_xz = ocean_base_xz;
	float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m);
	float mid_weight = fade_weight(distance_m, mid_fade_range_m);
	float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 long_normal = texture(normal_long, world_uv(world_xz, domain_long_m)).xyz;
	if (coastal_enabled) {
		vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
		if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
			vec4 field = texture(coastal_field, coast_uv);
			vec4 warp = texture(coastal_warp, clamp(coastal_uv(world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
			long_normal = mix(long_normal, texture(normal_long, world_uv(warp.xy, domain_long_m)).xyz, field.a * coastal_confidence(warp));
		}
	}
	NORMAL = normalize(long_normal * long_weight + texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight + texture(normal_short, world_uv(world_xz, domain_short_m)).xyz * short_weight);
	ALBEDO = mix(deep_water_color, horizon_water_color, smoothstep(200.0, 2500.0, distance_m));
	ROUGHNESS = 0.08; METALLIC = 0.0; SPECULAR = 0.9;
	if (crest_foam_enabled) {
		float long_foam = texture(crest_foam_long, world_uv(world_xz, domain_long_m)).r * long_weight;
		float mid_detail = texture(crest_foam_mid, world_uv(world_xz, domain_mid_m)).r * mid_weight * crest_foam_detail_contribution * 0.55;
		float short_detail = texture(crest_foam_short, world_uv(world_xz, domain_short_m)).r * short_weight * crest_foam_detail_contribution * 0.30;
		float detail = 1.0 - (1.0 - mid_detail) * (1.0 - short_detail);
		float raw_foam = 1.0 - (1.0 - clamp(long_foam, 0.0, 1.0)) * (1.0 - detail);
		float shaped = pow(smoothstep(0.0, 1.0, raw_foam), 1.0 / max(crest_foam_contrast, 0.1));
		float distance_fade = 1.0 - smoothstep(crest_foam_distance_fade_range_m.x, max(crest_foam_distance_fade_range_m.y, crest_foam_distance_fade_range_m.x + 0.001), distance_m);
		float crest = clamp(shaped * crest_foam_intensity * crest_breakup_mask(world_xz) * distance_fade, 0.0, 1.0);
		ALBEDO = mix(ALBEDO, crest_foam_residual_color, crest);
		ROUGHNESS = mix(ROUGHNESS, crest_foam_residual_roughness, crest);
		SPECULAR = mix(SPECULAR, crest_foam_residual_specular, crest);
	}
	if (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;
}
