#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rg32f, set = 0, binding = 0) readonly uniform image2D previous_fields;
layout(rg32f, set = 0, binding = 1) writeonly uniform image2D next_fields;
layout(set = 0, binding = 2, std140) uniform Params {
	vec4 region;   // new origin XZ, old origin XZ
	vec4 sim;      // delta, energy decay, stamp count, cell size
	vec4 controls; // intensity, base width, coverage, enabled
	vec4 response; // foam rise, foam decay, stamp energy, foam target ceiling
} params;
layout(set = 0, binding = 3, std430) readonly buffer StampBuffer {
	vec4 stamps[]; // position/strength/type, direction/width/length
};

const int MAX_STAMPS = 24;

float patch_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	vec4 h = fract(sin(vec4(dot(i, vec2(127.1, 311.7)), dot(i + vec2(1, 0), vec2(127.1, 311.7)),
		dot(i + vec2(0, 1), vec2(127.1, 311.7)), dot(i + vec2(1, 1), vec2(127.1, 311.7)))) * 43758.5453);
	return mix(mix(h.x, h.y, f.x), mix(h.z, h.w, f.x), f.y);
}

float stamp_energy(vec2 world_xz, int index) {
	int base = index * 3;
	vec4 source = stamps[base];
	vec4 heading = stamps[base + 1];
	vec2 from_source = world_xz - source.xy;
	float radius = length(from_source);
	float intensity = source.z * params.controls.x;
	if (source.w > 0.5) {
		float core = exp(-pow(radius / 1.25, 2.0));
		return core * (0.25 + patch_noise(world_xz * 2.1)) * intensity * 13.0;
	}
	vec2 direction = normalize(heading.xy + vec2(0.0001));
	float behind = -dot(from_source, direction);
	float lateral = abs(dot(from_source, vec2(-direction.y, direction.x)));
	float width = max(params.controls.y, 0.3) * 0.55;
	// One compact, soft stern churn stamp. No diagonal arms are painted here.
	float local = exp(-pow((behind - 0.35) / 0.9, 2.0) - pow(lateral / width, 2.0));
	float noise = 0.35 + 0.9 * patch_noise(world_xz * 1.7);
	return local * noise * intensity;
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(next_fields);
	if (any(greaterThanEqual(pixel, size))) return;
	float cell = params.sim.w;
	vec2 world_xz = params.region.xy + (vec2(pixel) + vec2(0.5)) * cell;
	ivec2 previous_pixel = ivec2(floor((world_xz - params.region.zw) / cell));
	vec2 fields = vec2(0.0);
	if (all(greaterThanEqual(previous_pixel, ivec2(0))) && all(lessThan(previous_pixel, size))) {
		fields = imageLoad(previous_fields, previous_pixel).rg;
	}
	float dt = params.sim.x;
	float neighbor_energy = 0.0;
	float neighbor_count = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			if (abs(x) + abs(y) != 1) continue;
			ivec2 neighbor_pixel = previous_pixel + ivec2(x, y);
			if (all(greaterThanEqual(neighbor_pixel, ivec2(0))) && all(lessThan(neighbor_pixel, size))) {
				neighbor_energy += imageLoad(previous_fields, neighbor_pixel).r;
				neighbor_count += 1.0;
			}
		}
	}
	float energy = fields.r;
	if (neighbor_count > 0.0) {
		float spread = clamp(dt * 1.0, 0.0, 0.05);
		energy = mix(energy, neighbor_energy / neighbor_count, spread);
	}
	float erosion = patch_noise(world_xz * 0.83);
	energy *= exp(-dt * (0.65 + erosion * 1.10) / max(params.sim.y, 0.25));
	if (params.controls.w > 0.5) {
		int stamp_count = min(int(params.sim.z), MAX_STAMPS);
		for (int i = 0; i < stamp_count; i++) {
			energy += stamp_energy(world_xz, i) * params.response.z;
		}
	}
	energy = clamp(energy, 0.0, 1.0);
	// A single fast-moving stamp peaks near 0.08 energy. The old 0.08..0.38
	// response barely generated G at all; reading R concealed that mismatch.
	float target_foam = smoothstep(0.012, 0.14, energy) * params.response.w;
	float rate = target_foam > fields.g ? params.response.x : params.response.y;
	if (target_foam < fields.g) rate *= 0.55 + erosion * 1.4;
	float foam = mix(fields.g, target_foam, 1.0 - exp(-dt * rate));
	imageStore(next_fields, pixel, vec4(energy, clamp(foam, 0.0, 1.0), 0.0, 1.0));
}
