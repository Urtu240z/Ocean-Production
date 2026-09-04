class_name OceanClipmapSurface
extends Node3D
## Presentación de las tres bandas P0. No conoce Coastal ni sistemas ópticos.

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
uniform float opacity_distance_end;
uniform float refraction_micro_normal_strength;
uniform float refraction_max_offset_px;
uniform float refraction_depth_tolerance_m;
uniform float refraction_wave_strength;
uniform float refraction_long_weight;
uniform float refraction_mid_weight;
uniform float refraction_short_weight;
uniform float refraction_depth_end_m;
uniform vec3 scattering_color : source_color;
uniform float scattering_strength;
uniform float shallow_scattering_strength;
uniform float water_turbidity;
uniform float crest_transmission_boost;
uniform float trough_density_boost;
uniform float transmission_detail_fade_start_m;
uniform float transmission_detail_fade_end_m;
uniform float transmission_max_lod;

float optics_linear_depth(vec2 uv, float raw_depth, mat4 inverse_projection) {
	vec4 view = inverse_projection * vec4(uv * 2.0 - 1.0, raw_depth, 1.0);
	return -view.z / max(view.w, 0.00001);
}
'''

const OPTICS_FRAGMENT := '''
	if (water_optics_enabled) {
		float raw_scene_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
		bool scene_depth_valid = raw_scene_depth > 0.000001 && raw_scene_depth <= 1.000001 && !isnan(raw_scene_depth) && !isinf(raw_scene_depth);
		float scene_depth_m = optics_linear_depth(SCREEN_UV, raw_scene_depth, INV_PROJECTION_MATRIX);
		float water_depth_m = optics_linear_depth(SCREEN_UV, FRAGCOORD.z, INV_PROJECTION_MATRIX);
		bool water_depth_valid = water_depth_m > 0.00001 && !isnan(water_depth_m) && !isinf(water_depth_m);
		float view_water_path_m = scene_depth_valid && water_depth_valid ? max(scene_depth_m - water_depth_m, 0.0) : maximum_optical_depth_above_m;
		float optical_depth_m = clamp(view_water_path_m, 0.0, maximum_optical_depth_above_m);
		float local_water_depth_m = maximum_optical_depth_above_m;
		float coastal_authority = 0.0;
		if (coastal_enabled) {
			vec2 coast_uv = coastal_uv(world_xz, coastal_origin, coastal_extent);
			if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
				vec4 metrics = texture(coastal_metrics, coast_uv);
				vec4 field = texture(coastal_field, coast_uv);
				coastal_authority = step(0.0, metrics.r) * field.a;
				local_water_depth_m = mix(local_water_depth_m, max(metrics.r, 0.0), coastal_authority);
				optical_depth_m = mix(optical_depth_m, min(optical_depth_m, max(metrics.r, 0.0) * 1.25), coastal_authority);
			}
		}
		vec3 transmittance_rgb = exp(-max(absorption_coeff_rgb, vec3(0.0)) * optical_depth_m);
		float body_depth_factor = smoothstep(water_body_depth_start_m, max(water_body_depth_end_m, water_body_depth_start_m + 0.001), local_water_depth_m);
		float crest_height = clamp(0.5 + (NORMAL.y - 0.5), 0.0, 1.0);
		vec3 body_color = mix(optics_shallow_water_color, optics_deep_water_color, body_depth_factor);
		body_color = mix(body_color, mix(optics_trough_tint, optics_crest_tint, crest_height), 0.24);
		float crest_mix = smoothstep(0.65, 1.0, crest_height) * clamp(crest_transmission_boost, 0.0, 0.5);
		vec3 effective_transmittance = mix(transmittance_rgb, sqrt(max(transmittance_rgb, vec3(0.0))), crest_mix);
		float transmission_lod = clamp(smoothstep(transmission_detail_fade_start_m, max(transmission_detail_fade_end_m, transmission_detail_fade_start_m + 0.001), optical_depth_m) * transmission_max_lod, 0.0, 8.0);
		vec3 long_slope_normal = normalize(long_normal);
		vec3 mid_slope_normal = normalize(texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz);
		vec3 short_slope_normal = normalize(texture(normal_short, world_uv(world_xz, domain_short_m)).xyz);
		vec2 wave_slope = vec2(-long_slope_normal.x / max(long_slope_normal.y, 0.08), -long_slope_normal.z / max(long_slope_normal.y, 0.08)) * refraction_long_weight;
		wave_slope += vec2(-mid_slope_normal.x / max(mid_slope_normal.y, 0.08), -mid_slope_normal.z / max(mid_slope_normal.y, 0.08)) * refraction_mid_weight;
		wave_slope += vec2(-short_slope_normal.x / max(short_slope_normal.y, 0.08), -short_slope_normal.z / max(short_slope_normal.y, 0.08)) * refraction_short_weight;
		float refraction_depth_factor = 1.0 - smoothstep(0.0, max(refraction_depth_end_m, 0.001), optical_depth_m);
		vec2 screen_size = max(vec2(textureSize(screen_texture, 0)), vec2(1.0));
		vec2 offset_px = wave_slope * refraction_wave_strength * refraction_micro_normal_strength * refraction_depth_factor * 12.0;
		float offset_length = length(offset_px);
		if (offset_length > refraction_max_offset_px) offset_px *= refraction_max_offset_px / max(offset_length, 0.00001);
		vec2 candidate_uv = clamp(SCREEN_UV + offset_px / screen_size, vec2(0.001), vec2(0.999));
		float candidate_raw_depth = textureLod(depth_texture, candidate_uv, 0.0).r;
		float candidate_depth_m = optics_linear_depth(candidate_uv, candidate_raw_depth, INV_PROJECTION_MATRIX);
		bool candidate_valid = candidate_raw_depth > 0.000001 && candidate_raw_depth <= 1.000001 && candidate_depth_m > water_depth_m + 0.05;
		float closer_error = candidate_valid ? max(scene_depth_m - candidate_depth_m, 0.0) : refraction_depth_tolerance_m + 1.0;
		float refraction_validity = candidate_valid ? 1.0 - smoothstep(refraction_depth_tolerance_m, refraction_depth_tolerance_m + 0.25, closer_error) : 0.0;
		vec2 refracted_uv = mix(SCREEN_UV, candidate_uv, clamp(refraction_validity, 0.0, 1.0));
		vec3 refracted_scene = textureLod(screen_texture, refracted_uv, transmission_lod).rgb;
		float trough_density = 1.0 + (1.0 - smoothstep(0.0, 0.45, crest_height)) * clamp(trough_density_boost, 0.0, 0.5);
		float scattering_response = 1.0 - exp(-0.22 * clamp(water_turbidity, 0.0, 2.0) * optical_depth_m);
		float scattering_share = clamp(scattering_response * scattering_strength * 0.35, 0.0, 0.45);
		vec3 absorbed = vec3(1.0) - effective_transmittance;
		vec3 body_component = body_color * absorbed * (1.0 - scattering_share) * trough_density;
		vec3 scattering_component = scattering_color * absorbed * scattering_share * trough_density;
		float shallow_factor = coastal_authority * (1.0 - body_depth_factor);
		scattering_component += scattering_color * shallow_factor * shallow_scattering_strength * scattering_strength * 0.12;
		float distance_opacity = smoothstep(80.0, max(opacity_distance_end, 80.001), distance_m);
		vec3 surface_color = mix(body_color, optics_horizon_water_color, distance_opacity);
		float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
		vec3 optical_scene = refracted_scene * effective_transmittance + body_component + scattering_component;
		ALBEDO = mix(optical_scene, surface_color, fresnel + (1.0 - fresnel) * distance_opacity);
	}
'''

var _material := ShaderMaterial.new()
var _levels: Array[MeshInstance3D] = []
var _sea_level := 0.0
var _quality: Resource
var _optics_shader: Shader


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
	for key in ["absorption_coeff_rgb", "maximum_optical_depth_above_m", "water_body_depth_start_m", "water_body_depth_end_m", "opacity_distance_end", "refraction_micro_normal_strength", "refraction_max_offset_px", "refraction_depth_tolerance_m", "refraction_wave_strength", "refraction_long_weight", "refraction_mid_weight", "refraction_short_weight", "refraction_depth_end_m", "scattering_color", "scattering_strength", "shallow_scattering_strength", "water_turbidity", "crest_transmission_boost", "trough_density_boost", "transmission_detail_fade_start_m", "transmission_detail_fade_end_m", "transmission_max_lod"]:
		_material.set_shader_parameter(key, values.get(key))


func set_coastal_data(data: Dictionary) -> void:
	var active := not data.is_empty()
	_material.set_shader_parameter(&"coastal_enabled", active)
	if not active: return
	for key in ["field", "metrics", "phase", "warp", "jacobian", "origin", "extent", "warp_origin", "warp_extent", "warp_detj_safe"]:
		_material.set_shader_parameter("coastal_%s" % key, data[key])


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
