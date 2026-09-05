@tool
class_name OceanUnderwaterMediumEffect
extends CompositorEffect
## Render-thread P6 waterline-mask prototype. No Camera3D state is consumed or changed.

const SHADER := preload("res://addons/ocean/underwater/shaders/ocean_underwater_medium.glsl")
const THREAD_SIZE := 8
const PARAMS_BYTES := 176
const SOURCE_READY_WARNING_FRAMES := 300

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _params := RID()
var _mask := RID()
var _mask_size := Vector2i.ZERO
var _failed := false
var _mutex := Mutex.new()
var _sea_level := 0.0
var _debug_mask_enabled := true
var _surface_long := RID()
var _surface_mid := RID()
var _surface_short := RID()
var _surface_domains := Vector3(512.0, 512.0, 37.0)
var _short_fade := Vector2(0.0, 55.0)
var _mid_fade := Vector2(96.0, 280.0)
var _long_fade := Vector2(768.0, 2500.0)
var _surface_sources_ready := false
var _surface_source_wait_frames := 0
var _surface_source_warning_emitted := false
var _shutdown_requested := false


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	_rd = RenderingServer.get_rendering_device()


func configure(sea_level: float, debug_mask_enabled: bool) -> void:
	_mutex.lock()
	_sea_level = sea_level
	_debug_mask_enabled = debug_mask_enabled
	_mutex.unlock()


func set_surface_sources(long_texture: RID, mid_texture: RID, short_texture: RID, domains: Vector3, short_fade: Vector2, mid_fade: Vector2, long_fade: Vector2) -> void:
	if not long_texture.is_valid() or not mid_texture.is_valid() or not short_texture.is_valid() or domains.x <= 0.0 or domains.y <= 0.0 or domains.z <= 0.0:
		return
	_mutex.lock()
	_surface_long = long_texture
	_surface_mid = mid_texture
	_surface_short = short_texture
	_surface_domains = Vector3(maxf(domains.x, 0.001), maxf(domains.y, 0.001), maxf(domains.z, 0.001))
	_short_fade = short_fade
	_mid_fade = mid_fade
	_long_fade = long_fade
	_surface_sources_ready = true
	_mutex.unlock()


func free_resources() -> void:
	_release_resources()
	_failed = false


func prepare_resources() -> void:
	# Called only through RenderingServer.call_on_render_thread after attachment.
	_mutex.lock()
	var shutting_down := _shutdown_requested
	_mutex.unlock()
	if not shutting_down:
		_ensure_pipeline()


func begin_shutdown() -> void:
	_mutex.lock()
	_shutdown_requested = true
	_debug_mask_enabled = false
	_mutex.unlock()


func _release_resources() -> void:
	if _rd != null:
		for rid in [_mask, _pipeline, _shader, _sampler, _params]:
			if rid.is_valid():
				_rd.free_rid(rid)
	_mask = RID()
	_mask_size = Vector2i.ZERO
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
	_params = RID()


func _ensure_pipeline() -> bool:
	if _failed:
		return false
	if _shader.is_valid() and _pipeline.is_valid() and _sampler.is_valid() and _params.is_valid():
		return true
	_release_resources()
	if SHADER == null:
		return _fail("shader missing")
	var spirv := SHADER.get_spirv()
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty():
		return _fail(error)
	_shader = _rd.shader_create_from_spirv(spirv, "OceanUnderwaterWaterlineMask")
	if not _shader.is_valid():
		return _fail("shader creation")
	_pipeline = _rd.compute_pipeline_create(_shader)
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)
	_params = _rd.uniform_buffer_create(PARAMS_BYTES)
	if _pipeline.is_valid() and _sampler.is_valid() and _params.is_valid():
		return true
	_release_resources()
	return _fail("pipeline resources")


func _ensure_mask(size: Vector2i) -> bool:
	if _mask.is_valid() and _mask_size == size:
		return true
	if _mask.is_valid():
		_rd.free_rid(_mask)
		_mask = RID()
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	format.width = size.x
	format.height = size.y
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_mask = _rd.texture_create(format, RDTextureView.new())
	_mask_size = size if _mask.is_valid() else Vector2i.ZERO
	if _mask.is_valid():
		_rd.set_resource_name(_mask, "Ocean.P6.WaterlineMask.R8")
	return _mask.is_valid()


func _fail(reason: String) -> bool:
	_failed = true
	push_error("Ocean Underwater Medium disabled: %s" % reason)
	return false


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null:
		return
	_mutex.lock()
	var sea_level := _sea_level
	var debug_mask_enabled := _debug_mask_enabled
	var surface_long := _surface_long
	var surface_mid := _surface_mid
	var surface_short := _surface_short
	var surface_domains := _surface_domains
	var short_fade := _short_fade
	var mid_fade := _mid_fade
	var long_fade := _long_fade
	var surface_sources_ready := _surface_sources_ready
	_mutex.unlock()
	if not debug_mask_enabled:
		return
	if not _ensure_pipeline():
		return
	if not surface_sources_ready or not surface_long.is_valid() or not surface_mid.is_valid() or not surface_short.is_valid():
		_surface_source_wait_frames += 1
		if _surface_source_wait_frames >= SOURCE_READY_WARNING_FRAMES and not _surface_source_warning_emitted:
			_surface_source_warning_emitted = true
			push_warning("Ocean P6 waterline mask is still waiting for valid LONG/MID/SHORT displacement RD sources.")
		return
	_surface_source_wait_frames = 0
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data()
	if buffers == null or data == null or buffers.get_view_count() != 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0 or not _ensure_mask(size):
		return
	var color := buffers.get_color_layer(0)
	if not color.is_valid():
		return
	var camera: Transform3D = data.get_cam_transform()
	var projection: Projection = data.get_view_projection(0)
	var inverse_vp: Projection = (projection * Projection(camera.affine_inverse())).inverse()
	_rd.buffer_update(_params, 0, PARAMS_BYTES, _pack_params(inverse_vp, size, camera.origin, sea_level, surface_domains, short_fade, mid_fade, long_fade).to_byte_array())
	var uniforms := [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 2, [_params]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_sampler, surface_long]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [_sampler, surface_mid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5, [_sampler, surface_short]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 6, [_mask]),
	]
	var set := UniformSetCacheRD.get_cache(_shader, 0, uniforms)
	if not set.is_valid() or not _rd.uniform_set_is_valid(set):
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()


func _uniform(type: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		uniform.add_id(id)
	return uniform


func _pack_params(inverse_vp: Projection, size: Vector2i, camera: Vector3, sea_level: float, domains: Vector3, short_fade: Vector2, mid_fade: Vector2, long_fade: Vector2) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for column in [inverse_vp.x, inverse_vp.y, inverse_vp.z, inverse_vp.w]:
		values.append_array([column.x, column.y, column.z, column.w])
	values.append_array([
		size.x, size.y, 0.0, 0.0,
		camera.x, camera.y, camera.z, 1.0,
		sea_level, 0.0, 0.0, 0.0,
		domains.x, domains.y, domains.z, 0.0,
		short_fade.x, short_fade.y, 0.0, 0.0,
		mid_fade.x, mid_fade.y, 0.0, 0.0,
		long_fade.x, long_fade.y, 0.0, 0.0,
	])
	return values
