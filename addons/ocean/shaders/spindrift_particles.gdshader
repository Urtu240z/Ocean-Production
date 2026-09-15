shader_type particles;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
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
uniform float spawn_search_radius_m = 4.0;
uniform float spawn_surface_offset_m = 0.12;
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
uniform float long_whitecap_threshold = 0.62;
uniform float mid_whitecap_threshold = 0.66;
uniform float short_whitecap_threshold = 0.68;
uniform float long_crest_weight = 1.0;
uniform float mid_crest_weight = 0.65;
uniform float short_crest_weight = 0.10;
uniform int layer_kind = 1; // 0 chunks, 1 streaks, 2 mist
uniform float layer_amount = 1.0;
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

const float SPINDRIFT_PREBREAK_J_MARGIN = 0.20;
const float SPINDRIFT_GOLDEN_ANGLE = 2.39996323;
const float SPINDRIFT_TAU = 6.28318530718;

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

vec3 sample_normal(vec2 world_xz) {
	float distance_m = distance(world_xz, spindrift_origin);
	vec3 normal = texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz * fade_weight(distance_m, long_fade_start_m, long_fade_end_m)
		+ texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz * fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m)
		+ texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz * fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	return normalize(normal);
}

void sample_physical_source(vec2 world_xz, out vec3 displacement, out float instantaneous_break_source, out float positive_height) {
	float distance_m = distance(world_xz, spindrift_origin);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	float mid_weight = fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m);
	float short_weight = fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	vec4 long_sample = texture(displacement_long, ocean_uv(world_xz, domain_long_m));
	vec4 mid_sample = texture(displacement_mid, ocean_uv(world_xz, domain_mid_m));
	vec4 short_sample = texture(displacement_short, ocean_uv(world_xz, domain_short_m));

	// A is the instantaneous Jacobian written by assemble_maps.glsl. It is
	// intentionally sampled directly instead of using temporally accumulated
	// crest_foam textures.
	displacement = long_sample.xyz * long_weight
		+ mid_sample.xyz * mid_weight
		+ short_sample.xyz * short_weight;
	float long_prebreak_threshold = min(1.0, long_whitecap_threshold + SPINDRIFT_PREBREAK_J_MARGIN);
	float mid_prebreak_threshold = min(1.0, mid_whitecap_threshold + SPINDRIFT_PREBREAK_J_MARGIN);
	float short_prebreak_threshold = min(1.0, short_whitecap_threshold + SPINDRIFT_PREBREAK_J_MARGIN);
	float long_break_gate = 1.0 - smoothstep(long_whitecap_threshold, long_prebreak_threshold, long_sample.a);
	float mid_break_gate = 1.0 - smoothstep(mid_whitecap_threshold, mid_prebreak_threshold, mid_sample.a);
	float short_break_gate = 1.0 - smoothstep(short_whitecap_threshold, short_prebreak_threshold, short_sample.a);
	float long_source = long_break_gate * long_weight * long_crest_weight;
	float mid_source = mid_break_gate * mid_weight * mid_crest_weight * 0.35;
	float short_source = short_break_gate * short_weight * short_crest_weight * 0.10;
	// LONG is authoritative; MID and SHORT are soft detail additions.
	instantaneous_break_source = clamp(long_source + (1.0 - long_source) * (mid_source + (1.0 - mid_source) * short_source), 0.0, 1.0);
	positive_height = max(displacement.y, 0.0);
}

float source_mask(vec2 world_xz, out vec3 displacement, out vec3 normal) {
	float instantaneous_break_source;
	float positive_height;
	sample_physical_source(world_xz, displacement, instantaneous_break_source, positive_height);
	normal = sample_normal(world_xz);
	float breakup_factor = crest_breakup_mask(world_xz);
	float distance_m = distance(world_xz, spindrift_origin);
	float crest_distance_fade = 1.0 - smoothstep(crest_distance_fade_start_m, max(crest_distance_fade_end_m, crest_distance_fade_start_m + 0.001), distance_m);
	float steepness = length(normal.xz) / max(abs(normal.y), 0.08);
	float steep_gate = smoothstep(0.12, 0.72, steepness);
	float height_gate = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), positive_height / max(wave_height_reference_m, 0.01));
	float emission_strength = clamp(instantaneous_break_source * breakup_factor * crest_distance_fade * storm_strength, 0.0, 1.0);
	if (source_debug_stage == 1) return clamp(height_gate * storm_strength, 0.0, 1.0);
	if (source_debug_stage == 2) return clamp(steep_gate * storm_strength, 0.0, 1.0);
	if (source_debug_stage == 3) return clamp(instantaneous_break_source * storm_strength, 0.0, 1.0);
	return emission_strength;
}

mat3 basis_for(vec3 direction, float width_m, float length_m) {
	vec3 forward = normalize(direction);
	vec3 side = cross(vec3(0.0, 1.0, 0.0), forward);
	if (length(side) < 0.001) side = vec3(1.0, 0.0, 0.0);
	side = normalize(side);
	vec3 up = normalize(cross(forward, side));
	return mat3(side * width_m, forward * length_m, up * width_m);
}

float layer_wind_scale() {
	return layer_kind == 0 ? 0.72 : (layer_kind == 2 ? 1.08 : 1.0);
}

float layer_initial_wind_fraction() {
	return layer_kind == 0 ? 0.18 : (layer_kind == 2 ? 0.32 : 0.24);
}

float layer_advection_drag() {
	return layer_kind == 0 ? 0.65 : (layer_kind == 2 ? 2.40 : 1.40);
}

vec3 wind_target_velocity() {
	float target_speed = wind_speed_mps * wind_velocity_multiplier * mix(0.30, 1.0, storm_strength);
	if (force_emission) target_speed = max(target_speed, 18.0) * 1.25;
	return vec3(wind_direction.x, 0.0, wind_direction.y) * target_speed * layer_wind_scale();
}

void start() {
	if (RESTART_POSITION) {
		float emission_seed = float(RANDOM_SEED) * 0.000001 + float(NUMBER) * 37.0 + float(INDEX) * 101.0 + float(layer_kind) * 8191.0;
		vec2 emission_center = position_debug ? position_debug_center_xz : (force_emission ? force_center_xz : spindrift_origin);
		vec2 base_xz = emission_center;
		vec3 displacement = vec3(0.0);
		vec3 normal = vec3(0.0, 1.0, 0.0);
		float source = 1.0;
		float selected_break_source = 1.0;
		if (force_emission || position_debug) {
			vec2 random_uv = hash21(emission_seed + 7.0);
			float radius = sqrt(random_uv.x) * (force_emission ? force_region_radius : position_debug_radius);
			float angle = random_uv.y * 6.28318530718;
			base_xz += vec2(cos(angle), sin(angle)) * radius;
			if (position_debug && !position_debug_force) {
				source = source_mask(base_xz, displacement, normal);
			}
		} else {
			float particle_count = max(layer_amount, 1.0);
			float stratified_u = (float(INDEX) + 0.5) / particle_count;
			float emission_rotation = hash11(float(NUMBER) * 0.371 + float(layer_kind) * 8191.0) * SPINDRIFT_TAU;
			float base_radius = sqrt(clamp(stratified_u, 0.0, 1.0)) * spawn_radius_m;
			float base_angle = float(INDEX) * SPINDRIFT_GOLDEN_ANGLE + emission_rotation;
			base_xz = spindrift_origin + vec2(cos(base_angle), sin(base_angle)) * base_radius;
			float best_break_source = 0.0;
			float best_candidate_rank = 0.0;
			vec2 best_xz = base_xz;
			vec3 best_displacement = vec3(0.0);
			for (int candidate_index = 0; candidate_index < 6; candidate_index++) {
				vec2 local_offset = vec2(0.0);
				if (candidate_index > 0) {
					float radial_index = float(candidate_index - 1);
					float local_radius = spawn_search_radius_m * sqrt((radial_index + 0.5) / 5.0);
					float local_angle = emission_rotation + radial_index * SPINDRIFT_GOLDEN_ANGLE;
					local_offset = vec2(cos(local_angle), sin(local_angle)) * local_radius;
				}
				vec2 candidate_xz = base_xz + local_offset;
				vec3 candidate_displacement;
				float candidate_break_source;
				float candidate_positive_height;
				sample_physical_source(candidate_xz, candidate_displacement, candidate_break_source, candidate_positive_height);
				float height_bias = smoothstep(0.0, 0.30, candidate_positive_height / max(wave_height_reference_m, 0.01));
				float candidate_rank = candidate_break_source * mix(0.35, 1.0, height_bias);
				if (candidate_rank > best_candidate_rank) {
					best_candidate_rank = candidate_rank;
					best_break_source = candidate_break_source;
					best_xz = candidate_xz;
					best_displacement = candidate_displacement;
				}
			}
			base_xz = best_xz;
			displacement = best_displacement;
			normal = sample_normal(best_xz);
			float breakup_factor = crest_breakup_mask(best_xz);
			float distance_m = distance(best_xz, spindrift_origin);
			float distance_fade = 1.0 - smoothstep(crest_distance_fade_start_m, max(crest_distance_fade_end_m, crest_distance_fade_start_m + 0.001), distance_m);
			selected_break_source = best_break_source;
			source = clamp(selected_break_source * breakup_factor * distance_fade * storm_strength, 0.0, 1.0);
		}
		float emission_roll = hash11(emission_seed + 443.0);
		float density_active = step(emission_roll, clamp(emission_density * storm_strength, 0.0, 1.0));
		float source_active = position_debug ? float(source >= source_spawn_min) : float(selected_break_source >= source_spawn_min);
		float active = (force_emission || position_debug_force) ? 1.0 : density_active * source_active;
		CUSTOM = vec4(source, hash11(emission_seed + 991.0), 0.0, active);
		TRANSFORM = mat4(1.0);
		vec2 spawn_xz = base_xz + displacement.xz;
		float spawn_y = force_emission
			? force_center_y
			: (position_debug ? sea_level + 2.0 : sea_level + displacement.y + spawn_surface_offset_m);
		TRANSFORM[3].xyz = vec3(spawn_xz.x, spawn_y, spawn_xz.y);

		vec2 spread_random = hash21(emission_seed + 137.0) * 2.0 - 1.0;
		vec2 sideways = vec2(-wind_direction.y, wind_direction.x);
		vec3 target_wind = wind_target_velocity();
		float initial_fraction = layer_initial_wind_fraction();
		if (force_emission) initial_fraction = 0.75;
		vec3 initial_wind = target_wind * initial_fraction;
		vec3 random_spread = vec3(sideways.x * spread_random.x, spread_random.y * vertical_spread * 0.5, sideways.y * spread_random.x) * horizontal_spread * max(length(initial_wind.xz), 1.0) * 0.35;
		float layer_kick = layer_kind == 0 ? 1.0 : (layer_kind == 2 ? 0.18 : 0.55);
		vec3 normal_ejection = normal * crest_kick * layer_kick * (0.5 + source);
		normal_ejection.y *= 0.75;
		VELOCITY = initial_wind + random_spread + normal_ejection;
		if (layer_kind == 2) VELOCITY.y += abs(spread_random.y) * vertical_spread * max(length(initial_wind.xz), 1.0) * 0.35;
		if (position_debug) VELOCITY = vec3(0.0);
		if (active < 0.5) VELOCITY = vec3(0.0);
		float initial_width = layer_kind == 0 ? 0.09 : (layer_kind == 2 ? 0.035 : 0.065);
		float initial_length = layer_kind == 0 ? 0.26 : (layer_kind == 2 ? 0.32 : 0.90);
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
			VELOCITY = mix(VELOCITY, wind_target_velocity(), clamp(layer_advection_drag() * DELTA, 0.0, 1.0));
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
			float layer_width = layer_kind == 0 ? 0.09 : (layer_kind == 2 ? 0.035 : 0.065);
			float layer_length = layer_kind == 0 ? 0.26 : (layer_kind == 2 ? 0.32 : 0.90);
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
