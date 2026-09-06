@tool
class_name OceanUnderwaterMediumEffect
extends CompositorEffect
## Same-camera P6 waterline raster. Main-thread methods only publish immutable
## data; all RenderingDevice creation, drawing and freeing stays render-thread.

const COMPUTE_SHADER := preload("res://addons/ocean/underwater/shaders/ocean_underwater_medium.glsl")
const RASTER_SHADER := preload("res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl")
const CAMERA_STATE_SHADER := preload("res://addons/ocean/underwater/shaders/ocean_waterline_camera_state.glsl")
const BUBBLES := preload("res://addons/ocean/underwater/bubbles/ocean_underwater_bubbles.gd")
const THREAD_SIZE := 8
const COMPUTE_PARAMS_VEC4_COUNT := 9
const COMPUTE_PARAMS_BYTE_SIZE := COMPUTE_PARAMS_VEC4_COUNT * 16 + 64
const COMPUTE_PARAMS_BYTES := COMPUTE_PARAMS_BYTE_SIZE
# Two mat4 values (128 bytes) plus five vec4 values (80 bytes), std140.
const RASTER_PARAMS_BYTES := 208
const CAMERA_STATE_PARAMS_BYTES := 80
const CAMERA_STATE_BYTES := 32

var _rd: RenderingDevice
var _mutex := Mutex.new()
var _shutdown_requested := false
var _failed := false
var _sea_level := 0.0
var _debug_mask_enabled := false
var _meniscus_enabled := false
var _meniscus_width_px := 30.0
var _meniscus_softness := 0.5
var _meniscus_strength := 0.04
var _meniscus_debug := false
var _visibility_distance_m := 25.0
var _depth_light_falloff := 0.028
var _surface_light_strength := 1.35
var _ambient_debug_mode := 0
var _absorption := Vector3(0.35, 0.14, 0.10)
var _absorption_scale := 0.36
var _scattering_color := Color(0.0024315654, 0.09275196, 0.13127226)
var _scattering_strength := 1.0
var _scattering_density := 0.15
var _maximum_distance := 120.0
var _enter_margin := 0.05
var _exit_margin := 0.05
var _geometry: Array = []
var _geometry_generation := 0
var _sources := {}
var _bubble_settings := {"enabled": false}
var _bubble_settings_generation := 0
var _bubble_settings_applied_generation := -1

var _compute_shader := RID()
var _compute_pipeline := RID()
var _compute_sampler := RID()
var _compute_params := RID()
var _camera_state_shader := RID()
var _camera_state_pipeline := RID()
var _camera_state_params := RID()
var _camera_state := RID()
var _raster_shader := RID()
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
var _target_size := Vector2i.ZERO
var _raster_state := &""
var _bubbles: OceanUnderwaterBubbles


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()


func configure(sea_level: float, debug_mask_enabled: bool, meniscus_enabled: bool, meniscus_width_px: float, meniscus_softness: float, meniscus_strength: float, meniscus_debug: bool, visibility_distance_m: float, depth_light_falloff: float, surface_light_strength: float, ambient_debug_mode: int, absorption: Vector3, absorption_scale: float, scattering_color: Color, scattering_strength: float, scattering_density: float, maximum_distance: float, enter_margin: float, exit_margin: float) -> void:
	_mutex.lock()
	_sea_level = sea_level
	_debug_mask_enabled = debug_mask_enabled
	_meniscus_enabled = meniscus_enabled
	_meniscus_width_px = clampf(meniscus_width_px, 1.0, 120.0)
	_meniscus_softness = clampf(meniscus_softness, 0.05, 1.0)
	_meniscus_strength = clampf(meniscus_strength, 0.0, 1.0)
	_meniscus_debug = meniscus_debug
	_visibility_distance_m = clampf(visibility_distance_m, 1.0, 100.0)
	_depth_light_falloff = clampf(depth_light_falloff, 0.0, 0.5)
	_surface_light_strength = clampf(surface_light_strength, 0.0, 3.0)
	_ambient_debug_mode = clampi(ambient_debug_mode, 0, 6)
	_absorption = Vector3(maxf(absorption.x, 0.0), maxf(absorption.y, 0.0), maxf(absorption.z, 0.0))
	_absorption_scale = clampf(absorption_scale, 0.0, 4.0)
	_scattering_color = scattering_color
	_scattering_strength = clampf(scattering_strength, 0.0, 4.0)
	_scattering_density = clampf(scattering_density, 0.0, 2.0)
	_maximum_distance = clampf(maximum_distance, 1.0, 500.0)
	_enter_margin = clampf(enter_margin, 0.0, 1.0)
	_exit_margin = clampf(exit_margin, 0.0, 1.0)
	_mutex.unlock()


func configure_bubbles(settings: Dictionary) -> void:
	_mutex.lock()
	_bubble_settings = settings.duplicate(true)
	_bubble_settings_generation += 1
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
	if _rd != null and not _is_shutting_down():
		_ensure_compute_pipeline()
		_ensure_raster_static()
		_ensure_camera_state()
		_ensure_bubbles()


func begin_shutdown() -> void:
	_mutex.lock()
	_shutdown_requested = true
	_debug_mask_enabled = false
	_bubble_settings = {"enabled": false}
	_mutex.unlock()


func free_resources() -> void:
	if _rd != null:
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


func _ensure_bubbles() -> bool:
	if _bubbles == null:
		_bubbles = BUBBLES.new()
	if _bubbles.prepare(_rd):
		return true
	return _fail("bubble binding resources: %s" % _bubbles.last_error)


func _ensure_camera_state() -> bool:
	if _failed: return false
	if _camera_state_pipeline.is_valid() and _camera_state_params.is_valid() and _camera_state.is_valid(): return true
	var spirv := CAMERA_STATE_SHADER.get_spirv()
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not error.is_empty(): return _fail(error)
	_camera_state_shader = _rd.shader_create_from_spirv(spirv, "OceanWaterlineCameraState")
	_camera_state_pipeline = _rd.compute_pipeline_create(_camera_state_shader)
	_camera_state_params = _rd.uniform_buffer_create(CAMERA_STATE_PARAMS_BYTES)
	_camera_state = _rd.storage_buffer_create(CAMERA_STATE_BYTES, PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0]).to_byte_array())
	if _camera_state_shader.is_valid() and _camera_state_pipeline.is_valid() and _camera_state_params.is_valid() and _camera_state.is_valid(): return true
	_release_resources()
	return _fail("camera-state compute resources")


func _ensure_raster_static() -> bool:
	if _failed: return false
	_mutex.lock()
	var geometry := _geometry
	var generation := _geometry_generation
	_mutex.unlock()
	if geometry.is_empty(): return false
	if _raster_geometry_generation == generation and _raster_shader.is_valid() and _raster_params.is_valid() and _raster_sampler.is_valid(): return true
	_release_raster_static()
	var raster_spirv := RASTER_SHADER.get_spirv()
	var error := raster_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX)
	if error.is_empty(): error = raster_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT)
	if not error.is_empty(): return _fail(error)
	_raster_shader = _rd.shader_create_from_spirv(raster_spirv, "OceanWaterlineRaster")
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
	if not _raster_shader.is_valid() or not _raster_sampler.is_valid() or not _raster_params.is_valid() or _raster_geometry.is_empty():
		_release_raster_static()
		return _fail("raster static resources")
	_raster_geometry_generation = generation
	return true


func _ensure_targets(size: Vector2i) -> bool:
	if _target_size == size and _framebuffer.is_valid() and _rd.framebuffer_is_valid(_framebuffer) and _raster_pipeline.is_valid(): return true
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
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [RDPipelineColorBlendStateAttachment.new(), RDPipelineColorBlendStateAttachment.new()]
	var framebuffer_format := _rd.framebuffer_get_format(_framebuffer)
	_raster_pipeline = _rd.render_pipeline_create(_raster_shader, framebuffer_format, _vertex_format, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, raster_state, RDPipelineMultisampleState.new(), depth_state, blend)
	if not _rd.render_pipeline_is_valid(_raster_pipeline):
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


func _compute_camera_state(camera: Vector3, sea_level: float, sources: Dictionary) -> bool:
	if not _ensure_camera_state(): return false
	var long_rid: RID = sources.get("long", RID())
	var mid_rid: RID = sources.get("mid", RID())
	var short_rid: RID = sources.get("short", RID())
	if not long_rid.is_valid() or not mid_rid.is_valid() or not short_rid.is_valid() or not _rd.texture_is_valid(long_rid) or not _rd.texture_is_valid(mid_rid) or not _rd.texture_is_valid(short_rid):
		_set_raster_state(&"WAIT_FFT_SOURCES")
		return false
	_rd.buffer_update(_camera_state_params, 0, CAMERA_STATE_PARAMS_BYTES, _pack_camera_state_params(camera, sea_level, sources).to_byte_array())
	var set := UniformSetCacheRD.get_cache(_camera_state_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_raster_sampler, long_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_raster_sampler, mid_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_raster_sampler, short_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [_camera_state_params]), _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [_camera_state])])
	if not set.is_valid() or not _rd.uniform_set_is_valid(set):
		_set_raster_state(&"INVALID_CAMERA_STATE_SET")
		return false
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _camera_state_pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list, 1, 1, 1)
	_rd.compute_list_end()
	return true


func _raster_waterline(data: RenderSceneData, size: Vector2i, sea_level: float) -> bool:
	if not _ensure_raster_static():
		_set_raster_state(&"WAIT_GEOMETRY")
		return false
	if not _ensure_targets(size):
		_set_raster_state(&"WAIT_TARGETS")
		return false
	_mutex.lock()
	var sources := _sources.duplicate()
	_mutex.unlock()
	var long_rid: RID = sources.get("long", RID())
	var mid_rid: RID = sources.get("mid", RID())
	var short_rid: RID = sources.get("short", RID())
	if not long_rid.is_valid() or not mid_rid.is_valid() or not short_rid.is_valid() or not _rd.texture_is_valid(long_rid) or not _rd.texture_is_valid(mid_rid) or not _rd.texture_is_valid(short_rid):
		_set_raster_state(&"WAIT_FFT_SOURCES")
		return false
	var camera: Transform3D = data.get_cam_transform()
	var projection: Projection = data.get_view_projection(0)
	var view_projection: Projection = projection * Projection(camera.affine_inverse())
	_rd.buffer_update(_raster_params, 0, RASTER_PARAMS_BYTES, _pack_raster_params(view_projection, view_projection.inverse(), camera.origin, sea_level, sources).to_byte_array())
	var raster_set := UniformSetCacheRD.get_cache(_raster_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_raster_sampler, long_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_raster_sampler, mid_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_raster_sampler, short_rid]), _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [_raster_params])])
	if not _rd.uniform_set_is_valid(raster_set):
		_set_raster_state(&"INVALID_RASTER_SET")
		return false
	var draw_list := _rd.draw_list_begin(_framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH, PackedColorArray([Color(0.0, 0.0, 0.0, 0.0), Color(0.0, 0.0, 0.0, 0.0)]), 0.0)
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
	_set_raster_state(&"READY")
	return true


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or _rd == null or _failed or _is_shutting_down(): return
	_mutex.lock()
	var sea_level := _sea_level
	var debug_mask_enabled := _debug_mask_enabled
	var meniscus_enabled := _meniscus_enabled
	var meniscus_width_px := _meniscus_width_px
	var meniscus_softness := _meniscus_softness
	var meniscus_strength := _meniscus_strength
	var meniscus_debug := _meniscus_debug
	var visibility_distance_m := _visibility_distance_m
	var depth_light_falloff := _depth_light_falloff
	var surface_light_strength := _surface_light_strength
	var ambient_debug_mode := _ambient_debug_mode
	var absorption := _absorption
	var absorption_scale := _absorption_scale
	var scattering_color := _scattering_color
	var scattering_strength := _scattering_strength
	var scattering_density := _scattering_density
	var maximum_distance := _maximum_distance
	var enter_margin := _enter_margin
	var exit_margin := _exit_margin
	var bubble_settings := _bubble_settings.duplicate(true)
	var bubble_settings_generation := _bubble_settings_generation
	_mutex.unlock()
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data() as RenderSceneData
	if buffers == null or data == null or buffers.get_view_count() != 1: return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0 or not _ensure_raster_static(): return
	var camera: Transform3D = data.get_cam_transform()
	_mutex.lock()
	var sources := _sources.duplicate()
	_mutex.unlock()
	if not _compute_camera_state(camera.origin, sea_level, sources): return
	if not _raster_waterline(data, size, sea_level): return
	if not _ensure_compute_pipeline(): return
	if not _ensure_bubbles(): return
	if _bubble_settings_applied_generation != bubble_settings_generation:
		_bubbles.configure(bubble_settings)
		_bubble_settings_applied_generation = bubble_settings_generation
	_bubbles.advance(camera.origin, sea_level, sources, Time.get_ticks_usec() * 0.000001)
	var color := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	if not color.is_valid() or not depth.is_valid(): return
	var projection: Projection = data.get_view_projection(0)
	var inverse_vp: Projection = (projection * Projection(camera.affine_inverse())).inverse()
	_rd.buffer_update(_compute_params, 0, COMPUTE_PARAMS_BYTES, _pack_compute_params(inverse_vp, size, camera.origin, sea_level, debug_mask_enabled, meniscus_enabled, meniscus_width_px, meniscus_softness, meniscus_strength, meniscus_debug, visibility_distance_m, depth_light_falloff, surface_light_strength, ambient_debug_mode, absorption_scale, maximum_distance, absorption, scattering_strength, scattering_color, scattering_density, enter_margin, exit_margin).to_byte_array())
	var set := UniformSetCacheRD.get_cache(_compute_shader, 0, [_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_compute_sampler, depth]), _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 2, [_compute_params]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_compute_sampler, _mask_texture]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [_compute_sampler, _ocean_depth_texture]), _uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 5, [_camera_state]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6, [_bubbles.get_density_sampler_rid(), _bubbles.get_density_rid()]), _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 7, [_bubbles.get_render_params_rid()]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8, [_bubbles.get_surface_sampler_rid(), sources.get("long", RID())]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 9, [_bubbles.get_surface_sampler_rid(), sources.get("mid", RID())]), _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 10, [_bubbles.get_surface_sampler_rid(), sources.get("short", RID())])])
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


func _pack_compute_params(inverse_vp: Projection, size: Vector2i, camera: Vector3, sea_level: float, debug_mask_enabled: bool, meniscus_enabled: bool, meniscus_width_px: float, meniscus_softness: float, meniscus_strength: float, meniscus_debug: bool, visibility_distance_m: float, depth_light_falloff: float, surface_light_strength: float, ambient_debug_mode: int, absorption_scale: float, maximum_distance: float, absorption: Vector3, scattering_strength: float, scattering_color: Color, scattering_density: float, enter_margin: float, exit_margin: float) -> PackedFloat32Array:
	var values := _pack_projection(inverse_vp)
	values.append_array([size.x, size.y, 0.0, 0.0, camera.x, camera.y, camera.z, exit_margin, maximum_distance, absorption_scale, 1.0 if debug_mask_enabled else 0.0, enter_margin, absorption.x, absorption.y, absorption.z, scattering_strength, scattering_color.r, scattering_color.g, scattering_color.b, scattering_density, 1.0 if meniscus_enabled else 0.0, meniscus_width_px, meniscus_strength, 1.0 if meniscus_debug else 0.0, meniscus_softness, 0.0, 0.0, 0.0, visibility_distance_m, depth_light_falloff, float(ambient_debug_mode), sea_level])
	values.append_array([surface_light_strength, 0.0, 0.0, 0.0])
	return values


func _set_raster_state(state: StringName) -> void:
	if _raster_state == state:
		return
	_raster_state = state
	if state == &"READY":
		print("P6 waterline raster state: READY")
	else:
		push_warning("P6 waterline raster state: %s" % state)


func _pack_raster_params(view_projection: Projection, inverse_view_projection: Projection, camera: Vector3, sea_level: float, sources: Dictionary) -> PackedFloat32Array:
	var domains: Vector3 = sources.get("domains", Vector3.ONE)
	var long_fade: Vector2 = sources.get("long_fade", Vector2(0.0, 1.0))
	var mid_fade: Vector2 = sources.get("mid_fade", Vector2(0.0, 1.0))
	var short_fade: Vector2 = sources.get("short_fade", Vector2(0.0, 1.0))
	var values := _pack_projection(view_projection)
	values.append_array(_pack_projection(inverse_view_projection))
	values.append_array([camera.x, camera.y, camera.z, sea_level, domains.x, domains.y, domains.z, 0.0, long_fade.x, long_fade.y, 0.0, 0.0, mid_fade.x, mid_fade.y, 0.0, 0.0, short_fade.x, short_fade.y, 0.0, 0.0])
	return values


func _pack_camera_state_params(camera: Vector3, sea_level: float, sources: Dictionary) -> PackedFloat32Array:
	var domains: Vector3 = sources.get("domains", Vector3.ONE)
	var long_fade: Vector2 = sources.get("long_fade", Vector2(0.0, 1.0))
	var mid_fade: Vector2 = sources.get("mid_fade", Vector2(0.0, 1.0))
	var short_fade: Vector2 = sources.get("short_fade", Vector2(0.0, 1.0))
	return PackedFloat32Array([camera.x, camera.y, camera.z, sea_level, domains.x, domains.y, domains.z, 0.0, long_fade.x, long_fade.y, 0.0, 0.0, mid_fade.x, mid_fade.y, 0.0, 0.0, short_fade.x, short_fade.y, 0.0, 0.0])


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
	for rid in [_raster_pipeline, _framebuffer, _mask_texture, _ocean_depth_texture, _depth_texture]:
		if rid.is_valid(): _rd.free_rid(rid)
	_raster_pipeline = RID(); _framebuffer = RID()
	_mask_texture = RID(); _ocean_depth_texture = RID(); _depth_texture = RID(); _target_size = Vector2i.ZERO


func _release_raster_static() -> void:
	_release_targets()
	for geometry in _raster_geometry:
		for key in ["vertex_array", "index_array", "vertex_buffer", "index_buffer"]:
			var rid: RID = geometry.get(key, RID())
			if rid.is_valid(): _rd.free_rid(rid)
	_raster_geometry.clear()
	for rid in [_raster_shader, _raster_sampler, _raster_params]:
		if rid.is_valid(): _rd.free_rid(rid)
	_raster_shader = RID(); _raster_sampler = RID(); _raster_params = RID()
	_vertex_format = -1; _raster_geometry_generation = -1


func _release_resources() -> void:
	if _bubbles != null:
		_bubbles.shutdown()
		_bubbles = null
	_bubble_settings_applied_generation = -1
	_release_raster_static()
	for rid in [_compute_pipeline, _compute_shader, _compute_sampler, _compute_params, _camera_state_pipeline, _camera_state_shader, _camera_state_params, _camera_state]:
		if rid.is_valid(): _rd.free_rid(rid)
	_compute_pipeline = RID(); _compute_shader = RID(); _compute_sampler = RID(); _compute_params = RID()
	_camera_state_pipeline = RID(); _camera_state_shader = RID(); _camera_state_params = RID(); _camera_state = RID()
