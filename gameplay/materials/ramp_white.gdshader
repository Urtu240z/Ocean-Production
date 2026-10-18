shader_type spatial;

// Equivalent to the ramp's original default white material. A private capture
// variant adds the opt-in water-plane clip without cutting the main view.
void fragment() {
	ALBEDO = vec3(1.0);
	ROUGHNESS = 1.0;
}
