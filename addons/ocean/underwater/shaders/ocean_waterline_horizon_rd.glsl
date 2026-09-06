#[vertex]
#version 450

vec2 positions[3] = vec2[](vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
void main() {
	gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
}

#[fragment]
#version 450

layout(set = 0, binding = 0, std140) uniform HorizonParams {
	mat4 view_projection;
	mat4 inverse_view_projection;
	vec4 camera_sea;
	vec4 domains;
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
} params;
layout(location = 0) out vec2 waterline_mask;
layout(location = 1) out float ocean_depth;

void main() {
	// The auxiliary horizon only supplies a coarse side outside clipmap coverage.
	// It never invents an ocean exit depth; actual geometry overwrites it later.
	waterline_mask = vec2(params.camera_sea.y > params.camera_sea.w ? 1.0 : 0.0, 1.0);
	ocean_depth = 0.0;
}
