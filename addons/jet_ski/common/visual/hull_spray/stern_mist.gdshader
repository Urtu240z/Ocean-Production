shader_type spatial;
render_mode blend_mix, depth_draw_never, depth_test_disabled, cull_disabled;
uniform sampler2D solid_depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D mist_noise : repeat_enable, filter_linear;
uniform vec4 mist_color : source_color = vec4(1.0);
uniform vec3 scene_light_tint = vec3(1.0);
uniform float mist_opacity = 1.0;
uniform float turbulence = 1.0;
uniform sampler2D mist_texture : hint_default_white, repeat_disable, filter_linear_mipmap;
uniform float detail_scale : hint_range(1.0,12.0) = 6.4;
uniform float waterline_y = 0.0;
uniform float speed_kmh = 60.0;
uniform float opacity_start_speed_kmh : hint_range(0.0,60.0) = 10.0;
uniform float opacity_full_speed_kmh : hint_range(1.0,120.0) = 60.0;
uniform float low_speed_opacity : hint_range(0.0,1.0) = 0.12;
uniform float high_speed_opacity : hint_range(0.0,1.0) = 0.9;
uniform float breakup_strength : hint_range(0.0,1.0) = 1.0;
uniform bool droplet_relief_enabled = true;
uniform sampler2D droplet_normal : hint_normal, repeat_enable, filter_linear_mipmap;
uniform float droplet_normal_strength : hint_range(0.0,2.0) = 0.55;
uniform float droplet_normal_tiling : hint_range(0.25,12.0) = 3.0;
uniform float droplet_roughness : hint_range(0.05,1.0) = 0.28;
uniform float droplet_specular : hint_range(0.0,1.0) = 0.35;
varying float particle_seed;
varying vec3 world_position;
varying vec4 particle_color;
void vertex() {
	particle_color = COLOR;
	particle_seed = float(INSTANCE_ID) * 0.61803399;
	float size_x = length(MODEL_MATRIX[0].xyz);
	float size_y = length(MODEL_MATRIX[1].xyz);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0],INV_VIEW_MATRIX[1],INV_VIEW_MATRIX[2],MODEL_MATRIX[3]);
	// Lighting must use the same camera-facing basis as the billboard geometry.
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	VERTEX.xy *= vec2(size_x,size_y);
	world_position = (INV_VIEW_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX,1.0)).xyz;
}
void fragment() {
	float depth = texture(solid_depth_texture, SCREEN_UV).r;
	float solid_fade = 1.0;
	if (depth > 0.0000001) {
		#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
		vec3 ndc = vec3(SCREEN_UV,depth)*2.0-1.0;
		#else
		vec3 ndc = vec3(SCREEN_UV*2.0-1.0,depth);
		#endif
		vec4 point = INV_PROJECTION_MATRIX*vec4(ndc,1.0);
		solid_fade = smoothstep(0.0,0.12,-point.z/point.w+VERTEX.z);
	}
	vec2 p = UV*2.0-1.0;
	vec2 drift = vec2(TIME*0.41,-TIME*0.63)*turbulence;
	vec2 warp = texture(mist_noise,UV*1.7+drift+particle_seed).rg-0.5;
	float wisps = texture(mist_noise,UV*detail_scale+warp*0.8-drift*0.7+particle_seed).r;
	float cloud = (1.0-smoothstep(0.08,1.0,length(p+warp*0.28))) * mix(1.0,smoothstep(0.10,0.75,wisps),breakup_strength);
	float above_water = smoothstep(-0.04,0.12,world_position.y-waterline_y);
	ALBEDO = particle_color.rgb*mist_color.rgb*scene_light_tint*mix(0.75,1.0,wisps);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	if (droplet_relief_enabled) {
		vec2 normal_uv = UV*droplet_normal_tiling+particle_seed+warp*0.2+drift*0.12;
		NORMAL_MAP = texture(droplet_normal,normal_uv).rgb;
		NORMAL_MAP_DEPTH = droplet_normal_strength;
		ROUGHNESS = droplet_roughness;
		SPECULAR = droplet_specular;
	}
	vec4 mask = texture(mist_texture,UV);
	float speed_blend = smoothstep(opacity_start_speed_kmh,max(opacity_full_speed_kmh,opacity_start_speed_kmh+0.1),speed_kmh);
	float speed_opacity = mix(low_speed_opacity,high_speed_opacity,speed_blend);
	ALPHA = cloud*particle_color.a*solid_fade*above_water*mist_opacity*mist_color.a*mask.r*mask.a*speed_opacity;
}
