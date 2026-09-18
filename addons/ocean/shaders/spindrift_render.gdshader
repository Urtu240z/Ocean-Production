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

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float cloud_lobe(vec2 point, vec2 center, float radius, float feather) {
	return 1.0 - smoothstep(radius - feather, radius, length(point - center));
}

float optics_linear_depth(vec2 uv, float raw_depth, mat4 inverse_projection) {
	vec4 view = inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	return -view.z / max(view.w, 0.00001);
}

float layer_life_fade(float age) {
	float fade_start = layer_kind == 0 ? 0.52 : (layer_kind == 2 ? 0.42 : 0.58);
	float fade_end = layer_kind == 0 ? 0.86 : (layer_kind == 2 ? 0.76 : 0.90);
	return smoothstep(0.0, 0.025, age) * (1.0 - smoothstep(fade_start, fade_end, age));
}

void vertex() {
	spindrift_uv = UV;
	particle_source = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
	particle_random = INSTANCE_CUSTOM.y;
	particle_age = clamp(INSTANCE_CUSTOM.z, 0.0, 1.0);
	particle_source_distance = clamp(INSTANCE_CUSTOM.w, 0.0, 1.0);

	vec3 particle_position = MODEL_MATRIX[3].xyz;
	particle_world_xz = particle_position.xz;
	float visual_width = max(length(MODEL_MATRIX[0].xyz), 0.0001);
	float visual_height = max(length(MODEL_MATRIX[1].xyz), 0.0001);
	if (!force_visible && !position_debug) {
		float terminal_shrink = layer_kind == 0 ? 0.62 : (layer_kind == 2 ? 0.68 : 0.56);
		float size_fade = smoothstep(0.48, 0.96, particle_age);
		float size_scale = mix(1.0, terminal_shrink, size_fade);
		visual_width *= size_scale;
		visual_height *= size_scale;
	}
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
		float crest_patch_length = clamp(visual_height * 2.2, 0.8, 1.4);
		float crest_patch_height = clamp(visual_width, 0.30, 0.50);
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
		float streak_length = min(visual_height, visual_width * 2.4);
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
	float raw_opaque_scene_depth = textureLod(opaque_scene_depth, SCREEN_UV, 0.0).r;
	bool opaque_depth_valid = raw_opaque_scene_depth > 0.000001 && raw_opaque_scene_depth <= 1.000001 && !isnan(raw_opaque_scene_depth) && !isinf(raw_opaque_scene_depth);
	float opaque_scene_linear_depth = optics_linear_depth(SCREEN_UV, raw_opaque_scene_depth, INV_PROJECTION_MATRIX);
	float particle_linear_depth = optics_linear_depth(SCREEN_UV, FRAGCOORD.z, INV_PROJECTION_MATRIX);
	float depth_delta = particle_linear_depth - opaque_scene_linear_depth - opaque_depth_bias_m;
	float occlusion = 1.0;
	if (opaque_depth_valid && opaque_scene_linear_depth > 0.00001 && particle_linear_depth > 0.00001) {
		occlusion = 1.0 - smoothstep(0.0, max(opaque_depth_softness_m, 0.001), depth_delta);
	}
	vec2 centered_uv = spindrift_uv * 2.0 - 1.0;
	vec2 cloud_wobble = vec2(
		hash12(vec2(random_value * 17.1 + 2.0, 5.3)),
		hash12(vec2(random_value * 31.7 + 7.0, 11.9))
	) * 2.0 - 1.0;
	float cloud_scale = mix(0.92, 1.08, hash12(vec2(random_value * 13.7 + 1.0, 19.0)));
	float cloud_mask = cloud_lobe(centered_uv, cloud_wobble * 0.05, 0.72 * cloud_scale, 0.18);
	cloud_mask = max(cloud_mask, cloud_lobe(centered_uv, vec2(-0.31, 0.06) + cloud_wobble * 0.04, 0.43 * cloud_scale, 0.16));
	cloud_mask = max(cloud_mask, cloud_lobe(centered_uv, vec2(0.29, 0.13) - cloud_wobble * 0.03, 0.40 * cloud_scale, 0.15));
	cloud_mask = max(cloud_mask, cloud_lobe(centered_uv, vec2(0.05, -0.28) + cloud_wobble * 0.02, 0.36 * cloud_scale, 0.14));
	cloud_mask = smoothstep(0.04, 0.24, cloud_mask);
	float cloud_mottle = mix(0.88, 1.0, hash12(floor(spindrift_uv * vec2(7.0, 9.0)) + random_value * 17.0));
	cloud_mask *= cloud_mottle;
	float breakup = mix(0.72, 1.0, hash12(floor(spindrift_uv * vec2(11.0, 17.0)) + random_value * 9.0));
	float life_fade = layer_life_fade(age);
	float layer_shape = layer_kind == 2 ? 0.72 : (layer_kind == 0 ? 1.0 : 0.92);
	// Normal rendering preserves the H4.28A visual response. The source
	// activity channel is consumed for diagnostic coloring only.
	float source_visibility = position_debug ? mix(0.55, 1.0, clamp(source, 0.0, 1.0)) : 1.0;
	float alpha = (force_visible ? 1.0 : opacity * source_visibility * lod * breakup * life_fade * layer_shape) * cloud_mask * occlusion;
	vec3 tint = particle_tint.rgb;
	if (position_debug) {
		alpha = cloud_mask;
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
