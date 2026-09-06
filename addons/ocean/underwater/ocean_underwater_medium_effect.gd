@tool
class_name OceanUnderwaterMediumEffect
extends CompositorEffect
## Same-camera P6 waterline raster. Main-thread methods only publish immutable
## data; all RenderingDevice creation, drawing and freeing stays render-thread.

const COMPUTE_SHADER := preload("res://addons/ocean/underwater/shaders/ocean_underwater_medium.glsl")
const RASTER_SHADER := preload("res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl")
const HORIZON_SHADER := preload("res://addons/ocean/underwater/shaders/ocean_waterline_horizon_rd.glsl")
const THREAD_SIZE := 8
const COMPUTE_PARAMS_BYTES := 144
const RASTER_PARAMS_BYTES := 192

var _rd: RenderingDevice
var _mutex := Mutex.new()
var _shutdown_requested := false
var _failed := false
var _sea_level := 0.0
var _debug_mask_enabled := false
var _absorption := Vector3(0.35, 0.14, 0.10)
var _absorption_scale := 0.43
var _scattering_color := Color(0.0024315654, 0.09275196, 0.13127226)
var _scattering_strength := 1.0
var _scattering_density := 0.15
var _maximum_distance := 120.0
var _geometry: Array = []
var _geometry_generation := 0
var _sources := {}

var _compute_shader := RID()
var _compute_pipeline := RID()
var _compute_sampler := RID()
var _compute_params := RID()
var _raster_shader := RID()
var _horizon_shader := RID()
var _raster_sampler := RID()
var _raster_params := RID()
var _vertex_format := -1
var _raster_geometry: Array = []
var _raster_geometry_generation := -1
var _mask_texture := RID()
var _ocean_depth_texture := RID()
var _depth_texture := RID()
var _framebuffer := RID()
var _raster_pipeline := RID()
var _horizon_pipeline := RID()
var _target_size := Vector2i.ZERO


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()


func configure(sea_level: float, debug_mask_enabled: bool, absorption: Vector3, absorption_scale: float, scattering_color: Color, scattering_strength: float, scattering_density: float, maximum_distance: float) -> void:
	_mutex.lock()
	_sea_level = sea_level
	_debug_mask_enabled = debug_mask_enabled
	_absorption = Vector3(maxf(absorption.x, 0.0), maxf(absorption.y, 0.0), maxf(absorption.z, 0.0))
	_absorption_scale = clampf(absorption_scale, 0.0, 4.0)
	_scattering_color = scattering_color
	_scattering_strength = clampf(scattering_strength, 0.0, 4.0)
	_scattering_density = clampf(scattering_density, 0.0, 2.0)
	_maximum_distance = clampf(maximum_distance, 1.0, 500.0)
	_mutex.unlock()


func set_raster_geometry(geometry: Array) -> void:
	if geometry.is_empty(): return
	_mutex.lock()
	_geometry = geometry
	_geometry_generation += 1
	_mutex.unlock()


func set_raster_sources(sources: Dictionary) -> void:
	for key in ["long", "mid", "short"]:
		var rid: RID = sources.get(key, RID())
		if not rid.is_valid(): return
	_mutex.lock()
	_sources = sources.duplicate()
	_mutex.unlock()


func prepare_resources() -> void:
	if not _is_shutting_down():
		_ensure_compute_pipeline()
		_ensure_raster_static()


func begin_shutdown() -> void:
	_mutex.lock()
	_shutdown_requested = true
	_debug_mask_enabled = false
	_mutex.unlock()


func free_resources() -> void:
	_release_resources()
	_failed = false


func _is_shutting_down() -> bool:
	_mutex.lock()
	var result := _shutdown_requested
	_mutex.unlock()
	return result


func _fail(reason: String) -> bool:
	_failed = true
	push_error("Ocean Underwater Medium disabled: %s" % reason)
	return false


func _ensure_compute_pipeline() -> bool:
	if _failed: return false
	if _compute_pipeline.is_valid() and _compute_sampler.is_valid() and _compute_params.is_valid(): return true
	var spirv := COMPUTE_SHADER.get_spirv()
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty(): return _fail(error)
	_compute_shader = _rd.shader_create_from_spirv(spirv, "OceanUnderwaterMedium")
	_compute_pipeline = _rd.compute_pipeline_create(_compute_shader)
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_compute_sampler = _rd.sampler_create(state)
	_compute_params = _rd.uniform_buffer_create(COMPUTE_PARAMS_BYTES)
	if _compute_shader.is_valid() and _compute_pipeline.is_valid() and _compute_sampler.is_valid() and _compute_params.is_valid(): return true
	_release_resources()
	return _fail("compute pipeline resources")


func _ensure_raster_static() -> bool:
	if _failed: return false
	_mutex.lock()
	var geometry := _geometry
	var generation := _geometry_generation
	_mutex.unlock()
	if geometry.is_empty(): return false
	if _raster_geometry_generation == generation and _raster_shader.is_valid() and _horizon_shader.is_valid() and _raster_params.is_valid() and _raster_sampler.is_valid(): return true
	_release_raster_static()
	var raster_spirv := RASTER_SHADER.get_spirv()
	var horizon_spirv := HORIZON_SHADER.get_spirv()
	var error := raster_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX)
	if error.is_empty(): error = raster_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT)
	if error.is_empty(): error = horizon_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX)
	if error.is_empty(): error = horizon_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT)
	if not error.is_empty(): return _fail(error)
	_raster_shader = _rd.shader_create_from_spirv(raster_spirv, "OceanWaterlineRaster")
	_horizon_shader = _rd.shader_create_from_spirv(horizon_spirv, "OceanWaterlineHorizon")
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_raster_sampler = _rd.sampler_create(sampler_state)
	_raster_params = _rd.uniform_buffer_create(RASTER_PARAMS_BYTES)
	var attribute := RDVertexAttribute.new()
	attribute.format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	attribute.location = 0
	attribute.offset = 0
	attribute.stride = 12
	_vertex_format = _rd.vertex_format_create([attribute])
	for item in geometry:
		var vertices: PackedVector3Array = item.get("vertices", PackedVector3Array())
		var indices: PackedInt32Array = item.get("indices", PackedInt32Array())
		if vertices.is_empty() or indices.is_empty():
			_release_raster_static()
			return _fail("clipmap raster geometry")
		var vertex_buffer := _rd.vertex_buffer_create(vertices.size() * 12, vertices.to_byte_array())
		var index_buffer := _rd.index_buffer_create(indices.size(), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, indices.to_byte_array())
		var vertex_array := _rd.vertex_array_create(vertices.size(), _vertex_format, [vertex_buffer])
		var index_array := _rd.index_array_create(index_buffer, 0, indices.size())
		if not vertex_buffer.is_valid() or not index_buffer.is_valid() or not vertex_array.is_valid() or not index_array.is_valid():
			_release_raster_static()
			return _fail("clipmap RD buffers")
		_raster_geometry.append({"vertex_buffer": vertex_buffer, "index_buffer": index_buffer, "vertex_array": vertex_array, "index_array": index_array})
	if not _raster_shader.is_valid() or not _horizon_shader.is_valid() or not _raster_sampler.is_valid() or not _raster_params.is_valid() or _raster_geometry.is_empty():
		_release_raster_static()
		return _fail("raster static resources")
	_raster_geometry_generation = generation
	return true


func _ensure_targets(size: Vector2i) -> bool:
	if _target_size == size and _framebuffer.is_valid() and _rd.framebuffer_is_valid(_framebuffer) and _raster_pipeline.is_valid() and _horizon_pipeline.is_valid(): return true
	_release_targets()
	_mask_texture = _create_target(size, RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT)
	_ocean_depth_texture = _create_target(size, RenderingDevice.DATA_FORMAT_R32_SFLOAT, RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT)
	_depth_texture = _create_target(size, RenderingDevice.DATA_FORMAT_D32_SFLOAT, RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)
	if not _mask_texture.is_valid() or not _ocean_depth_texture.is_valid() or not _depth_texture.is_valid():
		_release_targets()
		return _fail("waterline target formats")
	_framebuffer = _rd.framebuffer_create([_mask_texture, _ocean_depth_texture, _depth_texture])
	if not _framebuffer.is_valid() or not _rd.framebuffer_is_valid(_framebuffer):
		_release_targets()
		return _fail("waterline framebuffer")
	var raster_state := RDPipelineRasterizationState.new()
	# RDPipelineRasterizationState defaults to cull_mode 0 (disabled) in Godot
	# 4.7.1. Keep the default instead of referring to a non-exported enum name.
	var depth_state := RDPipelineDepthStencilState.new()
	depth_state.enable_depth_test = true
	depth_state.enable_depth_write = true
	depth_state.depth_compare_operator = RenderingDevice.COMPARE_OP_GREATER_OR_EQUAL
	var horizon_depth_state := RDPipelineDepthStencilState.new()
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [RDPipelineColorBlendStateAttachment.new(), RDPipelineColorBlendStateAttachment.new()]
	var framebuffer_format := _rd.framebuffer_get_format(_framebuffer)
	_raster_pipeline = _rd.render_pipeline_create(_raster_shader, framebuffer_format, _vertex_format, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster_state, RDPipelineMultisampleState.new(), depth_state, blend)
	_horizon_pipeline = _rd.render_pipeline_create(_horizon_shader, framebuffer_format, 0, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(), horizon_depth_state, blend)
	if not _rd.render_pipeline_is_valid(_raster_pipeline) or not _rd.render_pipeline_is_valid(_horizon_pipeline):
		_release_targets()
		return _fail("waterline raster pipeline")
	_target_size = size
	return true


func _create_target(size: Vector2i, data_format: int, usage: int) -> RID:
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.format = data_format
	format.width = size.x
	format.height = size.y
	format.depth = 1
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = usage
	return _rd.texture_create(format, RDTextureView.new())


func _raster_waterline(data: RenderSceneData, size: Vector2i, sea_level: float) -> bool:
	if not _ensure_raster_static() or not _ensure_targets(size): return false
	_mutex.lock()
	var sources := _sources.duplicate()
	_mutex.unlock()
	var long_rid: RID = sources.get("long", RID())
	var mid_rid: RID = sources.get("mid", RID())
	var short_rid: RID = sources.get("short", RID())
	if not long_rid.is_valid() or not mid_rid.is_valid() or not short_rid.is_valid() or not _rd.texture_is_valid(long_rid) or not _rd.texture_is_valid(mid_rid) or not _rd.texture_is_valid(short_rid): return false
	var camera: Transform3D = data.get_cam_transform()
	var projection: Projection = data.get_view_projection(0)
	var view_projection: Projection = projection * Projection(camera.affine_inverse())
	_rd.buffer_update(_raster_params, 0, RASTER_PARAMS_BYTES, _pack_raster_params(view_projection, view_projection.inverse(), camera.origin, sea_level, sources).to_byte_array())
	var raster_set := UniformSetCacheRD.get_cache(_raster_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_raster_sampler, long_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_raster_sampler, mid_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_raster_sampler, short_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [_raster_params])])
	var horizon_set := UniformSetCacheRD.get_cache(_horizon_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, [_raster_params])])
	if not _rd.uniform_set_is_valid(raster_set) or not _rd.uniform_set_is_valid(horizon_set): return false
	var draw_list := _rd.draw_list_begin(_framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH, PackedColorArray([Color(0.0, 0.0, 0.0, 0.0), Color(0.0, 0.0, 0.0, 0.0)]), 0.0)
	# Horizon is explicit first and has depth disabled; geometry is always later.
	_rd.draw_list_bind_render_pipeline(draw_list, _horizon_pipeline)
	_rd.draw_list_bind_uniform_set(draw_list, horizon_set, 0)
	_rd.draw_list_draw(draw_list, false, 1, 3)
	var root_model := Transform3D(Basis.IDENTITY, Vector3(camera.origin.x, sea_level, camera.origin.z))
	var push_constants := _pack_transform(root_model).to_byte_array()
	_rd.draw_list_bind_render_pipeline(draw_list, _raster_pipeline)
	_rd.draw_list_bind_uniform_set(draw_list, raster_set, 0)
	_rd.draw_list_set_push_constant(draw_list, push_constants, push_constants.size())
	for geometry in _raster_geometry:
		_rd.draw_list_bind_vertex_array(draw_list, geometry.vertex_array)
		_rd.draw_list_bind_index_array(draw_list, geometry.index_array)
		_rd.draw_list_draw(draw_list, true, 1)
	_rd.draw_list_end()
	return true


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null or _failed or _is_shutting_down(): return
	_mutex.lock()
	var sea_level := _sea_level
	var debug_mask_enabled := _debug_mask_enabled
	var absorption := _absorption
	var absorption_scale := _absorption_scale
	var scattering_color := _scattering_color
	var scattering_strength := _scattering_strength
	var scattering_density := _scattering_density
	var maximum_distance := _maximum_distance
	_mutex.unlock()
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data() as RenderSceneData
	if buffers == null or data == null or buffers.get_view_count() != 1: return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0 or not _raster_waterline(data, size, sea_level): return
	# Raw-mask validation intentionally performs no optical work when disabled.
	if not debug_mask_enabled or not _ensure_compute_pipeline(): return
	var color := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	if not color.is_valid() or not depth.is_valid(): return
	var camera: Transform3D = data.get_cam_transform()
	var projection: Projection = data.get_view_projection(0)
	var inverse_vp: Projection = (projection * Projection(camera.affine_inverse())).inverse()
	_rd.buffer_update(_compute_params, 0, COMPUTE_PARAMS_BYTES, _pack_compute_params(inverse_vp, size, camera.origin, sea_level, absorption_scale, maximum_distance, absorption, scattering_strength, scattering_color, scattering_density).to_byte_array())
	var set := UniformSetCacheRD.get_cache(_compute_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_compute_sampler, depth]), _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 2, [_compute_params]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_compute_sampler, _mask_texture]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [_compute_sampler, _ocean_depth_texture])])
	if not set.is_valid() or not _rd.uniform_set_is_valid(set): return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _compute_pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()


func _uniform(type: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids: uniform.add_id(id)
	return uniform


func _pack_compute_params(inverse_vp: Projection, size: Vector2i, camera: Vector3, sea_level: float, absorption_scale: float, maximum_distance: float, absorption: Vector3, scattering_strength: float, scattering_color: Color, scattering_density: float) -> PackedFloat32Array:
	var values := _pack_projection(inverse_vp)
	values.append_array([size.x, size.y, 0.0, 0.0, camera.x, camera.y, camera.z, 1.0, sea_level, maximum_distance, absorption_scale, 1.0, absorption.x, absorption.y, absorption.z, scattering_strength, scattering_color.r, scattering_color.g, scattering_color.b, scattering_density])
	return values


func _pack_raster_params(view_projection: Projection, inverse_view_projection: Projection, camera: Vector3, sea_level: float, sources: Dictionary) -> PackedFloat32Array:
	var domains: Vector3 = sources.get("domains", Vector3.ONE)
	var long_fade: Vector2 = sources.get("long_fade", Vector2(0.0, 1.0))
	var mid_fade: Vector2 = sources.get("mid_fade", Vector2(0.0, 1.0))
	var short_fade: Vector2 = sources.get("short_fade", Vector2(0.0, 1.0))
	var values := _pack_projection(view_projection)
	values.append_array(_pack_projection(inverse_view_projection))
	values.append_array([camera.x, camera.y, camera.z, sea_level, domains.x, domains.y, domains.z, 0.0, long_fade.x, long_fade.y, 0.0, 0.0, mid_fade.x, mid_fade.y, 0.0, 0.0, short_fade.x, short_fade.y, 0.0, 0.0])
	return values


func _pack_projection(projection: Projection) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for column in [projection.x, projection.y, projection.z, projection.w]: values.append_array([column.x, column.y, column.z, column.w])
	return values


func _pack_transform(transform: Transform3D) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for column in [transform.basis.x, transform.basis.y, transform.basis.z]: values.append_array([column.x, column.y, column.z, 0.0])
	values.append_array([transform.origin.x, transform.origin.y, transform.origin.z, 1.0])
	return values


func _release_targets() -> void:
	for rid in [_raster_pipeline, _horizon_pipeline, _framebuffer, _mask_texture, _ocean_depth_texture, _depth_texture]:
		if rid.is_valid(): _rd.free_rid(rid)
	_raster_pipeline = RID(); _horizon_pipeline = RID(); _framebuffer = RID()
	_mask_texture = RID(); _ocean_depth_texture = RID(); _depth_texture = RID(); _target_size = Vector2i.ZERO


func _release_raster_static() -> void:
	_release_targets()
	for geometry in _raster_geometry:
		for key in ["vertex_array", "index_array", "vertex_buffer", "index_buffer"]:
			var rid: RID = geometry.get(key, RID())
			if rid.is_valid(): _rd.free_rid(rid)
	_raster_geometry.clear()
	for rid in [_raster_shader, _horizon_shader, _raster_sampler, _raster_params]:
		if rid.is_valid(): _rd.free_rid(rid)
	_raster_shader = RID(); _horizon_shader = RID(); _raster_sampler = RID(); _raster_params = RID()
	_vertex_format = -1; _raster_geometry_generation = -1


func _release_resources() -> void:
	_release_raster_static()
	for rid in [_compute_pipeline, _compute_shader, _compute_sampler, _compute_params]:
		if rid.is_valid(): _rd.free_rid(rid)
	_compute_pipeline = RID(); _compute_shader = RID(); _compute_sampler = RID(); _compute_params = RID()
