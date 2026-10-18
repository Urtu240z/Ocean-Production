@tool
extends Node
## A second view of the SAME world. Never duplicate simulation or inherit the
## main camera's underwater compositor. Capture only above-water presentation.
var _surface: OceanClipmapSurface
var _profile: OceanReflectionProfile
var _sea_level := 0.0
var _source_override: Camera3D
var _viewport: SubViewport
var _camera: Camera3D
var _active := false
var _environment_source: Environment
var _capture_environment: Environment
var _frames := 0
const WATER_LAYER := 1 << 19
var _water_layers: Dictionary = {}
var _source_camera: Camera3D
var _source_mask := 0

func configure(surface: OceanClipmapSurface, ocean_level: float, profile: OceanReflectionProfile, camera_override: Camera3D = null) -> void:
	_surface = surface
	_source_override = camera_override
	update(ocean_level, profile)
	_viewport = SubViewport.new()
	_viewport.name = &"PlanarViewport"
	_viewport.disable_3d = false
	_viewport.use_hdr_2d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.name = &"MirroredCamera"
	_camera.compositor = Compositor.new()
	_viewport.add_child(_camera)
	_camera.current = true
	process_priority = 100

func update(ocean_level: float, profile: OceanReflectionProfile) -> void:
	_sea_level = ocean_level
	_profile = profile
	_capture_environment = null

func _invalidate_environment() -> void:
	_capture_environment = null

func set_runtime_active(value: bool) -> void:
	if _active == value:
		return
	_active = value
	if not value:
		_clear()

func _clear() -> void:
	_frames = 0
	_restore_layers()
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_surface):
		_surface.set_planar_reflection_state(false)
		_surface.set_reflection_texture(null, false)

func _restore_layers() -> void:
	for instance in _water_layers:
		if is_instance_valid(instance):
			instance.layers = _water_layers[instance]
	_water_layers.clear()
	if is_instance_valid(_source_camera):
		_source_camera.cull_mask = (_source_camera.cull_mask & ~WATER_LAYER) | (_source_mask & WATER_LAYER)
	_source_camera = null

func _isolate_water(source: Camera3D) -> void:
	if source != _source_camera:
		_restore_layers()
		_source_camera = source
		_source_mask = source.cull_mask
	# Layer 20 is reserved while planar is active. Excluding water before draw
	# submission avoids sampling a render target while it is being written.
	source.cull_mask |= WATER_LAYER
	for instance in _surface.find_children("*", "VisualInstance3D", true, false):
		if not _water_layers.has(instance):
			_water_layers[instance] = instance.layers
		instance.layers = WATER_LAYER

static func mirror_transform(source: Transform3D, level: float) -> Transform3D:
	var position := source.origin
	position.y = 2.0 * level - position.y
	var forward := -source.basis.z
	var up := source.basis.y
	forward.y = -forward.y
	up.y = -up.y
	# A camera needs a proper rotation: mirror its right axis, then project the
	# world position with this exact camera rather than assuming SCREEN_UV.
	return Transform3D(Basis.looking_at(forward, up), position)

func _process(_delta: float) -> void:
	if not _active or not is_instance_valid(_surface):
		return
	var source := _source_override if is_instance_valid(_source_override) else get_viewport().get_camera_3d()
	if not is_instance_valid(source) or source.global_position.y <= _sea_level + 0.05:
		_clear()
		return
	_viewport.world_3d = source.get_world_3d()
	_isolate_water(source)
	# Use physical render pixels, not the project's stretched logical UI size.
	var source_size: Vector2 = Vector2(source.get_viewport().get("size"))
	var target := Vector2i(maxi(16, roundi(source_size.x * _profile.planar_resolution_scale)), maxi(16, roundi(source_size.y * _profile.planar_resolution_scale)))
	if _viewport.size != target:
		_viewport.size = target
		_frames = 0
	_camera.keep_aspect = source.keep_aspect
	_camera.projection = source.projection
	_camera.fov = source.fov
	_camera.size = source.size
	_camera.frustum_offset = source.frustum_offset
	_camera.near = source.near
	_camera.far = source.far
	_camera.attributes = source.attributes
	_camera.cull_mask = source.cull_mask & _profile.planar_cull_mask & ~WATER_LAYER
	_camera.global_transform = mirror_transform(source.get_camera_transform(), _sea_level)
	var environment := source.environment if source.environment != null else source.get_world_3d().environment
	if environment != _environment_source or _capture_environment == null:
		if _environment_source != null and _environment_source.changed.is_connected(_invalidate_environment):
			_environment_source.changed.disconnect(_invalidate_environment)
		_environment_source = environment
		if _environment_source != null:
			_environment_source.changed.connect(_invalidate_environment)
		_capture_environment = environment.duplicate() as Environment if environment != null else Environment.new()
		_capture_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		_capture_environment.tonemap_exposure = 1.0
		_capture_environment.glow_enabled = false
		_capture_environment.ssr_enabled = false
		_capture_environment.adjustment_enabled = false
		_camera.environment = _capture_environment
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var view_projection := _camera.get_camera_projection() * Projection(_camera.global_transform.affine_inverse())
	_surface.set_planar_reflection_state(true, view_projection, _sea_level)
	# First frame must render before its texture can be advertised.
	if _frames > 0:
		_surface.set_reflection_texture(_viewport.get_texture(), true)
	_frames += 1

func get_state() -> Dictionary:
	return {"method": &"PLANAR", "active": _active, "target_size": _viewport.size if is_instance_valid(_viewport) else Vector2i.ZERO}

func shutdown() -> void:
	_active = false
	_clear()
	if _environment_source != null and _environment_source.changed.is_connected(_invalidate_environment):
		_environment_source.changed.disconnect(_invalidate_environment)
	_environment_source = null
	_capture_environment = null
	if is_instance_valid(_viewport):
		_viewport.queue_free()
	_viewport = null
	_camera = null
