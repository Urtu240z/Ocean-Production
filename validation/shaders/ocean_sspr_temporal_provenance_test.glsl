#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) readonly buffer ProvenanceInput { float values[]; };
layout(set = 0, binding = 1, std430) buffer ProvenanceResult { uint accepted[]; };

const float TEMPORAL_GEOMETRIC_ALPHA_MIN = 0.99;
const float REPROJECTION_EPSILON = 0.000001;

void main() {
	float current_alpha = values[0];
	float current_depth = values[1];
	float history_alpha = values[2];
	float history_depth = values[3];
	float expected_previous_depth = values[4];
	bool current_valid = current_alpha > 0.001 && current_depth > REPROJECTION_EPSILON;
	bool current_temporal_geometric = current_alpha >= TEMPORAL_GEOMETRIC_ALPHA_MIN && current_depth > REPROJECTION_EPSILON;
	bool history_temporal_geometric = history_alpha >= TEMPORAL_GEOMETRIC_ALPHA_MIN;
	float confidence = history_temporal_geometric ? 1.0 - smoothstep(0.05, 0.1, abs(expected_previous_depth - history_depth)) : 0.0;
	accepted[0] = current_valid && current_temporal_geometric && history_temporal_geometric && history_depth > REPROJECTION_EPSILON && confidence > 0.0 ? 1u : 0u;
}
