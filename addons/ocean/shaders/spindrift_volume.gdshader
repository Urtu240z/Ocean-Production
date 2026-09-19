shader_type fog;
// H4.33/H4.34/H4.35 Ocean V4 persistent volumetric spindrift, RENDER pass.
//
// This shader does not reconstruct density from Crest G, and it does NOT build a
// water-surface model. It samples the authoritative persistent Eulerian state
// produced by spindrift_volume_advect.glsl through a Texture3DRD wrapper:
//
//   R = density mass          -> fog opacity
//   G = wave-coupled mass     -> microstructure shaping only
//
// Crest G is an INJECTION source for the compute pass, never the final render
// density. That is what lets mist survive after its crest disappears.
//
// H4.35 VERTICAL AUTHORITY: the persistent state texture is the sole authority
// for WHERE aerosol exists in Y. The compute pass already injects relative to the
// displaced water surface, so the stored density is already at the correct
// world-space height. This shader must therefore never attenuate density by a
// height measured from flat sea_level (that wrongly killed mist sitting on a
// +6 m crest). The only vertical term left is a thin fade at the FogVolume's own
// Y boundary so the sampling box cannot show a hard cut. No displacement is
// resampled here; that would duplicate the simulation source logic.
//
// The granular, droplet-like read is produced by eroding the persistent macro
// density with a fine advected 3D microstructure. It is deliberately density
// only: there is no procedural colour noise and no per-droplet colour variation.
// The macro body and the fine droplet field each carry their OWN flat authored
// base colour, blended per froxel by density share (see the Material block and
// the multi-scale combination at the end of fog()). No particles, no sprites, no
// impostor cards.
//
// H4.34/H4.35 microstructure drift: a rigid wind translation (valid because its
// direction is approximately constant) plus a MATHEMATICALLY BOUNDED curl warp.
// The instantaneous curl field is never multiplied by total elapsed time, and the
// warp length is guaranteed <= CURL_WARP_MAX_M for every legal profile value.
//
// Godot 4.7 fog shader facts verified against this project's engine build:
//   * the entry point of a fog shader is `void fog()`, NOT `void fragment()`;
//   * built-ins inside `fog()`: WORLD_POSITION (vec3, world-space froxel
//     centre) plus the outputs DENSITY (float), ALBEDO (vec3), EMISSION (vec3);
//   * `return` is rejected inside a fog processor function, so the whole field
//     is one guarded expression;
//   * sampler3D uniforms with filter_linear / repeat_disable and texture()
//     fetches are valid here.
// SIZE / UVW / OBJECT_POSITION / SDF are deliberately unused: the simulation
// origin and extent are passed as explicit uniforms so the world -> grid
// mapping is exact and matches the compute pass bit for bit.

// --- Persistent GPU state --------------------------------------------------
// TWO persistent scales are sampled. Macro owns the large mist body; micro owns
// the fine droplet clusters, which carry their own independent history and are
// allowed to exist where macro density is zero.
//
// Each field carries its OWN wave-coupled channel (G), so each field has its OWN
// wave affinity and its OWN steady-state normalisation:
//
//   macro_wave_affinity = (macro.G / max(macro.R, eps)) / affinity_steady_ratio
//   micro_wave_affinity = (micro.G / max(micro.R, eps)) / micro_affinity_steady_ratio
//
// H4.37: these are strictly independent. macro_wave_affinity is never used to
// shape the micro field, so micro spray keeps a valid affinity even where
// macro_density == 0 or the macro field is unrelated.
uniform sampler3D persistent_state : filter_linear, repeat_disable;
uniform sampler3D micro_state : filter_linear, repeat_disable;
uniform sampler3D micro_ridged_texture : filter_linear, repeat_enable;
uniform sampler3D micro_cellular_texture : filter_linear, repeat_enable;
uniform vec3 sim_origin = vec3(0.0);
uniform vec3 sim_extent = vec3(96.0, 16.0, 96.0);
uniform float sim_time_s = 0.0;
// MACRO steady-state affinity ratio. Same formula and clamp as the macro compute
// pass uses for its own affinity proxy.
uniform float affinity_steady_ratio = 0.075;
// MICRO steady-state affinity ratio. Same formula and clamp as the micro compute
// pass uses (micro_density_decay / micro_wave_memory_decay).
uniform float micro_affinity_steady_ratio = 0.23;

// --- Placement -------------------------------------------------------------
// No sea_level and no height: persistent state owns vertical placement.
uniform float volume_density = 0.08;
// Master opacity of the fine droplet scale. micro_enabled == 0 removes the micro
// contribution entirely, which is the documented fallback when the micro GPU
// resources could not be created (macro volumetric spindrift keeps working).
uniform float micro_volume_density = 0.35;
uniform float micro_enabled = 0.0;
uniform float edge_fade = 0.30;

// --- Flow used by the microstructure --------------------------------------
// wind_advection has the same authoring meaning as in the compute pass: the
// fraction of the real atmospheric wind speed imparted to the aerosol.
// curl_strength keeps its compute meaning too (m/s of advection velocity); here
// it is only NORMALISED against CURL_REFERENCE_SPEED_MPS to drive a 0..1 visual
// response, so the render warp stays bounded. See CURL_REFERENCE_SPEED_MPS.
uniform vec2 wind_direction = vec2(1.0, 0.0);
uniform float wind_speed_mps = 18.0;
uniform float wind_advection = 0.08;
// H4.42: camera position is a detail-LOD input only. It never participates in
// the world-space Texture3D coordinate.
uniform vec3 camera_world_position = vec3(0.0);
uniform float curl_strength = 1.0;
uniform float curl_scale = 0.03;
uniform float curl_speed = 0.12;
// H4.39A. Micro-only temporal control, shared with the micro compute pass so
// simulated matter and visual breakup stay in the same temporal family.
//   * fast micro detail warp phase = sim_time * curl_speed * this
// It never multiplies wind transport, wave push or decay, and macro is untouched.
uniform float micro_turbulence_speed_multiplier = 4.0;
// H4.39A. Maximum render-side warp applied to MICRO sub-detail, in METRES.
// Bounded by construction: length(fast_warp) <= this, always.
uniform float micro_warp_strength_m = 0.75;

// --- Granular microstructure ----------------------------------------------
uniform float granule_strength = 0.60;
uniform float granule_scale = 0.45;
uniform float granule_speed = 0.35;
uniform float granule_threshold = 0.42;
// 0 = H4.39 procedural, 1 = reusable 3D textures, 2 = both.
uniform int micro_structure_mode = 0;
uniform float micro_structure_strength = 1.0;
uniform float micro_structure_world_size_m = 10.0;
uniform float micro_structure_threshold = 0.5;
uniform float micro_structure_softness = 0.1;
uniform float micro_cellular_weight = 0.3;
uniform float micro_structure_lod_start_m = 18.0;
uniform float micro_structure_lod_end_m = 45.0;

// --- Material --------------------------------------------------------------
// The two persistent scales may carry DIFFERENT authored base colours. A froxel
// has a single ALBEDO output, so the two are blended by their relative density
// contribution (see the multi-scale combination below). This is a blend between
// two flat authored colours, never procedural colour noise inside a field.
uniform vec3 macro_albedo_color = vec3(0.92, 0.95, 0.98);
uniform vec3 micro_albedo_color = vec3(0.92, 0.95, 0.98);
uniform float emission_strength = 0.0;

// Fixed, small constants. Nothing here is a knob the author has to tune.
const float EPSILON = 0.0001;
const float CURL_SECOND_OCTAVE = 0.35;
const float CURL_SECOND_SCALE = 1.91;
const vec3 CURL_SECOND_OFFSET = vec3(13.7, -7.1, 3.9);
// Maximum render-side curl warp, in metres. length(curl_warp) <= this, always.
const float CURL_WARP_MAX_M = 2.0;
// Authored curl strength (m/s) that maps to the FULL CURL_WARP_MAX_M. Above it
// the visual response saturates; the compute pass keeps using the raw m/s.
const float CURL_REFERENCE_SPEED_MPS = 2.0;
// Soft Y feather at the FogVolume boundary, as a fraction of the volume height.
// This only prevents a visible box cut. It is NOT a sea-surface model.
const float VERTICAL_EDGE_FADE = 0.08;
const float GRANULE_EROSION_WIDTH = 0.32;
// Bounded porosity the dense droplet field may carve out of the macro mist body.
// Small on purpose: it must never be able to erase the macro volume.
const float MICRO_POROSITY_MAX = 0.25;
// Fixed, small breakup applied to the macro body so it never reads as perfectly
// smooth. Deliberately NOT driven by granule_strength, which belongs to micro.
const float MACRO_FIXED_BREAKUP = 0.15;
// H4.39A. Spatial scale of the FAST micro warp, as a multiple of curl_scale.
// Matches the micro compute pass's MICRO_CURL_SCALE_MULT, so the visual breakup
// sits at the same scale as the simulated micro rotation.
const float MICRO_WARP_SCALE_MULT = 2.0;
// H4.39A. Downwind elongation of the MICRO detail only. Greater than 1 means the
// noise coordinate advances more slowly along the wind, so micro clusters come
// out as wind-aligned filaments and ribbons instead of round smoke puffs.
const float MICRO_WIND_STRETCH = 2.5;
// Incommensurate second-octave offsets: a rotating/scaled lattice would show
// as a repeating pattern, an irrational offset does not.
const vec3 GRANULE_OCTAVE_OFFSET = vec3(19.37, 7.13, 41.71);
const float GRANULE_OCTAVE_SCALE = 2.37;
const float GRANULE_OCTAVE_WEIGHT = 0.45;

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec3 p) {
	vec3 cell = floor(p);
	vec3 f = p - cell;
	vec3 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float n000 = hash13(cell);
	float n100 = hash13(cell + vec3(1.0, 0.0, 0.0));
	float n010 = hash13(cell + vec3(0.0, 1.0, 0.0));
	float n110 = hash13(cell + vec3(1.0, 1.0, 0.0));
	float n001 = hash13(cell + vec3(0.0, 0.0, 1.0));
	float n101 = hash13(cell + vec3(1.0, 0.0, 1.0));
	float n011 = hash13(cell + vec3(0.0, 1.0, 1.0));
	float n111 = hash13(cell + vec3(1.0, 1.0, 1.0));
	float x00 = mix(n000, n100, w.x);
	float x10 = mix(n010, n110, w.x);
	float x01 = mix(n001, n101, w.x);
	float x11 = mix(n011, n111, w.x);
	return mix(mix(x00, x10, w.y), mix(x01, x11, w.y), w.z);
}

// One octave of the analytic divergence-free field. Each component deliberately
// omits its own coordinate, so d/dx of x, d/dy of y and d/dz of z are all zero
// and the divergence vanishes identically.
vec3 divergence_free_octave(vec3 p) {
	return vec3(-sin(p.y) - cos(p.z), -sin(p.z) - cos(p.x), -sin(p.x) - cos(p.y));
}

// H4.35: the second octave uses a UNIFORM SCALE plus TRANSLATION, which
// preserves div == 0 (a coordinate permutation would not, because it mixes the
// derivative directions). Byte-for-byte the same construction as the advection
// pass, so the microstructure rides the same rotational flow as the density.
vec3 divergence_free_field(vec3 p) {
	vec3 first = divergence_free_octave(p);
	vec3 second = divergence_free_octave(p * CURL_SECOND_SCALE + CURL_SECOND_OFFSET);
	return first + second * CURL_SECOND_OCTAVE;
}

bool inside_unit_cube(vec3 value) {
	return all(greaterThanEqual(value, vec3(0.0))) && all(lessThanEqual(value, vec3(1.0)));
}

void fog() {
	vec3 world_pos = WORLD_POSITION;
	vec3 extent = max(sim_extent, vec3(EPSILON));
	vec3 uvw = (world_pos - sim_origin) / extent;

	// Persistent MACRO state. Trilinear sampling of the RG16F volume, clamped so a
	// froxel on the exact boundary cannot read a neighbouring texel.
	vec2 macro_state_value = vec2(0.0);
	if (inside_unit_cube(uvw)) {
		macro_state_value = max(texture(persistent_state, uvw).rg, vec2(0.0));
	}
	float macro_density = macro_state_value.r;
	// The MACRO field's own wave affinity. Never used for micro breakup.
	float macro_wave_affinity = clamp(
		macro_state_value.g / max(macro_density, EPSILON) / max(affinity_steady_ratio, 0.0001),
		0.0,
		1.0);

	// --- Volume boundary feather ------------------------------------------
	// Purely a box-edge softener in the volume's own normalized coordinates.
	// There is no water-surface model here and no sea_level reference: the
	// persistent field decides where aerosol actually is.
	float bottom_fade = smoothstep(0.0, VERTICAL_EDGE_FADE, uvw.y);
	float top_fade = 1.0 - smoothstep(1.0 - VERTICAL_EDGE_FADE, 1.0, uvw.y);
	float vertical_boundary_fade = bottom_fade * top_fade;

	// H4.39B: horizontal fade is measured against the nearest XZ BOX EDGE, not a
	// radial distance from the centre. The old radial form inscribed a circle in
	// the rectangular footprint and discarded the corners, which wasted most of
	// the domain whenever the wind was diagonal. edge_distance is 0.5 at the
	// centre and 0 on any edge, so the whole rectangle stays usable and the fade
	// stays a predictable inset from each wall.
	float edge_distance = min(min(uvw.x, 1.0 - uvw.x), min(uvw.z, 1.0 - uvw.z));
	float horizontal_fade_width = 0.5 * clamp(edge_fade, 0.02, 0.95);
	float edge = smoothstep(0.0, max(horizontal_fade_width, 0.0001), edge_distance);
	int structure_mode = clamp(micro_structure_mode, 0, 2);

	// --- Granular microstructure -----------------------------------------
	// Fine 3D structure carried by the same wind the density uses, plus a
	// BOUNDED curl warp. The wind term is a rigid translation integrated over
	// elapsed time, which is valid because its direction is approximately
	// constant. The curl term is NOT integrated over time: the instantaneous
	// curl field rotates and evolves, so multiplying it by total elapsed time
	// would be invalid advection and would make the microstructure crawl and
	// swim as time grows. It stays a bounded spatial displacement instead, and
	// only its own phase advances with curl_speed.
	vec2 wind = normalize(wind_direction + vec2(0.000001, 0.000001));
	vec3 wind_velocity = vec3(wind.x, 0.0, wind.y) * (max(wind_speed_mps, 0.0) * max(wind_advection, 0.0));
	vec3 wind_translation = wind_velocity * (sim_time_s * max(granule_speed, 0.0));
	vec3 curl_p = world_pos * max(curl_scale, EPSILON) + vec3(0.0, 0.0, sim_time_s * curl_speed);

	// Direction and amplitude are separated so the warp is bounded by
	// construction. Dividing by max(length, 1.0) can only ever shrink a vector
	// (it equals the length when length < 1 and 1.0 otherwise), so
	// length(curl_dir) <= 1.0 for every input, including a zero field.
	vec3 raw_curl = divergence_free_field(curl_p);
	vec3 curl_dir = raw_curl / max(length(raw_curl), 1.0);
	// Authored curl strength is m/s; normalise it against a reference speed so
	// the render response stays dimensionless and saturated in 0..1.
	float visual_curl_factor = clamp(max(curl_strength, 0.0) / CURL_REFERENCE_SPEED_MPS, 0.0, 1.0);
	// Therefore length(curl_warp) <= 1.0 * CURL_WARP_MAX_M * 1.0 == CURL_WARP_MAX_M.
	vec3 curl_warp = curl_dir * (CURL_WARP_MAX_M * visual_curl_factor);

	// Macro keeps its existing bounded curl coordinate. The H4.39 procedural
	// micro path also keeps its existing animated wind/fast-warp coordinate.
	vec3 macro_detail_position = world_pos - wind_translation + curl_warp;
	vec3 micro_detail_position = world_pos;
	if (structure_mode == 0 || structure_mode == 2) {
		// PROCEDURAL/HYBRID only: preserve the H4.39 animated procedural path.
		float micro_phase = sim_time_s * max(curl_speed, 0.0) * max(micro_turbulence_speed_multiplier, 0.0);
		vec3 fast_warp_p = world_pos * max(curl_scale, EPSILON) * MICRO_WARP_SCALE_MULT
			+ vec3(micro_phase * 0.83, -micro_phase * 1.17, micro_phase * 0.71);
		vec3 raw_fast_warp = divergence_free_field(fast_warp_p);
		vec3 fast_warp_dir = raw_fast_warp / max(length(raw_fast_warp), 1.0);
		vec3 fast_warp = fast_warp_dir * max(micro_warp_strength_m, 0.0);
		micro_detail_position = world_pos - wind_translation + fast_warp;
	}

	// --- Two droplet masks, two coordinates (H4.39A) -----------------------
	// MACRO keeps the slow bounded coordinate: a soft large mist body must not
	// vibrate. MICRO uses the fast warp above AND a wind-aligned anisotropic
	// frame, so the detail reads as torn ribbons and filaments stretched downwind
	// instead of round smoke puffs.
	//
	// Only the micro coordinate is stretched. Stretching the macro coordinate too
	// would turn the mist body into ribbons, which is not wanted.
	float droplet_scale = max(granule_scale, 0.0001);
	float droplet_threshold_hi = min(granule_threshold + GRANULE_EROSION_WIDTH, 0.999);

	float macro_noise_mono = mix(
		value_noise(macro_detail_position * droplet_scale),
		value_noise(macro_detail_position * (droplet_scale * GRANULE_OCTAVE_SCALE) + GRANULE_OCTAVE_OFFSET),
		GRANULE_OCTAVE_WEIGHT);
	float macro_droplet_mask = smoothstep(granule_threshold, droplet_threshold_hi, macro_noise_mono);

	// Wind-aligned frame for the legacy procedural coordinate. Along is divided
	// by MICRO_WIND_STRETCH, so procedural noise changes more slowly downwind.
	vec2 wind_axis = wind;
	vec2 wind_across = vec2(-wind.y, wind.x);
	float detail_along = dot(micro_detail_position.xz, wind_axis) / MICRO_WIND_STRETCH;
	float detail_across = dot(micro_detail_position.xz, wind_across);
	vec3 micro_detail_coord = vec3(
		wind_axis.x * detail_along + wind_across.x * detail_across,
		micro_detail_position.y,
		wind_axis.y * detail_along + wind_across.y * detail_across);

	float micro_droplet_mask = 1.0;
	float textured_structure = 1.0;
	if (structure_mode == 0 || structure_mode == 2) {
		// H4.39 procedural baseline: exactly the two micro value_noise samples
		// used before H4.40.
		float micro_noise_mono = mix(
			value_noise(micro_detail_coord * droplet_scale),
			value_noise(micro_detail_coord * (droplet_scale * GRANULE_OCTAVE_SCALE) + GRANULE_OCTAVE_OFFSET),
			GRANULE_OCTAVE_WEIGHT);
		micro_droplet_mask = smoothstep(granule_threshold, droplet_threshold_hi, micro_noise_mono);
	}
	if (structure_mode == 1 || structure_mode == 2) {
		// H4.42 TEXTURE_3D path: stable world-space orientation only. There is
		// deliberately no sim_time scroll, wind*time translation, camera term, or
		// fast warp here. Texture3D is a density mask, not a second simulation.
		float structure_world_size = max(micro_structure_world_size_m, 1.0);
		float structure_along = dot(world_pos.xz, wind_axis) / MICRO_WIND_STRETCH;
		float structure_across = dot(world_pos.xz, wind_across);
		vec3 stable_world_frame = vec3(
			wind_axis.x * structure_along + wind_across.x * structure_across,
			world_pos.y,
			wind_axis.y * structure_along + wind_across.y * structure_across);
		vec3 structure_p = stable_world_frame / structure_world_size;
		// The cellular resource is sampled at a fixed second scale. Its inverted
		// distance response supplies cavities/islands instead of flat cell IDs.
		float ridged = texture(micro_ridged_texture, structure_p).r;
		float cellular_distance = texture(micro_cellular_texture, structure_p * 1.75 + vec3(17.13, -9.71, 23.47)).r;
		float cellular_variant = 1.0 - cellular_distance;
		float combined_structure = mix(ridged, cellular_variant, clamp(micro_cellular_weight, 0.0, 1.0));
		float softness = max(micro_structure_softness, 0.01);
		float threshold = clamp(micro_structure_threshold, 0.0, 1.0);
		float vein_mask = smoothstep(threshold - softness, threshold + softness, combined_structure);
		textured_structure = mix(1.0, vein_mask, clamp(micro_structure_strength, 0.0, 1.0));
		float distance_to_camera = length(world_pos - camera_world_position);
		float structure_lod = 1.0 - smoothstep(
			max(micro_structure_lod_start_m, 0.0),
			max(micro_structure_lod_end_m, max(micro_structure_lod_start_m, 0.0) + 0.001),
			distance_to_camera);
		textured_structure = mix(1.0, textured_structure, structure_lod);
	}

	// --- Persistent MICRO droplet field ------------------------------------
	// Fine droplets are matter in their own right. The micro contribution is
	// deliberately NOT multiplied by macro density: it is valid for micro to
	// exist where macro is zero, because spray detaches from the mist body.
	//
	// H4.37: ONE RG lookup. The micro field's own G channel is the micro
	// wave/source-coupled mass, so the micro affinity is derived from micro state
	// alone and stays valid when macro_density == 0.
	vec2 micro_state_value = vec2(0.0);
	if (micro_enabled > 0.5 && inside_unit_cube(uvw)) {
		micro_state_value = max(texture(micro_state, uvw).rg, vec2(0.0));
	}
	float micro_density = micro_state_value.r;
	float micro_wave_affinity = clamp(
		micro_state_value.g / max(micro_density, EPSILON) / max(micro_affinity_steady_ratio, 0.0001),
		0.0,
		1.0);

	// --- Multi-scale combination -------------------------------------------
	// Macro is the large soft body: it stays predominantly smooth and only ever
	// receives a small fixed breakup, so it can never turn into noisy static and
	// so granule_strength is not applied twice. It is shaped by the MACRO field's
	// own affinity, bounded to a 1.00..1.25 range on a 0.15 amplitude (so the
	// breakup depth moves only between 0.150 and 0.1875).
	float macro_affinity_boost = mix(1.0, 1.25, macro_wave_affinity);
	float macro_erosion = mix(1.0, macro_droplet_mask, MACRO_FIXED_BREAKUP * macro_affinity_boost);
	float macro_render = max(volume_density, 0.0) * macro_density * macro_erosion;
	// Micro carries the granular spray read at full strength, shaped by the MICRO
	// field's own affinity: freshly torn droplets granulate a little harder than
	// droplets that have already aged into smooth wind-driven aerosol. This path
	// must never read macro_wave_affinity, and it never reads the slow macro mask:
	// the fast warp and the wind-aligned stretch are micro-only.
	float micro_affinity_boost = mix(1.0, 1.25, micro_wave_affinity);
	float selected_micro_structure = micro_droplet_mask;
	float structure_amount = granule_strength;
	if (structure_mode == 1) {
		selected_micro_structure = textured_structure;
		structure_amount = micro_structure_strength;
	} else if (structure_mode == 2) {
		selected_micro_structure = micro_droplet_mask * textured_structure;
		structure_amount = max(granule_strength, micro_structure_strength);
	}
	float micro_erosion = mix(1.0, selected_micro_structure, clamp(clamp(structure_amount, 0.0, 1.0) * micro_affinity_boost, 0.0, 1.0));
	float micro_render = max(micro_volume_density, 0.0) * micro_density * micro_erosion;
	// Where droplets are dense the mist body reads slightly porous. Strictly
	// bounded, so it can never erase the macro volume.
	float porosity = 1.0 - MICRO_POROSITY_MAX * smoothstep(0.0, 1.0, micro_density);
	float macro_contribution = macro_render * porosity;
	float micro_contribution = micro_render;
	float density = vertical_boundary_fade * edge * (macro_contribution + micro_contribution);

	// --- Authored macro / micro colour blend -------------------------------
	// A froxel has ONE ALBEDO output, so the two fields' base colours are mixed by
	// their relative share of this froxel's density. A froxel dominated by the
	// mist body reads the macro colour; one dominated by detached droplets reads
	// the micro colour; the boundary between them is a smooth material transition.
	// No procedural colour noise is involved anywhere: the granular read still
	// comes from density alone.
	float contribution_total = macro_contribution + micro_contribution;
	float micro_colour_weight = contribution_total > EPSILON ? micro_contribution / contribution_total : 0.0;
	vec3 volume_albedo = mix(macro_albedo_color, micro_albedo_color, clamp(micro_colour_weight, 0.0, 1.0));

	DENSITY = clamp(density, 0.0, 1.0);
	ALBEDO = volume_albedo;
	EMISSION = volume_albedo * max(emission_strength, 0.0);
}
