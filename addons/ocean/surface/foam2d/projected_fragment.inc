	// Projection samples the actual deformed Ocean vertices. No overlay geometry.
	// This clipmap's top triangles report FRONT_FACING=false. Use the authored
	// upward FFT normal and which side of the surface the viewer occupies.
	float projected_filament_debug = 0.0;
	float projected_running_debug = 0.0;
	vec3 projected_up = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 projected_to_camera = normalize(CAMERA_POSITION_WORLD - ocean_world_position);
	bool projected_upper_face = dot(projected_up, projected_to_camera) > 0.0;
	if (projected_upper_face && surface_air_blend > 0.95 && underwater_camera_signed_distance_m > 0.0) {
		float projected_white = 0.0;
		if (foam2d_contact_enabled || foam2d_wake_enabled) {
			vec2 projected_uv = (ocean_world_position.xz - interaction_foam_origin_xz) / interaction_foam_domain_m;
			if (all(greaterThanEqual(projected_uv,vec2(0.0))) && all(lessThan(projected_uv,vec2(1.0)))) {
				vec4 history = texture(interaction_foam_texture, projected_uv);
				float running_contact=foam2d_running_contact(ocean_world_position);
				if (history.r > 0.001 || running_contact > 0.001) {
				float agitation=clamp(history.a/max(history.r,0.001),0.0,1.0);
				vec2 world = ocean_world_position.xz;
				vec2 warp=vec2(foam2d_noise(world*0.21),foam2d_noise(world*0.21+vec2(31.8,17.4)))-0.5;
				vec2 filament_world=world;
				if (foam2d_filament_deformation > 0.001) {
					float evolution=foam2d_time*foam2d_filament_speed;
					// Independent local deformations bend different strands in
					// different directions. The history/coverage coordinates stay fixed.
					vec2 deformation=vec2(
						foam2d_noise(world*1.15+vec2(evolution*0.43,-evolution*0.31)+vec2(7.8,31.4)),
						foam2d_noise(mat2(vec2(0.8,-0.6),vec2(0.6,0.8))*world*1.07+vec2(-evolution*0.37,evolution*0.29)+vec2(51.2,13.6)))*2.0-1.0;
					filament_world+=deformation*foam2d_filament_deformation;
				}
				vec2 pigment_velocity=clamp(history.gb/max(history.r,0.001),vec2(-3.0),vec2(3.0));
				float grain;
				float fine;
				if (foam2d_transport_detail && dot(pigment_velocity,pigment_velocity)>0.0004) {
					// Two offset phases transport strands with the pigment. Each
					// reset has zero weight, so the UV never visibly snaps back.
					float phase=fract(foam2d_time*0.23);
					float other_phase=fract(foam2d_time*0.19+0.5);
					float first_weight=1.0-abs(phase*2.0-1.0);
					float second_weight=1.0-abs(other_phase*2.0-1.0);
					float blend=first_weight/max(first_weight+second_weight,0.0001);
					vec2 first=filament_world-pigment_velocity*(phase-0.5)/0.23;
					vec2 second=filament_world-pigment_velocity*(other_phase-0.5)/0.19;
					grain=mix(foam2d_stochastic_grain(second+warp*foam2d_variation*1.7),foam2d_stochastic_grain(first+warp*foam2d_variation*1.7),blend);
					grain=clamp((grain-0.5)/sqrt(max(blend*blend+(1.0-blend)*(1.0-blend),0.001))+0.5,0.0,1.0);
					fine=mix(foam2d_noise(second*4.7/max(foam2d_patch_size,0.3)+warp*2.3),foam2d_noise(first*4.7/max(foam2d_patch_size,0.3)+warp*2.3),blend);
				} else {
					grain=foam2d_stochastic_grain(filament_world+warp*foam2d_variation*1.7);
					fine=foam2d_noise(filament_world*4.7/max(foam2d_patch_size,0.3)+warp*2.3);
				}
				float threads=1.0-smoothstep(0.035,0.17,abs(grain-0.5));
				float erosion=mix(0.6,clamp(threads*(0.35+fine*0.65),0.0,1.0),foam2d_variation);
				float border = smoothstep(0.0,0.02,min(min(projected_uv.x,projected_uv.y),min(1.0-projected_uv.x,1.0-projected_uv.y)));
				float wake=clamp(pow(history.r,0.85)*border*foam2d_opacity,0.0,0.8);
				// Keep the low-density tail continuous. In particular, the calm
				// sqrt response must not amplify the field's discard threshold.
				float feather=smoothstep(0.001,0.035,history.r);
				if (!foam2d_wake_enabled) wake *= foam2d_contact(ocean_world_position).x;
				projected_filament_debug=wake*erosion*feather;
				float turbulent=smoothstep(foam2d_white_threshold,foam2d_white_threshold+foam2d_white_transition,agitation);
				float white=wake*erosion*turbulent*foam2d_white_strength*feather;
				// A separate blue filament floor keeps calm wet contact perceptible.
				// It uses the same irregular history and fades with that history.
				float calm=clamp(sqrt(wake)*erosion*foam2d_calm_strength*(1.0-turbulent)*feather,0.0,0.65);
				wake*=feather;
				projected_white=max(projected_white,white);
				ALBEDO=mix(ALBEDO,foam2d_water_tint.rgb,wake*foam2d_tint_strength);
				ALBEDO=mix(ALBEDO,mix(foam2d_water_tint.rgb,foam2d_white_color.rgb,0.35),calm);
				ALBEDO=mix(ALBEDO,foam2d_white_color.rgb,clamp(white,0.0,0.85));
				float optical=clamp(wake*0.6+white+calm*0.5,0.0,1.0);
				ROUGHNESS=mix(ROUGHNESS,foam2d_roughness,optical);
				SPECULAR=mix(SPECULAR,foam2d_specular,optical);
				NORMAL=normalize(NORMAL+(VIEW_MATRIX*vec4((grain-0.5)*wake*foam2d_normal_strength,0.0,(fine-0.5)*wake*foam2d_normal_strength,0.0)).xyz);
				// Independently tunable local lather. Same strands, no new texture,
				// no persistent deposit and no change to the existing wake colour.
				float running=clamp(running_contact*erosion*foam2d_running_strength,0.0,0.95);
				projected_running_debug=running;
				vec3 running_color=mix(foam2d_water_tint.rgb,foam2d_running_color.rgb,foam2d_running_whiteness);
				ALBEDO=mix(ALBEDO,running_color,running);
				ROUGHNESS=mix(ROUGHNESS,foam2d_running_roughness,running);
				SPECULAR=mix(SPECULAR,foam2d_running_specular,running);
				NORMAL=normalize(NORMAL+(VIEW_MATRIX*vec4((grain-0.5)*running*foam2d_running_normal_strength,0.0,(fine-0.5)*running*foam2d_running_normal_strength,0.0)).xyz);
				}
			}
		}
		if (foam2d_debug == 1) { ALBEDO=vec3(0); EMISSION=vec3(projected_white); SPECULAR=0.0; ROUGHNESS=1.0; }
	}
	if (foam2d_debug == 4) { ALBEDO=vec3(0); EMISSION=vec3(projected_filament_debug); SPECULAR=0.0; ROUGHNESS=1.0; }
	if (foam2d_debug == 5) { ALBEDO=vec3(0); EMISSION=vec3(projected_running_debug); SPECULAR=0.0; ROUGHNESS=1.0; }
	if (foam2d_debug == 2) { ALBEDO=vec3(0); EMISSION=FRONT_FACING?vec3(0,1,0):vec3(1,0,0); }
	if (hull_waves_enabled && hull_waves_debug > 0) {
		vec3 field=hull_wave_sample(ocean_world_position.xz);
		ALBEDO=vec3(0.01); ROUGHNESS=1.0; SPECULAR=0.0;
		if (hull_waves_debug == 1) { EMISSION=vec3(max(field.x,0.0),0.0,max(-field.x,0.0))/max(hull_waves_max_height,0.001)*4.0; }
		if (hull_waves_debug == 2) { EMISSION=normalize(vec3(-field.y,1.0,-field.z))*0.5+0.5; }
	}
	if (foam2d_debug == 3) {
		vec2 duv=(ocean_world_position.xz-interaction_foam_origin_xz)/interaction_foam_domain_m;
		ALBEDO=vec3(0); EMISSION=vec3(texture(interaction_foam_texture,duv).r*4.0);
	}
