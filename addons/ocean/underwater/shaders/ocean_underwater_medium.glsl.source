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
	vec4 sun_direction_energy; // xyz light_into_water, w DirectionalLight energy
	vec4 sun_color_strength; // DirectionalLight color * profile tint, w strength
	vec4 sunray_field; // enabled, anisotropy, density, maximum distance
	vec4 sunray_pattern; // scale, contrast, length variation, V3 compatibility speed
	vec4 sunray_wave; // enabled, continuous phase, speed, intensity strength
	vec4 sunray_wave_shape; // width strength, depth fade, constant phase, segment mode
	vec4 sunray_debug; // FINAL, BEAM_FIELD, SUN_DIRECTION, WAVE_MODULATION, CONTRIBUTION
} params;

// P6_BUBBLE_BINDINGS

const float EPSILON = 0.00001;
const float SUNRAY_WORLD_SLICE_SPACING_M = 14.0;

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

// P6_BUBBLE_HELPERS

float sunray_phase_response(vec3 view_to_camera, vec3 light_into_water) {
	if (params.sunray_wave_shape.z > 0.5) return 1.0;
	float cos_theta = clamp(dot(view_to_camera, light_into_water), -1.0, 1.0);
	float g = clamp(params.sunray_field.y, 0.0, 0.95);
	float denominator = 1.0 + g * g - 2.0 * g * cos_theta;
	float phase = (1.0 - g * g) / max(pow(denominator, 1.5), 0.001);
	float forward_denominator = 1.0 + g * g - 2.0 * g;
	float forward_phase = (1.0 - g * g) / max(pow(forward_denominator, 1.5), 0.001);
	float forward_gate = smoothstep(-0.15, 0.35, cos_theta);
	return clamp(phase / max(forward_phase, 0.001) * forward_gate, 0.0, 1.0);
}

bool sunray_beam_coord(vec3 world_position, vec3 light_into_water, out vec2 beam_coord) {
	beam_coord = vec2(0.0);
	if (!finite_vec3(light_into_water) || length(light_into_water) <= EPSILON) return false;
	vec3 l = normalize(light_into_water);
	vec3 reference = abs(l.y) < 0.98 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 u = cross(reference, l);
	if (!finite_vec3(u) || length(u) <= EPSILON) return false;
	u = normalize(u);
	vec3 v = cross(l, u);
	if (!finite_vec3(v) || length(v) <= EPSILON) return false;
	v = normalize(v);
	beam_coord = vec2(dot(world_position, u), dot(world_position, v));
	return !any(isnan(beam_coord)) && !any(isinf(beam_coord));
}

float sunray_wave_focus(vec3 light_entry, float wave_time) {
	float primary = sin(dot(light_entry.xz, vec2(0.31, 0.19)) + wave_time * 1.10);
	float secondary = sin(dot(light_entry.xz, vec2(-0.17, 0.28)) - wave_time * 1.70 + 1.83);
	float tertiary = cos(dot(light_entry.xz, vec2(0.09, -0.12)) + wave_time * 0.55 + 0.61);
	float raw_focus = 0.5 + 0.5 * (primary * 0.52 + secondary * 0.33 + tertiary * 0.15);
	return smoothstep(0.16, 0.84, clamp(raw_focus, 0.0, 1.0));
}

void sunray_wave_modulation(vec3 light_entry, vec3 sample_point, out float wave_focus,
		out float width_factor, out float intensity_factor) {
	wave_focus = 0.5;
	width_factor = 1.0;
	intensity_factor = 1.0;
	if (params.sunray_wave.x < 0.5) return;
	// The CPU integrates Production wave_time * wave speed. Runtime speed edits
	// therefore change the derivative, never the already accumulated phase.
	float wave_time = params.sunray_wave.y;
	wave_focus = sunray_wave_focus(light_entry, wave_time);
	float depth_below_surface = max(params.volume.w - sample_point.y, 0.0);
	float depth_envelope = 1.0 - smoothstep(0.0, max(params.sunray_wave_shape.y, EPSILON), depth_below_surface);
	float centered_focus = wave_focus * 2.0 - 1.0;
	intensity_factor = clamp(1.0 + centered_focus * clamp(params.sunray_wave.w, 0.0, 0.45) * depth_envelope, 0.50, 1.50);
	width_factor = clamp(1.0 + centered_focus * clamp(params.sunray_wave_shape.x, 0.0, 0.20) * depth_envelope, 0.60, 1.40);
}

float sunray_beam_field(vec3 sample_world, vec3 light_into_water, float width_factor, out vec2 beam_coord) {
	beam_coord = vec2(0.0);
	if (!sunray_beam_coord(sample_world, light_into_water, beam_coord)) return 0.0;
	float scale = max(params.sunray_pattern.x, 0.01);
	float broad_phase = beam_coord.x * (0.72 * scale) + sin(beam_coord.y * 0.13) * 0.24;
	float medium_phase = beam_coord.x * (2.17 * scale) + beam_coord.y * 0.18 + 1.37;
	float narrow_phase = beam_coord.x * (3.49 * scale) - beam_coord.y * 0.08 + 0.61;
	float safe_width = max(width_factor, 0.01);
	float broad = pow(max(0.0, 0.5 + 0.5 * cos(broad_phase)), 2.1 / safe_width);
	float medium = pow(max(0.0, 0.5 + 0.5 * sin(medium_phase)), 4.2 / safe_width);
	float narrow = pow(max(0.0, 0.5 + 0.5 * cos(narrow_phase)), 8.0 / safe_width);
	float slow_intensity = 0.84 + 0.16 * (0.5 + 0.5 * sin(beam_coord.y * 0.09));
	float ridges = clamp((broad * 0.82 + medium * 0.30 + narrow * 0.12) * slow_intensity, 0.0, 1.0);
	float contrast = clamp(params.sunray_pattern.y / 1.4, 0.0, 1.0);
	return mix(0.5, 0.30 + 0.70 * ridges, contrast);
}

float sunray_reach_factor(vec2 beam_coord) {
	float longitudinal_wave = sin(beam_coord.x * 0.23 + sin(beam_coord.y * 0.09) * 0.35);
	float diagonal_wave = sin(beam_coord.x * 0.11 + beam_coord.y * 0.05 + 1.21);
	return clamp(0.5 + 0.5 * (longitudinal_wave * 0.60 + diagonal_wave * 0.40), 0.0, 1.0);
}

bool sunray_world_slice_interval(vec3 camera_world, vec3 view_ray_world, float segment_m,
		vec3 light_into_water, int slice_id, out float interval_begin_m, out float interval_end_m) {
	interval_begin_m = 0.0;
	interval_end_m = 0.0;
	if (segment_m <= EPSILON || !finite_vec3(light_into_water)) return false;
	float longitudinal_at_camera = dot(camera_world, light_into_water);
	float longitudinal_per_m = dot(view_ray_world, light_into_water);
	float slice_min = float(slice_id) * SUNRAY_WORLD_SLICE_SPACING_M;
	float slice_max = slice_min + SUNRAY_WORLD_SLICE_SPACING_M;
	if (abs(longitudinal_per_m) <= EPSILON) {
		if (longitudinal_at_camera < slice_min || longitudinal_at_camera > slice_max) return false;
		interval_end_m = segment_m;
		return true;
	}
	float t_a = (slice_min - longitudinal_at_camera) / longitudinal_per_m;
	float t_b = (slice_max - longitudinal_at_camera) / longitudinal_per_m;
	interval_begin_m = max(0.0, min(t_a, t_b));
	interval_end_m = min(segment_m, max(t_a, t_b));
	return interval_end_m - interval_begin_m > EPSILON;
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
	// Ocean V3 sunrays are integrated inside this compositor pass. With the
	// system disabled the branch is skipped and the P6.5 + Bubble path is exact.
	if (params.sunray_field.x > 0.5 && direction_valid) {
		vec3 light_into_water = params.sun_direction_energy.xyz;
		float light_length = length(light_into_water);
		bool light_valid = finite_vec3(light_into_water) && light_length > EPSILON
			&& !isnan(light_length) && !isinf(light_length);
		if (light_valid) light_into_water /= light_length;
		int sunray_debug_mode = clamp(int(round(params.sunray_debug.x)), 0, 4);
		vec3 sunray_contribution = vec3(0.0);
		float integrated_length = 0.0;
		float pattern_integral = 0.0;
		float wave_integral = 0.0;
		if (light_valid) {
			float segment_base = optical_distance;
			// The analytic route follows the infinite sea plane. It introduces no
			// camera-centred region; the depth-driven route remains available for parity.
			if (params.sunray_wave_shape.w > 0.5 && ray_direction.y > EPSILON) {
				float surface_distance = (params.volume.w - params.camera.y) / ray_direction.y;
				if (surface_distance >= 0.0 && !isnan(surface_distance) && !isinf(surface_distance)) {
					segment_base = min(segment_base, surface_distance);
				}
			}
			float sunray_segment = min(segment_base, max(params.sunray_field.w, EPSILON));
			if (sunray_segment > EPSILON) {
				float longitudinal_begin = dot(params.camera.xyz, light_into_water);
				float longitudinal_end = dot(params.camera.xyz + ray_direction * sunray_segment, light_into_water);
				int first_slice_id = int(floor(min(longitudinal_begin, longitudinal_end) / SUNRAY_WORLD_SLICE_SPACING_M));
				int last_slice_id = int(floor(max(longitudinal_begin, longitudinal_end) / SUNRAY_WORLD_SLICE_SPACING_M));
				for (int slice_offset = 0; slice_offset < 4; ++slice_offset) {
					int slice_id = first_slice_id + slice_offset;
					if (slice_id > last_slice_id) break;
					float interval_begin = 0.0;
					float interval_end = 0.0;
					if (!sunray_world_slice_interval(params.camera.xyz, ray_direction, sunray_segment,
							light_into_water, slice_id, interval_begin, interval_end)) continue;
					float slice_length = interval_end - interval_begin;
					float sample_distance = 0.5 * (interval_begin + interval_end);
					vec3 sample_point = params.camera.xyz + ray_direction * sample_distance;
					vec3 toward_surface = -light_into_water;
					if (toward_surface.y <= EPSILON) continue;
					float light_distance = (params.volume.w - sample_point.y) / toward_surface.y;
					if (light_distance < 0.0 || isnan(light_distance) || isinf(light_distance)) continue;
					vec3 light_entry = sample_point + toward_surface * light_distance;
					if (!finite_vec3(light_entry) || abs(light_entry.y - params.volume.w) > 0.01) continue;

					float wave_focus = 0.5;
					float wave_width = 1.0;
					float wave_intensity = 1.0;
					sunray_wave_modulation(light_entry, sample_point, wave_focus, wave_width, wave_intensity);
					vec2 beam_coord = vec2(0.0);
					float beam_field = sunray_beam_field(sample_point, light_into_water, wave_width, beam_coord);
					float reach = sunray_reach_factor(beam_coord);
					float variable_ratio = mix(0.35, 1.0, reach);
					float maximum_reach = max(params.sunray_field.w, EPSILON)
						* mix(1.0, variable_ratio, clamp(params.sunray_pattern.z, 0.0, 1.0));
					float reach_envelope = 1.0 - smoothstep(maximum_reach * 0.75, maximum_reach, light_distance);
					float pattern = beam_field * reach_envelope * wave_intensity;
					if (isnan(pattern) || isinf(pattern)) continue;

					vec3 sun_path_transmittance = exp(-max(params.absorption.rgb, vec3(0.0))
						* max(params.medium.y, 0.0) * light_distance);
					float sample_depth = max(params.volume.w - sample_point.y, 0.0);
					float depth_light = exp(-sample_depth * max(params.volume.y, 0.0));
					vec3 incident_light = max(params.sun_color_strength.rgb, vec3(0.0))
						* max(params.ambient_light.x, 0.0) * depth_light * sun_path_transmittance;
					vec3 view_transmittance = exp(-max(params.absorption.rgb, vec3(0.0))
						* max(params.medium.y, 0.0) * sample_distance);
					float sample_radial = sqrt(clamp(exp(-view_extinction * sample_distance), 0.0, 1.0));
					float density_weight = max(params.sunray_field.z, 0.0) * slice_length;
					sunray_contribution += incident_light * view_transmittance * sample_radial * pattern * density_weight;
					integrated_length += slice_length;
					pattern_integral += beam_field * reach_envelope * slice_length;
					wave_integral += wave_intensity * slice_length;
				}
			}
			float phase_response = sunray_phase_response(-ray_direction, light_into_water);
			float density_path = max(params.sunray_field.z, 0.0) * integrated_length;
			float integration_normalizer = 1.0 / max(1.0, density_path);
			sunray_contribution *= max(params.sun_direction_energy.w, 0.0)
				* max(params.sun_color_strength.w, 0.0) * phase_response * integration_normalizer;
			float contribution_luma = dot(sunray_contribution, vec3(0.2126, 0.7152, 0.0722));
			float wave_average = integrated_length > EPSILON ? wave_integral / integrated_length : 1.0;
			float luma_limit = 0.75 * max(1.0, wave_average);
			if (contribution_luma > luma_limit) sunray_contribution *= luma_limit / contribution_luma;
		}
		if (sunray_debug_mode == 1) {
			color.rgb = vec3(integrated_length > EPSILON ? pattern_integral / integrated_length : 0.0);
			imageStore(color_image, pixel, color);
			return;
		} else if (sunray_debug_mode == 2) {
			color.rgb = light_valid ? light_into_water * 0.5 + 0.5 : vec3(0.0);
			imageStore(color_image, pixel, color);
			return;
		} else if (sunray_debug_mode == 3) {
			color.rgb = vec3(integrated_length > EPSILON ? clamp((wave_integral / integrated_length) / 1.5, 0.0, 1.0) : 0.0);
			imageStore(color_image, pixel, color);
			return;
		} else if (sunray_debug_mode == 4) {
			color.rgb = sunray_contribution;
			imageStore(color_image, pixel, color);
			return;
		}
		color.rgb += max(sunray_contribution, vec3(0.0));
	}
	// P6_BUBBLE_MAIN
	imageStore(color_image, pixel, color);
}
