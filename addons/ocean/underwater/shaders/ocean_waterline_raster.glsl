#[vertex]
#version 450

layout(location = 0) in vec3 vertex_position;
layout(set = 0, binding = 0) uniform sampler2D displacement_long;
layout(set = 0, binding = 1) uniform sampler2D displacement_mid;
layout(set = 0, binding = 2) uniform sampler2D displacement_short;
layout(set = 0, binding = 3, std140) uniform RasterParams {
	mat4 view_projection;
	mat4 inverse_view_projection;
	vec4 camera_sea;
	vec4 domains;
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
} params;
layout(push_constant, std430) uniform DrawParams {
	mat4 model;
} draw_params;

float fade_weight(float distance_m, vec2 range_m) {
	return 1.0 - smoothstep(range_m.x, range_m.y, distance_m);
}

vec2 world_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

void main() {
	vec3 world = (draw_params.model * vec4(vertex_position, 1.0)).xyz;
	float distance_m = distance(world.xz, params.camera_sea.xz);
	vec3 displacement = texture(displacement_long, world_uv(world.xz, params.domains.x)).xyz
		* fade_weight(distance_m, params.long_fade.xy);
	displacement += texture(displacement_mid, world_uv(world.xz, params.domains.y)).xyz
		* fade_weight(distance_m, params.mid_fade.xy);
	displacement += texture(displacement_short, world_uv(world.xz, params.domains.z)).xyz
		* fade_weight(distance_m, params.short_fade.xy);
	gl_Position = params.view_projection * vec4(world + displacement, 1.0);
}

#[fragment]
#version 450

layout(location = 0) out vec2 waterline_mask;
layout(location = 1) out float ocean_depth;

void main() {
	// R is the actual raster face side. G explicitly distinguishes missing
	// coverage from a valid back-facing (underwater) surface.
	waterline_mask = vec2(gl_FrontFacing ? 1.0 : 0.0, 1.0);
	ocean_depth = gl_FragCoord.z;
}
