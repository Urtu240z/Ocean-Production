@tool
extends Node
## Shared HDR Kawase chain for SSPR and planar captures. Each pass reads a
## different target; there is never a read/write feedback loop on one texture.
const SHADER := preload("res://addons/ocean/reflections/shaders/ocean_reflection_kawase.gdshader")
const PASS_COUNT := 3
var _passes: Array[SubViewport] = []
var _rects: Array[ColorRect] = []
var _enabled := false
var _strength := 1.0
var _source: Texture2D
var _size := Vector2i.ZERO
var _ready_frame := -1

func configure(profile: OceanReflectionProfile) -> void:
	_enabled = profile.kawase_enabled
	_strength = profile.kawase_strength
	if not _enabled or _strength <= 0.0:
		pause()

func _create_passes() -> void:
	if not _passes.is_empty():
		return
	for index in PASS_COUNT:
		var viewport := SubViewport.new()
		viewport.name = "KawasePass%d" % index
		viewport.disable_3d = true
		viewport.use_hdr_2d = true
		viewport.transparent_bg = true
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(viewport)
		var rect := ColorRect.new()
		rect.material = ShaderMaterial.new()
		rect.material.shader = SHADER
		viewport.add_child(rect)
		_passes.append(viewport)
		_rects.append(rect)

func filter_texture(source: Texture2D, size: Vector2i) -> Texture2D:
	if not _enabled or _strength <= 0.0 or source == null or size.x < 1 or size.y < 1:
		pause()
		return source
	_create_passes()
	if source != _source or size != _size:
		_ready_frame = Engine.get_frames_drawn() + 1
	_source = source
	_size = size
	var input: Texture2D = source
	for index in PASS_COUNT:
		var viewport := _passes[index]
		if viewport.size != size:
			viewport.size = size
		_rects[index].size = Vector2(size)
		var material: ShaderMaterial = _rects[index].material
		material.set_shader_parameter(&"reflection_source", input)
		material.set_shader_parameter(&"texel_size", Vector2.ONE / Vector2(size))
		material.set_shader_parameter(&"radius", (float(index) + 0.5) * _strength)
		material.set_shader_parameter(&"source_premultiplied", index > 0)
		material.set_shader_parameter(&"final_pass", index == PASS_COUNT - 1)
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		input = viewport.get_texture()
	return input if Engine.get_frames_drawn() >= _ready_frame else source

func pause() -> void:
	for viewport in _passes:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_source = null
	_ready_frame = -1

func shutdown() -> void:
	pause()
	for index in _rects.size():
		_rects[index].material.set_shader_parameter(&"reflection_source", null)
	for viewport in _passes:
		viewport.queue_free()
	_passes.clear()
	_rects.clear()
