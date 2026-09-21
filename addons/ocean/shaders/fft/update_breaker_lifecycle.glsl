#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// LONG crest foam G is the fresh ignition signal. R is the residual/history
// foam extent used to keep propagation attached to the same crest.
layout(set = 0, binding = 0) uniform sampler2D crest_activity;
layout(set = 0, binding = 1) uniform sampler2D displacement_long;
layout(set = 0, binding = 2) uniform sampler2D lifecycle_previous;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D lifecycle_next;
// Validation-only event acquisition record. values[0] is an atomic claim;
// values[1..3] store quantized UV x/y and seed strength.
layout(std430, set = 0, binding = 4) buffer BreakerEventProbe {
	uint values[8];
} event_probe;

layout(push_constant, std430) uniform Params {
	vec4 domain_step; // domain metres, fixed dt, elapsed fixed time, legacy spacing
	vec4 dynamics; // lateral speed m/s, event duration s, history decay s, refractory s
	vec4 candidate; // fresh foam threshold, continuity metres, reserved, history drift m/s
	vec4 direction; // dominant LONG propagation xz, remaining reserved
	vec4 compression; // event energy scale, remaining reserved
} params;

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
	return normalize(mix(reference, tangent, smoothstep(0.02, 0.15, length(gradient))));
}

vec2 sample_foam(vec2 uv) {
	vec2 foam = textureLod(crest_activity, uv, 0.0).rg;
	if (any(isnan(foam)) || any(isinf(foam))) return vec2(0.0);
	return clamp(foam, 0.0, 1.0);
}

float lifecycle_support(vec4 state) {
	return max(max(state.r, state.a), state.g);
}

void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(lifecycle_next);
	if (any(greaterThanEqual(coord, size))) return;
	vec2 texel = 1.0 / vec2(size);
	vec2 uv = (vec2(coord) + 0.5) * texel;
	float dt = max(params.domain_step.y, 0.0);
	float domain_m = max(params.domain_step.x, 0.001);
	vec2 tangent = crest_tangent(uv, texel);
	vec2 lateral_step = tangent * params.dynamics.x * dt / domain_m;
	vec2 upstream_uv = uv - lateral_step;
	vec2 downstream_uv = uv + lateral_step;
	vec4 previous = textureLod(lifecycle_previous, uv, 0.0);
	vec4 upstream = textureLod(lifecycle_previous, upstream_uv, 0.0);
	vec4 downstream = textureLod(lifecycle_previous, downstream_uv, 0.0);
	vec2 foam_here = sample_foam(uv);
	vec2 foam_upstream = sample_foam(upstream_uv);
	vec2 foam_downstream = sample_foam(downstream_uv);
	float fresh_foam = foam_here.g;
	float foam_history = foam_here.r;
	float threshold = clamp(params.candidate.x, 0.0, 1.0);
	float continuity_uv = max(params.candidate.y, 0.0) / domain_m;
	vec2 continuity_offset = tangent * continuity_uv;
	vec2 foam_continuity_a = sample_foam(uv - continuity_offset);
	vec2 foam_continuity_b = sample_foam(uv + continuity_offset);
	float foam_extent = max(max(fresh_foam, foam_history), max(max(foam_upstream.g, foam_upstream.r), max(max(foam_downstream.g, foam_downstream.r), max(max(foam_continuity_a.g, foam_continuity_a.r), max(foam_continuity_b.g, foam_continuity_b.r)))));
	float foam_support = smoothstep(threshold * 0.25, max(threshold, 0.001), foam_extent);
	// Seed topology uses a fixed 1.5-texel probe. Propagation below continues
	// to use physical speed * dt and is intentionally a separate distance.
	vec2 tangent_texel_direction = normalize(tangent / texel);
	vec2 seed_probe_offset = tangent_texel_direction * texel * 1.5;
	float foam_previous_along_tangent = sample_foam(uv - seed_probe_offset).g;
	bool threshold_edge = fresh_foam >= threshold && foam_previous_along_tangent < threshold;
	vec4 lifecycle_continuity_a = textureLod(lifecycle_previous, uv - continuity_offset, 0.0);
	vec4 lifecycle_continuity_b = textureLod(lifecycle_previous, uv + continuity_offset, 0.0);
	float nearby_event_support = max(lifecycle_support(previous), max(lifecycle_support(upstream), max(lifecycle_support(downstream), max(lifecycle_support(lifecycle_continuity_a), lifecycle_support(lifecycle_continuity_b)))));
	// A nearby active or recent event owns this coherent foam segment. This
	// suppresses redundant seeds while allowing a new segment to ignite.
	bool duplicate_event = nearby_event_support > 0.05;
	bool previous_active = previous.a > 0.01 && previous.b < 0.999;
	float seed = (!duplicate_event && !previous_active && threshold_edge) ? fresh_foam : 0.0;
	if (seed > 0.0 && atomicCompSwap(event_probe.values[0], 0u, 1u) == 0u) {
		event_probe.values[1] = uint(clamp(uv.x, 0.0, 1.0) * 1000000.0);
		event_probe.values[2] = uint(clamp(uv.y, 0.0, 1.0) * 1000000.0);
		event_probe.values[3] = uint(clamp(seed, 0.0, 1.0) * 1000000.0);
		event_probe.values[4] = floatBitsToUint(params.domain_step.z);
	}
	float decay = exp(-dt / max(params.dynamics.y, 0.001));
	float history_decay = exp(-dt / max(params.dynamics.z, 0.001));
	float incoming_front = max(upstream.r, downstream.r) * foam_support;
	float incoming_energy = max(upstream.a, downstream.a) * foam_support;
	float seeded_energy = seed * max(params.compression.x, 0.0);
	float local_front = previous_active ? previous.r * decay : 0.0;
	float local_energy = previous_active ? previous.a * decay : 0.0;
	float front_activity = max(local_front, max(incoming_front, seed));
	bool entering = !previous_active && (seed > 0.0 || incoming_front > 0.01);
	float age = entering ? 0.0 : (previous_active ? min(previous.b + dt / max(params.dynamics.y, 0.001), 1.0) : 1.0);
	bool event_active = (entering || previous_active) && age < 0.999;
	float energy = max(local_energy, max(incoming_energy * decay, seeded_energy));
	if (!event_active) {
		front_activity = 0.0;
		energy = 0.0;
	}
	// G remains lifecycle history for whitewater/rearm. It is not used to
	// multiply the VDM after spawn, and it does not veto an active event.
	float history = textureLod(lifecycle_previous,
		uv - normalize(params.direction.xy) * params.candidate.w * dt / domain_m, 0.0).g;
	history = max(history * history_decay, front_activity);
	imageStore(lifecycle_next, coord, vec4(clamp(front_activity, 0.0, 1.0), clamp(history, 0.0, 1.0), age, clamp(energy, 0.0, 1.0)));
}
