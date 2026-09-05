@tool
class_name OceanWaterlineRaster
extends Node
## Isolated 3D raster targets for P6. The game camera is read, never changed.

const WATERLINE_LAYER := 1
const MASK_MODE := 1
const DEPTH_MODE := 2
const HORIZON_SHADER := preload("res://addons/ocean/underwater/shaders/ocean_waterline_horizon.gdshader")

var _surface: OceanClipmapSurface
var _mask_viewport: SubViewport
var _depth_viewport: SubViewport
var _mask_camera: Camera3D
var _depth_camera: Camera3D
var _mask_root: Node3D
var _depth_root: Node3D
var _mask_material: ShaderMaterial
var _depth_material: ShaderMaterial
var _horizon_material: ShaderMaterial
var _sea_level := 0.0
var _targets_need_republication := true


func configure(surface: OceanClipmapSurface, sea_level: float) -> bool:
	if surface == null or not is_instance_valid(surface):
		return false
	_sea_level = sea_level
	if _surface == surface and _mask_viewport != null and _depth_viewport != null:
		_set_horizon_sea_level()
		return true
	shutdown()
	_surface = surface
	_mask_viewport = _create_viewport("OceanP6WaterlineMask", Color.BLACK)
	_depth_viewport = _create_viewport("OceanP6WaterlineDepth", Color.BLACK)
	add_child(_mask_viewport)
	add_child(_depth_viewport)
	_mask_camera = _create_camera()
	_depth_camera = _create_camera()
	_mask_viewport.add_child(_mask_camera)
	_depth_viewport.add_child(_depth_camera)
	_mask_viewport.add_child(_create_horizon_fill())
	var mask_clone := _surface.create_waterline_raster_clone(MASK_MODE, WATERLINE_LAYER)
	var depth_clone := _surface.create_waterline_raster_clone(DEPTH_MODE, WATERLINE_LAYER)
	_mask_root = mask_clone.get("root") as Node3D
	_depth_root = depth_clone.get("root") as Node3D
	_mask_material = mask_clone.get("material") as ShaderMaterial
	_depth_material = depth_clone.get("material") as ShaderMaterial
	if _mask_root == null or _depth_root == null or _mask_material == null or _depth_material == null:
		shutdown()
		return false
	_mask_viewport.add_child(_mask_root)
	_depth_viewport.add_child(_depth_root)
	set_process(true)
	_targets_need_republication = true
	_sync_from_visible_surface()
	return true


func get_target_rids() -> Dictionary:
	# The Viewport owns both color targets and their 3D depth attachments. The
	# depth color target contains the exact rasterized FRAGCOORD.z for sampling
	# in the compositor; no CPU readback occurs.
	if _mask_viewport == null or _depth_viewport == null:
		return {}
	var mask_texture := _mask_viewport.get_texture()
	var depth_texture := _depth_viewport.get_texture()
	if mask_texture == null or depth_texture == null:
		return {}
	var mask_rid := RenderingServer.texture_get_rd_texture(mask_texture.get_rid())
	var depth_rid := RenderingServer.texture_get_rd_texture(depth_texture.get_rid())
	if not mask_rid.is_valid() or not depth_rid.is_valid():
		return {}
	return {"mask": mask_rid, "depth": depth_rid}


func set_sea_level(value: float) -> void:
	_sea_level = value
	_set_horizon_sea_level()


func targets_need_republication() -> bool:
	return _targets_need_republication


func mark_targets_published() -> void:
	_targets_need_republication = false


func shutdown() -> void:
	set_process(false)
	for viewport in [_mask_viewport, _depth_viewport]:
		if viewport != null and is_instance_valid(viewport):
			viewport.queue_free()
	_mask_viewport = null
	_depth_viewport = null
	_mask_camera = null
	_depth_camera = null
	_mask_root = null
	_depth_root = null
	_mask_material = null
	_depth_material = null
	_horizon_material = null
	_surface = null
	_targets_need_republication = true


func _process(_delta: float) -> void:
	_sync_from_visible_surface()


func _create_viewport(viewport_name: String, clear_color: Color) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.name = viewport_name
	viewport.size = Vector2i(1, 1)
	viewport.own_world_3d = true
	viewport.transparent_bg = false
	viewport.use_hdr_2d = true
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = clear_color
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world_environment.environment = environment
	viewport.add_child(world_environment)
	return viewport


func _create_camera() -> Camera3D:
	var camera := Camera3D.new()
	camera.name = "OceanWaterlineRasterCamera"
	camera.current = true
	camera.cull_mask = WATERLINE_LAYER
	return camera


func _create_horizon_fill() -> MeshInstance3D:
	var fill := MeshInstance3D.new()
	fill.name = "OceanWaterlineHorizon"
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	fill.mesh = mesh
	_horizon_material = ShaderMaterial.new()
	_horizon_material.shader = HORIZON_SHADER
	fill.material_override = _horizon_material
	fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fill.layers = WATERLINE_LAYER
	_set_horizon_sea_level()
	return fill


func _sync_from_visible_surface() -> void:
	if _surface == null or not is_instance_valid(_surface):
		return
	var source_camera := _surface.get_viewport().get_camera_3d()
	if source_camera == null:
		return
	_sync_viewport_size(_mask_viewport, source_camera.get_viewport())
	_sync_viewport_size(_depth_viewport, source_camera.get_viewport())
	_sync_camera(_mask_camera, source_camera)
	_sync_camera(_depth_camera, source_camera)
	if _mask_root != null:
		_mask_root.global_transform = _surface.global_transform
	if _depth_root != null:
		_depth_root.global_transform = _surface.global_transform
	_surface.sync_waterline_raster_material(_mask_material, MASK_MODE)
	_surface.sync_waterline_raster_material(_depth_material, DEPTH_MODE)
	_set_horizon_sea_level()


func _set_horizon_sea_level() -> void:
	if _horizon_material != null:
		_horizon_material.set_shader_parameter(&"sea_level", _sea_level)


func _sync_viewport_size(viewport: SubViewport, source_viewport: Viewport) -> void:
	if viewport == null or source_viewport == null:
		return
	var source_size := source_viewport.get_visible_rect().size
	var target_size := Vector2i(maxi(1, roundi(source_size.x)), maxi(1, roundi(source_size.y)))
	if viewport.size != target_size:
		viewport.size = target_size
		_targets_need_republication = true


func _sync_camera(target: Camera3D, source: Camera3D) -> void:
	if target == null:
		return
	# This copies the active view into the isolated raster world. It never writes
	# to source, so there is no game Camera3D movement or projection mutation.
	target.global_transform = source.global_transform
	target.projection = source.projection
	target.keep_aspect = source.keep_aspect
	target.fov = source.fov
	target.size = source.size
	target.near = source.near
	target.far = source.far
	target.h_offset = source.h_offset
	target.v_offset = source.v_offset
	target.frustum_offset = source.frustum_offset
