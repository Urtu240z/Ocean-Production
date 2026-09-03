#[compute]
#version 450

// Independent V3 J-only source. It deliberately does not read any main FFT
// cascade: packed diagonals make one complex IFFT sufficient for the Jacobian.
layout(local_size_x = 8, local_size_y = 8) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D h0_texture;
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D packed_payload;
layout(set = 0, binding = 2, std140) uniform Params { vec4 values; } params;

vec2 cmul(vec2 a, vec2 b) { return vec2(a.x*b.x-a.y*b.y, a.x*b.y+a.y*b.x); }
void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy); ivec2 size = imageSize(h0_texture);
	if (any(greaterThanEqual(c, size))) return;
	vec2 k = vec2(c - size / 2) * (6.28318530718 / params.values.w);
	float kl = length(k); vec4 h0 = imageLoad(h0_texture, c);
	float w = sqrt(params.values.y * kl * tanh(kl * params.values.z));
	vec2 phase = vec2(cos(-w * params.values.x), sin(-w * params.values.x));
	vec2 height = cmul(h0.xy, phase) + cmul(h0.zw, vec2(phase.x, -phase.y));
	vec2 dx = vec2(0.0), dz = vec2(0.0), cross = vec2(0.0);
	if (kl > 0.000001) { vec2 u = k / kl; dx = -height * k.y * u.y; dz = -height * k.x * u.x; cross = -height * k.y * u.x; }
	imageStore(packed_payload, c, vec4(dx.x - dz.y, dx.y + dz.x, cross));
}
