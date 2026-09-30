extends RefCounted
## Focused PHYS-3.1 sampler diagnostics. Reads only small SSBO result packets
## from Production Coastal textures on the global RenderingDevice.

signal completed(request: Dictionary, bytes: PackedByteArray, error: String)
signal initialized(ok: bool, error: String)
signal texture_formats(field: Dictionary, warp: Dictionary)

const SCAN_VECS_PER_SAMPLE := 2
const DETAIL_VECS_PER_SAMPLE := 22
const LOCAL_SIZE_X := 64

var _rd: RenderingDevice
var _shader_scan := RID()
var _pipeline_scan := RID()
var _shader_detail := RID()
var _pipeline_detail := RID()
var _sampler := RID()
var _textures: Array[RID] = []
var _owner: Object


func initialize(owner: Object, textures: Array[RID], scan_file: RDShaderFile, detail_file: RDShaderFile) -> void:
	print("PHYS31_RD initialize_enter")
	_owner = owner
	_rd = RenderingServer.get_rendering_device()
	_textures = textures.duplicate()
	if _rd == null or textures.size() != 2 or scan_file == null or detail_file == null:
		_owner.call_deferred("_on_sampler_probe_initialized", false, "invalid global RD, texture RIDs, or shader resources")
		return
	for texture in textures:
		if not texture.is_valid():
			_owner.call_deferred("_on_sampler_probe_initialized", false, "invalid Coastal texture RID")
			return
	_shader_scan = _rd.shader_create_from_spirv(scan_file.get_spirv(), "PHYS3.1.SamplerScan")
	print("PHYS31_RD scan_shader_created ", _shader_scan.is_valid())
	_shader_detail = _rd.shader_create_from_spirv(detail_file.get_spirv(), "PHYS3.1.SamplerDetail")
	print("PHYS31_RD detail_shader_created ", _shader_detail.is_valid())
	if not _shader_scan.is_valid() or not _shader_detail.is_valid():
		_owner.call_deferred("_on_sampler_probe_initialized", false, "shader compilation failed")
		return
	_pipeline_scan = _rd.compute_pipeline_create(_shader_scan)
	print("PHYS31_RD scan_pipeline_created ", _pipeline_scan.is_valid())
	_pipeline_detail = _rd.compute_pipeline_create(_shader_detail)
	print("PHYS31_RD detail_pipeline_created ", _pipeline_detail.is_valid())
	if not _pipeline_scan.is_valid() or not _pipeline_detail.is_valid():
		_owner.call_deferred("_on_sampler_probe_initialized", false, "compute pipeline creation failed")
		return
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)
	print("PHYS31_RD sampler_created ", _sampler.is_valid())
	_owner.call_deferred("_on_sampler_probe_initialized", _sampler.is_valid(), "" if _sampler.is_valid() else "sampler creation failed")


func request_texture_formats() -> void:
	print("PHYS31_RD format_enter")
	if _rd == null:
		_owner.call_deferred("_on_sampler_texture_formats", {}, {})
		return
	var field: RDTextureFormat = _rd.texture_get_format(_textures[0])
	var warp: RDTextureFormat = _rd.texture_get_format(_textures[1])
	_owner.call_deferred("_on_sampler_texture_formats", _format_dict(field), _format_dict(warp))


func dispatch(request: Dictionary, coordinates: PackedFloat32Array, details: bool) -> void:
	var count := int(request.get("sample_count", 0))
	if _rd == null or count <= 0 or coordinates.size() != count * 4:
		_owner.call_deferred("_on_sampler_probe_completed", request, PackedByteArray(), "invalid probe packet")
		return
	var pipeline := _pipeline_detail if details else _pipeline_scan
	var vectors_per_sample := DETAIL_VECS_PER_SAMPLE if details else SCAN_VECS_PER_SAMPLE
	var coordinate_buffer := _rd.storage_buffer_create(coordinates.size() * 4, coordinates.to_byte_array())
	var result_buffer := _rd.storage_buffer_create(count * vectors_per_sample * 16)
	if not coordinate_buffer.is_valid() or not result_buffer.is_valid():
		_release(coordinate_buffer, result_buffer, [])
		_owner.call_deferred("_on_sampler_probe_completed", request, PackedByteArray(), "could not allocate probe buffers")
		return
	var uniforms: Array[RDUniform] = []
	for binding in 2:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		uniform.binding = binding
		uniform.add_id(_sampler)
		uniform.add_id(_textures[binding])
		uniforms.append(uniform)
	var input_uniform := RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 2
	input_uniform.add_id(coordinate_buffer)
	uniforms.append(input_uniform)
	var output_uniform := RDUniform.new()
	output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	output_uniform.binding = 3
	output_uniform.add_id(result_buffer)
	uniforms.append(output_uniform)
	var shader := _shader_detail if details else _shader_scan
	var uniform_set := _rd.uniform_set_create(uniforms, shader, 0)
	if not uniform_set.is_valid():
		_release(coordinate_buffer, result_buffer, [])
		_owner.call_deferred("_on_sampler_probe_completed", request, PackedByteArray(), "could not create probe uniform set")
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	var push := PackedByteArray()
	push.append_array(PackedInt32Array([count, 0, 0, 0]).to_byte_array())
	_rd.compute_list_set_push_constant(list, push, 16)
	_rd.compute_list_dispatch(list, ceili(float(count) / LOCAL_SIZE_X), 1, 1)
	_rd.compute_list_end()
	request["buffer_bytes"] = count * vectors_per_sample * 16
	var error := _rd.buffer_get_data_async(result_buffer, _on_readback.bind(request, coordinate_buffer, result_buffer, uniform_set), 0, int(request["buffer_bytes"]))
	if error != OK:
		_release(coordinate_buffer, result_buffer, [uniform_set])
		_owner.call_deferred("_on_sampler_probe_completed", request, PackedByteArray(), "buffer_get_data_async error %d" % error)


func shutdown() -> void:
	if _rd == null: return
	for rid in [_pipeline_scan, _pipeline_detail, _shader_scan, _shader_detail, _sampler]:
		if rid.is_valid(): _rd.free_rid(rid)
	_rd = null


func _on_readback(bytes: PackedByteArray, request: Dictionary, coordinate_buffer: RID,
		result_buffer: RID, uniform_set: RID) -> void:
	RenderingServer.call_on_render_thread(_release.bind(coordinate_buffer, result_buffer, [uniform_set]))
	_owner.call_deferred("_on_sampler_probe_completed", request, bytes, "")


func _release(coordinate_buffer: RID, result_buffer: RID, sets: Array) -> void:
	if _rd == null: return
	for rid in sets + [coordinate_buffer, result_buffer]:
		if rid.is_valid(): _rd.free_rid(rid)


func _format_dict(format: RDTextureFormat) -> Dictionary:
	return {"width": format.width, "height": format.height, "format": format.format,
		"texture_type": format.texture_type, "usage_bits": format.usage_bits, "mipmaps": format.mipmaps}
