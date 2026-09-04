class_name OceanClipmapSurface
extends Node3D
## Presentación de las tres bandas P0-P4. Integra sus variantes de material,
## pero no posee los datos Coastal ni el estado/compute de los sistemas ópticos.

const MeshBuilder := preload("res://addons/ocean/surface/ocean_clipmap_mesh_builder.gd")
const SURFACE_SHADER := preload("res://addons/ocean/shaders/ocean_surface.gdshader")
const CREST_BREAKUP_NOISE := preload("res://addons/ocean/surface/crest_breakup_noise.tres")
const OpticsProfile := preload("res://addons/ocean/core/ocean_optics_profile.gd")
const OPTICS_UNIFORMS_MARKER := "// P4_OPTICS_UNIFORMS"
const OPTICS_FRAGMENT_MARKER := "// P4_OPTICS_FRAGMENT"

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
		float crest_height = clamp(0.5 + (NORMAL.y - 0.5), 0.0, 1.0);
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
		vec3 base_normal_view = normalize(mat3(VIEW_MATRIX) * NORMAL);
		vec3 wave_normal_view = normalize(mat3(VIEW_MATRIX) * normalize(vec3(-wave_slope.x, 1.0, -wave_slope.y)));
		float grazing_confidence = smoothstep(0.18, 0.58, clamp(abs(dot(wave_normal_view, normalize(-water_view_position))), 0.0, 1.0));
		vec3 refraction_normal_view = normalize(mix(base_normal_view, wave_normal_view, clamp(refraction_wave_strength * refraction_depth_factor * grazing_confidence, 0.0, 1.0)));
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
		float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
		vec3 optical_scene = refracted_scene * effective_transmittance * seabed_transmission_weight + body_component + scattering_component;
		float shallow_relief = clamp(shallow_fresnel_relief, 0.0, 1.0) * real_seabed_coverage * (1.0 - smoothstep(shallow_fresnel_depth_start_m, max(shallow_fresnel_depth_end_m, shallow_fresnel_depth_start_m + 0.001), local_water_depth_m));
		float surface_weight = fresnel + (1.0 - fresnel) * distance_opacity * (1.0 - shallow_relief);
		ALBEDO = mix(optical_scene, surface_color, surface_weight);
	}
'''

var _material := ShaderMaterial.new()
var _levels: Array[MeshInstance3D] = []
var _sea_level := 0.0
var _quality: Resource
var _optics_shader: Shader
var _coastal_data := {}
var _coastal_waves_enabled := false


func initialize(quality: Resource, sea_level: float, configs: Array, displacements: Array[Texture2DRD], normals: Array[Texture2DRD], crest_foams: Array[Texture2DRD]) -> void:
	shutdown()
	assert(configs.size() == 3 and displacements.size() == 3 and normals.size() == 3 and crest_foams.size() == 3)
	_quality = quality
	_sea_level = sea_level
	_material.shader = SURFACE_SHADER
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
	if not enabled:
		_material.shader = SURFACE_SHADER
		return
	if _optics_shader == null:
		_optics_shader = Shader.new()
		_optics_shader.code = SURFACE_SHADER.code.replace(OPTICS_UNIFORMS_MARKER, OPTICS_UNIFORMS_MARKER + OPTICS_UNIFORMS).replace(OPTICS_FRAGMENT_MARKER, OPTICS_FRAGMENT)
	_material.shader = _optics_shader
	var values: Resource = profile
	if values == null or not values.has_method(&"get"):
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


func set_coastal_data(data: Dictionary, waves_enabled := true) -> void:
	_coastal_data = data
	_coastal_waves_enabled = waves_enabled
	_apply_coastal_data()


func _apply_coastal_data() -> void:
	var active := not _coastal_data.is_empty()
	_material.set_shader_parameter(&"coastal_enabled", active and _coastal_waves_enabled)
	if not active:
		if _material.shader == _optics_shader:
			_material.set_shader_parameter(&"optics_bathymetry_enabled", false)
			_material.set_shader_parameter(&"optics_real_seabed_coverage_enabled", false)
		return
	for key in ["field", "metrics", "phase", "warp", "jacobian", "origin", "extent", "warp_origin", "warp_extent", "warp_detj_safe"]:
		_material.set_shader_parameter("coastal_%s" % key, _coastal_data[key])
	if _material.shader != _optics_shader: return
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
