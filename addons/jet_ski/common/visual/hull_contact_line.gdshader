shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never;

uniform sampler2D breakup_texture : repeat_enable, filter_linear;
uniform float activity = 0.0;
uniform vec3 scene_light_tint = vec3(1.0);
varying vec2 contact_world_xz;

void vertex() {
	contact_world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	// Static world coordinates: the hull crosses the pattern; it does not scroll.
	float coarse = texture(breakup_texture, contact_world_xz * 0.73).r;
	float fine = texture(breakup_texture, contact_world_xz * 5.7 + vec2(coarse * 0.3)).r;
	float edge = 1.0 - smoothstep(0.12, 0.50, abs(UV.y - 0.5));
	float broken = smoothstep(0.40, 0.65, coarse + fine * 0.22);
	float bubbles = smoothstep(0.59, 0.77, fine) * broken;
	float speed = activity;
	float white = bubbles * mix(0.16, 0.52, speed);
	// A restrained wet meniscus and roughness change under the sparse bubbles.
	ALBEDO = mix(vec3(0.035, 0.15, 0.17), vec3(0.77, 0.90, 0.90), white) * scene_light_tint;
	ROUGHNESS = mix(0.17, 0.80, white);
	SPECULAR = mix(0.52, 0.12, white);
	ALPHA = edge * (0.08 * broken + white);
}
