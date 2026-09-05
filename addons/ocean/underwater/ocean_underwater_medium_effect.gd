@tool
class_name OceanUnderwaterMediumEffect
extends CompositorEffect
## Render-thread P6 raster-waterline compositor. It never mutates Camera3D state.

const SHADER := preload("res://addons/ocean/underwater/shaders/ocean_underwater_medium.glsl")
const THREAD_SIZE := 8
const PARAMS_BYTES := 144
const TARGET_READY_WARNING_FRAMES := 300

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _params := RID()
var _failed := false
var _mutex := Mutex.new()
var _sea_level := 0.0
var _debug_mask_enabled := true
var _absorption := Vector3(0.35, 0.14, 0.10)
var _absorption_scale := 0.43
var _scattering_color := Color(0.0024315654, 0.09275196, 0.13127226)
var _scattering_strength := 1.0
var _scattering_density := 0.15
var _maximum_distance := 120.0
var _waterline_mask := RID()
var _waterline_depth := RID()
var _waterline_targets_ready := false
var _waterline_target_wait_frames := 0
var _waterline_target_warning_emitted := false
var _shutdown_requested := false


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


func set_waterline_targets(mask_texture: RID, depth_texture: RID) -> void:
	if not mask_texture.is_valid() or not depth_texture.is_valid():
		return
	_mutex.lock()
	_waterline_mask = mask_texture
	_waterline_depth = depth_texture
	_waterline_targets_ready = true
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
		for rid in [_pipeline, _shader, _sampler, _params]:
			if rid.is_valid():
				_rd.free_rid(rid)
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
	# The mask is categorical and the depth target is a raw projection value;
	# filtering either would invent a boundary or an ocean-entry distance.
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)
	_params = _rd.uniform_buffer_create(PARAMS_BYTES)
	if _pipeline.is_valid() and _sampler.is_valid() and _params.is_valid():
		return true
	_release_resources()
	return _fail("pipeline resources")


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
	var absorption := _absorption
	var absorption_scale := _absorption_scale
	var scattering_color := _scattering_color
	var scattering_strength := _scattering_strength
	var scattering_density := _scattering_density
	var maximum_distance := _maximum_distance
	var waterline_mask := _waterline_mask
	var waterline_depth := _waterline_depth
	var waterline_targets_ready := _waterline_targets_ready
	_mutex.unlock()
	if not _ensure_pipeline():
		return
	if not waterline_targets_ready or not waterline_mask.is_valid() or not waterline_depth.is_valid():
		_waterline_target_wait_frames += 1
		if _waterline_target_wait_frames >= TARGET_READY_WARNING_FRAMES and not _waterline_target_warning_emitted:
			_waterline_target_warning_emitted = true
			push_warning("Ocean P6 waterline raster is still waiting for valid mask/depth RD targets.")
		return
	_waterline_target_wait_frames = 0
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data()
	if buffers == null or data == null or buffers.get_view_count() != 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color := buffers.get_color_layer(0)
	var depth := buffers.get_depth_layer(0)
	if not color.is_valid() or not depth.is_valid():
		return
	var camera: Transform3D = data.get_cam_transform()
	var projection: Projection = data.get_view_projection(0)
	var inverse_vp: Projection = (projection * Projection(camera.affine_inverse())).inverse()
	_rd.buffer_update(_params, 0, PARAMS_BYTES, _pack_params(inverse_vp, size, camera.origin, sea_level, debug_mask_enabled, absorption_scale, maximum_distance, absorption, scattering_strength, scattering_color, scattering_density).to_byte_array())
	var uniforms := [
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [_sampler, depth]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 2, [_params]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_sampler, waterline_mask]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [_sampler, waterline_depth]),
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


func _pack_params(inverse_vp: Projection, size: Vector2i, camera: Vector3, sea_level: float, debug_mask_enabled: bool, absorption_scale: float, maximum_distance: float, absorption: Vector3, scattering_strength: float, scattering_color: Color, scattering_density: float) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for column in [inverse_vp.x, inverse_vp.y, inverse_vp.z, inverse_vp.w]:
		values.append_array([column.x, column.y, column.z, column.w])
	values.append_array([
		size.x, size.y, 0.0, 0.0,
		camera.x, camera.y, camera.z, 1.0,
		sea_level, maximum_distance, absorption_scale, 1.0 if debug_mask_enabled else 0.0,
		absorption.x, absorption.y, absorption.z, scattering_strength,
		scattering_color.r, scattering_color.g, scattering_color.b, scattering_density,
	])
	return values
