#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 3) uniform sampler2D displacement_long;
layout(set = 0, binding = 4) uniform sampler2D displacement_mid;
layout(set = 0, binding = 5) uniform sampler2D displacement_short;
layout(r8, set = 0, binding = 6) uniform image2D waterline_mask;

layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport;
	vec4 camera;
	vec4 medium;
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

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	// Godot 4.7 uses reversed-Z: 1.0 is the camera near plane. This reuses
	// P6's inverse view-projection reconstruction path without scene depth.
	vec3 near_world;
	bool near_valid = reconstruct_world((vec2(pixel) + vec2(0.5)) / params.viewport.xy, 1.0, near_world);
	float mask = near_valid && near_world.y < surface_y_at(near_world.xz) ? 1.0 : 0.0;

	imageStore(waterline_mask, pixel, vec4(mask, 0.0, 0.0, 1.0));
	// P6 prototype presentation only: no Beer-Lambert or scattering is active.
	imageStore(color_image, pixel, vec4(vec3(mask), 1.0));
}
