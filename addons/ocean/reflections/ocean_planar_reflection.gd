@tool
extends Node
const CLIP_GEOMETRY := preload("res://addons/ocean/reflections/ocean_planar_clip_geometry.gd")
var _clip_geometry := CLIP_GEOMETRY.new()
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
var _kawase: Node
var _water_layers: Dictionary = {}
var _camera_masks: Dictionary = {}
var _layer_groups: Dictionary = {}
var _managed_mask := 0
var _scan_elapsed := 1.0
var _capture_elapsed := 1.0
var _fresh_frame := -1
var _last_source: Camera3D
var _last_world: World3D
var _last_transform := Transform3D.IDENTITY
var _view_projection := Projection()
var _reason := &"INACTIVE"
var _captures := 0
var _skips := 0
var _excluded_count := 0
var _warned_conflict := false
var _scene_cameras: Array[Camera3D] = []
var _scene_lights: Array[Light3D] = []
var _light_masks: Dictionary = {}
var _capture_configuration: Array = []
var _source_projection := Projection()
var _attributes_source: CameraAttributes
var _capture_attributes: CameraAttributes
var _distortion_uv_scale := Vector2.ONE
var _scene_visuals: Array[VisualInstance3D] = []
var _registry_ready := false
var _layer_updates := 0
## Optional diagnostic sink; disabled during normal use.
var diagnostic_metrics: RefCounted

func configure(surface: OceanClipmapSurface, ocean_level: float, profile: OceanReflectionProfile, camera_override: Camera3D = null, kawase: Node = null) -> void:
	_surface = surface
	_kawase = kawase
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
	get_tree().node_added.connect(_scene_node_added)
	process_priority = 100

func _scene_node_added(node: Node) -> void:
	if node == _camera: return
	if node is VisualInstance3D and not _scene_visuals.has(node): _scene_visuals.append(node)
	if node is Camera3D and not _scene_cameras.has(node): _scene_cameras.append(node)
	if node is Light3D and not _scene_lights.has(node): _scene_lights.append(node)
	if node is Camera3D or node is VisualInstance3D:
		_scan_elapsed = 1.0

func update(ocean_level: float, profile: OceanReflectionProfile) -> void:
	_sea_level = ocean_level
	_profile = profile
	_scan_elapsed = 1.0
	var configuration: Array = [ocean_level, profile.planar_cull_mask, profile.planar_water_layer, profile.planar_resolution_scale, profile.planar_update_fps, profile.planar_visibility_culling, profile.planar_exclude_submerged, profile.planar_exclude_group, profile.planar_clip_group, profile.planar_silhouette_mode, profile.planar_disable_expensive_effects, profile.planar_overscan]
	if configuration != _capture_configuration:
		_capture_configuration = configuration
		_capture_environment = null
		_capture_attributes = null
		_capture_elapsed = 1.0
		_invalidate_capture()

func _invalidate_capture() -> void:
	_fresh_frame = -1
	if _kawase != null: _kawase.pause()
	if is_instance_valid(_surface): _surface.set_reflection_texture(null, false)

func _invalidate_environment() -> void:
	_capture_environment = null

func _invalidate_attributes() -> void:
	_capture_attributes = null

func _cheap_effects() -> bool:
	return _profile.planar_silhouette_mode or _profile.planar_disable_expensive_effects

static func capture_size(source_size: Vector2, scale: float) -> Vector2i:
	# SubViewport requires >=2 pixels. Apply one minimum scale to both axes,
	# rather than stretching a 19x11 reflection into the old 19x16 minimum.
	var effective := maxf(clampf(scale, 0.01, 1.0), 2.0 / maxf(minf(source_size.x, source_size.y), 1.0))
	return Vector2i(maxi(2, roundi(source_size.x * effective)), maxi(2, roundi(source_size.y * effective)))

func _sync_attributes(source: Camera3D) -> void:
	var original: CameraAttributes = source.attributes if source.attributes != null else source.get_world_3d().camera_attributes
	if not _cheap_effects():
		_camera.attributes = source.attributes
		return
	if original != _attributes_source or _capture_attributes == null:
		if _attributes_source != null and _attributes_source.changed.is_connected(_invalidate_attributes):
			_attributes_source.changed.disconnect(_invalidate_attributes)
		_attributes_source = original
		if original != null: original.changed.connect(_invalidate_attributes)
		_capture_attributes = original.duplicate() as CameraAttributes if original != null else CameraAttributesPractical.new()
		_capture_attributes.auto_exposure_enabled = false
		# This disables DOF on the private attributes RID, including Physical
		# attributes, while retaining their physical FOV and fixed exposure.
		RenderingServer.camera_attributes_set_dof_blur(_capture_attributes.get_rid(), false, 10.0, 1.0, false, 1.0, 1.0, 0.0)
	_camera.attributes = _capture_attributes

func set_runtime_active(value: bool) -> void:
	if _active == value:
		return
	_active = value
	if not value:
		_clear()

func _clear(reason: StringName = &"INACTIVE") -> void:
	_reason = reason
	_invalidate_capture()
	if _kawase != null:
		_kawase.pause()
	_restore_layers()
	_clip_geometry.restore()
	_scan_elapsed = 1.0
	_capture_elapsed = 1.0
	if is_instance_valid(_viewport):
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_surface):
		_surface.set_planar_reflection_state(false)
		_surface.set_reflection_texture(null, false)

func _restore_layers() -> void:
	for instance in _water_layers:
		if is_instance_valid(instance):
			if instance.layers == int(_layer_groups.get(_water_layers[instance], 0)):
				instance.layers = _water_layers[instance]
	_water_layers.clear()
	for camera in _camera_masks:
		if is_instance_valid(camera):
			camera.cull_mask = (camera.cull_mask & ~_managed_mask) | (int(_camera_masks[camera]) & _managed_mask)
	_camera_masks.clear()
	for light in _light_masks:
		if is_instance_valid(light):
			light.light_cull_mask = (light.light_cull_mask & ~_managed_mask) | (int(_light_masks[light]) & _managed_mask)
	_light_masks.clear()
	_layer_groups.clear()
	_managed_mask = 0

func _original_camera_mask(source: Camera3D) -> int:
	return (source.cull_mask & ~_managed_mask) | (int(_camera_masks.get(source, source.cull_mask)) & _managed_mask)

func _is_excluded(instance: VisualInstance3D) -> bool:
	if _profile.planar_silhouette_mode and instance is Light3D: return true
	if _cheap_effects() and (instance is GPUParticles3D or instance is CPUParticles3D or instance is FogVolume or instance is Decal or instance is ReflectionProbe or instance is VoxelGI): return true
	if _profile.planar_exclude_group != &"":
		var parent: Node = instance
		while parent != null:
			if parent.is_in_group(_profile.planar_exclude_group): return true
			parent = parent.get_parent()
	if _profile.planar_exclude_submerged and instance is GeometryInstance3D:
		var local_bounds: AABB = instance.custom_aabb if instance.custom_aabb.has_volume() else instance.get_aabb()
		var bounds: AABB = (instance.global_transform * local_bounds).grow(instance.extra_cull_margin)
		return bounds.end.y < _sea_level - 0.02
	return false

func _isolate_water(source: Camera3D) -> bool:
	if not _registry_ready:
		_scene_visuals.clear()
		_scene_cameras.clear()
		_scene_lights.clear()
		for node in get_tree().root.find_children("*", "Node", true, false): _scene_node_added(node)
		_registry_ready = true
	var candidates: Array[VisualInstance3D] = []
	var candidate_set: Dictionary = {}
	var occupied := 0
	_excluded_count = 0
	for index in range(_scene_visuals.size() - 1, -1, -1):
		var instance := _scene_visuals[index]
		if not is_instance_valid(instance):
			_scene_visuals.remove_at(index)
			continue
		if not instance.is_inside_tree() or instance.get_world_3d() != source.get_world_3d(): continue
		if _surface.is_ancestor_of(instance):
			candidates.push_front(instance)
			candidate_set[instance] = true
		elif _is_excluded(instance):
			candidates.append(instance)
			candidate_set[instance] = true
			_excluded_count += 1
		else: occupied |= int(_water_layers.get(instance, instance.layers))
	var explicit_bit := 1 << (_profile.planar_water_layer - 1) if _profile.planar_water_layer > 0 else 0
	if explicit_bit != 0 and (occupied & explicit_bit) != 0: return false
	# Ordinary frames retain all assignments. Reallocation is only a recovery
	# path for a newly occupied managed layer or an explicit layer change.
	if (occupied & _managed_mask) != 0 or (explicit_bit != 0 and not _layer_groups.is_empty() and int(_layer_groups.values()[0]) != explicit_bit):
		_restore_layers()
	for instance in _water_layers.keys():
		if not is_instance_valid(instance):
			_water_layers.erase(instance)
		elif not candidate_set.has(instance) or instance.layers != int(_layer_groups.get(_water_layers[instance], 0)):
			if instance.layers == int(_layer_groups.get(_water_layers[instance], 0)): instance.layers = _water_layers[instance]
			_water_layers.erase(instance)
			_layer_updates += 1
	# Reclaim groups whose last object left, including the original visibility
	# bits on every camera/light before those bits can be reused.
	for original in _layer_groups.keys():
		if _water_layers.values().has(original): continue
		var released: int = _layer_groups[original]
		for camera in _camera_masks:
			if is_instance_valid(camera): camera.cull_mask = (camera.cull_mask & ~released) | (int(_camera_masks[camera]) & released)
		for light in _light_masks:
			if is_instance_valid(light): light.light_cull_mask = (light.light_cull_mask & ~released) | (int(_light_masks[light]) & released)
		_layer_groups.erase(original)
		_managed_mask &= ~released
	for instance in candidates:
		var original: int = _water_layers.get(instance, instance.layers)
		if not _layer_groups.has(original):
			var bit := explicit_bit if _layer_groups.is_empty() else 0
			if bit == 0:
				for layer in range(19, -1, -1):
					if ((occupied | _managed_mask) & (1 << layer)) == 0:
						bit = 1 << layer
						break
			if bit == 0: return false
			_layer_groups[original] = bit
			_managed_mask |= bit
		if not _water_layers.has(instance):
			_water_layers[instance] = original
			_layer_updates += 1
	# Allocate every layer before changing any geometry.
	for instance in candidates:
		var assigned: int = _layer_groups[_water_layers[instance]]
		if instance.layers != assigned: instance.layers = assigned
	_sync_cameras(source)
	_clip_geometry.scan(_scene_visuals, source.get_world_3d(), _profile.planar_clip_group, _surface)
	_scan_elapsed = 0.0
	return true

func _sync_cameras(source: Camera3D) -> void:
	for camera in _scene_cameras:
		if not is_instance_valid(camera) or camera == _camera or not camera.is_inside_tree() or camera.get_world_3d() != source.get_world_3d(): continue
		var original := _original_camera_mask(camera)
		if not _camera_masks.has(camera): _camera_masks[camera] = original
		var bits := 0
		for mask in _layer_groups:
			if (original & int(mask)) != 0: bits |= int(_layer_groups[mask])
		var mapped := (original & ~_managed_mask) | bits
		if camera.cull_mask != mapped: camera.cull_mask = mapped
	for light in _scene_lights:
		if not is_instance_valid(light) or not light.is_inside_tree() or light.get_world_3d() != source.get_world_3d(): continue
		var original := (light.light_cull_mask & ~_managed_mask) | (int(_light_masks.get(light, light.light_cull_mask)) & _managed_mask)
		if not _light_masks.has(light): _light_masks[light] = original
		var bits := 0
		for mask in _layer_groups:
			if (original & int(mask)) != 0: bits |= int(_layer_groups[mask])
		var mapped := (original & ~_managed_mask) | bits
		if light.light_cull_mask != mapped: light.light_cull_mask = mapped

func _water_visible(source: Camera3D) -> bool:
	if not _surface.is_visible_in_tree(): return false
	var mask := _original_camera_mask(source)
	var planes := source.get_frustum()
	var inverse := source.get_camera_projection().inverse()
	var camera_transform := source.get_camera_transform()
	var minimum_y := INF
	var maximum_y := -INF
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var corner := inverse * Vector4(x, y, z, 1.0)
				if absf(corner.w) < 0.0000001: continue
				var world := camera_transform * (Vector3(corner.x, corner.y, corner.z) / corner.w)
				minimum_y = minf(minimum_y, world.y)
				maximum_y = maxf(maximum_y, world.y)
	for node in _surface.find_children("*", "VisualInstance3D", true, false):
		var instance := node as VisualInstance3D
		if not instance.is_visible_in_tree() or (int(_water_layers.get(instance, instance.layers)) & mask) == 0: continue
		var local_bounds := instance.get_aabb()
		if instance is GeometryInstance3D and instance.custom_aabb.has_volume(): local_bounds = instance.custom_aabb
		var bounds: AABB = instance.global_transform * local_bounds
		bounds = bounds.grow(instance.extra_cull_margin if instance is GeometryInstance3D else 0.0)
		# A huge ocean AABB may intersect each frustum plane independently even
		# when the entire frustum points above the sea. Reject its vertical slab.
		if minimum_y > bounds.end.y or maximum_y < bounds.position.y: continue
		var center := bounds.get_center()
		var half := bounds.size * 0.5
		var outside := false
		for plane in planes:
			if plane.distance_to(center) > plane.normal.abs().dot(half):
				outside = true
				break
		if not outside: return true
	return false

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

func _process(delta: float) -> void:
	if diagnostic_metrics == null:
		_process_profile_body(delta)
		return
	var started := Time.get_ticks_usec()
	var before := _captures
	_process_profile_body(delta)
	diagnostic_metrics.record(&"planar.cpu", Time.get_ticks_usec()-started)
	diagnostic_metrics.record(&"planar.capture", 0, _captures-before)

func _process_profile_body(delta: float) -> void:
	if not _active or not is_instance_valid(_surface):
		return
	_scan_elapsed += delta
	_capture_elapsed += delta
	var source := _source_override if is_instance_valid(_source_override) else get_viewport().get_camera_3d()
	if not is_instance_valid(source) or source.global_position.y <= _sea_level + 0.05:
		_clear(&"NO_CAMERA_OR_UNDERWATER")
		return
	if _profile.planar_visibility_culling and not _water_visible(source):
		_skips += 1
		_clear(&"WATER_NOT_VISIBLE")
		return
	if source != _last_source or source.get_world_3d() != _last_world:
		_invalidate_capture()
		_capture_environment = null
		_scan_elapsed = 1.0
		_capture_elapsed = 1.0
		_last_source = source
		if _last_world != source.get_world_3d():
			_restore_layers()
			_clip_geometry.restore()
			_registry_ready = false
		_last_world = source.get_world_3d()
	_viewport.world_3d = source.get_world_3d()
	if _scan_elapsed >= 0.5 and not _isolate_water(source):
		_clear(&"LAYER_CONFLICT")
		if not _warned_conflict:
			push_warning("Planar capture suspended: no conflict-free render layer. Choose Auto or an unused Planar Water Layer.")
			_warned_conflict = true
		return
	_sync_cameras(source)
	# Use physical render pixels, not the project's stretched logical UI size.
	var source_size: Vector2 = Vector2(source.get_viewport().get("size"))
	var target := capture_size(source_size, _profile.planar_resolution_scale)
	# SSAO/SSIL allocate five mip levels; keep their smallest axis valid.
	if not _cheap_effects() and mini(target.x, target.y) < 16:
		target = capture_size(source_size, maxf(_profile.planar_resolution_scale, 16.0 / minf(source_size.x, source_size.y)))
	if _viewport.size != target:
		_invalidate_capture()
		_viewport.size = target
		_capture_elapsed = 1.0
	var transform := source.get_camera_transform()
	if transform.origin.distance_to(_last_transform.origin) > 32.0 or transform.basis.z.angle_to(_last_transform.basis.z) > deg_to_rad(35.0) or source.get_camera_projection() != _source_projection:
		_invalidate_capture()
		_capture_elapsed = 1.0
	if _profile.planar_update_fps > 0.0 and _fresh_frame >= 0 and _capture_elapsed < 1.0 / _profile.planar_update_fps:
		_skips += 1
		_reason = &"THROTTLED"
		_publish()
		return
	# Assigning inherited Physical attributes also writes Camera3D FOV/near/far.
	# A world-level Physical resource controls exposure on the source, not its
	# lens. Restore the source lens AFTER assigning the private capture attributes.
	_sync_attributes(source)
	_camera.keep_aspect = source.keep_aspect
	_camera.projection = source.projection
	_camera.fov = source.fov
	_camera.size = source.size
	_camera.frustum_offset = source.frustum_offset
	_camera.near = source.near
	_camera.far = source.far
	# Expand the tangent, not the angle: this adds the same proportional border
	# on all sides. More coverage at the existing target size, not more pixels.
	var overscan := _profile.planar_overscan
	if source.projection == Camera3D.PROJECTION_PERSPECTIVE:
		_camera.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(source.fov) * 0.5) * overscan))
	else:
		_camera.size = source.size * overscan
	var capture_projection := _camera.get_camera_projection()
	var source_projection := source.get_camera_projection()
	_distortion_uv_scale = Vector2(capture_projection.x.x / source_projection.x.x, capture_projection.y.y / source_projection.y.y)
	_viewport.debug_draw = Viewport.DEBUG_DRAW_UNSHADED if _profile.planar_silhouette_mode else Viewport.DEBUG_DRAW_DISABLED
	_viewport.positional_shadow_atlas_size = 0 if _profile.planar_silhouette_mode else 2048
	_viewport.mesh_lod_threshold = 4.0 if _cheap_effects() else 1.0
	_camera.cull_mask = _original_camera_mask(source) & _profile.planar_cull_mask & ~_managed_mask
	_camera.global_transform = mirror_transform(transform, _sea_level)
	_clip_geometry.set_plane(_camera.global_position, _sea_level + 0.02)
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
		if _cheap_effects():
			_capture_environment.ssao_enabled = false
			_capture_environment.ssil_enabled = false
			_capture_environment.sdfgi_enabled = false
			_capture_environment.fog_enabled = false
			_capture_environment.volumetric_fog_enabled = false
		_camera.environment = _capture_environment
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_view_projection = _camera.get_camera_projection() * Projection(_camera.global_transform.affine_inverse())
	_last_transform = transform
	_source_projection = source.get_camera_projection()
	if _fresh_frame < 0: _fresh_frame = Engine.get_frames_drawn() + 1
	_capture_elapsed = 0.0
	_captures += 1
	_reason = &"CAPTURING"
	_publish()

func _publish() -> void:
	_surface.set_planar_reflection_state(true, _view_projection, _sea_level, _viewport.get_texture(), _distortion_uv_scale)
	# First frame must render before its texture can be advertised.
	if _fresh_frame >= 0 and Engine.get_frames_drawn() >= _fresh_frame:
		var texture: Texture2D = _viewport.get_texture()
		if _kawase != null:
			texture = _kawase.filter_texture(texture, _viewport.size, _captures)
		_surface.set_reflection_texture(texture, true)

func get_state() -> Dictionary:
	return {"method": &"PLANAR", "active": _active, "status": _reason, "target_size": _viewport.size if is_instance_valid(_viewport) else Vector2i.ZERO, "captures": _captures, "skipped": _skips, "managed_layer_mask": _managed_mask, "camera_count": _camera_masks.size(), "excluded_objects": _excluded_count, "clip_geometry": _clip_geometry.get_state(), "silhouette_mode": _profile.planar_silhouette_mode, "expensive_effects_disabled": _cheap_effects(), "shadow_draw_calls": _viewport.get_render_info(Viewport.RENDER_INFO_TYPE_SHADOW, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME) if is_instance_valid(_viewport) else 0}

func shutdown() -> void:
	_active = false
	_clear()
	if is_inside_tree() and get_tree().node_added.is_connected(_scene_node_added): get_tree().node_added.disconnect(_scene_node_added)
	if _environment_source != null and _environment_source.changed.is_connected(_invalidate_environment):
		_environment_source.changed.disconnect(_invalidate_environment)
	_environment_source = null
	_capture_environment = null
	if _attributes_source != null and _attributes_source.changed.is_connected(_invalidate_attributes):
		_attributes_source.changed.disconnect(_invalidate_attributes)
	_attributes_source = null
	_capture_attributes = null
	if is_instance_valid(_viewport):
		_viewport.queue_free()
	_viewport = null
	_camera = null
