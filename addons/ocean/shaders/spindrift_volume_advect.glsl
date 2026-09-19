#[compute]
#version 450
// H4.33/H4.34 Ocean V4 persistent volumetric spindrift, advection pass.
//
// One dispatch advances the whole Eulerian aerosol volume by one fixed step.
// The volume is a single local 3D field, ping-ponged between two RG16F storage
// textures on the MAIN RenderingDevice, so the result stays visible to the
// normal renderer and to the FogVolume that samples it.
//
// State channels (RG16F):
//   R = density mass of the aerosol parcel
//   G = wave/source-coupled mass of the same parcel
// wave_affinity = (G / R) normalised by the steady-state ratio, i.e. ~1 while the
// parcel is still fed by a breaking crest and -> 0 once only aged density is
// left. That is what makes the mist keep moving after its source disappears.
//
// Advection is semi-Lagrangian: for every destination voxel the world position
// is reconstructed, a heterogeneous velocity is evaluated, the source position
// is backtraced and the previous state is trilinearly sampled. The previous
// grid origin is passed explicitly, so an integer-voxel recenter of the volume
// is handled exactly by the backtrace with no extra pass: cells that fall
// outside the previous grid simply receive zero and are refilled by injection.
// Density is never wrapped around the volume.
//
// H4.34 velocity model. Every term carries its own local preference so that
// neighbouring parcels genuinely disagree about what moves them:
//   velocity = wind_dir * wind_speed * wind_advection * age_factor * wind_var
//            + wave_dir * wave_push * wave_affinity * wave_var
//            + curl_3d * curl_var
//            + vertical lift * lift_var
// wind_var and wave_var are ANTI-CORRELATED (one rises where the other falls),
// so a region can be wind-dominated while its neighbour stays wave-dominated.
// No Navier-Stokes, no pressure projection, no FLIP.

layout(local_size_x = 8, local_size_y = 4, local_size_z = 8) in;

layout(set = 0, binding = 0) uniform sampler3D state_previous;
layout(rg16f, set = 0, binding = 1) uniform restrict writeonly image3D state_next;
// Crest G of the LONG crest texture: the same OpenOceanBreakingActivity
// authority the H4.31 particle spindrift consumes. Injection only.
layout(set = 0, binding = 2) uniform sampler2D breaking_activity_long;
// LONG displacement: choppy XZ displacement, vertical surface displacement and
// the local wave propagation direction, all with the exact H4.31 conventions.
layout(set = 0, binding = 3) uniform sampler2D displacement_long;

// std140 parameter block. Keep this table in sync with
// OceanSpindriftSimulationV1._pack_params().
layout(set = 0, binding = 4, std140) uniform AdvectParams {
	vec4 volume_origin_dt;      // xyz world origin of the destination grid, w dt
	vec4 volume_extent_time;    // xyz world extent of the grid, w simulation time
	vec4 previous_origin_valid; // xyz world origin of the previous grid, w 1 if history is usable
	vec4 domains_resolution;    // xyz FFT domain sizes in metres, w unused
	vec4 wind;                  // xy atmospheric wind direction (world XZ), z atmospheric wind speed m/s, w volumetric_wind_advection fraction 0..0.5
	vec4 decay;                 // x density decay 1/s, y wave memory decay 1/s, z injection turnover 1/s, w max mass
	vec4 injection;             // x crest threshold, y source gain, z injection full height m (above the displaced surface), w injection top height m
	vec4 wave;                  // x wave push m/s, y steady state affinity ratio, z wave gradient step m, w unused
	vec4 curl;                  // x curl strength m/s, y curl scale 1/m, z curl time rate, w unused
	vec4 variation;             // x variation strength, y variation scale 1/m, z variation time rate, w lift m/s
	vec4 ocean_space;           // x sea level, y clipmap geometry scale (H), z ocean surface scale (V), w unused
} params;

const float EPSILON = 0.0001;
// How much of the (already wind_advection-scaled) wind still acts on freshly
// injected, wave-coupled spray.
const float WIND_NEWBORN_FRACTION = 0.35;
const float AFFINITY_GAIN_FLOOR = 0.02;
const float MAX_MASS_HARD_LIMIT = 8.0;
// Second octave of the analytic divergence-free field.
const float CURL_SECOND_OCTAVE = 0.35;
const float CURL_SECOND_SCALE = 1.91;
const vec3 CURL_SECOND_OFFSET = vec3(13.7, -7.1, 3.9);
// Injection band, measured against the DISPLACED water surface.
const float INJECTION_BELOW_SURFACE_M = 0.25;
// Local preference mappings derived from one coherent signed noise field.
// Wind and wave are strictly anti-correlated; curl and lift use folded mappings
// so they are spatially different again instead of a copy of the wind factor.
const float WAVE_VARIATION_COUPLING = 0.85;
const float CURL_VARIATION_COUPLING = 0.80;
const float LIFT_VARIATION_COUPLING = 0.50;
const float VARIATION_MIN = 0.35;
const float VARIATION_MAX = 1.65;

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

// One octave of quintic value noise. Used only for the low-frequency coherent
// flow variation, never for per-frame or per-voxel randomness.
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

// Analytic divergence-free (curl-like) 3D field. Two incommensurate octaves so
// the rolling pattern never reads as a single global sinusoidal rotation, and
// fully continuous in world space so there are no cell or lattice seams.
vec3 divergence_free_field(vec3 p) {
	vec3 first = vec3(-sin(p.y) - cos(p.z), -sin(p.z) - cos(p.x), -sin(p.x) - cos(p.y));
	vec3 q = vec3(p.z + CURL_SECOND_OFFSET.x, p.x + CURL_SECOND_OFFSET.y, p.y + CURL_SECOND_OFFSET.z) * CURL_SECOND_SCALE;
	vec3 second = vec3(-sin(q.y) - cos(q.z), -sin(q.z) - cos(q.x), -sin(q.x) - cos(q.y));
	return first + second * CURL_SECOND_OCTAVE;
}

// Exact H4.31 world -> source mapping.
vec2 source_uv(vec2 world_xz) {
	return world_xz / max(params.domains_resolution.x, EPSILON) + vec2(0.5);
}

vec3 authored_displacement(vec2 world_xz) {
	return textureLod(displacement_long, source_uv(world_xz), 0.0).xyz;
}

// Exact H4.31 Ocean Space conversion of an authored displacement:
//   x,z scale with the clipmap horizontal scale, y with the ocean surface scale.
vec3 ocean_space_displacement(vec3 authored) {
	return vec3(
		authored.x * params.ocean_space.y,
		authored.y * params.ocean_space.z,
		authored.z * params.ocean_space.y);
}

// Crest G remains the sole breaking authority. R is residual foam and is never
// sampled. Always evaluated at the inverse-displaced source coordinate.
float crest_activity(vec2 world_xz) {
	return clamp(textureLod(breaking_activity_long, source_uv(world_xz), 0.0).g, 0.0, 1.0);
}

// Exact H4.31 local wave propagation semantics: finite difference of the LONG
// displacement height at +-step in X and Z, normalised. Atmospheric wind is
// never substituted for this.
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

void main() {
	ivec3 cell = ivec3(gl_GlobalInvocationID.xyz);
	ivec3 size = imageSize(state_next);
	if (any(greaterThanEqual(cell, size))) {
		return;
	}
	vec3 resolution = vec3(size);
	vec3 extent = max(params.volume_extent_time.xyz, vec3(EPSILON));
	vec3 world = params.volume_origin_dt.xyz + (vec3(cell) + vec3(0.5)) / resolution * extent;
	float dt = clamp(params.volume_origin_dt.w, 0.0, 0.25);
	bool history_valid = params.previous_origin_valid.w > 0.5;

	// State of this world position in the previous grid. The previous origin is
	// explicit, so a recentered volume still reads the same world location.
	vec3 previous_uvw = (world - params.previous_origin_valid.xyz) / extent;
	vec2 local = vec2(0.0);
	if (history_valid && inside_unit_cube(previous_uvw)) {
		local = textureLod(state_previous, previous_uvw, 0.0).rg;
	}
	local = max(local, vec2(0.0));
	float local_density = finite_scalar(local.r) ? local.r : 0.0;

	// Age/source proxy. Normalised by the steady-state ratio of the two decay
	// rates so a continuously fed crest reads ~1 and a stale parcel decays to 0.
	float steady_ratio = clamp(params.wave.y, AFFINITY_GAIN_FLOOR, 1.0);
	float wave_affinity = clamp(local.g / max(local_density, EPSILON) / steady_ratio, 0.0, 1.0);

	// -----------------------------------------------------------------------
	// Choppy inverse displacement (H4.34). This is a gather pass, so the source
	// point whose displaced surface reaches this destination XZ has to be
	// recovered instead of splatted. One fixed-point iteration:
	//   source_0 = world.xz
	//   source_1 = world.xz - displacement(source_0).xz * H
	// and then the displaced surface is resampled honestly at source_1.
	// Crest G and the surface displacement are both read at source_1, so the
	// injected mist is spatially aligned with the crest that produced it.
	// -----------------------------------------------------------------------
	vec3 disp_0 = ocean_space_displacement(authored_displacement(world.xz));
	vec2 source_xz = world.xz - disp_0.xz;
	vec3 disp_1 = ocean_space_displacement(authored_displacement(source_xz));
	float displaced_surface_y = params.ocean_space.x + disp_1.y;

	// Wave propagation direction, evaluated at the corrected source coordinate.
	// The wave term is gated by wave_affinity, which is only non-zero close to a
	// crest, and there the source coordinate IS the crest coordinate.
	vec2 propagation = wave_direction(source_xz);

	// -----------------------------------------------------------------------
	// Local preference field. One coherent low-frequency signed noise, mapped
	// four different ways. Wind and wave are anti-correlated, so neighbouring
	// parcels genuinely disagree about what is moving them.
	// -----------------------------------------------------------------------
	vec3 variation_p = world * max(params.variation.y, EPSILON) + vec3(0.0, 0.0, params.volume_extent_time.w * params.variation.z);
	float variation_signed = value_noise(variation_p) * 2.0 - 1.0;
	float variation_strength = clamp(params.variation.x, 0.0, 1.0);
	float local_wind_variation = clamp(1.0 + variation_signed * variation_strength, VARIATION_MIN, VARIATION_MAX);
	float local_wave_variation = clamp(1.0 - variation_signed * variation_strength * WAVE_VARIATION_COUPLING, VARIATION_MIN, VARIATION_MAX);
	float local_curl_variation = clamp(1.0 + abs(variation_signed) * variation_strength * CURL_VARIATION_COUPLING, VARIATION_MIN, VARIATION_MAX);
	float local_lift_variation = clamp(1.0 - abs(variation_signed) * variation_strength * LIFT_VARIATION_COUPLING, VARIATION_MIN, VARIATION_MAX);

	// --- Wind: dominates older aerosol, reduced for wave-coupled spray ------
	// wind.z is the real atmospheric speed, wind.w is the authored fraction of it
	// that is actually imparted to the aerosol.
	vec2 wind_dir = params.wind.xy;
	float wind_length = length(wind_dir);
	wind_dir = wind_length > EPSILON ? wind_dir / wind_length : vec2(1.0, 0.0);
	float wind_speed_effective = max(params.wind.z, 0.0) * clamp(params.wind.w, 0.0, 0.5);
	float wind_age_weight = mix(WIND_NEWBORN_FRACTION, 1.0, 1.0 - wave_affinity);
	float wind_weight = wind_speed_effective * wind_age_weight * local_wind_variation;
	vec3 velocity = vec3(wind_dir.x, 0.0, wind_dir.y) * wind_weight;

	// --- Wave: newborn spray keeps the motion it inherited from the crest ---
	float wave_weight = max(params.wave.x, 0.0) * wave_affinity * local_wave_variation;
	velocity += vec3(propagation.x, 0.0, propagation.y) * wave_weight;

	// --- Curl: real 3D advection, spatially non-uniform ---------------------
	vec3 curl_p = world * max(params.curl.y, EPSILON) + vec3(0.0, 0.0, params.volume_extent_time.w * params.curl.z);
	velocity += divergence_free_field(curl_p) * (max(params.curl.x, 0.0) * local_curl_variation);

	// --- Vertical lift: fine droplets separating from the water, not smoke --
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
		advected = textureLod(state_previous, sampled_uvw, 0.0).rg;
	}
	if (!finite_pair(advected)) {
		advected = vec2(0.0);
	}
	advected = max(advected, vec2(0.0));

	// --- Frame-rate independent decay. Wave memory always decays faster ----
	advected.r *= exp(-max(params.decay.x, 0.0) * dt);
	advected.g *= exp(-max(params.decay.y, 0.0) * dt);

	// --- Crest G injection: thin band on the DISPLACED water surface --------
	float height = world.y - displaced_surface_y;
	float injection_full = max(params.injection.z, 0.01);
	float injection_top = max(params.injection.w, injection_full + 0.01);
	float band = smoothstep(-INJECTION_BELOW_SURFACE_M, injection_full, height) * (1.0 - smoothstep(injection_full, injection_top, height));
	float threshold = clamp(params.injection.x, 0.0, 1.0);
	float activity = crest_activity(source_xz);
	float shaped = clamp((activity - threshold) / max(1.0 - threshold, 0.001), 0.0, 1.0);
	shaped = shaped * shaped * (3.0 - 2.0 * shaped) * max(params.injection.y, 0.0);
	float injected = shaped * band * max(params.decay.z, 0.0) * dt;
	vec2 next_state = advected + vec2(injected, injected);

	// Mass bookkeeping. Wave memory can never exceed density, and density can
	// never run away, so a hitch or an extreme profile cannot poison the field.
	next_state.r = clamp(next_state.r, 0.0, min(max(params.decay.w, 0.0), MAX_MASS_HARD_LIMIT));
	next_state.g = clamp(next_state.g, 0.0, next_state.r);
	if (!finite_pair(next_state)) {
		next_state = vec2(0.0);
	}
	imageStore(state_next, cell, vec4(next_state.r, next_state.g, 0.0, 0.0));
}
