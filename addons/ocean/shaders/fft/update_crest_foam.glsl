#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D displacement_map;
layout(set = 0, binding = 1) uniform sampler2D previous_displacement_map;
layout(set = 0, binding = 2) uniform sampler2D foam_previous;
layout(rg16f, set = 0, binding = 3) uniform restrict writeonly image2D foam_next;

const float RESIDUAL_DECAY_BASE_MULTIPLIER = 1.15;
const float FRESH_RELEASE_BASE_MULTIPLIER = 2.0;

void crest_parameters(ivec2 size, out float whitecap, out float fresh_attack_rate,
		out float cascade_weight, out float residual_decay_rate, out float domain_m) {
	if (size.x >= 1024) {
		whitecap = 0.62; fresh_attack_rate = 1.60 * 7.5; cascade_weight = 1.00; domain_m = 512.0;
	} else if (size.x >= 512) {
		whitecap = 0.66; fresh_attack_rate = 0.42 * 7.5; cascade_weight = 0.65; domain_m = 137.0;
	} else {
		whitecap = 0.68; fresh_attack_rate = 0.22 * 7.5; cascade_weight = 0.10; domain_m = 37.0;
	}
	residual_decay_rate = 4.50 * RESIDUAL_DECAY_BASE_MULTIPLIER * 0.2;
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(foam_next);
	if (any(greaterThanEqual(coord, size))) return;

	float whitecap; float fresh_attack_rate; float cascade_weight; float residual_decay_rate; float domain_m;
	crest_parameters(size, whitecap, fresh_attack_rate, cascade_weight, residual_decay_rate, domain_m);
	vec2 uv = (vec2(coord) + vec2(0.5)) / vec2(size);
	vec4 displacement = textureLod(displacement_map, uv, 0.0);
	float jacobian = (isnan(displacement.a) || isinf(displacement.a)) ? 1.0 : displacement.a;
	float delta_s = 1.0 / 30.0;
	vec2 previous_displacement = textureLod(previous_displacement_map, uv, 0.0).rg;
	vec2 velocity = delta_s > 0.00001 ? (displacement.xz - previous_displacement) / delta_s : vec2(0.0);
	vec2 backtrace_uv = uv - velocity * delta_s / max(domain_m, 0.001);
	vec2 previous = textureLod(foam_previous, backtrace_uv, 0.0).rg;
	if (any(isnan(previous)) || any(isinf(previous))) previous = vec2(0.0);

	float source = max(0.0, whitecap - jacobian);
	float fresh_target = clamp(source * cascade_weight, 0.0, 1.0);
	float fresh_release_rate = residual_decay_rate * FRESH_RELEASE_BASE_MULTIPLIER / RESIDUAL_DECAY_BASE_MULTIPLIER;
	float fresh_rate = fresh_target > previous.g ? fresh_attack_rate : fresh_release_rate;
	float fresh = mix(previous.g, fresh_target, 1.0 - exp(-fresh_rate * delta_s));
	float residual = previous.r * exp(-residual_decay_rate * delta_s);
	residual = max(residual, fresh * 0.72);
	imageStore(foam_next, coord, vec4(clamp(residual, 0.0, 1.0), clamp(fresh, 0.0, 1.0), 0.0, 1.0));
}
