#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) readonly buffer InputDepthBuffer { float input_depth[]; };
layout(set = 0, binding = 1, std430) readonly buffer InputSourceBuffer { uint input_source[]; };
layout(set = 0, binding = 2, std430) buffer CandidateDepthBuffer { uint candidate_depth[]; };
layout(set = 0, binding = 3, std430) buffer CandidateSourceBuffer { uint candidate_source[]; };
layout(push_constant, std430) uniform TestParams { uint mode; uint count; } params;
const uint INVALID_DEPTH = 0xffffffffu;

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= params.count) return;
	float depth = input_depth[index];
	if (!(depth > 0.0) || isnan(depth) || isinf(depth)) return;
	uint depth_key = floatBitsToUint(depth);
	if (depth_key == INVALID_DEPTH) return;
	if (params.mode == 0u) {
		atomicMin(candidate_depth[0], depth_key);
	} else if (params.mode == 1u && candidate_depth[0] == depth_key) {
		atomicMin(candidate_source[0], input_source[index]);
	}
}
