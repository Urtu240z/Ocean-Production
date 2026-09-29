extends RefCounted
## Validation-only filtered sampler probe for off-grid Production LONG samples.

const LOCAL_SIZE_X := 64

var _owner: Object
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _source_texture := RID()


func initialize(owner: Object, source_texture: RID, shader_file: RDShaderFile) -> void:
	_owner = owner
	_rd = RenderingServer.get_rendering_device()
	_source_texture = source_texture
	if _rd == null or not source_texture.is_valid() or shader_file == null:
		_owner.call_deferred("_on_linear_probe_initialized", false, "Global RenderingDevice, LONG RID, or linear probe shader is unavailable.")
		return
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "PHYS1.Validation.LongLinearProbe")
	if not _shader.is_valid():
		_owner.call_deferred("_on_linear_probe_initialized", false, "Could not create the linear probe shader.")
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_owner.call_deferred("_on_linear_probe_initialized", false, "Could not create the linear probe compute pipeline.")
		return
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler = _rd.sampler_create(sampler_state)
	if not _sampler.is_valid():
		_owner.call_deferred("_on_linear_probe_initialized", false, "Could not create the repeat-linear sampler.")
		return
	_owner.call_deferred("_on_linear_probe_initialized", true, "")


func dispatch_request(request: Dictionary, uvs: PackedVector2Array) -> void:
	var count := uvs.size()
	if _rd == null or not _pipeline.is_valid() or not _source_texture.is_valid() or count <= 0 or count > 64:
		_owner.call_deferred("_on_linear_probe_readback", request, PackedByteArray(), "Linear probe is unavailable or sample count is outside 1..64.")
		return
	var packed_uvs := PackedFloat32Array()
	packed_uvs.resize(count * 2)
	for index in count:
		packed_uvs[index * 2] = uvs[index].x
		packed_uvs[index * 2 + 1] = uvs[index].y
	var coordinate_buffer := _rd.storage_buffer_create(packed_uvs.size() * 4, packed_uvs.to_byte_array())
	var result_buffer := _rd.storage_buffer_create(count * 16)
	if not coordinate_buffer.is_valid() or not result_buffer.is_valid():
		_release_buffers(coordinate_buffer, result_buffer, RID())
		_owner.call_deferred("_on_linear_probe_readback", request, PackedByteArray(), "Could not allocate filtered probe buffers.")
		return
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	source_uniform.binding = 0
	source_uniform.add_id(_sampler)
	source_uniform.add_id(_source_texture)
	var coordinate_uniform := RDUniform.new()
	coordinate_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	coordinate_uniform.binding = 1
	coordinate_uniform.add_id(coordinate_buffer)
	var result_uniform := RDUniform.new()
	result_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	result_uniform.binding = 2
	result_uniform.add_id(result_buffer)
	var uniform_set := _rd.uniform_set_create([source_uniform, coordinate_uniform, result_uniform], _shader, 0)
	if not uniform_set.is_valid():
		_release_buffers(coordinate_buffer, result_buffer, uniform_set)
		_owner.call_deferred("_on_linear_probe_readback", request, PackedByteArray(), "Could not bind filtered probe resources.")
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, PackedInt32Array([count, 0, 0, 0]).to_byte_array(), 16)
	_rd.compute_list_dispatch(list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
	_rd.compute_list_end()
	var error := _rd.buffer_get_data_async(result_buffer, _on_readback.bind(request, coordinate_buffer, result_buffer, uniform_set), 0, count * 16)
	if error != OK:
		_release_buffers(coordinate_buffer, result_buffer, uniform_set)
		_owner.call_deferred("_on_linear_probe_readback", request, PackedByteArray(), "Linear buffer_get_data_async failed with Error %d." % error)


func shutdown() -> void:
	if _rd == null:
		return
	for resource in [_pipeline, _shader, _sampler]:
		if resource.is_valid():
			_rd.free_rid(resource)
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
	_source_texture = RID()
	_rd = null


func _on_readback(bytes: PackedByteArray, request: Dictionary, coordinate_buffer: RID, result_buffer: RID, uniform_set: RID) -> void:
	RenderingServer.call_on_render_thread(_release_buffers.bind(coordinate_buffer, result_buffer, uniform_set))
	_owner.call_deferred("_on_linear_probe_readback", request, bytes, "")


func _release_buffers(coordinate_buffer: RID, result_buffer: RID, uniform_set: RID) -> void:
	if _rd == null:
		return
	for resource in [uniform_set, coordinate_buffer, result_buffer]:
		if resource.is_valid():
			_rd.free_rid(resource)
