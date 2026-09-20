#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// LONG Crest G is the only breaking candidate. The lifecycle never detects a
// second break from its own noise or from the surface material.
layout(set = 0, binding = 0) uniform sampler2D crest_activity;
layout(set = 0, binding = 1) uniform sampler2D displacement_long;
layout(set = 0, binding = 2) uniform sampler2D lifecycle_previous;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D lifecycle_next;

layout(push_constant, std430) uniform Params {
	vec4 domain_step; // domain metres, fixed dt, elapsed fixed time, seed spacing in cells
	vec4 dynamics; // front speed m/s, front lifetime s, history decay s, refractory s
	vec4 candidate; // onset G, release G, seed probability, history drift m/s
	vec4 direction; // dominant LONG propagation xz, remaining reserved
	vec4 compression; // pre-fold start J, unsafe J, remaining reserved
} params;

float hash_cell(ivec3 cell) {
	uvec3 p = uvec3(cell) * uvec3(1664525u, 1013904223u, 747796405u);
	p ^= p.yzx >> 16u;
	p *= uvec3(2246822519u, 3266489917u, 668265263u);
	return float(p.x ^ p.y ^ p.z) / 4294967295.0;
}

vec2 crest_tangent(vec2 uv, vec2 texel) {
	vec2 propagation = normalize(params.direction.xy);
	vec2 reference = vec2(-propagation.y, propagation.x);
	float hx = textureLod(displacement_long, uv + vec2(texel.x * 2.0, 0.0), 0.0).y
		- textureLod(displacement_long, uv - vec2(texel.x * 2.0, 0.0), 0.0).y;
	float hz = textureLod(displacement_long, uv + vec2(0.0, texel.y * 2.0), 0.0).y
		- textureLod(displacement_long, uv - vec2(0.0, texel.y * 2.0), 0.0).y;
	vec2 gradient = vec2(hx, hz);
	if (dot(gradient, gradient) < 0.0001) return reference;
	vec2 tangent = normalize(vec2(-gradient.y, gradient.x));
	if (dot(tangent, reference) < 0.0) tangent = -tangent;
	// Keep a coherent sign when the local slope becomes nearly flat.
	return normalize(mix(reference, tangent, smoothstep(0.02, 0.15, length(gradient))));
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(lifecycle_next);
	if (any(greaterThanEqual(coord, size))) return;
	vec2 texel = 1.0 / vec2(size);
	vec2 uv = (vec2(coord) + 0.5) * texel;
	float dt = params.domain_step.y;
	float domain_m = max(params.domain_step.x, 0.001);
	vec2 tangent = crest_tangent(uv, texel);
	vec2 upstream_uv = uv - tangent * params.dynamics.x * dt / domain_m;
	vec4 previous = textureLod(lifecycle_previous, uv, 0.0);
	vec4 upstream = textureLod(lifecycle_previous, upstream_uv, 0.0);
	float activity = clamp(textureLod(crest_activity, uv, 0.0).g, 0.0, 1.0);
	float fft_j = textureLod(displacement_long, uv, 0.0).a;
	// Onset is a seed threshold. Once seeded, the front can peel across a
	// weaker contiguous crest down to the release threshold.
	float support = smoothstep(params.candidate.y * 0.25, max(params.candidate.y, 0.001), activity);

	int spacing = max(int(params.domain_step.w), 1);
	int epoch = int(floor(params.domain_step.z / 0.45));
	// A coarse hash selects crest patches, while every compressed pixel in a
	// selected patch can start the front. Grid-point-only seeds miss narrow lips.
	bool seed_cell = hash_cell(ivec3(coord / spacing, epoch)) < params.candidate.z;
	float seed = seed_cell && activity >= params.candidate.x
		&& fft_j < params.compression.x && fft_j > params.compression.y
		&& previous.b >= 0.999
		&& previous.g < 0.05 ? activity : 0.0;
	float carried = upstream.r * exp(-dt / max(params.dynamics.y, 0.001));
	float front_activity = clamp(max(seed, carried) * support, 0.0, 1.0);
	float history = textureLod(lifecycle_previous,
		uv - normalize(params.direction.xy) * params.candidate.w * dt / domain_m, 0.0).g;
	history = max(history * exp(-dt / max(params.dynamics.z, 0.001)), front_activity);
	// B is local shape time. G keeps the existing whitewater/rearm exclusion.
	bool front_entry = previous.r <= 0.08 && front_activity > 0.08;
	float age = front_entry ? 0.0 : min(previous.b + dt / 0.80, 1.0);
	float energy = max(previous.a * exp(-dt / max(params.dynamics.y, 0.001)), front_activity * activity);
	imageStore(lifecycle_next, coord, vec4(front_activity, clamp(history, 0.0, 1.0), age, clamp(energy, 0.0, 1.0)));
}
