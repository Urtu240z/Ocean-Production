#[vertex]
#version 450

layout(location = 0) in vec3 vertex_position;
layout(set = 0, binding = 0) uniform sampler2D displacement_long;
layout(set = 0, binding = 1) uniform sampler2D displacement_mid;
layout(set = 0, binding = 2) uniform sampler2D displacement_short;
layout(set = 0, binding = 4) uniform sampler2D coastal_field;
layout(set = 0, binding = 5) uniform sampler2D coastal_warp;
layout(set = 0, binding = 3, std140) uniform RasterParams {
	mat4 view_projection;
	mat4 inverse_view_projection;
	vec4 camera_sea;
	vec4 domains;
	vec4 ocean_space; // x = H clipmap geometry scale, y = V ocean scale
	vec4 coastal_origin_extent; // xy origin, zw extent
	vec4 coastal_warp_origin_extent; // xy warp origin, zw warp extent
	vec4 coastal_control; // x enabled, y warp_detj_safe
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

vec3 ocean_space_displacement(vec3 authored_displacement) {
	float horizontal_scale = params.ocean_space.x;
	float vertical_scale = params.ocean_space.y;
	return vec3(
		authored_displacement.x * horizontal_scale,
		authored_displacement.y * vertical_scale,
		authored_displacement.z * horizontal_scale
	);
}

vec2 world_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

vec2 coastal_uv_from_world(vec2 world_xz, vec2 origin, vec2 extent) {
	return (world_xz - origin) / max(extent, vec2(0.001));
}

float coastal_confidence_value(vec4 warp, float detj_safe) {
	return smoothstep(0.0, detj_safe, warp.z) * warp.w;
}

vec3 authored_long_at(vec2 q) {
	vec3 long_displacement = textureLod(displacement_long, world_uv(q, params.domains.x), 0.0).xyz;
	if (params.coastal_control.x <= 0.5) {
		return long_displacement;
	}
	vec2 coast_uv = coastal_uv_from_world(q, params.coastal_origin_extent.xy, params.coastal_origin_extent.zw);
	if (any(lessThan(coast_uv, vec2(0.0))) || any(greaterThan(coast_uv, vec2(1.0)))) {
		return long_displacement;
	}
	vec4 field = textureLod(coastal_field, coast_uv, 0.0);
	vec2 warp_uv = clamp(coastal_uv_from_world(q, params.coastal_warp_origin_extent.xy, params.coastal_warp_origin_extent.zw), vec2(0.0), vec2(1.0));
	vec4 warp = textureLod(coastal_warp, warp_uv, 0.0);
	float confidence = field.a * coastal_confidence_value(warp, params.coastal_control.y);
	vec3 warped_long = textureLod(displacement_long, world_uv(warp.xy, params.domains.x), 0.0).xyz;
	long_displacement = mix(long_displacement, warped_long, confidence);
	long_displacement.y *= mix(1.0, field.g, confidence);
	return long_displacement;
}

void main() {
	vec3 scaled_vertex = vertex_position;
	scaled_vertex.xz *= params.ocean_space.x;
	scaled_vertex.y *= params.ocean_space.y;
	vec3 world = (draw_params.model * vec4(scaled_vertex, 1.0)).xyz;
	float distance_m = distance(world.xz, params.camera_sea.xz);
	vec3 authored_displacement = authored_long_at(world.xz)
		* fade_weight(distance_m, params.long_fade.xy);
	authored_displacement += texture(displacement_mid, world_uv(world.xz, params.domains.y)).xyz
		* fade_weight(distance_m, params.mid_fade.xy);
	authored_displacement += texture(displacement_short, world_uv(world.xz, params.domains.z)).xyz
		* fade_weight(distance_m, params.short_fade.xy);
	vec3 displacement = ocean_space_displacement(authored_displacement);
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
