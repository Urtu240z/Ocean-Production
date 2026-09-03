#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D displacement_map;
layout(set = 0, binding = 1) uniform sampler2D previous_displacement_map;
layout(set = 0, binding = 2) uniform sampler2D foam_previous;
layout(rg16f, set = 0, binding = 3) uniform restrict writeonly image2D foam_next;

const float RESIDUAL_DECAY_BASE_MULTIPLIER = 1.15;
const float FRESH_RELEASE_BASE_MULTIPLIER = 2.0;

layout(push_constant, std430) uniform Params {
	vec4 fresh; // whitecap, attack rate/s, cascade weight, deposit strength
	vec4 transport; // residual decay rate/s, dt, advection enabled, strength
	vec4 domain; // domain metres; remaining fields are reserved for transitions
} params;

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(foam_next);
	if (any(greaterThanEqual(coord, size))) return;

	vec2 uv = (vec2(coord) + vec2(0.5)) / vec2(size);
	vec4 displacement = textureLod(displacement_map, uv, 0.0);
	float jacobian = (isnan(displacement.a) || isinf(displacement.a)) ? 1.0 : displacement.a;
	float delta_s = max(params.transport.y, 0.0);
	vec2 previous_displacement = textureLod(previous_displacement_map, uv, 0.0).rg;
	vec2 velocity = delta_s > 0.00001 ? (displacement.xz - previous_displacement) / delta_s : vec2(0.0);
	vec2 backtrace_uv = uv - velocity * delta_s * params.transport.z * params.transport.w / max(params.domain.x, 0.001);
	vec2 previous = textureLod(foam_previous, backtrace_uv, 0.0).rg;
	if (any(isnan(previous)) || any(isinf(previous))) previous = vec2(0.0);

	float source = max(0.0, params.fresh.x - jacobian);
	float fresh_target = clamp(source * max(params.fresh.z, 0.0), 0.0, 1.0);
	float decay_rate = max(params.transport.x, 0.0);
	float fresh_release_rate = decay_rate * FRESH_RELEASE_BASE_MULTIPLIER / RESIDUAL_DECAY_BASE_MULTIPLIER;
	float fresh_rate = fresh_target > previous.g ? max(params.fresh.y, 0.0) : fresh_release_rate;
	float fresh = mix(previous.g, fresh_target, 1.0 - exp(-fresh_rate * delta_s));
	float residual = previous.r * exp(-decay_rate * delta_s);
	residual = max(residual, fresh * max(params.fresh.w, 0.0));
	imageStore(foam_next, coord, vec4(clamp(residual, 0.0, 1.0), clamp(fresh, 0.0, 1.0), 0.0, 1.0));
}
