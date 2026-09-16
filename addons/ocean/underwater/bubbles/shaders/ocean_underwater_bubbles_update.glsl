#[compute]
#version 450

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0) uniform sampler3D density_previous;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image3D density_next;
layout(set = 0, binding = 2) uniform sampler2D displacement_long;
layout(set = 0, binding = 3) uniform sampler2D displacement_mid;
layout(set = 0, binding = 4) uniform sampler2D displacement_short;
layout(set = 0, binding = 6) uniform sampler2D breaking_activity_long;

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
	vec4 reserved_source_1;
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

vec4 cascade_sample(sampler2D source_texture, vec2 q, float domain_m, vec2 fade_range) {
	vec4 value = textureLod(source_texture, q / max(domain_m, 0.001) + vec2(0.5), 0.0);
	if (any(isnan(value)) || any(isinf(value))) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	float fade = fade_weight(distance(q, params.camera_sea.xz), fade_range);
	value.xyz *= fade;
	value.w = mix(1.0, value.w, fade);
	return value;
}

vec3 displacement_at(vec2 q) {
	return (cascade_sample(displacement_long, q, params.domains.x, params.long_fade.xy).xyz
		+ cascade_sample(displacement_mid, q, params.domains.y, params.mid_fade.xy).xyz
		+ cascade_sample(displacement_short, q, params.domains.z, params.short_fade.xy).xyz) * params.domains.w;
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
	vec4 sample_long = cascade_sample(displacement_long, q, params.domains.x, params.long_fade.xy);
	vec4 sample_mid = cascade_sample(displacement_mid, q, params.domains.y, params.mid_fade.xy);
	vec4 sample_short = cascade_sample(displacement_short, q, params.domains.z, params.short_fade.xy);
	surface_y = params.camera_sea.w + (sample_long.y + sample_mid.y + sample_short.y) * params.domains.w;
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
