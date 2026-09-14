shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_test_disabled;

uniform vec4 particle_tint : source_color = vec4(0.75, 0.80, 0.80, 0.55);
uniform float opacity = 0.55;
uniform float lod_end_m = 48.0;
uniform vec2 camera_world_xz = vec2(0.0);
uniform int layer_kind = 1;
uniform bool force_visible = false;
uniform bool position_debug = false;

varying vec2 spindrift_uv;
varying float particle_source;
varying float particle_random;
varying float particle_age;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	spindrift_uv = UV;
	particle_source = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	particle_random = INSTANCE_CUSTOM.y;
	particle_age = clamp(INSTANCE_CUSTOM.z, 0.0, 1.0);
}

void fragment() {
	float source = particle_source;
	float random_value = particle_random;
	float age = particle_age;
	vec3 particle_world = MODEL_MATRIX[3].xyz;
	float distance_m = distance(particle_world.xz, camera_world_xz);
	float lod = 1.0 - smoothstep(lod_end_m * 0.72, max(lod_end_m, lod_end_m * 0.72 + 0.001), distance_m);
	float edge = smoothstep(0.0, 0.16, spindrift_uv.x) * (1.0 - smoothstep(0.84, 1.0, spindrift_uv.x));
	float breakup = mix(0.72, 1.0, hash12(floor(spindrift_uv * vec2(11.0, 17.0)) + random_value * 9.0));
	float life_fade = smoothstep(0.0, 0.08, age) * (1.0 - smoothstep(0.80, 1.0, age));
	float layer_shape = layer_kind == 2 ? 0.72 : (layer_kind == 0 ? 1.0 : 0.92);
	float alpha = force_visible ? 1.0 : particle_tint.a * opacity * source * lod * edge * breakup * life_fade * layer_shape;
	vec3 tint = particle_tint.rgb;
	if (position_debug) {
		alpha = 1.0;
		tint = vec3(1.0, 0.0, 1.0);
	}
	if (alpha < 0.008) discard;
	ALBEDO = tint;
	ROUGHNESS = 0.88;
	SPECULAR = layer_kind == 2 ? 0.22 : 0.08;
	ALPHA = alpha;
}
