shader_type canvas_item;
render_mode unshaded, blend_disabled;

uniform sampler2D reflection_source : filter_linear, repeat_disable;
uniform vec2 texel_size = vec2(1.0);
uniform float radius = 1.0;
uniform bool source_premultiplied = false;
uniform bool final_pass = false;

vec4 premultiply(vec4 value) {
	return vec4(value.rgb * value.a, value.a);
}

vec4 sample_radiance(vec2 uv) {
	if (source_premultiplied) {
		return textureLod(reflection_source, uv, 0.0);
	}
	// First convert confidence to premultiplied radiance BEFORE interpolation.
	// Bilinear interpolation of straight RGB would darken SSPR hole boundaries.
	ivec2 size = textureSize(reflection_source, 0);
	vec2 pixel = clamp(uv * vec2(size) - vec2(0.5), vec2(0.0), vec2(size - 1));
	ivec2 base = ivec2(floor(pixel));
	vec2 weight = fract(pixel);
	vec4 a = premultiply(texelFetch(reflection_source, base, 0));
	vec4 b = premultiply(texelFetch(reflection_source, min(base + ivec2(1, 0), size - 1), 0));
	vec4 c = premultiply(texelFetch(reflection_source, min(base + ivec2(0, 1), size - 1), 0));
	vec4 d = premultiply(texelFetch(reflection_source, min(base + ivec2(1, 1), size - 1), 0));
	return mix(mix(a, b, weight.x), mix(c, d, weight.x), weight.y);
}

void fragment() {
	vec2 offset = texel_size * radius;
	vec4 a = sample_radiance(UV + vec2(-offset.x, -offset.y));
	vec4 b = sample_radiance(UV + vec2( offset.x, -offset.y));
	vec4 c = sample_radiance(UV + vec2(-offset.x,  offset.y));
	vec4 d = sample_radiance(UV + vec2( offset.x,  offset.y));
	// SSPR alpha is confidence. Filter premultiplied radiance, then unpremultiply
	// so missing samples do not introduce black fringes or false confidence.
	vec4 result = (a + b + c + d) * 0.25;
	COLOR = final_pass ? vec4(result.a > 0.00001 ? result.rgb / result.a : vec3(0.0), result.a) : result;
}
