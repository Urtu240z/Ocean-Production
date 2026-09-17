#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0) uniform sampler3D density_previous;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image3D density_next;
layout(set = 0, binding = 2) uniform sampler2D displacement_long;
layout(set = 0, binding = 3) uniform sampler2D displacement_mid;
layout(set = 0, binding = 4) uniform sampler2D displacement_short;
layout(set = 0, binding = 6) uniform sampler2D breaking_activity_long;
layout(set = 0, binding = 7) uniform sampler2D coastal_field;
layout(set = 0, binding = 8) uniform sampler2D coastal_warp;
layout(set = 0, binding = 9) uniform sampler2D breaker_phase;
layout(set = 0, binding = 10) uniform sampler2D breaker_metrics;
layout(set = 0, binding = 11) uniform sampler2D breaker_normal_long;

layout(set = 0, binding = 5, std140) uniform BubbleUpdateParams {
	vec4 current_origin_dt;
	vec4 previous_origin_history;
	vec4 extent_time;
	vec4 simulation; // injection strength/depth, downward entrainment, buoyancy
	vec4 flow; // horizontal X/Z drift, curl strength, curl scale
	vec4 dynamics; // curl time scale, diffusion, decay multiplier, max density
	vec4 camera_sea;
	vec4 domains;
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
	vec4 breaking_gate; // Crest G injection start, full, reserved, reserved
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
} params;

const float EPSILON = 0.00001;
const float DIFFUSION_STABILITY_LIMIT = 0.45;

bool finite_value(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

float fade_weight(float distance_m, vec2 range_m) {
	return 1.0 - smoothstep(range_m.x, max(range_m.y, range_m.x + 0.001), distance_m);
}

vec4 cascade_sample(sampler2D source_texture, vec2 q, float domain_m) {
	vec4 value = textureLod(source_texture, q / max(domain_m, 0.001) + vec2(0.5), 0.0);
	if (any(isnan(value)) || any(isinf(value))) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	return value;
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
	vec3 breaker_long_normal = ocean_space_normal_to_world_scaled(textureLod(breaker_normal_long, warp.xy / max(params.domains.x, 0.001) + vec2(0.5), 0.0).xyz);
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

vec3 displacement_at(vec2 q) {
	float distance_m = distance(q, params.camera_sea.xz);
	vec3 authored_long = cascade_sample(displacement_long, q, params.domains.x).xyz;
	if (params.coastal_control.x > 0.5) {
		vec2 coast_uv = (q - params.coastal_origin_extent.xy) / max(params.coastal_origin_extent.zw, vec2(0.001));
		if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
			vec4 field = textureLod(coastal_field, coast_uv, 0.0);
			vec2 warp_uv = clamp((q - params.coastal_warp_origin_extent.xy) / max(params.coastal_warp_origin_extent.zw, vec2(0.001)), vec2(0.0), vec2(1.0));
			vec4 warp = textureLod(coastal_warp, warp_uv, 0.0);
			float confidence = field.a * (smoothstep(0.0, params.coastal_control.y, warp.z) * warp.w);
			vec3 warped_long = textureLod(displacement_long, warp.xy / max(params.domains.x, 0.001) + vec2(0.5), 0.0).xyz;
			authored_long = mix(authored_long, warped_long, confidence);
			authored_long.y *= mix(1.0, field.g, confidence);
			authored_long = apply_breaker_deformation(authored_long, field, warp, coast_uv, confidence);
		}
	}
	vec3 authored_displacement = authored_long * fade_weight(distance_m, params.long_fade.xy)
		+ cascade_sample(displacement_mid, q, params.domains.y).xyz * fade_weight(distance_m, params.mid_fade.xy)
		+ cascade_sample(displacement_short, q, params.domains.z).xyz * fade_weight(distance_m, params.short_fade.xy);
	float horizontal_scale = params.ocean_space.x;
	float vertical_scale = params.ocean_space.y;
	return vec3(
		authored_displacement.x * horizontal_scale,
		authored_displacement.y * vertical_scale,
		authored_displacement.z * horizontal_scale
	);
}

float breaking_activity_at(vec2 q) {
	float value = textureLod(breaking_activity_long, q / max(params.domains.x, 0.001) + vec2(0.5), 0.0).g;
	if (isnan(value) || isinf(value)) return 0.0;
	return clamp(value, 0.0, 1.0);
}

float shape_breaking_for_injection(float raw_activity, float start_threshold, float full_threshold) {
	if (isnan(raw_activity) || isinf(raw_activity) || isnan(start_threshold) || isinf(start_threshold) || isnan(full_threshold) || isinf(full_threshold)) {
		return 0.0;
	}
	float start_value = clamp(start_threshold, 0.0, 1.0);
	float full_value = clamp(full_threshold, 0.0, 1.0);
	float raw_value = clamp(raw_activity, 0.0, 1.0);
	if (start_value >= 1.0) {
		return raw_value >= 1.0 ? 1.0 : 0.0;
	}
	full_value = min(max(full_value, start_value + 0.001), 1.001);
	return smoothstep(start_value, full_value, raw_value);
}

void surface_and_breaking_at(vec2 target_xz, out float surface_y, out float breaking_source) {
	vec2 q = target_xz;
	for (int iteration = 0; iteration < 3; ++iteration) {
		vec3 displacement = displacement_at(q);
		q = target_xz - displacement.xz;
		if (!finite_vec3(displacement) || any(isnan(q)) || any(isinf(q))) {
			surface_y = params.camera_sea.w;
			breaking_source = 0.0;
			return;
		}
	}
	vec3 final_displacement = displacement_at(q);
	surface_y = params.camera_sea.w + final_displacement.y;
	float raw_breaking = breaking_activity_at(q);
	breaking_source = shape_breaking_for_injection(raw_breaking, params.breaking_gate.x, params.breaking_gate.y);
	if (!finite_value(surface_y) || !finite_value(breaking_source)) {
		surface_y = params.camera_sea.w;
		breaking_source = 0.0;
	}
}

bool inside_unit(vec3 uvw) {
	return all(greaterThanEqual(uvw, vec3(0.0))) && all(lessThanEqual(uvw, vec3(1.0)));
}

float sample_history(vec3 world_position) {
	if (params.previous_origin_history.w < 0.5) {
		return 0.0;
	}
	vec3 uvw = (world_position - params.previous_origin_history.xyz) / max(params.extent_time.xyz, vec3(EPSILON));
	if (!inside_unit(uvw)) {
		return 0.0;
	}
	float value = textureLod(density_previous, uvw, 0.0).r;
	return finite_value(value) ? max(value, 0.0) : 0.0;
}

// Analytic curl of a smooth, time-varying vector potential in world space.
// Two incommensurate octaves prevent rigid columns without temporal flicker.
vec3 curl_octave(vec3 p, float time_phase) {
	return vec3(
		-sin(p.y + time_phase * 1.13) - cos(p.z + time_phase * 0.83),
		-sin(p.z - time_phase * 0.70) - cos(p.x - time_phase * 0.61),
		-sin(p.x + time_phase * 0.37) - cos(p.y + time_phase)
	);
}

vec3 curl_velocity(vec3 world_position) {
	float scale_m = max(params.flow.w, 0.25);
	float phase = params.extent_time.w * max(params.dynamics.x, 0.0);
	vec3 p = world_position / scale_m;
	vec3 first = curl_octave(p, phase);
	vec3 second_p = vec3(p.z + 13.7, p.x - 7.1, p.y + 3.9) * 1.91;
	vec3 second = curl_octave(second_p, phase * 0.73 + 5.2);
	return (first + second * 0.35) * (0.36 * max(params.flow.z, 0.0));
}

void main() {
	ivec3 coord = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(density_next);
	if (any(greaterThanEqual(coord, size))) {
		return;
	}

	vec3 voxel_size = params.extent_time.xyz / vec3(size);
	vec3 world_position = params.current_origin_dt.xyz + (vec3(coord) + vec3(0.5)) * voxel_size;
	float surface_y = params.camera_sea.w;
	float breaking_source = 0.0;
	surface_and_breaking_at(world_position.xz, surface_y, breaking_source);
	float depth_below_surface = surface_y - world_position.y;
	float interface_fade_m = max(voxel_size.y * 1.5, 0.15);
	float underwater_mask = smoothstep(0.0, interface_fade_m, depth_below_surface);
	if (depth_below_surface <= 0.0) {
		imageStore(density_next, coord, vec4(0.0));
		return;
	}

	float injection_depth = max(params.simulation.y, 0.1);
	float depth_falloff = 1.0 - smoothstep(0.0, injection_depth, depth_below_surface);
	float vertical_profile = underwater_mask * depth_falloff;
	vec3 velocity = vec3(params.flow.x, 0.0, params.flow.y) + curl_velocity(world_position);
	velocity.y += max(params.simulation.w, 0.0);
	velocity.y -= breaking_source * max(params.simulation.z, 0.0) * depth_falloff;

	float dt = max(params.current_origin_dt.w, 0.0);
	vec3 previous_world_position = world_position - velocity * dt;
	float advected = sample_history(previous_world_position);
	float requested_diffusion = max(params.dynamics.y, 0.0);
	float effective_diffusion = 0.0;
	vec3 safe_voxel = voxel_size;
	if (finite_value(dt) && dt > EPSILON && finite_vec3(safe_voxel) && finite_value(requested_diffusion)) {
		safe_voxel = max(safe_voxel, vec3(EPSILON));
		vec3 inverse_h2 = 1.0 / (safe_voxel * safe_voxel);
		float inverse_h2_sum = inverse_h2.x + inverse_h2.y + inverse_h2.z;
		float diffusion_denominator = dt * inverse_h2_sum;
		if (finite_vec3(inverse_h2) && finite_value(inverse_h2_sum) && inverse_h2_sum > 0.0 && finite_value(diffusion_denominator) && diffusion_denominator > 0.0) {
			float max_stable_diffusion = DIFFUSION_STABILITY_LIMIT / max(diffusion_denominator, EPSILON);
			if (finite_value(max_stable_diffusion)) {
				effective_diffusion = min(requested_diffusion, max_stable_diffusion);
			}
		}
	}
	if (effective_diffusion > 0.0 && params.previous_origin_history.w > 0.5) {
		float laplacian =
			(sample_history(previous_world_position + vec3(voxel_size.x, 0.0, 0.0))
			+ sample_history(previous_world_position - vec3(voxel_size.x, 0.0, 0.0)) - 2.0 * advected) / max(voxel_size.x * voxel_size.x, EPSILON)
			+ (sample_history(previous_world_position + vec3(0.0, voxel_size.y, 0.0))
			+ sample_history(previous_world_position - vec3(0.0, voxel_size.y, 0.0)) - 2.0 * advected) / max(voxel_size.y * voxel_size.y, EPSILON)
			+ (sample_history(previous_world_position + vec3(0.0, 0.0, voxel_size.z))
			+ sample_history(previous_world_position - vec3(0.0, 0.0, voxel_size.z)) - 2.0 * advected) / max(voxel_size.z * voxel_size.z, EPSILON);
		advected = max(advected + effective_diffusion * dt * laplacian, 0.0);
	}

	float injection = breaking_source * max(params.simulation.x, 0.0) * vertical_profile * dt;
	float density = advected * clamp(params.dynamics.z, 0.0, 1.0) + injection;
	density = clamp(density * underwater_mask, 0.0, max(params.dynamics.w, 0.01));
	if (!finite_value(density)) {
		density = 0.0;
	}
	imageStore(density_next, coord, vec4(density, 0.0, 0.0, 1.0));
}
