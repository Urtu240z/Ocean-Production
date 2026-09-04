@tool
class_name OceanSSPREffect
extends CompositorEffect
## Render-thread P5 implementation. SSPR is a color+confidence producer only;
## the ocean material owns the PBR/IBL fallback through RADIANCE alpha.

const PROJECT := preload("res://addons/ocean/reflections/shaders/ocean_sspr_project.glsl")
const RESOLVE := preload("res://addons/ocean/reflections/shaders/ocean_sspr_resolve.glsl")
const TEMPORAL := preload("res://addons/ocean/reflections/shaders/ocean_sspr_temporal.glsl")
const DOWNSAMPLE := preload("res://addons/ocean/reflections/shaders/ocean_sspr_downsample.glsl")
const THREAD := 8
const PARAMS_BYTES := 240
const TEMPORAL_PARAMS_BYTES := 176

var _rd: RenderingDevice
var _project_shader := RID()
var _resolve_shader := RID()
var _temporal_shader := RID()
var _downsample_shader := RID()
var _project_pipeline := RID()
var _resolve_pipeline := RID()
var _temporal_pipeline := RID()
var _downsample_pipeline := RID()
var _sampler := RID()
var _params := RID()
var _temporal_params := RID()
var _candidate := RID()
var _raw := RID()
var _depth := RID()
var _final := RID()
var _history_color_read := RID()
var _history_color_write := RID()
var _history_depth_read := RID()
var _history_depth_write := RID()
var _mips: Array[RID] = []
var _retired: Array[RID] = []
var _candidate_clear_bytes := PackedByteArray()
var _source_size := Vector2i.ZERO
var _target_size := Vector2i.ZERO
var _active := true
var _ocean_level := 0.0
var _scale := 0.40
var _temporal_enabled := true
var _temporal_weight := 0.12
var _depth_threshold := 0.035
var _history_valid := false
var _previous_view_projection := Projection()
var _output := RID()
var _mutex := Mutex.new()
var _failed := false

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()

func configure(ocean_level: float, scale: float, temporal_enabled: bool, weight: float, threshold: float) -> void:
	_mutex.lock()
	_ocean_level = ocean_level
	_scale = clampf(scale, 0.25, 1.0)
	_temporal_enabled = temporal_enabled
	_temporal_weight = clampf(weight, 0.0, 0.5)
	_depth_threshold = clampf(threshold, 0.001, 0.25)
	_history_valid = false
	_mutex.unlock()

func set_active(value: bool) -> void:
	_mutex.lock()
	_active = value
	_history_valid = false
	_mutex.unlock()

func get_output_rid() -> RID:
	_mutex.lock()
	var result := _output
	_mutex.unlock()
	return result

func get_source_size() -> Vector2i:
	return _source_size

func get_target_size() -> Vector2i:
	return _target_size

func release_retired(rid: RID) -> void:
	if _rd != null and rid.is_valid() and _retired.has(rid):
		_retired.erase(rid)
		_rd.free_rid(rid)

func free_resources() -> void:
	if _rd == null: return
	_mutex.lock()
	_output = RID()
	_mutex.unlock()
	for rid in [_candidate, _params, _temporal_params, _sampler, _raw, _depth, _history_color_read, _history_color_write, _history_depth_read, _history_depth_write]:
		if rid.is_valid(): _rd.free_rid(rid)
	for rid in _mips:
		if rid.is_valid(): _rd.free_rid(rid)
	if _final.is_valid(): _rd.free_rid(_final)
	for rid in _retired:
		if rid.is_valid(): _rd.free_rid(rid)
	for rid in [_project_pipeline, _resolve_pipeline, _temporal_pipeline, _downsample_pipeline, _project_shader, _resolve_shader, _temporal_shader, _downsample_shader]:
		if rid.is_valid(): _rd.free_rid(rid)
	_candidate = RID(); _params = RID(); _temporal_params = RID(); _sampler = RID()
	_raw = RID(); _depth = RID(); _final = RID(); _history_color_read = RID(); _history_color_write = RID(); _history_depth_read = RID(); _history_depth_write = RID(); _mips.clear(); _retired.clear()
	_project_pipeline = RID(); _resolve_pipeline = RID(); _temporal_pipeline = RID(); _downsample_pipeline = RID(); _project_shader = RID(); _resolve_shader = RID(); _temporal_shader = RID(); _downsample_shader = RID()
	_source_size = Vector2i.ZERO; _target_size = Vector2i.ZERO; _history_valid = false; _failed = false

func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT or _rd == null or _failed: return
	_mutex.lock()
	var active := _active; var sea_level := _ocean_level; var scale := _scale
	var temporal_enabled := _temporal_enabled; var temporal_weight := _temporal_weight; var threshold := _depth_threshold
	_mutex.unlock()
	if not active or not _ensure_pipelines(): return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var data := render_data.get_render_scene_data()
	if buffers == null or data == null: return
	var source := buffers.get_internal_size()
	if source.x <= 0 or source.y <= 0 or source.x > 65535 or source.y > 65535 or buffers.get_view_count() != 1: return
	var target := Vector2i(maxi(1, ceili(source.x * scale)), maxi(1, ceili(source.y * scale)))
	if not _ensure_resources(source, target): return
	var scene_color := buffers.get_color_layer(0); var scene_depth := buffers.get_depth_layer(0)
	if not scene_color.is_valid() or not scene_depth.is_valid(): return
	var projection: Projection = data.get_view_projection(0)
	var camera: Transform3D = data.get_cam_transform()
	var view_projection: Projection = projection * Projection(camera.affine_inverse())
	_rd.buffer_update(_params, 0, PARAMS_BYTES, _pack_params(projection.inverse(), Projection(camera), view_projection, source, target, sea_level).to_byte_array())
	_rd.buffer_update(_temporal_params, 0, TEMPORAL_PARAMS_BYTES, _pack_temporal(view_projection.inverse(), view_projection, target, sea_level, temporal_enabled, temporal_weight, threshold, _history_valid).to_byte_array())
	_rd.buffer_update(_candidate, 0, _candidate_clear_bytes.size(), _candidate_clear_bytes)
	var project_set := _project_set(scene_depth)
	var resolve_set := _resolve_set(scene_color, scene_depth)
	var temporal_set := _temporal_set()
	if not _valid_set(project_set) or not _valid_set(resolve_set) or not _valid_set(temporal_set): return
	var list := _rd.compute_list_begin()
	_bind_dispatch(list, _project_pipeline, project_set, source)
	_rd.compute_list_add_barrier(list)
	_bind_dispatch(list, _resolve_pipeline, resolve_set, target)
	_rd.compute_list_add_barrier(list)
	_bind_dispatch(list, _temporal_pipeline, temporal_set, target)
	_rd.compute_list_add_barrier(list)
	for mip in range(1, _mips.size()):
		var set := _mip_set(mip)
		if not _valid_set(set): continue
		_bind_dispatch(list, _downsample_pipeline, set, Vector2i(maxi(1,target.x >> mip), maxi(1,target.y >> mip)))
		if mip + 1 < _mips.size(): _rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	_previous_view_projection = view_projection
	_history_valid = true
	var color_swap := _history_color_read; _history_color_read = _history_color_write; _history_color_write = color_swap
	var depth_swap := _history_depth_read; _history_depth_read = _history_depth_write; _history_depth_write = depth_swap

func _bind_dispatch(list: int, pipeline: RID, set: RID, size: Vector2i) -> void:
	_rd.compute_list_bind_compute_pipeline(list, pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD), ceili(float(size.y) / THREAD), 1)

func _valid_set(set: RID) -> bool:
	return set.is_valid() and _rd.uniform_set_is_valid(set)

func _ensure_pipelines() -> bool:
	if _project_pipeline.is_valid(): return true
	_project_shader = _shader(PROJECT, "OceanSSPR.Project")
	_resolve_shader = _shader(RESOLVE, "OceanSSPR.Resolve")
	_temporal_shader = _shader(TEMPORAL, "OceanSSPR.Temporal")
	_downsample_shader = _shader(DOWNSAMPLE, "OceanSSPR.Downsample")
	if not _project_shader.is_valid() or not _resolve_shader.is_valid() or not _temporal_shader.is_valid() or not _downsample_shader.is_valid(): return _fail("shader creation")
	_project_pipeline = _rd.compute_pipeline_create(_project_shader); _resolve_pipeline = _rd.compute_pipeline_create(_resolve_shader); _temporal_pipeline = _rd.compute_pipeline_create(_temporal_shader); _downsample_pipeline = _rd.compute_pipeline_create(_downsample_shader)
	return _project_pipeline.is_valid() and _resolve_pipeline.is_valid() and _temporal_pipeline.is_valid() and _downsample_pipeline.is_valid() or _fail("pipeline creation")

func _shader(file: RDShaderFile, label: String) -> RID:
	return _rd.shader_create_from_spirv(file.get_spirv(), label) if file != null else RID()

func _fail(reason: String) -> bool:
	_failed = true
	push_error("OceanSSPR disabled: %s" % reason)
	return false

func _ensure_resources(source: Vector2i, target: Vector2i) -> bool:
	if source == _source_size and target == _target_size and _final.is_valid(): return true
	if _final.is_valid(): _retired.append(_final)
	for rid in [_candidate, _params, _temporal_params, _raw, _depth, _history_color_read, _history_color_write, _history_depth_read, _history_depth_write]:
		if rid.is_valid(): _rd.free_rid(rid)
	for mip in _mips:
		if mip.is_valid(): _rd.free_rid(mip)
	_mips.clear(); _source_size = source; _target_size = target; _history_valid = false
	var candidate_clear := PackedInt32Array()
	candidate_clear.resize(target.x * target.y)
	_candidate_clear_bytes = candidate_clear.to_byte_array()
	_candidate = _rd.storage_buffer_create(_candidate_clear_bytes.size(), _candidate_clear_bytes)
	_params = _rd.uniform_buffer_create(PARAMS_BYTES); _temporal_params = _rd.uniform_buffer_create(TEMPORAL_PARAMS_BYTES)
	var color := RDTextureFormat.new(); color.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT; color.width = target.x; color.height = target.y; color.texture_type = RenderingDevice.TEXTURE_TYPE_2D; color.mipmaps = _mip_count(target); color.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_final = _rd.texture_create(color, RDTextureView.new())
	for mip in range(color.mipmaps):
		_mips.append(_rd.texture_create_shared_from_slice(RDTextureView.new(), _final, 0, mip, 1))
	var single_color := RDTextureFormat.new(); single_color.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT; single_color.width=target.x; single_color.height=target.y; single_color.texture_type=RenderingDevice.TEXTURE_TYPE_2D; single_color.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_raw=_rd.texture_create(single_color,RDTextureView.new()); _history_color_read=_rd.texture_create(single_color,RDTextureView.new()); _history_color_write=_rd.texture_create(single_color,RDTextureView.new())
	var depth := RDTextureFormat.new(); depth.format=RenderingDevice.DATA_FORMAT_R16_SFLOAT; depth.width=target.x; depth.height=target.y; depth.texture_type=RenderingDevice.TEXTURE_TYPE_2D; depth.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	_depth=_rd.texture_create(depth,RDTextureView.new()); _history_depth_read=_rd.texture_create(depth,RDTextureView.new()); _history_depth_write=_rd.texture_create(depth,RDTextureView.new())
	if not _sampler.is_valid():
		var state := RDSamplerState.new(); state.mag_filter=RenderingDevice.SAMPLER_FILTER_LINEAR; state.min_filter=RenderingDevice.SAMPLER_FILTER_LINEAR; state.mip_filter=RenderingDevice.SAMPLER_FILTER_LINEAR; state.repeat_u=RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE; state.repeat_v=RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE; _sampler=_rd.sampler_create(state)
	_mutex.lock(); _output = _final; _mutex.unlock()
	return _candidate.is_valid() and _params.is_valid() and _temporal_params.is_valid() and _raw.is_valid() and _depth.is_valid() and _final.is_valid() and _mips.size() > 0 and _history_color_read.is_valid() and _history_depth_read.is_valid() and _sampler.is_valid()

func _mip_count(size: Vector2i) -> int: return floori(log(float(maxi(size.x,size.y)))/log(2.0))+1
func _uniform(type: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		uniform.add_id(id)
	return uniform
func _project_set(scene_depth: RID) -> RID: return UniformSetCacheRD.get_cache(_project_shader,0,[_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,0,[_sampler,scene_depth]),_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,1,[_candidate]),_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,2,[_params])])
func _resolve_set(scene_color: RID, scene_depth: RID) -> RID: return UniformSetCacheRD.get_cache(_resolve_shader,0,[_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,0,[_sampler,scene_color]),_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER,1,[_candidate]),_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,2,[_raw]),_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,3,[_params]),_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,4,[_depth]),_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,5,[_sampler,scene_depth])])
func _temporal_set() -> RID: return UniformSetCacheRD.get_cache(_temporal_shader,0,[_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,0,[_sampler,_raw]),_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,1,[_sampler,_depth]),_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,2,[_sampler,_history_color_read]),_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,3,[_sampler,_history_depth_read]),_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,4,[_mips[0]]),_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,5,[_history_color_write]),_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,6,[_history_depth_write]),_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER,7,[_temporal_params])])
func _mip_set(mip: int) -> RID: return UniformSetCacheRD.get_cache(_downsample_shader,0,[_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE,0,[_sampler,_mips[mip-1]]),_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE,1,[_mips[mip]])])
func _pack_params(inverse_projection: Projection, inverse_view: Projection, view_projection: Projection, source: Vector2i, target: Vector2i, sea_level: float) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for matrix in [inverse_projection, inverse_view, view_projection]:
		for column in [matrix.x, matrix.y, matrix.z, matrix.w]:
			values.append_array([column.x, column.y, column.z, column.w])
	values.append_array([source.x, source.y, 0.0, 0.0, target.x, target.y, 0.0, 0.0, sea_level, 0.0, 0.0, 0.0])
	return values
func _pack_temporal(inverse_vp: Projection, vp: Projection, target: Vector2i, sea: float, enabled: bool, weight: float, threshold: float, history: bool) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for matrix in [inverse_vp, vp]:
		for column in [matrix.x, matrix.y, matrix.z, matrix.w]:
			values.append_array([column.x, column.y, column.z, column.w])
	values.append_array([target.x, target.y, 0.0, 0.0, 1.0 if enabled else 0.0, weight, threshold, 1.0 if history else 0.0, sea, 0.0, 0.0, 0.0])
	return values
