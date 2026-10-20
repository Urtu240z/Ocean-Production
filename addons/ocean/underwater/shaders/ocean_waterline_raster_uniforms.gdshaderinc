layout(location = 0) in vec3 vertex_position;
layout(set = 0, binding = 0) uniform sampler2D displacement_long;
layout(set = 0, binding = 1) uniform sampler2D displacement_mid;
layout(set = 0, binding = 2) uniform sampler2D displacement_short;
layout(set = 0, binding = 4) uniform sampler2D coastal_field;
layout(set = 0, binding = 5) uniform sampler2D coastal_warp;
layout(set = 0, binding = 6) uniform sampler2D breaker_phase;
layout(set = 0, binding = 7) uniform sampler2D breaker_metrics;
layout(set = 0, binding = 8) uniform sampler2D breaker_normal_long;
layout(set = 0, binding = 9) uniform sampler2D breaker_lifecycle;
layout(set = 0, binding = 10) uniform sampler2D breaking_activity_long;
layout(set = 0, binding = 11) uniform sampler2D breaker_multiphase_vdm;
layout(set = 0, binding = 12) uniform sampler2D hull_waves_field;
layout(set = 0, binding = 13) uniform sampler2D hull_waves_previous_field;
layout(set = 0, binding = 3, std140) uniform RasterParams {
	mat4 view_projection;
	mat4 inverse_view_projection;
	vec4 camera_sea;
	vec4 domains;
	vec4 ocean_space; // x = H clipmap geometry scale, y = V ocean scale
	vec4 coastal_origin_extent; // xy origin, zw extent
	vec4 coastal_warp_origin_extent; // xy warp origin, zw warp extent
	vec4 coastal_control; // x enabled, y warp_detj_safe
	vec4 breaker_0; // strength, shallow start/end, deep start
	vec4 breaker_1; // deep end, shoaling start/full, detj start
	vec4 breaker_2; // detj full, crest height start/full, front slope start
	vec4 breaker_3; // front slope full, forward push, face compression, crest lift
	vec4 breaker_4; // crest curve, pre-lip strength/forward/lift
	vec4 breaker_5; // max horizontal/vertical, enabled, reserved
	vec4 breaker_6; // lip strength, forward fraction, drop scale, lift scale
	vec4 breaker_7; // pre-fold start/full J, unsafe/recover J
	vec4 long_fade;
	vec4 mid_fade;
	vec4 short_fade;
	vec4 visual_horizontal_displacement_scale; // per-band XZ multipliers, same as visible mesh
	vec4 hull_wave_origins; // current XY, previous XY; world XZ metres
	vec4 hull_wave_control; // enabled, interpolation, height cap, physical display
} params;
