#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D coastal_field;
layout(set = 0, binding = 1) uniform sampler2D coastal_warp;
layout(set = 0, binding = 2, std430) readonly buffer ProbeCoordinates { vec4 coordinates[]; };
layout(set = 0, binding = 3, std430) writeonly buffer ProbeResults { vec4 values[]; };
layout(push_constant, std430) uniform ProbeParameters { uvec4 counts; } probe;

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= probe.counts.x) { return; }
	vec4 uv = coordinates[i]; // field.xy, warp.zw
	values[i * 2u] = texture(coastal_field, uv.xy);
	values[i * 2u + 1u] = texture(coastal_warp, uv.zw);
}
