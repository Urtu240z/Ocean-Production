extends RefCounted
## Validation-only sampler for Production FFT and Coastal textures. All work is
## queued on the global RenderingDevice render thread; only a tiny result SSBO
## is read asynchronously.

const LOCAL_SIZE_X := 64
const OUTPUT_VECS_PER_SAMPLE := 18

var _owner: Object
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _wave_sampler := RID()
var _coastal_sampler := RID()
var _textures: Array[RID] = []


func initialize(owner: Object, textures: Array[RID], shader_file: RDShaderFile) -> void:
	_owner = owner
	_rd = RenderingServer.get_rendering_device()
	_textures = textures.duplicate()
	if _rd == null or textures.size() != 5 or shader_file == null:
		_owner.call_deferred("_on_phys3_probe_initialized", false, "Global RenderingDevice, five source textures, or shader is unavailable.")
		return
	for texture in textures:
		if not texture.is_valid():
			_owner.call_deferred("_on_phys3_probe_initialized", false, "A Production FFT/Coastal texture RID is invalid.")
			return
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "PHYS3.Validation.CoastalAndFFTProbe")
	if not _shader.is_valid():
		_owner.call_deferred("_on_phys3_probe_initialized", false, "Could not create Coastal validation shader.")
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_owner.call_deferred("_on_phys3_probe_initialized", false, "Could not create Coastal validation pipeline.")
		return
	var wave_state := RDSamplerState.new()
	wave_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	wave_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	wave_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	wave_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_wave_sampler = _rd.sampler_create(wave_state)
	var coastal_state := RDSamplerState.new()
	coastal_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	coastal_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	coastal_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	coastal_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_coastal_sampler = _rd.sampler_create(coastal_state)
	if not _wave_sampler.is_valid() or not _coastal_sampler.is_valid():
		_owner.call_deferred("_on_phys3_probe_initialized", false, "Could not create Production-matching samplers.")
		return
	_owner.call_deferred("_on_phys3_probe_initialized", true, "")


func dispatch_request(request: Dictionary, coordinates: PackedFloat32Array,
					  detj_safe: float) -> void:
	var count := int(request.get("sample_count", 0))
	if _rd == null or not _pipeline.is_valid() or count <= 0 or coordinates.size() != count * 16:
		_owner.call_deferred("_on_phys3_probe_readback", request, PackedByteArray(), "Probe is uninitialized or coordinate packet has the wrong length.")
		return
	var coordinate_buffer := _rd.storage_buffer_create(coordinates.size() * 4, coordinates.to_byte_array())
	var result_bytes := count * OUTPUT_VECS_PER_SAMPLE * 16
	var result_buffer := _rd.storage_buffer_create(result_bytes)
	if not coordinate_buffer.is_valid() or not result_buffer.is_valid():
		_release_buffers(coordinate_buffer, result_buffer, [])
		_owner.call_deferred("_on_phys3_probe_readback", request, PackedByteArray(), "Could not allocate tiny Coastal probe buffers.")
		return
	var uniforms: Array[RDUniform] = []
	for binding in 5:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = binding
		uniform.add_id(_wave_sampler if binding < 3 else _coastal_sampler)
		uniform.add_id(_textures[binding])
		uniforms.append(uniform)
	var coordinates_uniform := RDUniform.new()
	coordinates_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	coordinates_uniform.binding = 5
	coordinates_uniform.add_id(coordinate_buffer)
	uniforms.append(coordinates_uniform)
	var result_uniform := RDUniform.new()
	result_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	result_uniform.binding = 6
	result_uniform.add_id(result_buffer)
	uniforms.append(result_uniform)
	var uniform_set := _rd.uniform_set_create(uniforms, _shader, 0)
	if not uniform_set.is_valid():
		_release_buffers(coordinate_buffer, result_buffer, [])
		_owner.call_deferred("_on_phys3_probe_readback", request, PackedByteArray(), "Could not bind Production Coastal textures to the probe.")
		return
	var push := PackedByteArray()
	push.append_array(PackedInt32Array([count, 0, 0, 0]).to_byte_array())
	push.append_array(PackedFloat32Array([0.0, detj_safe, 0.0, 0.0]).to_byte_array())
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, push, 32)
	_rd.compute_list_dispatch(list, ceili(float(count) / float(LOCAL_SIZE_X)), 1, 1)
	_rd.compute_list_end()
	request["result_buffer_bytes"] = result_bytes
	var err := _rd.buffer_get_data_async(result_buffer,
		_on_readback.bind(request, coordinate_buffer, result_buffer, uniform_set), 0, result_bytes)
	if err != OK:
		_release_buffers(coordinate_buffer, result_buffer, [uniform_set])
		_owner.call_deferred("_on_phys3_probe_readback", request, PackedByteArray(), "buffer_get_data_async failed with Error %d." % err)


func shutdown() -> void:
	if _rd == null:
		return
	for resource in [_pipeline, _shader, _wave_sampler, _coastal_sampler]:
		if resource.is_valid():
			_rd.free_rid(resource)
	_pipeline = RID()
	_shader = RID()
	_wave_sampler = RID()
	_coastal_sampler = RID()
	_textures.clear()
	_rd = null


func _on_readback(bytes: PackedByteArray, request: Dictionary,
				  coordinate_buffer: RID, result_buffer: RID, uniform_set: RID) -> void:
	RenderingServer.call_on_render_thread(_release_buffers.bind(coordinate_buffer, result_buffer, [uniform_set]))
	_owner.call_deferred("_on_phys3_probe_readback", request, bytes, "")


func _release_buffers(coordinate_buffer: RID, result_buffer: RID, uniform_sets: Array) -> void:
	if _rd == null:
		return
	for resource in uniform_sets + [coordinate_buffer, result_buffer]:
		if resource is RID and resource.is_valid():
			_rd.free_rid(resource)
