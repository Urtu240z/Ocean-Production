shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// External, non-versioned AUDIT reference.  R affects horizontal surge;
// B affects vertical crest, as traced from MF_Shore_Gen3.
uniform sampler2D waterline_disp_texture : filter_linear, repeat_enable;

// Unreal Shore Wave Displacement=(500, 1, 800) cm -> (5, .01, 8) m.
uniform vec3 shore_wave_displacement_m = vec3(5.0, 0.01, 8.0);
uniform float shore_shallows_range = -0.256;
uniform float shore_normal_shift = 3.0;
uniform float wave_speed = 0.15;
uniform float audit_multiplier = 1.0;

varying float shore_mask_out;
varying float crest_out;

void vertex() {
	// WATERLINE REF: Shore coordinates
	// Unreal Z-up / XY plane becomes Godot Y-up / XZ plane.  Values are meters.
	vec2 shore_world = vec2(VERTEX.x, VERTEX.z);
	float shoreline_distance_m = VERTEX.z + 3.0;
	float shore_distance = clamp(shoreline_distance_m / 6.0, 0.0, 1.0);

	// Temporary deterministic Shore Manager emulation: straight shore, seaward -Z.
	// The real system obtains direction and distance masks from RT_Shore.
	vec2 shore_direction = vec2(0.0, -1.0);
	float shore_band = smoothstep(0.04, 0.30, shore_distance) *
		(1.0 - smoothstep(0.64, 0.96, shore_distance));
	float shore_mask = clamp(shore_band + shore_shallows_range * 0.0, 0.0, 1.0);

	// WATERLINE REF: Wave profile sample
	// MF_Shore_Gen3's RT Shore UV is replaced only at this input boundary.
	// T_PL_Wave_1_Disp keeps repeat sampling; Unreal asset has X clamp/Y wrap.
	vec2 shore_uv = vec2(clamp(shore_distance, 0.0, 1.0), fract(VERTEX.x * 0.35 - TIME * wave_speed));
	vec4 wave_texture_sample = texture(waterline_disp_texture, shore_uv);
	float profile_r = wave_texture_sample.r;
	float profile_b = wave_texture_sample.b;

	// WATERLINE REF: Direction
	// MF_Shore_Gen3: AppendVector8 = (shore_direction * sample.R, sample.B).
	vec2 horizontal_profile = shore_direction * profile_r;

	// WATERLINE REF: Horizontal displacement
	// Graph duplicates the R/X parameter across the two planar components.
	vec2 horizontal_displacement = horizontal_profile * shore_wave_displacement_m.x;

	// WATERLINE REF: Vertical displacement
	// The B/Z branch is independent of the horizontal R/X branch.
	float vertical_displacement = profile_b * shore_wave_displacement_m.z;

	// WATERLINE REF: Breakup
	// Safe, local gate for the reference demo.  It preserves a finite surface.
	float breakup = 0.72 + 0.28 * sin((shore_uv.y + shore_distance * 1.7) * TAU);
	vec3 shore_displacement = vec3(
		horizontal_displacement.x,
		vertical_displacement,
		horizontal_displacement.y
	) * shore_mask * breakup * audit_multiplier;

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
