class_name OceanClipmapSurface
extends Node3D
## Presentación de las tres bandas P0. No conoce Coastal ni sistemas ópticos.

const MeshBuilder := preload("res://addons/ocean/surface/ocean_clipmap_mesh_builder.gd")
const SURFACE_SHADER := preload("res://addons/ocean/shaders/ocean_surface.gdshader")
const CREST_BREAKUP_NOISE := preload("res://addons/ocean/surface/crest_breakup_noise.tres")

var _material := ShaderMaterial.new()
var _levels: Array[MeshInstance3D] = []
var _sea_level := 0.0
var _quality: Resource


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


func set_coastal_data(data: Dictionary) -> void:
	var active := not data.is_empty()
	_material.set_shader_parameter(&"coastal_enabled", active)
	if not active: return
	for key in ["field", "metrics", "phase", "warp", "jacobian", "origin", "extent", "warp_origin", "warp_extent", "warp_detj_safe"]:
		_material.set_shader_parameter("coastal_%s" % key, data[key])


func set_crest_foam_enabled(enabled: bool) -> void:
	_material.set_shader_parameter(&"crest_foam_enabled", enabled)


func shutdown() -> void:
	for level in _levels:
		if is_instance_valid(level): level.queue_free()
	_levels.clear()


func _process(_delta: float) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null: return
	global_position = Vector3(camera.global_position.x, _sea_level, camera.global_position.z)
	_material.set_shader_parameter(&"camera_world_xz", Vector2(camera.global_position.x, camera.global_position.z))
