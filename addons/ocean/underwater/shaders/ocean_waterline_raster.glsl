#[vertex]
#version 450

layout(location = 0) in vec3 vertex_position;
layout(set = 0, binding = 0) uniform sampler2D displacement_long;
layout(set = 0, binding = 1) uniform sampler2D displacement_mid;
layout(set = 0, binding = 2) uniform sampler2D displacement_short;
layout(set = 0, binding = 4) uniform sampler2D coastal_field;
layout(set = 0, binding = 5) uniform sampler2D coastal_warp;
layout(set = 0, binding = 6) uniform sampler2D breaker_phase;
layout(set = 0, binding = 7) uniform sampler2D breaker_metrics;
layout(set = 0, binding = 8) uniform sampler2D breaker_normal_long;
layout(set = 0, binding = 3, std140) uniform RasterParams {
	mat4 view_projection;
	mat4 inverse_view_projection;
	vec4 camera_sea;
	vec4 domains;
	vec4 ocean_space; // x = H clipmap geometry scale, y = V ocean scale
	vec4 coastal_origin_extent; // xy origin, zw extent
	vec4 coastal_warp_origin_extent; // xy warp origin, zw warp extent
	vec4 coastal_control; // x enabled, y warp_detj_safe
	vec4 breaker_0; // strength, shallow start/end, deep start
	vec4 breaker_1; // deep end, shoaling start/full, detj start
	vec4 breaker_2; // detj full, crest height start/full, front slope start
	vec4 breaker_3; // front slope full, forward push, face compression, crest lift
	vec4 breaker_4; // crest curve, pre-lip strength/forward/lift
	vec4 breaker_5; // max horizontal/vertical, enabled, reserved
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
} params;
layout(push_constant, std430) uniform DrawParams {
	mat4 model;
} draw_params;

float fade_weight(float distance_m, vec2 range_m) {
	return 1.0 - smoothstep(range_m.x, range_m.y, distance_m);
}

vec3 ocean_space_displacement(vec3 authored_displacement) {
	float horizontal_scale = params.ocean_space.x;
	float vertical_scale = params.ocean_space.y;
	return vec3(
		authored_displacement.x * horizontal_scale,
		authored_displacement.y * vertical_scale,
		authored_displacement.z * horizontal_scale
	);
}

vec2 world_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

vec2 coastal_uv_from_world(vec2 world_xz, vec2 origin, vec2 extent) {
	return (world_xz - origin) / max(extent, vec2(0.001));
}

float coastal_confidence_value(vec4 warp, float detj_safe) {
	return smoothstep(0.0, detj_safe, warp.z) * warp.w;
}

vec2 breaker_safe_direction(vec2 direction) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : vec2(0.0, 1.0);
}

vec3 ocean_space_normal_to_world_scaled(vec3 n) {
	const float epsilon = 0.00001;
	if (any(isnan(n)) || any(isinf(n))) return vec3(0.0, 1.0, 0.0);
	float horizontal_scale = max(abs(params.ocean_space.x), epsilon);
	float vertical_scale = max(abs(params.ocean_space.y), epsilon);
	vec3 transformed = vec3(n.x * vertical_scale / horizontal_scale, n.y, n.z * vertical_scale / horizontal_scale);
	float length_squared = dot(transformed, transformed);
	if (isnan(length_squared) || isinf(length_squared) || length_squared <= epsilon * epsilon) return vec3(0.0, 1.0, 0.0);
	return normalize(transformed);
}

vec3 apply_breaker_deformation(vec3 long_displacement, vec4 field, vec4 warp, vec2 coast_uv, float confidence) {
	if (params.breaker_5.z <= 0.5) return long_displacement;
	vec4 phase_info = textureLod(breaker_phase, coast_uv, 0.0);
	vec4 metrics = textureLod(breaker_metrics, coast_uv, 0.0);
	vec2 phase_direction = breaker_safe_direction(phase_info.yz);
	vec2 propagation_direction = -phase_direction;
	vec3 breaker_long_normal = ocean_space_normal_to_world_scaled(textureLod(breaker_normal_long, world_uv(warp.xy, params.domains.x), 0.0).xyz);
	float shoreline_gate = smoothstep(params.breaker_0.y, max(params.breaker_0.z, params.breaker_0.y + 0.001), metrics.r);
	float deep_gate = 1.0 - smoothstep(params.breaker_0.w, max(params.breaker_1.x, params.breaker_0.w + 0.001), metrics.r);
	float shoaling_gate = smoothstep(params.breaker_1.y, max(params.breaker_1.z, params.breaker_1.y + 0.001), field.g);
	float compression_gate = 1.0 - smoothstep(params.breaker_2.x, max(params.breaker_1.w, params.breaker_2.x + 0.001), warp.z);
	float environment_gate = confidence * clamp(phase_info.a, 0.0, 1.0) * shoreline_gate * deep_gate * max(shoaling_gate, compression_gate);
	float breaker_activation = smoothstep(0.0, 1.0, clamp(environment_gate, 0.0, 1.0));
	float breaker_amplitude = clamp(params.breaker_0.x, 0.0, 2.0);
	float breaker_environment_strength = breaker_activation;
	float positive_crest_height = max(long_displacement.y, 0.0);
	float crest_gate = smoothstep(params.breaker_2.y, max(params.breaker_2.z, params.breaker_2.y + 0.001), positive_crest_height);
	float crest_core = pow(max(crest_gate, 0.0), max(params.breaker_4.x, 0.25));
	float pre_lip_activation = breaker_environment_strength * clamp(params.breaker_4.y, 0.0, 1.0);
	float wavelength_m = max(metrics.g, 0.001);
	float continuity_height_span_m = max(params.breaker_2.z, wavelength_m * 0.05);
	float upper_wave_support = smoothstep(-0.50 * continuity_height_span_m, 0.50 * continuity_height_span_m, long_displacement.y);
	vec2 height_gradient = -breaker_long_normal.xz / max(breaker_long_normal.y, 0.08);
	float travel_slope = dot(height_gradient, propagation_direction);
	float front_downslope = -travel_slope;
	float front_face_gate = smoothstep(params.breaker_2.w, max(params.breaker_3.x, params.breaker_2.w + 0.001), front_downslope);
	float front_face_support = front_face_gate * upper_wave_support;
	float directional_transition = max(params.breaker_2.w, 0.001);
	float forward_crest_side = smoothstep(-directional_transition, 0.0, front_downslope);
	float directional_crest_core = crest_core * forward_crest_side;
	const float pre_lip_exponent = 2.5;
	float directional_pre_lip_core = pow(clamp(directional_crest_core, 0.0, 1.0), pre_lip_exponent);
	float lip_crest_anchor = smoothstep(0.88, 1.00, clamp(directional_pre_lip_core, 0.0, 1.0));
	float lip_front_support = clamp(max(front_face_gate, lip_crest_anchor), 0.0, 1.0);
	float crest_forward = wavelength_m * max(params.breaker_3.y, 0.0) * directional_crest_core * breaker_environment_strength * breaker_amplitude;
	float pre_lip_forward = wavelength_m * max(params.breaker_4.z, 0.0) * directional_pre_lip_core * pre_lip_activation * breaker_amplitude;
	float front_compression_support = front_face_support * (1.0 - directional_crest_core);
	float front_compression = wavelength_m * max(params.breaker_3.z, 0.0) * front_compression_support * breaker_environment_strength * breaker_amplitude;
	float delta_s_raw = crest_forward + pre_lip_forward - front_compression;
	float horizontal_limit = wavelength_m * max(params.breaker_5.x, 0.0);
	float positive_raw = max(delta_s_raw, 0.0);
	float onset_width = max(wavelength_m * 0.03, horizontal_limit * 0.08);
	float onset_gate = smoothstep(0.0, max(onset_width, 0.001), positive_raw);
	float smooth_positive = positive_raw * onset_gate;
	float delta_s = 0.0;
	if (horizontal_limit > 0.00001) {
		float cap_start = horizontal_limit * 0.85;
		float cap_gate = smoothstep(cap_start, horizontal_limit, smooth_positive);
		delta_s = mix(smooth_positive, horizontal_limit, cap_gate);
	}
	long_displacement.xz += propagation_direction * delta_s;
	float base_lift_raw = positive_crest_height * max(params.breaker_3.w, 0.0) * directional_crest_core * breaker_environment_strength * breaker_amplitude;
	float pre_lip_lift_raw = positive_crest_height * max(params.breaker_4.w, 0.0) * directional_pre_lip_core * pre_lip_activation * breaker_amplitude;
	float total_lift_raw = base_lift_raw + pre_lip_lift_raw;
	float lift = min(total_lift_raw, positive_crest_height * max(params.breaker_5.y, 0.0));
	long_displacement.y += lift;
	return long_displacement;
}

vec3 authored_long_at(vec2 q) {
	vec3 long_displacement = textureLod(displacement_long, world_uv(q, params.domains.x), 0.0).xyz;
	if (params.coastal_control.x <= 0.5) {
		return long_displacement;
	}
	vec2 coast_uv = coastal_uv_from_world(q, params.coastal_origin_extent.xy, params.coastal_origin_extent.zw);
	if (any(lessThan(coast_uv, vec2(0.0))) || any(greaterThan(coast_uv, vec2(1.0)))) {
		return long_displacement;
	}
	vec4 field = textureLod(coastal_field, coast_uv, 0.0);
	vec2 warp_uv = clamp(coastal_uv_from_world(q, params.coastal_warp_origin_extent.xy, params.coastal_warp_origin_extent.zw), vec2(0.0), vec2(1.0));
	vec4 warp = textureLod(coastal_warp, warp_uv, 0.0);
	float confidence = field.a * coastal_confidence_value(warp, params.coastal_control.y);
	vec3 warped_long = textureLod(displacement_long, world_uv(warp.xy, params.domains.x), 0.0).xyz;
	long_displacement = mix(long_displacement, warped_long, confidence);
	long_displacement.y *= mix(1.0, field.g, confidence);
	long_displacement = apply_breaker_deformation(long_displacement, field, warp, coast_uv, confidence);
	return long_displacement;
}

void main() {
	vec3 scaled_vertex = vertex_position;
	scaled_vertex.xz *= params.ocean_space.x;
	scaled_vertex.y *= params.ocean_space.y;
	vec3 world = (draw_params.model * vec4(scaled_vertex, 1.0)).xyz;
	float distance_m = distance(world.xz, params.camera_sea.xz);
	vec3 authored_displacement = authored_long_at(world.xz)
		* fade_weight(distance_m, params.long_fade.xy);
	authored_displacement += texture(displacement_mid, world_uv(world.xz, params.domains.y)).xyz
		* fade_weight(distance_m, params.mid_fade.xy);
	authored_displacement += texture(displacement_short, world_uv(world.xz, params.domains.z)).xyz
		* fade_weight(distance_m, params.short_fade.xy);
	vec3 displacement = ocean_space_displacement(authored_displacement);
	gl_Position = params.view_projection * vec4(world + displacement, 1.0);
}

#[fragment]
#version 450

layout(location = 0) out vec2 waterline_mask;
layout(location = 1) out float ocean_depth;

void main() {
	// R is the actual raster face side. G explicitly distinguishes missing
	// coverage from a valid back-facing (underwater) surface.
	waterline_mask = vec2(gl_FrontFacing ? 1.0 : 0.0, 1.0);
	ocean_depth = gl_FragCoord.z;
}
