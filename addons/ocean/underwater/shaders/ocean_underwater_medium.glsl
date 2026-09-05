#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 3) uniform sampler2D displacement_long;
layout(set = 0, binding = 4) uniform sampler2D displacement_mid;
layout(set = 0, binding = 5) uniform sampler2D displacement_short;
layout(set = 0, binding = 6) uniform sampler2D normal_long;
layout(set = 0, binding = 7) uniform sampler2D normal_mid;
layout(set = 0, binding = 8) uniform sampler2D normal_short;
layout(r8, set = 0, binding = 9) uniform image2D waterline_mask;

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

void surface_sample(vec2 world_xz, out float surface_y, out vec3 surface_normal) {
	float distance_m = distance(world_xz, params.camera.xz);
	float long_weight = fade_weight(distance_m, params.long_fade.xy);
	float mid_weight = fade_weight(distance_m, params.mid_fade.xy);
	float short_weight = fade_weight(distance_m, params.short_fade.xy);
	vec3 displacement = textureLod(displacement_long, world_uv(world_xz, params.domains.x), 0.0).xyz * long_weight
		+ textureLod(displacement_mid, world_uv(world_xz, params.domains.y), 0.0).xyz * mid_weight
		+ textureLod(displacement_short, world_uv(world_xz, params.domains.z), 0.0).xyz * short_weight;
	surface_y = params.medium.x + displacement.y;
	surface_normal = normalize(
		textureLod(normal_long, world_uv(world_xz, params.domains.x), 0.0).xyz * long_weight
		+ textureLod(normal_mid, world_uv(world_xz, params.domains.y), 0.0).xyz * mid_weight
		+ textureLod(normal_short, world_uv(world_xz, params.domains.z), 0.0).xyz * short_weight
	);
}

float surface_match_tolerance(float distance_m) {
	// The visible clipmap displaces vertices, while this classification samples at
	// the resolved-depth fragment position. The tolerance grows only with the
	// existing far clipmap spacing; it never changes the rendered ocean surface.
	return mix(0.10, 1.50, smoothstep(200.0, 2500.0, distance_m));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	float mask = 0.0;
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	vec3 world_position;
	if (raw_depth > EPSILON && raw_depth <= 1.000001 && reconstruct_world((vec2(pixel) + vec2(0.5)) / params.viewport.xy, raw_depth, world_position)) {
		float surface_y;
		vec3 surface_normal;
		surface_sample(world_position.xz, surface_y, surface_normal);
		float distance_m = distance(world_position.xz, params.camera.xz);
		bool is_ocean_surface = abs(world_position.y - surface_y) <= surface_match_tolerance(distance_m);
		if (is_ocean_surface && dot(surface_normal, params.camera.xyz - world_position) < 0.0) {
			mask = 1.0;
		}
	}

	imageStore(waterline_mask, pixel, vec4(mask, 0.0, 0.0, 1.0));
	// P6 prototype presentation only: no Beer-Lambert or scattering is active.
	imageStore(color_image, pixel, vec4(vec3(mask), 1.0));
}
