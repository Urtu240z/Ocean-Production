shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
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

float fade_weight(float distance_m, vec2 range_m) { return 1.0 - smoothstep(range_m.x, range_m.y, distance_m); }
vec2 world_uv(vec2 world_xz, float domain_m) { return world_xz / domain_m + vec2(0.5); }
vec2 coastal_uv(vec2 world_xz, vec2 origin, vec2 extent) { return (world_xz - origin) / max(extent, vec2(0.001)); }
float coastal_confidence(vec4 warp) { return smoothstep(0.0, coastal_warp_detj_safe, warp.z) * warp.w; }
void vertex() {
	vec2 world_xz = MODEL_MATRIX[3].xz + VERTEX.xz; float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m); float mid_weight = fade_weight(distance_m, mid_fade_range_m); float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 long_displacement = texture(displacement_long, world_uv(world_xz, domain_long_m)).xyz;
	if (coastal_enabled) {
		vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
		if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
			vec4 field = texture(coastal_field, coast_uv); vec2 warp_uv = coastal_uv(world_xz, coastal_warp_origin, coastal_warp_extent); vec4 warp = texture(coastal_warp, clamp(warp_uv, vec2(0.0), vec2(1.0)));
			float confidence = field.a * coastal_confidence(warp); vec3 warped = texture(displacement_long, world_uv(warp.xy, domain_long_m)).xyz;
			long_displacement = mix(long_displacement, warped, confidence); long_displacement.y *= mix(1.0, field.g, confidence);
		}
	}
	vec3 mid_displacement = texture(displacement_mid, world_uv(world_xz, domain_mid_m)).xyz;
	vec3 short_displacement = texture(displacement_short, world_uv(world_xz, domain_short_m)).xyz;
	VERTEX += long_displacement * long_weight + mid_displacement * mid_weight + short_displacement * short_weight;
}
void fragment() {
	vec2 world_xz = MODEL_MATRIX[3].xz + VERTEX.xz; float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m); float mid_weight = fade_weight(distance_m, mid_fade_range_m); float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 long_normal = texture(normal_long, world_uv(world_xz, domain_long_m)).xyz;
	if (coastal_enabled) { vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent); if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) { vec4 field = texture(coastal_field, coast_uv); vec4 warp = texture(coastal_warp, clamp(coastal_uv(world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0))); long_normal = mix(long_normal, texture(normal_long, world_uv(warp.xy, domain_long_m)).xyz, field.a * coastal_confidence(warp)); } }
	vec3 n = long_normal * long_weight + texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight + texture(normal_short, world_uv(world_xz, domain_short_m)).xyz * short_weight;
	NORMAL = normalize(n); ALBEDO = mix(deep_water_color, horizon_water_color, smoothstep(200.0, 2500.0, distance_m)); ROUGHNESS = 0.08; METALLIC = 0.0; SPECULAR = 0.9;
	if (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;
}
