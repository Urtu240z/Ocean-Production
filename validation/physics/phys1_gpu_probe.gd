extends RefCounted
## Validation-only exact texel probe for Production's published LONG displacement RID.
## All RenderingDevice resource/dispatch operations run on the global render thread.

const LOCAL_SIZE_X := 64

var _owner: Object
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _source_texture := RID()


func initialize(owner: Object, source_texture: RID, shader_file: RDShaderFile) -> void:
	_owner = owner
	_rd = RenderingServer.get_rendering_device()
	_source_texture = source_texture
	if _rd == null or not source_texture.is_valid() or shader_file == null:
		_owner.call_deferred("_on_gpu_probe_initialized", false, "Global RenderingDevice, LONG RID, or probe shader is unavailable.")
		return
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "PHYS1.Validation.LongTexelProbe")
	if not _shader.is_valid():
		_owner.call_deferred("_on_gpu_probe_initialized", false, "Could not create the validation probe shader.")
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_owner.call_deferred("_on_gpu_probe_initialized", false, "Could not create the validation probe compute pipeline.")
		return
	_owner.call_deferred("_on_gpu_probe_initialized", true, "")


func dispatch_request(request: Dictionary, texels: PackedVector2Array) -> void:
	if _rd == null or not _pipeline.is_valid() or not _source_texture.is_valid():
		_owner.call_deferred("_on_gpu_probe_readback", request, PackedByteArray(), "Probe is not initialized.")
		return
	var count := texels.size()
	if count <= 0 or count > 64:
		_owner.call_deferred("_on_gpu_probe_readback", request, PackedByteArray(), "Probe supports 1 through 64 exact samples per packet.")
		return
	var packed_texels := PackedInt32Array()
	packed_texels.resize(count * 2)
	for index in count:
		packed_texels[index * 2] = int(texels[index].x)
		packed_texels[index * 2 + 1] = int(texels[index].y)
	var coordinate_buffer := _rd.storage_buffer_create(packed_texels.size() * 4, packed_texels.to_byte_array())
	var result_buffer := _rd.storage_buffer_create(count * 16)
	if not coordinate_buffer.is_valid() or not result_buffer.is_valid():
		_release_buffers(coordinate_buffer, result_buffer, RID())
		_owner.call_deferred("_on_gpu_probe_readback", request, PackedByteArray(), "Could not allocate the small probe buffers.")
		return
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	source_uniform.binding = 0
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
		_owner.call_deferred("_on_gpu_probe_readback", request, PackedByteArray(), "Could not bind the LONG RID and small probe buffers.")
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, PackedInt32Array([count, 0, 0, 0]).to_byte_array(), 16)
	_rd.compute_list_dispatch(list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
	_rd.compute_list_end()
	var error := _rd.buffer_get_data_async(
		result_buffer,
		_on_readback.bind(request, coordinate_buffer, result_buffer, uniform_set),
		0,
		count * 16
	)
	if error != OK:
		_release_buffers(coordinate_buffer, result_buffer, uniform_set)
		_owner.call_deferred("_on_gpu_probe_readback", request, PackedByteArray(), "buffer_get_data_async failed with Error %d." % error)


func shutdown() -> void:
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
	_pipeline = RID()
	_shader = RID()
	_source_texture = RID()
	_rd = null


func _on_readback(bytes: PackedByteArray, request: Dictionary, coordinate_buffer: RID, result_buffer: RID, uniform_set: RID) -> void:
	# Readback callbacks may arrive after later Ocean frames. Keep the original
	# request dictionary intact and never query a new wave_time here.
	RenderingServer.call_on_render_thread(_release_buffers.bind(coordinate_buffer, result_buffer, uniform_set))
	_owner.call_deferred("_on_gpu_probe_readback", request, bytes, "")


func _release_buffers(coordinate_buffer: RID, result_buffer: RID, uniform_set: RID) -> void:
	if _rd == null:
		return
	for resource in [uniform_set, coordinate_buffer, result_buffer]:
		if resource.is_valid():
			_rd.free_rid(resource)
