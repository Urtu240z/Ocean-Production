shader_type spatial;
render_mode unshaded, cull_disabled;

void vertex() {
	// The parent sensor particle transform supplies the world-cell position.
}

void fragment() {
	// Keep READY sensors visible to the validation camera without changing the
	// encoded activity/state/transition channels.
	ALBEDO = vec3(0.02 + COLOR.r * 0.98, COLOR.g, COLOR.b);
}
