class_name OceanClipmapSurface
extends Node3D
## Presentación de las tres bandas P0-P5. Integra sus variantes de material,
## incluido el estado de Optics/SSPR, pero no posee datos Coastal ni sus
## productores/compute de RenderingDevice.

const MeshBuilder := preload("res://addons/ocean/surface/ocean_clipmap_mesh_builder.gd")
const SURFACE_SHADER := preload("res://addons/ocean/shaders/ocean_surface.gdshader")
const CREST_BREAKUP_NOISE := preload("res://addons/ocean/surface/crest_breakup_noise.tres")
const OpticsProfile := preload("res://addons/ocean/core/ocean_optics_profile.gd")
const ReflectionProfile := preload("res://addons/ocean/core/ocean_reflection_profile.gd")
const CrestFoamProfile := preload("res://addons/ocean/core/ocean_crest_foam_profile.gd")
const SurfaceFoamProfile := preload("res://addons/ocean/core/ocean_surface_foam_profile.gd")
const SurfaceDetailProfile := preload("res://addons/ocean/core/ocean_surface_detail_profile.gd")
const OPTICS_UNIFORMS_MARKER := "// P4_OPTICS_UNIFORMS"
const OPTICS_FRAGMENT_MARKER := "// P4_OPTICS_FRAGMENT"
const REFLECTIONS_UNIFORMS_MARKER := "// P5_REFLECTIONS_UNIFORMS"
const REFLECTIONS_FRAGMENT_MARKER := "// P5_REFLECTIONS_FRAGMENT"
const SURFACE_DETAIL_UNIFORMS_MARKER := "// P5_5_SURFACE_DETAIL_UNIFORMS"
const SURFACE_DETAIL_VERTEX_MARKER := "// P5_5_SURFACE_DETAIL_VERTEX"
const SURFACE_DETAIL_FRAGMENT_MARKER := "// P5_5_SURFACE_DETAIL_FRAGMENT"
const OPTICS_DETAIL_BASE_NORMAL_MARKER := "// P5_5_OPTICS_BASE_NORMAL"
const OPTICS_DETAIL_NORMAL_MARKER := "// P5_5_OPTICS_DETAIL_NORMAL"

const SURFACE_DETAIL_UNIFORMS := '''
uniform sampler2D surface_normal_texture_a : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_normal_texture_b : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_warp_texture : repeat_enable, filter_linear_mipmap;
uniform float surface_detail_wave_follow = 0.70;
uniform float surface_normal_world_size_a = 7.5;
uniform float surface_normal_world_size_b = 3.25;
uniform float surface_normal_strength = 0.62;
uniform vec2 surface_flow_direction_a = vec2(0.82, 0.57);
uniform vec2 surface_flow_direction_b = vec2(-0.46, 0.89);
uniform float surface_flow_speed_a = 0.24;
uniform float surface_flow_speed_b = -0.17;
uniform float surface_warp_world_size = 46.0;
uniform float surface_warp_strength = 2.4;
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
		vec3 mid_slope_normal = normalize(texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz);
		vec3 short_slope_normal = normalize(texture(normal_short, world_uv(world_xz, domain_short_m)).xyz);
		vec2 wave_slope = vec2(-long_slope_normal.x / max(long_slope_normal.y, 0.08), -long_slope_normal.z / max(long_slope_normal.y, 0.08)) * refraction_long_weight;
		wave_slope += vec2(-mid_slope_normal.x / max(mid_slope_normal.y, 0.08), -mid_slope_normal.z / max(mid_slope_normal.y, 0.08)) * refraction_mid_weight;
		wave_slope += vec2(-short_slope_normal.x / max(short_slope_normal.y, 0.08), -short_slope_normal.z / max(short_slope_normal.y, 0.08)) * refraction_short_weight;
		float refraction_depth_factor = 1.0 - smoothstep(refraction_depth_start_m, max(refraction_depth_end_m, refraction_depth_start_m + 0.001), bounded_view_water_path_m);
		vec2 screen_size = max(vec2(textureSize(screen_texture, 0)), vec2(1.0));
		vec4 water_view_h = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, FRAGCOORD.z, 1.0);
		vec3 water_view_position = water_view_h.xyz / max(water_view_h.w, 0.00001);
		// P5_5_OPTICS_BASE_NORMAL
		vec3 base_normal_view = visual_normal;
		vec3 wave_normal_view = normalize(mat3(VIEW_MATRIX) * normalize(vec3(-wave_slope.x, 1.0, -wave_slope.y)));
		float grazing_confidence = smoothstep(0.18, 0.58, clamp(abs(dot(wave_normal_view, normalize(-water_view_position))), 0.0, 1.0));
		vec3 refraction_normal_view = normalize(
			mix(base_normal_view, wave_normal_view, clamp(refraction_wave_strength * refraction_depth_factor * grazing_confidence, 0.0, 1.0))
			// P5_5_OPTICS_DETAIL_NORMAL
		);
		vec3 refracted_direction_view = refract(normalize(water_view_position), refraction_normal_view, 1.0 / 1.333);
		vec2 candidate_uv = SCREEN_UV;
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
		float refraction_validity = optics_edge_confidence(candidate_uv) * behind_water_confidence * (candidate_valid ? 1.0 - smoothstep(depth_tolerance, depth_tolerance + 0.25, closer_error) : 0.0);
		vec2 refracted_uv = mix(SCREEN_UV, candidate_uv, clamp(refraction_validity, 0.0, 1.0));
		vec3 refracted_scene = textureLod(screen_texture, refracted_uv, transmission_lod).rgb;
		float effective_seabed_match = mix(original_seabed_match, candidate_seabed_match, clamp(refraction_validity, 0.0, 1.0)) * optical_seabed_confidence;
		float seabed_transmission_weight = mix(1.0, bottom_visibility, effective_seabed_match);
		float trough_density = 1.0 + (1.0 - smoothstep(0.0, 0.45, crest_height)) * clamp(trough_density_boost, 0.0, 0.5);
		float path_saturation = clamp(optical_depth_m / max(maximum_optical_depth_above_m, 0.001), 0.0, 1.0);
		float scattering_response = clamp((1.0 - exp(-0.22 * clamp(water_turbidity, 0.0, 2.0) * optical_depth_m)) * mix(0.55, 1.0, path_saturation), 0.0, 1.0);
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
		vec3 optical_scene = refracted_scene * effective_transmittance * seabed_transmission_weight + body_component + scattering_component;
		float shallow_relief = clamp(shallow_fresnel_relief, 0.0, 1.0) * real_seabed_coverage * (1.0 - smoothstep(shallow_fresnel_depth_start_m, max(shallow_fresnel_depth_end_m, shallow_fresnel_depth_start_m + 0.001), local_water_depth_m));
		float surface_weight = fresnel + (1.0 - fresnel) * distance_opacity * (1.0 - shallow_relief);
		ALBEDO = mix(optical_scene, surface_color, surface_weight);
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
uniform float reflection_environment_specular_boost = 0.65;

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
	SPECULAR = 0.2546625 * reflection_environment_specular_boost;
'''

var _material := ShaderMaterial.new()
var _levels: Array[MeshInstance3D] = []
var _sea_level := 0.0
var _quality: Resource
var _optics_shader: Shader
var _variant_shaders := {}
var _active_shader_variant_key := ""
var _coastal_data := {}
var _coastal_waves_enabled := false
var _optics_enabled := false
var _optics_profile: OceanOpticsProfile
var _reflections_enabled := false
var _reflection_profile: OceanReflectionProfile
var _reflection_texture: Texture2D
var _reflection_texture_available := false
var _crest_foam_profile: OceanCrestFoamProfile
var _surface_foam_profile: OceanSurfaceFoamProfile
var _surface_detail_enabled := false
var _surface_detail_profile: OceanSurfaceDetailProfile


func initialize(quality: Resource, sea_level: float, configs: Array, displacements: Array[Texture2DRD], normals: Array[Texture2DRD], crest_foams: Array[Texture2DRD]) -> void:
	shutdown()
	assert(configs.size() == 3 and displacements.size() == 3 and normals.size() == 3 and crest_foams.size() == 3)
	_quality = quality
	_sea_level = sea_level
	_material.shader = SURFACE_SHADER
	_active_shader_variant_key = "base:fallback"
	_material.set_shader_parameter(&"deep_water_color", Color(0.019474017, 0.0909042, 0.088472255))
	_material.set_shader_parameter(&"horizon_water_color", Color(0.0075189536, 0.07750165, 0.04554274))
	_material.set_shader_parameter(&"short_fade_range_m", quality.short_fade_range_m)
	_material.set_shader_parameter(&"mid_fade_range_m", quality.mid_fade_range_m)
	_material.set_shader_parameter(&"long_fade_range_m", quality.long_fade_range_m)
	for index in 3:
		var id: String = ["long", "mid", "short"][index]
		_material.set_shader_parameter("domain_%s_m" % id, configs[index].domain_size_m)
		_material.set_shader_parameter("displacement_%s" % id, displacements[index])
		_material.set_shader_parameter("normal_%s" % id, normals[index])
		_material.set_shader_parameter("crest_foam_%s" % id, crest_foams[index])
	_material.set_shader_parameter(&"crest_breakup_texture", CREST_BREAKUP_NOISE)
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
		instance.extra_cull_margin = 4.0
		add_child(instance)
		_levels.append(instance)


func set_debug_view(value: int) -> void:
	_material.set_shader_parameter(&"debug_view", clampi(value, 0, 1))


func set_optics(enabled: bool, profile: Resource) -> void:
	var state_changed := _optics_enabled != enabled
	_optics_enabled = enabled
	_optics_profile = profile as OceanOpticsProfile
	if state_changed:
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


func _apply_optics_profile() -> void:
	var values: OceanOpticsProfile = _optics_profile
	if values == null:
		values = OpticsProfile.new()
	_material.set_shader_parameter(&"water_optics_enabled", true)
	_material.set_shader_parameter(&"optics_shallow_water_color", values.shallow_water_color)
	_material.set_shader_parameter(&"optics_deep_water_color", values.deep_water_color)
	_material.set_shader_parameter(&"optics_horizon_water_color", values.horizon_water_color)
	_material.set_shader_parameter(&"optics_trough_tint", values.trough_tint)
	_material.set_shader_parameter(&"optics_crest_tint", values.crest_tint)
	for key in ["absorption_coeff_rgb", "maximum_optical_depth_above_m", "water_body_depth_start_m", "water_body_depth_end_m", "opacity_distance_start", "opacity_distance_end", "refraction_micro_normal_strength", "refraction_max_offset_px", "refraction_depth_tolerance_m", "refraction_wave_strength", "refraction_long_weight", "refraction_mid_weight", "refraction_short_weight", "refraction_depth_start_m", "refraction_depth_end_m", "scattering_color", "scattering_strength", "scattering_shallow_tint_influence", "scattering_deep_tint_influence", "shallow_scattering_strength", "shallow_scattering_depth_start_m", "shallow_scattering_depth_end_m", "water_turbidity", "crest_transmission_boost", "trough_density_boost", "transmission_detail_fade_start_m", "transmission_detail_fade_end_m", "transmission_max_lod", "bottom_visibility_fade_start_m", "bottom_visibility_fade_end_m", "seabed_match_tolerance_start_m", "seabed_match_tolerance_end_m", "shallow_fresnel_relief", "shallow_fresnel_depth_start_m", "shallow_fresnel_depth_end_m"]:
		_material.set_shader_parameter(key, values.get(key))
	_apply_coastal_data()


func set_reflections(enabled: bool, profile: Resource) -> void:
	var state_changed := _reflections_enabled != enabled
	_reflections_enabled = enabled
	_reflection_profile = profile as OceanReflectionProfile
	if not enabled:
		_reflection_texture = null
		_reflection_texture_available = false
	if state_changed:
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
		_apply_shader_variant()
	elif enabled:
		_apply_surface_detail_profile()


func set_surface_detail_profile(profile: OceanSurfaceDetailProfile) -> void:
	_surface_detail_profile = profile
	if _surface_detail_enabled:
		_apply_surface_detail_profile()


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
	_material.set_shader_parameter(&"surface_normal_texture_a", texture_a)
	_material.set_shader_parameter(&"surface_normal_texture_b", texture_b)
	_material.set_shader_parameter(&"surface_warp_texture", warp_texture)
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
		_material.set_shader_parameter(uniform_name, values.get(key))


func set_crest_foam_profile(profile: OceanCrestFoamProfile) -> void:
	_crest_foam_profile = profile
	_apply_crest_foam_profile()


func _apply_crest_foam_profile() -> void:
	var values: OceanCrestFoamProfile = _crest_foam_profile
	if values == null: values = CrestFoamProfile.new()
	for key in ["intensity", "contrast", "detail_contribution", "breakup_strength", "breakup_world_size_m", "edge_softness", "residual_color", "residual_roughness", "residual_specular"]:
		_material.set_shader_parameter("crest_foam_%s" % key, values.get(key))
	_material.set_shader_parameter(&"crest_foam_distance_fade_range_m", values.distance_fade_range_m)


func set_surface_foam_profile(profile: OceanSurfaceFoamProfile) -> void:
	_surface_foam_profile = profile
	_apply_surface_foam_profile()


func _apply_surface_foam_profile() -> void:
	var values: OceanSurfaceFoamProfile = _surface_foam_profile
	if values == null: values = SurfaceFoamProfile.new()
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
		_material.set_shader_parameter(uniform_name, values.get(key))
	_material.set_shader_parameter(&"surface_foam_distance_fade_range_m", values.distance_fade_range_m)
	_material.set_shader_parameter(&"surface_foam_mid_fold_influence", values.mid_fold_influence)
	_material.set_shader_parameter(&"crest_filigree_residual_strength", values.crest_residual_filigree_strength)
	_material.set_shader_parameter(&"crest_filigree_contrast", values.crest_filigree_contrast)
	_material.set_shader_parameter(&"crest_filigree_threshold", values.crest_filigree_threshold)


func _apply_reflection_profile() -> void:
	var values: OceanReflectionProfile = _reflection_profile
	if values == null:
		values = ReflectionProfile.new()
	for key in ["base_roughness", "roughness_distance_m", "sspr_resolution_scale", "distortion_strength", "edge_fade", "radiance_exposure_ev", "radiance_saturation", "screen_space_weight", "environment_specular_boost"]:
		var uniform_name: String = "reflection_" + key
		if key == "sspr_resolution_scale": continue
		if key == "distortion_strength": uniform_name = "reflection_sspr_distortion_strength"
		elif key == "edge_fade": uniform_name = "reflection_sspr_edge_fade"
		elif key == "radiance_exposure_ev": uniform_name = "reflection_radiance_exposure_ev"
		elif key == "radiance_saturation": uniform_name = "reflection_radiance_saturation"
		_material.set_shader_parameter(uniform_name, values.get(key))


func _apply_reflection_state() -> void:
	# This route never changes shaders. It is safe to call after any Base/Optics/
	# SSPR variant assignment and does not depend on ShaderMaterial persistence.
	_apply_reflection_profile()
	_material.set_shader_parameter(&"reflection_sspr_available", _reflection_texture_available)
	if _reflection_texture_available:
		_material.set_shader_parameter(&"reflection_sspr_texture", _reflection_texture)


func _apply_shader_variant() -> void:
	var key := "%s:%s:%s" % ["optics" if _optics_enabled else "base", "sspr" if _reflections_enabled else "fallback", "detail" if _surface_detail_enabled else "flat"]
	if key == _active_shader_variant_key:
		return
	if key == "base:fallback:flat":
		_material.shader = SURFACE_SHADER
		_active_shader_variant_key = key
		_apply_crest_foam_profile()
		_apply_surface_foam_profile()
		return
	if not _variant_shaders.has(key):
		var code := SURFACE_SHADER.code
		if _surface_detail_enabled:
			code = code.replace(SURFACE_DETAIL_UNIFORMS_MARKER, SURFACE_DETAIL_UNIFORMS_MARKER + SURFACE_DETAIL_UNIFORMS)
			code = code.replace(SURFACE_DETAIL_VERTEX_MARKER, SURFACE_DETAIL_VERTEX)
			code = code.replace(SURFACE_DETAIL_FRAGMENT_MARKER, SURFACE_DETAIL_FRAGMENT)
		if _optics_enabled:
			code = code.replace(OPTICS_UNIFORMS_MARKER, OPTICS_UNIFORMS_MARKER + OPTICS_UNIFORMS).replace(OPTICS_FRAGMENT_MARKER, OPTICS_FRAGMENT)
			if _surface_detail_enabled:
				code = code.replace(OPTICS_DETAIL_BASE_NORMAL_MARKER + "\n\t\tvec3 base_normal_view = visual_normal;", "vec3 base_normal_view = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);")
				code = code.replace(OPTICS_DETAIL_NORMAL_MARKER, "+ surface_detail_offset_view * surface_normal_strength * refraction_micro_normal_strength")
		if _reflections_enabled:
			code = code.replace(REFLECTIONS_UNIFORMS_MARKER, REFLECTIONS_UNIFORMS_MARKER + REFLECTIONS_UNIFORMS).replace(REFLECTIONS_FRAGMENT_MARKER, REFLECTIONS_FRAGMENT)
		var variant := Shader.new()
		variant.code = code
		_variant_shaders[key] = variant
	_material.shader = _variant_shaders[key]
	_active_shader_variant_key = key
	if _optics_enabled:
		_apply_optics_profile()
	_apply_coastal_data()
	_apply_crest_foam_profile()
	_apply_surface_foam_profile()
	if _surface_detail_enabled:
		_apply_surface_detail_profile()
	if _reflections_enabled:
		_apply_reflection_state()


func set_coastal_data(data: Dictionary, waves_enabled := true) -> void:
	_coastal_data = data
	_coastal_waves_enabled = waves_enabled
	_apply_coastal_data()


func _apply_coastal_data() -> void:
	var active := not _coastal_data.is_empty()
	_material.set_shader_parameter(&"coastal_enabled", active and _coastal_waves_enabled)
	if not active:
		if _optics_enabled:
			_material.set_shader_parameter(&"optics_bathymetry_enabled", false)
			_material.set_shader_parameter(&"optics_real_seabed_coverage_enabled", false)
		return
	for key in ["field", "metrics", "phase", "warp", "jacobian", "origin", "extent", "warp_origin", "warp_extent", "warp_detj_safe"]:
		_material.set_shader_parameter("coastal_%s" % key, _coastal_data[key])
	if not _optics_enabled: return
	_material.set_shader_parameter(&"optics_bathymetry_enabled", true)
	var seabed_enabled: bool = _coastal_data["seabed_coverage_enabled"]
	_material.set_shader_parameter(&"optics_real_seabed_coverage_enabled", seabed_enabled)
	if seabed_enabled:
		_material.set_shader_parameter(&"optics_real_seabed_coverage_texture", _coastal_data["seabed_coverage"])
		_material.set_shader_parameter(&"optics_real_seabed_coverage_origin", _coastal_data["seabed_origin"])
		_material.set_shader_parameter(&"optics_real_seabed_coverage_extent", _coastal_data["seabed_extent"])
		_material.set_shader_parameter(&"optics_seabed_sea_level", _coastal_data["seabed_sea_level"])


func set_crest_foam_enabled(enabled: bool) -> void:
	_material.set_shader_parameter(&"crest_foam_enabled", enabled)


func set_surface_foam(field: Texture2DRD, topology: Texture2DRD, mid_history: Texture2DRD, enabled: bool) -> void:
	_material.set_shader_parameter(&"surface_foam_enabled", enabled)
	_material.set_shader_parameter(&"crest_filigree_enabled", enabled)
	if enabled:
		_material.set_shader_parameter(&"surface_foam_field", field)
		_material.set_shader_parameter(&"surface_foam_topology", topology)
		_material.set_shader_parameter(&"surface_foam_mid_history", mid_history)


func shutdown() -> void:
	for level in _levels:
		if is_instance_valid(level): level.queue_free()
	_levels.clear()


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null: return
	global_position = Vector3(camera.global_position.x, _sea_level, camera.global_position.z)
	_material.set_shader_parameter(&"camera_world_xz", Vector2(camera.global_position.x, camera.global_position.z))
	if _surface_detail_enabled:
		_material.set_shader_parameter(&"ocean_time_s", Time.get_ticks_msec() * 0.001)
