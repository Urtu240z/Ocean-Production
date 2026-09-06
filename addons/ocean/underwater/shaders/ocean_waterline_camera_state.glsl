#[compute]
#version 450

// One invocation samples the same open-ocean displacement fields used by the
// visible clipmap. It never crosses the CPU/GPU boundary.
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D displacement_long;
layout(set = 0, binding = 1) uniform sampler2D displacement_mid;
layout(set = 0, binding = 2) uniform sampler2D displacement_short;
layout(set = 0, binding = 3, std140) uniform CameraStateParams {
	vec4 camera_sea;
	vec4 domains;
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
} params;
layout(set = 0, binding = 4, std430) buffer CameraWaterState {
	vec4 value; // signed height, surface height, valid, reserved
} camera_state;

bool finite_value(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_vec3(vec3 value) {
	return finite_value(value.x) && finite_value(value.y) && finite_value(value.z);
}

float fade_weight(float distance_m, vec2 range_m) {
	return 1.0 - smoothstep(range_m.x, range_m.y, distance_m);
}

vec3 displacement_at(vec2 q) {
	float distance_m = distance(q, params.camera_sea.xz);
	vec3 displacement = textureLod(displacement_long, q / max(params.domains.x, 0.001) + vec2(0.5), 0.0).xyz * fade_weight(distance_m, params.long_fade.xy);
	displacement += textureLod(displacement_mid, q / max(params.domains.y, 0.001) + vec2(0.5), 0.0).xyz * fade_weight(distance_m, params.mid_fade.xy);
	displacement += textureLod(displacement_short, q / max(params.domains.z, 0.001) + vec2(0.5), 0.0).xyz * fade_weight(distance_m, params.short_fade.xy);
	return displacement;
}

void main() {
	vec2 q = params.camera_sea.xz;
	if (!finite_value(params.camera_sea.y) || !finite_value(params.camera_sea.w) || !finite_value(q.x) || !finite_value(q.y)) {
		camera_state.value = vec4(0.0);
		return;
	}
	// Fixed-point inverse horizontal chop: P(q).xz == camera.xz.
	for (int iteration = 0; iteration < 4; ++iteration) {
		vec3 displacement = displacement_at(q);
		if (!finite_vec3(displacement)) {
			camera_state.value = vec4(0.0);
			return;
		}
		q = params.camera_sea.xz - displacement.xz;
		if (!finite_value(q.x) || !finite_value(q.y)) {
			camera_state.value = vec4(0.0);
			return;
		}
	}
	vec3 final_displacement = displacement_at(q);
	float surface_y = params.camera_sea.w + final_displacement.y;
	float signed_height = params.camera_sea.y - surface_y;
	if (!finite_vec3(final_displacement) || !finite_value(surface_y) || !finite_value(signed_height)) {
		camera_state.value = vec4(0.0);
		return;
	}
	camera_state.value = vec4(signed_height, surface_y, 1.0, 0.0);
}
