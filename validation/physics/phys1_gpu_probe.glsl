#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform readonly image2D long_displacement;
layout(set = 0, binding = 1, std430) readonly buffer SampleCoordinates {
	ivec2 texels[];
};
layout(set = 0, binding = 2, std430) writeonly buffer ProbeResults {
	vec4 values[];
};
layout(push_constant, std430) uniform ProbeParameters {
	uvec4 counts;
} params;

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= params.counts.x) {
		return;
	}
	values[index] = imageLoad(long_displacement, texels[index]);
}
