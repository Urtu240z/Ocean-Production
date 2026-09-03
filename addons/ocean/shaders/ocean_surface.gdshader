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

float fade_weight(float distance_m, vec2 range_m) { return 1.0 - smoothstep(range_m.x, range_m.y, distance_m); }
vec2 world_uv(vec2 world_xz, float domain_m) { return world_xz / domain_m + vec2(0.5); }
void vertex() {
	vec2 world_xz = MODEL_MATRIX[3].xz + VERTEX.xz; float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m); float mid_weight = fade_weight(distance_m, mid_fade_range_m); float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 long_displacement = texture(displacement_long, world_uv(world_xz, domain_long_m)).xyz;
	vec3 mid_displacement = texture(displacement_mid, world_uv(world_xz, domain_mid_m)).xyz;
	vec3 short_displacement = texture(displacement_short, world_uv(world_xz, domain_short_m)).xyz;
	VERTEX += long_displacement * long_weight + mid_displacement * mid_weight + short_displacement * short_weight;
}
void fragment() {
	vec2 world_xz = MODEL_MATRIX[3].xz + VERTEX.xz; float distance_m = distance(world_xz, camera_world_xz);
	float long_weight = fade_weight(distance_m, long_fade_range_m); float mid_weight = fade_weight(distance_m, mid_fade_range_m); float short_weight = fade_weight(distance_m, short_fade_range_m);
	vec3 n = texture(normal_long, world_uv(world_xz, domain_long_m)).xyz * long_weight + texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight + texture(normal_short, world_uv(world_xz, domain_short_m)).xyz * short_weight;
	NORMAL = normalize(n); ALBEDO = mix(deep_water_color, horizon_water_color, smoothstep(200.0, 2500.0, distance_m)); ROUGHNESS = 0.08; METALLIC = 0.0; SPECULAR = 0.9;
	if (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;
}
