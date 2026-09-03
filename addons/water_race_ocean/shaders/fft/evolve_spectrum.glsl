#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba32f, set = 0, binding = 0) uniform restrict readonly image2D h0_current_texture;
layout(rgba32f, set = 0, binding = 1) uniform restrict readonly image2D h0_target_texture;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D spectrum_a;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D spectrum_b;
layout(rgba32f, set = 0, binding = 4) uniform restrict writeonly image2D spectrum_c;
layout(push_constant, std430) uniform Params { vec4 values; float transition_alpha; } params;
vec2 multiply_complex(vec2 a, vec2 b) { return vec2(a.x*b.x-a.y*b.y, a.x*b.y+a.y*b.x); }
void main() {
	ivec2 coord = ivec2(gl_GlobalInvocationID.xy); ivec2 size = imageSize(h0_current_texture);
	if (any(greaterThanEqual(coord, size))) return;
	vec2 k = vec2(coord - size / 2) * (6.283185307179586 / params.values.w);
	float length_k = length(k); vec4 h0 = mix(imageLoad(h0_current_texture, coord), imageLoad(h0_target_texture, coord), clamp(params.transition_alpha, 0.0, 1.0));
	float phase = -sqrt(params.values.y * length_k) * params.values.x;
	vec2 positive = vec2(cos(phase), sin(phase)); vec2 negative = vec2(positive.x, -positive.y);
	vec2 height = multiply_complex(h0.xy, positive) + multiply_complex(h0.zw, negative);
	vec2 dx = vec2(0.0), dz = vec2(0.0), dhx_dx = vec2(0.0), dhz_dz = vec2(0.0), dhz_dx = vec2(0.0);
	if (length_k > 0.000001) { vec2 minus_i_h = vec2(height.y, -height.x); dx = minus_i_h * (k.x / length_k) * -params.values.z; dz = minus_i_h * (k.y / length_k) * -params.values.z; dhx_dx = vec2(-dx.y, dx.x) * k.x; dhz_dz = vec2(-dz.y, dz.x) * k.y; dhz_dx = vec2(-dz.y, dz.x) * k.x; }
	imageStore(spectrum_a, coord, vec4(height, dx)); imageStore(spectrum_b, coord, vec4(dz, dhx_dx)); imageStore(spectrum_c, coord, vec4(dhz_dz, dhz_dx));
}
