uniform bool hull_waves_enabled = false;
uniform bool hull_waves_physical = false;
uniform sampler2D hull_waves_texture : filter_linear, repeat_disable;
uniform sampler2D hull_waves_previous_texture : filter_linear, repeat_disable;
uniform vec2 hull_waves_origin = vec2(0.0);
uniform vec2 hull_waves_previous_origin = vec2(0.0);
uniform float hull_waves_blend = 1.0;
uniform float hull_waves_max_height = 2.0;
uniform int hull_waves_debug = 0;
vec3 hull_wave_sample(vec2 world) {
	if (!hull_waves_enabled) { return vec3(0.0); }
	vec2 uv=(world-hull_waves_origin)/128.0;
	if(any(lessThan(uv,vec2(0))) || any(greaterThan(uv,vec2(1)))) { return vec3(0); }
	vec3 field=textureLod(hull_waves_texture,uv,0.0).rgb;
	vec2 previous_uv=(world-hull_waves_previous_origin)/128.0;
	vec3 previous=vec3(0.0);
	if(all(greaterThanEqual(previous_uv,vec2(0))) && all(lessThanEqual(previous_uv,vec2(1)))) {
		previous=textureLod(hull_waves_previous_texture,previous_uv,0.0).rgb;
	}
	field=mix(previous,field,clamp(hull_waves_blend,0.0,1.0));
	float cap=max(hull_waves_max_height,0.001);
	// Preserve useful amplitudes below the knee, then approach the safety cap.
	float knee=cap*0.75;
	float slope_scale=1.0;
	if(abs(field.x)>knee) {
		float tail=exp(-(abs(field.x)-knee)/(cap-knee));
		field.x=sign(field.x)*(knee+(cap-knee)*(1.0-tail));
		slope_scale=tail;
	}
	// Physics uses world packets, independent of the camera. Keep full display
	// throughout the useful atlas, feathering only its distant storage border.
	float fade=hull_waves_physical ? 1.0-smoothstep(56.0,64.0,max(abs(world.x-hull_waves_origin.x-64.0),abs(world.y-hull_waves_origin.y-64.0))) : 1.0-smoothstep(18.0,35.0,length(world-camera_world_xz));
	return vec3(field.x,field.yz*slope_scale)*fade;
}
