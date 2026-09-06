#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 3) uniform sampler2D waterline_mask;
layout(set = 0, binding = 4) uniform sampler2D waterline_depth;
layout(set = 0, binding = 5, std430) readonly buffer CameraWaterState {
	vec4 value; // signed height, surface height, valid, reserved
	vec4 state1; // local tangent-plane normal, w reserved
} camera_state;
layout(set = 0, binding = 6) uniform sampler3D bubble_density;
layout(set = 0, binding = 8) uniform sampler2D bubble_displacement_long;
layout(set = 0, binding = 9) uniform sampler2D bubble_displacement_mid;
layout(set = 0, binding = 10) uniform sampler2D bubble_displacement_short;

layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport;
	vec4 camera; // xyz camera position, w exit margin
	vec4 medium; // maximum path, absorption scale, debug mask flag, enter margin
	vec4 absorption;
	vec4 scattering;
	vec4 meniscus; // enabled, width in pixels, strength, debug
	vec4 meniscus_shape; // softness, reserved
	vec4 volume; // visibility distance, depth light falloff, debug mode, sea level
	vec4 ambient_light; // surface light strength, reserved
} params;

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
} bubbles;

const float EPSILON = 0.00001;

bool finite_vec3(vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool reconstruct_world(vec2 uv, float raw_depth, out vec3 world_position) {
	vec4 world = params.inverse_view_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(world.w) <= EPSILON) {
		return false;
	}
	world_position = world.xyz / world.w;
	return finite_vec3(world_position);
}

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

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	// R is raw actual front/back classification. G is raw raster coverage.
	vec2 raster = textureLod(waterline_mask, uv, 0.0).rg;
	bool raster_valid = raster.g >= 0.5;
	bool raw_water = raster_valid && raster.r < 0.5;
	bool camera_state_valid = camera_state.value.z >= 0.5
		&& !isnan(camera_state.value.x) && !isinf(camera_state.value.x);
	bool underwater = raw_water;
	float meniscus_weight = 0.0;
	float distance_px = 0.0;
	if (camera_state_valid) {
		float signed_height = camera_state.value.x;
		if (signed_height > params.camera.w) {
			// Force air: visible ocean has no authority over camera medium.
			underwater = false;
		} else if (signed_height < -params.medium.w) {
			// Force water: every camera-side segment starts in water.
			underwater = true;
		} else {
			// Split the local intersection against the GPU-computed tangent plane.
			vec4 clip = vec4(uv * 2.0 - 1.0, 1.0, 1.0);
			vec4 h = params.inverse_view_projection * clip;
			bool near_valid = abs(h.w) > EPSILON && !isnan(h.w) && !isinf(h.w);
			vec3 near_world = near_valid ? h.xyz / h.w : vec3(0.0);
			vec3 surface_point = vec3(params.camera.x, camera_state.value.y, params.camera.z);
			vec3 surface_normal = camera_state.state1.xyz;
			bool normal_valid = finite_vec3(surface_normal) && length(surface_normal) > EPSILON;
			vec3 plane_normal = normal_valid ? normalize(surface_normal) : vec3(0.0);
			float signed_value = near_valid && normal_valid ? dot(near_world - surface_point, plane_normal) : 0.0;
			underwater = near_valid && normal_valid && signed_value < 0.0;
			if (params.meniscus.x > 0.5 && near_valid && normal_valid) {
				vec4 h_x = h + params.inverse_view_projection[0] * (2.0 / params.viewport.x);
				vec4 h_y = h + params.inverse_view_projection[1] * (2.0 / params.viewport.y);
				bool reference_valid = abs(h_x.w) > EPSILON && abs(h_y.w) > EPSILON
					&& !isnan(h_x.w) && !isinf(h_x.w) && !isnan(h_y.w) && !isinf(h_y.w);
				vec3 world_x = reference_valid ? h_x.xyz / h_x.w : vec3(0.0);
				vec3 world_y = reference_valid ? h_y.xyz / h_y.w : vec3(0.0);
				vec3 delta_world_x = world_x - near_world;
				vec3 delta_world_y = world_y - near_world;
				float ds_dx = dot(delta_world_x, plane_normal);
				float ds_dy = dot(delta_world_y, plane_normal);
				float gradient_px = length(vec2(ds_dx, ds_dy));
				if (reference_valid && finite_vec3(delta_world_x) && finite_vec3(delta_world_y) && !isnan(gradient_px) && !isinf(gradient_px) && gradient_px > EPSILON) {
					distance_px = abs(signed_value) / gradient_px;
					float falloff_start_px = params.meniscus.y * (1.0 - clamp(params.meniscus_shape.x, 0.05, 1.0));
					meniscus_weight = 1.0 - smoothstep(falloff_start_px, params.meniscus.y, distance_px);
					if (isnan(meniscus_weight) || isinf(meniscus_weight)) meniscus_weight = 0.0;
				}
			}
		}
	}
	if (params.meniscus.w > 0.5) {
		imageStore(color_image, pixel, vec4(vec3(meniscus_weight), 1.0));
		return;
	}
	if (params.medium.z > 0.5) {
		vec3 debug_color = !camera_state_valid ? vec3(1.0, 0.0, 1.0) : (underwater ? vec3(0.0) : vec3(1.0));
		imageStore(color_image, pixel, vec4(debug_color, 1.0));
		return;
	}
	if (!underwater) {
		return;
	}

	float ocean_raw_depth = textureLod(waterline_depth, uv, 0.0).r;
	float scene_raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 ocean_world = vec3(0.0);
	vec3 scene_world = vec3(0.0);
	bool ocean_exit_valid = ocean_raw_depth > EPSILON
		&& ocean_raw_depth <= 1.000001
		&& reconstruct_world(uv, ocean_raw_depth, ocean_world);
	bool scene_valid = scene_raw_depth > EPSILON
		&& scene_raw_depth <= 1.000001
		&& reconstruct_world(uv, scene_raw_depth, scene_world);
	// A back-facing mask means the camera-side segment starts in water. Its
	// length therefore begins at the camera and ends at the first scene hit or,
	// if sooner, at the rasterized ocean backface where the ray exits the water.
	float water_path_m = params.medium.x;
	if (scene_valid) {
		water_path_m = distance(params.camera.xyz, scene_world);
	}
	if (raster_valid && raw_water && ocean_exit_valid) {
		float ocean_exit_distance = distance(params.camera.xyz, ocean_world);
		if (!scene_valid || ocean_exit_distance < water_path_m) {
			water_path_m = ocean_exit_distance;
		}
	}
	// Clear scene depth plus clear ocean depth is deliberate far-water fallback.
	// A zero ocean depth means no surface exit was rasterized along this ray.
	water_path_m = clamp(water_path_m, 0.0, params.medium.x);
	if (isnan(water_path_m) || isinf(water_path_m) || water_path_m <= EPSILON) {
		return;
	}
	float optical_distance = water_path_m;
	if (meniscus_weight > 0.0) {
		float m = clamp(params.meniscus.z * meniscus_weight, 0.0, 1.0);
		optical_distance *= 1.0 - m;
	}
	vec4 color = imageLoad(color_image, pixel);
	vec3 transmittance = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.y, 0.0) * optical_distance);
	float camera_depth = max(params.volume.w - params.camera.y, 0.0);
	float surface_energy = exp(-camera_depth * max(params.volume.y, 0.0));
	// The intuitive distance means roughly 25% radial energy remains there.
	float view_extinction = log(4.0) / max(params.volume.x, 0.001);
	float radial_visibility = exp(-view_extinction * optical_distance);
	surface_energy = clamp(surface_energy, 0.0, 1.0);
	radial_visibility = clamp(radial_visibility, 0.0, 1.0);
	// Scene radiance already carries RGB Beer–Lambert. A square-root radial
	// shaping prevents the independent radial gate from crushing useful nearby
	// contrast, while the unsoftened gate still closes the distant medium.
	float scene_radial_visibility = sqrt(radial_visibility);
	vec3 scene_term = color.rgb * transmittance * scene_radial_visibility;
	vec3 scattering_color = max(params.scattering.rgb, vec3(0.0));
	float tint_peak = max(max(scattering_color.r, scattering_color.g), scattering_color.b);
	vec3 scatter_tint = tint_peak > EPSILON ? scattering_color / tint_peak : vec3(0.0);
	vec3 ray_endpoint = vec3(0.0);
	bool ray_valid = reconstruct_world(uv, 0.0, ray_endpoint);
	vec3 ray_direction = ray_valid ? normalize(ray_endpoint - params.camera.xyz) : vec3(0.0);
	bool direction_valid = ray_valid && finite_vec3(ray_direction) && length(ray_direction) > EPSILON;
	ray_direction = direction_valid ? ray_direction : vec3(0.0);
	// Integrate exp(-depth_falloff * depth(s)) * exp(-view_extinction * s)
	// analytically. The view extinction lives inside the integral, so a distant
	// scene hit cannot erase the nearby water volume.
	float integration_rate = view_extinction - max(params.volume.y, 0.0) * ray_direction.y;
	float integrated_length = optical_distance;
	if (abs(integration_rate) > EPSILON) {
		float exponent = clamp(-integration_rate * optical_distance, -50.0, 50.0);
		integrated_length = (1.0 - exp(exponent)) / integration_rate;
	}
	integrated_length = max(integrated_length, 0.0);
	float integrated_kernel = clamp(view_extinction * integrated_length, 0.0, 1.0);
	float integrated_volume = surface_energy * integrated_kernel;
	vec3 ambient_radiance = scatter_tint * max(params.ambient_light.x, 0.0) * surface_energy;
	vec3 scatter_term = ambient_radiance * max(params.scattering.w, 0.0) * integrated_kernel;
	float debug_mode = params.volume.z;
	if (debug_mode > 5.5) {
		imageStore(color_image, pixel, vec4(scene_term + scatter_term, 1.0));
		return;
	} else if (debug_mode > 4.5) {
		imageStore(color_image, pixel, vec4(clamp(scatter_term, vec3(0.0), vec3(1.0)), 1.0));
		return;
	} else if (debug_mode > 3.5) {
		imageStore(color_image, pixel, vec4(clamp(ambient_radiance, vec3(0.0), vec3(1.0)), 1.0));
		return;
	} else if (debug_mode > 2.5) {
		imageStore(color_image, pixel, vec4(vec3(integrated_volume), 1.0));
		return;
	} else if (debug_mode > 1.5) {
		imageStore(color_image, pixel, vec4(vec3(ray_direction.y * 0.5 + 0.5), 1.0));
		return;
	} else if (debug_mode > 0.5) {
		imageStore(color_image, pixel, vec4(vec3(1.0 - surface_energy), 1.0));
		return;
	}
	color.rgb = scene_term + scatter_term;
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
				float integrated_density = 0.0;
				float integrated_injection = 0.0;
				for (int step_index = 0; step_index < 64; ++step_index) {
					if (step_index >= march_steps) break;
					float distance_along_ray = segment_start + (float(step_index) + 0.5) * step_length;
					vec3 world_sample = params.camera.xyz + ray_direction * distance_along_ray;
					vec3 volume_uvw = (world_sample - bounds_min) / max(bubbles.extent_debug.xyz, vec3(EPSILON));
					float raw_density = textureLod(bubble_density, volume_uvw, 0.0).r;
					raw_density = (!isnan(raw_density) && !isinf(raw_density)) ? max(raw_density, 0.0) : 0.0;
					float density = pow(raw_density, max(bubbles.render.z, 0.1));
					integrated_density += density * step_length;
					if (bubbles.extent_debug.w > 1.5) {
						integrated_injection += bubble_injection_at(world_sample) * step_length;
					}
					float step_extinction = density * max(bubbles.render.y, 0.0);
					float step_transmittance = exp(-step_extinction * step_length);
					vec3 bubble_scatter = max(bubbles.tint.rgb, vec3(0.0)) * max(bubbles.render.x, 0.0);
					accumulated_scatter += bubble_transmittance * bubble_scatter * (1.0 - step_transmittance);
					bubble_transmittance *= step_transmittance;
				}
				if (bubbles.extent_debug.w > 1.5) {
					float source_debug = 1.0 - exp(-max(integrated_injection, 0.0));
					color.rgb = vec3(source_debug);
				} else if (bubbles.extent_debug.w > 0.5) {
					float density_debug = 1.0 - exp(-max(integrated_density, 0.0));
					color.rgb = vec3(density_debug);
				} else {
					color.rgb = color.rgb * bubble_transmittance + accumulated_scatter;
				}
			}
		}
	}
	imageStore(color_image, pixel, color);
}
