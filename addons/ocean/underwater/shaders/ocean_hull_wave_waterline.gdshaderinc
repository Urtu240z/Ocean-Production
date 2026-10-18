float hull_wave_height_at(vec2 world) {
	if (params.hull_wave_control.x < 0.5) return 0.0;
	return hull_wave_projected_sample(hull_waves_field, hull_waves_previous_field,
		world, params.hull_wave_origins.xy, params.hull_wave_origins.zw,
		params.hull_wave_control.y, params.hull_wave_control.z,
		params.hull_wave_control.w > 0.5, params.camera_sea.xz).x;
}
