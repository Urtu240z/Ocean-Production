@tool
class_name OceanCausticsManager
extends Node

const EFFECT_SCRIPT := preload("res://addons/ocean/underwater/caustics/ocean_caustics_effect.gd")
const COMPOSITOR_ATTACHMENT := preload("res://addons/ocean/core/ocean_compositor_attachment.gd")

var _ocean: Node
var _effect: OceanCausticsEffect
var _compositor_attachment: RefCounted
var _compositor: Compositor
var _enabled := false
var _sea_level := 0.0
var _texture: Texture2D
var _luma_gradient: Texture2D
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
var _fade_start := 4.0
var _max_depth := 6.0
var _sun_direction := Vector3(0.0, 1.0, 0.0)
var _debug_mode := 0
var _time := 0.0
var _attached := false


func configure(ocean: Node, sea_level: float, enabled: bool, texture: Texture2D,
		luma_gradient: Texture2D, scale: float, speed: float, strength: float,
		power: float, chroma_split: float, layer_a_speed_multiplier: float,
		layer_b_speed_multiplier: float, layer_a_scale_multiplier: float,
		layer_b_scale_multiplier: float, layer_a_direction: Vector2, layer_b_direction: Vector2,
		luminance_mask_strength: float, sun_strength: float, fade_start: float,
		max_depth: float, sun_direction: Vector3, debug_mode: int) -> void:
	_ocean = ocean
	_sea_level = sea_level
	_enabled = enabled
	_texture = texture
	_luma_gradient = luma_gradient
	_scale = scale
	_speed = speed
	_strength = strength
	_power = power
	_chroma_split = chroma_split
	_layer_a_speed_multiplier = layer_a_speed_multiplier
	_layer_b_speed_multiplier = layer_b_speed_multiplier
	_layer_a_scale_multiplier = layer_a_scale_multiplier
	_layer_b_scale_multiplier = layer_b_scale_multiplier
	_layer_a_direction = layer_a_direction
	_layer_b_direction = layer_b_direction
	_luminance_mask_strength = luminance_mask_strength
	_sun_strength = sun_strength
	_fade_start = fade_start
	_max_depth = max_depth
	_sun_direction = sun_direction
	_debug_mode = debug_mode
	if not is_inside_tree() or Engine.is_editor_hint():
		return
	call_deferred(&"_initialize")


func set_settings(enabled: bool, sea_level: float, texture: Texture2D,
		luma_gradient: Texture2D, scale: float, speed: float, strength: float,
		power: float, chroma_split: float, layer_a_speed_multiplier: float,
		layer_b_speed_multiplier: float, layer_a_scale_multiplier: float,
		layer_b_scale_multiplier: float, layer_a_direction: Vector2, layer_b_direction: Vector2,
		luminance_mask_strength: float, sun_strength: float, fade_start: float,
		max_depth: float, sun_direction: Vector3, debug_mode: int) -> void:
	_enabled = enabled
	_sea_level = sea_level
	_texture = texture
	_luma_gradient = luma_gradient
	_scale = scale
	_speed = speed
	_strength = strength
	_power = power
	_chroma_split = chroma_split
	_layer_a_speed_multiplier = layer_a_speed_multiplier
	_layer_b_speed_multiplier = layer_b_speed_multiplier
	_layer_a_scale_multiplier = layer_a_scale_multiplier
	_layer_b_scale_multiplier = layer_b_scale_multiplier
	_layer_a_direction = layer_a_direction
	_layer_b_direction = layer_b_direction
	_luminance_mask_strength = luminance_mask_strength
	_sun_strength = sun_strength
	_fade_start = fade_start
	_max_depth = max_depth
	_sun_direction = sun_direction
	_debug_mode = debug_mode
	_push_settings()


func set_time(value: float) -> void:
	_time = value
	if _effect != null:
		_effect.set_time(value)


func _ready() -> void:
	if not Engine.is_editor_hint() and _ocean == null:
		_ocean = get_parent()
		call_deferred(&"_initialize")


func _process(_delta: float) -> void:
	if _effect == null:
		return
	_ensure_attachment()
	if not _enabled:
		return
	_time = _read_ocean_time()
	_sun_direction = _read_sun_direction()
	_push_settings()
	_effect.set_time(_time)


func _push_settings() -> void:
	if _effect != null:
		_effect.enabled = _enabled
		_effect.set_settings(_enabled, _sea_level, _texture, _luma_gradient, _scale,
			_speed, _strength, _power, _chroma_split, _layer_a_speed_multiplier,
			_layer_b_speed_multiplier, _layer_a_scale_multiplier, _layer_b_scale_multiplier,
			_layer_a_direction, _layer_b_direction, _luminance_mask_strength, _sun_strength,
			_fade_start, _max_depth, _sun_direction, _debug_mode)


func _initialize() -> void:
	if _effect != null or Engine.is_editor_hint() or not is_inside_tree():
		return
	_effect = EFFECT_SCRIPT.new()
	_effect.set_time(_time)
	_push_settings()
	_compositor_attachment = COMPOSITOR_ATTACHMENT.new(self, _effect)
	call_deferred(&"_ensure_attachment")


func _ensure_attachment() -> void:
	if _effect == null or _compositor_attachment == null:
		return
	_attached = _compositor_attachment.ensure_attached()
	_compositor = _compositor_attachment.get_compositor()


func _read_ocean_time() -> float:
	if _ocean == null or not is_instance_valid(_ocean):
		return _time
	var open_ocean := _ocean.get_node_or_null(^"OpenOceanFFT")
	if open_ocean != null and open_ocean.has_method(&"get_wave_time"):
		return float(open_ocean.get_wave_time())
	return _time


func _read_sun_direction() -> Vector3:
	var light: DirectionalLight3D = _ocean.get("underwater_sun_light") as DirectionalLight3D if _ocean != null else null
	if light == null or not is_instance_valid(light) or not light.is_inside_tree():
		light = _first_directional_light(get_tree().current_scene)
		if light == null:
			light = _first_directional_light(get_tree().root)
	if light != null:
		var direction := light.global_transform.basis.z.normalized()
		if direction.length_squared() > 0.000001:
			return direction
	return Vector3.UP


func _first_directional_light(scope: Node) -> DirectionalLight3D:
	if scope == null:
		return null
	var candidates: Array[Node] = scope.find_children("*", "DirectionalLight3D", true, false)
	for candidate_node: Node in candidates:
		if candidate_node is DirectionalLight3D:
			return candidate_node as DirectionalLight3D
	return null


func _exit_tree() -> void:
	if _effect != null:
		if _compositor_attachment != null:
			_compositor_attachment.detach()
		_effect.enabled = false
		_effect.set_settings(false, _sea_level, null, null, _scale, _speed, 0.0,
			_power, _chroma_split, _layer_a_speed_multiplier, _layer_b_speed_multiplier,
			_layer_a_scale_multiplier, _layer_b_scale_multiplier, _layer_a_direction,
			_layer_b_direction, _luminance_mask_strength, _sun_strength, _fade_start,
			_max_depth, _sun_direction, 0)
		RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_compositor_attachment = null
	_compositor = null
	_attached = false
