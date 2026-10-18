// Shared by the visible surface and underwater's raster/sensor. Coordinates,
// temporal interpolation, amplitude cap and display falloff must stay identical.
vec3 hull_wave_projected_sample(sampler2D current_field, sampler2D previous_field,
		vec2 world, vec2 origin, vec2 previous_origin, float blend,
		float max_height, bool physical, vec2 camera_xz) {
	vec2 uv = (world - origin) / 128.0;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return vec3(0.0);
	vec3 field = textureLod(current_field, uv, 0.0).rgb;
	vec2 previous_uv = (world - previous_origin) / 128.0;
	vec3 previous = vec3(0.0);
	if (all(greaterThanEqual(previous_uv, vec2(0.0))) && all(lessThanEqual(previous_uv, vec2(1.0)))) {
		previous = textureLod(previous_field, previous_uv, 0.0).rgb;
	}
	field = mix(previous, field, clamp(blend, 0.0, 1.0));
	float cap = max(max_height, 0.001);
	float knee = cap * 0.75;
	float slope_scale = 1.0;
	if (abs(field.x) > knee) {
		float tail = exp(-(abs(field.x) - knee) / (cap - knee));
		field.x = sign(field.x) * (knee + (cap - knee) * (1.0 - tail));
		slope_scale = tail;
	}
	float fade = physical
		? 1.0 - smoothstep(56.0, 64.0, max(abs(world.x - origin.x - 64.0), abs(world.y - origin.y - 64.0)))
		: 1.0 - smoothstep(18.0, 35.0, length(world - camera_xz));
	return vec3(field.x, field.yz * slope_scale) * fade;
}
