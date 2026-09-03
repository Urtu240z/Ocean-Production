class_name OceanGPUStockhamFFT
extends RefCounted
## Una banda FFT y, cuando Crest está activo, su acumulador V3 RG16F.

const EVOLVE_SHADER := "res://addons/ocean/shaders/fft/evolve_spectrum.glsl"
const STOCKHAM_SHADER := "res://addons/ocean/shaders/fft/stockham_ifft.glsl"
const ASSEMBLE_SHADER := "res://addons/ocean/shaders/fft/assemble_maps.glsl"
const UPDATE_CREST_SHADER := preload("res://addons/ocean/shaders/fft/update_crest_foam.glsl")
const STORE_PREVIOUS_SHADER := preload("res://addons/ocean/shaders/fft/store_crest_previous_displacement.glsl")

var ready := false
var last_error := ""
var displacement_rid := RID()
var normal_rid := RID()
var crest_foam_rid := RID()

var _rd: RenderingDevice
var _config: Resource
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _ping_c: Array[RID] = [RID(), RID()]
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _uniform_sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_set := RID()

var _crest_enabled := false
var _crest_shaders: Array[RID] = [RID(), RID()]
var _crest_pipelines: Array[RID] = [RID(), RID()]
var _crest_resolution := 1024
var _crest_accumulator := 0.0
var _crest_ping: Array[RID] = [RID(), RID()]
var _previous_displacement: Array[RID] = [RID(), RID()]
var _crest_read_index := 0
var _previous_read_index := 0
var _crest_sampler := RID()
var _crest_sets: Array[RID] = []
var _store_sets: Array[RID] = []


func initialize(config: Resource, h0_data: PackedByteArray, resource_prefix: String) -> void:
	shutdown()
	_config = config
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		return
	for item in [[EVOLVE_SHADER, ".Evolve"], [STOCKHAM_SHADER, ".Stockham"], [ASSEMBLE_SHADER, ".Assemble"]]:
		if not _create_pipeline(item[0], resource_prefix + item[1]).is_valid():
			shutdown()
			return
	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", h0_data, true)
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingA%d" % index)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingB%d" % index)
		_ping_c[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingC%d" % index)
	displacement_rid = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".Displacement")
	var normal_data := PackedByteArray()
	normal_data.resize(_config.resolution * _config.resolution * 8)
	normal_rid = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, resource_prefix + ".Normal", normal_data)
	_evolve_set = _create_image_set(_shaders[0], [_h0, _h0, _ping_a[0], _ping_b[0], _ping_c[0]])
	_fft_sets[0] = _create_image_set(_shaders[1], [_ping_a[0], _ping_b[0], _ping_c[0], _ping_a[1], _ping_b[1], _ping_c[1]])
	_fft_sets[1] = _create_image_set(_shaders[1], [_ping_a[1], _ping_b[1], _ping_c[1], _ping_a[0], _ping_b[0], _ping_c[0]])
	_assemble_set = _create_image_set(_shaders[2], [_ping_a[0], _ping_b[0], _ping_c[0], displacement_rid, normal_rid])
	ready = _evolve_set.is_valid() and _fft_sets[0].is_valid() and _fft_sets[1].is_valid() and _assemble_set.is_valid()
	if not ready: last_error = "No se pudieron crear los uniform sets de %s." % resource_prefix


func set_crest_foam_resolution(resolution: int) -> void:
	_crest_resolution = resolution


func set_crest_foam_enabled(enabled: bool) -> void:
	if _crest_enabled == enabled or _rd == null: return
	_crest_enabled = enabled
	if _crest_enabled: _create_crest_resources()
	else: _free_crest_resources()


func dispatch(render_time: float, delta_s: float) -> void:
	if not ready: return
	var groups := ceili(float(_config.resolution) / 8.0)
	var crest_delta := _prepare_crest_update(delta_s)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[0])
	_rd.compute_list_bind_uniform_set(list, _evolve_set, 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([render_time, _config.gravity_mps2, _config.choppiness, _config.domain_size_m, 0.0]).to_byte_array(), 20)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[1])
	var pass_index := 0
	for axis in 2:
		var stage_size := 2
		for _stage in _config.fft_stage_count():
			_rd.compute_list_bind_uniform_set(list, _fft_sets[pass_index % 2], 0)
			_rd.compute_list_set_push_constant(list, PackedInt32Array([stage_size, axis, _config.resolution, 1]).to_byte_array(), 16)
			_rd.compute_list_dispatch(list, groups, groups, 1)
			_rd.compute_list_add_barrier(list)
			stage_size *= 2
			pass_index += 1
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[2])
	_rd.compute_list_bind_uniform_set(list, _assemble_set, 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([_config.domain_size_m, 1.0 / float(_config.resolution * _config.resolution), _config.domain_size_m / float(_config.resolution), 0.0]).to_byte_array(), 16)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_add_barrier(list)
	_dispatch_crest(list, groups, crest_delta)
	_rd.compute_list_end()


func shutdown() -> void:
	ready = false
	if _rd == null: return
	_free_crest_resources()
	for uniform_set in _uniform_sets:
		if uniform_set.is_valid(): _rd.free_rid(uniform_set)
	_uniform_sets.clear()
	for texture in [_h0, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], _ping_c[0], _ping_c[1], displacement_rid, normal_rid]:
		if texture.is_valid(): _rd.free_rid(texture)
	for pipeline in _pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_shaders.clear(); _pipelines.clear(); _h0 = RID(); _ping_a = [RID(), RID()]; _ping_b = [RID(), RID()]; _ping_c = [RID(), RID()]
	displacement_rid = RID(); normal_rid = RID(); crest_foam_rid = RID(); _evolve_set = RID(); _fft_sets = [RID(), RID()]; _assemble_set = RID(); _rd = null


func _prepare_crest_update(delta_s: float) -> float:
	if not _crest_enabled or _crest_sets.is_empty(): return 0.0
	_crest_accumulator += maxf(delta_s, 0.0)
	if _crest_accumulator < 1.0 / 30.0: return 0.0
	var crest_delta := _crest_accumulator
	_crest_accumulator = fmod(_crest_accumulator, 1.0 / 30.0)
	return crest_delta


func _dispatch_crest(list: int, groups: int, crest_delta: float) -> void:
	if crest_delta <= 0.0: return
	_rd.compute_list_bind_compute_pipeline(list, _crest_pipelines[0])
	_rd.compute_list_bind_uniform_set(list, _crest_sets[_previous_read_index * 2 + _crest_read_index], 0)
	_rd.compute_list_set_push_constant(list, PackedByteArray(), 0)
	var foam_groups := ceili(float(_crest_resolution) / 8.0)
	_rd.compute_list_dispatch(list, foam_groups, foam_groups, 1)
	_crest_read_index = 1 - _crest_read_index
	crest_foam_rid = _crest_ping[_crest_read_index]
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _crest_pipelines[1])
	_rd.compute_list_bind_uniform_set(list, _store_sets[_previous_read_index], 0)
	_rd.compute_list_set_push_constant(list, PackedByteArray(), 0)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_previous_read_index = 1 - _previous_read_index
	_rd.compute_list_add_barrier(list)


func _create_crest_resources() -> void:
	if not ready or _crest_ping[0].is_valid(): return
	if not _create_crest_pipeline(UPDATE_CREST_SHADER, "Ocean.UpdateCrest", 0) or not _create_crest_pipeline(STORE_PREVIOUS_SHADER, "Ocean.StoreCrestPrevious", 1):
		_free_crest_resources()
		return
	var initial := PackedByteArray(); initial.resize(_crest_resolution * _crest_resolution * 4)
	_crest_ping[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestFoamA", initial, false, _crest_resolution)
	_crest_ping[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestFoamB", initial, false, _crest_resolution)
	var snapshots := PackedByteArray(); snapshots.resize(_config.resolution * _config.resolution * 4)
	_previous_displacement[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestPreviousA", snapshots)
	_previous_displacement[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestPreviousB", snapshots)
	var state := RDSamplerState.new(); state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST; state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_crest_sampler = _rd.sampler_create(state)
	for snapshot_index in 2:
		for foam_index in 2:
			_crest_sets.append(_create_crest_set(_crest_shaders[0], _previous_displacement[snapshot_index], _crest_ping[foam_index], _crest_ping[1 - foam_index]))
		_store_sets.append(_create_store_set(_crest_shaders[1], _previous_displacement[(snapshot_index + 1) % 2]))
	_crest_read_index = 0; _previous_read_index = 0; _crest_accumulator = 0.0; crest_foam_rid = _crest_ping[0]


func _free_crest_resources() -> void:
	if _rd == null: return
	for uniform_set in _crest_sets + _store_sets:
		if uniform_set.is_valid(): _rd.free_rid(uniform_set)
		_uniform_sets.erase(uniform_set)
	for texture in _crest_ping + _previous_displacement:
		if texture.is_valid(): _rd.free_rid(texture)
	if _crest_sampler.is_valid(): _rd.free_rid(_crest_sampler)
	for pipeline in _crest_pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _crest_shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_crest_sets.clear(); _store_sets.clear(); _crest_ping = [RID(), RID()]; _previous_displacement = [RID(), RID()]; _crest_sampler = RID(); _crest_shaders = [RID(), RID()]; _crest_pipelines = [RID(), RID()]; crest_foam_rid = RID(); _crest_accumulator = 0.0


func _create_crest_set(shader: RID, previous_displacement: RID, previous_foam: RID, next_foam: RID) -> RID:
	var output := RDUniform.new(); output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding = 3; output.add_id(next_foam)
	var set := _rd.uniform_set_create([_sampler_uniform(0, displacement_rid), _sampler_uniform(1, previous_displacement), _sampler_uniform(2, previous_foam), output], shader, 0)
	_uniform_sets.append(set)
	return set


func _create_store_set(shader: RID, destination: RID) -> RID:
	var source := RDUniform.new(); source.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; source.binding = 0; source.add_id(displacement_rid)
	var output := RDUniform.new(); output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding = 1; output.add_id(destination)
	var set := _rd.uniform_set_create([source, output], shader, 0)
	_uniform_sets.append(set)
	return set


func _sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new(); uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; uniform.binding = binding; uniform.add_id(_crest_sampler); uniform.add_id(texture)
	return uniform


func _create_pipeline(path: String, resource_name: String) -> RID:
	var file := load(path) as RDShaderFile
	if file == null: last_error = "No se pudo cargar %s" % path; return RID()
	var shader := _rd.shader_create_from_spirv(file.get_spirv(), resource_name)
	if not shader.is_valid(): last_error = "No se pudo compilar %s" % path; return RID()
	var pipeline := _rd.compute_pipeline_create(shader); _shaders.append(shader); _pipelines.append(pipeline)
	return pipeline


func _create_crest_pipeline(shader_file: RDShaderFile, resource_name: String, index: int) -> bool:
	if shader_file == null:
		last_error = "No se pudo cargar shader Crest."
		return false
	var shader := _rd.shader_create_from_spirv(shader_file.get_spirv(), resource_name)
	if not shader.is_valid():
		last_error = "No se pudo compilar %s" % resource_name
		return false
	var pipeline := _rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		_rd.free_rid(shader)
		last_error = "No se pudo crear pipeline %s" % resource_name
		return false
	_crest_shaders[index] = shader
	_crest_pipelines[index] = pipeline
	return true


func _create_texture(format: int, resource_name: String, data := PackedByteArray(), allow_update := false, resolution_override := 0) -> RID:
	var format_info := RDTextureFormat.new(); format_info.format = format as RenderingDevice.DataFormat; format_info.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	var resolution: int = resolution_override if resolution_override > 0 else int(_config.resolution)
	format_info.width = resolution; format_info.height = resolution; format_info.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if allow_update: format_info.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial: Array[PackedByteArray] = []; if not data.is_empty(): initial.append(data)
	var texture := _rd.texture_create(format_info, RDTextureView.new(), initial); _rd.set_resource_name(texture, resource_name)
	return texture


func _create_image_set(shader: RID, textures: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in textures.size():
		var uniform := RDUniform.new(); uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; uniform.binding = binding; uniform.add_id(textures[binding]); uniforms.append(uniform)
	var set := _rd.uniform_set_create(uniforms, shader, 0); _uniform_sets.append(set)
	return set
