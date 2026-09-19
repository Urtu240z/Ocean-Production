shader_type fog;
// H4.33 Ocean V4 persistent volumetric spindrift, RENDER pass.
//
// This shader does not reconstruct density from Crest G any more. It samples
// the authoritative persistent Eulerian state produced by
// spindrift_volume_advect.glsl through a Texture3DRD wrapper:
//
//   R = density mass          -> fog opacity
//   G = wave-coupled mass     -> optional microstructure shaping only
//
// Crest G is now an INJECTION source for the compute pass, never the final
// render density. That is what lets mist survive after its crest disappears.
//
// The granular, droplet-like read is produced by eroding the persistent macro
// density with a fine advected 3D microstructure. It is deliberately density
// only: ALBEDO stays flat and near-white, so there is no colour variation and
// no per-droplet colour noise. No particles, no sprites, no impostor cards.
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
uniform float sea_level = 0.0;
uniform float height_m = 8.0;
uniform float volume_density = 0.08;
uniform float edge_fade = 0.30;

// --- Flow used by the microstructure --------------------------------------
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
const float CURL_WARP_M = 2.0;
const float SURFACE_BAND = 0.05;
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

// Same analytic divergence-free field as the advection pass, so the
// microstructure is carried by the same rotational flow as the density.
vec3 divergence_free_field(vec3 p) {
	vec3 first = vec3(-sin(p.y) - cos(p.z), -sin(p.z) - cos(p.x), -sin(p.x) - cos(p.y));
	vec3 q = vec3(p.z + CURL_SECOND_OFFSET.x, p.x + CURL_SECOND_OFFSET.y, p.y + CURL_SECOND_OFFSET.z) * CURL_SECOND_SCALE;
	vec3 second = vec3(-sin(q.y) - cos(q.z), -sin(q.z) - cos(q.x), -sin(q.x) - cos(q.y));
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

	// Vertical envelope. world_y - sea_level is the authoritative height
	// reference shared with injection and lift.
	float rel_y = world_pos.y - sea_level;
	float volume_height = max(height_m, 0.01);
	float vertical_t = clamp(rel_y / volume_height, 0.0, 1.0);
	float surface_soft = smoothstep(0.0, SURFACE_BAND, vertical_t);
	float height_falloff = 1.0 - vertical_t;
	float vertical = surface_soft * height_falloff * height_falloff;

	// Local volume edge fade, keyed on the same grid the simulation owns.
	float radial = length(uvw.xz - vec2(0.5)) * 2.0;
	float fade_start = clamp(1.0 - clamp(edge_fade, 0.02, 0.95), 0.0, 0.99);
	float edge = 1.0 - smoothstep(fade_start, 1.0, radial);

	// --- Granular microstructure -----------------------------------------
	// Fine 3D structure advected by an approximation of the same wind + curl
	// field the density uses. It is coherent in space and slow in time, never
	// screen-space noise and never a per-frame random phase.
	vec2 wind = normalize(wind_direction + vec2(0.000001, 0.000001));
	vec3 curl_p = world_pos * max(curl_scale, EPSILON) + vec3(0.0, 0.0, sim_time_s * curl_speed);
	vec3 curl = divergence_free_field(curl_p) * max(curl_strength, 0.0);
	vec3 flow = vec3(wind.x, 0.0, wind.y) * (max(wind_speed_mps, 0.0) * wind_advection) + curl;
	vec3 micro_p = world_pos - flow * (sim_time_s * granule_speed) + curl * CURL_WARP_M;

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

	float density = max(volume_density, 0.0) * macro_density * vertical * edge * erosion;

	// Uniform, near-white mist. No colour variation anywhere: the granular read
	// comes from density only, and Godot volumetric lighting stays the only
	// brightness authority besides the deliberately small emission control.
	DENSITY = clamp(density, 0.0, 1.0);
	ALBEDO = albedo_color;
	EMISSION = albedo_color * max(emission_strength, 0.0);
}
