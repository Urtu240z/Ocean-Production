shader_type particles;

// This shader is used only by the visible sub-emitter. Its transform is
// initialized by the sensor's emit_subparticle() call and then integrated
// locally; it deliberately has no FFT or Crest texture uniforms.
uniform vec3 wind_velocity = vec3(0.0);
uniform float gravity_mps2 = 9.81;
uniform float wind_drag = 0.35;
uniform float turbulence_strength = 0.45;
uniform float turbulence_scale = 0.16;
uniform float turbulence_speed = 1.35;

float hash11(float value) {
	return fract(sin(value * 127.1 + 311.7) * 43758.5453);
}

void start() {
	// The parent supplies position, basis, velocity and CUSTOM. This fallback
	// only protects a manually restarted child from exposing uninitialized data.
	if (RESTART_CUSTOM) {
		CUSTOM = vec4(1.0, hash11(float(RANDOM_SEED)), 0.0, 1.0);
	}
}

void process() {
	float age_step = DELTA / max(LIFETIME, 0.001);
	CUSTOM.z = min(CUSTOM.z + age_step, 1.0);
	float noise_time = (CUSTOM.z * turbulence_speed + float(RANDOM_SEED) * 0.0001) * turbulence_scale;
	vec3 turbulence = vec3(
		sin(noise_time * 7.13 + CUSTOM.y * 11.0),
		cos(noise_time * 5.71 + CUSTOM.y * 17.0),
		sin(noise_time * 6.37 + CUSTOM.y * 23.0)
	) * (turbulence_strength * 0.35);
	VELOCITY += turbulence * DELTA;
	VELOCITY.y -= gravity_mps2 * DELTA;
	VELOCITY += (wind_velocity - VELOCITY) * clamp(wind_drag * DELTA, 0.0, 1.0);
	TRANSFORM[3].xyz += VELOCITY * DELTA;
}
