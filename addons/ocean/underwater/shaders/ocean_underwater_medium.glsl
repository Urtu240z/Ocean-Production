#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 3) uniform sampler2D displacement_long;
layout(set = 0, binding = 4) uniform sampler2D displacement_mid;
layout(set = 0, binding = 5) uniform sampler2D displacement_short;
layout(r8, set = 0, binding = 6) uniform image2D waterline_mask;

layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport;
	vec4 camera;
	vec4 medium; // sea level, maximum path, absorption scale, debug mask flag
	vec4 absorption;
	vec4 scattering;
	vec4 domains;
	vec4 short_fade;
	vec4 mid_fade;
	vec4 long_fade;
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

float fade_weight(float distance_m, vec2 range_m) {
	return 1.0 - smoothstep(range_m.x, max(range_m.y, range_m.x + EPSILON), distance_m);
}

vec2 world_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, EPSILON) + vec2(0.5);
}

float surface_y_at(vec2 world_xz) {
	float distance_m = distance(world_xz, params.camera.xz);
	float long_weight = fade_weight(distance_m, params.long_fade.xy);
	float mid_weight = fade_weight(distance_m, params.mid_fade.xy);
	float short_weight = fade_weight(distance_m, params.short_fade.xy);
	vec3 displacement = textureLod(displacement_long, world_uv(world_xz, params.domains.x), 0.0).xyz * long_weight
		+ textureLod(displacement_mid, world_uv(world_xz, params.domains.y), 0.0).xyz * mid_weight
		+ textureLod(displacement_short, world_uv(world_xz, params.domains.z), 0.0).xyz * short_weight;
	return params.medium.x + displacement.y;
}

float distance_to_plane(vec3 origin, vec3 direction, float plane_y, out bool hit) {
	hit = false;
	if (abs(direction.y) <= EPSILON) {
		return 0.0;
	}
	float distance_m = (plane_y - origin.y) / direction.y;
	if (distance_m > EPSILON && !isnan(distance_m) && !isinf(distance_m)) {
		hit = true;
		return distance_m;
	}
	return 0.0;
}

// Existing P6/V3 optical-path approximation. It deliberately has no dynamic
// ocean-entry depth yet; the near-plane mask only decides which side receives it.
float water_path_for_scene(vec3 scene_world, bool scene_valid, vec2 uv) {
	vec3 camera_world = params.camera.xyz;
	if (!scene_valid) {
		vec3 sky_world;
		if (reconstruct_world(uv, 0.0, sky_world)) {
			bool surface_hit;
			float surface_distance = distance_to_plane(camera_world, normalize(sky_world - camera_world), params.medium.x, surface_hit);
			if (surface_hit) {
				return surface_distance;
			}
		}
		return params.medium.y;
	}
	vec3 ray = scene_world - camera_world;
	float ray_length = length(ray);
	if (ray_length <= EPSILON || isnan(ray_length) || isinf(ray_length)) {
		return 0.0;
	}
	if (scene_world.y < params.medium.x) {
		return ray_length;
	}
	bool surface_hit;
	float surface_distance = distance_to_plane(camera_world, ray / ray_length, params.medium.x, surface_hit);
	return (surface_hit && surface_distance <= ray_length) ? surface_distance : 0.0;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	// Godot 4.7 uses reversed-Z: 1.0 is the camera near plane. This reuses
	// P6's inverse view-projection reconstruction path without scene depth.
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	vec3 near_world;
	bool near_valid = reconstruct_world(uv, 1.0, near_world);
	float mask = near_valid && near_world.y < surface_y_at(near_world.xz) ? 1.0 : 0.0;

	imageStore(waterline_mask, pixel, vec4(mask, 0.0, 0.0, 1.0));
	if (params.medium.w > 0.5) {
		imageStore(color_image, pixel, vec4(vec3(mask), 1.0));
		return;
	}
	if (mask < 0.5) {
		return;
	}

	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 scene_world = vec3(0.0);
	bool scene_valid = raw_depth > EPSILON && raw_depth <= 1.000001 && reconstruct_world(uv, raw_depth, scene_world);
	float water_path_m = clamp(water_path_for_scene(scene_world, scene_valid, uv), 0.0, params.medium.y);
	if (isnan(water_path_m) || isinf(water_path_m) || water_path_m <= EPSILON) {
		return;
	}
	vec4 color = imageLoad(color_image, pixel);
	vec3 transmittance = exp(-max(params.absorption.rgb, vec3(0.0)) * max(params.medium.z, 0.0) * water_path_m);
	float scattering_response = 1.0 - exp(-max(params.scattering.w, 0.0) * water_path_m);
	color.rgb = color.rgb * transmittance + max(params.scattering.rgb, vec3(0.0)) * scattering_response * max(params.absorption.w, 0.0);
	imageStore(color_image, pixel, color);
}
