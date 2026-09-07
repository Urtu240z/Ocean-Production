/* P6_BUBBLE_BINDINGS_BEGIN */
layout(set = 0, binding = 6) uniform sampler3D bubble_density;
layout(set = 0, binding = 8) uniform sampler2D bubble_displacement_long;
layout(set = 0, binding = 9) uniform sampler2D bubble_displacement_mid;
layout(set = 0, binding = 10) uniform sampler2D bubble_displacement_short;
/* P6_BUBBLE_NOISE_BINDINGS */

layout(set = 0, binding = 7, std140) uniform BubbleVolumeParams {
	vec4 origin_enabled;
	vec4 extent_debug;
	vec4 render; // scatter, extinction, density gamma, march steps
	vec4 tint;
	vec4 camera_sea;
	vec4 simulation; // injection strength/depth, reserved
	vec4 domains;
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
	vec4 source_thresholds;
	vec4 source_weights;
	vec4 detail; // macro scale/strength, micro scale/strength
	vec4 noise; // simulation time, wave time, curl warp strength, wave warp strength
	vec4 flow; // dominant direction X/Z, curl strength, curl scale
	vec4 advection; // accumulated world-space flow offset, curl time scale
	vec4 shadow; // strength, steps, reserved
	vec4 shadow_tint;
} bubbles;
/* P6_BUBBLE_BINDINGS_END */

/* P6_BUBBLE_HELPERS_BEGIN */
bool intersect_aabb(vec3 ray_origin, vec3 ray_direction, vec3 bounds_min, vec3 bounds_max, out float near_t, out float far_t) {
	vec3 safe_direction = vec3(
		abs(ray_direction.x) > EPSILON ? ray_direction.x : (ray_direction.x < 0.0 ? -EPSILON : EPSILON),
		abs(ray_direction.y) > EPSILON ? ray_direction.y : (ray_direction.y < 0.0 ? -EPSILON : EPSILON),
		abs(ray_direction.z) > EPSILON ? ray_direction.z : (ray_direction.z < 0.0 ? -EPSILON : EPSILON)
	);
	vec3 inverse_direction = 1.0 / safe_direction;
	vec3 t0 = (bounds_min - ray_origin) * inverse_direction;
	vec3 t1 = (bounds_max - ray_origin) * inverse_direction;
	vec3 lower = min(t0, t1);
	vec3 upper = max(t0, t1);
	near_t = max(lower.x, max(lower.y, lower.z));
	far_t = min(upper.x, min(upper.y, upper.z));
	return far_t >= max(near_t, 0.0) && !isnan(near_t) && !isinf(near_t) && !isnan(far_t) && !isinf(far_t);
}

float bubble_fade_weight(float distance_m, vec2 range_m) {
	return 1.0 - smoothstep(range_m.x, max(range_m.y, range_m.x + 0.001), distance_m);
}

vec4 bubble_cascade_sample(sampler2D source_texture, vec2 q, float domain_m, vec2 fade_range) {
	vec4 value = textureLod(source_texture, q / max(domain_m, 0.001) + vec2(0.5), 0.0);
	if (any(isnan(value)) || any(isinf(value))) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	float fade = bubble_fade_weight(distance(q, bubbles.camera_sea.xz), fade_range);
	value.xyz *= fade;
	value.w = mix(1.0, value.w, fade);
	return value;
}

vec3 bubble_displacement_at(vec2 q) {
	return bubble_cascade_sample(bubble_displacement_long, q, bubbles.domains.x, bubbles.long_fade.xy).xyz
		+ bubble_cascade_sample(bubble_displacement_mid, q, bubbles.domains.y, bubbles.mid_fade.xy).xyz
		+ bubble_cascade_sample(bubble_displacement_short, q, bubbles.domains.z, bubbles.short_fade.xy).xyz;
}

float bubble_injection_at(vec3 world_position) {
	vec2 q = world_position.xz;
	for (int iteration = 0; iteration < 3; ++iteration) {
		vec3 displacement = bubble_displacement_at(q);
		if (!finite_vec3(displacement)) return 0.0;
		q = world_position.xz - displacement.xz;
	}
	vec4 sample_long = bubble_cascade_sample(bubble_displacement_long, q, bubbles.domains.x, bubbles.long_fade.xy);
	vec4 sample_mid = bubble_cascade_sample(bubble_displacement_mid, q, bubbles.domains.y, bubbles.mid_fade.xy);
	vec4 sample_short = bubble_cascade_sample(bubble_displacement_short, q, bubbles.domains.z, bubbles.short_fade.xy);
	float surface_y = bubbles.camera_sea.w + sample_long.y + sample_mid.y + sample_short.y;
	float depth = surface_y - world_position.y;
	if (depth <= 0.0) return 0.0;
	vec3 source = max(vec3(0.0), bubbles.source_thresholds.xyz - vec3(sample_long.w, sample_mid.w, sample_short.w))
		/ max(bubbles.source_thresholds.xyz, vec3(0.001))
		* max(bubbles.source_weights.xyz, vec3(0.0));
	float breaking = clamp(max(source.x, max(source.y, source.z)), 0.0, 1.0);
	float injection_depth = max(bubbles.simulation.y, 0.1);
	float interface_fade = max(bubbles.extent_debug.y / max(bubbles.simulation.z, 1.0) * 1.5, 0.15);
	float vertical_profile = smoothstep(0.0, interface_fade, depth) * (1.0 - smoothstep(0.0, injection_depth, depth));
	return breaking * max(bubbles.simulation.x, 0.0) * vertical_profile;
}

/* P6_BUBBLE_NOISE_HELPERS */

vec3 bubble_warped_position(vec3 world_position, out vec3 secondary_warp) {
	// Translation is integrated per fixed simulation tick, so changing drift or
	// buoyancy at runtime changes velocity without teleporting the noise domain.
	vec3 advected_position = world_position - bubbles.advection.xyz;
	vec3 curl_warp = vec3(0.0);
	if (bubbles.noise.z > EPSILON && bubbles.flow.z > EPSILON) {
		curl_warp = bubble_curl_velocity(advected_position) * bubbles.noise.z;
	}
	vec3 wave_warp = vec3(0.0);
	if (bubbles.noise.w > EPSILON) {
		vec2 wave_direction = bubbles.flow.xy;
		float direction_length = length(wave_direction);
		wave_direction = direction_length > EPSILON ? wave_direction / direction_length : vec2(1.0, 0.0);
		float wavelength_m = max(bubbles.detail.x * 2.5, 4.0);
		float wave_phase = dot(advected_position.xz, wave_direction) * (6.2831853 / wavelength_m) - bubbles.noise.y * 0.85;
		float wave_shape = sin(wave_phase);
		wave_warp = vec3(wave_direction.x, 0.28 * cos(wave_phase * 0.73), wave_direction.y) * (wave_shape * bubbles.noise.w);
	}
	secondary_warp = vec3(curl_warp.z, -curl_warp.x, curl_warp.y) * 0.35 + wave_warp * 0.20;
	return advected_position + curl_warp + wave_warp;
}

float bubble_visual_density(float simulated_density, vec3 world_position, float sample_distance_to_camera) {
	float macro_strength = clamp(bubbles.detail.y, 0.0, 1.0);
	float micro_strength = clamp(bubbles.detail.w, 0.0, 1.0);
	if (macro_strength <= EPSILON && micro_strength <= EPSILON) {
		return max(simulated_density, 0.0);
	}
	vec3 secondary_warp = vec3(0.0);
	vec3 warped_position = bubble_warped_position(world_position, secondary_warp);
	float macro_term = 1.0;
	if (macro_strength > EPSILON) {
		float macro_n = bubble_macro_noise_3d(warped_position / max(bubbles.detail.x, 0.001));
		float macro_shape = 1.45 * smoothstep(0.32, 0.68, macro_n);
		macro_term = mix(1.0, macro_shape, macro_strength);
	}
	float micro_term = 1.0;
	if (micro_strength > EPSILON) {
		float micro_scale_m = max(bubbles.detail.z, 0.02);
		// Compute-shader equivalent of a conservative pixel footprint. Centimetre
		// detail remains available nearby and fades before it can shimmer far away.
		float pixel_footprint_m = max(sample_distance_to_camera * (2.0 / max(params.viewport.y, 1.0)), 0.002);
		float micro_resolve = smoothstep(pixel_footprint_m * 1.5, pixel_footprint_m * 4.0, micro_scale_m);
		vec3 micro_offset = vec3(19.19, 47.77, 73.31);
		float micro_n = bubble_micro_noise_3d((warped_position + secondary_warp) / micro_scale_m + micro_offset);
		float micro_shape = mix(0.40, 1.45, smoothstep(0.35, 0.65, micro_n));
		micro_term = mix(1.0, micro_shape, micro_strength * micro_resolve);
	}
	return max(simulated_density, 0.0) * max(macro_term, 0.0) * max(micro_term, 0.0);
}

float bubble_shadow_visibility(vec3 world_position, vec3 bounds_min, vec3 bounds_max) {
	int shadow_steps = clamp(int(round(bubbles.shadow.y)), 0, 4);
	float shadow_strength = max(bubbles.shadow.x, 0.0);
	if (shadow_steps <= 0 || shadow_strength <= EPSILON) {
		return 1.0;
	}
	// P6.5 currently models available illumination as coming from the surface,
	// so +Y is the coherent light direction until a real sun vector is published.
	float light_target_y = min(bubbles.camera_sea.w, bounds_max.y);
	float light_distance = max(light_target_y - world_position.y, 0.0);
	if (light_distance <= EPSILON) {
		return 1.0;
	}
	float shadow_step_length = light_distance / float(shadow_steps);
	float shadow_density = 0.0;
	for (int shadow_index = 0; shadow_index < 4; ++shadow_index) {
		if (shadow_index >= shadow_steps) break;
		vec3 light_position = world_position + vec3(0.0, (float(shadow_index) + 0.5) * shadow_step_length, 0.0);
		vec3 light_uvw = (light_position - bounds_min) / max(bubbles.extent_debug.xyz, vec3(EPSILON));
		if (all(greaterThanEqual(light_uvw, vec3(0.0))) && all(lessThanEqual(light_uvw, vec3(1.0)))) {
			float light_density = textureLod(bubble_density, light_uvw, 0.0).r;
			shadow_density += max(light_density, 0.0) * shadow_step_length;
		}
	}
	return exp(-shadow_density * shadow_strength);
}

vec3 bubble_incident_light(vec3 world_position) {
	float sample_depth = max(params.volume.w - world_position.y, 0.0);
	float depth_light = exp(-sample_depth * max(params.volume.y, 0.0));
	vec3 spectral_transmittance = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.y, 0.0) * sample_depth);
	// Surface light is near-white at the interface; Beer-Lambert attenuation
	// progressively gives it the same spectral character as the surrounding
	// P6.5 water. No independent bubble light is introduced.
	return vec3(max(params.ambient_light.x, 0.0))
		* depth_light
		* spectral_transmittance;
}

/* P6_BUBBLE_HELPERS_END */

/* P6_BUBBLE_MAIN_BEGIN */
if (bubbles.origin_enabled.w > 0.5 && direction_valid) {
	vec3 bounds_min = bubbles.origin_enabled.xyz;
	vec3 bounds_max = bounds_min + max(bubbles.extent_debug.xyz, vec3(EPSILON));
	float bubble_near = 0.0;
	float bubble_far = 0.0;
	if (intersect_aabb(params.camera.xyz, ray_direction, bounds_min, bounds_max, bubble_near, bubble_far)) {
		float segment_start = max(bubble_near, 0.0);
		float segment_end = min(bubble_far, optical_distance);
		float segment_length = segment_end - segment_start;
		if (segment_length > EPSILON) {
			int march_steps = clamp(int(round(bubbles.render.w)), 1, 64);
			float step_length = segment_length / float(march_steps);
			float bubble_transmittance = 1.0;
			vec3 accumulated_scatter = vec3(0.0);
			float integrated_raw_density = 0.0;
			float integrated_visual_density = 0.0;
			float integrated_injection = 0.0;
			float shadow_visibility_sum = 0.0;
			float shadow_visibility_weight = 0.0;
			for (int step_index = 0; step_index < 64; ++step_index) {
				if (step_index >= march_steps) break;
				float distance_along_ray = segment_start + (float(step_index) + 0.5) * step_length;
				vec3 world_sample = params.camera.xyz + ray_direction * distance_along_ray;
				vec3 volume_uvw = (world_sample - bounds_min) / max(bubbles.extent_debug.xyz, vec3(EPSILON));
				float raw_density = textureLod(bubble_density, volume_uvw, 0.0).r;
				raw_density = (!isnan(raw_density) && !isinf(raw_density)) ? max(raw_density, 0.0) : 0.0;
				float visual_density = bubble_visual_density(raw_density, world_sample, distance_along_ray);
				float density = pow(max(visual_density, 0.0), max(bubbles.render.z, 0.1));
				integrated_raw_density += raw_density * step_length;
				integrated_visual_density += density * step_length;
				if (bubbles.extent_debug.w > 3.5) {
					integrated_injection += bubble_injection_at(world_sample) * step_length;
				}
				float step_extinction = density * max(bubbles.render.y, 0.0);
				float step_transmittance = exp(-step_extinction * step_length);
				vec3 incident_light = bubble_incident_light(world_sample);
				float shadow_visibility = bubble_shadow_visibility(world_sample, bounds_min, bounds_max);
				vec3 shadow_factor = mix(clamp(bubbles.shadow_tint.rgb, vec3(0.0), vec3(1.0)), vec3(1.0), shadow_visibility);
				incident_light *= shadow_factor;
				float shadow_weight = density * step_length;
				shadow_visibility_sum += shadow_visibility * shadow_weight;
				shadow_visibility_weight += shadow_weight;
				vec3 bubble_scatter = max(bubbles.tint.rgb, vec3(0.0)) * max(bubbles.render.x, 0.0) * incident_light;
				// The bubble source has already travelled surface -> sample in
				// incident_light. It must now travel sample -> camera through water;
				// bubble_transmittance below remains reserved for air self-occlusion.
				float sample_distance_to_camera = max(distance_along_ray, 0.0);
				vec3 water_view_transmittance = exp(-max(params.absorption.rgb, vec3(0.0))
					* max(params.medium.y, 0.0) * sample_distance_to_camera);
				float sample_radial_visibility = exp(-view_extinction * sample_distance_to_camera);
				sample_radial_visibility = sqrt(clamp(sample_radial_visibility, 0.0, 1.0));
				vec3 sample_radiance_to_camera = bubble_scatter * water_view_transmittance * sample_radial_visibility;
				accumulated_scatter += bubble_transmittance * sample_radiance_to_camera * (1.0 - step_transmittance);
				bubble_transmittance *= step_transmittance;
			}
			if (bubbles.extent_debug.w > 3.5) {
				float source_debug = 1.0 - exp(-max(integrated_injection, 0.0));
				color.rgb = vec3(source_debug);
			} else if (bubbles.extent_debug.w > 2.5) {
				float shadow_debug = shadow_visibility_weight > EPSILON ? shadow_visibility_sum / shadow_visibility_weight : 1.0;
				color.rgb = vec3(clamp(shadow_debug, 0.0, 1.0));
			} else if (bubbles.extent_debug.w > 1.5) {
				float density_debug = 1.0 - exp(-max(integrated_visual_density, 0.0));
				color.rgb = vec3(density_debug);
			} else if (bubbles.extent_debug.w > 0.5) {
				float density_debug = 1.0 - exp(-max(integrated_raw_density, 0.0));
				color.rgb = vec3(density_debug);
			} else {
				color.rgb = color.rgb * bubble_transmittance + accumulated_scatter;
			}
		}
	}
}
/* P6_BUBBLE_MAIN_END */
