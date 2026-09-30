#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D coastal_field;
layout(set = 0, binding = 1) uniform sampler2D coastal_warp;
layout(set = 0, binding = 2, std430) readonly buffer ProbeCoordinates { vec4 coordinates[]; };
layout(set = 0, binding = 3, std430) writeonly buffer ProbeResults { vec4 values[]; };
layout(push_constant, std430) uniform ProbeParameters { uvec4 counts; } probe;

const uint VECS_PER_SAMPLE = 22u;

void sample_details(sampler2D source, vec2 uv, bool alternate, out vec4 hardware,
		out vec4 meta0, out vec4 meta1, out vec4 weights,
		out vec4 t00, out vec4 t10, out vec4 t01, out vec4 t11, out vec4 manual_value) {
	ivec2 dims = textureSize(source, 0);
	hardware = texture(source, uv);
	vec2 texel = alternate ? uv * vec2(dims - ivec2(1)) : uv * vec2(dims) - vec2(0.5);
	texel = clamp(texel, vec2(0.0), vec2(dims - ivec2(1)));
	ivec2 lo = ivec2(floor(texel));
	ivec2 hi = min(lo + ivec2(1), dims - ivec2(1));
	vec2 f = texel - vec2(lo);
	t00 = texelFetch(source, ivec2(lo.x, lo.y), 0);
	t10 = texelFetch(source, ivec2(hi.x, lo.y), 0);
	t01 = texelFetch(source, ivec2(lo.x, hi.y), 0);
	t11 = texelFetch(source, ivec2(hi.x, hi.y), 0);
	manual_value = mix(mix(t00, t10, f.x), mix(t01, t11, f.x), f.y);
	meta0 = vec4(uv, texel);
	meta1 = vec4(lo, hi);
	weights = vec4(f, 0.0, 0.0);
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= probe.counts.x) { return; }
	vec4 uv = coordinates[i];
	uint b = i * VECS_PER_SAMPLE;
	vec4 h, m0, m1, w, t00, t10, t01, t11, manual_value;
	sample_details(coastal_field, uv.xy, false, h, m0, m1, w, t00, t10, t01, t11, manual_value);
	values[b + 0u] = h; values[b + 1u] = m0; values[b + 2u] = m1; values[b + 3u] = w;
	values[b + 4u] = t00; values[b + 5u] = t10; values[b + 6u] = t01; values[b + 7u] = t11;
	values[b + 8u] = manual_value;
	sample_details(coastal_warp, uv.zw, false, h, m0, m1, w, t00, t10, t01, t11, manual_value);
	values[b + 9u] = h; values[b + 10u] = m0; values[b + 11u] = m1; values[b + 12u] = w;
	values[b + 13u] = t00; values[b + 14u] = t10; values[b + 15u] = t01; values[b + 16u] = t11;
	values[b + 17u] = manual_value;
	sample_details(coastal_field, uv.xy, true, h, m0, m1, w, t00, t10, t01, t11, manual_value);
	values[b + 18u] = manual_value;
	sample_details(coastal_warp, uv.zw, true, h, m0, m1, w, t00, t10, t01, t11, manual_value);
	values[b + 19u] = manual_value;
	ivec2 dims = textureSize(coastal_warp, 0);
	vec2 texel = clamp(uv.zw * vec2(dims) - vec2(0.5), vec2(0.0), vec2(dims - ivec2(1)));
	ivec2 lo = ivec2(floor(texel));
	ivec2 hi = min(lo + ivec2(1), dims - ivec2(1));
	vec2 f = texel - vec2(lo);
	vec4 c00 = texelFetch(coastal_warp, ivec2(lo.x, lo.y), 0);
	vec4 c10 = texelFetch(coastal_warp, ivec2(hi.x, lo.y), 0);
	vec4 c01 = texelFetch(coastal_warp, ivec2(lo.x, hi.y), 0);
	vec4 c11 = texelFetch(coastal_warp, ivec2(hi.x, hi.y), 0);
	vec2 f_round = floor(f * 256.0 + vec2(0.5)) / 256.0;
	vec2 f_trunc = floor(f * 256.0) / 256.0;
	values[b + 20u] = mix(mix(c00, c10, f_round.x), mix(c01, c11, f_round.x), f_round.y);
	values[b + 21u] = mix(mix(c00, c10, f_trunc.x), mix(c01, c11, f_trunc.x), f_trunc.y);
}
