#[compute]
#version 450

// POST_SKY runs after opaque color/depth and sky resolve, before transparent
// materials sample the background. The projected contribution is therefore
// visible through the existing Production water transmission path.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D caustics_texture;
layout(set = 0, binding = 3) uniform sampler2D luma_gradient;
layout(set = 0, binding = 4) uniform sampler2D displacement_long;
layout(set = 0, binding = 5) uniform sampler2D displacement_mid;
layout(set = 0, binding = 6) uniform sampler2D displacement_short;
layout(set = 0, binding = 7) uniform sampler2D coastal_field;
layout(set = 0, binding = 8) uniform sampler2D coastal_warp;

layout(set = 0, binding = 9, std140) uniform Params {
	mat4 inverse_view_projection;
	vec4 viewport; // width, height, unused, unused
	vec4 caustics; // sea level, tiling (1 / scale), strength, power
	vec4 lighting; // speed, chroma split, luminance-mask strength, sun strength
	vec4 layer_a; // speed multiplier, scale multiplier, panner direction xy
	vec4 layer_b; // speed multiplier, scale multiplier, panner direction xy
	vec4 fade; // start depth, max depth, time, enabled/debug
	vec4 sun; // surface -> sun direction, unused
	vec4 ocean_space; // x = horizontal clipmap scale, y = vertical ocean scale, z/w = camera x/z
	vec4 domains; // LONG, MID, SHORT world-space FFT domains
	vec4 long_fade; // start/end distance, unused
	vec4 mid_fade; // start/end distance, unused
	vec4 short_fade; // start/end distance, unused
	vec4 coastal_origin_extent; // xy origin, zw extent
	vec4 coastal_warp_origin_extent; // xy warp origin, zw warp extent
	vec4 coastal_control; // x enabled, y warp detJ safety
	vec4 surface_controls; // x cutoff offset, y soft-entry fade distance
} params;


float fade_weight(float distance_m, vec2 range_m) {
	float start_m = range_m.x;
	float end_m = max(range_m.y, start_m + 0.001);
	return 1.0 - smoothstep(start_m, end_m, distance_m);
}


vec2 world_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}


vec2 coastal_uv_from_world(vec2 world_xz, vec2 origin, vec2 extent) {
	return (world_xz - origin) / max(extent, vec2(0.001));
}


float coastal_confidence_value(vec4 warp, float detj_safe) {
	return smoothstep(0.0, detj_safe, warp.z) * warp.w;
}


float sample_dynamic_surface_height(vec2 world_xz) {
	float distance_m = distance(world_xz, vec2(params.ocean_space.z, params.ocean_space.w));
	float long_weight = fade_weight(distance_m, params.long_fade.xy);
	float mid_weight = fade_weight(distance_m, params.mid_fade.xy);
	float short_weight = fade_weight(distance_m, params.short_fade.xy);
	vec3 long_displacement = textureLod(
		displacement_long, world_uv(world_xz, params.domains.x), 0.0
	).xyz;
	if (params.coastal_control.x > 0.5) {
		vec2 coast_uv = coastal_uv_from_world(
			world_xz, params.coastal_origin_extent.xy, params.coastal_origin_extent.zw
		);
		if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
			vec2 warp_uv = coastal_uv_from_world(
				world_xz, params.coastal_warp_origin_extent.xy, params.coastal_warp_origin_extent.zw
			);
			vec4 field = textureLod(coastal_field, coast_uv, 0.0);
			vec4 warp = textureLod(coastal_warp, clamp(warp_uv, vec2(0.0), vec2(1.0)), 0.0);
			float confidence = field.a * coastal_confidence_value(warp, params.coastal_control.y);
			vec3 warped_long = textureLod(
				displacement_long, world_uv(warp.xy, params.domains.x), 0.0
			).xyz;
			long_displacement = mix(long_displacement, warped_long, confidence);
			long_displacement.y *= mix(1.0, field.g, confidence);
		}
	}
	vec3 authored_displacement = long_displacement * long_weight;
	authored_displacement += textureLod(
		displacement_mid, world_uv(world_xz, params.domains.y), 0.0
	).xyz * mid_weight;
	authored_displacement += textureLod(
		displacement_short, world_uv(world_xz, params.domains.z), 0.0
	).xyz * short_weight;
	return authored_displacement.y * params.ocean_space.y;
}


vec3 sample_caustics(vec2 uv, float split) {
	if (split <= 0.000001) {
		float value = texture(caustics_texture, uv).r;
		return vec3(value);
	}
	return vec3(
		texture(caustics_texture, uv + vec2(split, split)).r,
		texture(caustics_texture, uv + vec2(split, -split)).r,
		texture(caustics_texture, uv + vec2(-split, -split)).r
	);
}


void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.viewport.xy);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	if (params.fade.w < 0.5) {
		return;
	}
	float raw_depth = texelFetch(scene_depth, pixel, 0).r;
	if (!(raw_depth > 0.000001) || raw_depth > 1.000001) {
		return;
	}
	vec2 screen_uv = (vec2(pixel) + vec2(0.5)) / params.viewport.xy;
	vec2 ndc = screen_uv * 2.0 - 1.0;
	vec4 world_position = params.inverse_view_projection * vec4(ndc, raw_depth, 1.0);
	if (abs(world_position.w) <= 0.000001) {
		return;
	}
	world_position /= world_position.w;
	if (any(isnan(world_position.xyz)) || any(isinf(world_position.xyz))) {
		return;
	}

	float surface_y = params.caustics.x + sample_dynamic_surface_height(world_position.xz);
	float effective_surface_y = surface_y - params.surface_controls.x;
	float water_column = effective_surface_y - world_position.y;
	if (water_column <= 0.0) {
		return;
	}
	float water_depth = max(surface_y - world_position.y, 0.0);
	float surface_fade = 1.0;
	if (params.surface_controls.y > 0.0001) {
		surface_fade = smoothstep(0.0, params.surface_controls.y, water_column);
	}
	float depth_mask = 1.0 - smoothstep(
		params.fade.x,
		max(params.fade.y, params.fade.x + 0.001),
		water_depth
	);
	if (depth_mask <= 0.0001) {
		return;
	}

	vec3 light = normalize(params.sun.xyz);
	float sun_height = smoothstep(0.04, 0.45, light.y);
	float sun_mask = mix(1.0, sun_height, params.lighting.w);
	if (sun_mask <= 0.0001) {
		return;
	}
	vec4 color = imageLoad(color_image, pixel);
	vec2 sun_axis = vec2(light.x, light.z);
	if (dot(sun_axis, sun_axis) < 0.000001) {
		sun_axis = vec2(0.0, 1.0);
	} else {
		sun_axis = normalize(sun_axis);
	}
	vec2 sun_tangent = vec2(-sun_axis.y, sun_axis.x);
	vec2 projected = vec2(
		dot(world_position.xz, sun_tangent),
		dot(world_position.xz, sun_axis)
	) * params.caustics.y;

	float time = params.fade.z;
	vec2 uv_a = fract(
		projected * params.layer_a.y +
		params.layer_a.zw * (time * params.lighting.x * params.layer_a.x)
	);
	vec2 uv_b = fract(
		projected * params.layer_b.y +
		params.layer_b.zw * (time * params.lighting.x * params.layer_b.x)
	);
	vec3 layer_a = pow(max(sample_caustics(uv_a, params.lighting.y), vec3(0.0)), vec3(max(params.caustics.w, 0.01)));
	vec3 layer_b = pow(max(sample_caustics(uv_b, params.lighting.y), vec3(0.0)), vec3(max(params.caustics.w, 0.01)));
	vec3 caustic = min(layer_a, layer_b) * params.caustics.z;

	float luminance = dot(max(color.rgb, vec3(0.0)), vec3(0.299, 0.587, 0.114));
	float gradient_luma = texture(luma_gradient, vec2(clamp(luminance, 0.0, 1.0), 0.5)).r;
	float luminance_mask = mix(1.0, gradient_luma, params.lighting.z);
	caustic *= depth_mask * sun_mask * luminance_mask * surface_fade;

	if (params.fade.w > 1.5) {
		color.rgb = caustic;
	} else {
		color.rgb += caustic;
	}
	imageStore(color_image, pixel, color);
}
