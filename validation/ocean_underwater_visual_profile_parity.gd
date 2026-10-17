extends SceneTree
## GPU regression using the actual waterline camera shader and CPU packets.
## A known wave has a 2 m horizontal shift and a 1 m crest. Disabling the shift
## must move the detected crest to its visible location, including near crossings.
const EFFECT = preload("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")
const MEDIUM = preload("res://addons/ocean/underwater/ocean_underwater_medium.gd")
const CAMERA_PATH := "res://addons/ocean/underwater/shaders/ocean_waterline_camera_state.glsl"
const RASTER_PATH := "res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl"
var failures: Array[String] = []
var resources: Array[RID] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _source(text: String) -> String:
	return text.replace('#include "res://addons/ocean/shaders/coastal_coverage.gdshaderinc"',
		FileAccess.get_file_as_string("res://addons/ocean/shaders/coastal_coverage.gdshaderinc"))


func _texture(rd: RenderingDevice, wave: bool) -> RID:
	var pixels := PackedFloat32Array()
	for x in 256:
		var q := (float(x) + 0.5) / 256.0 * 8.0 - 4.0
		pixels.append_array([2.0 if wave else 0.0, sin(q * TAU / 8.0) if wave else 0.0, 0.0, 0.0])
	var format := RDTextureFormat.new()
	format.width = 256
	format.height = 1
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var rid := rd.texture_create(format, RDTextureView.new(), [pixels.to_byte_array()])
	resources.append(rid)
	return rid


func _uniform(kind: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = kind
	uniform.binding = binding
	for rid in ids:
		uniform.add_id(rid)
	return uniform


func _run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("Visual profile GPU regression requires Forward+ / RenderingDevice")
		quit(1)
		return
	var camera_source := RDShaderSource.new()
	camera_source.source_compute = _source(FileAccess.get_file_as_string(CAMERA_PATH).replace("#[compute]", ""))
	var spirv := rd.shader_compile_spirv_from_source(camera_source)
	_check(spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE).is_empty(), "Camera shader compiles")
	var shader := rd.shader_create_from_spirv(spirv)
	resources.append(shader)
	var pipeline := rd.compute_pipeline_create(shader)
	resources.append(pipeline)
	var raster_source := RDShaderSource.new()
	var raster_text := FileAccess.get_file_as_string(RASTER_PATH)
	raster_source.source_vertex = _source(raster_text.get_slice("#[fragment]", 0).replace("#[vertex]", ""))
	raster_source.source_fragment = raster_text.get_slice("#[fragment]", 1)
	var raster_spirv := rd.shader_compile_spirv_from_source(raster_source)
	_check(raster_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_VERTEX).is_empty(), "Raster vertex shader compiles")
	_check(raster_spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT).is_empty(), "Raster fragment shader compiles")
	var wave := _texture(rd, true)
	var neutral := _texture(rd, false)
	var sampler_state := RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	var sampler := rd.sampler_create(sampler_state)
	resources.append(sampler)
	var sources := {"long": wave, "mid": neutral, "short": neutral, "breaking_activity_long": neutral,
		"domains": Vector3(8, 8, 8), "ocean_scale": 1.0, "clipmap_geometry_scale": 1.0,
		"long_fade": Vector2(100, 200), "mid_fade": Vector2(100, 200), "short_fade": Vector2(100, 200)}
	var effect := EFFECT.new()
	var medium := MEDIUM.new()
	var before := medium._raster_source_signature(sources)
	sources["visual_horizontal_displacement_scale"] = Vector3(0, 0, 1)
	_check(before != medium._raster_source_signature(sources), "Profile switches republish even when FFT RIDs are unchanged")
	var aligned_signature := medium._raster_source_signature(sources)
	sources["ocean_scale"] = 2.0
	_check(aligned_signature != medium._raster_source_signature(sources), "Height scale edits republish")
	sources["ocean_scale"] = 1.0
	sources["clipmap_geometry_scale"] = 0.5
	_check(aligned_signature != medium._raster_source_signature(sources), "Geometry scale edits republish")
	sources["clipmap_geometry_scale"] = 1.0
	_check(medium._raster_source_signature_valid(aligned_signature), "Updated signature retains valid resource contract")
	for profile in [Vector3(0, 0, 1), Vector3.ONE, Vector3(0.5, 0.3, 0.7)]:
		sources["visual_horizontal_displacement_scale"] = profile
		var expected_height := sin((2.0 - 2.0 * profile.x) * TAU / 8.0)
		for offset in [-0.1, 0.1]:
			var camera := Vector3(2.0, expected_height + float(offset), 0.0)
			var packet: PackedFloat32Array = effect._pack_camera_state_params(camera, 0.0, sources)
			_check(packet.to_byte_array().size() == EFFECT.CAMERA_STATE_PARAMS_BYTES, "Sensor CPU/GPU packet byte size")
			var raster_packet: PackedFloat32Array = effect._pack_raster_params(Projection(), Projection(), camera, 0.0, sources)
			_check(raster_packet.to_byte_array().size() == EFFECT.RASTER_PARAMS_BYTES, "Raster CPU/GPU packet byte size")
			_check(raster_packet.slice(-4) == packet.slice(-4), "Raster and sensor receive identical per-band shape controls")
			var params := rd.uniform_buffer_create(packet.to_byte_array().size(), packet.to_byte_array())
			var result := rd.storage_buffer_create(32)
			resources.append_array([params, result])
			var uniforms: Array[RDUniform] = [
				_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [params]),
				_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 4, [result])]
			for binding in [0, 1, 2, 5, 6, 7, 8, 9, 10, 11, 12]:
				uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, binding, [sampler, wave if binding == 0 else neutral]))
			var set := rd.uniform_set_create(uniforms, shader, 0)
			resources.append(set)
			var list := rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(list, set, 0)
			rd.compute_list_dispatch(list, 1, 1, 1)
			rd.compute_list_end()
			rd.submit()
			rd.sync()
			var values := rd.buffer_get_data(result).to_float32_array()
			_check(values.size() == 8 and values[2] > 0.5, "GPU sensor sample valid")
			_check(absf(values[1] - expected_height) < 0.005, "GPU surface height matches visible profile within 5 mm")
			_check(signf(values[0]) == signf(float(offset)), "Camera is classified correctly 10 cm above/below visible waterline")
	medium.free()
	for index in range(resources.size() - 1, -1, -1):
		if resources[index].is_valid():
			rd.free_rid(resources[index])
	rd.free()
	print("OCEAN_UNDERWATER_VISUAL_PROFILE: ", "PASS" if failures.is_empty() else "FAIL", " ", failures)
	quit(0 if failures.is_empty() else 1)
