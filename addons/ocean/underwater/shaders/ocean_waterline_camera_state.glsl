#[compute]
#version 450

// One invocation samples the same open-ocean displacement fields used by the
// visible clipmap. It never crosses the CPU/GPU boundary.
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D displacement_long;
layout(set = 0, binding = 1) uniform sampler2D displacement_mid;
layout(set = 0, binding = 2) uniform sampler2D displacement_short;
layout(set = 0, binding = 5) uniform sampler2D coastal_field;
layout(set = 0, binding = 6) uniform sampler2D coastal_warp;
layout(set = 0, binding = 7) uniform sampler2D breaker_phase;
layout(set = 0, binding = 8) uniform sampler2D breaker_metrics;
layout(set = 0, binding = 9) uniform sampler2D breaker_normal_long;
layout(set = 0, binding = 10) uniform sampler2D breaker_lifecycle;
layout(set = 0, binding = 11) uniform sampler2D breaking_activity_long;
layout(set = 0, binding = 12) uniform sampler2D breaker_multiphase_vdm;
layout(set = 0, binding = 3, std140) uniform CameraStateParams {
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
	vec4 breaker_6; // lip strength, forward fraction, drop scale, lift scale
	vec4 breaker_7; // pre-fold start/full J, unsafe/recover J
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
} params;
layout(set = 0, binding = 4, std430) buffer CameraWaterState {
	vec4 value; // signed height, surface height, valid, reserved
	vec4 state1; // local tangent-plane normal, w reserved
} camera_state;

const float SURFACE_SLOPE_EPSILON = 0.05;

bool finite_value(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return finite_value(value.x) && finite_value(value.y) && finite_value(value.z);
}

float fade_weight(float distance_m, vec2 range_m) {
	float start_m = range_m.x;
	float end_m = max(range_m.y, start_m + 0.001);
	return 1.0 - smoothstep(start_m, end_m, distance_m);
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

vec3 apply_breaker_vdm_deformation(vec3 long_displacement, vec4 field, vec4 warp, vec2 coast_uv, float confidence, vec2 long_uv) {
	if (params.breaker_5.z <= 0.5) return long_displacement;
	vec4 phase_info = textureLod(breaker_phase, coast_uv, 0.0);
	vec2 propagation_direction = -breaker_safe_direction(phase_info.yz);
	vec2 crest_tangent = vec2(-propagation_direction.y, propagation_direction.x);
	vec3 breaker_long_normal = ocean_space_normal_to_world_scaled(textureLod(breaker_normal_long, long_uv, 0.0).xyz);
	vec4 metrics = textureLod(breaker_metrics, coast_uv, 0.0);
	float shoreline_gate = smoothstep(params.breaker_0.y, max(params.breaker_0.z, params.breaker_0.y + 0.001), metrics.r);
	float deep_gate = 1.0 - smoothstep(params.breaker_0.w, max(params.breaker_1.x, params.breaker_0.w + 0.001), metrics.r);
	float shoaling_gate = smoothstep(params.breaker_1.y, max(params.breaker_1.z, params.breaker_1.y + 0.001), field.g);
	float compression_gate = 1.0 - smoothstep(params.breaker_2.x, max(params.breaker_1.w, params.breaker_2.x + 0.001), warp.z);
	float breaker_activation = confidence * clamp(phase_info.a, 0.0, 1.0) * shoreline_gate * deep_gate * max(shoaling_gate, compression_gate);
	vec4 breaker_state = textureLod(breaker_lifecycle, long_uv, 0.0);
	float active_break = smoothstep(0.05, 0.35, breaker_state.r);
	float breaking_g = clamp(textureLod(breaking_activity_long, long_uv, 0.0).g, 0.0, 1.0);
	float fft_j = textureLod(displacement_long, long_uv, 0.0).a;
	if (isnan(fft_j) || isinf(fft_j)) fft_j = 1.0;
	float fold_energy = 1.0 - smoothstep(params.breaker_7.y, max(params.breaker_7.x, params.breaker_7.y + 0.001), fft_j);
	float unsafe_fft = 1.0 - smoothstep(params.breaker_7.z, max(params.breaker_7.w, params.breaker_7.z + 0.001), fft_j);
	float lip_energy = breaker_activation * active_break * breaking_g * fold_energy;
	long_displacement.xz *= 1.0 - 0.35 * lip_energy * unsafe_fft;
	vec2 height_gradient = -breaker_long_normal.xz / max(breaker_long_normal.y, 0.08);
	float front_downslope = -dot(height_gradient, propagation_direction);
	float profile_k0 = 6.28318530718 / max(metrics.g, 0.001);
	float wrapped_phase = mod(phase_info.r + 3.14159265359, 6.28318530718) - 3.14159265359;
	float s_profile = -wrapped_phase / max(profile_k0, 0.001);
	float profile_u = clamp(0.5 + s_profile / 12.0, 0.0, 1.0);
	float root_tip_weight = smoothstep(0.08, 0.18, profile_u);
	float lateral_u = fract(0.5 + dot(warp.xy, crest_tangent) / 32.0);
	float breaker_phase_b = clamp(breaker_state.b, 0.0, 1.0);
	float phase_pos = breaker_phase_b * 7.0;
	float phase0 = floor(phase_pos);
	float phase_mix = smoothstep(0.0, 1.0, fract(phase_pos));
	vec4 vdm0 = textureLod(breaker_multiphase_vdm, vec2(profile_u, (phase0 + lateral_u) / 8.0), 0.0);
	vec4 vdm1 = textureLod(breaker_multiphase_vdm, vec2(profile_u, (min(phase0 + 1.0, 7.0) + lateral_u) / 8.0), 0.0);
	vec4 vdm = mix(vdm0, vdm1, phase_mix);
	float overturn_envelope = smoothstep(0.40, 0.55, breaker_phase_b) * (1.0 - smoothstep(0.72, 0.88, breaker_phase_b));
	float effective_vdm_scale = mix(0.35, 0.52, overturn_envelope);
	float vdm_authority = clamp(vdm.a * root_tip_weight * lip_energy * clamp(params.breaker_0.x, 0.0, 2.0), 0.0, 1.0);
	float rear_negative_guard = smoothstep(0.24, 0.42, profile_u);
	float signed_vdm_r = vdm.r >= 0.0 ? vdm.r : vdm.r * rear_negative_guard;
	long_displacement.xz += propagation_direction * signed_vdm_r * effective_vdm_scale * vdm_authority + crest_tangent * vdm.g * effective_vdm_scale * vdm_authority;
	long_displacement.y += vdm.b * effective_vdm_scale * vdm_authority;
	return long_displacement;
}

vec3 apply_breaker_deformation(vec3 long_displacement, vec4 field, vec4 warp, vec2 coast_uv, float confidence) {
	if (params.breaker_5.z <= 0.5) return long_displacement;
	return apply_breaker_vdm_deformation(long_displacement, field, warp, coast_uv, confidence, warp.xy / max(params.domains.x, 0.001) + vec2(0.5));
	vec4 phase_info = textureLod(breaker_phase, coast_uv, 0.0);
	vec4 metrics = textureLod(breaker_metrics, coast_uv, 0.0);
	vec2 phase_direction = breaker_safe_direction(phase_info.yz);
	vec2 propagation_direction = -phase_direction;
	vec3 breaker_long_normal = ocean_space_normal_to_world_scaled(textureLod(breaker_normal_long, warp.xy / max(params.domains.x, 0.001) + vec2(0.5), 0.0).xyz);
	float shoreline_gate = smoothstep(params.breaker_0.y, max(params.breaker_0.z, params.breaker_0.y + 0.001), metrics.r);
	float deep_gate = 1.0 - smoothstep(params.breaker_0.w, max(params.breaker_1.x, params.breaker_0.w + 0.001), metrics.r);
	float shoaling_gate = smoothstep(params.breaker_1.y, max(params.breaker_1.z, params.breaker_1.y + 0.001), field.g);
	float compression_gate = 1.0 - smoothstep(params.breaker_2.x, max(params.breaker_1.w, params.breaker_2.x + 0.001), warp.z);
	float environment_gate = confidence * clamp(phase_info.a, 0.0, 1.0) * shoreline_gate * deep_gate * max(shoaling_gate, compression_gate);
	float breaker_activation = smoothstep(0.0, 1.0, clamp(environment_gate, 0.0, 1.0));
	vec4 breaker_state = textureLod(breaker_lifecycle, warp.xy / max(params.domains.x, 0.001) + vec2(0.5), 0.0);
	float active_break = smoothstep(0.05, 0.35, breaker_state.r);
	float breaking_g = clamp(textureLod(breaking_activity_long, warp.xy / max(params.domains.x, 0.001) + vec2(0.5), 0.0).g, 0.0, 1.0);
	float fft_j = textureLod(displacement_long, warp.xy / max(params.domains.x, 0.001) + vec2(0.5), 0.0).a;
	if (isnan(fft_j) || isinf(fft_j)) fft_j = 1.0;
	float pre_fold = 1.0 - smoothstep(params.breaker_7.y, max(params.breaker_7.x, params.breaker_7.y + 0.001), fft_j);
	float safe_fold = smoothstep(params.breaker_7.z, max(params.breaker_7.w, params.breaker_7.z + 0.001), fft_j);
	float chop_authority = breaker_activation * active_break * breaking_g * pre_fold;
	float chop_damping = max(0.70 * chop_authority, 0.85 * breaker_activation * active_break * (1.0 - safe_fold));
	long_displacement.xz *= 1.0 - clamp(chop_damping, 0.0, 0.85);
	float breaker_amplitude = clamp(params.breaker_0.x, 0.0, 2.0);
	float breaker_environment_strength = breaker_activation * active_break * breaking_g * pre_fold * safe_fold;
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
	float lip_core = directional_pre_lip_core * clamp(params.breaker_6.x, 0.0, 1.0);
	float lip_forward = wavelength_m * max(params.breaker_6.y, 0.0) * lip_core * breaker_environment_strength * breaker_amplitude;
	float delta_s_raw = crest_forward + pre_lip_forward + lip_forward - front_compression;
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
	float lip_lift_raw = positive_crest_height * max(params.breaker_6.w, 0.0) * lip_core * breaker_environment_strength * breaker_amplitude;
	float lip_tip_drop = positive_crest_height * clamp(params.breaker_6.z, 0.0, 1.0) * lip_front_support * breaker_environment_strength * breaker_amplitude;
	float collapse = breaker_activation * breaker_state.g * (1.0 - active_break);
	float total_lift_raw = base_lift_raw + pre_lip_lift_raw + lip_lift_raw - lip_tip_drop - positive_crest_height * clamp(params.breaker_6.z, 0.0, 1.0) * collapse;
	float lift = min(total_lift_raw, positive_crest_height * max(params.breaker_5.y, 0.0));
	long_displacement.y += lift;
	return long_displacement;
}

vec3 authored_long_at(vec2 q) {
	vec3 long_displacement = textureLod(displacement_long, q / max(params.domains.x, 0.001) + vec2(0.5), 0.0).xyz;
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
	vec3 warped_long = textureLod(displacement_long, warp.xy / max(params.domains.x, 0.001) + vec2(0.5), 0.0).xyz;
	long_displacement = mix(long_displacement, warped_long, confidence);
	long_displacement.y *= mix(1.0, field.g, confidence);
	long_displacement = apply_breaker_deformation(long_displacement, field, warp, coast_uv, confidence);
	return long_displacement;
}

vec3 displacement_at(vec2 q) {
	float distance_m = distance(q, params.camera_sea.xz);
	vec3 authored_displacement = authored_long_at(q) * fade_weight(distance_m, params.long_fade.xy);
	authored_displacement += textureLod(displacement_mid, q / max(params.domains.y, 0.001) + vec2(0.5), 0.0).xyz * fade_weight(distance_m, params.mid_fade.xy);
	authored_displacement += textureLod(displacement_short, q / max(params.domains.z, 0.001) + vec2(0.5), 0.0).xyz * fade_weight(distance_m, params.short_fade.xy);
	return ocean_space_displacement(authored_displacement);
}

float surface_height_at(vec2 target_xz) {
	vec2 q = target_xz;
	for (int iteration = 0; iteration < 4; ++iteration) {
		vec3 displacement = displacement_at(q);
		if (!finite_vec3(displacement)) return 0.0 / 0.0;
		q = target_xz - displacement.xz;
		if (!finite_value(q.x) || !finite_value(q.y)) return 0.0 / 0.0;
	}
	vec3 displacement = displacement_at(q);
	if (!finite_vec3(displacement)) return 0.0 / 0.0;
	return params.camera_sea.w + displacement.y;
}

void main() {
	vec2 q = params.camera_sea.xz;
	if (!finite_value(params.camera_sea.y) || !finite_value(params.camera_sea.w) || !finite_value(q.x) || !finite_value(q.y)) {
		camera_state.value = vec4(0.0); camera_state.state1 = vec4(0.0);
		return;
	}
	// Fixed-point inverse horizontal chop: P(q).xz == camera.xz.
	for (int iteration = 0; iteration < 4; ++iteration) {
		vec3 displacement = displacement_at(q);
		if (!finite_vec3(displacement)) {
			camera_state.value = vec4(0.0); camera_state.state1 = vec4(0.0);
			return;
		}
		q = params.camera_sea.xz - displacement.xz;
		if (!finite_value(q.x) || !finite_value(q.y)) {
			camera_state.value = vec4(0.0); camera_state.state1 = vec4(0.0);
			return;
		}
	}
	vec3 final_displacement = displacement_at(q);
	float surface_y = params.camera_sea.w + final_displacement.y;
	float signed_height = params.camera_sea.y - surface_y;
	float h_x_plus = surface_height_at(params.camera_sea.xz + vec2(SURFACE_SLOPE_EPSILON, 0.0));
	float h_x_minus = surface_height_at(params.camera_sea.xz - vec2(SURFACE_SLOPE_EPSILON, 0.0));
	float h_z_plus = surface_height_at(params.camera_sea.xz + vec2(0.0, SURFACE_SLOPE_EPSILON));
	float h_z_minus = surface_height_at(params.camera_sea.xz - vec2(0.0, SURFACE_SLOPE_EPSILON));
	float dHdx = (h_x_plus - h_x_minus) / (2.0 * SURFACE_SLOPE_EPSILON);
	float dHdz = (h_z_plus - h_z_minus) / (2.0 * SURFACE_SLOPE_EPSILON);
	vec3 normal = normalize(vec3(-dHdx, 1.0, -dHdz));
	if (!finite_vec3(final_displacement) || !finite_value(surface_y) || !finite_value(signed_height)
			|| !finite_value(h_x_plus) || !finite_value(h_x_minus) || !finite_value(h_z_plus) || !finite_value(h_z_minus)
			|| !finite_value(dHdx) || !finite_value(dHdz) || !finite_vec3(normal)) {
		camera_state.value = vec4(0.0); camera_state.state1 = vec4(0.0);
		return;
	}
	camera_state.value = vec4(signed_height, surface_y, 1.0, 0.0);
	camera_state.state1 = vec4(normal, 0.0);
}
