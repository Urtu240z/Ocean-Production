class_name OceanClipmapSurface
extends Node3D
## Presentación de las tres bandas P0-P5. Integra sus variantes de material,
## incluido el estado de Optics/SSPR, pero no posee datos Coastal ni sus
## productores/compute de RenderingDevice.

const MeshBuilder := preload("res://addons/ocean/surface/ocean_clipmap_mesh_builder.gd")
const RefinementBatcher := preload("res://addons/ocean/surface/refinement/ocean_refinement_batcher.gd")
const BreakerRefinementRegion := preload("res://addons/ocean/surface/refinement/ocean_breaker_refinement_region.gd")
const RefinementManager := preload("res://addons/ocean/surface/refinement/ocean_refinement_manager.gd")
const SURFACE_SHADER := preload("res://addons/ocean/shaders/ocean_surface.gdshader")
const CREST_BREAKUP_NOISE := preload("res://addons/ocean/surface/crest_breakup_noise.tres")
const OpticsProfile := preload("res://addons/ocean/core/ocean_optics_profile.gd")
const UnderwaterMediumProfile := preload("res://addons/ocean/core/ocean_underwater_medium_profile.gd")
const ReflectionProfile := preload("res://addons/ocean/core/ocean_reflection_profile.gd")
const CrestFoamProfile := preload("res://addons/ocean/core/ocean_crest_foam_profile.gd")
const SurfaceFoamProfile := preload("res://addons/ocean/core/ocean_surface_foam_profile.gd")
const SurfaceDetailProfile := preload("res://addons/ocean/core/ocean_surface_detail_profile.gd")
const BreakerProfile := preload("res://addons/ocean/core/ocean_breaker_profile.gd")
const OPTICS_UNIFORMS_MARKER := "// P4_OPTICS_UNIFORMS"
const OPTICS_FRAGMENT_MARKER := "// P4_OPTICS_FRAGMENT"
const REFLECTIONS_UNIFORMS_MARKER := "// P5_REFLECTIONS_UNIFORMS"
const REFLECTIONS_FRAGMENT_MARKER := "// P5_REFLECTIONS_FRAGMENT"
const SNELL_TIR_COMPOSITION_MARKER := "// P6_SNELL_TIR_COMPOSITION"
const SURFACE_DETAIL_UNIFORMS_MARKER := "// P5_5_SURFACE_DETAIL_UNIFORMS"
const SURFACE_DETAIL_VERTEX_MARKER := "// P5_5_SURFACE_DETAIL_VERTEX"
const SURFACE_DETAIL_FRAGMENT_MARKER := "// P5_5_SURFACE_DETAIL_FRAGMENT"
const OPTICS_DETAIL_BASE_NORMAL_MARKER := "// P5_5_OPTICS_BASE_NORMAL"
const OPTICS_DETAIL_NORMAL_MARKER := "// P5_5_OPTICS_DETAIL_NORMAL"
const SNELL_DETAIL_MARKER := "// P6_SNELL_DETAIL"
const BREAKERS_UNIFORMS_MARKER := "// P7_BREAKERS_UNIFORMS"
const BREAKERS_VARYINGS_MARKER := "// P7_BREAKERS_VARYINGS"
const BREAKERS_VERTEX_INIT_MARKER := "// P7_BREAKERS_VERTEX_INIT"
const BREAKERS_COASTAL_VERTEX_MARKER := "// P7_BREAKERS_COASTAL_VERTEX"
const BREAKERS_VERTEX_POST_MARKER := "// P7_BREAKERS_VERTEX_POST"
const BREAKERS_FRAGMENT_NORMAL_MARKER := "// P7_BREAKERS_FRAGMENT_NORMAL"
const BREAKER_WHITEWATER_FRAGMENT_MARKER := "// P7_BREAKER_WHITEWATER_FRAGMENT"
const BREAKER_SHAPE_LAB_UNIFORMS_MARKER := "// P7_BREAKER_SHAPE_LAB_UNIFORMS"
const BREAKER_SHAPE_LAB_VARYINGS_MARKER := "// P7_BREAKER_SHAPE_LAB_VARYINGS"
const BREAKER_SHAPE_LAB_DEFORMATION_MARKER := "// P7_BREAKER_SHAPE_LAB_DEFORMATION"
const BREAKER_SHAPE_LAB_VERTEX_POST_MARKER := "// P7_BREAKER_SHAPE_LAB_VERTEX_POST"
const BREAKER_SHAPE_LAB_FRAGMENT_NORMAL_MARKER := "// P7_BREAKER_SHAPE_LAB_FRAGMENT_NORMAL"
const SURFACE_FOAM_SOURCE_DOMAIN_M := 14.5
const SURFACE_FOAM_FIELD_DOMAIN_M := 88.0
const CLIPMAP_EXTRA_CULL_MARGIN_M := 4.0

const SNELL_TIR_COMPOSITION := '''
		float reflection_radiance_confidence = 0.0;
		vec3 tir_sspr_macro_normal_view = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);
		vec3 tir_flat_normal_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
		vec3 tir_view_direction = normalize(VIEW);
		vec3 tir_planar_ray = normalize(reflect(-tir_view_direction, tir_flat_normal_view));
		vec3 tir_wave_ray = normalize(reflect(-tir_view_direction, tir_sspr_macro_normal_view));
		vec2 tir_projection_scale = vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
		vec2 tir_projected_delta = (tir_wave_ray.xy / max(abs(tir_wave_ray.z), 0.12) - tir_planar_ray.xy / max(abs(tir_planar_ray.z), 0.12)) * tir_projection_scale * 0.5;
		float tir_camera_distance = distance(world_xz, camera_world_xz);
		float tir_distortion_scale = reflection_sspr_distortion_strength * clamp(tir_camera_distance / max(tir_camera_distance + reflection_roughness_distance_m.x, 0.001), 0.15, 1.0);
		vec2 tir_sspr_uv = SCREEN_UV + tir_projected_delta * tir_distortion_scale;
		float tir_uv_inside = float(all(greaterThanEqual(tir_sspr_uv, vec2(0.0))) && all(lessThanEqual(tir_sspr_uv, vec2(1.0))));
		float tir_distortion_confidence = exp(-length(tir_projected_delta * tir_distortion_scale) * 2.5);
		float tir_filter_roughness = clamp(ROUGHNESS + smoothstep(reflection_roughness_distance_m.x, max(reflection_roughness_distance_m.y, reflection_roughness_distance_m.x + 0.001), tir_camera_distance) * max(0.23 - reflection_base_roughness, 0.0), 0.0, 1.0);
		float tir_roughness_confidence = 1.0 - smoothstep(0.55, 0.90, tir_filter_roughness);
		float tir_slope_confidence = 1.0 - smoothstep(0.65, 1.0, 1.0 - clamp(shading_normal_world.y, 0.0, 1.0));
		vec4 reflection_sample = reflection_sspr_available && tir_uv_inside > 0.5 ? textureLod(reflection_sspr_texture, tir_sspr_uv, tir_filter_roughness * max(log2(float(max(textureSize(reflection_sspr_texture, 0).x, textureSize(reflection_sspr_texture, 0).y))), 0.0)) : vec4(0.0);
		reflection_radiance_confidence = clamp(reflection_sample.a * reflection_edge_confidence(tir_sspr_uv) * tir_distortion_confidence * tir_roughness_confidence * tir_slope_confidence * reflection_screen_space_weight * tir_uv_inside, 0.0, 1.0);
		vec3 reflection_radiance = reflection_grade_radiance(reflection_sample.rgb);
		float tir_strength = clamp(underwater_tir_strength * underwater_snell_strength, 0.0, 1.0);
		float tir_screen_space_weight = tir_strength * underwater_snell_tir_visual_weight * reflection_radiance_confidence;
		optical_scene = mix(optical_scene, reflection_radiance, tir_screen_space_weight);
'''

const BREAKERS_UNIFORMS := '''
uniform float breaker_profile_strength = 0.85;
uniform float breaker_shallow_fade_start_m = 0.35;
uniform float breaker_shallow_fade_end_m = 1.20;
uniform float breaker_deep_activation_start_m = 4.0;
uniform float breaker_deep_activation_end_m = 14.0;
uniform float breaker_shoaling_start = 1.05;
uniform float breaker_shoaling_full = 1.30;
uniform float breaker_detj_compression_start = 0.92;
uniform float breaker_detj_compression_full = 0.65;
uniform float breaker_crest_height_start_m = 0.20;
uniform float breaker_crest_height_full_m = 1.0;
uniform float breaker_front_slope_start = 0.12;
uniform float breaker_front_slope_full = 0.55;
uniform float breaker_forward_push_fraction = 0.045;
uniform float breaker_face_compression_fraction = 0.030;
uniform float breaker_crest_lift_scale = 0.25;
uniform float breaker_crest_curve = 1.50;
uniform float breaker_normal_follow_strength = 0.80;
uniform float breaker_pre_lip_strength = 0.0;
uniform float breaker_pre_lip_forward_fraction = 0.04;
uniform float breaker_pre_lip_lift_scale = 0.15;
uniform float breaker_max_horizontal_fraction = 0.14;
uniform float breaker_max_vertical_lift_scale = 0.45;
uniform float breaker_lip_strength = 0.80;
uniform float breaker_lip_forward_fraction = 0.08;
uniform float breaker_lip_drop_scale = 0.12;
uniform float breaker_lip_lift_scale = 0.40;
uniform float breaker_lip_prefold_start_j = 0.62;
uniform float breaker_lip_prefold_full_j = 0.30;
uniform float breaker_lip_unsafe_j = 0.02;
uniform float breaker_lip_recover_j = 0.15;
uniform sampler2D breaker_lifecycle : repeat_enable, filter_linear;
uniform sampler2D breaker_multiphase_vdm : repeat_disable, filter_linear;
// Legacy scalar retained for material compatibility; authored VDM geometry
// below is scaled from its real profile span and anchored crest height.
uniform float breaker_vdm_scale = 0.35;
uniform float breaker_vdm_validation_phase = -1.0;
uniform float breaker_runtime_enabled = 0.0;
uniform float breaker_probe_horizontal_gain = 1.0;
uniform float breaker_probe_vertical_gain = 1.0;

vec2 breaker_safe_direction(vec2 direction) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : vec2(0.0, 1.0);
}
'''

const BREAKERS_VARYINGS := '''
varying vec3 breaker_displaced_world_position;
varying float breaker_strength;
varying float breaker_environment_mask;
'''

const BREAKERS_VERTEX_INIT := '''
	breaker_strength = 0.0;
	breaker_environment_mask = 0.0;
'''

const BREAKERS_COASTAL_VERTEX := '''
	// P7 stays inside the Coastal LONG block: field and warp are already sampled.
	vec4 phase_info = texture(coastal_phase, coast_uv);
	vec4 metrics = texture(coastal_metrics, coast_uv);
	vec2 phase_direction = breaker_safe_direction(phase_info.yz);
	// coastal_phase.yz follows the Coastal phase/render-direction convention;
	// P7 needs the visible wave-travel direction, opposite under FFT/Coastal.
	vec2 propagation_direction = -phase_direction;
	float breaker_runtime = clamp(breaker_runtime_enabled, 0.0, 1.0);
	// Coastal phase is the signed profile coordinate. The negative sign follows
	// the established FFT/Coastal convention so positive s is the forward face.
	float wavelength_m = max(metrics.g, 0.001);
	float phase_k = 6.28318530718 / wavelength_m;
	float wrapped_phase = mod(phase_info.r + 3.14159265359, 6.28318530718) - 3.14159265359;
	float s_profile = -wrapped_phase / max(phase_k, 0.001);
	vec2 crest_anchor_xz = warp.xy - propagation_direction * s_profile;
	vec2 crest_anchor_uv = world_uv(crest_anchor_xz, domain_long_m);
	vec4 anchored_breaker_state = texture(breaker_lifecycle, crest_anchor_uv);
	vec4 anchored_long_displacement = texture(displacement_long, crest_anchor_uv);
	float anchored_positive_crest_height = max(anchored_long_displacement.y, 0.0);
	float event_active = smoothstep(0.05, 0.35, anchored_breaker_state.r);
	float event_energy = clamp(anchored_breaker_state.a, 0.0, 1.0);
	bool vdm_validation_mode = breaker_vdm_validation_phase >= 0.0;
	float breaker_event_authority = vdm_validation_mode ? 1.0 : breaker_runtime * event_active * event_energy;
	breaker_environment_mask = breaker_event_authority;
	// Production geometry is driven only by the existing authored multiphase
	// atlas. Its authored profile spans the complete normalized base domain
	// [-0.5,+0.5]; real wavelength and anchored crest height scale the channels.
	const float authored_profile_span_m = 12.0;
	const float authored_vertical_reference_m = 3.72184;
	float profile_n = s_profile / wavelength_m;
	float profile_support = smoothstep(-0.50, -0.48, profile_n) * (1.0 - smoothstep(0.48, 0.50, profile_n));
	float profile_u = clamp(profile_n + 0.5, 0.001953125, 0.998046875);
	float phase_position = breaker_vdm_validation_phase >= 0.0
		? clamp(breaker_vdm_validation_phase, 0.0, 7.0)
		: clamp(anchored_breaker_state.b, 0.0, 1.0) * 7.0;
	float phase_index = floor(phase_position);
	float phase_fraction = smoothstep(0.0, 1.0, fract(phase_position));
	vec4 vdm_phase_0 = texture(breaker_multiphase_vdm, vec2(profile_u, (phase_index + 0.5) / 8.0));
	vec4 vdm_phase_1 = texture(breaker_multiphase_vdm, vec2(profile_u, (min(phase_index + 1.0, 7.0) + 0.5) / 8.0));
	vec4 vdm_sample = mix(vdm_phase_0, vdm_phase_1, phase_fraction);
	float vdm_profile_gain = clamp(breaker_profile_strength, 0.0, 2.0);
	float vdm_authority = clamp(breaker_event_authority * profile_support * clamp(vdm_sample.a, 0.0, 1.0) * vdm_profile_gain, 0.0, 1.0);
	float scale_s = wavelength_m / authored_profile_span_m;
	float base_s = (profile_u - 0.5) * wavelength_m;
	float delta_s = vdm_sample.r * scale_s;
	float target_s = base_s + delta_s;
	float vdm_forward_m = target_s - base_s;
	float vdm_lateral_m = vdm_sample.g * (wavelength_m / authored_profile_span_m);
	float validation_crest_height_m = 2.0;
	float crest_height_for_vdm = vdm_validation_mode ? validation_crest_height_m : anchored_positive_crest_height;
	float vdm_vertical_m = vdm_sample.b * (crest_height_for_vdm / authored_vertical_reference_m);
	vec2 crest_tangent = vec2(-propagation_direction.y, propagation_direction.x);
	vec3 breaker_target_displacement = vec3(
		propagation_direction * vdm_forward_m + crest_tangent * vdm_lateral_m,
		vdm_vertical_m
	);
	long_displacement = mix(long_displacement, breaker_target_displacement, vdm_authority);
	breaker_strength = vdm_authority;
'''

const BREAKERS_VERTEX_POST := '''
	breaker_strength *= long_weight;
	breaker_environment_mask *= long_weight;
	breaker_displaced_world_position = (MODEL_MATRIX * vec4(VERTEX + surface_displacement, 1.0)).xyz;
'''

const BREAKERS_FRAGMENT_NORMAL := '''
	vec3 breaker_dx = dFdx(breaker_displaced_world_position);
	vec3 breaker_dy = dFdy(breaker_displaced_world_position);
	vec3 breaker_cross = cross(breaker_dx, breaker_dy);
	if (length(breaker_cross) > 0.00001) {
		vec3 breaker_geometric_normal = normalize(breaker_cross);
		float geometric_follow = clamp(breaker_strength * breaker_normal_follow_strength * 0.25, 0.0, 0.25);
		shading_normal_world = normalize(mix(shading_normal_world, breaker_geometric_normal, geometric_follow));
	}
'''

const BREAKER_WHITEWATER_FRAGMENT := '''
	vec4 breaker_base_state = texture(breaker_lifecycle, world_uv(ocean_wave_sample_xz, domain_long_m));
	vec4 breaker_warped_state = texture(breaker_lifecycle, world_uv(crest_long_coastal_warp_xz, domain_long_m));
	vec4 breaker_water_state = mix(breaker_base_state, breaker_warped_state, crest_long_coastal_confidence);
	float aeration_structure = texture(crest_breakup_texture, world_xz / 2.0).r;
	float whitewater_density = smoothstep(0.08, 0.80, breaker_water_state.g * (0.65 + 0.35 * aeration_structure)) * breaker_environment_mask;
	float whitecap_density = smoothstep(0.05, 0.50, breaker_water_state.r * breaker_water_state.a) * breaker_environment_mask;
	float aerated_body = clamp(max(whitewater_density * 0.70, whitecap_density), 0.0, 1.0);
	ALBEDO = mix(ALBEDO, vec3(0.90, 0.94, 0.93), aerated_body);
	ROUGHNESS = mix(ROUGHNESS, 0.88, aerated_body);
	SPECULAR = mix(SPECULAR, 0.24, aerated_body);
'''

const BREAKER_SHAPE_LAB_UNIFORMS := '''
uniform sampler2D breaker_shape_vdm : repeat_disable, filter_linear;
uniform vec2 breaker_shape_origin;
uniform vec2 breaker_shape_propagation;
uniform vec2 breaker_shape_reference_direction;
uniform float breaker_shape_wavefront_width_m;
uniform float breaker_shape_length_m;
uniform float breaker_shape_flatten_strength;
uniform int breaker_shape_debug_mode;
uniform bool breaker_shape_waterline_temp = false;
uniform bool breaker_shape_multiphase_vdm = false;
uniform float breaker_shape_waterline_propagation_scale = 6.0;
uniform float breaker_shape_waterline_vertical_scale = 18.0;
uniform sampler2D breaker_shape_shore_distance_tex : repeat_disable, filter_linear;
uniform float breaker_shape_shore_distance_near_m = 0.0;
uniform float breaker_shape_shore_distance_far_m = 16.0;
uniform bool breaker_shape_animation_enabled = true;
uniform float breaker_shape_cycle_seconds = 4.0;
uniform float breaker_shape_travel_m = 8.0;
uniform float breaker_shape_horizontal_sign = -1.0;
uniform float breaker_shape_phase_override = -1.0;
uniform float breaker_shape_coastal_shore_depth_near_m = 0.25;
uniform float breaker_shape_coastal_shore_depth_far_m = 8.0;
uniform float breaker_shape_coastal_shallow_fade_start_m = 0.25;
uniform float breaker_shape_coastal_shallow_fade_end_m = 0.75;
uniform float breaker_shape_coastal_deep_fade_start_m = 6.0;
uniform float breaker_shape_coastal_deep_fade_end_m = 10.0;

vec2 breaker_shape_lab_safe_direction(vec2 direction) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : vec2(0.0, 1.0);
}
'''

const BREAKER_SHAPE_LAB_VARYINGS := '''
varying vec3 breaker_shape_lab_world_position;
varying float breaker_shape_lab_normal_weight;
'''

const BREAKER_SHAPE_LAB_DEFORMATION := '''
	float breaker_shape_lab_mask = 0.0;
	if (breaker_shape_debug_mode > 1) {
		vec2 breaker_shape_propagation_safe = normalize(breaker_shape_propagation);
		vec2 breaker_shape_tangent = vec2(-breaker_shape_propagation_safe.y, breaker_shape_propagation_safe.x);
		bool breaker_shape_reference_mode = breaker_shape_debug_mode == 5;
		vec2 breaker_shape_reference_direction_safe = breaker_shape_lab_safe_direction(breaker_shape_reference_direction);
		vec2 breaker_shape_reference_tangent = vec2(-breaker_shape_reference_direction_safe.y, breaker_shape_reference_direction_safe.x);
		vec2 breaker_shape_relative = world_xz - breaker_shape_origin;
		float breaker_shape_reference_s = dot(breaker_shape_relative, breaker_shape_reference_direction_safe);
		float breaker_shape_reference_profile_u = breaker_shape_reference_s / 12.0 + 0.5;
		float breaker_shape_reference_v = dot(breaker_shape_relative, breaker_shape_reference_tangent) / max(breaker_shape_wavefront_width_m, 0.001) + 0.5;
		vec2 breaker_shape_uv = vec2(
			dot(breaker_shape_relative, breaker_shape_tangent) / max(breaker_shape_wavefront_width_m, 0.001) + 0.5,
			dot(breaker_shape_relative, breaker_shape_propagation_safe) / max(breaker_shape_length_m, 0.001) + 0.5
		);
		if (breaker_shape_reference_mode) breaker_shape_uv = vec2(breaker_shape_reference_v, breaker_shape_reference_profile_u);
		vec4 breaker_shape_vdm_sample = vec4(0.0);
		vec2 breaker_shape_waterline_direction = breaker_shape_propagation_safe;
		float breaker_shape_depth_authority = 0.0;
		float breaker_shape_effect_authority = 0.0;
		float breaker_shape_lifecycle_phase = 0.5;
		float breaker_shape_lifecycle = 1.0;
		float breaker_shape_travel_phase = 0.5;
		if (all(greaterThanEqual(breaker_shape_uv, vec2(0.0))) && all(lessThanEqual(breaker_shape_uv, vec2(1.0)))) {
			if (breaker_shape_waterline_temp || breaker_shape_multiphase_vdm) {
				if (breaker_shape_reference_mode) {
					breaker_shape_lifecycle_phase = breaker_shape_phase_override >= 0.0 ? clamp(breaker_shape_phase_override / 7.0, 0.0, 1.0) : (breaker_shape_animation_enabled ? fract(TIME / max(breaker_shape_cycle_seconds, 0.001)) : 0.5);
					breaker_shape_travel_phase = breaker_shape_phase_override >= 0.0 ? 0.0 : breaker_shape_lifecycle_phase;
					float lifecycle_in = smoothstep(0.00, 0.15, breaker_shape_lifecycle_phase);
					float lifecycle_out = 1.0 - smoothstep(0.80, 1.00, breaker_shape_lifecycle_phase);
					breaker_shape_lifecycle = lifecycle_in * lifecycle_out;
					if (breaker_shape_phase_override >= 0.0) breaker_shape_lifecycle = 1.0;
					if (breaker_shape_multiphase_vdm) {
						float phase_position = breaker_shape_lifecycle_phase * 7.0;
						float phase0 = floor(phase_position);
						float phase1 = min(phase0 + 1.0, 7.0);
						float phase_blend = smoothstep(0.0, 1.0, fract(phase_position));
						float safe_reference_profile_u = clamp(breaker_shape_reference_profile_u, 0.5 / 256.0, 255.5 / 256.0);
						float safe_reference_v = clamp(breaker_shape_reference_v, 0.5 / 256.0, 255.5 / 256.0);
						vec4 phase_sample0 = texture(breaker_shape_vdm, vec2(safe_reference_profile_u, (phase0 + safe_reference_v) / 8.0));
						vec4 phase_sample1 = texture(breaker_shape_vdm, vec2(safe_reference_profile_u, (phase1 + safe_reference_v) / 8.0));
						breaker_shape_vdm_sample = mix(phase_sample0, phase_sample1, phase_blend);
					}
					breaker_shape_depth_authority = 1.0;
					float reference_lateral = clamp(breaker_shape_reference_v, 0.0, 1.0) * 2.0 - 1.0;
					float wavefront_edge = 1.0 - smoothstep(0.78, 1.0, abs(reference_lateral));
					float authored_authority = breaker_shape_multiphase_vdm ? clamp(breaker_shape_vdm_sample.a, 0.0, 1.0) : 1.0;
					breaker_shape_effect_authority = authored_authority * breaker_shape_lifecycle * wavefront_edge;
					breaker_shape_lab_mask = breaker_shape_effect_authority;
					breaker_shape_waterline_direction = breaker_shape_reference_direction_safe;
				} else if (coastal_enabled) {
					vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
					if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
						vec4 field = texture(coastal_field, coast_uv);
						vec4 metrics = texture(coastal_metrics, coast_uv);
						vec4 phase_info = texture(coastal_phase, coast_uv);
						vec2 phase_direction = breaker_shape_lab_safe_direction(phase_info.yz);
						vec2 shore_direction = -phase_direction;
						vec2 propagation_direction = shore_direction;
						float shore_distance_m = texture(breaker_shape_shore_distance_tex, coast_uv).r;
						breaker_shape_lifecycle_phase = breaker_shape_phase_override >= 0.0 ? clamp(breaker_shape_phase_override / 7.0, 0.0, 1.0) : (breaker_shape_animation_enabled ? fract(TIME / max(breaker_shape_cycle_seconds, 0.001)) : 0.5);
						breaker_shape_travel_phase = breaker_shape_phase_override >= 0.0 ? 0.0 : breaker_shape_lifecycle_phase;
						float lifecycle_in = smoothstep(0.00, 0.15, breaker_shape_lifecycle_phase);
						float lifecycle_out = 1.0 - smoothstep(0.80, 1.00, breaker_shape_lifecycle_phase);
						breaker_shape_lifecycle = lifecycle_in * lifecycle_out;
						if (breaker_shape_phase_override >= 0.0) breaker_shape_lifecycle = 1.0;
						float animated_distance_m = shore_distance_m + breaker_shape_travel_phase * breaker_shape_travel_m;
						float shore_u = clamp((animated_distance_m - breaker_shape_shore_distance_near_m) / max(breaker_shape_shore_distance_far_m - breaker_shape_shore_distance_near_m, 0.001), 0.0, 1.0);
						float shore_v = clamp(breaker_shape_uv.x, 0.0, 1.0);
						if (breaker_shape_multiphase_vdm) {
							float phase_position = breaker_shape_lifecycle_phase * 7.0;
							float phase0 = floor(phase_position);
							float phase1 = min(phase0 + 1.0, 7.0);
							float phase_blend = smoothstep(0.0, 1.0, fract(phase_position));
							float profile_u = 1.0 - shore_u;
							float safe_profile_u = clamp(profile_u, 0.5 / 256.0, 255.5 / 256.0);
							float safe_shore_v = clamp(shore_v, 0.5 / 256.0, 255.5 / 256.0);
							vec4 phase_sample0 = texture(breaker_shape_vdm, vec2(safe_profile_u, (phase0 + safe_shore_v) / 8.0));
							vec4 phase_sample1 = texture(breaker_shape_vdm, vec2(safe_profile_u, (phase1 + safe_shore_v) / 8.0));
							breaker_shape_vdm_sample = mix(phase_sample0, phase_sample1, phase_blend);
						} else {
							breaker_shape_vdm_sample = texture(breaker_shape_vdm, vec2(shore_u, shore_v));
						}
						float shallow_gate = smoothstep(breaker_shape_coastal_shallow_fade_start_m, max(breaker_shape_coastal_shallow_fade_end_m, breaker_shape_coastal_shallow_fade_start_m + 0.001), metrics.r);
						float deep_gate = 1.0 - smoothstep(breaker_shape_coastal_deep_fade_start_m, max(breaker_shape_coastal_deep_fade_end_m, breaker_shape_coastal_deep_fade_start_m + 0.001), metrics.r);
						breaker_shape_depth_authority = shallow_gate * deep_gate;
						float lateral = shore_v * 2.0 - 1.0;
						float wavefront_edge = 1.0 - smoothstep(0.78, 1.0, abs(lateral));
						float authored_authority = breaker_shape_multiphase_vdm ? clamp(breaker_shape_vdm_sample.a, 0.0, 1.0) : 1.0;
						breaker_shape_effect_authority = breaker_shape_depth_authority * authored_authority * (breaker_shape_debug_mode >= 3 ? breaker_shape_lifecycle * wavefront_edge : 1.0);
						breaker_shape_lab_mask = breaker_shape_effect_authority;
						if (breaker_shape_debug_mode == 2) breaker_shape_lab_mask = breaker_shape_depth_authority;
						breaker_shape_waterline_direction = propagation_direction;
					}
				}
			} else {
				breaker_shape_vdm_sample = texture(breaker_shape_vdm, breaker_shape_uv);
				breaker_shape_lab_mask = clamp(breaker_shape_vdm_sample.a, 0.0, 1.0);
			}
		}
		float breaker_shape_flatten = breaker_shape_lab_mask * clamp(breaker_shape_flatten_strength, 0.0, 1.0);
		if (breaker_shape_waterline_temp || breaker_shape_multiphase_vdm) {
			if (breaker_shape_debug_mode == 2) breaker_shape_flatten = breaker_shape_depth_authority;
			if (breaker_shape_debug_mode == 3) breaker_shape_flatten = 0.0;
			if (breaker_shape_debug_mode == 4) breaker_shape_flatten = breaker_shape_effect_authority * 0.90;
		} else if (breaker_shape_debug_mode == 3) {
			breaker_shape_flatten = breaker_shape_lab_mask;
		}
		vec3 breaker_shape_offset;
		if (breaker_shape_multiphase_vdm) {
			vec2 breaker_shape_displacement_direction = breaker_shape_debug_mode == 5 ? breaker_shape_reference_direction_safe : breaker_shape_waterline_direction;
			vec2 breaker_shape_displacement_tangent = vec2(-breaker_shape_displacement_direction.y, breaker_shape_displacement_direction.x);
			breaker_shape_offset = vec3(breaker_shape_displacement_direction.x, 0.0, breaker_shape_displacement_direction.y) * breaker_shape_vdm_sample.r
				+ vec3(breaker_shape_displacement_tangent.x, 0.0, breaker_shape_displacement_tangent.y) * breaker_shape_vdm_sample.g
				+ vec3(0.0, 1.0, 0.0) * breaker_shape_vdm_sample.b;
			breaker_shape_offset *= breaker_shape_effect_authority;
		} else if (breaker_shape_waterline_temp) {
			// Waterline R follows real Coastal Shore Direction; B is vertical. G is unused here.
			float rise = smoothstep(0.05, 0.38, breaker_shape_lifecycle_phase);
			float plunge = smoothstep(0.25, 0.58, breaker_shape_lifecycle_phase);
			float collapse = smoothstep(0.68, 0.90, breaker_shape_lifecycle_phase);
			float vertical_shape = mix(0.15, 1.0, rise);
			vertical_shape *= mix(1.0, 0.35, collapse);
			float horizontal_shape = mix(0.05, 1.0, plunge);
			horizontal_shape *= mix(1.0, 0.65, collapse);
			breaker_shape_offset = vec3(breaker_shape_waterline_direction.x, 0.0, breaker_shape_waterline_direction.y) * breaker_shape_vdm_sample.r * breaker_shape_waterline_propagation_scale * breaker_shape_horizontal_sign * horizontal_shape
				+ vec3(0.0, 1.0, 0.0) * breaker_shape_vdm_sample.b * breaker_shape_waterline_vertical_scale * vertical_shape;
			breaker_shape_offset *= breaker_shape_effect_authority;
		} else {
			breaker_shape_offset = vec3(breaker_shape_tangent.x, 0.0, breaker_shape_tangent.y) * breaker_shape_vdm_sample.r
				+ vec3(0.0, 1.0, 0.0) * breaker_shape_vdm_sample.g
				+ vec3(breaker_shape_propagation_safe.x, 0.0, breaker_shape_propagation_safe.y) * breaker_shape_vdm_sample.b;
		}
		if (breaker_shape_debug_mode == 2) breaker_shape_offset = vec3(0.0);
		if (breaker_shape_debug_mode == 5) {
			surface_displacement *= 1.0 - breaker_shape_effect_authority;
		} else {
			surface_displacement *= 1.0 - breaker_shape_flatten;
		}
		surface_displacement += breaker_shape_offset;
	}
'''

const BREAKER_SHAPE_LAB_VERTEX_POST := '''
	breaker_shape_lab_normal_weight = breaker_shape_lab_mask;
	breaker_shape_lab_world_position = (MODEL_MATRIX * vec4(VERTEX + surface_displacement, 1.0)).xyz;
'''

const BREAKER_SHAPE_LAB_FRAGMENT_NORMAL := '''
	if (breaker_shape_lab_normal_weight > 0.0001) {
		vec3 breaker_shape_lab_dx = dFdx(breaker_shape_lab_world_position);
		vec3 breaker_shape_lab_dy = dFdy(breaker_shape_lab_world_position);
		vec3 breaker_shape_lab_cross = cross(breaker_shape_lab_dx, breaker_shape_lab_dy);
		if (length(breaker_shape_lab_cross) > 0.00001) {
			vec3 breaker_shape_lab_normal = normalize(breaker_shape_lab_cross);
			if (!FRONT_FACING) breaker_shape_lab_normal = -breaker_shape_lab_normal;
			float normal_weight = clamp(breaker_shape_lab_normal_weight * 0.85, 0.0, 0.85);
			shading_normal_world = normalize(mix(shading_normal_world, breaker_shape_lab_normal, normal_weight));
		}
	}
'''

const SURFACE_DETAIL_UNIFORMS := '''
uniform sampler2D surface_normal_texture_a : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_normal_texture_b : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_warp_texture : repeat_enable, filter_linear_mipmap;
uniform float surface_detail_wave_follow = 1.0;
uniform float surface_normal_world_size_a = 34.15;
uniform float surface_normal_world_size_b = 2.4;
uniform float surface_normal_strength = 1.18;
uniform vec2 surface_flow_direction_a = vec2(0.82, 0.57);
uniform vec2 surface_flow_direction_b = vec2(-0.46, 0.89);
uniform float surface_flow_speed_a = 0.24;
uniform float surface_flow_speed_b = -0.17;
uniform float surface_warp_world_size = 14.5;
uniform float surface_warp_strength = 1.15;
uniform float surface_detail_fade_start = 180.0;
uniform float surface_detail_fade_end = 800.0;
uniform float surface_detail_far_strength = 0.18;
uniform int ocean_surface_detail_quality = 2;
uniform float ocean_time_s = 0.0;
varying vec2 surface_detail_world_xz;

vec2 surface_detail_safe_direction(vec2 direction, vec2 fallback) {
	float magnitude = length(direction);
	return magnitude > 0.00001 ? direction / magnitude : fallback;
}

vec2 surface_detail_carrier_xz() {
	return mix(
		surface_detail_world_xz,
		ocean_base_xz,
		clamp(surface_detail_wave_follow, 0.0, 1.0)
	);
}

vec3 sample_surface_detail(vec2 carrier_xz, float camera_distance) {
	vec2 warp = vec2(0.0);
	if (ocean_surface_detail_quality >= 2) {
		vec2 warp_uv = carrier_xz / max(surface_warp_world_size, 0.001)
			+ vec2(0.31, -0.95) * ocean_time_s * 0.035;
		warp = (texture(surface_warp_texture, warp_uv).rg * 2.0 - 1.0)
			* surface_warp_strength;
	}
	vec2 uv_a = (carrier_xz + warp) / max(surface_normal_world_size_a, 0.001)
		+ surface_detail_safe_direction(surface_flow_direction_a, vec2(1.0, 0.0))
			* ocean_time_s * surface_flow_speed_a / max(surface_normal_world_size_a, 0.001);
	vec2 uv_b = (carrier_xz - warp * 0.57) / max(surface_normal_world_size_b, 0.001)
		+ surface_detail_safe_direction(surface_flow_direction_b, vec2(0.0, 1.0))
			* ocean_time_s * surface_flow_speed_b / max(surface_normal_world_size_b, 0.001);
	vec3 normal_a = texture(surface_normal_texture_a, uv_a).xyz * 2.0 - 1.0;
	vec3 combined = normalize(normal_a);
	if (ocean_surface_detail_quality >= 1) {
		vec3 normal_b = texture(surface_normal_texture_b, uv_b).xyz * 2.0 - 1.0;
		combined = normalize(vec3(
			normal_a.xy * 0.58 + normal_b.xy * 0.42,
			max(normal_a.z * 0.58 + normal_b.z * 0.42, 0.08)
		));
	}
	float detail_distance = 1.0 - smoothstep(
		surface_detail_fade_start,
		max(surface_detail_fade_end, surface_detail_fade_start + 0.001),
		camera_distance
	);
	float detail_fade = mix(surface_detail_far_strength, 1.0, detail_distance);
	return vec3(combined.xy * detail_fade, combined.z);
}
'''

const SURFACE_DETAIL_VERTEX := '''
	surface_detail_world_xz = world_xz + surface_displacement.xz;
'''

const SURFACE_DETAIL_FRAGMENT := '''
	vec3 surface_detail_offset_view = vec3(0.0);
	vec3 detail_normal = sample_surface_detail(
		surface_detail_carrier_xz(),
		distance(surface_detail_world_xz, camera_world_xz)
	);
	vec2 detail_slope = detail_normal.xy / max(detail_normal.z, 0.08);
	surface_detail_offset_view = mat3(VIEW_MATRIX) * vec3(
		detail_slope.x,
		0.0,
		detail_slope.y
	);
	visual_normal = normalize(visual_normal + surface_detail_offset_view * surface_normal_strength);
'''

const SNELL_DETAIL_FRAGMENT := '''
			if (abs(underwater_snell_detail_world_scale - 1.0) > 0.001) {
				vec3 snell_detail_normal = sample_surface_detail(
					surface_detail_carrier_xz() / max(underwater_snell_detail_world_scale, 0.01),
					distance(surface_detail_world_xz, camera_world_xz)
				);
				vec2 snell_detail_slope = snell_detail_normal.xy / max(snell_detail_normal.z, 0.08);
				vec3 snell_detail_offset_view = mat3(VIEW_MATRIX) * vec3(
					snell_detail_slope.x,
					0.0,
					snell_detail_slope.y
				);
				micro_slope = vec2(snell_detail_offset_view.x, -snell_detail_offset_view.z);
			}
'''

const OPTICS_UNIFORMS := '''
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform bool water_optics_enabled = true;
uniform vec3 optics_shallow_water_color : source_color;
uniform vec3 optics_deep_water_color : source_color;
uniform vec3 optics_horizon_water_color : source_color;
uniform vec3 optics_trough_tint : source_color;
uniform vec3 optics_crest_tint : source_color;
uniform vec3 absorption_coeff_rgb;
uniform float maximum_optical_depth_above_m;
uniform float water_body_depth_start_m;
uniform float water_body_depth_end_m;
uniform float opacity_distance_start;
uniform float opacity_distance_end;
uniform float refraction_micro_normal_strength;
uniform float refraction_max_offset_px;
uniform float refraction_depth_tolerance_m;
uniform float refraction_wave_strength;
uniform float refraction_long_weight;
uniform float refraction_mid_weight;
uniform float refraction_short_weight;
uniform float refraction_depth_start_m;
uniform float refraction_depth_end_m;
uniform vec3 scattering_color : source_color;
uniform float scattering_strength;
uniform float scattering_shallow_tint_influence;
uniform float scattering_deep_tint_influence;
uniform float shallow_scattering_strength;
uniform float shallow_scattering_depth_start_m;
uniform float shallow_scattering_depth_end_m;
uniform float water_turbidity;
uniform float crest_transmission_boost;
uniform float trough_density_boost;
uniform float transmission_detail_fade_start_m;
uniform float transmission_detail_fade_end_m;
uniform float transmission_max_lod;
uniform float bottom_visibility_fade_start_m;
uniform float bottom_visibility_fade_end_m;
uniform float seabed_match_tolerance_start_m;
uniform float seabed_match_tolerance_end_m;
uniform float shallow_fresnel_relief;
uniform float shallow_fresnel_depth_start_m;
uniform float shallow_fresnel_depth_end_m;
uniform bool optics_bathymetry_enabled = false;
uniform bool optics_real_seabed_coverage_enabled = false;
uniform sampler2D optics_real_seabed_coverage_texture : repeat_disable, filter_linear;
uniform vec2 optics_real_seabed_coverage_origin = vec2(0.0);
uniform vec2 optics_real_seabed_coverage_extent = vec2(1.0);
uniform float optics_seabed_sea_level = 0.0;

float optics_linear_depth(vec2 uv, float raw_depth, mat4 inverse_projection) {
	vec4 view = inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	return -view.z / max(view.w, 0.00001);
}

bool optics_world_position(vec2 uv, float raw_depth, mat4 inverse_projection, mat4 inverse_view, out vec3 world_position) {
	world_position = vec3(0.0);
	if (raw_depth <= 0.000001 || raw_depth > 1.000001 || isnan(raw_depth) || isinf(raw_depth)) return false;
	vec4 view_position = inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	if (abs(view_position.w) <= 0.00001 || any(isnan(view_position)) || any(isinf(view_position))) return false;
	view_position /= view_position.w;
	vec4 world_position_h = inverse_view * vec4(view_position.xyz, 1.0);
	if (abs(world_position_h.w) <= 0.00001 || any(isnan(world_position_h)) || any(isinf(world_position_h))) return false;
	world_position = world_position_h.xyz / world_position_h.w;
	return !any(isnan(world_position)) && !any(isinf(world_position));
}

vec2 optics_project_view_position(vec3 view_position, mat4 projection, out bool valid) {
	vec4 clip_position = projection * vec4(view_position, 1.0);
	if (clip_position.w <= 0.0001 || any(isnan(clip_position)) || any(isinf(clip_position))) {
		valid = false;
		return vec2(0.0);
	}
	vec2 uv = clip_position.xy / clip_position.w * 0.5 + 0.5;
	valid = !any(isnan(uv)) && !any(isinf(uv));
	return uv;
}

float optics_edge_confidence(vec2 uv) {
	float edge_distance = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	return smoothstep(0.0, 0.02, edge_distance);
}
'''

const OPTICS_FRAGMENT := '''
	if (water_optics_enabled) {
		float raw_scene_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		bool scene_is_sky = raw_scene_depth <= 0.000001;
		bool scene_depth_valid = raw_scene_depth > 0.000001 && raw_scene_depth <= 1.000001 && !isnan(raw_scene_depth) && !isinf(raw_scene_depth);
		float scene_depth_m = optics_linear_depth(SCREEN_UV, raw_scene_depth, INV_PROJECTION_MATRIX);
		float water_depth_m = optics_linear_depth(SCREEN_UV, FRAGCOORD.z, INV_PROJECTION_MATRIX);
		bool water_depth_valid = water_depth_m > 0.00001 && !isnan(water_depth_m) && !isinf(water_depth_m);
		vec3 original_scene_world_position = vec3(0.0);
		bool original_scene_world_valid = scene_depth_valid && optics_world_position(SCREEN_UV, raw_scene_depth, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, original_scene_world_position);
		float view_water_path_m = scene_is_sky ? maximum_optical_depth_above_m : scene_depth_valid && water_depth_valid ? max(scene_depth_m - water_depth_m, 0.0) : maximum_optical_depth_above_m;
		float bounded_view_water_path_m = clamp(view_water_path_m, 0.0, maximum_optical_depth_above_m);
		float raw_bathymetry_m = 0.0;
		float bathymetry_domain = 0.0;
		float bathymetry_edge_confidence = 0.0;
		if (optics_bathymetry_enabled) {
			vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
			if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
				vec4 metrics = texture(coastal_metrics, coast_uv);
				raw_bathymetry_m = metrics.r;
				bathymetry_domain = 1.0;
				vec2 edge_m = min(coast_uv, vec2(1.0) - coast_uv) * coastal_extent;
				float cell_m = max(min(coastal_extent.x / max(float(textureSize(coastal_metrics, 0).x - 1), 1.0), coastal_extent.y / max(float(textureSize(coastal_metrics, 0).y - 1), 1.0)), 0.001);
				bathymetry_edge_confidence = smoothstep(0.0, cell_m * 2.0, max(min(edge_m.x, edge_m.y), 0.0));
			}
		}
		vec2 coverage_uv = (ocean_base_xz - optics_real_seabed_coverage_origin) / max(optics_real_seabed_coverage_extent, vec2(0.001));
		float coverage_domain = optics_real_seabed_coverage_enabled ? step(0.0, coverage_uv.x) * step(coverage_uv.x, 1.0) * step(0.0, coverage_uv.y) * step(coverage_uv.y, 1.0) : 0.0;
		vec4 coverage_sample = coverage_domain > 0.0 ? textureLod(optics_real_seabed_coverage_texture, clamp(coverage_uv, vec2(0.0), vec2(1.0)), 0.0) : vec4(0.0);
		float real_seabed_coverage = coverage_domain * step(0.5, coverage_sample.r);
		float optical_seabed_confidence = coverage_domain * clamp(coverage_sample.g, 0.0, 1.0);
		float local_depth_authority = bathymetry_domain * bathymetry_edge_confidence * real_seabed_coverage;
		bool local_depth_valid = raw_bathymetry_m >= 0.0 && !isnan(raw_bathymetry_m) && !isinf(raw_bathymetry_m) && local_depth_authority > 0.001;
		float local_deep_fallback_m = max(maximum_optical_depth_above_m, max(water_body_depth_end_m, max(shallow_scattering_depth_end_m, 20.0)) + 1.0);
		float local_water_depth_m = mix(local_deep_fallback_m, max(raw_bathymetry_m, 0.0), local_depth_authority);
		float shallow_path_m = min(bounded_view_water_path_m, local_water_depth_m * 1.5);
		float optical_depth_m = clamp(mix(bounded_view_water_path_m, shallow_path_m, local_depth_valid ? real_seabed_coverage : 0.0), 0.0, maximum_optical_depth_above_m);
		float expected_seabed_y = optics_seabed_sea_level - max(local_water_depth_m, 0.0);
		float original_seabed_match = original_scene_world_valid && local_depth_valid ? 1.0 - smoothstep(seabed_match_tolerance_start_m, max(seabed_match_tolerance_end_m, seabed_match_tolerance_start_m + 0.001), abs(original_scene_world_position.y - expected_seabed_y)) : 0.0;
		float bottom_visibility = (1.0 - smoothstep(bottom_visibility_fade_start_m, max(bottom_visibility_fade_end_m, bottom_visibility_fade_start_m + 0.001), local_water_depth_m)) * optical_seabed_confidence;
		vec3 transmittance_rgb = exp(-max(absorption_coeff_rgb, vec3(0.0)) * optical_depth_m);
		float body_depth_factor = smoothstep(water_body_depth_start_m, max(water_body_depth_end_m, water_body_depth_start_m + 0.001), local_water_depth_m);
		float crest_height = clamp(0.5 + (shading_normal_world.y - 0.5), 0.0, 1.0);
		vec3 body_color = mix(optics_shallow_water_color, optics_deep_water_color, body_depth_factor);
		body_color = mix(body_color, mix(optics_trough_tint, optics_crest_tint, crest_height), 0.24);
		float crest_mix = smoothstep(0.65, 1.0, crest_height) * clamp(crest_transmission_boost, 0.0, 0.5);
		vec3 effective_transmittance = mix(transmittance_rgb, sqrt(max(transmittance_rgb, vec3(0.0))), crest_mix);
		float transmission_detail_fade = smoothstep(transmission_detail_fade_start_m, max(transmission_detail_fade_end_m, transmission_detail_fade_start_m + 0.001), optical_depth_m);
		float turbidity_detail_fade = smoothstep(0.0, 1.0, clamp(water_turbidity * 0.75, 0.0, 1.0)) * smoothstep(2.0, 10.0, optical_depth_m);
		float transmission_lod = clamp(mix(transmission_detail_fade, max(transmission_detail_fade, turbidity_detail_fade), 0.35) * max(transmission_max_lod, 0.0), 0.0, 8.0);
		vec3 long_slope_normal = normalize(long_normal);
		vec3 mid_slope_normal = ocean_space_normal_to_world_scaled(texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz);
		vec3 short_slope_normal = ocean_space_normal_to_world_scaled(texture(normal_short, world_uv(world_xz, domain_short_m)).xyz);
		vec2 wave_slope = vec2(-long_slope_normal.x / max(long_slope_normal.y, 0.08), -long_slope_normal.z / max(long_slope_normal.y, 0.08)) * refraction_long_weight;
		wave_slope += vec2(-mid_slope_normal.x / max(mid_slope_normal.y, 0.08), -mid_slope_normal.z / max(mid_slope_normal.y, 0.08)) * refraction_mid_weight;
		wave_slope += vec2(-short_slope_normal.x / max(short_slope_normal.y, 0.08), -short_slope_normal.z / max(short_slope_normal.y, 0.08)) * refraction_short_weight;
		float refraction_depth_factor = 1.0 - smoothstep(refraction_depth_start_m, max(refraction_depth_end_m, refraction_depth_start_m + 0.001), bounded_view_water_path_m);
		vec2 screen_size = max(vec2(textureSize(screen_texture, 0)), vec2(1.0));
		vec4 water_view_h = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, FRAGCOORD.z, 1.0);
		vec3 water_view_position = water_view_h.xyz / max(water_view_h.w, 0.00001);
		vec3 view_direction = normalize(VIEW);
		// Continuous camera/surface authority published by the P6 waterline
		// readback. Positive means the camera is above the displaced surface;
		// negative means it is below it.
		float local_camera_depth_m = -underwater_camera_signed_distance_m;
		underwater_snell_camera_weight = underwater_snell_enabled
			? 1.0 - smoothstep(-0.20, 0.20, underwater_camera_signed_distance_m)
			: 0.0;
		// Lab does not apply the camera-to-surface medium segment twice: its
		// POST_TRANSPARENT underwater pass owns that segment while active Snell
		// transmission keeps the surface optical scene unabsorbed. Preserve that
		// behavior continuously across the Production waterline blend.
		float snell_transmission_depth_m = mix(optical_depth_m, 0.0, underwater_snell_camera_weight);
		transmittance_rgb = exp(-max(absorption_coeff_rgb, vec3(0.0)) * snell_transmission_depth_m);
		effective_transmittance = mix(transmittance_rgb, sqrt(max(transmittance_rgb, vec3(0.0))), crest_mix);
		float underwater_snell_depth_blend = smoothstep(
			0.0,
			max(underwater_snell_cone_deep_start_m, 0.001),
			max(local_camera_depth_m, 0.0)
		);
		float underwater_snell_authored_cone_angle_deg = mix(
			underwater_snell_cone_angle_surface_deg,
			underwater_snell_cone_angle_deep_deg,
			underwater_snell_depth_blend
		);
		vec2 snell_macro_slope = vec2(
			-long_slope_normal.x / max(long_slope_normal.y, 0.08),
			-long_slope_normal.z / max(long_slope_normal.y, 0.08)
		) + vec2(
			-mid_slope_normal.x / max(mid_slope_normal.y, 0.08),
			-mid_slope_normal.z / max(mid_slope_normal.y, 0.08)
		);
		vec3 underwater_snell_normal_world = normalize(vec3(
			-snell_macro_slope.x * underwater_snell_wave_distortion,
			1.0,
			-snell_macro_slope.y * underwater_snell_wave_distortion
		));
		vec3 incident_world = normalize((INV_VIEW_MATRIX * vec4(-view_direction, 0.0)).xyz);
		if (dot(incident_world, underwater_snell_normal_world) > 0.0) {
			underwater_snell_normal_world = -underwater_snell_normal_world;
		}
		float underwater_snell_cos_i = clamp(-dot(incident_world, underwater_snell_normal_world), 0.0, 1.0);
		float eta_water_air = max(underwater_water_ior, 1.0003) / 1.0003;
		float underwater_snell_k = 1.0 - eta_water_air * eta_water_air
			* (1.0 - underwater_snell_cos_i * underwater_snell_cos_i);
		float underwater_snell_tir = underwater_snell_k < 0.0 ? 1.0 : 0.0;
		float authored_cone_angle = radians(clamp(underwater_snell_authored_cone_angle_deg, 0.0, 90.0));
		float snell_cos_threshold = cos(authored_cone_angle);
		float underwater_snell_artistic_tir = underwater_snell_cos_i < snell_cos_threshold ? 1.0 : 0.0;
		underwater_snell_tir_visual_weight = underwater_snell_artistic_tir;
		if (underwater_snell_edge_softness > 0.0) {
			float edge_width = max(
				fwidth(snell_cos_threshold - underwater_snell_cos_i) * 1.5 * underwater_snell_edge_softness,
				0.0005
			);
			underwater_snell_tir_visual_weight = smoothstep(
				-edge_width,
				edge_width,
				snell_cos_threshold - underwater_snell_cos_i
			);
		}
		underwater_snell_tir_visual_weight *= underwater_snell_camera_weight;
		// P5_5_OPTICS_BASE_NORMAL
		vec3 base_normal_view = visual_normal;
		vec3 wave_normal_view = normalize(mat3(VIEW_MATRIX) * normalize(vec3(-wave_slope.x, 1.0, -wave_slope.y)));
		float grazing_confidence = smoothstep(0.18, 0.58, clamp(abs(dot(wave_normal_view, normalize(-water_view_position))), 0.0, 1.0));
		vec3 refraction_normal_view = normalize(
			mix(base_normal_view, wave_normal_view, clamp(refraction_wave_strength * refraction_depth_factor * grazing_confidence, 0.0, 1.0))
			// P5_5_OPTICS_DETAIL_NORMAL
		);
		// Lab's Snell ray uses the same displaced LONG+MID macro normal that
		// classified TIR. Blend only the camera crossing authority; never replace
		// it with the logical runtime water state or the presentation blend scalar.
		vec3 snell_normal_view = normalize(mat3(VIEW_MATRIX) * underwater_snell_normal_world);
		refraction_normal_view = normalize(mix(
			refraction_normal_view,
			snell_normal_view,
			underwater_snell_camera_weight
		));
		float snell_eta = mix(
			1.0 / 1.333,
			eta_water_air,
			underwater_snell_camera_weight
		);
		vec3 refracted_direction_view = refract(normalize(water_view_position), refraction_normal_view, snell_eta);
		if (underwater_snell_camera_weight > 0.999 && underwater_snell_tir > 0.5) {
			refracted_direction_view = vec3(0.0);
		}
		vec2 candidate_uv = SCREEN_UV;
		bool sky_refraction_active = false;
		float sky_refraction_validity = 0.0;
		if (!scene_is_sky && scene_depth_valid && water_depth_valid && length(refracted_direction_view) > 0.00001 && !any(isnan(refracted_direction_view)) && !any(isinf(refracted_direction_view))) {
			refracted_direction_view = normalize(refracted_direction_view);
			float direction_z = refracted_direction_view.z;
			float target_depth_m = min(scene_depth_m, water_depth_m + bounded_view_water_path_m);
			float path_m = abs(direction_z) > 0.00001 ? (-target_depth_m - water_view_position.z) / direction_z : -1.0;
			if (path_m >= 0.0 && path_m <= max(maximum_optical_depth_above_m * 8.0, 1.0) && !isnan(path_m) && !isinf(path_m)) {
				bool projected;
				vec2 projected_uv = optics_project_view_position(water_view_position + refracted_direction_view * path_m, PROJECTION_MATRIX, projected);
				if (projected) {
					vec2 offset_px = (projected_uv - SCREEN_UV) * screen_size;
					float offset_length = length(offset_px);
					if (refraction_max_offset_px <= 0.00001) offset_px = vec2(0.0);
					else if (offset_length > refraction_max_offset_px) offset_px *= refraction_max_offset_px / max(offset_length, 0.00001);
					candidate_uv = SCREEN_UV + offset_px / screen_size;
				}
			}
		}
		if (underwater_snell_camera_weight > 0.0001 && scene_is_sky
				&& length(refracted_direction_view) > 0.00001
				&& !any(isnan(refracted_direction_view)) && !any(isinf(refracted_direction_view))) {
			refracted_direction_view = normalize(refracted_direction_view);
			float sky_projection_distance_m = max(maximum_optical_depth_above_m * 4.0, 1000.0);
			vec3 sky_position_view = water_view_position + refracted_direction_view * sky_projection_distance_m;
			bool sky_projected;
			vec2 sky_uv = optics_project_view_position(sky_position_view, PROJECTION_MATRIX, sky_projected);
			if (sky_projected && !any(isnan(sky_uv)) && !any(isinf(sky_uv))) {
				candidate_uv = sky_uv;
				sky_refraction_validity = optics_edge_confidence(sky_uv);
				sky_refraction_active = true;
			}
		}
		vec2 snell_micro_offset_px = vec2(0.0);
		if (underwater_snell_camera_weight > 0.0001
				&& underwater_snell_artistic_tir <= 0.5
				&& length(refracted_direction_view) > 0.00001) {
			vec2 micro_slope = vec2(
				-short_slope_normal.x / max(short_slope_normal.y, 0.08),
				short_slope_normal.z / max(short_slope_normal.y, 0.08)
			);
			// P6_SNELL_DETAIL
			vec2 focal_pixels = 0.5 * screen_size * vec2(
				abs(PROJECTION_MATRIX[0][0]),
				abs(PROJECTION_MATRIX[1][1])
			);
			snell_micro_offset_px = micro_slope * focal_pixels * 0.03
				* underwater_snell_detail_strength;
			float micro_offset_length_px = length(snell_micro_offset_px);
			if (micro_offset_length_px > underwater_snell_detail_max_px
					&& underwater_snell_detail_max_px > 0.0) {
				snell_micro_offset_px *= underwater_snell_detail_max_px / micro_offset_length_px;
			}
		}
		candidate_uv = clamp(candidate_uv, vec2(0.001), vec2(0.999));
		float candidate_raw_depth = textureLod(depth_texture, candidate_uv, 0.0).r;
		float candidate_depth_m = optics_linear_depth(candidate_uv, candidate_raw_depth, INV_PROJECTION_MATRIX);
		bool candidate_valid = candidate_raw_depth > 0.000001 && candidate_raw_depth <= 1.000001 && candidate_depth_m > 0.00001 && !isnan(candidate_depth_m) && !isinf(candidate_depth_m);
		vec3 candidate_world_position = vec3(0.0);
		bool candidate_world_valid = candidate_valid && optics_world_position(candidate_uv, candidate_raw_depth, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX, candidate_world_position);
		float candidate_seabed_match = candidate_world_valid && local_depth_valid ? 1.0 - smoothstep(seabed_match_tolerance_start_m, max(seabed_match_tolerance_end_m, seabed_match_tolerance_start_m + 0.001), abs(candidate_world_position.y - expected_seabed_y)) : original_seabed_match;
		float behind_water_confidence = candidate_valid ? smoothstep(water_depth_m + 0.10, water_depth_m + 0.25, candidate_depth_m) : 0.0;
		float depth_tolerance = max(refraction_depth_tolerance_m, bounded_view_water_path_m * 0.08);
		float closer_error = candidate_valid ? max(scene_depth_m - candidate_depth_m, 0.0) : depth_tolerance + 1.0;
		float refraction_validity = sky_refraction_active
			? sky_refraction_validity
			: optics_edge_confidence(candidate_uv) * behind_water_confidence * (candidate_valid ? 1.0 - smoothstep(depth_tolerance, depth_tolerance + 0.25, closer_error) : 0.0);
		vec2 refracted_uv = mix(SCREEN_UV, candidate_uv, clamp(refraction_validity, 0.0, 1.0));
		refracted_uv = clamp(refracted_uv + snell_micro_offset_px / screen_size, vec2(0.001), vec2(0.999));
		float snell_transmission_lod = mix(transmission_lod, min(transmission_lod, 2.0), underwater_snell_camera_weight);
		vec3 refracted_scene = textureLod(screen_texture, refracted_uv, snell_transmission_lod).rgb;
		float effective_seabed_match = mix(original_seabed_match, candidate_seabed_match, clamp(refraction_validity, 0.0, 1.0)) * optical_seabed_confidence;
		float seabed_transmission_weight = mix(1.0, bottom_visibility, effective_seabed_match);
		float trough_density = 1.0 + (1.0 - smoothstep(0.0, 0.45, crest_height)) * clamp(trough_density_boost, 0.0, 0.5);
		float path_saturation = clamp(snell_transmission_depth_m / max(maximum_optical_depth_above_m, 0.001), 0.0, 1.0);
		float scattering_response = clamp((1.0 - exp(-0.22 * clamp(water_turbidity, 0.0, 2.0) * snell_transmission_depth_m)) * mix(0.55, 1.0, path_saturation), 0.0, 1.0);
		float shallow_scattering_factor = 1.0 - smoothstep(shallow_scattering_depth_start_m, max(shallow_scattering_depth_end_m, shallow_scattering_depth_start_m + 0.001), local_water_depth_m);
		float scattering_tint_influence = mix(clamp(scattering_deep_tint_influence, 0.0, 1.0), clamp(scattering_shallow_tint_influence, 0.0, 1.0), shallow_scattering_factor);
		vec3 scattering_tint = mix(optics_deep_water_color * 0.65, scattering_color, scattering_tint_influence);
		float scattering_share = clamp(scattering_response * clamp(scattering_strength, 0.0, 2.0) * 0.35, 0.0, 0.45);
		vec3 absorbed = vec3(1.0) - effective_transmittance;
		vec3 body_component = body_color * absorbed * (1.0 - scattering_share) * trough_density;
		vec3 scattering_component = scattering_tint * absorbed * scattering_share * trough_density;
		float shallow_light_response = shallow_scattering_factor * clamp(dot(effective_transmittance, vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0) * mix(0.5, 1.0, clamp(dot(max(refracted_scene, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722)), 0.0, 1.0));
		scattering_component += scattering_tint * clamp(shallow_light_response * clamp(shallow_scattering_strength, 0.0, 2.0) * clamp(scattering_strength, 0.0, 2.0) * 0.55, 0.0, 0.30);
		float distance_opacity = smoothstep(opacity_distance_start, max(opacity_distance_end, opacity_distance_start + 0.001), distance_m);
		vec3 surface_color = mix(body_color, optics_horizon_water_color, distance_opacity);
		float fresnel = pow(1.0 - clamp(dot(visual_normal, VIEW), 0.0, 1.0), 5.0);
		float snell_f0 = pow((eta_water_air - 1.0) / (eta_water_air + 1.0), 2.0);
		float snell_fresnel = snell_f0 + (1.0 - snell_f0) * pow(1.0 - underwater_snell_cos_i, 5.0);
		if (underwater_snell_tir > 0.5) snell_fresnel = 1.0;
		fresnel = mix(fresnel, snell_fresnel, clamp(underwater_snell_strength * underwater_snell_camera_weight, 0.0, 1.0));
		vec3 optical_scene = refracted_scene * effective_transmittance * seabed_transmission_weight + body_component + scattering_component;
		float shallow_relief = clamp(shallow_fresnel_relief, 0.0, 1.0) * real_seabed_coverage * (1.0 - smoothstep(shallow_fresnel_depth_start_m, max(shallow_fresnel_depth_end_m, shallow_fresnel_depth_start_m + 0.001), local_water_depth_m));
		float surface_weight = fresnel + (1.0 - fresnel) * distance_opacity * (1.0 - shallow_relief);
		if (underwater_snell_tir_visual_weight > 0.0) {
			surface_weight = max(surface_weight, clamp(underwater_tir_strength * underwater_snell_strength * underwater_snell_tir_visual_weight, 0.0, 1.0));
		}
		// Lab composes screen-space TIR into the optical scene before the final
		// surface mix. The reflection-enabled variant replaces this marker with
		// the existing SSPR sample; the fallback variant leaves it as a comment.
		// P6_SNELL_TIR_COMPOSITION
		// Surface-air blending remains presentation-only. Snell/TIR gets its own
		// continuous geometric crossing weight so the Lab underwater path is not
		// discarded when the camera is below the displaced interface.
		float underwater_snell_presentation_weight = max(clamp(surface_air_blend, 0.0, 1.0), underwater_snell_camera_weight);
		ALBEDO = mix(base_surface_albedo, mix(optical_scene, surface_color, surface_weight), underwater_snell_presentation_weight);
	}
'''

const REFLECTIONS_UNIFORMS := '''
uniform bool reflection_sspr_available = false;
uniform sampler2D reflection_sspr_texture : repeat_disable, filter_linear_mipmap;
uniform float reflection_base_roughness = 0.08;
uniform vec2 reflection_roughness_distance_m = vec2(80.0, 300.0);
uniform float reflection_sspr_distortion_strength = 1.0;
uniform float reflection_sspr_edge_fade = 0.25;
uniform float reflection_radiance_exposure_ev = -1.5;
uniform float reflection_radiance_saturation = 0.36;
uniform float reflection_screen_space_weight = 0.55;
uniform float reflection_environment_specular_near_boost = 0.65;
uniform float reflection_environment_specular_far_boost = 0.65;
uniform float reflection_environment_specular_near_distance = 20.0;
uniform float reflection_environment_specular_far_distance = 80.0;

vec3 reflection_grade_radiance(vec3 radiance) {
	vec3 exposed = max(radiance, vec3(0.0)) * exp2(reflection_radiance_exposure_ev);
	float luma = dot(exposed, vec3(0.2126, 0.7152, 0.0722));
	return mix(vec3(luma), exposed, reflection_radiance_saturation);
}

float reflection_edge_confidence(vec2 uv) {
	float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	return reflection_sspr_edge_fade <= 0.0001 ? 1.0 : smoothstep(0.0, reflection_sspr_edge_fade, edge);
}

'''

const REFLECTIONS_FRAGMENT := '''
	// Macro FFT normal owns ray distortion. Foam changes final roughness only.
	vec3 sspr_macro_normal_view = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);
	vec3 flat_normal_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 view_direction = normalize(VIEW);
	vec3 planar_ray = normalize(reflect(-view_direction, flat_normal_view));
	vec3 wave_ray = normalize(reflect(-view_direction, sspr_macro_normal_view));
	vec2 projection_scale = vec2(PROJECTION_MATRIX[0][0], PROJECTION_MATRIX[1][1]);
	vec2 projected_delta = (wave_ray.xy / max(abs(wave_ray.z), 0.12) - planar_ray.xy / max(abs(planar_ray.z), 0.12)) * projection_scale * 0.5;
	float camera_distance = distance(world_xz, camera_world_xz);
	float distortion_scale = reflection_sspr_distortion_strength * clamp(camera_distance / max(camera_distance + reflection_roughness_distance_m.x, 0.001), 0.15, 1.0);
	vec2 sspr_uv = SCREEN_UV + projected_delta * distortion_scale;
	float uv_inside = float(all(greaterThanEqual(sspr_uv, vec2(0.0))) && all(lessThanEqual(sspr_uv, vec2(1.0))));
	float distortion_confidence = exp(-length(projected_delta * distortion_scale) * 2.5);
	// Distance roughening is a reflection filter, preserving the P2/P3 final
	// material roughness that was already approved with Reflections OFF.
	float sspr_filter_roughness = clamp(ROUGHNESS + smoothstep(reflection_roughness_distance_m.x, max(reflection_roughness_distance_m.y, reflection_roughness_distance_m.x + 0.001), camera_distance) * max(0.23 - reflection_base_roughness, 0.0), 0.0, 1.0);
	float roughness_confidence = 1.0 - smoothstep(0.55, 0.90, sspr_filter_roughness);
	float slope_confidence = 1.0 - smoothstep(0.65, 1.0, 1.0 - clamp(shading_normal_world.y, 0.0, 1.0));
	vec4 sspr_sample = reflection_sspr_available && uv_inside > 0.5 ? textureLod(reflection_sspr_texture, sspr_uv, sspr_filter_roughness * max(log2(float(max(textureSize(reflection_sspr_texture, 0).x, textureSize(reflection_sspr_texture, 0).y))), 0.0)) : vec4(0.0);
	float confidence = clamp(sspr_sample.a * reflection_edge_confidence(sspr_uv) * distortion_confidence * roughness_confidence * slope_confidence * reflection_screen_space_weight * uv_inside, 0.0, 1.0);
	// Alpha is confidence, never opacity: alpha=0 leaves Godot PBR/IBL intact.
	RADIANCE = vec4(reflection_grade_radiance(sspr_sample.rgb), confidence);
	// Water IOR 1.333: F0 = 0.020373, represented by Godot's scalar specular.
	float specular_far_distance = max(reflection_environment_specular_far_distance, reflection_environment_specular_near_distance + 0.001);
	float specular_distance_t = smoothstep(reflection_environment_specular_near_distance, specular_far_distance, camera_distance);
	float environment_specular_boost = mix(reflection_environment_specular_near_boost, reflection_environment_specular_far_boost, specular_distance_t);
	float underwater_water_specular = 0.356835 * environment_specular_boost;
	SPECULAR = mix(underwater_water_specular, 0.2546625 * environment_specular_boost, clamp(surface_air_blend, 0.0, 1.0));
'''

var _material: ShaderMaterial
var _levels: Array[MeshInstance3D] = []
const LOCAL_BREAKER_REFINEMENT_MAX_ACTIVE_BREAKERS := 1
const LOCAL_BREAKER_REFINEMENT_PREFERRED_COARSE_CELLS_PER_TILE := 16
const LOCAL_BREAKER_REFINEMENT_MAX_CREST_LENGTH_M := 12.0
const ACTIVE_FRONT_REFINEMENT_SCAN_INTERVAL_S := 0.25
var _base_clipmap_triangles := 0
var _base_l0_triangles := 0
var _local_breaker_refinement_enabled := false
var _local_breaker_refinement_debug_visible := false
var _local_breaker_refinement_batcher
var _local_breaker_refinement_manager
var _local_breaker_refinement_region
var _local_breaker_refinement_coarse_mesh: ArrayMesh
var _local_breaker_refinement_high_meshes: Array[ArrayMesh] = []
var _local_breaker_refinement_grid_width := 0
var _local_breaker_refinement_grid_height := 0
var _local_breaker_refinement_layout: Dictionary = {}
var _local_breaker_refinement_tile_transforms: Array[Transform3D] = []
var _local_breaker_refinement_last_tiles: Array[Vector2i] = []
var _local_breaker_refinement_initialized := false
var _local_breaker_refinement_authority: Dictionary = {}
var _active_front_refinement_authority: Dictionary = {}
var _active_front_refinement_scan_pending := false
var _active_front_refinement_scan_elapsed_s := 0.0
var _local_breaker_refinement_info: Dictionary = {}
var _local_breaker_refinement_meshes_generated_since_startup := 0
var _local_breaker_refinement_arraymesh_rebuilds := 0
var _breaker_shape_lab_topology_meshes: Array[MeshInstance3D] = []
var _breaker_shape_lab_topology_info := {}
var _breaker_shape_lab_topology_mode := 0
var _breaker_shape_lab_refinement_instance: MeshInstance3D
var _breaker_shape_lab_refinement_meshes: Array[ArrayMesh] = []
var _breaker_shape_lab_refinement_info := {}
var _breaker_shape_lab_refinement_mode := -1
var _breaker_shape_lab_refinement_active := false
var _breaker_shape_lab_tiled_batcher
var _breaker_shape_lab_refinement_manager
var _breaker_shape_lab_refinement_region
var _breaker_shape_lab_auto_last_tiles: Array[Vector2i] = []
var _breaker_shape_lab_auto_initialized := false
var _breaker_shape_lab_auto_tile_changes_this_frame := 0
var _breaker_shape_lab_auto_active := false
var _breaker_shape_lab_auto_front_extent_m := 5.0
var _breaker_shape_lab_auto_rear_extent_m := 2.0
var _breaker_shape_lab_tiled_coarse_mesh: ArrayMesh
var _breaker_shape_lab_tiled_coarse_triangles := 0
var _breaker_shape_lab_tiled_high_meshes: Array[ArrayMesh] = []
var _breaker_shape_lab_tiled_info := {}
var _breaker_shape_lab_tiled_pattern := ""
var _breaker_shape_lab_tiled_active := false
var _breaker_shape_lab_tiled_grid_width := 0
var _breaker_shape_lab_tiled_grid_height := 0
var _breaker_shape_lab_tiled_meshes_generated_since_startup := 0
var _breaker_shape_lab_tiled_meshes_generated_this_frame := 0
var _breaker_shape_lab_tiled_arraymesh_rebuilds_this_frame := 0
var _breaker_shape_lab_tiled_mesh_assignments_last_transition := 0
var _breaker_shape_lab_tiled_max_mesh_assignments := 0
var _breaker_shape_lab_tiled_transform_updates_last_transition := 0
var _sea_level := 0.0
var _quality: Resource
var _wave_configs: Array = []
var _optics_shader: Shader
var _variant_shaders := {}
var _variant_materials: Dictionary = {}
var _surface_parameter_state: Dictionary = {}
var _active_shader_variant_key := ""
var _coastal_data := {}
var _coastal_waves_enabled := false
var _optics_enabled := false
var _optics_profile: OceanOpticsProfile
var _snell_profile: OceanUnderwaterMediumProfile
var _reflections_enabled := false
var _reflection_profile: OceanReflectionProfile
var _reflection_texture: Texture2D
var _reflection_texture_available := false
var _crest_foam_profile: OceanCrestFoamProfile
var _surface_foam_profile: OceanSurfaceFoamProfile
var _surface_detail_enabled := false
var _surface_detail_profile: OceanSurfaceDetailProfile
var _wave_time_s := 0.0
var _surface_scale := 1.0
var _clipmap_geometry_scale := 1.0
var _ocean_space_horizontal_scale := 1.0
var _base_wave_domains := Vector3(512.0, 137.0, 37.0)
var _fft_displacement_bounds_ocean := Vector3.ZERO
var _clipmap_culling_bounds_signature := ""
var _clipmap_culling_bounds_update_count := 0
var _breakers_requested := false
var _breakers_enabled := false
var _breaker_runtime_enabled := false
var _breaker_profile: OceanBreakerProfile
var _breaker_lifecycle_texture: Texture2DRD
var _breaker_multiphase_vdm: Texture2D
var _breaker_shape_lab_shader: Shader
var _breaker_shape_lab_material: ShaderMaterial
var _breaker_shape_lab_active := false
var _breaker_shape_lab_origin := Vector2.ZERO
var _breaker_shape_lab_propagation := Vector2(0.0, 1.0)
var _breaker_shape_lab_reference_direction := Vector2(1.0, 0.0)
var _breaker_shape_lab_wavefront_width_m := 0.0
var _breaker_shape_lab_length_m := 0.0
var _breaker_shape_lab_travel_m := 8.0
var _breaker_shape_lab_animation_enabled := false
var _breaker_shape_lab_phase_override := -1.0
var _breaker_shape_lab_debug_mode := 1
var _breaker_shape_lab_multiphase := false
var _crest_foam_enabled := false
var _surface_foam_enabled := false
var _surface_foam_presentation_enabled := false
var _runtime_water_state: StringName = &"TRANSITION"
var _camera_surface_signed_distance_m := 1.0
var _surface_air_blend := 1.0


func initialize(quality: Resource, sea_level: float, configs: Array, displacements: Array[Texture2DRD], normals: Array[Texture2DRD], crest_foams: Array[Texture2DRD], fft_displacement_bounds := Vector3(-1.0, -1.0, -1.0)) -> void:
	shutdown()
	assert(configs.size() == 3 and displacements.size() == 3 and normals.size() == 3 and crest_foams.size() == 3)
	_variant_shaders.clear()
	_variant_materials.clear()
	_surface_parameter_state.clear()
	_material = null
	_quality = quality
	_sea_level = sea_level
	_wave_configs = configs.duplicate()
	_fft_displacement_bounds_ocean = fft_displacement_bounds if fft_displacement_bounds.x >= 0.0 and fft_displacement_bounds.y >= 0.0 else _derive_fft_displacement_bounds(configs)
	_prepare_shader_variant("base:fallback:flat:nobreaker", false, false, false, false)
	_material = _variant_materials["base:fallback:flat:nobreaker"] as ShaderMaterial
	_active_shader_variant_key = "base:fallback:flat:nobreaker"
	_set_surface_shader_parameter(&"deep_water_color", Color(0.019474017, 0.0909042, 0.088472255))
	_set_surface_shader_parameter(&"horizon_water_color", Color(0.0075189536, 0.07750165, 0.04554274))
	_set_surface_shader_parameter(&"surface_air_blend", _surface_air_blend)
	_set_surface_shader_parameter(&"underwater_camera_signed_distance_m", _camera_surface_signed_distance_m)
	_set_surface_shader_parameter(&"short_fade_range_m", quality.short_fade_range_m)
	_set_surface_shader_parameter(&"mid_fade_range_m", quality.mid_fade_range_m)
	_set_surface_shader_parameter(&"long_fade_range_m", quality.long_fade_range_m)
	_base_wave_domains = Vector3(
		float(configs[0].domain_size_m),
		float(configs[1].domain_size_m),
		float(configs[2].domain_size_m)
	)
	for index in 3:
		var id: String = ["long", "mid", "short"][index]
		_set_surface_shader_parameter("displacement_%s" % id, displacements[index])
		_set_surface_shader_parameter("normal_%s" % id, normals[index])
		_set_surface_shader_parameter("crest_foam_%s" % id, crest_foams[index])
	_apply_ocean_space_domains()
	_set_surface_shader_parameter(&"crest_breakup_texture", CREST_BREAKUP_NOISE)
	_apply_crest_foam_profile()
	_apply_surface_foam_profile()
	set_surface_foam(null, null, null, false)
	for level in quality.level_count:
		var spacing: float = quality.base_spacing_m * pow(2.0, level)
		var instance := MeshInstance3D.new()
		instance.name = "ClipmapLevel%d" % level
		instance.mesh = MeshBuilder.build_level(quality.cells_per_side, spacing, level)
		instance.material_override = _material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.extra_cull_margin = CLIPMAP_EXTRA_CULL_MARGIN_M
		add_child(instance)
		_levels.append(instance)
	_base_clipmap_triangles = 0
	for level in _levels:
		_base_clipmap_triangles += _mesh_triangle_count(level.mesh as ArrayMesh)
	_base_l0_triangles = _mesh_triangle_count(_levels[0].mesh as ArrayMesh) if not _levels.is_empty() else 0
	_update_clipmap_culling_bounds()


func set_debug_view(value: int) -> void:
	_set_surface_shader_parameter(&"debug_view", clampi(value, 0, 1))


func set_wave_time(value: float) -> void:
	_wave_time_s = maxf(value, 0.0)
	_apply_wave_time()


func _apply_wave_time() -> void:
	_set_surface_shader_parameter(&"ocean_time_s", _wave_time_s)


func set_surface_scale(value: float) -> void:
	_surface_scale = clampf(value, 0.25, 4.0)
	_apply_surface_scale()
	_update_clipmap_culling_bounds()


func _apply_surface_scale() -> void:
	_set_surface_shader_parameter(&"ocean_surface_scale", _surface_scale)


func set_clipmap_geometry_scale(value: float) -> void:
	_clipmap_geometry_scale = clampf(value, 0.25, 4.0)
	_ocean_space_horizontal_scale = _clipmap_geometry_scale
	_apply_clipmap_geometry_scale()
	_apply_ocean_space_domains()
	_apply_crest_foam_profile()
	_apply_surface_foam_profile()
	_apply_surface_detail_profile()
	_update_local_breaker_space_scale()
	_update_clipmap_culling_bounds()


func set_ocean_space_contract(contract: Dictionary) -> void:
	_surface_scale = clampf(float(contract.get("ocean_scale", _surface_scale)), 0.25, 4.0)
	_clipmap_geometry_scale = clampf(float(contract.get("clipmap_geometry_scale", _clipmap_geometry_scale)), 0.25, 4.0)
	_ocean_space_horizontal_scale = _clipmap_geometry_scale
	_apply_surface_scale()
	_apply_clipmap_geometry_scale()
	_apply_ocean_space_domains()
	_apply_crest_foam_profile()
	_apply_surface_foam_profile()
	_apply_surface_detail_profile()
	_update_local_breaker_space_scale()
	_update_clipmap_culling_bounds()


func _apply_clipmap_geometry_scale() -> void:
	_set_surface_shader_parameter(&"clipmap_geometry_scale", _clipmap_geometry_scale)


func _apply_ocean_space_domains() -> void:
	var effective_domains := _base_wave_domains * _ocean_space_horizontal_scale
	_set_surface_shader_parameter(&"domain_long_m", effective_domains.x)
	_set_surface_shader_parameter(&"domain_mid_m", effective_domains.y)
	_set_surface_shader_parameter(&"domain_short_m", effective_domains.z)


func get_effective_wave_domains() -> Vector3:
	return Vector3(
		float(_material.get_shader_parameter(&"domain_long_m")),
		float(_material.get_shader_parameter(&"domain_mid_m")),
		float(_material.get_shader_parameter(&"domain_short_m"))
	)


func get_effective_ocean_space_scales() -> Vector2:
	return Vector2(
		float(_material.get_shader_parameter(&"clipmap_geometry_scale")),
		float(_material.get_shader_parameter(&"ocean_surface_scale"))
	)


func get_effective_surface_foam_domains() -> Vector2:
	return Vector2(
		float(_material.get_shader_parameter(&"surface_foam_source_domain_m")),
		float(_material.get_shader_parameter(&"surface_foam_field_domain_m"))
	)


static func build_gpu_culling_aabb(authored_aabb: AABB, horizontal_scale: float, vertical_scale: float, horizontal_displacement_m: float, vertical_displacement_m: float) -> AABB:
	var h := absf(horizontal_scale)
	var v := absf(vertical_scale)
	var authored_max := authored_aabb.position + authored_aabb.size
	var scaled_min := Vector3(
		minf(authored_aabb.position.x * h, authored_max.x * h),
		minf(authored_aabb.position.y * v, authored_max.y * v),
		minf(authored_aabb.position.z * h, authored_max.z * h))
	var scaled_max := Vector3(
		maxf(authored_aabb.position.x * h, authored_max.x * h),
		maxf(authored_aabb.position.y * v, authored_max.y * v),
		maxf(authored_aabb.position.z * h, authored_max.z * h))
	var horizontal_delta := maxf(horizontal_displacement_m, 0.0)
	var vertical_delta := maxf(vertical_displacement_m, 0.0)
	var minimum := scaled_min - Vector3(horizontal_delta, vertical_delta, horizontal_delta)
	var maximum := scaled_max + Vector3(horizontal_delta, vertical_delta, horizontal_delta)
	return AABB(minimum, maximum - minimum)


func get_clipmap_culling_bounds_contract() -> Array:
	var result: Array = []
	for index in _levels.size():
		var level := _levels[index]
		if not is_instance_valid(level) or not level.mesh is ArrayMesh:
			continue
		result.append({
			"level": index,
			"instance_id": level.get_instance_id(),
			"mesh_id": level.mesh.get_instance_id(),
			"authored_aabb": (level.mesh as ArrayMesh).get_aabb(),
			"custom_aabb": level.custom_aabb,
			"extra_cull_margin": level.extra_cull_margin,
		})
	return result


func get_clipmap_culling_bounds_state() -> Dictionary:
	var displacement := _get_gpu_culling_displacement_world()
	return {
		"horizontal_displacement_ocean_m": _fft_displacement_bounds_ocean.x,
		"vertical_displacement_ocean_m": _fft_displacement_bounds_ocean.y,
		"horizontal_displacement_world_m": displacement.x,
		"vertical_displacement_world_m": displacement.y,
		"horizontal_scale": _clipmap_geometry_scale,
		"vertical_scale": _surface_scale,
		"signature": _clipmap_culling_bounds_signature,
		"update_count": _clipmap_culling_bounds_update_count,
	}


func _derive_fft_displacement_bounds(configs: Array) -> Vector3:
	var result := Vector3.ZERO
	for config in configs:
		if config == null:
			continue
		var measured := float(config.get("measured_hs_m"))
		var target := float(config.get("target_hs_m"))
		var hs := measured if measured > 0.0 else target
		result.x += absf(hs) * maxf(float(config.get("choppiness")), 0.0)
		result.y += absf(hs)
	return result


func _get_gpu_culling_displacement_world() -> Vector2:
	var horizontal := absf(_fft_displacement_bounds_ocean.x) * absf(_clipmap_geometry_scale)
	var vertical := absf(_fft_displacement_bounds_ocean.y) * absf(_surface_scale)
	if _breakers_enabled:
		var values: OceanBreakerProfile = _breaker_profile if _breaker_profile != null else BreakerProfile.new()
		var longest_wavelength := 0.0
		if not _wave_configs.is_empty() and _wave_configs[0] != null:
			longest_wavelength = maxf(float(_wave_configs[0].get("max_wavelength_m")), 0.0)
		var horizontal_fraction := maxf(float(values.get("max_horizontal_fraction")), 0.0)
		var vertical_lift_scale := maxf(float(values.get("max_vertical_lift_scale")), 0.0)
		# Breaker dimensions are authored in Ocean Space and the final surface
		# displacement applies H once. Keep culling on that same one-scale contract.
		horizontal += longest_wavelength * horizontal_fraction * absf(_clipmap_geometry_scale)
		vertical += absf(_fft_displacement_bounds_ocean.y) * vertical_lift_scale * absf(_surface_scale)
	return Vector2(horizontal, vertical)


func _update_clipmap_culling_bounds() -> void:
	if _levels.is_empty():
		return
	var displacement := _get_gpu_culling_displacement_world()
	var signature := "%0.6f|%0.6f|%0.6f|%0.6f|%s|%0.6f" % [
		_clipmap_geometry_scale, _surface_scale, displacement.x, displacement.y,
		str(_breakers_enabled), _longest_breaker_wavelength_m()]
	if signature == _clipmap_culling_bounds_signature:
		return
	for level in _levels:
		if not is_instance_valid(level) or not level.mesh is ArrayMesh:
			continue
		var authored_aabb := (level.mesh as ArrayMesh).get_aabb()
		level.custom_aabb = build_gpu_culling_aabb(authored_aabb, _clipmap_geometry_scale, _surface_scale, displacement.x, displacement.y)
	_update_local_breaker_culling_bounds(displacement)
	_update_breaker_shape_lab_culling_bounds(displacement)
	_clipmap_culling_bounds_signature = signature
	_clipmap_culling_bounds_update_count += 1


func _longest_breaker_wavelength_m() -> float:
	if _wave_configs.is_empty() or _wave_configs[0] == null:
		return 0.0
	return maxf(float(_wave_configs[0].get("max_wavelength_m")), 0.0)


func _update_local_breaker_culling_bounds(displacement: Vector2) -> void:
	if _local_breaker_refinement_batcher == null:
		return
	var layout: Dictionary = _local_breaker_refinement_layout
	var tile_size_m: float = float(layout.get("tile_size_ocean_m", 1.0)) * absf(_clipmap_geometry_scale)
	var extent := Vector3(
		float(_local_breaker_refinement_grid_width) * tile_size_m,
		0.0,
		float(_local_breaker_refinement_grid_height) * tile_size_m)
	var authored := AABB(Vector3(-extent.x * 0.5, 0.0, -extent.z * 0.5), extent)
	_local_breaker_refinement_batcher.set_culling_aabb(build_gpu_culling_aabb(authored, 1.0, 1.0, displacement.x, displacement.y))


func _update_breaker_shape_lab_culling_bounds(displacement: Vector2) -> void:
	for diagnostic in _breaker_shape_lab_topology_meshes:
		if is_instance_valid(diagnostic) and diagnostic.mesh is ArrayMesh:
			diagnostic.custom_aabb = build_gpu_culling_aabb((diagnostic.mesh as ArrayMesh).get_aabb(), _clipmap_geometry_scale, _surface_scale, displacement.x, displacement.y)
	if is_instance_valid(_breaker_shape_lab_refinement_instance) and _breaker_shape_lab_refinement_instance.mesh is ArrayMesh:
		_breaker_shape_lab_refinement_instance.custom_aabb = build_gpu_culling_aabb((_breaker_shape_lab_refinement_instance.mesh as ArrayMesh).get_aabb(), _clipmap_geometry_scale, _surface_scale, displacement.x, displacement.y)
	if _breaker_shape_lab_tiled_batcher != null:
		var authored: AABB = _breaker_shape_lab_tiled_batcher.get_authored_aabb()
		_breaker_shape_lab_tiled_batcher.set_culling_aabb(build_gpu_culling_aabb(authored, 1.0, 1.0, displacement.x, displacement.y))


func set_local_breaker_refinement_enabled(enabled: bool) -> void:
	_local_breaker_refinement_enabled = enabled
	if not enabled:
		if not _levels.is_empty() and is_instance_valid(_levels[0]):
			_levels[0].visible = true
		if _local_breaker_refinement_batcher != null:
			_local_breaker_refinement_batcher.hide()
		# Force a fresh assignment pass when the prototype gate is re-enabled;
		# hiding batches must not make the next ON sample look unchanged.
		_local_breaker_refinement_last_tiles = [Vector2i(-1, -1)]
		_local_breaker_refinement_info["enabled"] = false
		_local_breaker_refinement_info["active"] = false
		_local_breaker_refinement_info["high_tile_count"] = 0
		_local_breaker_refinement_info["coarse_tile_count"] = _local_breaker_refinement_grid_width * _local_breaker_refinement_grid_height
		_local_breaker_refinement_info["total_triangles"] = _base_l0_triangles
		_local_breaker_refinement_info["production_total_triangles"] = _base_clipmap_triangles
		_local_breaker_refinement_info["active_batch_count"] = 0
		return
	_ensure_local_breaker_refinement()
	if not _levels.is_empty() and is_instance_valid(_levels[0]):
		_levels[0].visible = false
	_update_local_breaker_refinement()


func set_local_breaker_refinement_debug_visible(visible: bool) -> void:
	_local_breaker_refinement_debug_visible = visible
	_local_breaker_refinement_info["debug_visible"] = visible


func set_local_breaker_refinement_authority(authority: Dictionary) -> void:
	_local_breaker_refinement_authority = authority.duplicate(true)
	if _local_breaker_refinement_enabled:
		_update_local_breaker_refinement()


func get_local_breaker_refinement_info() -> Dictionary:
	# Callers use this for A/B snapshots; return a copy so a later ON/OFF
	# transition cannot mutate the previously captured measurement.
	return _local_breaker_refinement_info.duplicate(true)


func _ensure_local_breaker_refinement() -> void:
	if _local_breaker_refinement_initialized or _quality == null or get_parent() == null:
		return
	_local_breaker_refinement_layout = _derive_local_breaker_refinement_layout()
	var tile_size_ocean_m: float = float(_local_breaker_refinement_layout["tile_size_ocean_m"])
	var coarse_spacing_ocean_m: float = float(_local_breaker_refinement_layout["coarse_spacing_ocean_m"])
	var high_spacing_ocean_m: float = float(_local_breaker_refinement_layout["high_spacing_ocean_m"])
	var tile_size_m: float = tile_size_ocean_m * absf(_clipmap_geometry_scale)
	var l0_extent_ocean_m: float = float(_local_breaker_refinement_layout["l0_extent_ocean_m"])
	var l0_extent_m: float = l0_extent_ocean_m * absf(_clipmap_geometry_scale)
	_local_breaker_refinement_grid_width = int(_local_breaker_refinement_layout["grid_width"])
	_local_breaker_refinement_grid_height = int(_local_breaker_refinement_layout["grid_height"])
	var reference_direction := Vector2(0.0, 1.0)
	_local_breaker_refinement_coarse_mesh = MeshBuilder.build_aligned_grid(tile_size_ocean_m, tile_size_ocean_m, coarse_spacing_ocean_m, reference_direction)
	_local_breaker_refinement_high_meshes.clear()
	var high_variant_info: Array = []
	for edge_mask in 16:
		var variant: Dictionary = MeshBuilder.build_tiled_high_variant(tile_size_ocean_m, high_spacing_ocean_m, coarse_spacing_ocean_m, edge_mask, reference_direction)
		_local_breaker_refinement_high_meshes.append(variant["mesh"] as ArrayMesh)
		variant.erase("mesh")
		high_variant_info.append(variant)
	_local_breaker_refinement_tile_transforms = _build_local_breaker_tile_transforms(_surface_world_origin())
	var variant_meshes: Array[ArrayMesh] = [_local_breaker_refinement_coarse_mesh]
	variant_meshes.append_array(_local_breaker_refinement_high_meshes)
	_local_breaker_refinement_batcher = RefinementBatcher.new()
	_local_breaker_refinement_batcher.configure(self, _material, variant_meshes, _local_breaker_refinement_tile_transforms)
	_local_breaker_refinement_manager = RefinementManager.new()
	_local_breaker_refinement_manager.configure(_surface_world_origin(), Vector2(0.0, 1.0), Vector2(1.0, 0.0), _local_breaker_refinement_grid_width, _local_breaker_refinement_grid_height, tile_size_m)
	_local_breaker_refinement_region = BreakerRefinementRegion.new()
	_local_breaker_refinement_last_tiles = [Vector2i(-1, -1)]
	_local_breaker_refinement_initialized = true
	_local_breaker_refinement_meshes_generated_since_startup = 1 + _local_breaker_refinement_high_meshes.size()
	_local_breaker_refinement_arraymesh_rebuilds = 0
	_local_breaker_refinement_info = {
		"enabled": false,
		"active": false,
		"max_active_breakers": LOCAL_BREAKER_REFINEMENT_MAX_ACTIVE_BREAKERS,
		"grid_width": _local_breaker_refinement_grid_width,
		"grid_height": _local_breaker_refinement_grid_height,
		"tile_size_m": tile_size_m,
		"coarse_spacing_m": coarse_spacing_ocean_m * absf(_clipmap_geometry_scale),
		"high_spacing_m": high_spacing_ocean_m * absf(_clipmap_geometry_scale),
		"l0_extent_m": l0_extent_m,
		"coarse_cells_per_tile": int(_local_breaker_refinement_layout["coarse_cells_per_tile"]),
		"tile_size_ocean_m": tile_size_ocean_m,
		"coarse_spacing_ocean_m": coarse_spacing_ocean_m,
		"high_spacing_ocean_m": high_spacing_ocean_m,
		"l0_extent_ocean_m": l0_extent_ocean_m,
		"prebuilt_mesh_count": _local_breaker_refinement_meshes_generated_since_startup,
		"high_variant_count": _local_breaker_refinement_high_meshes.size(),
		"high_variants": high_variant_info,
		"coarse_tile_count": _local_breaker_refinement_grid_width * _local_breaker_refinement_grid_height,
		"high_tile_count": 0,
		"total_triangles": _base_l0_triangles,
		"production_total_triangles": _base_clipmap_triangles,
		"active_batch_count": 0,
		"arraymesh_rebuilds_runtime": 0,
		"high_tiles": [],
		"debug_visible": _local_breaker_refinement_debug_visible,
	}
	_update_local_breaker_culling_bounds(_get_gpu_culling_displacement_world())


func _derive_local_breaker_refinement_layout() -> Dictionary:
	var cells_per_side: int = maxi(int(_quality.get("cells_per_side")), 4)
	var coarse_spacing_ocean_m: float = maxf(float(_quality.get("base_spacing_m")), 0.001)
	var coarse_cells_per_tile: int = 4
	if cells_per_side % LOCAL_BREAKER_REFINEMENT_PREFERRED_COARSE_CELLS_PER_TILE == 0:
		coarse_cells_per_tile = LOCAL_BREAKER_REFINEMENT_PREFERRED_COARSE_CELLS_PER_TILE
	elif cells_per_side % 8 == 0:
		coarse_cells_per_tile = 8
	var high_spacing_ocean_m: float = coarse_spacing_ocean_m * 0.5
	var tile_size_ocean_m: float = coarse_spacing_ocean_m * float(coarse_cells_per_tile)
	var grid_width: int = maxi(cells_per_side / coarse_cells_per_tile, 1)
	var l0_extent_ocean_m: float = float(cells_per_side) * coarse_spacing_ocean_m
	return {
		"coarse_cells_per_tile": coarse_cells_per_tile,
		"coarse_spacing_ocean_m": coarse_spacing_ocean_m,
		"high_spacing_ocean_m": high_spacing_ocean_m,
		"tile_size_ocean_m": tile_size_ocean_m,
		"grid_width": grid_width,
		"grid_height": grid_width,
		"l0_extent_ocean_m": l0_extent_ocean_m,
	}


func _update_local_breaker_refinement() -> void:
	if not _local_breaker_refinement_initialized or _local_breaker_refinement_manager == null or _local_breaker_refinement_region == null:
		return
	var surface_origin := _surface_world_origin()
	_local_breaker_refinement_manager.set_origin_world(surface_origin)
	var authority := _local_breaker_refinement_authority.duplicate(true)
	if authority.is_empty():
		authority = _active_front_refinement_authority.duplicate(true)
	if authority.has("crest_length"):
		authority["crest_length"] = minf(float(authority["crest_length"]), LOCAL_BREAKER_REFINEMENT_MAX_CREST_LENGTH_M)
	_local_breaker_refinement_region.update_from_authority(authority)
	var high_tiles: Array[Vector2i] = _local_breaker_refinement_manager.select_high_tiles(_local_breaker_refinement_region)
	var origin_changed := not surface_origin.is_equal_approx(_local_breaker_refinement_info.get("surface_origin_world", Vector2(INF, INF)))
	if origin_changed:
		_local_breaker_refinement_tile_transforms = _build_local_breaker_tile_transforms(surface_origin)
		_local_breaker_refinement_batcher.update_tile_transforms(_local_breaker_refinement_tile_transforms)
		_local_breaker_refinement_info["surface_origin_world"] = surface_origin
	var changed := high_tiles != _local_breaker_refinement_last_tiles
	var previous_tiles := _local_breaker_refinement_last_tiles.duplicate()
	if changed:
		_local_breaker_refinement_last_tiles = high_tiles.duplicate()
		_set_local_breaker_refinement_pattern(high_tiles)
	_local_breaker_refinement_info["enabled"] = true
	_local_breaker_refinement_info["active"] = _local_breaker_refinement_region.active
	_local_breaker_refinement_info["breaker_center_world"] = _local_breaker_refinement_region.center_world
	_local_breaker_refinement_info["breaker_travel_direction_world"] = _local_breaker_refinement_region.travel_direction_world
	_local_breaker_refinement_info["breaker_crest_direction_world"] = _local_breaker_refinement_region.crest_direction_world
	_local_breaker_refinement_info["breaker_crest_length_m"] = minf(_local_breaker_refinement_region.crest_length, LOCAL_BREAKER_REFINEMENT_MAX_CREST_LENGTH_M)
	_local_breaker_refinement_info["breaker_front_extent_m"] = _local_breaker_refinement_region.front_extent
	_local_breaker_refinement_info["breaker_rear_extent_m"] = _local_breaker_refinement_region.rear_extent
	_local_breaker_refinement_info["breaker_strength"] = _local_breaker_refinement_region.strength
	_local_breaker_refinement_info["tile_changes_this_frame"] = _count_tile_changes(previous_tiles, high_tiles) if changed else 0
	_local_breaker_refinement_info["high_tiles"] = high_tiles
	_local_breaker_refinement_info["active_front_automatic"] = _local_breaker_refinement_authority.is_empty()


func _request_active_front_refinement_scan(camera_world: Vector2, delta: float) -> void:
	if not _local_breaker_refinement_authority.is_empty() or _breaker_lifecycle_texture == null or not _breaker_lifecycle_texture.texture_rd_rid.is_valid():
		return
	_active_front_refinement_scan_elapsed_s += delta
	if _active_front_refinement_scan_pending or _active_front_refinement_scan_elapsed_s < ACTIVE_FRONT_REFINEMENT_SCAN_INTERVAL_S:
		return
	_active_front_refinement_scan_elapsed_s = 0.0
	_active_front_refinement_scan_pending = true
	var lifecycle_rid := _breaker_lifecycle_texture.texture_rd_rid
	var long_domain := maxf(_base_wave_domains.x, 0.001)
	RenderingServer.call_on_render_thread(_read_active_front_refinement.bind(lifecycle_rid, camera_world, long_domain))


func _read_active_front_refinement(lifecycle_rid: RID, camera_world: Vector2, long_domain: float) -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null or not lifecycle_rid.is_valid():
		call_deferred("_consume_active_front_refinement", PackedByteArray(), camera_world, long_domain)
		return
	var request_error: Error = rd.texture_get_data_async(lifecycle_rid, 0, _on_active_front_refinement_data.bind(camera_world, long_domain))
	if request_error != OK:
		call_deferred("_consume_active_front_refinement", PackedByteArray(), camera_world, long_domain)


func _on_active_front_refinement_data(data: PackedByteArray, camera_world: Vector2, long_domain: float) -> void:
	call_deferred("_consume_active_front_refinement", data, camera_world, long_domain)


func _consume_active_front_refinement(data: PackedByteArray, camera_world: Vector2, long_domain: float) -> void:
	_active_front_refinement_scan_pending = false
	if not _local_breaker_refinement_authority.is_empty() or data.is_empty():
		return
	var resolution := int(round(sqrt(float(data.size()) / 8.0)))
	if resolution <= 0 or resolution * resolution * 8 != data.size():
		return
	var image := Image.create_from_data(resolution, resolution, false, Image.FORMAT_RGBAH, data)
	var tile_size_m := float(_local_breaker_refinement_layout.get("tile_size_ocean_m", 1.0)) * absf(_clipmap_geometry_scale)
	var half_extent := maxf(float(maxi(_local_breaker_refinement_grid_width, _local_breaker_refinement_grid_height)) * tile_size_m * 0.5, tile_size_m)
	var samples: Array[Vector3] = []
	var weighted_center := Vector2.ZERO
	var total_weight := 0.0
	var max_activity := 0.0
	var stride := maxi(resolution / 128, 1)
	for y in range(0, resolution, stride):
		for x in range(0, resolution, stride):
			var activity := clampf(image.get_pixel(x, y).r, 0.0, 1.0)
			if activity < 0.12:
				continue
			var periodic := Vector2((float(x) + 0.5) / float(resolution) - 0.5, (float(y) + 0.5) / float(resolution) - 0.5) * long_domain
			var world := Vector2(_nearest_active_front_periodic(periodic.x, camera_world.x, long_domain), _nearest_active_front_periodic(periodic.y, camera_world.y, long_domain))
			if absf(world.x - camera_world.x) > half_extent or absf(world.y - camera_world.y) > half_extent:
				continue
			samples.append(Vector3(world.x, world.y, activity))
			weighted_center += world * activity
			total_weight += activity
			max_activity = maxf(max_activity, activity)
	if total_weight <= 0.0:
		_active_front_refinement_authority = {"active": false}
		return
	var center := weighted_center / total_weight
	var covariance_xx := 0.0
	var covariance_xy := 0.0
	var covariance_yy := 0.0
	for sample in samples:
		var offset := Vector2(sample.x, sample.y) - center
		covariance_xx += sample.z * offset.x * offset.x
		covariance_xy += sample.z * offset.x * offset.y
		covariance_yy += sample.z * offset.y * offset.y
	covariance_xx /= total_weight
	covariance_xy /= total_weight
	covariance_yy /= total_weight
	var trace := covariance_xx + covariance_yy
	var spread := sqrt(maxf((covariance_xx - covariance_yy) * (covariance_xx - covariance_yy) + 4.0 * covariance_xy * covariance_xy, 0.0))
	var major_variance := maxf((trace + spread) * 0.5, 0.0)
	var minor_variance := maxf((trace - spread) * 0.5, 0.0)
	var crest_direction := Vector2(covariance_xy, major_variance - covariance_xx)
	if crest_direction.length_squared() <= 0.000001:
		crest_direction = Vector2(1.0, 0.0)
	else:
		crest_direction = crest_direction.normalized()
	var crest_length := clampf(maxf(sqrt(major_variance) * 6.0, tile_size_m * 2.0), tile_size_m * 2.0, LOCAL_BREAKER_REFINEMENT_MAX_CREST_LENGTH_M)
	var face_extent := clampf(maxf(sqrt(minor_variance) * 3.0, tile_size_m), tile_size_m, LOCAL_BREAKER_REFINEMENT_MAX_CREST_LENGTH_M * 0.5)
	_active_front_refinement_authority = {
		"active": true,
		"center_world": center,
		"travel_direction_world": Vector2(-crest_direction.y, crest_direction.x),
		"crest_direction_world": crest_direction,
		"crest_length": crest_length,
		"rear_extent": face_extent,
		"front_extent": face_extent,
		"strength": max_activity,
	}


static func _nearest_active_front_periodic(value: float, anchor: float, period: float) -> float:
	return value + roundf((anchor - value) / maxf(period, 0.001)) * period


func _set_local_breaker_refinement_pattern(high_tiles: Array[Vector2i]) -> void:
	if _local_breaker_refinement_batcher == null:
		return
	var high_tile_set := {}
	for tile_coord in high_tiles:
		if tile_coord.x >= 0 and tile_coord.x < _local_breaker_refinement_grid_width and tile_coord.y >= 0 and tile_coord.y < _local_breaker_refinement_grid_height:
			high_tile_set[tile_coord] = true
	var tile_masks := {}
	for tile_y in _local_breaker_refinement_grid_height:
		for tile_x in _local_breaker_refinement_grid_width:
			var coord := Vector2i(tile_x, tile_y)
			if not high_tile_set.has(coord):
				continue
			var mask := 0
			if not high_tile_set.has(Vector2i(tile_x, tile_y + 1)): mask |= 1
			if not high_tile_set.has(Vector2i(tile_x + 1, tile_y)): mask |= 2
			if not high_tile_set.has(Vector2i(tile_x, tile_y - 1)): mask |= 4
			if not high_tile_set.has(Vector2i(tile_x - 1, tile_y)): mask |= 8
			tile_masks[coord] = mask
	var variant_assignments: Array[int] = []
	var coarse_count := 0
	var high_count := 0
	var total_triangles := 0
	var active_masks: Array[int] = []
	var active_mask_set := {}
	var coarse_triangles := _coarse_tile_triangle_count(_local_breaker_refinement_coarse_mesh)
	for index in _local_breaker_refinement_grid_width * _local_breaker_refinement_grid_height:
		var tile_x := index % _local_breaker_refinement_grid_width
		var tile_y := index / _local_breaker_refinement_grid_width
		var coord := Vector2i(tile_x, tile_y)
		if high_tile_set.has(coord):
			var mask: int = int(tile_masks.get(coord, 15))
			variant_assignments.append(mask + 1)
			high_count += 1
			total_triangles += int(_local_breaker_refinement_info["high_variants"][mask]["triangles"])
			active_mask_set[mask] = true
		else:
			variant_assignments.append(0)
			coarse_count += 1
			total_triangles += coarse_triangles
	for mask in active_mask_set.keys(): active_masks.append(int(mask))
	active_masks.sort()
	var batch_info: Dictionary = _local_breaker_refinement_batcher.apply_variant_assignments(variant_assignments)
	_local_breaker_refinement_info["coarse_tile_count"] = coarse_count
	_local_breaker_refinement_info["high_tile_count"] = high_count
	_local_breaker_refinement_info["total_triangles"] = total_triangles
	_local_breaker_refinement_info["production_total_triangles"] = _base_clipmap_triangles - _base_l0_triangles + total_triangles
	_local_breaker_refinement_info["active_high_mask_variants"] = active_masks
	_local_breaker_refinement_info["active_batch_count"] = int(batch_info.get("active_batch_count", 0))
	_local_breaker_refinement_info["batch_node_count"] = int(batch_info.get("batch_node_count", 0))
	_local_breaker_refinement_info["multimesh_count"] = int(batch_info.get("multimesh_count", 0))
	_local_breaker_refinement_info["logical_instance_count"] = int(batch_info.get("logical_instance_count", variant_assignments.size()))
	_local_breaker_refinement_info["instance_transform_updates_this_frame"] = int(batch_info.get("instance_transform_updates_last_transition", 0))
	_local_breaker_refinement_info["arraymesh_rebuilds_runtime"] = _local_breaker_refinement_arraymesh_rebuilds
	_local_breaker_refinement_info["draw_call_count_approx"] = int(batch_info.get("draw_call_count_approx", 0))


func _build_local_breaker_tile_transforms(surface_origin: Vector2) -> Array[Transform3D]:
	var transforms: Array[Transform3D] = []
	var parent_inverse := global_transform.affine_inverse()
	var tile_size_ocean_m: float = float(_local_breaker_refinement_layout.get("tile_size_ocean_m", 1.0))
	for tile_y in _local_breaker_refinement_grid_height:
		for tile_x in _local_breaker_refinement_grid_width:
			var frame_s := (float(tile_x) - float(_local_breaker_refinement_grid_width) * 0.5 + 0.5) * tile_size_ocean_m * _clipmap_geometry_scale
			var frame_v := (float(tile_y) - float(_local_breaker_refinement_grid_height) * 0.5 + 0.5) * tile_size_ocean_m * _clipmap_geometry_scale
			var world_xz := surface_origin + Vector2(frame_v, frame_s)
			var basis := Basis.IDENTITY.scaled(Vector3(_clipmap_geometry_scale, 1.0, _clipmap_geometry_scale))
			transforms.append(parent_inverse * Transform3D(basis, Vector3(world_xz.x, _sea_level, world_xz.y)))
	return transforms


func _update_local_breaker_space_scale() -> void:
	if not _local_breaker_refinement_initialized or _local_breaker_refinement_manager == null:
		return
	var tile_size_ocean_m: float = float(_local_breaker_refinement_layout.get("tile_size_ocean_m", 1.0))
	var coarse_spacing_ocean_m: float = float(_local_breaker_refinement_layout.get("coarse_spacing_ocean_m", 0.001))
	var high_spacing_ocean_m: float = float(_local_breaker_refinement_layout.get("high_spacing_ocean_m", 0.0005))
	var scale: float = absf(_clipmap_geometry_scale)
	_local_breaker_refinement_manager.configure(_surface_world_origin(), Vector2(0.0, 1.0), Vector2(1.0, 0.0), _local_breaker_refinement_grid_width, _local_breaker_refinement_grid_height, tile_size_ocean_m * scale)
	_local_breaker_refinement_tile_transforms = _build_local_breaker_tile_transforms(_surface_world_origin())
	if _local_breaker_refinement_batcher != null:
		_local_breaker_refinement_batcher.update_tile_transforms(_local_breaker_refinement_tile_transforms)
	_local_breaker_refinement_info["tile_size_m"] = tile_size_ocean_m * scale
	_local_breaker_refinement_info["coarse_spacing_m"] = coarse_spacing_ocean_m * scale
	_local_breaker_refinement_info["high_spacing_m"] = high_spacing_ocean_m * scale
	_local_breaker_refinement_info["l0_extent_m"] = float(_local_breaker_refinement_layout.get("l0_extent_ocean_m", 0.0)) * scale


func _surface_world_origin() -> Vector2:
	return Vector2(global_position.x, global_position.z)


func _set_surface_shader_parameter(parameter: Variant, value: Variant) -> void:
	_surface_parameter_state[parameter] = value
	if _material != null:
		_material.set_shader_parameter(parameter, value)


func set_breaker_carrier_suppression(enabled: bool, search_xz: Vector2, crest_length_m: float, event_seed_sample_xz: Vector2 = Vector2.ZERO) -> void:
	## H5.2C render-only validation mask. The base ocean computes the same
	## Coastal crest snap as the carrier shader and discards only its interior.
	_set_surface_shader_parameter(&"breaker_carrier_suppression_enabled", enabled)
	_set_surface_shader_parameter(&"breaker_carrier_search_xz", search_xz)
	_set_surface_shader_parameter(&"breaker_carrier_event_seed_sample_xz", event_seed_sample_xz)
	_set_surface_shader_parameter(&"breaker_carrier_crest_length_m", maxf(crest_length_m, 0.001))


func _set_breaker_probe_gains(horizontal_gain: float, vertical_gain: float) -> void:
	_set_surface_shader_parameter(&"breaker_probe_horizontal_gain", clampf(horizontal_gain, 0.0, 10.0))
	_set_surface_shader_parameter(&"breaker_probe_vertical_gain", clampf(vertical_gain, 0.0, 10.0))


func _set_breaker_vdm_validation_phase(phase: float) -> void:
	_set_surface_shader_parameter(&"breaker_vdm_validation_phase", clampf(phase, -1.0, 7.0))


func _hydrate_material(material: ShaderMaterial) -> void:
	if material == null:
		return
	for parameter in _surface_parameter_state.keys():
		material.set_shader_parameter(parameter, _surface_parameter_state[parameter])


func _assign_material_to_surface_geometry(material: Material) -> void:
	for level in _levels:
		if is_instance_valid(level):
			level.material_override = material
	if _local_breaker_refinement_batcher != null:
		_local_breaker_refinement_batcher.set_material(material)
	for diagnostic in _breaker_shape_lab_topology_meshes:
		if is_instance_valid(diagnostic):
			diagnostic.material_override = material
	if is_instance_valid(_breaker_shape_lab_refinement_instance):
		_breaker_shape_lab_refinement_instance.material_override = material
	if _breaker_shape_lab_tiled_batcher != null:
		_breaker_shape_lab_tiled_batcher.set_material(material)


func enable_breaker_shape_lab(vdm: Texture2D, origin: Vector2, propagation: Vector2, reference_direction: Vector2, wavefront_width_m: float, length_m: float, flatten_strength: float, debug_mode: int) -> bool:
	if vdm == null:
		return false
	var propagation_safe := propagation.normalized()
	if propagation_safe.length_squared() < 0.000001:
		propagation_safe = Vector2(0.0, 1.0)
	_breaker_shape_lab_shader = Shader.new()
	_breaker_shape_lab_shader.code = _build_shader_source(false, false, false, false, true)
	_breaker_shape_lab_material = ShaderMaterial.new()
	_breaker_shape_lab_material.shader = _breaker_shape_lab_shader
	_material = _breaker_shape_lab_material
	_hydrate_material(_material)
	_active_shader_variant_key = "lab:breaker_shape"
	_breaker_shape_lab_active = true
	_breaker_shape_lab_origin = origin
	_breaker_shape_lab_propagation = propagation_safe
	_breaker_shape_lab_reference_direction = reference_direction.normalized()
	if _breaker_shape_lab_reference_direction.length_squared() < 0.000001:
		_breaker_shape_lab_reference_direction = Vector2(1.0, 0.0)
	_breaker_shape_lab_wavefront_width_m = maxf(wavefront_width_m, 0.001)
	_breaker_shape_lab_length_m = maxf(length_m, 0.001)
	_breaker_shape_lab_debug_mode = debug_mode
	_breaker_shape_lab_phase_override = -1.0
	_breaker_shape_lab_multiphase = false
	_set_surface_shader_parameter(&"breaker_shape_vdm", vdm)
	_set_surface_shader_parameter(&"breaker_shape_origin", origin)
	_set_surface_shader_parameter(&"breaker_shape_propagation", propagation_safe)
	var reference_direction_safe := reference_direction.normalized()
	if reference_direction_safe.length_squared() < 0.000001:
		reference_direction_safe = Vector2(0.0, 1.0)
	_set_surface_shader_parameter(&"breaker_shape_reference_direction", reference_direction_safe)
	_set_surface_shader_parameter(&"breaker_shape_wavefront_width_m", maxf(wavefront_width_m, 0.001))
	_set_surface_shader_parameter(&"breaker_shape_length_m", maxf(length_m, 0.001))
	_set_surface_shader_parameter(&"breaker_shape_flatten_strength", clampf(flatten_strength, 0.0, 1.0))
	var shader_debug_mode := 4 if debug_mode == 5 else clampi(debug_mode, 1, 4)
	_set_surface_shader_parameter(&"breaker_shape_debug_mode", shader_debug_mode)
	_set_surface_shader_parameter(&"breaker_shape_phase_override", -1.0)
	_assign_material_to_surface_geometry(_material)
	return true


func set_breaker_shape_lab_mode(debug_mode: int) -> void:
	if not _breaker_shape_lab_active:
		return
	_breaker_shape_lab_debug_mode = debug_mode
	var shader_debug_mode := 4 if debug_mode == 5 else clampi(debug_mode, 1, 4)
	_set_surface_shader_parameter(&"breaker_shape_debug_mode", shader_debug_mode)


func configure_breaker_shape_lab_waterline(waterline_temp: bool, shore_distance_texture: Texture2D, animation_enabled: bool, horizontal_sign: float, scales: Vector3) -> void:
	if not _breaker_shape_lab_active:
		return
	_breaker_shape_lab_animation_enabled = animation_enabled
	_breaker_shape_lab_multiphase = false
	_set_surface_shader_parameter(&"breaker_shape_waterline_temp", waterline_temp)
	_set_surface_shader_parameter(&"breaker_shape_multiphase_vdm", false)
	_set_surface_shader_parameter(&"breaker_shape_shore_distance_tex", shore_distance_texture)
	_set_surface_shader_parameter(&"breaker_shape_animation_enabled", animation_enabled)
	_set_surface_shader_parameter(&"breaker_shape_horizontal_sign", horizontal_sign)
	_set_surface_shader_parameter(&"breaker_shape_waterline_propagation_scale", scales.x)
	_set_surface_shader_parameter(&"breaker_shape_waterline_vertical_scale", scales.z)


func configure_breaker_shape_lab_multiphase(shore_distance_texture: Texture2D, animation_enabled: bool) -> void:
	if not _breaker_shape_lab_active:
		return
	_breaker_shape_lab_animation_enabled = animation_enabled
	_breaker_shape_lab_multiphase = true
	_set_surface_shader_parameter(&"breaker_shape_waterline_temp", false)
	_set_surface_shader_parameter(&"breaker_shape_multiphase_vdm", true)
	_set_surface_shader_parameter(&"breaker_shape_shore_distance_tex", shore_distance_texture)
	_set_surface_shader_parameter(&"breaker_shape_shore_distance_near_m", 0.0)
	_set_surface_shader_parameter(&"breaker_shape_shore_distance_far_m", 12.0)
	_set_surface_shader_parameter(&"breaker_shape_animation_enabled", animation_enabled)


func set_breaker_shape_lab_phase_override(phase_index: int) -> void:
	if not _breaker_shape_lab_active:
		return
	_breaker_shape_lab_phase_override = float(clampi(phase_index, 0, 7))
	_set_surface_shader_parameter(&"breaker_shape_phase_override", float(clampi(phase_index, 0, 7)))


func clear_breaker_shape_lab_phase_override() -> void:
	if not _breaker_shape_lab_active:
		return
	_breaker_shape_lab_phase_override = -1.0
	_set_surface_shader_parameter(&"breaker_shape_phase_override", -1.0)


func disable_breaker_shape_lab() -> void:
	if not _breaker_shape_lab_active:
		return
	_breaker_shape_lab_active = false
	_breaker_shape_lab_auto_active = false
	_breaker_shape_lab_refinement_manager = null
	_breaker_shape_lab_refinement_region = null
	_breaker_shape_lab_auto_last_tiles.clear()
	_breaker_shape_lab_auto_initialized = false
	_breaker_shape_lab_auto_front_extent_m = 5.0
	_breaker_shape_lab_auto_rear_extent_m = 2.0
	for parameter in [&"breaker_shape_vdm", &"breaker_shape_origin", &"breaker_shape_propagation", &"breaker_shape_reference_direction", &"breaker_shape_wavefront_width_m", &"breaker_shape_length_m", &"breaker_shape_flatten_strength", &"breaker_shape_debug_mode", &"breaker_shape_phase_override"]:
		_surface_parameter_state.erase(parameter)
	_breaker_shape_lab_shader = null
	_breaker_shape_lab_material = null
	_active_shader_variant_key = ""
	_clear_breaker_shape_lab_topology_diagnostic()
	_clear_breaker_shape_lab_refinement_diagnostic()
	_clear_breaker_shape_lab_tiled_diagnostic()
	_apply_shader_variant()


func configure_breaker_shape_lab_topology_diagnostic(origin: Vector2, reference_direction: Vector2, wavefront_width_m: float, profile_domain_m := 12.0) -> Dictionary:
	_clear_breaker_shape_lab_topology_diagnostic()
	if _quality == null or get_parent() == null:
		return {}
	var production_spacing := maxf(float(_quality.get("base_spacing_m")), 0.001)
	var safe_direction := reference_direction.normalized()
	if safe_direction.length_squared() < 0.000001:
		safe_direction = Vector2(0.0, 1.0)
	var parent := get_parent()
	var production_vertices := 0
	var production_triangles := 0
	var production_cells_per_side := maxi(int(_quality.get("cells_per_side")), 2)
	var production_level_extents := []
	for level in _levels:
		production_level_extents.append(float(production_cells_per_side) * production_spacing * pow(2.0, _levels.find(level)))
		if not is_instance_valid(level) or not level.mesh is ArrayMesh:
			continue
		var production_arrays := (level.mesh as ArrayMesh).surface_get_arrays(0)
		var production_level_vertices: PackedVector3Array = production_arrays[Mesh.ARRAY_VERTEX]
		var production_level_indices: PackedInt32Array = production_arrays[Mesh.ARRAY_INDEX]
		production_vertices += production_level_vertices.size()
		production_triangles += production_level_indices.size() / 3
	var density_modes := [1, 2, 4]
	var topology_entries := []
	for topology_index in density_modes.size():
		var density_multiplier: int = density_modes[topology_index]
		var spacing := production_spacing / float(density_multiplier)
		var mesh := MeshBuilder.build_aligned_grid(profile_domain_m, wavefront_width_m, spacing, safe_direction)
		var instance := MeshInstance3D.new()
		instance.name = "BreakerShapeLabTopologyT%d" % (topology_index + 1)
		instance.mesh = mesh
		instance.material_override = _material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		instance.extra_cull_margin = CLIPMAP_EXTRA_CULL_MARGIN_M
		parent.add_child(instance)
		instance.global_position = Vector3(origin.x, _sea_level, origin.y)
		instance.visible = false
		_breaker_shape_lab_topology_meshes.append(instance)
		_update_breaker_shape_lab_culling_bounds(_get_gpu_culling_displacement_world())
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		topology_entries.append({
			"spacing_m": spacing,
			"s_extent_m": profile_domain_m,
			"v_extent_m": wavefront_width_m,
			"s_cells": roundi(maxf(profile_domain_m, spacing) / spacing),
			"v_cells": roundi(maxf(wavefront_width_m, spacing) / spacing),
			"vertices": vertices.size(),
			"triangles": indices.size() / 3,
			"material_id": _material.get_instance_id(),
		})
	_breaker_shape_lab_topology_info = {
		"production_l0_spacing_m": production_spacing,
		"t0": {
			"spacing_m": production_spacing,
			"cells_per_side": production_cells_per_side,
			"level_extents_m": production_level_extents,
			"vertices": production_vertices,
			"triangles": production_triangles,
		},
		"t1": topology_entries[0],
		"t2": topology_entries[1],
		"t3": topology_entries[2],
		"origin": origin,
		"reference_direction": safe_direction,
		"reference_tangent": Vector2(-safe_direction.y, safe_direction.x),
		"profile_domain_m": profile_domain_m,
		"wavefront_width_m": wavefront_width_m,
	}
	set_breaker_shape_lab_topology_mode(0)
	return _breaker_shape_lab_topology_info


func set_breaker_shape_lab_topology_mode(mode: int) -> Dictionary:
	_breaker_shape_lab_topology_mode = clampi(mode, 0, 3)
	_breaker_shape_lab_refinement_active = false
	_breaker_shape_lab_tiled_active = false
	if is_instance_valid(_breaker_shape_lab_refinement_instance):
		_breaker_shape_lab_refinement_instance.visible = false
	if _breaker_shape_lab_tiled_batcher != null:
		_breaker_shape_lab_tiled_batcher.hide()
	for level in _levels:
		if is_instance_valid(level):
			level.visible = _breaker_shape_lab_topology_mode == 0
	for index in _breaker_shape_lab_topology_meshes.size():
		var diagnostic := _breaker_shape_lab_topology_meshes[index]
		if is_instance_valid(diagnostic):
			diagnostic.visible = _breaker_shape_lab_topology_mode == index + 1
	return _breaker_shape_lab_topology_info


func configure_breaker_shape_lab_refinement_diagnostic(origin: Vector2, reference_direction: Vector2, outer_s_extent_m := 20.0, outer_v_extent_m := 16.0, core_s_extent_m := 12.0, core_v_extent_m := 5.0, outer_spacing := 0.25, core_spacing := 0.125) -> Dictionary:
	_clear_breaker_shape_lab_refinement_diagnostic()
	if _quality == null or get_parent() == null:
		return {}
	var safe_direction := reference_direction.normalized()
	if safe_direction.length_squared() < 0.000001:
		safe_direction = Vector2(0.0, 1.0)
	var r0_mesh := MeshBuilder.build_aligned_grid(outer_s_extent_m, outer_v_extent_m, outer_spacing, safe_direction)
	var r1_build: Dictionary = MeshBuilder.build_static_local_refinement_tile(outer_s_extent_m, outer_v_extent_m, core_s_extent_m, core_v_extent_m, outer_spacing, core_spacing, safe_direction)
	var r1_mesh: ArrayMesh = r1_build["mesh"]
	_breaker_shape_lab_refinement_meshes = [r0_mesh, r1_mesh]
	var parent := get_parent()
	_breaker_shape_lab_refinement_instance = MeshInstance3D.new()
	_breaker_shape_lab_refinement_instance.name = "BreakerShapeLabStaticLocalRefinementTile"
	_breaker_shape_lab_refinement_instance.mesh = r0_mesh
	_breaker_shape_lab_refinement_instance.material_override = _material
	_breaker_shape_lab_refinement_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_breaker_shape_lab_refinement_instance.extra_cull_margin = CLIPMAP_EXTRA_CULL_MARGIN_M
	parent.add_child(_breaker_shape_lab_refinement_instance)
	_breaker_shape_lab_refinement_instance.global_position = Vector3(origin.x, _sea_level, origin.y)
	_breaker_shape_lab_refinement_instance.visible = false
	_update_breaker_shape_lab_culling_bounds(_get_gpu_culling_displacement_world())
	var r0_info := _mesh_topology_info(r0_mesh)
	r0_info["outer_triangles"] = r0_info["triangles"]
	r0_info["core_triangles"] = 0
	r0_info["stitch_triangles"] = 0
	r0_info["outer_s_cells"] = roundi(maxf(outer_s_extent_m, outer_spacing) / outer_spacing)
	r0_info["outer_v_cells"] = roundi(maxf(outer_v_extent_m, outer_spacing) / outer_spacing)
	var r1_info: Dictionary = r1_build.duplicate(true)
	r1_info.erase("mesh")
	r1_info["outer_s_extent_m"] = outer_s_extent_m
	r1_info["outer_v_extent_m"] = outer_v_extent_m
	r1_info["core_s_extent_m"] = core_s_extent_m
	r1_info["core_v_extent_m"] = core_v_extent_m
	r1_info["outer_spacing_m"] = outer_spacing
	r1_info["core_spacing_m"] = core_spacing
	r1_info["material_id"] = _material.get_instance_id()
	r0_info["outer_s_extent_m"] = outer_s_extent_m
	r0_info["outer_v_extent_m"] = outer_v_extent_m
	r0_info["core_s_extent_m"] = core_s_extent_m
	r0_info["core_v_extent_m"] = core_v_extent_m
	r0_info["outer_spacing_m"] = outer_spacing
	r0_info["core_spacing_m"] = outer_spacing
	r0_info["material_id"] = _material.get_instance_id()
	_breaker_shape_lab_refinement_info = {
		"r0": r0_info,
		"r1": r1_info,
		"origin": origin,
		"reference_direction": safe_direction,
		"reference_tangent": Vector2(-safe_direction.y, safe_direction.x),
		"mesh_count": 1,
		"surface_count": 1,
		"no_overlapping_surface": true,
	}
	_breaker_shape_lab_refinement_mode = -1
	_breaker_shape_lab_refinement_active = false
	return _breaker_shape_lab_refinement_info


func configure_breaker_shape_lab_tiled_refinement_diagnostic(origin: Vector2, reference_direction: Vector2, grid_width := 5, grid_height := 4, tile_size_m := 4.0, coarse_spacing := 0.25, high_spacing := 0.125) -> Dictionary:
	_clear_breaker_shape_lab_tiled_diagnostic()
	if _quality == null or not get_parent() is Node3D:
		return {}
	var safe_direction := reference_direction.normalized()
	if safe_direction.length_squared() < 0.000001:
		safe_direction = Vector2(0.0, 1.0)
	_breaker_shape_lab_tiled_grid_width = maxi(grid_width, 1)
	_breaker_shape_lab_tiled_grid_height = maxi(grid_height, 1)
	var parent := get_parent() as Node3D
	_breaker_shape_lab_tiled_coarse_mesh = MeshBuilder.build_aligned_grid(tile_size_m, tile_size_m, coarse_spacing, safe_direction)
	_breaker_shape_lab_tiled_coarse_triangles = _coarse_tile_triangle_count(_breaker_shape_lab_tiled_coarse_mesh)
	var coarse_edge_summary := _mesh_edge_topology_summary(_breaker_shape_lab_tiled_coarse_mesh)
	_breaker_shape_lab_tiled_high_meshes.clear()
	var high_variant_info := []
	for edge_mask in 16:
		var variant: Dictionary = MeshBuilder.build_tiled_high_variant(tile_size_m, high_spacing, coarse_spacing, edge_mask, safe_direction)
		var mesh: ArrayMesh = variant["mesh"]
		_breaker_shape_lab_tiled_high_meshes.append(mesh)
		variant.erase("mesh")
		high_variant_info.append(variant)
	var tile_transforms: Array[Transform3D] = []
	var parent_inverse := parent.global_transform.affine_inverse()
	for tile_y in _breaker_shape_lab_tiled_grid_height:
		for tile_x in _breaker_shape_lab_tiled_grid_width:
			var frame_s := (float(tile_x) - float(_breaker_shape_lab_tiled_grid_width) * 0.5 + 0.5) * tile_size_m
			var frame_v := (float(tile_y) - float(_breaker_shape_lab_tiled_grid_height) * 0.5 + 0.5) * tile_size_m
			var world_position := Vector3(origin.x + safe_direction.x * frame_s + (-safe_direction.y) * frame_v, _sea_level, origin.y + safe_direction.y * frame_s + safe_direction.x * frame_v)
			tile_transforms.append(parent_inverse * Transform3D(Basis.IDENTITY, world_position))
	var variant_meshes: Array[ArrayMesh] = []
	variant_meshes.append(_breaker_shape_lab_tiled_coarse_mesh)
	variant_meshes.append_array(_breaker_shape_lab_tiled_high_meshes)
	_breaker_shape_lab_tiled_batcher = RefinementBatcher.new()
	_breaker_shape_lab_tiled_batcher.configure(parent, _material, variant_meshes, tile_transforms)
	_update_breaker_shape_lab_culling_bounds(_get_gpu_culling_displacement_world())
	_breaker_shape_lab_tiled_meshes_generated_since_startup = 1 + _breaker_shape_lab_tiled_high_meshes.size()
	_breaker_shape_lab_tiled_meshes_generated_this_frame = 0
	_breaker_shape_lab_tiled_arraymesh_rebuilds_this_frame = 0
	_breaker_shape_lab_tiled_mesh_assignments_last_transition = 0
	_breaker_shape_lab_tiled_max_mesh_assignments = 0
	_breaker_shape_lab_tiled_pattern = ""
	_breaker_shape_lab_tiled_info = {
		"grid_width": _breaker_shape_lab_tiled_grid_width,
		"grid_height": _breaker_shape_lab_tiled_grid_height,
		"tile_size_m": tile_size_m,
		"coarse_spacing_m": coarse_spacing,
		"high_spacing_m": high_spacing,
		"prebuilt_mesh_count": _breaker_shape_lab_tiled_meshes_generated_since_startup,
		"high_variant_count": _breaker_shape_lab_tiled_high_meshes.size(),
		"high_variants": high_variant_info,
		"coarse_edge_summary": coarse_edge_summary,
		"batch_node_count": _breaker_shape_lab_tiled_batcher.get_batch_node_count(),
		"multimesh_count": _breaker_shape_lab_tiled_batcher.get_batch_node_count(),
		"logical_instance_count": tile_transforms.size(),
		"active_batch_count": 0,
		"surface_count": 0,
		"draw_call_count_approx": 0,
		"instance_transform_updates_last_transition": 0,
		"all_variants_manifold": bool(coarse_edge_summary.get("is_manifold", false)) and _all_tiled_variants_manifold(high_variant_info),
		"no_overlapping_surface": true,
	}
	return _breaker_shape_lab_tiled_info


func configure_breaker_shape_lab_auto_refinement(front_extent_m := 5.0, rear_extent_m := 2.0) -> Dictionary:
	if _breaker_shape_lab_tiled_batcher == null:
		return {}
	var grid_s := _breaker_shape_lab_reference_direction
	var grid_v := Vector2(-grid_s.y, grid_s.x)
	_breaker_shape_lab_refinement_manager = RefinementManager.new()
	_breaker_shape_lab_refinement_manager.configure(_breaker_shape_lab_origin, grid_s, grid_v, _breaker_shape_lab_tiled_grid_width, _breaker_shape_lab_tiled_grid_height, 4.0)
	_breaker_shape_lab_refinement_region = BreakerRefinementRegion.new()
	_breaker_shape_lab_auto_front_extent_m = maxf(front_extent_m, 0.0)
	_breaker_shape_lab_auto_rear_extent_m = maxf(rear_extent_m, 0.0)
	_breaker_shape_lab_auto_last_tiles.clear()
	_breaker_shape_lab_auto_initialized = false
	_breaker_shape_lab_auto_tile_changes_this_frame = 0
	_breaker_shape_lab_auto_active = false
	return {
		"mode": "AUTO BREAKER",
		"front_extent_m": _breaker_shape_lab_auto_front_extent_m,
		"rear_extent_m": _breaker_shape_lab_auto_rear_extent_m,
		"grid_width": _breaker_shape_lab_tiled_grid_width,
		"grid_height": _breaker_shape_lab_tiled_grid_height,
	}


func update_breaker_shape_lab_auto_refinement() -> Dictionary:
	if _breaker_shape_lab_refinement_manager == null or _breaker_shape_lab_refinement_region == null:
		return _breaker_shape_lab_tiled_info
	var authority := get_breaker_shape_lab_authority()
	_breaker_shape_lab_refinement_region.update_from_authority(authority)
	var high_tiles: Array[Vector2i] = _breaker_shape_lab_refinement_manager.select_high_tiles(_breaker_shape_lab_refinement_region)
	var changed := not _breaker_shape_lab_auto_initialized or high_tiles != _breaker_shape_lab_auto_last_tiles
	_breaker_shape_lab_auto_tile_changes_this_frame = 0
	if changed:
		var previous_tiles := _breaker_shape_lab_auto_last_tiles.duplicate()
		_breaker_shape_lab_auto_last_tiles = high_tiles.duplicate()
		_breaker_shape_lab_auto_initialized = true
		_breaker_shape_lab_auto_tile_changes_this_frame = _count_tile_changes(previous_tiles, high_tiles)
		set_breaker_shape_lab_tiled_pattern("AUTO BREAKER", high_tiles)
	_breaker_shape_lab_auto_active = _breaker_shape_lab_refinement_region.active
	_breaker_shape_lab_tiled_info["refinement_mode"] = "AUTO BREAKER"
	_breaker_shape_lab_tiled_info["breaker_active"] = _breaker_shape_lab_refinement_region.active
	_breaker_shape_lab_tiled_info["breaker_center_world"] = _breaker_shape_lab_refinement_region.center_world
	_breaker_shape_lab_tiled_info["breaker_travel_direction_world"] = _breaker_shape_lab_refinement_region.travel_direction_world
	_breaker_shape_lab_tiled_info["breaker_crest_direction_world"] = _breaker_shape_lab_refinement_region.crest_direction_world
	_breaker_shape_lab_tiled_info["breaker_crest_length_m"] = _breaker_shape_lab_refinement_region.crest_length
	_breaker_shape_lab_tiled_info["breaker_front_extent_m"] = _breaker_shape_lab_refinement_region.front_extent
	_breaker_shape_lab_tiled_info["breaker_rear_extent_m"] = _breaker_shape_lab_refinement_region.rear_extent
	_breaker_shape_lab_tiled_info["breaker_strength"] = _breaker_shape_lab_refinement_region.strength
	_breaker_shape_lab_tiled_info["tile_changes_this_frame"] = _breaker_shape_lab_auto_tile_changes_this_frame
	_breaker_shape_lab_tiled_info["instance_transform_updates_this_frame"] = _breaker_shape_lab_tiled_transform_updates_last_transition if changed else 0
	_breaker_shape_lab_tiled_info["auto_high_tiles"] = high_tiles
	return _breaker_shape_lab_tiled_info


func get_breaker_shape_lab_authority() -> Dictionary:
	# This is a CPU projection of the existing P5 shader authority for tile
	# selection; it does not introduce a second deformation/shape authority.
	var phase := 0.5
	if _breaker_shape_lab_phase_override >= 0.0:
		phase = clampf(_breaker_shape_lab_phase_override / 7.0, 0.0, 1.0)
	elif _breaker_shape_lab_animation_enabled:
		phase = fposmod(Time.get_ticks_msec() / 1000.0, 4.0) / 4.0
	var lifecycle := smoothstep(0.0, 0.15, phase) * (1.0 - smoothstep(0.80, 1.0, phase))
	if _breaker_shape_lab_phase_override >= 0.0:
		lifecycle = 1.0
	var active := _breaker_shape_lab_active and _breaker_shape_lab_multiphase and _breaker_shape_lab_debug_mode >= 3 and lifecycle > 0.02
	var travel := _breaker_shape_lab_propagation.normalized()
	var crest := Vector2(-travel.y, travel.x)
	var center := _breaker_shape_lab_origin + _breaker_shape_lab_reference_direction * (phase * _breaker_shape_lab_travel_m)
	return {
		"active": active,
		"center_world": center,
		"travel_direction_world": travel,
		"crest_direction_world": crest,
		# The LAB frame is 16 m across; keep the initial footprint local while
		# consuming the real P5 wavefront width as its source authority.
		"crest_length": minf(_breaker_shape_lab_wavefront_width_m, 12.0),
		"rear_extent": _breaker_shape_lab_auto_rear_extent_m,
		"front_extent": _breaker_shape_lab_auto_front_extent_m,
		"strength": lifecycle,
		"phase": phase,
		"lifecycle": lifecycle,
	}


func get_breaker_shape_lab_auto_info() -> Dictionary:
	return _breaker_shape_lab_tiled_info


func _count_tile_changes(previous: Array, current: Array) -> int:
	var previous_set := {}
	for tile in previous: previous_set[tile] = true
	var current_set := {}
	for tile in current: current_set[tile] = true
	var changed := 0
	for tile in previous_set.keys():
		if not current_set.has(tile): changed += 1
	for tile in current_set.keys():
		if not previous_set.has(tile): changed += 1
	return changed


func set_breaker_shape_lab_tiled_pattern(pattern_name: String, high_tiles: Array[Vector2i]) -> Dictionary:
	# Runtime switching is assignment-only: topology and every ArrayMesh are prebuilt above.
	if _breaker_shape_lab_tiled_batcher == null or _breaker_shape_lab_tiled_high_meshes.size() != 16 or _breaker_shape_lab_tiled_coarse_mesh == null:
		return _breaker_shape_lab_tiled_info
	var high_tile_set := {}
	for tile_coord in high_tiles:
		if tile_coord.x >= 0 and tile_coord.x < _breaker_shape_lab_tiled_grid_width and tile_coord.y >= 0 and tile_coord.y < _breaker_shape_lab_tiled_grid_height:
			high_tile_set[tile_coord] = true
	var tile_masks := {}
	for tile_y in _breaker_shape_lab_tiled_grid_height:
		for tile_x in _breaker_shape_lab_tiled_grid_width:
			var coord := Vector2i(tile_x, tile_y)
			if not high_tile_set.has(coord):
				continue
			var mask := 0
			if not high_tile_set.has(Vector2i(tile_x, tile_y + 1)): mask |= 1
			if not high_tile_set.has(Vector2i(tile_x + 1, tile_y)): mask |= 2
			if not high_tile_set.has(Vector2i(tile_x, tile_y - 1)): mask |= 4
			if not high_tile_set.has(Vector2i(tile_x - 1, tile_y)): mask |= 8
			tile_masks[coord] = mask
	var total_triangles := 0
	var coarse_count := 0
	var high_count := 0
	var active_masks := {}
	var variant_assignments: Array[int] = []
	for index in _breaker_shape_lab_tiled_grid_width * _breaker_shape_lab_tiled_grid_height:
		var tile_x := index % _breaker_shape_lab_tiled_grid_width
		var tile_y := index / _breaker_shape_lab_tiled_grid_width
		var coord := Vector2i(tile_x, tile_y)
		var variant_index := 0
		if high_tile_set.has(coord):
			var mask: int = int(tile_masks.get(coord, 15))
			variant_index = mask + 1
			active_masks[mask] = int(active_masks.get(mask, 0)) + 1
			high_count += 1
			total_triangles += int(_breaker_shape_lab_tiled_info["high_variants"][mask]["triangles"])
		else:
			coarse_count += 1
			total_triangles += _breaker_shape_lab_tiled_coarse_triangles
		variant_assignments.append(variant_index)
	var batch_info: Dictionary = _breaker_shape_lab_tiled_batcher.apply_variant_assignments(variant_assignments)
	_hide_non_tiled_lab_geometry()
	_breaker_shape_lab_tiled_active = true
	_breaker_shape_lab_tiled_pattern = pattern_name
	_breaker_shape_lab_tiled_mesh_assignments_last_transition = int(batch_info.get("mesh_assignments_last_transition", 0))
	_breaker_shape_lab_tiled_max_mesh_assignments = maxi(_breaker_shape_lab_tiled_max_mesh_assignments, _breaker_shape_lab_tiled_mesh_assignments_last_transition)
	_breaker_shape_lab_tiled_transform_updates_last_transition = int(batch_info.get("instance_transform_updates_last_transition", 0))
	_breaker_shape_lab_tiled_meshes_generated_this_frame = 0
	_breaker_shape_lab_tiled_arraymesh_rebuilds_this_frame = 0
	var active_mask_list: Array[int] = []
	for mask_key in active_masks.keys():
		active_mask_list.append(int(mask_key))
	active_mask_list.sort()
	_breaker_shape_lab_tiled_info["pattern"] = pattern_name
	_breaker_shape_lab_tiled_info["logical_tile_count"] = variant_assignments.size()
	_breaker_shape_lab_tiled_info["coarse_tile_count"] = coarse_count
	_breaker_shape_lab_tiled_info["high_tile_count"] = high_count
	_breaker_shape_lab_tiled_info["total_triangles"] = total_triangles
	_breaker_shape_lab_tiled_info["active_high_mask_variants"] = active_mask_list
	_breaker_shape_lab_tiled_info["mesh_assignments_last_transition"] = _breaker_shape_lab_tiled_mesh_assignments_last_transition
	_breaker_shape_lab_tiled_info["max_mesh_assignments"] = _breaker_shape_lab_tiled_max_mesh_assignments
	_breaker_shape_lab_tiled_info["instance_transform_updates_last_transition"] = _breaker_shape_lab_tiled_transform_updates_last_transition
	_breaker_shape_lab_tiled_info["instance_transform_updates_this_frame"] = _breaker_shape_lab_tiled_transform_updates_last_transition
	_breaker_shape_lab_tiled_info["active_batch_count"] = int(batch_info.get("active_batch_count", 0))
	_breaker_shape_lab_tiled_info["batch_node_count"] = int(batch_info.get("batch_node_count", 0))
	_breaker_shape_lab_tiled_info["multimesh_count"] = int(batch_info.get("multimesh_count", 0))
	_breaker_shape_lab_tiled_info["logical_instance_count"] = int(batch_info.get("logical_instance_count", variant_assignments.size()))
	_breaker_shape_lab_tiled_info["active_batch_variants"] = batch_info.get("active_batch_variants", [])
	_breaker_shape_lab_tiled_info["meshes_generated_since_startup"] = _breaker_shape_lab_tiled_meshes_generated_since_startup
	_breaker_shape_lab_tiled_info["meshes_generated_this_frame"] = _breaker_shape_lab_tiled_meshes_generated_this_frame
	_breaker_shape_lab_tiled_info["arraymesh_rebuilds_this_frame"] = _breaker_shape_lab_tiled_arraymesh_rebuilds_this_frame
	_breaker_shape_lab_tiled_info["surface_count"] = int(batch_info.get("active_surface_count", 0))
	_breaker_shape_lab_tiled_info["draw_call_count_approx"] = int(batch_info.get("draw_call_count_approx", 0))
	return _breaker_shape_lab_tiled_info


func get_breaker_shape_lab_tiled_info() -> Dictionary:
	return _breaker_shape_lab_tiled_info


func _coarse_tile_triangle_count(mesh: ArrayMesh) -> int:
	var arrays := mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	return indices.size() / 3


func _mesh_triangle_count(mesh: ArrayMesh) -> int:
	if mesh == null or mesh.get_surface_count() == 0:
		return 0
	var arrays := mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	return indices.size() / 3


func _mesh_edge_topology_summary(mesh: ArrayMesh) -> Dictionary:
	if mesh == null or mesh.get_surface_count() == 0:
		return {"boundary_edges": 0, "interior_edges": 0, "non_manifold_edges": 0, "is_manifold": false}
	var arrays := mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var edge_counts := {}
	for index in range(0, indices.size(), 3):
		var a: int = indices[index]
		var b: int = indices[index + 1]
		var c: int = indices[index + 2]
		_count_mesh_edge(edge_counts, a, b)
		_count_mesh_edge(edge_counts, b, c)
		_count_mesh_edge(edge_counts, c, a)
	var boundary_edges := 0
	var interior_edges := 0
	var non_manifold_edges := 0
	for count in edge_counts.values():
		if count == 1:
			boundary_edges += 1
		elif count == 2:
			interior_edges += 1
		else:
			non_manifold_edges += 1
	return {
		"boundary_edges": boundary_edges,
		"interior_edges": interior_edges,
		"non_manifold_edges": non_manifold_edges,
		"is_manifold": non_manifold_edges == 0,
	}


func _count_mesh_edge(edge_counts: Dictionary, a: int, b: int) -> void:
	var edge := Vector2i(mini(a, b), maxi(a, b))
	edge_counts[edge] = int(edge_counts.get(edge, 0)) + 1


func _all_tiled_variants_manifold(variants: Array) -> bool:
	for variant in variants:
		if not bool(variant.get("edge_summary", {}).get("is_manifold", false)):
			return false
	return true


func _hide_non_tiled_lab_geometry() -> void:
	for level in _levels:
		if is_instance_valid(level): level.visible = false
	for diagnostic in _breaker_shape_lab_topology_meshes:
		if is_instance_valid(diagnostic): diagnostic.visible = false
	if is_instance_valid(_breaker_shape_lab_refinement_instance):
		_breaker_shape_lab_refinement_instance.visible = false


func _clear_breaker_shape_lab_tiled_diagnostic() -> void:
	if _breaker_shape_lab_tiled_batcher != null:
		_breaker_shape_lab_tiled_batcher.clear()
	_breaker_shape_lab_tiled_batcher = null
	_breaker_shape_lab_tiled_coarse_mesh = null
	_breaker_shape_lab_tiled_coarse_triangles = 0
	_breaker_shape_lab_tiled_high_meshes.clear()
	_breaker_shape_lab_tiled_info = {}
	_breaker_shape_lab_tiled_pattern = ""
	_breaker_shape_lab_tiled_active = false
	_breaker_shape_lab_tiled_grid_width = 0
	_breaker_shape_lab_tiled_grid_height = 0
	_breaker_shape_lab_tiled_meshes_generated_since_startup = 0
	_breaker_shape_lab_tiled_meshes_generated_this_frame = 0
	_breaker_shape_lab_tiled_arraymesh_rebuilds_this_frame = 0
	_breaker_shape_lab_tiled_mesh_assignments_last_transition = 0
	_breaker_shape_lab_tiled_max_mesh_assignments = 0
	_breaker_shape_lab_tiled_transform_updates_last_transition = 0


func set_breaker_shape_lab_refinement_mode(mode: int) -> Dictionary:
	if not is_instance_valid(_breaker_shape_lab_refinement_instance) or _breaker_shape_lab_refinement_meshes.size() != 2:
		return _breaker_shape_lab_refinement_info
	_breaker_shape_lab_refinement_mode = clampi(mode, 0, 1)
	_breaker_shape_lab_refinement_active = true
	_breaker_shape_lab_tiled_active = false
	if _breaker_shape_lab_tiled_batcher != null:
		_breaker_shape_lab_tiled_batcher.hide()
	for level in _levels:
		if is_instance_valid(level):
			level.visible = false
	for diagnostic in _breaker_shape_lab_topology_meshes:
		if is_instance_valid(diagnostic):
			diagnostic.visible = false
	_breaker_shape_lab_refinement_instance.mesh = _breaker_shape_lab_refinement_meshes[_breaker_shape_lab_refinement_mode]
	_breaker_shape_lab_refinement_instance.visible = true
	return _breaker_shape_lab_refinement_info


func get_breaker_shape_lab_refinement_mode() -> int:
	return _breaker_shape_lab_refinement_mode


func get_breaker_shape_lab_refinement_info() -> Dictionary:
	return _breaker_shape_lab_refinement_info


func _mesh_topology_info(mesh: ArrayMesh) -> Dictionary:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	return {
		"vertices": vertices.size(),
		"triangles": indices.size() / 3,
		"surface_count": mesh.get_surface_count(),
	}


func _clear_breaker_shape_lab_refinement_diagnostic() -> void:
	if is_instance_valid(_breaker_shape_lab_refinement_instance):
		_breaker_shape_lab_refinement_instance.queue_free()
	_breaker_shape_lab_refinement_instance = null
	_breaker_shape_lab_refinement_meshes.clear()
	_breaker_shape_lab_refinement_info = {}
	_breaker_shape_lab_refinement_mode = -1
	_breaker_shape_lab_refinement_active = false


func get_breaker_shape_lab_topology_mode() -> int:
	return _breaker_shape_lab_topology_mode


func get_breaker_shape_lab_topology_info() -> Dictionary:
	return _breaker_shape_lab_topology_info


func _clear_breaker_shape_lab_topology_diagnostic() -> void:
	for diagnostic in _breaker_shape_lab_topology_meshes:
		if is_instance_valid(diagnostic):
			diagnostic.queue_free()
	_breaker_shape_lab_topology_meshes.clear()
	_breaker_shape_lab_topology_info = {}
	_breaker_shape_lab_topology_mode = 0
	_breaker_shape_lab_refinement_active = false
	_breaker_shape_lab_tiled_active = false
	if _breaker_shape_lab_tiled_batcher != null:
		_breaker_shape_lab_tiled_batcher.hide()
	for level in _levels:
		if is_instance_valid(level):
			level.visible = true


func get_underwater_medium_raster_geometry() -> Array:
	# This is deliberately the already-built ArrayMesh source data. P6 may make
	# one private RD buffer copy, but never builds a second clipmap topology.
	var geometry: Array = []
	for level in _levels:
		if level == null or not is_instance_valid(level) or not level.mesh is ArrayMesh:
			return []
		var arrays := (level.mesh as ArrayMesh).surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if vertices.is_empty() or indices.is_empty():
			return []
		geometry.append({"vertices": vertices, "indices": indices})
	return geometry


func set_optics(enabled: bool, profile: Resource) -> void:
	var state_changed := _optics_enabled != enabled
	_optics_enabled = enabled
	_optics_profile = profile as OceanOpticsProfile
	if state_changed:
		_warm_runtime_variants()
		_apply_shader_variant()
	if not enabled:
		_apply_coastal_data()
		return
	if not state_changed:
		_apply_optics_profile()


func set_optics_profile(profile: OceanOpticsProfile) -> void:
	_optics_profile = profile
	if _optics_enabled:
		_apply_optics_profile()


func set_snell_profile(profile: Resource) -> void:
	_snell_profile = profile as OceanUnderwaterMediumProfile
	_apply_snell_profile()


func _apply_optics_profile() -> void:
	var values: OceanOpticsProfile = _optics_profile
	if values == null:
		values = OpticsProfile.new()
	_set_surface_shader_parameter(&"water_optics_enabled", true)
	_set_surface_shader_parameter(&"optics_shallow_water_color", values.shallow_water_color)
	_set_surface_shader_parameter(&"optics_deep_water_color", values.deep_water_color)
	_set_surface_shader_parameter(&"optics_horizon_water_color", values.horizon_water_color)
	_set_surface_shader_parameter(&"optics_trough_tint", values.trough_tint)
	_set_surface_shader_parameter(&"optics_crest_tint", values.crest_tint)
	for key in ["absorption_coeff_rgb", "maximum_optical_depth_above_m", "water_body_depth_start_m", "water_body_depth_end_m", "opacity_distance_start", "opacity_distance_end", "refraction_micro_normal_strength", "refraction_max_offset_px", "refraction_depth_tolerance_m", "refraction_wave_strength", "refraction_long_weight", "refraction_mid_weight", "refraction_short_weight", "refraction_depth_start_m", "refraction_depth_end_m", "scattering_color", "scattering_strength", "scattering_shallow_tint_influence", "scattering_deep_tint_influence", "shallow_scattering_strength", "shallow_scattering_depth_start_m", "shallow_scattering_depth_end_m", "water_turbidity", "crest_transmission_boost", "trough_density_boost", "transmission_detail_fade_start_m", "transmission_detail_fade_end_m", "transmission_max_lod", "bottom_visibility_fade_start_m", "bottom_visibility_fade_end_m", "seabed_match_tolerance_start_m", "seabed_match_tolerance_end_m", "shallow_fresnel_relief", "shallow_fresnel_depth_start_m", "shallow_fresnel_depth_end_m"]:
		_set_surface_shader_parameter(key, values.get(key))
	_apply_coastal_data()


func _apply_snell_profile() -> void:
	var values: OceanUnderwaterMediumProfile = _snell_profile
	_set_surface_shader_parameter(&"underwater_snell_enabled", values != null and values.snell_tir_enabled)
	if values == null:
		values = UnderwaterMediumProfile.new()
	_set_surface_shader_parameter(&"underwater_water_ior", values.underwater_water_ior)
	_set_surface_shader_parameter(&"underwater_snell_strength", values.underwater_snell_strength)
	_set_surface_shader_parameter(&"underwater_tir_strength", values.underwater_tir_strength)
	_set_surface_shader_parameter(&"underwater_snell_wave_distortion", values.underwater_snell_wave_distortion)
	_set_surface_shader_parameter(&"underwater_snell_detail_strength", values.underwater_snell_detail_strength)
	_set_surface_shader_parameter(&"underwater_snell_detail_world_scale", values.underwater_snell_detail_world_scale)
	_set_surface_shader_parameter(&"underwater_snell_detail_max_px", values.underwater_snell_detail_max_px)
	_set_surface_shader_parameter(&"underwater_snell_edge_softness", values.underwater_snell_edge_softness)
	_set_surface_shader_parameter(&"underwater_snell_cone_angle_surface_deg", values.underwater_snell_cone_angle_surface_deg)
	_set_surface_shader_parameter(&"underwater_snell_cone_angle_deep_deg", values.underwater_snell_cone_angle_deep_deg)
	_set_surface_shader_parameter(&"underwater_snell_cone_deep_start_m", values.underwater_snell_cone_deep_start_m)
	_set_surface_shader_parameter(&"underwater_surface_sea_level_y", _sea_level)


func set_reflections(enabled: bool, profile: Resource) -> void:
	var state_changed := _reflections_enabled != enabled
	_reflections_enabled = enabled
	_reflection_profile = profile as OceanReflectionProfile
	if not enabled:
		_reflection_texture = null
		_reflection_texture_available = false
	if state_changed:
		_warm_runtime_variants()
		_apply_shader_variant()
	if enabled and not state_changed:
		_apply_reflection_state()


func set_reflection_profile(profile: OceanReflectionProfile) -> void:
	_reflection_profile = profile
	if _reflections_enabled:
		_apply_reflection_state()


func set_reflection_texture(texture: Texture2D, available: bool) -> void:
	_reflection_texture = texture
	_reflection_texture_available = available and texture != null
	if _reflections_enabled:
		_apply_reflection_state()


func set_surface_detail(enabled: bool, profile: OceanSurfaceDetailProfile) -> void:
	var state_changed := _surface_detail_enabled != enabled
	_surface_detail_enabled = enabled
	_surface_detail_profile = profile
	if state_changed:
		_warm_runtime_variants()
		_apply_shader_variant()
	elif enabled:
		_apply_surface_detail_profile()


func set_surface_detail_profile(profile: OceanSurfaceDetailProfile) -> void:
	_surface_detail_profile = profile
	if _surface_detail_enabled:
		_apply_surface_detail_profile()


func set_breakers(enabled: bool, profile: OceanBreakerProfile) -> void:
	_breakers_requested = enabled
	_breaker_profile = profile
	_update_breakers_effective()
	if _breakers_enabled:
		_apply_breaker_profile()
	_update_clipmap_culling_bounds()


func set_breaker_lifecycle_texture(texture: Texture2DRD) -> void:
	_breaker_lifecycle_texture = texture
	_set_surface_shader_parameter(&"breaker_lifecycle", texture)
	_set_surface_shader_parameter(&"breaker_carrier_lifecycle", texture)


func set_breaker_multiphase_vdm_texture(texture: Texture2D) -> void:
	if texture == null or not (texture is Texture2DRD) or not (texture as Texture2DRD).texture_rd_rid.is_valid():
		return
	_breaker_multiphase_vdm = texture
	_set_surface_shader_parameter(&"breaker_multiphase_vdm", texture)
	_update_breakers_effective()


func set_breaker_profile(profile: OceanBreakerProfile) -> void:
	_breaker_profile = profile
	if _breakers_enabled:
		_apply_breaker_profile()
	_update_clipmap_culling_bounds()


func _update_breakers_effective() -> void:
	var vdm_ready := _breaker_multiphase_vdm is Texture2DRD and (_breaker_multiphase_vdm as Texture2DRD).texture_rd_rid.is_valid()
	var variant_available := _coastal_waves_enabled and not _coastal_data.is_empty() and vdm_ready
	var runtime_enabled := _breakers_requested and variant_available
	if runtime_enabled != _breaker_runtime_enabled:
		_breaker_runtime_enabled = runtime_enabled
		_set_surface_shader_parameter(&"breaker_runtime_enabled", 1.0 if runtime_enabled else 0.0)
	if variant_available == _breakers_enabled:
		return
	_breakers_enabled = variant_available
	_warm_runtime_variants()
	_apply_shader_variant()


func _apply_breaker_profile() -> void:
	var values: OceanBreakerProfile = _breaker_profile
	if values == null:
		values = BreakerProfile.new()
	for key in ["strength", "shallow_fade_start_m", "shallow_fade_end_m", "deep_activation_start_m", "deep_activation_end_m", "shoaling_start", "shoaling_full", "detj_compression_start", "detj_compression_full", "crest_height_start_m", "crest_height_full_m", "front_slope_start", "front_slope_full", "forward_push_fraction", "face_compression_fraction", "crest_lift_scale", "crest_curve", "normal_follow_strength", "pre_lip_strength", "pre_lip_forward_fraction", "pre_lip_lift_scale", "max_horizontal_fraction", "max_vertical_lift_scale", "lip_strength", "lip_forward_fraction", "lip_drop_scale", "lip_lift_scale", "lip_prefold_start_j", "lip_prefold_full_j", "lip_unsafe_j", "lip_recover_j"]:
		_set_surface_shader_parameter("breaker_" + key if key != "strength" else "breaker_profile_strength", values.get(key))
	_set_surface_shader_parameter(&"breaker_multiphase_vdm", _breaker_multiphase_vdm)
	_set_surface_shader_parameter(&"breaker_runtime_enabled", 1.0 if _breaker_runtime_enabled else 0.0)


func _apply_surface_detail_profile() -> void:
	var values: OceanSurfaceDetailProfile = _surface_detail_profile
	if values == null:
		values = SurfaceDetailProfile.new()
	var texture_a: Texture2D = values.normal_texture_a
	var texture_b: Texture2D = values.normal_texture_b
	var warp_texture: Texture2D = values.warp_texture
	if texture_a == null: texture_a = SurfaceDetailProfile.DEFAULT_NORMAL_TEXTURE_A
	if texture_b == null: texture_b = SurfaceDetailProfile.DEFAULT_NORMAL_TEXTURE_B
	if warp_texture == null: warp_texture = SurfaceDetailProfile.DEFAULT_WARP_TEXTURE
	_set_surface_shader_parameter(&"surface_normal_texture_a", texture_a)
	_set_surface_shader_parameter(&"surface_normal_texture_b", texture_b)
	_set_surface_shader_parameter(&"surface_warp_texture", warp_texture)
	for key in ["wave_follow", "normal_world_size_a", "normal_world_size_b", "normal_strength", "flow_direction_a", "flow_direction_b", "flow_speed_a", "flow_speed_b", "warp_world_size", "warp_strength", "fade_start_m", "fade_end_m", "far_strength", "quality"]:
		var uniform_name: String = "surface_" + key
		if key == "wave_follow": uniform_name = "surface_detail_wave_follow"
		elif key == "normal_world_size_a": uniform_name = "surface_normal_world_size_a"
		elif key == "normal_world_size_b": uniform_name = "surface_normal_world_size_b"
		elif key == "normal_strength": uniform_name = "surface_normal_strength"
		elif key == "flow_direction_a": uniform_name = "surface_flow_direction_a"
		elif key == "flow_direction_b": uniform_name = "surface_flow_direction_b"
		elif key == "flow_speed_a": uniform_name = "surface_flow_speed_a"
		elif key == "flow_speed_b": uniform_name = "surface_flow_speed_b"
		elif key == "warp_world_size": uniform_name = "surface_warp_world_size"
		elif key == "warp_strength": uniform_name = "surface_warp_strength"
		elif key == "fade_start_m": uniform_name = "surface_detail_fade_start"
		elif key == "fade_end_m": uniform_name = "surface_detail_fade_end"
		elif key == "far_strength": uniform_name = "surface_detail_far_strength"
		elif key == "quality": uniform_name = "ocean_surface_detail_quality"
		var effective_value: Variant = values.get(key)
		if key in ["normal_world_size_a", "normal_world_size_b", "warp_world_size"]:
			effective_value = float(effective_value) * _ocean_space_horizontal_scale
		_set_surface_shader_parameter(uniform_name, effective_value)


func set_crest_foam_profile(profile: OceanCrestFoamProfile) -> void:
	_crest_foam_profile = profile
	_apply_crest_foam_profile()


func _apply_crest_foam_profile() -> void:
	var values: OceanCrestFoamProfile = _crest_foam_profile
	if values == null: values = CrestFoamProfile.new()
	for key in ["intensity", "contrast", "detail_contribution", "breakup_strength", "breakup_world_size_m", "edge_softness", "residual_color", "residual_roughness", "residual_specular"]:
		var effective_value: Variant = values.get(key)
		if key == "breakup_world_size_m":
			effective_value = float(effective_value) * _ocean_space_horizontal_scale
		_set_surface_shader_parameter("crest_foam_%s" % key, effective_value)
	_set_surface_shader_parameter(&"crest_foam_distance_fade_range_m", values.distance_fade_range_m)


func set_surface_foam_profile(profile: OceanSurfaceFoamProfile) -> void:
	_surface_foam_profile = profile
	_apply_surface_foam_profile()


func _apply_surface_foam_profile() -> void:
	var values: OceanSurfaceFoamProfile = _surface_foam_profile
	if values == null: values = SurfaceFoamProfile.new()
	_set_surface_shader_parameter(&"surface_foam_source_domain_m", SURFACE_FOAM_SOURCE_DOMAIN_M * _ocean_space_horizontal_scale)
	_set_surface_shader_parameter(&"surface_foam_field_domain_m", SURFACE_FOAM_FIELD_DOMAIN_M * _ocean_space_horizontal_scale)
	for key in ["intensity", "threshold_visual", "color", "roughness", "specular", "ocean_coupling", "stochastic_deperiodization_enabled", "stochastic_cell_size_m"]:
		var uniform_name := "surface_foam_%s" % key
		if key == "intensity": uniform_name = "surface_foam_strength"
		elif key == "threshold_visual": uniform_name = "surface_foam_threshold_visual"
		elif key == "color": uniform_name = "surface_foam_color"
		elif key == "roughness": uniform_name = "surface_foam_roughness"
		elif key == "specular": uniform_name = "surface_foam_specular"
		elif key == "ocean_coupling": uniform_name = "surface_foam_ocean_coupling"
		elif key == "stochastic_deperiodization_enabled": uniform_name = "surface_foam_stochastic_deperiodization_enabled"
		elif key == "stochastic_cell_size_m": uniform_name = "surface_foam_stochastic_cell_size_m"
		var effective_value: Variant = values.get(key)
		if key == "stochastic_cell_size_m":
			effective_value = float(effective_value) * _ocean_space_horizontal_scale
		_set_surface_shader_parameter(uniform_name, effective_value)
	_set_surface_shader_parameter(&"surface_foam_distance_fade_range_m", values.distance_fade_range_m)
	_set_surface_shader_parameter(&"surface_foam_mid_fold_influence", values.mid_fold_influence)
	_set_surface_shader_parameter(&"crest_filigree_residual_strength", values.crest_residual_filigree_strength)
	_set_surface_shader_parameter(&"crest_filigree_contrast", values.crest_filigree_contrast)
	_set_surface_shader_parameter(&"crest_filigree_threshold", values.crest_filigree_threshold)


func _apply_reflection_profile() -> void:
	var values: OceanReflectionProfile = _reflection_profile
	if values == null:
		values = ReflectionProfile.new()
	for key in ["base_roughness", "roughness_distance_m", "sspr_resolution_scale", "distortion_strength", "edge_fade", "radiance_exposure_ev", "radiance_saturation", "screen_space_weight", "environment_specular_near_boost", "environment_specular_far_boost", "environment_specular_near_distance", "environment_specular_far_distance"]:
		var uniform_name: String = "reflection_" + key
		if key == "sspr_resolution_scale": continue
		if key == "distortion_strength": uniform_name = "reflection_sspr_distortion_strength"
		elif key == "edge_fade": uniform_name = "reflection_sspr_edge_fade"
		elif key == "radiance_exposure_ev": uniform_name = "reflection_radiance_exposure_ev"
		elif key == "radiance_saturation": uniform_name = "reflection_radiance_saturation"
		_set_surface_shader_parameter(uniform_name, values.get(key))


func _apply_reflection_state() -> void:
	# This route never changes shaders. It is safe to call after any Base/Optics/
	# SSPR variant assignment and does not depend on ShaderMaterial persistence.
	_apply_reflection_profile()
	_set_surface_shader_parameter(&"reflection_sspr_available", _reflection_texture_available)
	if _reflection_texture_available:
		_set_surface_shader_parameter(&"reflection_sspr_texture", _reflection_texture)


func _variant_key(optics_enabled: bool, reflections_enabled: bool, detail_enabled: bool, breakers_enabled: bool) -> String:
	return "%s:%s:%s:%s" % ["optics" if optics_enabled else "base", "sspr" if reflections_enabled else "fallback", "detail" if detail_enabled else "flat", "breaker" if breakers_enabled else "nobreaker"]


func _warm_runtime_variants() -> void:
	# Authoring changes may compile variants.  Runtime water crossings only select
	# these prepared shaders/materials and therefore never allocate them during a
	# switch.
	_prepare_shader_variant(_variant_key(_optics_enabled, _reflections_enabled, _surface_detail_enabled, _breakers_enabled), _optics_enabled, _reflections_enabled, _surface_detail_enabled, _breakers_enabled)
	_prepare_shader_variant(_variant_key(false, false, _surface_detail_enabled, _breakers_enabled), false, false, _surface_detail_enabled, _breakers_enabled)
	_prepare_shader_variant("base:fallback:flat:nobreaker", false, false, false, false)


func _prepare_shader_variant(key: String, optics_enabled: bool, reflections_enabled: bool, detail_enabled: bool, breakers_enabled: bool) -> void:
	if _variant_materials.has(key):
		return
	var shader: Shader
	if key == "base:fallback:flat:nobreaker":
		shader = SURFACE_SHADER
	else:
		shader = Shader.new()
		shader.code = _build_shader_source(optics_enabled, reflections_enabled, detail_enabled, breakers_enabled)
	var material := ShaderMaterial.new()
	material.shader = shader
	_variant_shaders[key] = shader
	_variant_materials[key] = material


func _build_shader_source(optics_enabled: bool, reflections_enabled: bool, detail_enabled: bool, breakers_enabled: bool, lab_enabled := false) -> String:
	var code := SURFACE_SHADER.code
	if lab_enabled:
		code = code.replace(BREAKER_SHAPE_LAB_UNIFORMS_MARKER, BREAKER_SHAPE_LAB_UNIFORMS)
		code = code.replace(BREAKER_SHAPE_LAB_VARYINGS_MARKER, BREAKER_SHAPE_LAB_VARYINGS)
		code = code.replace(BREAKER_SHAPE_LAB_DEFORMATION_MARKER, BREAKER_SHAPE_LAB_DEFORMATION)
		code = code.replace(BREAKER_SHAPE_LAB_VERTEX_POST_MARKER, BREAKER_SHAPE_LAB_VERTEX_POST)
		code = code.replace(BREAKER_SHAPE_LAB_FRAGMENT_NORMAL_MARKER, BREAKER_SHAPE_LAB_FRAGMENT_NORMAL)
	if detail_enabled:
		code = code.replace(SURFACE_DETAIL_UNIFORMS_MARKER, SURFACE_DETAIL_UNIFORMS_MARKER + SURFACE_DETAIL_UNIFORMS)
		code = code.replace(SURFACE_DETAIL_VERTEX_MARKER, SURFACE_DETAIL_VERTEX)
		code = code.replace(SURFACE_DETAIL_FRAGMENT_MARKER, SURFACE_DETAIL_FRAGMENT)
	if breakers_enabled:
		code = code.replace(BREAKERS_UNIFORMS_MARKER, BREAKERS_UNIFORMS_MARKER + BREAKERS_UNIFORMS)
		code = code.replace(BREAKERS_VARYINGS_MARKER, BREAKERS_VARYINGS_MARKER + BREAKERS_VARYINGS)
		code = code.replace(BREAKERS_VERTEX_INIT_MARKER, BREAKERS_VERTEX_INIT)
		code = code.replace(BREAKERS_COASTAL_VERTEX_MARKER, BREAKERS_COASTAL_VERTEX)
		code = code.replace(BREAKERS_VERTEX_POST_MARKER, BREAKERS_VERTEX_POST)
		code = code.replace(BREAKERS_FRAGMENT_NORMAL_MARKER, BREAKERS_FRAGMENT_NORMAL)
		code = code.replace(BREAKER_WHITEWATER_FRAGMENT_MARKER, BREAKER_WHITEWATER_FRAGMENT)
	if optics_enabled:
		code = code.replace(OPTICS_UNIFORMS_MARKER, OPTICS_UNIFORMS_MARKER + OPTICS_UNIFORMS).replace(OPTICS_FRAGMENT_MARKER, OPTICS_FRAGMENT)
		if detail_enabled:
			code = code.replace(OPTICS_DETAIL_BASE_NORMAL_MARKER + "\n\t\tvec3 base_normal_view = visual_normal;", "vec3 base_normal_view = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);")
			code = code.replace(OPTICS_DETAIL_NORMAL_MARKER, "+ surface_detail_offset_view * surface_normal_strength * refraction_micro_normal_strength")
			code = code.replace(SNELL_DETAIL_MARKER, SNELL_DETAIL_FRAGMENT)
	if reflections_enabled:
		code = code.replace(REFLECTIONS_UNIFORMS_MARKER, REFLECTIONS_UNIFORMS_MARKER + REFLECTIONS_UNIFORMS).replace(REFLECTIONS_FRAGMENT_MARKER, REFLECTIONS_FRAGMENT)
		if optics_enabled:
			code = code.replace(SNELL_TIR_COMPOSITION_MARKER, SNELL_TIR_COMPOSITION)
	return code


func _apply_shader_variant() -> void:
	if _breaker_shape_lab_active:
		return
	var effective_optics := _optics_enabled
	var effective_reflections := _reflections_enabled
	var effective_detail := _surface_detail_enabled
	var effective_breakers := _breakers_enabled
	var key := _variant_key(effective_optics, effective_reflections, effective_detail, effective_breakers)
	if key == _active_shader_variant_key:
		return
	# Both possible keys are cached by _warm_runtime_variants before gameplay.
	if not _variant_materials.has(key):
		push_error("Ocean surface runtime material variant was not warmed: %s" % key)
		return
	var target_material := _variant_materials[key] as ShaderMaterial
	_material = target_material
	_hydrate_material(target_material)
	_apply_wave_time()
	_apply_surface_scale()
	_apply_clipmap_geometry_scale()
	if effective_optics:
		_apply_optics_profile()
	_apply_coastal_data()
	_apply_crest_foam_profile()
	_apply_surface_foam_profile()
	if effective_detail:
		_apply_surface_detail_profile()
	_apply_snell_profile()
	if effective_breakers:
		_apply_breaker_profile()
	if effective_reflections:
		_apply_reflection_state()
	_assign_material_to_surface_geometry(target_material)
	_active_shader_variant_key = key


func set_runtime_water_state(state: StringName) -> void:
	if state == _runtime_water_state:
		return
	_runtime_water_state = state


func set_camera_surface_signed_distance(distance_m: float) -> void:
	if not is_finite(distance_m):
		return
	_camera_surface_signed_distance_m = distance_m
	_surface_air_blend = smoothstep(-0.20, 0.20, distance_m)
	_set_surface_shader_parameter(&"surface_air_blend", _surface_air_blend)
	_set_surface_shader_parameter(&"underwater_camera_signed_distance_m", _camera_surface_signed_distance_m)


func set_coastal_data(data: Dictionary, waves_enabled := true) -> void:
	_coastal_data = data
	_coastal_waves_enabled = waves_enabled
	_update_breakers_effective()
	_apply_coastal_data()
	_update_clipmap_culling_bounds()


func _apply_coastal_data() -> void:
	var active := not _coastal_data.is_empty()
	_set_surface_shader_parameter(&"coastal_enabled", active and _coastal_waves_enabled)
	var effective_optics := _optics_enabled
	if not active:
		if effective_optics:
			_set_surface_shader_parameter(&"optics_bathymetry_enabled", false)
			_set_surface_shader_parameter(&"optics_real_seabed_coverage_enabled", false)
		return
	for key in ["field", "metrics", "phase", "warp", "jacobian", "origin", "extent", "warp_origin", "warp_extent", "warp_detj_safe"]:
		_set_surface_shader_parameter("coastal_%s" % key, _coastal_data[key])
	if not effective_optics: return
	_set_surface_shader_parameter(&"optics_bathymetry_enabled", true)
	var seabed_enabled: bool = _coastal_data["seabed_coverage_enabled"]
	_set_surface_shader_parameter(&"optics_real_seabed_coverage_enabled", seabed_enabled)
	if seabed_enabled:
		_set_surface_shader_parameter(&"optics_real_seabed_coverage_texture", _coastal_data["seabed_coverage"])
		_set_surface_shader_parameter(&"optics_real_seabed_coverage_origin", _coastal_data["seabed_origin"])
		_set_surface_shader_parameter(&"optics_real_seabed_coverage_extent", _coastal_data["seabed_extent"])
		_set_surface_shader_parameter(&"optics_seabed_sea_level", _coastal_data["seabed_sea_level"])


func set_crest_foam_enabled(enabled: bool) -> void:
	_crest_foam_enabled = enabled
	_set_surface_shader_parameter(&"crest_foam_enabled", enabled)


func set_surface_foam(field: Texture2DRD, topology: Texture2DRD, mid_history: Texture2DRD, enabled: bool) -> void:
	_surface_foam_enabled = enabled
	set_surface_foam_presentation(enabled)
	if enabled:
		_set_surface_shader_parameter(&"surface_foam_field", field)
		_set_surface_shader_parameter(&"surface_foam_topology", topology)
		_set_surface_shader_parameter(&"surface_foam_mid_history", mid_history)


func set_surface_foam_presentation(enabled: bool) -> void:
	_surface_foam_presentation_enabled = enabled and _surface_foam_enabled
	_set_surface_shader_parameter(&"surface_foam_enabled", _surface_foam_presentation_enabled)
	_set_surface_shader_parameter(&"crest_filigree_enabled", _surface_foam_presentation_enabled)


func get_runtime_feature_state() -> Dictionary:
	return {
		"shader_variant_key": _active_shader_variant_key,
		"active_material_id": _material.get_instance_id() if _material != null else 0,
		"variant_material_count": _variant_materials.size(),
		"variant_material_keys": _variant_materials.keys(),
		"surface_parameter_state": _surface_parameter_state.duplicate(),
		"crest_foam": _crest_foam_enabled,
		"surface_foam": _surface_foam_presentation_enabled,
		"optics": _optics_enabled,
		"snell_tir": _snell_profile != null and _snell_profile.snell_tir_enabled,
		"reflections": _reflections_enabled,
		"camera_surface_signed_distance_m": _camera_surface_signed_distance_m,
		"surface_air_blend": _surface_air_blend,
		"surface_detail": _surface_detail_enabled,
		"breakers_requested": _breakers_requested,
		"breakers": _breaker_runtime_enabled,
		"breaker_multiphase_vdm_ready": _breaker_multiphase_vdm is Texture2DRD and (_breaker_multiphase_vdm as Texture2DRD).texture_rd_rid.is_valid(),
		"breaker_multiphase_vdm_rid_valid": _breaker_multiphase_vdm is Texture2DRD and (_breaker_multiphase_vdm as Texture2DRD).texture_rd_rid.is_valid(),
		"breaker_material_enabled": _breakers_enabled,
		"breaker_carrier_suppression_enabled": bool(_surface_parameter_state.get("breaker_carrier_suppression_enabled", false)),
		"breaker_carrier_search_xz": _surface_parameter_state.get("breaker_carrier_search_xz", Vector2.ZERO),
		"breaker_carrier_event_seed_sample_xz": _surface_parameter_state.get("breaker_carrier_event_seed_sample_xz", Vector2.ZERO),
		"breaker_runtime_enabled": _breaker_runtime_enabled,
		"local_breaker_refinement_enabled": _local_breaker_refinement_enabled,
		"local_breaker_refinement": _local_breaker_refinement_info,
	}


func shutdown() -> void:
	if _local_breaker_refinement_batcher != null:
		_local_breaker_refinement_batcher.clear()
	_local_breaker_refinement_batcher = null
	_local_breaker_refinement_manager = null
	_local_breaker_refinement_region = null
	_local_breaker_refinement_coarse_mesh = null
	_local_breaker_refinement_high_meshes.clear()
	_local_breaker_refinement_tile_transforms.clear()
	_local_breaker_refinement_last_tiles.clear()
	_local_breaker_refinement_layout.clear()
	_local_breaker_refinement_initialized = false
	_local_breaker_refinement_info = {}
	_wave_configs.clear()
	_fft_displacement_bounds_ocean = Vector3.ZERO
	_clipmap_culling_bounds_signature = ""
	_breaker_shape_lab_shader = null
	_breaker_shape_lab_material = null
	_breaker_shape_lab_active = false
	_clear_breaker_shape_lab_topology_diagnostic()
	_clear_breaker_shape_lab_refinement_diagnostic()
	for level in _levels:
		if is_instance_valid(level): level.queue_free()
	_levels.clear()


func _process(delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null: return
	global_position = Vector3(camera.global_position.x, _sea_level, camera.global_position.z)
	_set_surface_shader_parameter(&"camera_world_xz", Vector2(camera.global_position.x, camera.global_position.z))
	if _local_breaker_refinement_enabled:
		_request_active_front_refinement_scan(Vector2(camera.global_position.x, camera.global_position.z), delta)
		_update_local_breaker_refinement()
