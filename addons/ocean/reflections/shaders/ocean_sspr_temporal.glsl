#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set=0,binding=0) uniform sampler2D current_color;
layout(set=0,binding=1) uniform sampler2D current_depth;
layout(set=0,binding=2) uniform sampler2D history_color;
layout(set=0,binding=3) uniform sampler2D history_depth;
layout(set=0,binding=4,rgba16f) uniform image2D reflection_output;
layout(set=0,binding=5,rgba16f) uniform image2D history_color_output;
layout(set=0,binding=6,r16f) uniform image2D history_depth_output;
layout(set=0,binding=7,std140) uniform TemporalParams {
	mat4 current_inverse_view_projection;
	mat4 previous_view_projection;
	vec4 destination_size;
	vec4 temporal_settings;
	vec4 reserved_ocean_level;
} params;

const float REPROJECTION_EPSILON = 0.000001;
const float TEMPORAL_GEOMETRIC_ALPHA_MIN = 0.99;

bool reproject_previous(vec2 current_uv, float current_depth_value, out vec2 previous_uv, out float expected_previous_depth) {
	previous_uv = vec2(0.0);
	expected_previous_depth = 0.0;
	if (isnan(current_depth_value) || isinf(current_depth_value) || current_depth_value < 0.0 || current_depth_value > 1.0) return false;
	vec2 ndc_xy = current_uv * 2.0 - 1.0;
	vec4 current_world = params.current_inverse_view_projection * vec4(ndc_xy, current_depth_value, 1.0);
	if (abs(current_world.w) <= REPROJECTION_EPSILON || any(isnan(current_world)) || any(isinf(current_world))) return false;
	current_world /= current_world.w;
	if (any(isnan(current_world)) || any(isinf(current_world))) return false;
	vec4 previous_clip = params.previous_view_projection * vec4(current_world.xyz, 1.0);
	if (previous_clip.w <= REPROJECTION_EPSILON || any(isnan(previous_clip)) || any(isinf(previous_clip))) return false;
	vec3 previous_ndc = previous_clip.xyz / previous_clip.w;
	if (any(isnan(previous_ndc)) || any(isinf(previous_ndc))) return false;
	previous_uv = previous_ndc.xy * 0.5 + 0.5;
	expected_previous_depth = previous_ndc.z;
	return all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0))) && expected_previous_depth >= 0.0 && expected_previous_depth <= 1.0;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 extent = ivec2(params.destination_size.xy);
	if (any(greaterThanEqual(pixel, extent))) return;
	vec4 current = texelFetch(current_color, pixel, 0);
	float current_depth_value = texelFetch(current_depth, pixel, 0).r;
	bool current_valid = current.a > 0.001 && current_depth_value > REPROJECTION_EPSILON;
	bool current_temporal_geometric = current.a >= TEMPORAL_GEOMETRIC_ALPHA_MIN && current_depth_value > REPROJECTION_EPSILON;
	vec4 result = current;
	vec2 current_uv = (vec2(pixel) + 0.5) / params.destination_size.xy;
	vec2 old_uv;
	float expected_previous_depth;
	bool reprojection_valid = false;
	if (current_temporal_geometric) {
		reprojection_valid = reproject_previous(current_uv, current_depth_value, old_uv, expected_previous_depth);
	}
	if (params.temporal_settings.x > 0.5 && params.temporal_settings.w > 0.5 && current_temporal_geometric && reprojection_valid) {
		vec4 history = texture(history_color, old_uv);
		bool history_temporal_geometric = history.a >= TEMPORAL_GEOMETRIC_ALPHA_MIN;
		if (history_temporal_geometric) {
			float old_depth = texture(history_depth, old_uv).r;
			float confidence = 1.0 - smoothstep(params.temporal_settings.z, params.temporal_settings.z * 2.0, abs(expected_previous_depth - old_depth));
			if (old_depth > REPROJECTION_EPSILON && confidence > 0.0) {
				float weight = clamp(params.temporal_settings.y * confidence * min(current.a, history.a), 0.0, 1.0);
				result.rgb = mix(current.rgb, history.rgb, weight);
			}
		}
	}
	if (!current_valid) result = vec4(0.0);
	imageStore(reflection_output, pixel, result);
	imageStore(history_color_output, pixel, result);
	imageStore(history_depth_output, pixel, vec4(current_valid ? current_depth_value : 0.0));
}
