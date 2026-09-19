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
// only: ALBEDO stays flat and near-white, so there is no colour variation and
// no per-droplet colour noise. No particles, no sprites, no impostor cards.
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
uniform sampler3D persistent_state : filter_linear, repeat_disable;
uniform vec3 sim_origin = vec3(0.0);
uniform vec3 sim_extent = vec3(96.0, 16.0, 96.0);
uniform float sim_time_s = 0.0;
uniform float affinity_steady_ratio = 0.075;

// --- Placement -------------------------------------------------------------
// No sea_level and no height: persistent state owns vertical placement.
uniform float volume_density = 0.08;
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
uniform float curl_strength = 1.0;
uniform float curl_scale = 0.03;
uniform float curl_speed = 0.12;

// --- Granular microstructure ----------------------------------------------
uniform float granule_strength = 0.60;
uniform float granule_scale = 0.45;
uniform float granule_speed = 0.35;
uniform float granule_threshold = 0.42;

// --- Material --------------------------------------------------------------
uniform vec3 albedo_color = vec3(0.92, 0.95, 0.98);
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

	// Persistent state. Trilinear sampling of the RG16F volume, clamped so a
	// froxel on the exact boundary cannot read a neighbouring texel.
	vec2 state = vec2(0.0);
	if (inside_unit_cube(uvw)) {
		state = max(texture(persistent_state, uvw).rg, vec2(0.0));
	}
	float macro_density = state.r;
	float wave_affinity = clamp(state.g / max(macro_density, EPSILON) / max(affinity_steady_ratio, 0.0001), 0.0, 1.0);

	// --- Volume boundary feather ------------------------------------------
	// Purely a box-edge softener in the volume's own normalized coordinates.
	// There is no water-surface model here and no sea_level reference: the
	// persistent field decides where aerosol actually is.
	float bottom_fade = smoothstep(0.0, VERTICAL_EDGE_FADE, uvw.y);
	float top_fade = 1.0 - smoothstep(1.0 - VERTICAL_EDGE_FADE, 1.0, uvw.y);
	float vertical_boundary_fade = bottom_fade * top_fade;

	// Horizontal edge fade, keyed on the same grid the simulation owns.
	float radial = length(uvw.xz - vec2(0.5)) * 2.0;
	float fade_start = clamp(1.0 - clamp(edge_fade, 0.02, 0.95), 0.0, 0.99);
	float edge = 1.0 - smoothstep(fade_start, 1.0, radial);

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
	vec3 micro_p = world_pos - wind_translation + curl_warp;

	float scale = max(granule_scale, 0.0001);
	float octave_a = value_noise(micro_p * scale);
	float octave_b = value_noise(micro_p * (scale * GRANULE_OCTAVE_SCALE) + GRANULE_OCTAVE_OFFSET);
	float micro = mix(octave_a, octave_b, GRANULE_OCTAVE_WEIGHT);
	// Thresholding the product of two incommensurate octaves produces holes,
	// islands and filaments instead of a uniform fuzz.
	float granule = smoothstep(granule_threshold, min(granule_threshold + GRANULE_EROSION_WIDTH, 0.999), micro);
	// Microstructure exists only where there is persistent macro density: the
	// erosion is a multiplier, so it can never invent fog of its own.
	float micro_response = smoothstep(0.0, 0.35, macro_density);
	// Wave-coupled parcels are freshly torn spray, so they granulate a little
	// harder than aerosol that has already aged into smooth wind-driven mist.
	float affinity_boost = mix(1.0, 1.25, clamp(wave_affinity, 0.0, 1.0));
	float erosion = mix(1.0, granule, clamp(clamp(granule_strength, 0.0, 1.0) * affinity_boost, 0.0, 1.0) * micro_response);

	float density = max(volume_density, 0.0) * macro_density * vertical_boundary_fade * edge * erosion;

	// Uniform, near-white mist. No colour variation anywhere: the granular read
	// comes from density only, and Godot volumetric lighting stays the only
	// brightness authority besides the deliberately small emission control.
	DENSITY = clamp(density, 0.0, 1.0);
	ALBEDO = albedo_color;
	EMISSION = albedo_color * max(emission_strength, 0.0);
}
