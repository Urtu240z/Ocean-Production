shader_type particles;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D crest_foam_long : repeat_enable, filter_linear;
uniform sampler2D crest_foam_mid : repeat_enable, filter_linear;
uniform sampler2D crest_foam_short : repeat_enable, filter_linear;

uniform vec2 spindrift_origin = vec2(0.0);
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_speed_mps = 18.0;
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform float spindrift_radius = 48.0;
uniform float crest_threshold = 0.58;
uniform float crest_softness = 0.16;
uniform float min_wave_strength = 0.12;
uniform float emission_density = 0.72;
uniform float storm_strength = 0.85;
uniform float wind_velocity_multiplier = 1.0;
uniform float crest_kick = 0.42;
uniform float horizontal_spread = 0.30;
uniform float vertical_spread = 0.10;
uniform float turbulence_strength = 0.45;
uniform float turbulence_scale = 0.16;
uniform float turbulence_speed = 1.35;
uniform float wave_height_reference_m = 2.5;
uniform int layer_kind = 1; // 0 chunks, 1 streaks, 2 mist

float hash11(float value) {
	return fract(sin(value * 127.1 + 311.7) * 43758.5453);
}

vec2 hash21(float value) {
	return vec2(hash11(value + 17.0), hash11(value + 71.0));
}

vec2 ocean_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

vec3 sample_displacement(vec2 world_xz) {
	return texture(displacement_long, ocean_uv(world_xz, domain_long_m)).xyz * 0.55
		+ texture(displacement_mid, ocean_uv(world_xz, domain_mid_m)).xyz * 0.30
		+ texture(displacement_short, ocean_uv(world_xz, domain_short_m)).xyz * 0.15;
}

vec3 sample_normal(vec2 world_xz) {
	vec3 normal = texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz * 0.55
		+ texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz * 0.30
		+ texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz * 0.15;
	return normalize(normal);
}

float sample_crest(vec2 world_xz) {
	float long_crest = texture(crest_foam_long, ocean_uv(world_xz, domain_long_m)).r;
	float mid_crest = texture(crest_foam_mid, ocean_uv(world_xz, domain_mid_m)).r;
	float short_crest = texture(crest_foam_short, ocean_uv(world_xz, domain_short_m)).r;
	return 1.0 - (1.0 - clamp(long_crest, 0.0, 1.0))
		* (1.0 - clamp(mid_crest, 0.0, 1.0))
		* (1.0 - clamp(short_crest, 0.0, 1.0));
}

float source_mask(vec2 world_xz, out vec3 displacement, out vec3 normal) {
	displacement = sample_displacement(world_xz);
	normal = sample_normal(world_xz);
	float crest = sample_crest(world_xz);
	float steepness = length(normal.xz) / max(abs(normal.y), 0.08);
	float steep_gate = smoothstep(0.12, 0.72, steepness);
	float height_gate = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), abs(displacement.y) / max(wave_height_reference_m, 0.01));
	float crest_gate = smoothstep(crest_threshold, crest_threshold + max(crest_softness, 0.01), crest);
	return clamp(crest_gate * mix(0.45, 1.0, steep_gate) * mix(0.35, 1.0, height_gate) * storm_strength, 0.0, 1.0);
}

mat3 basis_for(vec3 direction, float width_m, float length_m) {
	vec3 forward = normalize(direction);
	vec3 side = cross(vec3(0.0, 1.0, 0.0), forward);
	if (length(side) < 0.001) side = vec3(1.0, 0.0, 0.0);
	side = normalize(side);
	vec3 up = normalize(cross(forward, side));
	return mat3(side * width_m, forward * length_m, up * width_m);
}

void start() {
	if (RESTART_POSITION) {
		float particle_id = float(INDEX) + float(layer_kind) * 8191.0;
		vec2 random_uv = hash21(particle_id);
		float radius = sqrt(random_uv.x) * spindrift_radius;
		float angle = random_uv.y * 6.28318530718;
		vec2 base_xz = spindrift_origin + vec2(cos(angle), sin(angle)) * radius;
		vec2 jitter = (hash21(particle_id + 101.0) * 2.0 - 1.0) * max(spindrift_radius / 64.0, 0.25);
		base_xz += jitter;

		vec3 displacement;
		vec3 normal;
		float source = source_mask(base_xz, displacement, normal);
		float emission_roll = hash11(particle_id + 443.0);
		float active = step(emission_roll, clamp(emission_density * storm_strength, 0.0, 1.0)) * step(0.015, source);
		CUSTOM = vec4(source, hash11(particle_id + 991.0), 0.0, active);
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = vec3(base_xz + displacement.xz, sea_level + displacement.y);

		vec2 spread_random = hash21(particle_id + 137.0) * 2.0 - 1.0;
		vec2 sideways = vec2(-wind_direction.y, wind_direction.x);
		float wind_scale = wind_speed_mps * wind_velocity_multiplier * mix(0.30, 1.0, storm_strength);
		float layer_wind_scale = layer_kind == 0 ? 0.72 : (layer_kind == 2 ? 1.08 : 1.0);
		vec3 wind = vec3(wind_direction.x, 0.0, wind_direction.y) * wind_scale * layer_wind_scale;
		vec3 random_spread = vec3(sideways.x * spread_random.x, spread_random.y * vertical_spread, sideways.y * spread_random.x) * horizontal_spread * wind_scale * 0.35;
		float layer_kick = layer_kind == 0 ? 1.0 : (layer_kind == 2 ? 0.18 : 0.55);
		VELOCITY = wind + random_spread + normal * crest_kick * layer_kick * (0.5 + source);
		if (layer_kind == 2) VELOCITY.y += abs(spread_random.y) * vertical_spread * wind_scale * 0.35;
		if (active < 0.5) VELOCITY = vec3(0.0);
		float initial_width = layer_kind == 0 ? 0.055 : (layer_kind == 2 ? 0.022 : 0.040);
		float initial_length = layer_kind == 0 ? 0.18 : (layer_kind == 2 ? 0.22 : 0.65);
		mat3 start_basis = basis_for(VELOCITY + vec3(0.0, 0.01, 0.0), initial_width, initial_length);
		TRANSFORM[0].xyz = start_basis[0];
		TRANSFORM[1].xyz = start_basis[1];
		TRANSFORM[2].xyz = start_basis[2];
	}
}

void process() {
	if (CUSTOM.w < 0.5) {
		TRANSFORM[3].y = -100000.0;
	} else {
		CUSTOM.z = min(CUSTOM.z + DELTA / max(LIFETIME, 0.001), 1.0);
		vec3 position = TRANSFORM[3].xyz;
		vec3 turbulence = vec3(
			sin(TIME * turbulence_speed + position.z * turbulence_scale + CUSTOM.y * 13.0),
			cos(TIME * turbulence_speed * 0.77 + position.x * turbulence_scale + CUSTOM.y * 7.0),
			sin(TIME * turbulence_speed * 0.91 + position.xz.x * turbulence_scale * 0.61 + CUSTOM.y * 19.0)
		) * turbulence_strength;
		VELOCITY += turbulence * DELTA;
		TRANSFORM[3].xyz += VELOCITY * DELTA;
		float size_random = mix(0.72, 1.55, CUSTOM.y);
		float length_scale = layer_kind == 0 ? mix(0.55, 1.15, CUSTOM.y) : (layer_kind == 2 ? mix(0.35, 0.85, CUSTOM.y) : mix(1.0, 2.4, CUSTOM.y));
		float storm_length = mix(0.65, 1.35, storm_strength);
		float layer_width = layer_kind == 0 ? 0.055 : (layer_kind == 2 ? 0.022 : 0.040);
		float layer_length = layer_kind == 0 ? 0.18 : (layer_kind == 2 ? 0.22 : 0.65);
		mat3 process_basis = basis_for(VELOCITY + vec3(0.0, 0.01, 0.0), layer_width * size_random, layer_length * length_scale * storm_length);
		TRANSFORM[0].xyz = process_basis[0];
		TRANSFORM[1].xyz = process_basis[1];
		TRANSFORM[2].xyz = process_basis[2];
	}
}
