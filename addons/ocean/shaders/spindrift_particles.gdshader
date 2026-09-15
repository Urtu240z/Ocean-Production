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
uniform sampler2D crest_breakup_texture : repeat_enable, filter_linear;

uniform vec2 spindrift_origin = vec2(0.0);
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_speed_mps = 18.0;
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform float spindrift_radius = 48.0;
uniform float spawn_radius_m = 48.0;
uniform float crest_min = 0.001;
uniform float crest_full = 0.03;
uniform float source_spawn_min = 0.002;
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
uniform bool force_emission = false;
uniform vec2 force_center_xz = vec2(0.0);
uniform float force_center_y = 3.0;
uniform float force_region_radius = 6.0;
uniform vec2 position_debug_center_xz = vec2(0.0);
uniform float position_debug_radius = 5.0;
uniform int source_debug_stage = 0; // 0 final, 1 height, 2 steepness, 3 crest
uniform bool position_debug = false;
uniform bool position_debug_force = false;
uniform int source_mask_override = 0;
uniform float short_fade_start_m = 0.0;
uniform float short_fade_end_m = 55.0;
uniform float mid_fade_start_m = 96.0;
uniform float mid_fade_end_m = 280.0;
uniform float long_fade_start_m = 768.0;
uniform float long_fade_end_m = 2500.0;
uniform float crest_detail_contribution = 0.35;
uniform float crest_intensity = 0.96;
uniform float crest_contrast = 1.19;
uniform float crest_distance_fade_start_m = 0.0;
uniform float crest_distance_fade_end_m = 5000.0;
uniform float crest_breakup_strength = 0.45;
uniform float crest_breakup_world_size_m = 14.0;
uniform float crest_edge_softness = 0.32;

float hash11(float value) {
	return fract(sin(value * 127.1 + 311.7) * 43758.5453);
}

vec2 hash21(float value) {
	return vec2(hash11(value + 17.0), hash11(value + 71.0));
}

vec2 ocean_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

float fade_weight(float distance_m, float start_m, float end_m) {
	return 1.0 - smoothstep(start_m, max(end_m, start_m + 0.001), distance_m);
}

float crest_breakup_mask(vec2 base_xz) {
	float noise = texture(crest_breakup_texture, base_xz / max(crest_breakup_world_size_m, 0.001)).r;
	float softness = clamp(crest_edge_softness, 0.01, 0.49);
	float breakup = mix(0.25, 1.0, smoothstep(0.5 - softness, 0.5 + softness, noise));
	return mix(1.0, breakup, crest_breakup_strength);
}

vec3 sample_displacement(vec2 world_xz) {
	float distance_m = distance(world_xz, spindrift_origin);
	return texture(displacement_long, ocean_uv(world_xz, domain_long_m)).xyz * fade_weight(distance_m, long_fade_start_m, long_fade_end_m)
		+ texture(displacement_mid, ocean_uv(world_xz, domain_mid_m)).xyz * fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m)
		+ texture(displacement_short, ocean_uv(world_xz, domain_short_m)).xyz * fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
}

vec3 sample_normal(vec2 world_xz) {
	float distance_m = distance(world_xz, spindrift_origin);
	vec3 normal = texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz * fade_weight(distance_m, long_fade_start_m, long_fade_end_m)
		+ texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz * fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m)
		+ texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz * fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	return normalize(normal);
}

float sample_raw_crest(vec2 world_xz) {
	float distance_m = distance(world_xz, spindrift_origin);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	float mid_weight = fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m);
	float short_weight = fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	float long_crest = texture(crest_foam_long, ocean_uv(world_xz, domain_long_m)).r * long_weight;
	float mid_detail = texture(crest_foam_mid, ocean_uv(world_xz, domain_mid_m)).r * mid_weight * crest_detail_contribution * 0.55;
	float short_detail = texture(crest_foam_short, ocean_uv(world_xz, domain_short_m)).r * short_weight * crest_detail_contribution * 0.30;
	float detail = 1.0 - (1.0 - clamp(mid_detail, 0.0, 1.0)) * (1.0 - clamp(short_detail, 0.0, 1.0));
	return clamp(1.0 - (1.0 - clamp(long_crest, 0.0, 1.0)) * (1.0 - detail), 0.0, 1.0);
}

float source_mask(vec2 world_xz, out vec3 displacement, out vec3 normal) {
	displacement = sample_displacement(world_xz);
	normal = sample_normal(world_xz);
	float raw_crest = sample_raw_crest(world_xz);
	float crest_gate = smoothstep(crest_min, max(crest_full, crest_min + 0.0001), raw_crest);
	float breakup_factor = crest_breakup_mask(world_xz);
	float distance_m = distance(world_xz, spindrift_origin);
	float crest_distance_fade = 1.0 - smoothstep(crest_distance_fade_start_m, max(crest_distance_fade_end_m, crest_distance_fade_start_m + 0.001), distance_m);
	float steepness = length(normal.xz) / max(abs(normal.y), 0.08);
	float steep_gate = smoothstep(0.12, 0.72, steepness);
	float height_gate = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), abs(displacement.y) / max(wave_height_reference_m, 0.01));
	float steep_factor = mix(0.45, 1.0, steep_gate);
	float height_factor = mix(0.35, 1.0, height_gate);
	if (source_debug_stage == 1) return clamp(height_gate * storm_strength, 0.0, 1.0);
	if (source_debug_stage == 2) return clamp(steep_gate * storm_strength, 0.0, 1.0);
	if (source_debug_stage == 3) return clamp(crest_gate * storm_strength, 0.0, 1.0);
	return clamp(crest_gate * breakup_factor * crest_distance_fade * steep_factor * height_factor * storm_strength, 0.0, 1.0);
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
		float emission_seed = float(RANDOM_SEED) * 0.000001 + float(NUMBER) * 37.0 + float(INDEX) * 101.0 + float(layer_kind) * 8191.0;
		vec2 emission_center = position_debug ? position_debug_center_xz : (force_emission ? force_center_xz : spindrift_origin);
		vec2 base_xz = emission_center;
		vec3 displacement = vec3(0.0);
		vec3 normal = vec3(0.0, 1.0, 0.0);
		float source = 1.0;
		if (force_emission || position_debug) {
			vec2 random_uv = hash21(emission_seed + 7.0);
			float radius = sqrt(random_uv.x) * (force_emission ? force_region_radius : position_debug_radius);
			float angle = random_uv.y * 6.28318530718;
			base_xz += vec2(cos(angle), sin(angle)) * radius;
			if (position_debug && !position_debug_force) {
				source = source_mask(base_xz, displacement, normal);
			}
		} else {
			float best_source = 0.0;
			vec2 best_xz = emission_center;
			vec3 best_displacement = vec3(0.0);
			vec3 best_normal = vec3(0.0, 1.0, 0.0);
			for (int candidate_index = 0; candidate_index < 12; candidate_index++) {
				float candidate_seed = emission_seed + float(candidate_index) * 53.0 + 17.0;
				vec2 candidate_random = hash21(candidate_seed);
				float radius = sqrt(candidate_random.x) * spawn_radius_m;
				float angle = candidate_random.y * 6.28318530718;
				vec2 candidate_xz = emission_center + vec2(cos(angle), sin(angle)) * radius;
				vec2 jitter = (hash21(candidate_seed + 101.0) * 2.0 - 1.0) * max(spawn_radius_m / 64.0, 0.25);
				candidate_xz += jitter;
				vec3 candidate_displacement;
				vec3 candidate_normal;
				float candidate_source = source_mask(candidate_xz, candidate_displacement, candidate_normal);
				if (candidate_source > best_source) {
					best_source = candidate_source;
					best_xz = candidate_xz;
					best_displacement = candidate_displacement;
					best_normal = candidate_normal;
				}
			}
			base_xz = best_xz;
			displacement = best_displacement;
			normal = best_normal;
			source = best_source;
		}
		float emission_roll = hash11(emission_seed + 443.0);
		float density_active = step(emission_roll, clamp(emission_density * storm_strength, 0.0, 1.0));
		float source_active = float(source >= source_spawn_min);
		float active = (force_emission || position_debug_force) ? 1.0 : density_active * source_active;
		CUSTOM = vec4(source, hash11(emission_seed + 991.0), 0.0, active);
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = vec3(base_xz + displacement.xz, force_emission ? force_center_y : (position_debug ? sea_level + 2.0 : sea_level + displacement.y));

		vec2 spread_random = hash21(emission_seed + 137.0) * 2.0 - 1.0;
		vec2 sideways = vec2(-wind_direction.y, wind_direction.x);
		float wind_scale = wind_speed_mps * wind_velocity_multiplier * mix(0.30, 1.0, storm_strength);
		if (force_emission) wind_scale = max(wind_scale, 18.0) * 1.25;
		float layer_wind_scale = layer_kind == 0 ? 0.72 : (layer_kind == 2 ? 1.08 : 1.0);
		vec3 wind = vec3(wind_direction.x, 0.0, wind_direction.y) * wind_scale * layer_wind_scale;
		vec3 random_spread = vec3(sideways.x * spread_random.x, spread_random.y * vertical_spread, sideways.y * spread_random.x) * horizontal_spread * wind_scale * 0.35;
		float layer_kick = layer_kind == 0 ? 1.0 : (layer_kind == 2 ? 0.18 : 0.55);
		VELOCITY = wind + random_spread + normal * crest_kick * layer_kick * (0.5 + source);
		if (layer_kind == 2) VELOCITY.y += abs(spread_random.y) * vertical_spread * wind_scale * 0.35;
		if (position_debug) VELOCITY = vec3(0.0);
		if (active < 0.5) VELOCITY = vec3(0.0);
		float initial_width = layer_kind == 0 ? 0.055 : (layer_kind == 2 ? 0.022 : 0.040);
		float initial_length = layer_kind == 0 ? 0.18 : (layer_kind == 2 ? 0.22 : 0.65);
		if (position_debug) {
			initial_width = 0.20;
			initial_length = 0.20;
		}
		if (force_emission) {
			initial_width = layer_kind == 0 ? 0.80 : (layer_kind == 2 ? 0.55 : 0.65);
			initial_length = layer_kind == 0 ? 1.20 : (layer_kind == 2 ? 1.70 : 3.60);
		}
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
		if (position_debug) {
			mat3 debug_basis = basis_for(vec3(0.0, 1.0, 0.0), 0.20, 0.20);
			TRANSFORM[0].xyz = debug_basis[0];
			TRANSFORM[1].xyz = debug_basis[1];
			TRANSFORM[2].xyz = debug_basis[2];
		} else {
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
			if (force_emission) {
				layer_width = layer_kind == 0 ? 0.80 : (layer_kind == 2 ? 0.55 : 0.65);
				layer_length = layer_kind == 0 ? 1.20 : (layer_kind == 2 ? 1.70 : 3.60);
			}
			mat3 process_basis = basis_for(VELOCITY + vec3(0.0, 0.01, 0.0), layer_width * size_random, layer_length * length_scale * storm_length);
			TRANSFORM[0].xyz = process_basis[0];
			TRANSFORM[1].xyz = process_basis[1];
			TRANSFORM[2].xyz = process_basis[2];
		}
	}
}
