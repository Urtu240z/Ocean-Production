#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D scene_depth;
layout(set = 0, binding = 1, std430) buffer CandidateBuffer { uint candidates[]; };
layout(set = 0, binding = 2, std140) uniform Params {
	mat4 inverse_projection;
	mat4 inverse_view;
	mat4 view_projection;
	vec4 source_size;
	vec4 destination_size;
	vec4 ocean_level;
} params;

void main() {
	ivec2 source_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 source_extent = ivec2(params.source_size.xy);
	if (any(greaterThanEqual(source_pixel, source_extent))) return;
	float raw_depth = texelFetch(scene_depth, source_pixel, 0).r;
	if (!(raw_depth > 0.000001) || raw_depth > 1.000001) return;
	vec2 uv = (vec2(source_pixel) + 0.5) / params.source_size.xy;
	vec4 view_position = params.inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(view_position.w) <= 0.000001) return;
	view_position /= view_position.w;
	vec4 world_position = params.inverse_view * vec4(view_position.xyz, 1.0);
	if (abs(world_position.w) <= 0.000001) return;
	world_position /= world_position.w;
	if (any(isnan(world_position.xyz)) || any(isinf(world_position.xyz)) || world_position.y <= params.ocean_level.x) return;
	world_position.y = 2.0 * params.ocean_level.x - world_position.y;
	vec4 destination_clip = params.view_projection * vec4(world_position.xyz, 1.0);
	if (!(destination_clip.w > 0.000001) || any(isnan(destination_clip)) || any(isinf(destination_clip))) return;
	vec3 ndc = destination_clip.xyz / destination_clip.w;
	if (ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0) return;
	ivec2 destination_pixel = ivec2((ndc.xy * 0.5 + 0.5) * params.destination_size.xy);
	ivec2 destination_extent = ivec2(params.destination_size.xy);
	if (any(lessThan(destination_pixel, ivec2(0))) || any(greaterThanEqual(destination_pixel, destination_extent))) return;
	uint payload = ((uint(source_pixel.y) << 16u) | uint(source_pixel.x)) + 1u;
	atomicMax(candidates[uint(destination_pixel.y * destination_extent.x + destination_pixel.x)], payload);
}
