shader_type particles;

// Persistent GPU sensor. CUSTOM.xy stores the world-space cell identity;
// CUSTOM.w is the hysteresis state. The sensor itself has no draw mesh.
uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
uniform sampler2D breaking_activity_long : repeat_enable, filter_linear;

uniform vec2 sensor_anchor_xz = vec2(0.0);
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 camera_forward_xz = vec2(0.0, -1.0);
uniform vec2 camera_right_xz = vec2(1.0, 0.0);
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_speed_mps = 18.0;
uniform float sea_level = 0.0;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform float ocean_surface_scale = 1.0;
uniform float clipmap_geometry_scale = 1.0;
uniform float sensor_grid_cell_m = 2.5;
uniform float source_edge_feather_m = 8.0;
uniform float active_radius_m = 48.0;
// The layer lattice must reach as far as the layer can actually be seen plus
// the distance the camera may drift from the anchor before a recenter. If this
// disk is smaller than that, part of the visual footprint has no sensor at all.
uniform float sensor_radius_m = 48.0;
uniform float emission_radius_m = 48.0;
uniform float event_trigger_threshold = 0.72;
uniform float event_rearm_threshold = 0.28;
uniform float event_density = 0.72;
uniform float storm_strength = 0.85;
uniform float crest_kick = 0.42;
uniform float horizontal_spread = 0.30;
uniform float vertical_spread = 0.10;
uniform int layer_kind = 1;
uniform float layer_amount = 1.0;
uniform bool force_emission = false;
uniform vec2 force_center_xz = vec2(0.0);
uniform float force_center_y = 3.0;
uniform float force_region_radius = 6.0;
uniform vec2 position_debug_center_xz = vec2(0.0);
uniform float position_debug_radius = 5.0;
uniform bool position_debug = false;
uniform bool position_debug_force = false;
uniform int source_mask_override = 0;
uniform float short_fade_start_m = 0.0;
uniform float short_fade_end_m = 55.0;
uniform float mid_fade_start_m = 96.0;
uniform float mid_fade_end_m = 280.0;
uniform float long_fade_start_m = 768.0;
uniform float long_fade_end_m = 2500.0;
// Validation-only channel. It publishes the activity, latch state and emission
// result of the real sensor through COLOR so an observation viewport can prove
// "eligible sensor -> emit_subparticle -> child" without Production telemetry.
// It is off by default and production never enables it.
uniform bool validation_telemetry = false;

float hash11(float value) {
	return fract(sin(value * 127.1 + 311.7) * 43758.5453);
}

vec2 hash21(float value) {
	return vec2(hash11(value + 17.0), hash11(value + 71.0));
}

vec2 ocean_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

vec3 ocean_space_normal_to_world_scaled(vec3 n) {
	const float epsilon = 0.00001;
	if (any(isnan(n)) || any(isinf(n))) return vec3(0.0, 1.0, 0.0);
	float horizontal_scale = max(abs(clipmap_geometry_scale), epsilon);
	float vertical_scale = max(abs(ocean_surface_scale), epsilon);
	vec3 transformed = vec3(n.x * vertical_scale / horizontal_scale, n.y, n.z * vertical_scale / horizontal_scale);
	float length_squared = dot(transformed, transformed);
	if (isnan(length_squared) || isinf(length_squared) || length_squared <= epsilon * epsilon) return vec3(0.0, 1.0, 0.0);
	return normalize(transformed);
}

vec3 ocean_space_displacement(vec3 authored) {
	return vec3(
		authored.x * clipmap_geometry_scale,
		authored.y * ocean_surface_scale,
		authored.z * clipmap_geometry_scale
	);
}

float fade_weight(float distance_m, float start_m, float end_m) {
	return 1.0 - smoothstep(start_m, max(end_m, start_m + 0.001), distance_m);
}

vec2 cell_to_world(vec2 cell) {
	return (cell + vec2(0.5)) * max(sensor_grid_cell_m, 0.1);
}

vec2 world_to_cell(vec2 world_xz) {
	return floor(world_xz / max(sensor_grid_cell_m, 0.1));
}

vec2 initial_cell(float stable_id) {
	float count = max(layer_amount, 1.0);
	float radial_u = clamp((stable_id + 0.5) / count, 0.0, 1.0);
	// Uniform-by-area low-discrepancy disk over the layer's own sensor lattice,
	// which is sized to the layer footprint plus the recenter margin.
	float radial_distance = sqrt(radial_u) * max(sensor_radius_m - sensor_grid_cell_m, sensor_grid_cell_m);
	float angular_u = fract(stable_id * 0.61803398875 + float(layer_kind) * 0.3333333333);
	float angle = angular_u * 6.28318530718;
	vec2 disk_offset = vec2(cos(angle), sin(angle)) * radial_distance;
	vec2 target = sensor_anchor_xz + disk_offset;
	return world_to_cell(target);
}

bool cell_is_active(vec2 cell) {
	vec2 world_xz = cell_to_world(cell);
	return distance(world_xz, sensor_anchor_xz) <= max(active_radius_m, sensor_grid_cell_m * 2.0);
}

float sensor_footprint_fade(vec2 world_xz) {
	float distance_m = distance(world_xz, sensor_anchor_xz);
	float edge_end = max(active_radius_m, 0.001);
	float edge_start = max(edge_end - max(source_edge_feather_m, sensor_grid_cell_m), 0.0);
	return 1.0 - smoothstep(edge_start, max(edge_end, edge_start + 0.001), distance_m);
}

bool inside_emission_footprint(vec2 world_xz) {
	return distance(world_xz, camera_world_xz) < max(emission_radius_m, sensor_grid_cell_m);
}

float breaking_activity(vec2 world_xz) {
	// Crest G is the sole open-ocean event authority. R is intentionally never
	// sampled here: R is residual foam, not fresh breaking activity.
	return clamp(texture(breaking_activity_long, ocean_uv(world_xz, domain_long_m)).g, 0.0, 1.0);
}

vec3 sample_displacement(vec2 world_xz) {
	float distance_m = distance(world_xz, sensor_anchor_xz);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	float mid_weight = fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m);
	float short_weight = fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	vec3 authored = texture(displacement_long, ocean_uv(world_xz, domain_long_m)).xyz * long_weight
		+ texture(displacement_mid, ocean_uv(world_xz, domain_mid_m)).xyz * mid_weight
		+ texture(displacement_short, ocean_uv(world_xz, domain_short_m)).xyz * short_weight;
	return ocean_space_displacement(authored);
}

vec3 sample_normal(vec2 world_xz) {
	float distance_m = distance(world_xz, sensor_anchor_xz);
	float long_weight = fade_weight(distance_m, long_fade_start_m, long_fade_end_m);
	float mid_weight = fade_weight(distance_m, mid_fade_start_m, mid_fade_end_m);
	float short_weight = fade_weight(distance_m, short_fade_start_m, short_fade_end_m);
	vec3 normal = ocean_space_normal_to_world_scaled(texture(normal_long, ocean_uv(world_xz, domain_long_m)).xyz) * long_weight
		+ ocean_space_normal_to_world_scaled(texture(normal_mid, ocean_uv(world_xz, domain_mid_m)).xyz) * mid_weight
		+ ocean_space_normal_to_world_scaled(texture(normal_short, ocean_uv(world_xz, domain_short_m)).xyz) * short_weight;
	return length(normal) > 0.0001 ? normalize(normal) : vec3(0.0, 1.0, 0.0);
}

vec2 wave_propagation_direction(vec2 world_xz) {
	// A local direction derived from LONG height, not from atmospheric wind.
	// It is used only for initial child velocity/orientation.
	float step_m = max(sensor_grid_cell_m * 0.5, 0.25);
	float h_x0 = texture(displacement_long, ocean_uv(world_xz - vec2(step_m, 0.0), domain_long_m)).y;
	float h_x1 = texture(displacement_long, ocean_uv(world_xz + vec2(step_m, 0.0), domain_long_m)).y;
	float h_z0 = texture(displacement_long, ocean_uv(world_xz - vec2(0.0, step_m), domain_long_m)).y;
	float h_z1 = texture(displacement_long, ocean_uv(world_xz + vec2(0.0, step_m), domain_long_m)).y;
	vec2 gradient = vec2(h_x1 - h_x0, h_z1 - h_z0);
	return length(gradient) > 0.0001 ? normalize(gradient) : vec2(0.0, -1.0);
}

mat3 child_basis(vec3 direction, float width_m, float length_m) {
	vec3 forward = normalize(direction);
	vec3 side = cross(vec3(0.0, 1.0, 0.0), forward);
	if (length(side) < 0.001) side = vec3(1.0, 0.0, 0.0);
	side = normalize(side);
	vec3 up = normalize(cross(forward, side));
	return mat3(side * width_m, forward * length_m, up * width_m);
}

mat4 sensor_transform(vec2 cell) {
	mat4 result = mat4(1.0);
	vec2 world_xz = cell_to_world(cell);
	result[3].xyz = vec3(world_xz.x, sea_level, world_xz.y);
	return result;
}

bool emit_detached_event(vec2 world_xz, float activity, float random_value) {
	vec3 displacement = sample_displacement(world_xz);
	vec3 normal = sample_normal(world_xz);
	if (normal.y < 0.0) normal = -normal;
	vec2 propagation_xz = wave_propagation_direction(world_xz);
	vec3 propagation = vec3(propagation_xz.x, 0.0, propagation_xz.y);
	vec3 wind = vec3(wind_direction.x, 0.0, wind_direction.y) * wind_speed_mps * mix(0.30, 1.0, storm_strength);
	vec3 side = normalize(cross(vec3(0.0, 1.0, 0.0), propagation));
	float lateral_sign = random_value < 0.5 ? -1.0 : 1.0;
	float layer_speed = layer_kind == 0 ? 1.0 : (layer_kind == 2 ? 0.55 : 0.78);
	vec3 velocity = propagation * (0.45 + activity * 0.85) * layer_speed;
	velocity += normal * (crest_kick * (0.65 + activity) + vertical_spread * hash11(random_value + 31.0));
	velocity += side * lateral_sign * horizontal_spread * (0.35 + activity);
	velocity += wind * 0.12;
	float width = layer_kind == 0 ? 0.56 : (layer_kind == 2 ? 0.34 : 0.40);
	float length = layer_kind == 0 ? 0.88 : (layer_kind == 2 ? 0.58 : 1.15);
	mat3 basis = child_basis(propagation + normal * 0.18, width, length);
	mat4 child_transform = mat4(1.0);
	child_transform[0].xyz = basis[0];
	child_transform[1].xyz = basis[1];
	child_transform[2].xyz = basis[2];
	child_transform[3].xyz = vec3(world_xz.x + displacement.x, sea_level + displacement.y, world_xz.y + displacement.z) + normal * 0.28;
	float source_distance = clamp(distance(world_xz, sensor_anchor_xz) / max(active_radius_m, 0.001), 0.0, 1.0);
	// Godot 4.7 exposes the flags as uint values in the particle compiler;
	// 31 enables position, rotation/scale, velocity, color and CUSTOM.
	return emit_subparticle(child_transform, velocity, vec4(1.0), vec4(activity, random_value, 0.0, source_distance), 31u);
}

void start() {
	vec2 cell = initial_cell(float(INDEX));
	CUSTOM = vec4(cell.x, cell.y, 0.0, 0.0);
	TRANSFORM = sensor_transform(cell);
	if (force_emission || position_debug_force) {
		vec2 random_uv = hash21(float(RANDOM_SEED) + 7.0);
		vec2 forced_xz = (force_emission ? force_center_xz : position_debug_center_xz) + (random_uv * 2.0 - 1.0) * (force_emission ? force_region_radius : position_debug_radius);
		bool emitted = emit_detached_event(forced_xz, 1.0, random_uv.x);
		if (emitted) {
			CUSTOM.w = 1.0;
		}
	}
}

void process() {
	vec2 cell = round(CUSTOM.xy);
	if (!cell_is_active(cell)) {
		cell = initial_cell(float(INDEX));
		CUSTOM.xy = cell;
		CUSTOM.w = 0.0;
	}
	vec2 world_xz = cell_to_world(cell);
	TRANSFORM = sensor_transform(cell);
	float activity = breaking_activity(world_xz) * sensor_footprint_fade(world_xz);
	bool inside_visual_coverage = force_emission || position_debug || inside_emission_footprint(world_xz);
	float emitted_flag = 0.0;
	float rearm_flag = 0.0;
	if (source_mask_override == 1) activity = 0.0;
	if (source_mask_override == 2) activity = 1.0;
	if (position_debug && !position_debug_force) activity = breaking_activity(world_xz);
	if (CUSTOM.w < 0.5) {
		float density = clamp(event_density, 0.0, 2.0);
		bool eligible = activity >= event_trigger_threshold;
		float first_hash = hash11(float(RANDOM_SEED) + 103.0);
		bool emit_first = force_emission || position_debug_force || (eligible && inside_visual_coverage && (density >= 1.0 || first_hash <= density));
		if (emit_first) {
			bool emitted_any = false;
			bool emitted_first = emit_detached_event(world_xz, clamp(activity, 0.0, 1.0), hash11(float(RANDOM_SEED) + 991.0));
			emitted_any = emitted_any || emitted_first;
			if (!force_emission && !position_debug_force && eligible && inside_visual_coverage && density > 1.0) {
				float second_hash = hash11(float(RANDOM_SEED) + 211.0);
				if (second_hash <= density - 1.0) {
					vec2 second_offset = (hash21(float(RANDOM_SEED) + 307.0) * 2.0 - 1.0) * 0.12;
					bool emitted_second = emit_detached_event(world_xz + second_offset, clamp(activity, 0.0, 1.0), hash11(float(RANDOM_SEED) + 997.0));
					emitted_any = emitted_any || emitted_second;
				}
			}
			if (emitted_any) {
				CUSTOM.w = 1.0;
				emitted_flag = 1.0;
			}
		}
	} else if (!force_emission && activity <= event_rearm_threshold) {
		CUSTOM.w = 0.0;
		rearm_flag = 0.5;
	}
	if (validation_telemetry) {
		// Validation-only state publication for the real sensor particle:
		//   r = consumed activity band (1.0 >= trigger, 0.5 > rearm, 0.0 <= rearm)
		//   g = hysteresis latch
		//   b = 1.0 emitted this frame, 0.5 rearmed this frame, 0.0 neither
		// Bands survive both linear and sRGB readback, so the observer never has
		// to guess the transfer function of the telemetry render target.
		float activity_band = activity >= event_trigger_threshold ? 1.0 : (activity > event_rearm_threshold ? 0.5 : 0.0);
		CUSTOM.z = activity;
		COLOR = vec4(activity_band, CUSTOM.w, emitted_flag > 0.0 ? 1.0 : rearm_flag, 1.0);
	}
}
