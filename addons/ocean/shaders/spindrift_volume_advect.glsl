#[compute]
#version 450
// H4.33 Ocean V4 persistent volumetric spindrift, advection pass.
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
// Velocity is deliberately heterogeneous, never a rigid block move:
//   velocity = wind(wave_affinity, flow_variation)
//            + wave_push * local_wave_direction * wave_affinity
//            + curl_3d(flow_variation)
//            + vertical lift(density, flow_variation)
// No Navier-Stokes, no pressure projection, no FLIP.

layout(local_size_x = 8, local_size_y = 4, local_size_z = 8) in;

layout(set = 0, binding = 0) uniform sampler3D state_previous;
layout(rg16f, set = 0, binding = 1) uniform restrict writeonly image3D state_next;
// Crest G of the LONG crest texture: the same OpenOceanBreakingActivity
// authority the H4.31 particle spindrift consumes. Injection only.
layout(set = 0, binding = 2) uniform sampler2D breaking_activity_long;
// LONG displacement, used only for the local wave propagation direction with
// the exact finite-difference semantics of spindrift_event_particles.gdshader.
layout(set = 0, binding = 3) uniform sampler2D displacement_long;

layout(set = 0, binding = 4, std140) uniform AdvectParams {
	vec4 volume_origin_dt;      // xyz world origin of the destination grid, w dt
	vec4 volume_extent_time;    // xyz world extent of the grid, w simulation time
	vec4 previous_origin_valid; // xyz world origin of the previous grid, w 1 if history is usable
	vec4 domains_resolution;    // xyz FFT domain sizes in metres, w unused
	vec4 wind;                  // xy atmospheric wind direction (world XZ), z wind speed m/s, w unused
	vec4 decay;                 // x density decay 1/s, y wave memory decay 1/s, z injection turnover 1/s, w max mass
	vec4 injection;             // x crest threshold, y source gain, z injection full height m, w injection top height m
	vec4 wave;                  // x wave push m/s, y steady state affinity ratio, z wave gradient step m, w unused
	vec4 curl;                  // x curl strength m/s, y curl scale 1/m, z curl time rate, w unused
	vec4 variation;             // x variation strength, y variation scale 1/m, z variation time rate, w lift m/s
	vec4 ocean_space;           // x sea level, y clipmap geometry scale, z ocean scale, w unused
} params;

const float EPSILON = 0.0001;
// How much of the wind still acts on freshly injected, wave-coupled spray.
const float WIND_NEWBORN_FRACTION = 0.35;
const float AFFINITY_GAIN_FLOOR = 0.02;
const float MAX_MASS_HARD_LIMIT = 8.0;
// Second octave of the analytic divergence-free field.
const float CURL_SECOND_OCTAVE = 0.35;
const float CURL_SECOND_SCALE = 1.91;
const vec3 CURL_SECOND_OFFSET = vec3(13.7, -7.1, 3.9);
// The free surface reference. Injection is thin and sits on the water plane.
const float INJECTION_BELOW_SEA_M = 0.25;

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
float crest_activity(vec2 world_xz) {
	vec2 uv = world_xz / max(params.domains_resolution.x, EPSILON) + vec2(0.5);
	return clamp(textureLod(breaking_activity_long, uv, 0.0).g, 0.0, 1.0);
}

// Exact H4.31 local wave propagation semantics: finite difference of the LONG
// displacement height at +-step in X and Z, normalised. Atmospheric wind is
// never substituted for this.
vec2 wave_direction(vec2 world_xz) {
	float step_m = max(params.wave.z, 0.25);
	float domain_m = max(params.domains_resolution.x, EPSILON);
	float h_x0 = textureLod(displacement_long, (world_xz - vec2(step_m, 0.0)) / domain_m + vec2(0.5), 0.0).y;
	float h_x1 = textureLod(displacement_long, (world_xz + vec2(step_m, 0.0)) / domain_m + vec2(0.5), 0.0).y;
	float h_z0 = textureLod(displacement_long, (world_xz - vec2(0.0, step_m)) / domain_m + vec2(0.5), 0.0).y;
	float h_z1 = textureLod(displacement_long, (world_xz + vec2(0.0, step_m)) / domain_m + vec2(0.5), 0.0).y;
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

	// Coherent low-frequency variation of how strongly a region responds to
	// wind, curl and lift. Slow in time, continuous in space, never flickering.
	vec3 variation_p = world * max(params.variation.y, EPSILON) + vec3(0.0, 0.0, params.volume_extent_time.w * params.variation.z);
	float variation = value_noise(variation_p) * 2.0 - 1.0;
	float flow_variation = 1.0 + variation * clamp(params.variation.x, 0.0, 1.0);
	flow_variation = clamp(flow_variation, 0.05, 2.0);

	// --- Wind: dominates older aerosol, reduced for wave-coupled spray ------
	vec2 wind_dir = params.wind.xy;
	float wind_length = length(wind_dir);
	wind_dir = wind_length > EPSILON ? wind_dir / wind_length : vec2(1.0, 0.0);
	float wind_weight = params.wind.z * mix(WIND_NEWBORN_FRACTION, 1.0, 1.0 - wave_affinity) * flow_variation;
	vec3 velocity = vec3(wind_dir.x, 0.0, wind_dir.y) * max(wind_weight, 0.0);

	// --- Wave: newborn spray keeps the motion it inherited from the crest ---
	vec2 propagation = wave_direction(world.xz);
	float wave_weight = max(params.wave.x, 0.0) * wave_affinity * max(flow_variation, 0.05);
	velocity += vec3(propagation.x, 0.0, propagation.y) * wave_weight;

	// --- Curl: real 3D advection, spatially non-uniform ---------------------
	vec3 curl_p = world * max(params.curl.y, EPSILON) + vec3(0.0, 0.0, params.volume_extent_time.w * params.curl.z);
	velocity += divergence_free_field(curl_p) * (max(params.curl.x, 0.0) * flow_variation);

	// --- Vertical lift: fine droplets separating from the water, not smoke --
	float lift_response = smoothstep(0.0, 0.30, local_density);
	velocity.y += max(params.variation.w, 0.0) * lift_response * max(flow_variation, 0.0);

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

	// --- Crest G injection: thin band on the ocean surface -----------------
	float height = world.y - params.ocean_space.x;
	float injection_full = max(params.injection.z, 0.01);
	float injection_top = max(params.injection.w, injection_full + 0.01);
	float band = smoothstep(-INJECTION_BELOW_SEA_M, injection_full, height) * (1.0 - smoothstep(injection_full, injection_top, height));
	float threshold = clamp(params.injection.x, 0.0, 1.0);
	float activity = crest_activity(world.xz);
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
