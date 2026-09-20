@tool
class_name OceanCausticsManager
extends Node

const EFFECT_SCRIPT := preload("res://addons/ocean/underwater/caustics/ocean_caustics_effect.gd")
const COMPOSITOR_ATTACHMENT := preload("res://addons/ocean/core/ocean_compositor_attachment.gd")
const CAUSTICS_PROFILE_SCRIPT := preload("res://addons/ocean/core/ocean_caustics_profile.gd")
const CAUSTICS_TEXTURE_PATH := "res://addons/ocean/underwater/caustics/caustics_pattern_primary.png"
const CAUSTICS_TEXTURE_SCENE_PATH := "res://addons/ocean/underwater/caustics/caustics_pattern_secondary.png"
const CAUSTICS_TEXTURE_FALLBACK_PATH := "res://addons/ocean/underwater/caustics/caustics_filament_tile.png"
const CAUSTICS_LUMA_GRADIENT_PATH := "res://addons/ocean/underwater/caustics/luma_gradient.tres"

var _ocean: Node
var _effect: OceanCausticsEffect
var _compositor_attachment: RefCounted
var _compositor: Compositor
var _enabled := false
var _sea_level := 0.0
var _texture: Texture2D
var _source_luma_gradient: Texture2D
var _runtime_luma_texture: ImageTexture
var _scale := 4.0
var _speed := 0.1
var _strength := 1.0
var _power := 2.0
var _chroma_split := 0.002
var _layer_a_speed_multiplier := 0.75
var _layer_b_speed_multiplier := 1.0
var _layer_a_scale_multiplier := 1.0
var _layer_b_scale_multiplier := -1.0
var _layer_a_direction := Vector2(1.0, 0.0)
var _layer_b_direction := Vector2(1.0, 0.0)
var _luminance_mask_strength := 0.2
var _sun_strength := 1.0
var _fade_start_depth_m := 4.0
var _max_depth_m := 6.0
var _debug_mode := 0
var _time := 0.0
var _sun_direction := Vector3(0.0, 1.0, 0.0)
var _explicit_sun_light: DirectionalLight3D
var _cached_sun_light: DirectionalLight3D
var _sun_resolution_attempted := false
var _attached := false
var _static_textures_ready := false
var _readiness_warning_reported := false


func configure(ocean: Node, sea_level: float, profile: OceanCausticsProfile,
		explicit_sun_light: DirectionalLight3D) -> void:
	_ocean = ocean
	_enabled = true
	_set_static_state(sea_level, profile, explicit_sun_light)
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	call_deferred(&"_initialize")


func set_settings(sea_level: float, profile: OceanCausticsProfile,
		explicit_sun_light: DirectionalLight3D) -> void:
	_enabled = true
	_set_static_state(sea_level, profile, explicit_sun_light)
	_push_static_settings()


func _set_static_state(sea_level: float, profile: OceanCausticsProfile,
		explicit_sun_light: DirectionalLight3D) -> void:
	_sea_level = sea_level
	var active_profile := profile
	if active_profile == null:
		active_profile = CAUSTICS_PROFILE_SCRIPT.new()
	_texture = _active_caustics_texture(active_profile.texture)
	_prepare_runtime_luma(_resolve_luma_source(active_profile.luma_gradient))
	_scale = active_profile.scale_m
	_speed = active_profile.speed
	_strength = active_profile.strength
	_power = active_profile.power
	_chroma_split = active_profile.chroma_split
	_layer_a_speed_multiplier = active_profile.layer_a_speed_multiplier
	_layer_b_speed_multiplier = active_profile.layer_b_speed_multiplier
	_layer_a_scale_multiplier = active_profile.layer_a_scale_multiplier
	_layer_b_scale_multiplier = active_profile.layer_b_scale_multiplier
	_layer_a_direction = active_profile.layer_a_direction
	_layer_b_direction = active_profile.layer_b_direction
	_luminance_mask_strength = active_profile.luminance_mask_strength
	_sun_strength = active_profile.sun_strength
	_fade_start_depth_m = active_profile.fade_start_depth_m
	_max_depth_m = active_profile.max_depth_m
	_debug_mode = active_profile.debug_mode
	if _explicit_sun_light != explicit_sun_light:
		_explicit_sun_light = explicit_sun_light
		_cached_sun_light = null
		_sun_resolution_attempted = false


func set_dynamic_state(wave_time: float, sun_direction: Vector3) -> void:
	_time = wave_time
	_sun_direction = sun_direction
	if _effect != null:
		_effect.set_dynamic_state(wave_time, sun_direction)


func _ready() -> void:
	if not Engine.is_editor_hint() and _ocean == null:
		_ocean = get_parent()
		call_deferred(&"_initialize")


func _process(_delta: float) -> void:
	if _effect == null or not _enabled:
		return
	_ensure_attachment()
	_activate_if_ready()
	_time = _read_ocean_time()
	_sun_direction = _read_sun_direction()
	_effect.set_dynamic_state(_time, _sun_direction)


func _push_static_settings() -> void:
	if _effect != null:
		_effect.enabled = false
		_effect.set_active(false)
		_static_textures_ready = _effect.set_settings(false, _sea_level, _texture, _runtime_luma_texture, _scale,
			_speed, _strength, _power, _chroma_split, _layer_a_speed_multiplier,
			_layer_b_speed_multiplier, _layer_a_scale_multiplier, _layer_b_scale_multiplier,
			_layer_a_direction, _layer_b_direction, _luminance_mask_strength, _sun_strength,
			_fade_start_depth_m, _max_depth_m, _sun_direction, _debug_mode)
		if not _static_textures_ready:
			if _compositor_attachment != null:
				_compositor_attachment.detach()
			_compositor_attachment = null
			_compositor = null
			_attached = false
			var status := _effect.get_texture_binding_status()
			var missing: PackedStringArray = []
			if not bool(status.get("pattern", false)):
				missing.append("caustics pattern")
			if not bool(status.get("luma", false)):
				missing.append("runtime luma gradient")
			_report_readiness_failure(", ".join(missing))
		if _static_textures_ready and _compositor_attachment == null:
			_compositor_attachment = COMPOSITOR_ATTACHMENT.new(self, _effect)
			_ensure_attachment()
		_activate_if_ready()


func _initialize() -> void:
	if _effect != null or not _enabled or Engine.is_editor_hint() or not is_inside_tree():
		return
	_effect = EFFECT_SCRIPT.new()
	_effect.set_dynamic_state(_time, _sun_direction)
	_push_static_settings()


func _ensure_attachment() -> void:
	if not _enabled or _effect == null or _compositor_attachment == null:
		return
	_attached = _compositor_attachment.ensure_attached()
	_compositor = _compositor_attachment.get_compositor()


func _activate_if_ready() -> void:
	if _effect == null:
		return
	var active := _enabled and _static_textures_ready and _attached
	_effect.set_active(active)
	_effect.enabled = active


func _read_ocean_time() -> float:
	if _ocean == null or not is_instance_valid(_ocean):
		return _time
	var open_ocean := _ocean.get_node_or_null(^"OpenOceanFFT")
	if open_ocean != null and open_ocean.has_method(&"get_wave_time"):
		return float(open_ocean.get_wave_time())
	return _time


func _read_sun_direction() -> Vector3:
	var light := _resolve_sun_light()
	if light != null:
		var direction := light.global_transform.basis.z.normalized()
		if direction.length_squared() > 0.000001:
			return direction
	return Vector3.UP


func _resolve_sun_light() -> DirectionalLight3D:
	if _explicit_sun_light != null:
		if is_instance_valid(_explicit_sun_light) and _explicit_sun_light.is_inside_tree():
			return _explicit_sun_light
		if _cached_sun_light == _explicit_sun_light:
			_cached_sun_light = null
			_sun_resolution_attempted = false
		elif _sun_resolution_attempted:
			return null
	if _cached_sun_light != null:
		if is_instance_valid(_cached_sun_light) and _cached_sun_light.is_inside_tree():
			return _cached_sun_light
		_cached_sun_light = null
		_sun_resolution_attempted = false
	if _sun_resolution_attempted:
		return null
	_sun_resolution_attempted = true
	_cached_sun_light = _first_directional_light(get_tree().current_scene)
	if _cached_sun_light == null:
		_cached_sun_light = _first_directional_light(get_tree().root)
	return _cached_sun_light


func _first_directional_light(scope: Node) -> DirectionalLight3D:
	if scope == null:
		return null
	var candidates: Array[Node] = scope.find_children("*", "DirectionalLight3D", true, false)
	for candidate_node: Node in candidates:
		if candidate_node is DirectionalLight3D:
			return candidate_node as DirectionalLight3D
	return null


func _active_caustics_texture(explicit_texture: Texture2D) -> Texture2D:
	if explicit_texture != null:
		return explicit_texture
	for path in [CAUSTICS_TEXTURE_PATH, CAUSTICS_TEXTURE_SCENE_PATH, CAUSTICS_TEXTURE_FALLBACK_PATH]:
		var candidate := load(path) as Texture2D
		if candidate != null:
			return candidate
	return null


func _resolve_luma_source(explicit_gradient: Texture2D) -> Texture2D:
	if explicit_gradient != null:
		return explicit_gradient
	return load(CAUSTICS_LUMA_GRADIENT_PATH) as Texture2D


func _prepare_runtime_luma(source: Texture2D) -> bool:
	if source == _source_luma_gradient and _runtime_luma_texture != null:
		return _runtime_luma_texture.get_rid().is_valid()
	_source_luma_gradient = source
	_runtime_luma_texture = null
	if source == null:
		return false
	var image := source.get_image()
	if image == null or image.is_empty():
		return false
	_runtime_luma_texture = ImageTexture.create_from_image(image)
	return _runtime_luma_texture != null and _runtime_luma_texture.get_rid().is_valid()


func _report_readiness_failure(reason: String) -> void:
	if _readiness_warning_reported:
		return
	_readiness_warning_reported = true
	push_warning("Ocean caustics inactive: runtime texture not ready (" + reason + ").")


func shutdown() -> void:
	_enabled = false
	if _effect != null:
		_effect.enabled = false
		_effect.set_active(false)
		if _compositor_attachment != null:
			_compositor_attachment.detach()
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_runtime_luma_texture = null
	_source_luma_gradient = null
	_texture = null
	_static_textures_ready = false
	_compositor_attachment = null
	_compositor = null
	_attached = false


func _exit_tree() -> void:
	shutdown()
