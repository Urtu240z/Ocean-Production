	// Projection samples the actual deformed Ocean vertices. No overlay geometry.
	// This clipmap's top triangles report FRONT_FACING=false. Use the authored
	// upward FFT normal and which side of the surface the viewer occupies.
	float projected_filament_debug = 0.0;
	float projected_running_debug = 0.0;
	float projected_relief_mask = 0.0;
	float projected_relief_height = 0.0;
	float projected_relief_cavity = 0.0;
	float projected_fresh_coverage = 0.0;
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
				float relief_detail=0.5;
				if (foam2d_transport_detail && dot(pigment_velocity,pigment_velocity)>0.0004) {
					// Equal rates keep the phases half a cycle apart: one is fully
					// visible when the other resets, with no near-zero weight sum.
					float phase=fract(foam2d_time*0.23);
					float other_phase=fract(phase+0.5);
					float first_weight=pow(sin(phase*3.14159265),2.0);
					float second_weight=pow(sin(other_phase*3.14159265),2.0);
					float blend=first_weight/max(first_weight+second_weight,0.0001);
					vec2 first=filament_world-pigment_velocity*(phase-0.5)/0.23;
					vec2 second=filament_world-pigment_velocity*(other_phase-0.5)/0.23;
					grain=mix(foam2d_stochastic_grain(second+warp*foam2d_variation*1.7),foam2d_stochastic_grain(first+warp*foam2d_variation*1.7),blend);
					grain=clamp((grain-0.5)/sqrt(max(blend*blend+(1.0-blend)*(1.0-blend),0.001))+0.5,0.0,1.0);
					fine=mix(foam2d_noise(second*4.7/max(foam2d_patch_size,0.3)+warp*2.3),foam2d_noise(first*4.7/max(foam2d_patch_size,0.3)+warp*2.3),blend);
					if (foam2d_relief_enabled) {
						relief_detail=mix(foam2d_noise(second/max(foam2d_relief_detail_size_m,0.04)),foam2d_noise(first/max(foam2d_relief_detail_size_m,0.04)),blend);
					}
				} else {
					grain=foam2d_stochastic_grain(filament_world+warp*foam2d_variation*1.7);
					fine=foam2d_noise(filament_world*4.7/max(foam2d_patch_size,0.3)+warp*2.3);
					if (foam2d_relief_enabled) { relief_detail=foam2d_noise(filament_world/max(foam2d_relief_detail_size_m,0.04)); }
				}
				float threads=1.0-smoothstep(0.035,0.17,abs(grain-0.5));
				// Broad, world-coherent pockets are independent of fine strand size.
				// A soft noise field replaces repeated evenly filled filament patches.
				float pockets=smoothstep(0.48,0.78,foam2d_noise(filament_world/max(foam2d_white_patch_size_m,0.3)+warp*0.7+vec2(83.4,29.7)));
				float foam_structure=mix(threads,max(threads*0.65,pockets),foam2d_white_patch_strength);
				float erosion=mix(0.6,clamp(foam_structure*(0.35+fine*0.65),0.0,1.0),foam2d_variation);
				float border = smoothstep(0.0,0.02,min(min(projected_uv.x,projected_uv.y),min(1.0-projected_uv.x,1.0-projected_uv.y)));
				float wake=clamp(pow(history.r,0.85)*border*foam2d_opacity,0.0,0.8);
				// Keep the low-density tail continuous. In particular, the calm
				// sqrt response must not amplify the field's discard threshold.
				float feather=smoothstep(0.001,0.035,history.r);
				if (!foam2d_wake_enabled) wake *= foam2d_contact(ocean_world_position).x;
				projected_filament_debug=wake*erosion*feather;
				float turbulent=smoothstep(foam2d_white_threshold,foam2d_white_threshold+foam2d_white_transition,agitation);
				float white=wake*erosion*turbulent*foam2d_white_strength*feather;
				// Coverage-premultiplied birth speed travels with this pigment.
				// Stopping one hull never dims its old wake or another vehicle.
				float speed_white=foam2d_speed_white_strength.x;
				float fresh_wake=0.0;
				if (foam2d_speed_white_strength.x != foam2d_speed_white_strength.y || (foam2d_fresh_wake_enabled && foam2d_wake_enabled && foam2d_fresh_wake_strength>0.0)) {
					vec2 metadata=texture(foam2d_speed_texture,projected_uv).rg/max(history.r,0.001);
					float birth_kmh=metadata.r*3.6;
					float speed_blend=smoothstep(foam2d_white_speed_kmh.x,max(foam2d_white_speed_kmh.y,foam2d_white_speed_kmh.x+0.1),birth_kmh);
					speed_white=mix(foam2d_speed_white_strength.x,foam2d_speed_white_strength.y,speed_blend);
					if (foam2d_fresh_wake_enabled && foam2d_wake_enabled) {
						// G stores aft pigment times exp(-age), carried by the same
						// history. Decode a smooth finite settling time without moving
						// the old trail or inventing an attached white triangle.
						float freshness=pow(clamp(metadata.g,0.0,1.0),1.0/max(foam2d_fresh_wake_settling_s,0.05));
						fresh_wake=clamp(smoothstep(0.36787944,0.75,freshness)*speed_blend*foam2d_fresh_wake_strength,0.0,1.0);
					}
				}
				white*=speed_white;
				// Fresh stern foam fills strand gaps. Its soft footprint still comes
				// exclusively from deposited coverage and fades back to old filaments.
				float fresh_density=smoothstep(0.015,0.20,wake)*feather;
				projected_fresh_coverage=fresh_wake*fresh_density;
				white=mix(white,max(white,0.92*fresh_density),fresh_wake);
				// A separate blue filament floor keeps calm wet contact perceptible.
				// It uses the same irregular history and fades with that history.
				float calm=clamp(sqrt(wake)*erosion*foam2d_calm_strength*(1.0-turbulent)*feather,0.0,0.65);
				wake*=feather;
				float tint_white=smoothstep(0.60,0.90,min(min(foam2d_water_tint.r,foam2d_water_tint.g),foam2d_water_tint.b));
				vec3 calm_color=mix(foam2d_water_tint.rgb,foam2d_white_color.rgb,0.35);
				float calm_white=smoothstep(0.60,0.90,min(min(calm_color.r,calm_color.g),calm_color.b));
				float tint_mask=clamp(wake*foam2d_tint_strength*mix(1.0,speed_white,tint_white)*mix(1.0,erosion,tint_white),0.0,1.0);
				calm=clamp(calm*mix(1.0,speed_white,calm_white),0.0,0.85);
				projected_white=max(projected_white,white);
				ALBEDO=mix(ALBEDO,foam2d_water_tint.rgb,tint_mask);
				ALBEDO=mix(ALBEDO,calm_color,calm);
				ALBEDO=mix(ALBEDO,foam2d_white_color.rgb,clamp(white,0.0,0.85));
				float optical=clamp(wake*0.6+white+calm*0.5,0.0,1.0);
				ROUGHNESS=mix(ROUGHNESS,foam2d_roughness,optical);
				SPECULAR=mix(SPECULAR,foam2d_specular,optical);
				float strand_normal=foam2d_normal_strength*(1.0-fresh_wake*0.85);
				NORMAL=normalize(NORMAL+(VIEW_MATRIX*vec4((grain-0.5)*wake*strand_normal,0.0,(fine-0.5)*wake*strand_normal,0.0)).xyz);
				// Independently tunable local lather. Same strands, no new texture,
				// no persistent deposit and no change to the existing wake colour.
				float running=clamp(running_contact*erosion*foam2d_running_strength,0.0,0.95);
				projected_running_debug=running;
				vec3 running_color=mix(foam2d_water_tint.rgb,foam2d_running_color.rgb,foam2d_running_whiteness);
				ALBEDO=mix(ALBEDO,running_color,running);
				ROUGHNESS=mix(ROUGHNESS,foam2d_running_roughness,running);
				SPECULAR=mix(SPECULAR,foam2d_running_specular,running);
				NORMAL=normalize(NORMAL+(VIEW_MATRIX*vec4((grain-0.5)*running*foam2d_running_normal_strength,0.0,(fine-0.5)*running*foam2d_running_normal_strength,0.0)).xyz);
				// Puff up the same visible strands. Coverage, blue calm filaments,
				// motion and persistent history are not changed by this material layer.
				// Artists may make calm foam white through Water Tint as well as
				// agitation. Those visible white pockets need relief too; blue stays flat.
				float tint_coverage=tint_mask*tint_white;
				float calm_coverage=clamp(calm*calm_white,0.0,1.0);
				projected_relief_mask=1.0-(1.0-clamp(white,0.0,0.85))*(1.0-running*foam2d_running_whiteness)*(1.0-tint_coverage)*(1.0-calm_coverage);
				float puffy_threads=sqrt(max(mix(foam_structure,1.0,fresh_wake),0.0));
				float bubble_height=smoothstep(0.05,0.95,relief_detail);
				projected_relief_height=foam2d_relief_height_m*puffy_threads*(0.25+0.75*bubble_height);
				projected_relief_cavity=(1.0-bubble_height)*(0.65+0.35*(1.0-puffy_threads));
				// Dense new froth suppresses fine strand shading as well as holes.
				projected_relief_height*=1.0-fresh_wake*0.85;
				projected_relief_cavity*=1.0-fresh_wake*0.85;
				}
			}
		}
		if (foam2d_debug == 1) { ALBEDO=vec3(0); EMISSION=vec3(projected_white); SPECULAR=0.0; ROUGHNESS=1.0; }
	}
	if (foam2d_relief_enabled && foam2d_debug == 0) {
		// Derivatives run for the full pixel quad, including transparent holes.
		// Only the white coverage receives the resulting normal/material change.
		vec3 relief_dx=dFdx(ocean_world_position), relief_dy=dFdy(ocean_world_position);
		vec2 height_gradient=vec2(dFdx(projected_relief_height),dFdy(projected_relief_height));
		if (projected_relief_mask > 0.0) {
			float pixel_size=max(length(relief_dx),length(relief_dy));
			float resolved=1.0-smoothstep(foam2d_relief_detail_size_m*0.4,foam2d_relief_detail_size_m*1.2,pixel_size);
			vec3 relief_base=normalize((INV_VIEW_MATRIX*vec4(NORMAL,0.0)).xyz);
			vec3 relief_normal=foam2d_relief_normal(relief_dx,relief_dy,relief_base,height_gradient,sqrt(projected_relief_mask)*resolved);
			NORMAL=normalize((VIEW_MATRIX*vec4(relief_normal,0.0)).xyz);
			float cavity=foam2d_relief_cavity_strength*projected_relief_cavity*projected_relief_mask*resolved;
			ALBEDO*=1.0-cavity;
			AO*=1.0-cavity;
			ROUGHNESS=mix(ROUGHNESS,foam2d_relief_roughness,projected_relief_mask);
			SPECULAR=mix(SPECULAR,foam2d_relief_specular,projected_relief_mask);
		}
	}
	if (foam2d_debug == 0 && projected_fresh_coverage>0.0) {
		ROUGHNESS=mix(ROUGHNESS,0.92,projected_fresh_coverage);
		SPECULAR=mix(SPECULAR,0.10,projected_fresh_coverage);
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
