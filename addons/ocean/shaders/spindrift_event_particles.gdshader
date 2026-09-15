shader_type particles;

// Persistent GPU sensors. A particle is a sensor first; it becomes visible
// only for the short burst that follows an edge-triggered crest event.
uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D crest_foam_long : repeat_enable, filter_linear;
uniform sampler2D crest_breakup_texture : repeat_enable, filter_linear;

uniform vec2 spindrift_origin = vec2(0.0);
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_speed_mps = 18.0;
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 camera_forward_xz = vec2(0.0, 1.0);
uniform vec2 camera_right_xz = vec2(1.0, 0.0);
uniform float spawn_footprint_near_m = 2.0;
uniform float spawn_footprint_far_m = 38.0;
uniform float spawn_footprint_half_width_m = 20.0;
uniform float spawn_footprint_near_feather_m = 3.0;
uniform float spawn_footprint_far_feather_m = 7.0;
uniform float spawn_footprint_side_feather_m = 4.0;
uniform float spawn_footprint_grid_cell_m = 2.5;
uniform float min_wave_strength = 0.12;
uniform float source_spawn_min = 0.002;
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
uniform int layer_kind = 1;
uniform float layer_amount = 1.0;
uniform bool force_emission = false;
uniform vec2 force_center_xz = vec2(0.0);
uniform float force_center_y = 3.0;
uniform float force_region_radius = 6.0;
uniform vec2 position_debug_center_xz = vec2(0.0);
uniform float position_debug_radius = 5.0;
uniform int source_debug_stage = 0;
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
uniform float crest_min = 0.001;
uniform float crest_full = 0.03;

uniform float event_fire_threshold = 0.72;
uniform float event_rearm_threshold = 0.28;
uniform float fresh_foam_threshold = 0.12;
uniform float fresh_foam_full = 0.42;
uniform float burst_duration_s = 0.42;

const float PREBREAK_MARGIN = 0.20;
const float CREST_SAMPLE_OFFSET_M = 0.8;

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

vec3 sample_normal(vec2 world_xz) {
	float distance_m = distance(world_xz, spindrift_origin);
	vec3 normal = texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz * fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	normal += texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz * fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m);
	normal += texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz * fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	return normalize(normal);
}

void sample_physical_source(vec2 world_xz, out vec3 displacement, out float positive_height) {
	float distance_m = distance(world_xz, spindrift_origin);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	float mid_weight = fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m);
	float short_weight = fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	displacement = texture(displacement_long, ocean_uv(world_xz, domain_long_m)).xyz * long_weight;
	displacement += texture(displacement_mid, ocean_uv(world_xz, domain_mid_m)).xyz * mid_weight;
	displacement += texture(displacement_short, ocean_uv(world_xz, domain_short_m)).xyz * short_weight;
	positive_height = max(displacement.y, 0.0);
}

float source_mask(vec2 world_xz, out vec3 displacement, out vec3 normal) {
	float positive_height;
	sample_physical_source(world_xz, displacement, positive_height);
	normal = sample_normal(world_xz);
	float height_gate = smoothstep(min_wave_strength, max(min_wave_strength + 0.18, 0.20), positive_height / max(wave_height_reference_m, 0.01));
	return clamp(height_gate * storm_strength, 0.0, 1.0);
}

void sample_long_event_signals(vec2 world_xz, out float height, out float prebreak_gate, out float fresh_gate) {
	float distance_m = distance(world_xz, spindrift_origin);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	vec4 displacement = texture(displacement_long, ocean_uv(world_xz, domain_long_m));
	vec4 foam = texture(crest_foam_long, ocean_uv(world_xz, domain_long_m));
	float prebreak_threshold = min(1.0, long_whitecap_threshold + PREBREAK_MARGIN);
	height = displacement.y * long_weight;
	prebreak_gate = 1.0 - smoothstep(long_whitecap_threshold, prebreak_threshold, displacement.a);
	fresh_gate = smoothstep(fresh_foam_threshold, max(fresh_foam_full, fresh_foam_threshold + 0.001), clamp(foam.g, 0.0, 1.0));
}

void resolve_sensor_anchor(float stable_id, out vec2 base_xz, out float footprint_fade) {
	float count = max(layer_amount, 1.0);
	float stable_u = fract(stable_id * 0.000123 + float(layer_kind) * 0.17320508);
	float stable_v = hash11(stable_id * 0.000731 + float(layer_kind) * 409.0);
	float stable_jitter = hash11(stable_id * 0.001137 + float(layer_kind) * 97.0) - 0.5;
	float grid_cell = max(spawn_footprint_grid_cell_m, 0.1);
	float forward_distance = mix(spawn_footprint_near_m, spawn_footprint_far_m, clamp(stable_u, 0.0, 1.0)) + stable_jitter * 0.35;
	float side_distance = (stable_v * 2.0 - 1.0) * spawn_footprint_half_width_m + stable_jitter * 0.25;
	vec2 grid_anchor = floor(spindrift_origin / grid_cell) * grid_cell + vec2(grid_cell * 0.5);
	base_xz = grid_anchor + camera_forward_xz * forward_distance + camera_right_xz * side_distance;
	base_xz = floor(base_xz / grid_cell) * grid_cell + vec2(grid_cell * 0.5);
	float side_fade = 1.0 - smoothstep(max(spawn_footprint_half_width_m - spawn_footprint_side_feather_m, 0.0), spawn_footprint_half_width_m, abs(side_distance));
	float near_fade = smoothstep(spawn_footprint_near_m, spawn_footprint_near_m + max(spawn_footprint_near_feather_m, 0.001), forward_distance);
	float far_fade = 1.0 - smoothstep(max(spawn_footprint_far_m - spawn_footprint_far_feather_m, spawn_footprint_near_m), spawn_footprint_far_m, forward_distance);
	footprint_fade = side_fade * near_fade * far_fade;
}

float evaluate_event_score(vec2 base_xz, float footprint_fade, out vec3 displacement, out vec3 normal) {
	vec2 dominant_direction = normalize(wind_direction);
	if (length(dominant_direction) < 0.0001) dominant_direction = vec2(1.0, 0.0);
	float h_center;
	float h_forward;
	float h_backward;
	float prebreak_gate;
	float fresh_gate;
	float unused_gate;
	sample_long_event_signals(base_xz, h_center, prebreak_gate, fresh_gate);
	sample_long_event_signals(base_xz + dominant_direction * CREST_SAMPLE_OFFSET_M, h_forward, unused_gate, unused_gate);
	sample_long_event_signals(base_xz - dominant_direction * CREST_SAMPLE_OFFSET_M, h_backward, unused_gate, unused_gate);
	float local_peak_gate = smoothstep(-0.02, 0.10, h_center - max(h_forward, h_backward));
	float curvature_gate = smoothstep(-0.01, 0.08, h_center - 0.5 * (h_forward + h_backward));
	float positive_height_gate = smoothstep(0.0, max(min_wave_strength * wave_height_reference_m, 0.10), h_center);
	float score = local_peak_gate * curvature_gate * positive_height_gate * prebreak_gate * fresh_gate;
	float positive_height;
	sample_physical_source(base_xz, displacement, positive_height);
	normal = sample_normal(base_xz);
	if (normal.y < 0.0) normal = -normal;
	normal = normalize(normal);
	return clamp(score * footprint_fade * storm_strength, 0.0, 1.0);
}

vec3 wind_target_velocity() {
	float target_speed = wind_speed_mps * wind_velocity_multiplier * mix(0.30, 1.0, storm_strength);
	return vec3(wind_direction.x, 0.0, wind_direction.y) * target_speed;
}

mat3 basis_for(vec3 direction, float width_m, float length_m) {
	vec3 forward = normalize(direction);
	vec3 side = cross(vec3(0.0, 1.0, 0.0), forward);
	if (length(side) < 0.001) side = vec3(1.0, 0.0, 0.0);
	side = normalize(side);
	vec3 up = normalize(cross(forward, side));
	return mat3(side * width_m, forward * length_m, up * width_m);
}

float layer_width() { return layer_kind == 0 ? 0.45 : (layer_kind == 2 ? 0.55 : 0.30); }
float layer_length() { return layer_kind == 0 ? 0.45 : (layer_kind == 2 ? 0.45 : 0.70); }

mat4 hidden_transform(vec2 base_xz) {
	mat4 result = mat4(1.0);
	result[3].xyz = vec3(base_xz.x, -100000.0, base_xz.y);
	return result;
}

mat4 burst_transform(vec2 base_xz, vec3 displacement, vec3 normal, float age, float source, float random_value) {
	float phase = 1.0 - smoothstep(0.0, 0.85, age);
	float kick_scale = layer_kind == 0 ? 1.0 : (layer_kind == 2 ? 0.18 : 0.55);
	vec3 wind = wind_target_velocity();
	vec3 wind_dir = normalize(vec3(wind.x, 0.02, wind.z));
	float drift = min(length(wind.xz) * burst_duration_s * 0.16, 2.2) * smoothstep(0.0, 0.75, age);
	vec3 position = vec3(base_xz.x + displacement.x, sea_level + displacement.y, base_xz.y + displacement.z);
	position += normal * (0.30 + crest_kick * kick_scale * (0.35 + source) * phase);
	position += vec3(0.0, 0.04, 0.0) + wind_dir * drift;
	vec3 direction = normalize(normal * (0.45 + source) + wind_dir * 0.55);
	float width = layer_width() * mix(1.0, 0.38, age) * mix(0.88, 1.18, random_value);
	float length = layer_length() * mix(1.0, 0.42, age) * (0.90 + source * 0.25);
	if (layer_kind == 0) { width *= 1.25; length *= 1.15; }
	if (layer_kind == 2) { width *= 0.72; length *= 0.68; }
	mat3 basis = basis_for(direction, width, length);
	mat4 result = mat4(1.0);
	result[0].xyz = basis[0];
	result[1].xyz = basis[1];
	result[2].xyz = basis[2];
	result[3].xyz = position;
	return result;
}

void start() {
	float seed = float(RANDOM_SEED) * 0.000001 + float(layer_kind) * 8191.0;
	vec2 base_xz;
	float footprint_fade;
	if (force_emission || position_debug) {
		vec2 random_uv = hash21(seed + 7.0);
		float radius = sqrt(random_uv.x) * (force_emission ? force_region_radius : position_debug_radius);
		float angle = random_uv.y * 6.28318530718;
		base_xz = (force_emission ? force_center_xz : position_debug_center_xz) + vec2(cos(angle), sin(angle)) * radius;
		footprint_fade = 1.0;
	} else {
		resolve_sensor_anchor(float(RANDOM_SEED), base_xz, footprint_fade);
	}
	CUSTOM = vec4(0.0, hash11(seed + 991.0), 0.0, 0.0);
	if (force_emission || position_debug_force) CUSTOM = vec4(1.0, CUSTOM.y, 0.01, 1.0);
	vec3 displacement = vec3(0.0);
	vec3 normal = vec3(0.0, 1.0, 0.0);
	if (force_emission || position_debug) {
		float debug_source = source_mask(base_xz, displacement, normal);
		if (position_debug && !position_debug_force) CUSTOM.x = debug_source;
	} else {
		float event_score = evaluate_event_score(base_xz, footprint_fade, displacement, normal);
		if (event_score >= event_fire_threshold) CUSTOM = vec4(event_score, CUSTOM.y, 0.01, 1.0);
	}
	if (CUSTOM.w > 0.5) TRANSFORM = burst_transform(base_xz, displacement, normal, CUSTOM.z, CUSTOM.x, CUSTOM.y);
	else TRANSFORM = hidden_transform(base_xz);
}

void process() {
	vec2 base_xz;
	float footprint_fade;
	if (force_emission || position_debug) {
		vec2 random_uv = hash21(CUSTOM.y * 991.0 + 7.0);
		float radius = sqrt(random_uv.x) * (force_emission ? force_region_radius : position_debug_radius);
		float angle = random_uv.y * 6.28318530718;
		base_xz = (force_emission ? force_center_xz : position_debug_center_xz) + vec2(cos(angle), sin(angle)) * radius;
		footprint_fade = 1.0;
	} else {
		resolve_sensor_anchor(float(RANDOM_SEED), base_xz, footprint_fade);
	}

	if (!force_emission && !position_debug) {
		vec3 displacement;
		vec3 normal;
		float event_score = evaluate_event_score(base_xz, footprint_fade, displacement, normal);
		if (CUSTOM.w < 0.5) {
			if (event_score >= event_fire_threshold) {
				CUSTOM.x = event_score;
				CUSTOM.z = 0.01;
				CUSTOM.w = 1.0;
			}
		} else if (CUSTOM.w < 1.5) {
			CUSTOM.z += DELTA / max(burst_duration_s, 0.05);
			if (CUSTOM.z >= 1.0) {
				CUSTOM.x = 0.0;
				CUSTOM.z = 1.0;
				CUSTOM.w = 2.0;
			}
		} else if (event_score <= event_rearm_threshold) {
			CUSTOM.w = 0.0;
		}
		if (CUSTOM.w > 0.5 && CUSTOM.w < 1.5) TRANSFORM = burst_transform(base_xz, displacement, normal, clamp(CUSTOM.z, 0.0, 1.0), CUSTOM.x, CUSTOM.y);
		else TRANSFORM = hidden_transform(base_xz);
	} else if (position_debug) {
		vec3 displacement;
		vec3 normal;
		float source = source_mask(base_xz, displacement, normal);
		CUSTOM.x = position_debug_force ? 1.0 : source;
		CUSTOM.z = position_debug_force ? 0.01 : 0.5;
		CUSTOM.w = 1.0;
		if (position_debug_force) TRANSFORM = burst_transform(base_xz, displacement, normal, CUSTOM.z, CUSTOM.x, CUSTOM.y);
		else {
			TRANSFORM = mat4(1.0);
			TRANSFORM[3].xyz = vec3(base_xz.x, sea_level + 2.0, base_xz.y);
			mat3 debug_basis = basis_for(vec3(0.0, 1.0, 0.0), 0.20, 0.20);
			TRANSFORM[0].xyz = debug_basis[0];
			TRANSFORM[1].xyz = debug_basis[1];
			TRANSFORM[2].xyz = debug_basis[2];
		}
	} else {
		vec3 zero_displacement = vec3(0.0);
		vec3 up = vec3(0.0, 1.0, 0.0);
		CUSTOM.x = 1.0;
		CUSTOM.z = min(CUSTOM.z + DELTA / max(burst_duration_s, 0.05), 1.0);
		CUSTOM.w = 1.0;
		TRANSFORM = burst_transform(base_xz, zero_displacement, up, CUSTOM.z, CUSTOM.x, CUSTOM.y);
	}
}
