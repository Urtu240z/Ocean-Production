shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// External, non-versioned AUDIT references. Both are linear samples.
uniform sampler2D waterline_disp_texture : filter_linear, repeat_enable;
// Displacement_Contrast has sRGB enabled in Waterline; preserve that decode.
uniform sampler2D breakup_texture : source_color, filter_linear, repeat_enable;

// Unreal Shore Wave Displacement=(500, 1, 800) cm -> (5, .01, 8) m.
uniform vec3 shore_wave_displacement_m = vec3(5.0, 0.01, 8.0);
uniform float shore_shallows_range = -0.256;
uniform float shore_normal_shift = 3.0;
uniform float wave_speed = 0.15;
uniform float audit_multiplier = 1.0;

// MF_Ocean_Displacement_Gen4 / Water_Parameters source values, converted cm -> m.
uniform float breakup_wave_height_m = 0.15;
uniform float displacement_wave_speed = 0.09;
uniform float water_tile_m = 20.0;
uniform float breakup_reference_available = 1.0;
// 0 = BASE SHORE; 1 = SHORE + BREAKUP; 2 = SHORE + BREAKUP + 4 WAY.
uniform int comparison_mode = 0;

varying float shore_mask_out;
varying float crest_out;

float waterline_breakup_selector_single(vec2 unreal_world_xy_m) {
	// MF_Ocean_Displacement_Gen4: Panner_0(TextureCoordinate =
	// Rotator(WorldXY, H Rot?) / WaterTile, Speed = WaveSpeed). H Rot? defaults to 0.
	vec2 uv = unreal_world_xy_m / water_tile_m;
	uv += vec2(displacement_wave_speed * TIME);
	return texture(breakup_texture, uv).r;
}

float waterline_breakup_selector_4_way(vec2 unreal_world_xy_m) {
	// WS_Texture_4WayChaos exact graph transcription:
	// ComponentMask13 = WorldXY / (abs(TextureSize) * -1), TextureSize = WaterTile.
	vec2 uv = unreal_world_xy_m / (vec2(abs(water_tile_m)) * -1.0);
	float scaled_time = displacement_wave_speed * TIME;

	// Each Panner has its SpeedX/SpeedY from the source function. Add_8 sums RGBA;
	// ComponentMask_2 then takes R, so summing red samples is algebraically identical.
	float s0 = texture(breakup_texture, uv + scaled_time * vec2(0.1, 0.1)).r;
	float s1 = texture(breakup_texture, uv + vec2(0.418100, 0.354800) + scaled_time * vec2(-0.1, -0.1)).r;
	float s2 = texture(breakup_texture, uv + vec2(0.864861, 0.148384) + scaled_time * vec2(-0.1, 0.1)).r;
	float s3 = texture(breakup_texture, uv + vec2(0.651340, 0.751638) + scaled_time * vec2(0.1, -0.1)).r;
	return s0 + s1 + s2 + s3;
}

void vertex() {
	// WATERLINE REF: Shore coordinates
	// Unreal Z-up / XY plane becomes Godot Y-up / XZ plane. Values are meters.
	vec2 shore_world = vec2(VERTEX.x, VERTEX.z);
	float shoreline_distance_m = VERTEX.z + 3.0;
	float shore_distance = clamp(shoreline_distance_m / 6.0, 0.0, 1.0);

	// Temporary deterministic Shore Manager emulation: straight shore, seaward -Z.
	// The real system obtains direction and distance masks from RT_Shore.
	vec2 shore_direction = vec2(0.0, -1.0);
	float shore_band = smoothstep(0.04, 0.30, shore_distance) *
		(1.0 - smoothstep(0.64, 0.96, shore_distance));
	float shore_mask = clamp(shore_band + shore_shallows_range * 0.0, 0.0, 1.0);

	// WATERLINE REF: MF_Shore_Gen3 wave profile sample. R drives planar surge, B crest.
	vec2 shore_uv = vec2(clamp(shore_distance, 0.0, 1.0), fract(VERTEX.x * 0.35 - TIME * wave_speed));
	vec4 wave_texture_sample = texture(waterline_disp_texture, shore_uv);
	vec2 horizontal_displacement = shore_direction * wave_texture_sample.r * shore_wave_displacement_m.x;
	float vertical_displacement = wave_texture_sample.b * shore_wave_displacement_m.z;
	vec3 shore_displacement = vec3(horizontal_displacement.x, vertical_displacement, horizontal_displacement.y) * shore_mask * audit_multiplier;

	// MF_Ocean_Displacement_Gen4, exact topology with its absent ocean-base input = 0:
	// MakeFloat3(base.X, base.Y, base.Z + Lerp(-WaveHeight, WaveHeight, selector));
	// then Add_9 adds Shore Displacement. UE's vertical Z maps to Godot Y.
	float selector = waterline_breakup_selector_single(shore_world);
	if (comparison_mode == 2) {
		selector = waterline_breakup_selector_4_way(shore_world);
	}
	float breakup_z = mix(-breakup_wave_height_m, breakup_wave_height_m, selector) * breakup_reference_available;
	if (comparison_mode >= 1) {
		shore_displacement.y += breakup_z;
	}

	VERTEX += shore_displacement;
	shore_mask_out = shore_mask;
	crest_out = clamp(abs(vertical_displacement) / max(shore_wave_displacement_m.z, 0.001), 0.0, 1.0);
}

void fragment() {
	vec3 deep = vec3(0.015, 0.13, 0.21);
	vec3 shallow = vec3(0.02, 0.55, 0.45);
	ALBEDO = mix(deep, shallow, shore_mask_out) + crest_out * vec3(0.13, 0.18, 0.14);
	ROUGHNESS = mix(0.16, 0.38, crest_out);
	METALLIC = 0.0;
	SPECULAR = 0.8;
}
