shader_type canvas_item;

uniform sampler2D breaking_activity_long : repeat_enable, filter_linear;
uniform vec2 sensor_anchor_xz = vec2(0.0);
uniform float sample_radius_m = 120.0;
uniform float domain_long_m = 512.0;

void fragment() {
	vec2 disk_uv = UV * 2.0 - vec2(1.0);
	float crest_g = 0.0;
	if (length(disk_uv) <= 1.0) {
		vec2 world_xz = sensor_anchor_xz + disk_uv * sample_radius_m;
		vec2 wave_uv = world_xz / max(domain_long_m, 0.001) + vec2(0.5);
		crest_g = clamp(texture(breaking_activity_long, wave_uv).g, 0.0, 1.0);
	}
	COLOR = vec4(crest_g, crest_g, crest_g, 1.0);
}
