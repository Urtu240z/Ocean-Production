#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D scene_depth;
layout(set = 0, binding = 1, std430) readonly buffer CandidateDepthBuffer { uint candidate_depth[]; };
layout(set = 0, binding = 2, std430) buffer CandidateSourceBuffer { uint candidate_source[]; };
layout(set = 0, binding = 3, std140) uniform Params {
	mat4 inverse_projection;
	mat4 inverse_view;
	mat4 view_projection;
	vec4 source_size;
	vec4 destination_size;
	vec4 ocean_level;
} params;
const float LINEAR_DEPTH_EPSILON = 0.0001;
const uint INVALID_DEPTH = 0xffffffffu;

// SHARED_PROJECT_CANDIDATE_BEGIN
bool project_candidate(ivec2 source_pixel, out uint destination_index, out uint depth_key, out uint source_payload) {
	ivec2 source_extent = ivec2(params.source_size.xy);
	if (any(lessThan(source_pixel, ivec2(0))) || any(greaterThanEqual(source_pixel, source_extent))) return false;
	float raw_depth = texelFetch(scene_depth, source_pixel, 0).r;
	if (!(raw_depth > 0.000001) || raw_depth > 1.000001) return false;
	vec2 uv = (vec2(source_pixel) + 0.5) / params.source_size.xy;
	vec4 view_position = params.inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(view_position.w) <= 0.000001) return false;
	view_position /= view_position.w;
	vec4 world_position = params.inverse_view * vec4(view_position.xyz, 1.0);
	if (abs(world_position.w) <= 0.000001) return false;
	world_position /= world_position.w;
	if (any(isnan(world_position.xyz)) || any(isinf(world_position.xyz)) || world_position.y <= params.ocean_level.x) return false;
	world_position.y = 2.0 * params.ocean_level.x - world_position.y;
	vec3 reflected_world_position = world_position.xyz;
	vec3 camera_position = params.inverse_view[3].xyz;
	vec3 camera_forward = -normalize(params.inverse_view[2].xyz);
	if (any(isnan(camera_position)) || any(isinf(camera_position)) || any(isnan(camera_forward)) || any(isinf(camera_forward))) return false;
	float linear_depth = dot(reflected_world_position - camera_position, camera_forward);
	if (!(linear_depth > LINEAR_DEPTH_EPSILON) || isnan(linear_depth) || isinf(linear_depth)) return false;
	uint candidate_depth_key = floatBitsToUint(linear_depth);
	if (candidate_depth_key == INVALID_DEPTH) return false;
	vec4 destination_clip = params.view_projection * vec4(world_position.xyz, 1.0);
	if (!(destination_clip.w > 0.000001) || any(isnan(destination_clip)) || any(isinf(destination_clip))) return false;
	vec3 ndc = destination_clip.xyz / destination_clip.w;
	if (any(isnan(ndc)) || any(isinf(ndc)) || ndc.x < -1.0 || ndc.x > 1.0 || ndc.y < -1.0 || ndc.y > 1.0 || ndc.z < 0.0 || ndc.z > 1.0) return false;
	ivec2 destination_pixel = ivec2((ndc.xy * 0.5 + 0.5) * params.destination_size.xy);
	ivec2 destination_extent = ivec2(params.destination_size.xy);
	if (any(lessThan(destination_pixel, ivec2(0))) || any(greaterThanEqual(destination_pixel, destination_extent))) return false;
	destination_index = uint(destination_pixel.y * destination_extent.x + destination_pixel.x);
	depth_key = candidate_depth_key;
	source_payload = ((uint(source_pixel.y) << 16u) | uint(source_pixel.x)) + 1u;
	return true;
}
// SHARED_PROJECT_CANDIDATE_END

void main() {
	ivec2 source_pixel = ivec2(gl_GlobalInvocationID.xy);
	uint destination_index;
	uint depth_key;
	uint source_payload;
	if (!project_candidate(source_pixel, destination_index, depth_key, source_payload)) return;
	if (candidate_depth[destination_index] == depth_key) {
		atomicMin(candidate_source[destination_index], source_payload);
	}
}
