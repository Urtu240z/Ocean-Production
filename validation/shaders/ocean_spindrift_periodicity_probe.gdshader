shader_type canvas_item;

// Same-frame spatial invariant probe. It reads the live LONG displacement
// texture at p and at p + period and reports the absolute delta, so the test
// never compares two different simulation times.
uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform vec2 origin_xz = vec2(0.0);
uniform float period_m = 2560.0;
uniform float domain_long_m = 512.0;
uniform float sample_span_m = 55.0;

void fragment() {
	vec2 centered = UV * 2.0 - vec2(1.0);
	vec2 world_xz = origin_xz + centered * sample_span_m;
	vec2 uv_a = world_xz / max(domain_long_m, 0.001) + vec2(0.5);
	vec2 uv_b = (world_xz + vec2(period_m, 0.0)) / max(domain_long_m, 0.001) + vec2(0.5);
	vec3 a = texture(displacement_long, uv_a).xyz;
	vec3 b = texture(displacement_long, uv_b).xyz;
	float delta = length(a - b);
	// r = absolute delta, g = raw signed height at the origin sample.
	COLOR = vec4(delta, clamp(a.y * 0.5 + 0.5, 0.0, 1.0), 0.0, 1.0);
}
