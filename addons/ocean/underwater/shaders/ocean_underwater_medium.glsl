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
} params;

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
	float scattering_response = 1.0 - exp(-max(params.scattering.w, 0.0) * optical_distance);
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
	// It starts at zero, peaks at medium distance, then fades with the same
	// radial closure that prevents an infinite, flat color fill.
	float medium_response = scattering_response * radial_visibility;
	vec3 ambient_radiance = scatter_tint * max(params.ambient_light.x, 0.0) * surface_energy;
	vec3 scatter_term = ambient_radiance * medium_response * max(params.absorption.w, 0.0);
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
		imageStore(color_image, pixel, vec4(vec3(medium_response), 1.0));
		return;
	} else if (debug_mode > 1.5) {
		imageStore(color_image, pixel, vec4(vec3(scene_radial_visibility), 1.0));
		return;
	} else if (debug_mode > 0.5) {
		imageStore(color_image, pixel, vec4(vec3(surface_energy), 1.0));
		return;
	}
	color.rgb = scene_term + scatter_term;
	imageStore(color_image, pixel, color);
}
