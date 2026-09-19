shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, depth_test_disabled;

uniform vec4 particle_tint : source_color = vec4(0.75, 0.80, 0.80, 0.55);
uniform float opacity = 0.55;
uniform float lod_end_m = 48.0;
uniform float source_radius_m = 120.0;
uniform sampler2D opaque_scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform float opaque_depth_bias_m = 0.03;
uniform float opaque_depth_softness_m = 0.10;
uniform vec2 camera_world_xz = vec2(0.0);
uniform int layer_kind = 1;
uniform bool force_visible = false;
uniform bool position_debug = false;
// Art values are supplied per layer by OceanSpindriftProfile.
uniform float sea_level = 0.0;
uniform float fade_in_fraction = 0.07;
uniform float fade_out_start_fraction = 0.70;
uniform float water_fade_height_m = 0.35;
uniform float visual_scale = 1.0;
uniform float shape_width_scale = 1.0;
uniform float shape_length_scale = 1.0;
uniform float edge_softness = 0.12;
uniform float breakup_strength = 0.30;
uniform float mottle_strength = 0.20;
uniform float terminal_scale = 0.65;
uniform float core_strength = 0.60;
// Supplied spray artwork. Every layer binds all three so the families overlap.
uniform sampler2D spray_streaks : repeat_disable, filter_linear;
uniform sampler2D spray_mist : repeat_disable, filter_linear;
uniform sampler2D spray_chunks : repeat_disable, filter_linear;

varying vec2 spindrift_uv;
varying float particle_source;
varying float particle_random;
varying float particle_age;
varying float particle_source_distance;
// MODEL_MATRIX is per-particle only in the vertex stage. In the fragment stage
// it is the particle system node transform, so the camera-relative LOD would be
// measured from the node origin instead of from the particle. The particle world
// position must travel to the fragment stage as an interpolated varying.
varying vec2 particle_world_xz;
varying float particle_world_y;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Stable value noise over quantized UV cells. No time term: the silhouette of a
// particle stays identical for its whole lifetime.
float stable_cell_noise(vec2 uv, float channel, float cells) {
	vec2 scaled = uv * cells;
	vec2 cell = floor(scaled);
	vec2 local = fract(scaled);
	vec2 smooth_local = local * local * (3.0 - 2.0 * local);
	float offset = fract(channel * 0.61803398875) * 97.0;
	vec2 base = vec2(offset, offset * 0.5);
	float n00 = hash12(cell + base);
	float n10 = hash12(cell + base + vec2(1.0, 0.0));
	float n01 = hash12(cell + base + vec2(0.0, 1.0));
	float n11 = hash12(cell + base + vec2(1.0, 1.0));
	return mix(mix(n00, n10, smooth_local.x), mix(n01, n11, smooth_local.x), smooth_local.y);
}

// --- supplied spray artwork ---------------------------------------------------
// Each layer material binds all three textures, so the visual families can
// overlap per particle instead of being segregated by particle system.

// Mirror and rotate around the centre. The square is scaled inward by the
// rotation extent so the lookup can never leave [0,1] and smear clamped border
// texels into the silhouette.
vec2 artwork_uv(vec2 uv, float angle, float mirror) {
	vec2 sampled = vec2(mix(uv.x, 1.0 - uv.x, mirror), uv.y);
	float extent = abs(cos(angle)) + abs(sin(angle));
	vec2 centered = (sampled - 0.5) / max(extent, 0.0001);
	float s = sin(angle);
	float c = cos(angle);
	return vec2(centered.x * c - centered.y * s, centered.x * s + centered.y * c) + 0.5;
}

// streaks.png is authored as a horizontal filament, so its X axis must run along
// the billboard's long axis (local Y), which the vertex stage already aligned
// with the particle's own travel direction.
vec2 streak_artwork_uv(vec2 uv, float seed) {
	vec2 sampled = vec2(uv.y, uv.x);
	sampled.x = mix(sampled.x, 1.0 - sampled.x, step(0.5, seed));
	sampled.y += sin(sampled.x * 6.2831853 + seed * 12.0) * (seed - 0.5) * 0.16;
	return sampled;
}

// Radial attenuation so a rectangular card can never show an edge or a corner.
float card_limits(vec2 centered_uv, float softness) {
	float start = mix(0.72, 0.28, clamp(softness * 2.0, 0.0, 1.0));
	return 1.0 - smoothstep(start, 1.32, length(centered_uv));
}

// Silhouette detail applied on top of the artwork: edge-biased breakup, internal
// mottle, and a coherent centre that survives fragmentation.
float shape_detail(float base_shape, vec2 uv, float random_value) {
	float edge_factor = 1.0 - smoothstep(0.45, 0.90, base_shape);
	float breakup_noise = stable_cell_noise(uv + random_value * 0.137, random_value, 3.0);
	float breakup_factor = 1.0 - breakup_strength * edge_factor * mix(0.35, 1.0, breakup_noise);
	float shape = base_shape * clamp(breakup_factor, 0.0, 1.0);
	float mottle_noise = stable_cell_noise(uv + random_value * 0.271, random_value + 11.0, 2.0);
	shape *= mix(1.0, mix(0.55, 1.0, mottle_noise), clamp(mottle_strength, 0.0, 1.0));
	float core = smoothstep(0.35, 0.85, base_shape);
	shape = mix(shape, max(shape, core), clamp(core_strength, 0.0, 1.0));
	return clamp(shape, 0.0, 1.0);
}

float optics_linear_depth(vec2 uv, float raw_depth, mat4 inverse_projection) {
	vec4 view = inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	return -view.z / max(view.w, 0.00001);
}

float layer_life_fade(float age) {
	// Profile-driven birth/death fades. The shader clamps the interval so a
	// reversed or collapsed combination can never produce NaN.
	float birth_end = clamp(fade_in_fraction, 0.0001, 0.49);
	float birth_fade = smoothstep(0.0, birth_end, age);
	float death_start = clamp(fade_out_start_fraction, birth_end, 0.999);
	float death_fade = 1.0 - smoothstep(death_start, 1.0, age);
	return birth_fade * death_fade;
}

float water_fade_at(float world_y) {
	// Visual-only sea-level fade: full contribution above the fade height,
	// smoothly to zero at sea level. Slot cleanup lives in the child shader.
	float height_above_water = world_y - sea_level;
	return smoothstep(0.0, max(water_fade_height_m, 0.001), height_above_water);
}

void vertex() {
	spindrift_uv = UV;
	particle_source = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	particle_random = INSTANCE_CUSTOM.y;
	particle_age = clamp(INSTANCE_CUSTOM.z, 0.0, 1.0);
	particle_source_distance = clamp(INSTANCE_CUSTOM.w, 0.0, 1.0);

	vec3 particle_position = MODEL_MATRIX[3].xyz;
	particle_world_xz = particle_position.xz;
	particle_world_y = particle_position.y;
	float visual_width = max(length(MODEL_MATRIX[0].xyz), 0.0001);
	float visual_height = max(length(MODEL_MATRIX[1].xyz), 0.0001);
	if (!force_visible && !position_debug) {
		float size_fade = smoothstep(0.48, 0.96, particle_age);
		float size_scale = mix(1.0, terminal_scale, size_fade);
		visual_width *= size_scale;
		visual_height *= size_scale;
	}
	// Visual-only scale: the particle world transform and the LOD distances are
	// deliberately not touched. The profile owns both the overall and the
	// per-layer width/length proportions, and per-particle jitter keeps the field
	// from reading as identical stamps.
	float width_jitter = mix(0.85, 1.18, hash12(vec2(particle_random * 13.7 + 4.0, 61.0)));
	float length_jitter = mix(0.90, 1.15, hash12(vec2(particle_random * 7.3 + 9.0, 67.0)));
	visual_width *= visual_scale * shape_width_scale * width_jitter;
	visual_height *= visual_scale * shape_length_scale * length_jitter;
	vec3 camera_right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 camera_forward = normalize(-INV_VIEW_MATRIX[2].xyz);
	vec3 camera_up = normalize(INV_VIEW_MATRIX[1].xyz);
	mat4 billboard_model = mat4(1.0);
	if (layer_kind == 0) {
		// The sensor derives this basis from LONG wave geometry at spawn. The
		// visible child keeps it while detached; wind never substitutes for it.
		vec3 crest_tangent = normalize(MODEL_MATRIX[1].xyz);
		vec3 projected_tangent = crest_tangent - camera_forward * dot(crest_tangent, camera_forward);
		if (length(projected_tangent) < 0.0001) projected_tangent = camera_up;
		vec2 tangent_screen_direction = vec2(dot(normalize(projected_tangent), camera_right), dot(normalize(projected_tangent), camera_up));
		if (length(tangent_screen_direction) < 0.0001) tangent_screen_direction = vec2(0.0, 1.0);
		tangent_screen_direction = normalize(tangent_screen_direction);
		vec3 long_axis = camera_right * tangent_screen_direction.x + camera_up * tangent_screen_direction.y;
		vec3 side_axis = camera_right * (-tangent_screen_direction.y) + camera_up * tangent_screen_direction.x;
		// Crest-following patch. Its proportions come from the profile scales
		// already folded into visual_width/visual_height; only numerical safety
		// bounds remain here.
		float crest_patch_length = max(visual_height, 0.01);
		float crest_patch_height = max(visual_width, 0.01);
		billboard_model = mat4(
			vec4(side_axis * crest_patch_height, 0.0),
			vec4(long_axis * crest_patch_length, 0.0),
			vec4(camera_forward * crest_patch_height, 0.0),
			vec4(particle_position, 1.0)
		);
	} else if (layer_kind == 2) {
		billboard_model = mat4(
			vec4(camera_right * visual_width, 0.0),
			vec4(camera_up * visual_height, 0.0),
			vec4(camera_forward * visual_width, 0.0),
			vec4(particle_position, 1.0)
		);
	} else {
		// Streaks keep their particle direction; the profile decides how much
		// longer than wide the sheet is, so it never collapses to a square.
		float streak_length = max(visual_height, 0.01);
		vec3 particle_direction = normalize(MODEL_MATRIX[1].xyz);
		vec3 projected_direction = particle_direction - camera_forward * dot(particle_direction, camera_forward);
		if (length(projected_direction) < 0.0001) {
			projected_direction = camera_up;
		}
		vec2 screen_direction = vec2(dot(normalize(projected_direction), camera_right), dot(normalize(projected_direction), camera_up));
		if (length(screen_direction) < 0.0001) {
			screen_direction = vec2(0.0, 1.0);
		}
		screen_direction = normalize(screen_direction);
		vec3 long_axis = camera_right * screen_direction.x + camera_up * screen_direction.y;
		vec3 side_axis = camera_right * (-screen_direction.y) + camera_up * screen_direction.x;
		billboard_model = mat4(
			vec4(side_axis * visual_width, 0.0),
			vec4(long_axis * streak_length, 0.0),
			vec4(camera_forward * visual_width, 0.0),
			vec4(particle_position, 1.0)
		);
	}
	MODELVIEW_MATRIX = VIEW_MATRIX * billboard_model;
}

void fragment() {
	float source = particle_source;
	float random_value = particle_random;
	float age = particle_age;
	float source_distance_m = particle_source_distance * max(source_radius_m, 0.001);
	float distance_m = distance(particle_world_xz, camera_world_xz);
	float lod = 1.0 - smoothstep(lod_end_m * 0.72, max(lod_end_m, lod_end_m * 0.72 + 0.001), distance_m);
	float life_fade = layer_life_fade(age);
	float water_fade = water_fade_at(particle_world_y);
	bool debug_visible = force_visible || position_debug;
	// Equivalence-preserving early out: each of these factors alone forces alpha
	// below the final discard threshold, so the depth read and the procedural
	// silhouette work further down can be skipped. Debug modes keep their
	// validated bypass of the fades and never take this path.
	if (!debug_visible) {
		if (lod <= 0.001 || life_fade <= 0.001 || water_fade <= 0.001) {
			discard;
		}
	}
	float raw_opaque_scene_depth = textureLod(opaque_scene_depth, SCREEN_UV, 0.0).r;
	bool opaque_depth_valid = raw_opaque_scene_depth > 0.000001 && raw_opaque_scene_depth <= 1.000001 && !isnan(raw_opaque_scene_depth) && !isinf(raw_opaque_scene_depth);
	float opaque_scene_linear_depth = optics_linear_depth(SCREEN_UV, raw_opaque_scene_depth, INV_PROJECTION_MATRIX);
	float particle_linear_depth = optics_linear_depth(SCREEN_UV, FRAGCOORD.z, INV_PROJECTION_MATRIX);
	float depth_delta = particle_linear_depth - opaque_scene_linear_depth - opaque_depth_bias_m;
	float occlusion = 1.0;
	if (opaque_depth_valid && opaque_scene_linear_depth > 0.00001 && particle_linear_depth > 0.00001) {
		occlusion = 1.0 - smoothstep(0.0, max(opaque_depth_softness_m, 0.001), depth_delta);
	}
	// Deterministic visual family. Every input is either stable per particle
	// (its seed and its birth data) or the age ramp, so a particle never flickers
	// between families and no simulation data is reinterpreted.
	float seed_chunks = hash12(vec2(random_value * 71.1 + 2.0, 53.0));
	float seed_streaks = hash12(vec2(random_value * 57.3 + 11.0, 29.0));
	float seed_mist = hash12(vec2(random_value * 33.9 + 5.0, 41.0));
	vec3 weights = layer_kind == 0 ? vec3(0.55, 0.35, 0.10)
		: (layer_kind == 2 ? vec3(0.05, 0.30, 0.65) : vec3(0.10, 0.72, 0.18));
	weights *= vec3(mix(0.55, 1.45, seed_chunks), mix(0.55, 1.45, seed_streaks), mix(0.55, 1.45, seed_mist));
	// Visual progression: coarse torn structure at birth, directional body in the
	// middle, diffuse aerosol as the particle dies.
	float age_birth = 1.0 - smoothstep(0.0, 0.45, age);
	float age_late = smoothstep(0.25, 1.0, age);
	weights.x *= (0.35 + 0.95 * age_birth) * mix(0.80, 1.30, clamp(source, 0.0, 1.0));
	weights.y *= (0.80 + 0.35 * age_birth);
	weights.z *= (0.45 + 1.30 * age_late);
	weights /= max(max(weights.x, max(weights.y, weights.z)), 0.0001);
	vec4 art_chunks = texture(spray_chunks, artwork_uv(spindrift_uv, (seed_chunks - 0.5) * 1.0, step(0.5, seed_chunks)));
	vec4 art_mist = texture(spray_mist, artwork_uv(spindrift_uv, (seed_mist - 0.5) * 1.0, step(0.5, seed_mist)));
	vec4 art_streaks = texture(spray_streaks, streak_artwork_uv(spindrift_uv, seed_streaks));
	vec3 contribution = vec3(art_chunks.a * weights.x, art_streaks.a * weights.y, art_mist.a * weights.z);
	float contribution_sum = contribution.x + contribution.y + contribution.z;
	float artwork_mask = max(max(contribution.x, contribution.y), contribution.z);
	// Alpha-weighted colour keeps transparent regions of one family from darkening
	// the region where another family is the visible one.
	vec3 artwork_color = contribution_sum > 0.0001
		? (art_chunks.rgb * contribution.x + art_streaks.rgb * contribution.y + art_mist.rgb * contribution.z) / contribution_sum
		: vec3(1.0);
	vec2 centered_uv = spindrift_uv * 2.0 - 1.0;
	float base_shape = artwork_mask * card_limits(centered_uv, edge_softness);
	float shape_mask = shape_detail(base_shape, centered_uv, random_value);
	// The source activity channel is consumed for diagnostic coloring only.
	float source_visibility = position_debug ? mix(0.55, 1.0, clamp(source, 0.0, 1.0)) : 1.0;
	float alpha;
	if (debug_visible) {
		// Debug keeps the readable artwork silhouette: no fades, no breakup.
		alpha = base_shape * occlusion;
	} else {
		alpha = opacity * source_visibility * lod * life_fade * water_fade * shape_mask * occlusion;
	}
	vec3 tint = particle_tint.rgb * artwork_color;
	if (position_debug) {
		if (source_distance_m < 30.0) {
			tint = vec3(1.0, 0.05, 1.0);
		} else if (source_distance_m < 70.0) {
			tint = vec3(1.0, 1.0, 0.05);
		} else {
			tint = vec3(0.05, 1.0, 1.0);
		}
	}
	if (alpha < 0.002) discard;
	ALBEDO = tint;
	ALPHA = alpha;
	ROUGHNESS = 0.88;
	SPECULAR = layer_kind == 2 ? 0.22 : 0.08;
}
