shader_type spatial;
// Bypass the live water depth, then test against the pre-transparent opaque
// depth snapshot below. Hull/rider/terrain occlude without per-object masks.
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled;

uniform sampler2D flipbook_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D breakup_mask : filter_linear, repeat_disable;
uniform sampler2D distortion_texture : filter_linear, repeat_enable;
uniform sampler2D sequence_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D sequence_next_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D sequence_previous_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D sequence_following_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D solid_depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
// Standalone materials retain the previous look; the controller enables water.
uniform bool water_appearance_enabled = false;
uniform bool has_normal_texture = false;
uniform float foam_opacity : hint_range(0.0, 1.0) = 1.0;
uniform float water_opacity : hint_range(0.0, 0.6) = 0.12;
uniform vec4 water_tint : source_color = vec4(0.75, 0.91, 1.0, 1.0);
uniform float normal_strength = 0.8;
uniform vec2 normal_tiling = vec2(4.0, 3.0);
uniform float normal_time = 0.0;
uniform float water_roughness : hint_range(0.03, 1.0) = 0.14;
uniform float highlight_strength : hint_range(0.0, 4.0) = 1.5;
uniform float solid_occlusion_bias = 0.005;
uniform bool has_image_sequence = false;
uniform float sequence_blend : hint_range(0.0, 1.0) = 0.0;
uniform vec4 sequence_frame_crop = vec4(0.42, 0.0, 0.0, 0.5);
uniform bool has_flipbook = false;
uniform bool has_breakup_mask = false;
uniform bool has_distortion = true;
uniform vec2 flipbook_grid = vec2(8.0, 8.0);
uniform int flipbook_frames = 64;
uniform float flipbook_fps = 20.0;
uniform float phase_offset = 0.0;
uniform float animation_time = 0.0;
uniform float frame_position = 0.0;
uniform float frame_phase = 0.0;
uniform float animation_smoothing : hint_range(0.0, 1.0) = 0.75;
uniform float side_sign = 1.0;
uniform float speed_factor : hint_range(0.0, 1.0) = 0.0;
uniform float contact_factor : hint_range(0.0, 1.0) = 0.0;
uniform float spray_opacity : hint_range(0.0, 1.0) = 0.65;
uniform float spray_scale = 1.0;
uniform vec4 layer_scale_factors = vec4(1.0);
uniform float layer_scale_factor_5 = 1.0;
uniform float distortion_strength = 0.025;
uniform float breakup_strength : hint_range(0.0, 1.0) = 0.7;
uniform bool alpha_from_luminance = false;
uniform float alpha_cutoff = 0.04;
uniform float alpha_softness = 0.08;
uniform float alpha_gain = 1.0;
uniform float edge_softness = 0.15;
uniform float side_fade_strength : hint_range(0.0, 1.0) = 1.0;
uniform float side_fade_angle = 0.349066;
uniform vec3 attachment_offset = vec3(0.0);
uniform vec4 frame_crop = vec4(0.0);
uniform bool flipbook_flip_y = true;
uniform float steering = 0.0;
uniform float steering_tilt_strength = 0.14;
uniform float sheet_length = 1.9;
uniform float sheet_width = 0.85;
uniform float sheet_height = 0.48;
uniform vec4 spray_color : source_color = vec4(0.88, 0.96, 1.0, 1.0);
uniform float spray_whiteness : hint_range(0.0, 1.0) = 0.0;
uniform float spray_saturation : hint_range(0.0, 2.0) = 1.0;
uniform float spray_brightness : hint_range(0.0, 4.0) = 1.0;
uniform int volume_layers = 3;
uniform float volume_depth = 0.18;
uniform float volume_verticality : hint_range(0.0, 1.0) = 0.65;
uniform float undulation_strength = 0.06;
uniform float undulation_frequency = 3.0;
uniform float undulation_speed = 0.8;
uniform float volume_time = 0.0;

vec4 premultiplied(vec4 sample_color) {
	return vec4(sample_color.rgb * sample_color.a, sample_color.a);
}

vec4 blend_animation(vec4 previous, vec4 current, vec4 next, vec4 following, float t) {
	vec4 a = premultiplied(current);
	vec4 b = premultiplied(next);
	vec4 linear_mix = mix(a, b, t);
	float inverse_t = 1.0 - t;
	float t2 = t * t;
	float t3 = t2 * t;
	// Cubic B-spline: continuous temporal derivatives across frame boundaries.
	vec4 cubic_mix = premultiplied(previous) * (inverse_t * inverse_t * inverse_t / 6.0)
		+ a * ((3.0 * t3 - 6.0 * t2 + 4.0) / 6.0)
		+ b * ((-3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0) / 6.0)
		+ premultiplied(following) * (t3 / 6.0);
	vec4 result = mix(linear_mix, cubic_mix, animation_smoothing);
	return vec4(result.rgb / max(result.a, 0.00001), result.a);
}

vec2 sprite_uv(vec2 uv, vec4 crop) {
	vec2 crop_start = clamp(crop.xy, vec2(0.0), vec2(0.95));
	vec2 crop_end = max(crop_start + vec2(0.001), vec2(1.0) - clamp(crop.zw, vec2(0.0), vec2(0.95)));
	vec2 oriented_uv = vec2(uv.x, flipbook_flip_y ? 1.0 - uv.y : uv.y);
	return mix(crop_start, crop_end, oriented_uv);
}

// Rows advance from the top-left. Clamp inside each cell to avoid atlas bleeding.
vec4 atlas_frame(vec2 uv, float frame) {
	vec2 grid = max(flipbook_grid, vec2(1.0));
	vec2 cell = vec2(mod(frame, grid.x), floor(frame / grid.x));
	vec2 inset = min(0.5 * grid / vec2(textureSize(flipbook_texture, 0)), vec2(0.49));
	vec2 cropped_uv = sprite_uv(uv, frame_crop);
	return texture(flipbook_texture, (cell + clamp(cropped_uv, inset, vec2(1.0) - inset)) / grid);
}

vec3 sheet_position(vec2 uv, float layer) {
	// The subdivided quad becomes a flared sheet: U travels aft (+Z), V outboard.
	float u = uv.x;
	float v = uv.y;
	// Shape endpoints are already interpolated by the controller.
	int layer_index = int(round((layer + 1.0) * 0.5 * float(max(volume_layers - 1, 0))));
	float layer_scale = layer_scale_factor_5;
	if (layer_index == 0) { layer_scale = layer_scale_factors.x; }
	else if (layer_index == 1) { layer_scale = layer_scale_factors.y; }
	else if (layer_index == 2) { layer_scale = layer_scale_factors.z; }
	else if (layer_index == 3) { layer_scale = layer_scale_factors.w; }
	// Grow/shrink around the emission origin, leaving the editable anchor fixed.
	float size = spray_scale * layer_scale;
	float envelope = sin(u * 3.141593) * v;
	float width = sheet_width * mix(1.0, 0.35, volume_verticality) * (0.16 + 0.84 * sin(u * 1.570796));
	vec3 sheet = vec3(side_sign * (0.20 * u + v * width),
		sheet_height * envelope + 0.035 * v,
		sheet_length * u + 0.20 * v * u);
	// Ribbons fan out from the same hull anchor; thickness vanishes at the root.
	float thickness = layer * volume_depth * envelope;
	sheet += vec3(side_sign * thickness, thickness * 0.25, thickness * 0.45);
	// Clock already integrates undulation_speed, so rate edits do not jump phase.
	float phase = u * undulation_frequency * 6.283185 - volume_time * 6.283185 + layer * 1.7;
	float sway = sin(phase) * undulation_strength * envelope * mix(0.3, 1.0, speed_factor);
	sheet.x += side_sign * sway;
	sheet.y += cos(phase * 0.83) * undulation_strength * envelope * 0.2;
	sheet *= size;
	float tilt = -steering * steering_tilt_strength * speed_factor;
	vec2 rolled = mat2(vec2(cos(tilt), sin(tilt)), vec2(-sin(tilt), cos(tilt))) * sheet.xy;
	return vec3(rolled, sheet.z);
}

void vertex() {
	vec3 sheet = sheet_position(UV, UV2.x);
	// Smooth normals follow the curved/waving ribbons instead of the flat source
	// grid. Finite differences avoid per-triangle bands in the angle fade.
	vec3 along = sheet_position(UV + vec2(0.001, 0.0), UV2.x) - sheet;
	vec3 across = sheet_position(UV + vec2(0.0, 0.001), UV2.x) - sheet;
	NORMAL = normalize(cross(along, across));
	// Tangent frame follows the animated curve, not the original flat grid.
	TANGENT = normalize(along);
	BINORMAL = normalize(cross(NORMAL, TANGENT));
	// Offset is independent of spray size/steering and never changes node transforms.
	VERTEX = sheet + attachment_offset;
}

void fragment() {
	// Depth reconstruction works for perspective/orthographic and reverse-Z.
	float solid_depth = texture(solid_depth_texture, SCREEN_UV).r;
	if (solid_depth > 0.0000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(SCREEN_UV, solid_depth) * 2.0 - 1.0;
		#else
		vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, solid_depth);
		#endif
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
		float scene_distance = -scene_view.z / scene_view.w;
		if (scene_distance + solid_occlusion_bias < -VERTEX.z) {
			discard;
		}
	}
	float clock = animation_time + phase_offset + UV2.y * 0.17;
	vec2 noise_uv = UV * vec2(2.8, 2.0) - vec2(clock * 0.65, clock * 0.12);
	vec2 noise = vec2(0.5);
	if (has_distortion) {
		noise = vec2(texture(distortion_texture, noise_uv).r,
			texture(distortion_texture, noise_uv + vec2(0.37, 0.61)).g);
	}
	vec2 warped = clamp(UV + (noise - 0.5) * distortion_strength, vec2(0.0), vec2(1.0));
	vec4 spray = vec4(1.0);
	if (has_image_sequence) {
		vec2 uv = sprite_uv(warped, sequence_frame_crop);
		vec4 a = texture(sequence_texture, uv);
		vec4 b = texture(sequence_next_texture, uv);
		vec4 previous = a;
		vec4 following = b;
		if (animation_smoothing > 0.0) {
			previous = texture(sequence_previous_texture, uv);
			following = texture(sequence_following_texture, uv);
		}
		spray = blend_animation(previous, a, b, following, sequence_blend);
	} else if (has_flipbook) {
		float count = max(float(flipbook_frames), 1.0);
		float frame = mod(frame_position + frame_phase, count);
		float current = floor(frame);
		spray = blend_animation(atlas_frame(warped, mod(current - 1.0 + count, count)),
			atlas_frame(warped, current), atlas_frame(warped, mod(current + 1.0, count)),
			atlas_frame(warped, mod(current + 2.0, count)), fract(frame));
	} else {
		// Animated provisional water filaments while the final RGBA atlas is absent.
		float filaments = pow(0.5 + 0.5 * sin(warped.y * 86.0 + noise.x * 12.0
			- clock * 15.0 + warped.x * 8.0), 5.0);
		float droplets = smoothstep(0.58, 0.78, noise.x);
		spray.a = (0.12 + filaments * 0.70 + droplets * 0.30)
			* mix(1.0, smoothstep(0.26, 0.68, noise.y), warped.y);
	}
	if ((has_image_sequence || has_flipbook) && alpha_from_luminance) {
		spray.a *= max(spray.r, max(spray.g, spray.b));
	}
	float breakup = 1.0;
	if (has_breakup_mask) {
		vec2 breakup_uv = clamp(warped + (noise - 0.5) * 0.045 * breakup_strength,
			vec2(0.0), vec2(1.0));
		breakup = mix(1.0, texture(breakup_mask, breakup_uv).r, breakup_strength);
	}
	float coverage = clamp(spray.a * alpha_gain, 0.0, 1.0);
	// Maintain at least a pixel-wide cutoff transition, even with very low softness.
	float cutoff_softness = max(max(alpha_softness, 0.001), fwidth(coverage));
	coverage *= smoothstep(alpha_cutoff, alpha_cutoff + cutoff_softness, coverage);
	float feather = clamp(edge_softness, 0.02, 0.4);
	float edge = smoothstep(0.0, max(0.045, feather * 0.5), UV.x)
		* (1.0 - smoothstep(1.0 - max(0.32, feather), 1.0, UV.x))
		* smoothstep(0.0, max(0.06, feather), UV.y)
		* (1.0 - smoothstep(1.0 - max(0.22, feather * 1.5), 1.0, UV.y));
	// VIEW also handles orthographic editor cameras. Double-sided faces share fade.
	float facing = abs(dot(normalize(NORMAL), VIEW));
	float side_fade = mix(1.0, smoothstep(0.0, sin(side_fade_angle), facing), side_fade_strength);
	float luminance = dot(spray.rgb, vec3(0.2126, 0.7152, 0.0722));
	vec3 tinted = max(mix(vec3(luminance), spray.rgb, spray_saturation), vec3(0.0)) * spray_color.rgb;
	vec3 foam_color = mix(tinted, vec3(1.0), spray_whiteness) * spray_brightness;
	float visibility = breakup * edge * side_fade * spray_opacity * speed_factor * contact_factor * spray_color.a;
	float foam_alpha = clamp(coverage * visibility * (water_appearance_enabled ? foam_opacity : 1.0), 0.0, 1.0);
	// A softer alpha mask retains thin transparent water between the foam specks.
	// Both layers use sprite coverage and the existing edge/breakup/air fades.
	float water_mask = smoothstep(0.005, 0.18, clamp(spray.a * alpha_gain, 0.0, 1.0));
	float water_alpha = water_appearance_enabled ? clamp(water_mask * visibility * water_opacity, 0.0, 1.0) : 0.0;
	float alpha = foam_alpha + water_alpha * (1.0 - foam_alpha);
	float foam_fraction = foam_alpha / max(alpha, 0.00001);
	float water_fraction = water_alpha * (1.0 - foam_alpha) / max(alpha, 0.00001);
	// Preserve the PNG colour with emission, while the water uses real scene
	// lighting/reflections. Opacity and specular controls remain independent.
	ALBEDO = water_tint.rgb * water_fraction * 0.015;
	EMISSION = foam_color * foam_fraction;
	METALLIC = 0.0;
	SPECULAR = water_appearance_enabled ? clamp(highlight_strength * 0.25, 0.0, 1.0) * water_mask : 0.0;
	ROUGHNESS = water_appearance_enabled ? clamp(water_roughness, 0.03, 1.0) : 1.0;
	if (dot(NORMAL, VIEW) < 0.0) {
		NORMAL = -NORMAL;
		BINORMAL = -BINORMAL;
	}
	NORMAL_MAP = vec3(0.5, 0.5, 1.0);
	NORMAL_MAP_DEPTH = 0.0;
	if (water_appearance_enabled && has_normal_texture) {
		float normal_phase = normal_time + phase_offset + UV2.y * 0.37;
		vec2 tiling = max(abs(normal_tiling), vec2(0.01));
		vec3 normal_a = texture(normal_texture, UV * tiling + vec2(normal_phase * 0.17, -normal_phase * 0.29)).rgb;
		vec3 normal_b = texture(normal_texture, UV * tiling * 1.31 + vec2(-normal_phase * 0.11, normal_phase * 0.21) + vec2(0.31, 0.73)).rgb;
		NORMAL_MAP = mix(normal_a, normal_b, 0.35);
		NORMAL_MAP_DEPTH = normal_strength;
	}
	// Preserve total density where several ribbons overlap.
	ALPHA = 1.0 - pow(1.0 - alpha, 1.0 / max(float(volume_layers), 1.0));
}
