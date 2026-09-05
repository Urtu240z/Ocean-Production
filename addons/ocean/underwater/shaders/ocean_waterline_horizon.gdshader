shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_always, fog_disabled;

uniform float sea_level = 0.0;

void vertex() {
	// Full-screen horizon fill at the far depth. The rasterized ocean geometry
	// is closer and overwrites it through the normal 3D depth attachment.
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
}

void fragment() {
	vec4 far_view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.0, 1.0);
	vec3 far_world = (INV_VIEW_MATRIX * vec4(far_view.xyz / max(abs(far_view.w), 0.00001), 1.0)).xyz;
	ALBEDO = vec3(0.0);
	EMISSION = vec3(far_world.y > sea_level ? 1.0 : 0.0);
}
