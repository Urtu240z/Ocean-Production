#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D displacement_long;
layout(set = 0, binding = 1) uniform sampler2D displacement_mid;
layout(set = 0, binding = 2) uniform sampler2D displacement_short;
layout(set = 0, binding = 3) uniform sampler2D coastal_field;
layout(set = 0, binding = 4) uniform sampler2D coastal_warp;
layout(set = 0, binding = 5, std430) readonly buffer ProbeCoordinates { vec4 coordinates[]; };
layout(set = 0, binding = 6, std430) writeonly buffer ProbeResults { vec4 values[]; };
layout(push_constant, std430) uniform ProbeParameters {
	uvec4 counts;
	vec4 params;
} probe;

vec3 sample_periodic_lattice(sampler2D source, vec2 uv) {
	ivec2 dimensions = textureSize(source, 0);
	vec2 texel = uv * vec2(dimensions) - vec2(0.5);
	ivec2 lo = ivec2(floor(texel));
	vec2 fraction = texel - vec2(lo);
	ivec2 hi = lo + ivec2(1);
	ivec2 lo_wrapped = ivec2((lo.x % dimensions.x + dimensions.x) % dimensions.x,
		(lo.y % dimensions.y + dimensions.y) % dimensions.y);
	ivec2 hi_wrapped = ivec2((hi.x % dimensions.x + dimensions.x) % dimensions.x,
		(hi.y % dimensions.y + dimensions.y) % dimensions.y);
	vec3 p00 = texelFetch(source, ivec2(lo_wrapped.x, lo_wrapped.y), 0).xyz;
	vec3 p10 = texelFetch(source, ivec2(hi_wrapped.x, lo_wrapped.y), 0).xyz;
	vec3 p01 = texelFetch(source, ivec2(lo_wrapped.x, hi_wrapped.y), 0).xyz;
	vec3 p11 = texelFetch(source, ivec2(hi_wrapped.x, hi_wrapped.y), 0).xyz;
	return mix(mix(p00, p10, fraction.x), mix(p01, p11, fraction.x), fraction.y);
}

vec4 sample_clamped_bilinear(sampler2D source, vec2 uv) {
	ivec2 dimensions = textureSize(source, 0);
	vec2 texel = uv * vec2(dimensions) - vec2(0.5);
	ivec2 lo = ivec2(floor(texel));
	vec2 fraction = texel - vec2(lo);
	ivec2 hi = lo + ivec2(1);
	ivec2 lo_clamped = clamp(lo, ivec2(0), dimensions - ivec2(1));
	ivec2 hi_clamped = clamp(hi, ivec2(0), dimensions - ivec2(1));
	vec4 p00 = texelFetch(source, ivec2(lo_clamped.x, lo_clamped.y), 0);
	vec4 p10 = texelFetch(source, ivec2(hi_clamped.x, lo_clamped.y), 0);
	vec4 p01 = texelFetch(source, ivec2(lo_clamped.x, hi_clamped.y), 0);
	vec4 p11 = texelFetch(source, ivec2(hi_clamped.x, hi_clamped.y), 0);
	return mix(mix(p00, p10, fraction.x), mix(p01, p11, fraction.x), fraction.y);
}

void main() {
	uint index = gl_GlobalInvocationID.x;
	if (index >= probe.counts.x) { return; }
uint base = index * 4u;
	vec4 coastal_uvs = coordinates[base];       // field.xy, warp.zw
	vec4 long_uv_domain = coordinates[base + 1u]; // long.xy, LONG domain in z
	vec4 mid_short_uvs = coordinates[base + 2u]; // mid.xy, short.zw
	vec4 warped_long_uv_domain = coordinates[base + 3u]; // CPU-manual warp.xy, LONG domain in z
	vec4 field = texture(coastal_field, coastal_uvs.xy);
	vec4 warp_hardware = texture(coastal_warp, coastal_uvs.zw);
	vec4 warp = sample_clamped_bilinear(coastal_warp, coastal_uvs.zw);
	vec3 long_open = texture(displacement_long, long_uv_domain.xy).xyz;
	vec2 hardware_warped_uv = warp_hardware.xy / max(long_uv_domain.z, 0.001) + vec2(0.5);
	vec2 warped_uv = warp.xy / max(long_uv_domain.z, 0.001) + vec2(0.5);
	vec3 long_warped_hardware = texture(displacement_long, hardware_warped_uv).xyz;
	vec3 long_warped = texture(displacement_long, warped_uv).xyz;
	bool in_coverage = all(greaterThanEqual(coastal_uvs.xy, vec2(0.0))) && all(lessThanEqual(coastal_uvs.xy, vec2(1.0)));
	float confidence = in_coverage ? field.a * smoothstep(0.0, probe.params.y, warp.z) * warp.w : 0.0;
	float confidence_hardware = in_coverage ? field.a * smoothstep(0.0, probe.params.y, warp_hardware.z) * warp_hardware.w : 0.0;
	vec3 long_coastal = mix(long_open, long_warped, confidence);
	long_coastal.y *= mix(1.0, field.g, confidence);
	vec3 long_coastal_hardware = mix(long_open, long_warped_hardware, confidence_hardware);
	long_coastal_hardware.y *= mix(1.0, field.g, confidence_hardware);
	vec3 mid_value = texture(displacement_mid, mid_short_uvs.xy).xyz;
	vec3 short_value = texture(displacement_short, mid_short_uvs.zw).xyz;
	vec3 long_open_lattice = sample_periodic_lattice(displacement_long, long_uv_domain.xy);
	vec3 long_warped_lattice = sample_periodic_lattice(displacement_long, warped_long_uv_domain.xy);
	vec3 mid_lattice = sample_periodic_lattice(displacement_mid, mid_short_uvs.xy);
	vec3 short_lattice = sample_periodic_lattice(displacement_short, mid_short_uvs.zw);
	values[index * 18u + 0u] = field;
	values[index * 18u + 1u] = warp_hardware;
	values[index * 18u + 2u] = vec4(long_open, confidence);
	values[index * 18u + 3u] = vec4(long_coastal, 0.0);
	values[index * 18u + 4u] = vec4(long_coastal + mid_value + short_value, 0.0);
	values[index * 18u + 15u] = vec4(long_coastal_hardware + mid_value + short_value, 0.0);
	// Exact lattice values for a deterministic manual bilinear FFT reconstruction.
	// This path reads only the four texels surrounding each requested sample.
	uint ref_base = index * 18u + 5u;
	values[ref_base + 0u] = vec4(long_open_lattice, 0.0);
	values[ref_base + 1u] = vec4(long_warped_lattice, 0.0);
	values[ref_base + 2u] = vec4(mid_lattice, 0.0);
	values[ref_base + 3u] = vec4(short_lattice, 0.0);
	// Validation-only variants: preserve hardware Field while switching only Warp,
	// then switch both Coastal fields to deterministic clamp-to-edge bilinear.
	vec4 manual_warp = sample_clamped_bilinear(coastal_warp, coastal_uvs.zw);
	vec2 manual_warped_uv = manual_warp.xy / max(long_uv_domain.z, 0.001) + vec2(0.5);
	vec3 long_manual_warped = texture(displacement_long, manual_warped_uv).xyz;
	float confidence_manual_warp = in_coverage ? field.a * smoothstep(0.0, probe.params.y, manual_warp.z) * manual_warp.w : 0.0;
	vec3 long_manual_warp_only = mix(long_open, long_manual_warped, confidence_manual_warp);
	long_manual_warp_only.y *= mix(1.0, field.g, confidence_manual_warp);
	values[index * 18u + 9u] = manual_warp;
	values[index * 18u + 10u] = vec4(long_manual_warp_only + mid_value + short_value, 0.0);
	vec4 manual_field = sample_clamped_bilinear(coastal_field, coastal_uvs.xy);
	values[index * 18u + 11u] = manual_field;
	float confidence_manual_both = in_coverage ? manual_field.a * smoothstep(0.0, probe.params.y, manual_warp.z) * manual_warp.w : 0.0;
	vec3 long_manual_both = mix(long_open, long_manual_warped, confidence_manual_both);
	long_manual_both.y *= mix(1.0, manual_field.g, confidence_manual_both);
	values[index * 18u + 12u] = vec4(long_manual_both + mid_value + short_value, 0.0);
	values[index * 18u + 13u] = vec4(long_warped_hardware, 0.0);
	values[index * 18u + 14u] = vec4(long_warped, 0.0);
	vec3 long_manual_fft_warp = mix(long_open_lattice, long_warped_lattice, confidence_manual_warp);
	long_manual_fft_warp.y *= mix(1.0, field.g, confidence_manual_warp);
	values[index * 18u + 16u] = vec4(long_manual_fft_warp + mid_lattice + short_lattice, 0.0);
	vec3 long_manual_fft_both = mix(long_open_lattice, long_warped_lattice, confidence_manual_both);
	long_manual_fft_both.y *= mix(1.0, manual_field.g, confidence_manual_both);
	values[index * 18u + 17u] = vec4(long_manual_fft_both + mid_lattice + short_lattice, 0.0);
}
