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
			vec3 near_world;
			bool near_valid = reconstruct_world(uv, 1.0, near_world);
			vec3 surface_point = vec3(params.camera.x, camera_state.value.y, params.camera.z);
			vec3 surface_normal = camera_state.state1.xyz;
			bool normal_valid = finite_vec3(surface_normal) && length(surface_normal) > EPSILON;
			underwater = near_valid && normal_valid && dot(near_world - surface_point, normalize(surface_normal)) < 0.0;
		}
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
	if (ocean_exit_valid) {
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
	vec4 color = imageLoad(color_image, pixel);
	vec3 transmittance = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.y, 0.0) * water_path_m);
	float scattering_response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
	color.rgb = color.rgb * transmittance + max(params.scattering.rgb, vec3(0.0)) * scattering_response * max(params.absorption.w, 0.0);
	imageStore(color_image, pixel, color);
}
