#[compute]
#version 450
// H4.36 Ocean V4 persistent MICRO-aerosol pass.
//
// The macro pass (spindrift_volume_advect.glsl) owns the large mist body. This
// pass owns the fine droplet scale: a SECOND persistent Eulerian field, at higher
// resolution, with its own history and its own faster dynamics. It is never
// reconstructed from render-side noise: it is simulated, advected and decayed
// every step exactly like the macro field.
//
//   MICRO STATE channels (RG16F):
//     R = fine aerosol / droplet-cluster density
//     G = micro wave/source-coupled mass        (always clamped to 0 <= G <= R)
//
// It shares the macro world-space grid definition (same origin, same extent,
// different voxel size), so the trilinear backtrace recenters it correctly with
// no extra machinery.
//
// H4.36 intentionally does NOT read macro state: no six-neighbour macro gradient
// samples, no shedding solver, no inter-pass barrier. Micro aerosol is injected
// directly from the same authoritative Crest G source and then evolves
// independently. That keeps the pass cheap and dependency-free; macro-to-micro
// shedding can be added later if the visual gate asks for it.
//
// Micro injection is deliberately PATCHY. A uniform slab wherever Crest G exists
// would just be a second smooth fog cloud, so the source is multiplied by a
// coherent world-space sparse seed field. The seed is deterministic, continuous
// and only drifts slowly, so the persistent simulation stays the dominant
// temporal mechanism instead of the noise pattern.
//
// Everything else (semi-Lagrangian advection, displaced-crest placement,
// divergence-free curl, heterogeneous local preference, exponential decay) uses
// the corrected H4.34/H4.35 constructions, with micro-specific multipliers baked
// into the packed parameters by the host so this shader stays structurally
// identical to the macro one.

layout(local_size_x = 8, local_size_y = 4, local_size_z = 8) in;

layout(set = 0, binding = 0) uniform sampler3D micro_previous;
layout(rg16f, set = 0, binding = 1) uniform restrict writeonly image3D micro_next;
// Crest G of the LONG crest texture: the same OpenOceanBreakingActivity authority
// the H4.31 particles and the macro volume consume. Injection only.
layout(set = 0, binding = 2) uniform sampler2D breaking_activity_long;
// LONG displacement: choppy XZ displacement, vertical surface displacement and
// the local wave propagation direction, with the exact H4.35 conventions.
layout(set = 0, binding = 3) uniform sampler2D displacement_long;

// Same std140 layout as the macro pass. The host substitutes micro-specific
// values (multipliers, micro decay rates, micro band, micro turnover) so the two
// shaders stay structurally identical.
layout(set = 0, binding = 4, std140) uniform MicroAdvectParams {
	vec4 volume_origin_dt;      // xyz world origin of the destination grid, w dt
	vec4 volume_extent_time;    // xyz world extent of the grid, w simulation time
	vec4 previous_origin_valid; // xyz world origin of the previous grid, w 1 if history is usable
	vec4 domains_resolution;    // xyz FFT domain sizes in metres, w unused
	vec4 wind;                  // xy wind direction (world XZ), z wind speed m/s ALREADY scaled by the micro multiplier, w volumetric_wind_advection
	vec4 decay;                 // x micro density decay 1/s, y micro wave memory decay 1/s, z micro injection turnover 1/s, w max mass
	vec4 injection;             // x crest threshold, y micro source gain, z micro injection full height m, w micro injection top height m
	vec4 wave;                  // x wave push m/s, y micro steady state affinity ratio, z wave gradient step m, w micro seed scale 1/m
	vec4 curl;                  // x micro curl strength m/s, y micro curl scale 1/m, z curl time rate, w unused
	vec4 variation;             // x variation strength, y micro variation scale 1/m, z variation time rate, w micro lift m/s
	vec4 ocean_space;           // x sea level, y clipmap geometry scale (H), z ocean surface scale (V), w unused
} params;

const float EPSILON = 0.0001;
// H4.39A: how much of the (already micro-scaled) wind still acts on freshly
// injected, wave-coupled droplets. Deliberately higher than the macro field's
// 0.35: fine droplets are light and get caught by strong wind almost
// immediately, which is what makes newborn spray accelerate promptly instead of
// hanging near the crest like smoke. Macro semantics are untouched.
const float MICRO_WIND_NEWBORN_FRACTION = 0.70;
const float AFFINITY_GAIN_FLOOR = 0.02;
const float MAX_MASS_HARD_LIMIT = 8.0;
// Second octave of the analytic divergence-free field (H4.35 form: uniform scale
// plus translation, which preserves div == 0).
const float CURL_SECOND_OCTAVE = 0.35;
const float CURL_SECOND_SCALE = 1.91;
const vec3 CURL_SECOND_OFFSET = vec3(13.7, -7.1, 3.9);
// Micro injection band, measured against the DISPLACED water surface. Thinner
// than the macro band: fine droplets are born at the torn crest/lip.
const float MICRO_INJECTION_BELOW_M = 0.10;
// Local preference mappings, identical construction to macro.
const float WAVE_VARIATION_COUPLING = 0.85;
const float CURL_VARIATION_COUPLING = 0.80;
const float LIFT_VARIATION_COUPLING = 0.50;
const float VARIATION_MIN = 0.35;
const float VARIATION_MAX = 1.65;
// Sparse seed shaping. Two frequencies maximum.
const float MICRO_SEED_OCTAVE_SCALE = 2.17;
const vec3 MICRO_SEED_OCTAVE_OFFSET = vec3(23.11, 5.37, 17.93);
const float MICRO_SEED_OCTAVE_WEIGHT = 0.40;
const float MICRO_SEED_THRESHOLD = 0.42;
const float MICRO_SEED_SOFTNESS = 0.30;
// Slow coherent drift of the seed pattern so one crest does not emit a frozen
// checkerboard. Deliberately much slower than the simulation itself.
const float MICRO_SEED_PHASE_RATE = 0.06;

bool finite_scalar(float value) {
	return !isnan(value) && !isinf(value);
}

bool finite_pair(vec2 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

// One octave of quintic value noise. Coherent, deterministic, no per-frame RNG.
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

// One octave of the analytic divergence-free field: each component omits its own
// coordinate, so its own partial derivative is zero and div == 0.
vec3 divergence_free_octave(vec3 p) {
	return vec3(-sin(p.y) - cos(p.z), -sin(p.z) - cos(p.x), -sin(p.x) - cos(p.y));
}

// Two incommensurate octaves. The second uses the corrected uniform-scale plus
// translation transform, so it is genuinely divergence-free.
vec3 divergence_free_field(vec3 p) {
	vec3 first = divergence_free_octave(p);
	vec3 second = divergence_free_octave(p * CURL_SECOND_SCALE + CURL_SECOND_OFFSET);
	return first + second * CURL_SECOND_OCTAVE;
}

// Exact macro world -> source mapping.
vec2 source_uv(vec2 world_xz) {
	return world_xz / max(params.domains_resolution.x, EPSILON) + vec2(0.5);
}

vec3 authored_displacement(vec2 world_xz) {
	return textureLod(displacement_long, source_uv(world_xz), 0.0).xyz;
}

// Exact H4.35 Ocean Space conversion of an authored displacement.
vec3 ocean_space_displacement(vec3 authored) {
	return vec3(
		authored.x * params.ocean_space.y,
		authored.y * params.ocean_space.z,
		authored.z * params.ocean_space.y);
}

// Crest G remains the sole breaking authority; R (residual foam) is never read.
float crest_activity(vec2 world_xz) {
	return clamp(textureLod(breaking_activity_long, source_uv(world_xz), 0.0).g, 0.0, 1.0);
}

// Exact H4.35 local wave propagation semantics.
vec2 wave_direction(vec2 world_xz) {
	float step_m = max(params.wave.z, 0.25);
	float h_x0 = textureLod(displacement_long, source_uv(world_xz - vec2(step_m, 0.0)), 0.0).y;
	float h_x1 = textureLod(displacement_long, source_uv(world_xz + vec2(step_m, 0.0)), 0.0).y;
	float h_z0 = textureLod(displacement_long, source_uv(world_xz - vec2(0.0, step_m)), 0.0).y;
	float h_z1 = textureLod(displacement_long, source_uv(world_xz + vec2(0.0, step_m)), 0.0).y;
	vec2 gradient = vec2(h_x1 - h_x0, h_z1 - h_z0);
	return length(gradient) > EPSILON ? normalize(gradient) : vec2(0.0, -1.0);
}

bool inside_unit_cube(vec3 value) {
	return all(greaterThanEqual(value, vec3(0.0))) && all(lessThanEqual(value, vec3(1.0)));
}

// Patchy coherent source field. Evaluated at the DISPLACED surface position so it
// travels with the crest it belongs to, in stable world space, with only a slow
// phase drift. No screen-space pattern, no per-frame randomness.
float sparse_seed(vec2 source_xz, float displaced_surface_y, float sim_time_s, float seed_scale) {
	vec3 seed_p = vec3(source_xz.x, displaced_surface_y, source_xz.y) * max(seed_scale, 0.0001);
	seed_p.z += sim_time_s * MICRO_SEED_PHASE_RATE;
	float n0 = value_noise(seed_p);
	float n1 = value_noise(seed_p * MICRO_SEED_OCTAVE_SCALE + MICRO_SEED_OCTAVE_OFFSET);
	float seed_noise = mix(n0, n1, MICRO_SEED_OCTAVE_WEIGHT);
	return smoothstep(MICRO_SEED_THRESHOLD, MICRO_SEED_THRESHOLD + MICRO_SEED_SOFTNESS, seed_noise);
}

void main() {
	ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(micro_next);
	if (any(greaterThanEqual(cell, size))) {
		return;
	}
	vec3 resolution = vec3(size);
	vec3 extent = max(params.volume_extent_time.xyz, vec3(EPSILON));
	vec3 world = params.volume_origin_dt.xyz + (vec3(cell) + vec3(0.5)) / resolution * extent;
	float dt = clamp(params.volume_origin_dt.w, 0.0, 0.25);
	bool history_valid = params.previous_origin_valid.w > 0.5;

	// Previous micro state at the same world position. The previous origin is
	// explicit, so a recentered volume still reads the same world location.
	vec3 previous_uvw = (world - params.previous_origin_valid.xyz) / extent;
	vec2 local = vec2(0.0);
	if (history_valid && inside_unit_cube(previous_uvw)) {
		local = textureLod(micro_previous, previous_uvw, 0.0).rg;
	}
	local = max(local, vec2(0.0));
	float local_density = finite_scalar(local.r) ? local.r : 0.0;

	// Age/source proxy, normalised by the micro steady-state ratio of the two
	// micro decay rates.
	float steady_ratio = clamp(params.wave.y, AFFINITY_GAIN_FLOOR, 1.0);
	float wave_affinity = clamp(local.g / max(local_density, EPSILON) / steady_ratio, 0.0, 1.0);

	// --- Choppy inverse displacement, identical to macro -------------------
	vec3 disp_0 = ocean_space_displacement(authored_displacement(world.xz));
	vec2 source_xz = world.xz - disp_0.xz;
	vec3 disp_1 = ocean_space_displacement(authored_displacement(source_xz));
	float displaced_surface_y = params.ocean_space.x + disp_1.y;

	vec2 propagation = wave_direction(source_xz);

	// --- Coherent local preference field, same construction as macro -------
	vec3 variation_p = world * max(params.variation.y, EPSILON) + vec3(0.0, 0.0, params.volume_extent_time.w * params.variation.z);
	float variation_signed = value_noise(variation_p) * 2.0 - 1.0;
	float variation_strength = clamp(params.variation.x, 0.0, 1.0);
	float local_wind_variation = clamp(1.0 + variation_signed * variation_strength, VARIATION_MIN, VARIATION_MAX);
	float local_wave_variation = clamp(1.0 - variation_signed * variation_strength * WAVE_VARIATION_COUPLING, VARIATION_MIN, VARIATION_MAX);
	float local_curl_variation = clamp(1.0 + abs(variation_signed) * variation_strength * CURL_VARIATION_COUPLING, VARIATION_MIN, VARIATION_MAX);
	float local_lift_variation = clamp(1.0 - abs(variation_signed) * variation_strength * LIFT_VARIATION_COUPLING, VARIATION_MIN, VARIATION_MAX);

	// --- Wind: fine droplets are generally more wind-responsive ------------
	// params.wind.z already carries wind_speed * volumetric_micro_wind_multiplier.
	vec2 wind_dir = params.wind.xy;
	float wind_length = length(wind_dir);
	wind_dir = wind_length > EPSILON ? wind_dir / wind_length : vec2(1.0, 0.0);
	float wind_speed_effective = max(params.wind.z, 0.0) * clamp(params.wind.w, 0.0, 0.5);
	float wind_age_weight = mix(MICRO_WIND_NEWBORN_FRACTION, 1.0, 1.0 - wave_affinity);
	float wind_weight = wind_speed_effective * wind_age_weight * local_wind_variation;
	vec3 velocity = vec3(wind_dir.x, 0.0, wind_dir.y) * wind_weight;

	// --- Wave: newborn droplets inherit the crest motion -------------------
	float wave_weight = max(params.wave.x, 0.0) * wave_affinity * local_wave_variation;
	velocity += vec3(propagation.x, 0.0, propagation.y) * wave_weight;

	// --- Curl: finer and stronger than macro, same divergence-free field ---
	vec3 curl_p = world * max(params.curl.y, EPSILON) + vec3(0.0, 0.0, params.volume_extent_time.w * params.curl.z);
	velocity += divergence_free_field(curl_p) * (max(params.curl.x, 0.0) * local_curl_variation);

	// --- Vertical lift: slightly easier for fine droplets, never buoyancy --
	float lift_response = smoothstep(0.0, 0.30, local_density);
	velocity.y += max(params.variation.w, 0.0) * lift_response * local_lift_variation;

	if (!finite_scalar(velocity.x) || !finite_scalar(velocity.y) || !finite_scalar(velocity.z)) {
		velocity = vec3(0.0);
	}

	// --- Semi-Lagrangian backtrace ----------------------------------------
	vec3 sampled_world = world - velocity * dt;
	vec3 sampled_uvw = (sampled_world - params.previous_origin_valid.xyz) / extent;
	vec2 advected = vec2(0.0);
	if (history_valid && inside_unit_cube(sampled_uvw)) {
		advected = textureLod(micro_previous, sampled_uvw, 0.0).rg;
	}
	if (!finite_pair(advected)) {
		advected = vec2(0.0);
	}
	advected = max(advected, vec2(0.0));

	// --- Frame-rate independent decay. Micro dies faster than macro --------
	advected.r *= exp(-max(params.decay.x, 0.0) * dt);
	advected.g *= exp(-max(params.decay.y, 0.0) * dt);

	// --- Patchy crest injection into the fine droplet scale ---------------
	float height = world.y - displaced_surface_y;
	float injection_full = max(params.injection.z, 0.01);
	float injection_top = max(params.injection.w, injection_full + 0.01);
	float band = smoothstep(-MICRO_INJECTION_BELOW_M, injection_full, height) * (1.0 - smoothstep(injection_full, injection_top, height));
	float threshold = clamp(params.injection.x, 0.0, 1.0);
	float activity = crest_activity(source_xz);
	float shaped = clamp((activity - threshold) / max(1.0 - threshold, 0.001), 0.0, 1.0);
	shaped = shaped * shaped * (3.0 - 2.0 * shaped) * max(params.injection.y, 0.0);
	float seed = sparse_seed(source_xz, displaced_surface_y, params.volume_extent_time.w, params.wave.w);
	float injected = shaped * band * seed * max(params.decay.z, 0.0) * dt;
	vec2 next_state = advected + vec2(injected, injected);

	next_state.r = clamp(next_state.r, 0.0, min(max(params.decay.w, 0.0), MAX_MASS_HARD_LIMIT));
	next_state.g = clamp(next_state.g, 0.0, next_state.r);
	if (!finite_pair(next_state)) {
		next_state = vec2(0.0);
	}
	imageStore(micro_next, cell, vec4(next_state.r, next_state.g, 0.0, 0.0));
}
