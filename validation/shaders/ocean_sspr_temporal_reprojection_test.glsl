#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) readonly buffer ReprojectionInput { float input_values[]; };
layout(set = 0, binding = 1, std430) buffer ReprojectionResult { vec4 result[]; };

const float REPROJECTION_EPSILON = 0.000001;

bool reproject_previous(mat4 current_inverse_view_projection, mat4 previous_view_projection, vec2 current_uv, float current_depth_value, out vec3 current_world_position, out vec2 previous_uv, out float expected_previous_depth) {
	current_world_position = vec3(0.0);
	previous_uv = vec2(0.0);
	expected_previous_depth = 0.0;
	if (isnan(current_depth_value) || isinf(current_depth_value) || current_depth_value < 0.0 || current_depth_value > 1.0) return false;
	vec2 ndc_xy = current_uv * 2.0 - 1.0;
	vec4 current_world = current_inverse_view_projection * vec4(ndc_xy, current_depth_value, 1.0);
	if (abs(current_world.w) <= REPROJECTION_EPSILON || any(isnan(current_world)) || any(isinf(current_world))) return false;
	current_world /= current_world.w;
	if (any(isnan(current_world)) || any(isinf(current_world))) return false;
	current_world_position = current_world.xyz;
	vec4 previous_clip = previous_view_projection * vec4(current_world_position, 1.0);
	if (previous_clip.w <= REPROJECTION_EPSILON || any(isnan(previous_clip)) || any(isinf(previous_clip))) return false;
	vec3 previous_ndc = previous_clip.xyz / previous_clip.w;
	if (any(isnan(previous_ndc)) || any(isinf(previous_ndc))) return false;
	previous_uv = previous_ndc.xy * 0.5 + 0.5;
	expected_previous_depth = previous_ndc.z;
	return all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0))) && expected_previous_depth >= 0.0 && expected_previous_depth <= 1.0;
}

void main() {
	mat4 current_inverse_view_projection = mat4(
		vec4(input_values[0], input_values[1], input_values[2], input_values[3]),
		vec4(input_values[4], input_values[5], input_values[6], input_values[7]),
		vec4(input_values[8], input_values[9], input_values[10], input_values[11]),
		vec4(input_values[12], input_values[13], input_values[14], input_values[15])
	);
	mat4 previous_view_projection = mat4(
		vec4(input_values[16], input_values[17], input_values[18], input_values[19]),
		vec4(input_values[20], input_values[21], input_values[22], input_values[23]),
		vec4(input_values[24], input_values[25], input_values[26], input_values[27]),
		vec4(input_values[28], input_values[29], input_values[30], input_values[31])
	);
	vec3 world_position;
	vec2 previous_uv;
	float expected_previous_depth;
	bool valid = reproject_previous(current_inverse_view_projection, previous_view_projection, vec2(input_values[32], input_values[33]), input_values[34], world_position, previous_uv, expected_previous_depth);
	result[0] = vec4(world_position, 1.0);
	result[1] = vec4(previous_uv, expected_previous_depth, valid ? 1.0 : 0.0);
}
