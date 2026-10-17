extends SceneTree
## Isolated GPU timestamp A/B of the actual 512² interaction shaders.
## Excludes raster, compilation, upload and readback from the timestamp interval.
var result := []
func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		push_error("F1F2 compute requires Vulkan")
		quit(1)
		return
	for count in [1, 24]:
		for variant in ["baseline", "prototype"]:
			var path := "res://addons/ocean/shaders/interaction_foam_update.glsl"
			if variant == "baseline": path = "res://addons/ocean/surface/foam2d/references/original/interaction_foam_update.glsl"
			var source := RDShaderSource.new()
			source.source_compute = FileAccess.get_file_as_string(path).replace("#[compute]", "")
			var spirv := rd.shader_compile_spirv_from_source(source)
			if not spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE).is_empty():
				push_error(spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE))
				quit(1)
				return
			var shader := rd.shader_create_from_spirv(spirv)
			var pipeline := rd.compute_pipeline_create(shader)
			var format := RDTextureFormat.new()
			format.width = 512
			format.height = 512
			format.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
			format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
			var zero := PackedFloat32Array()
			zero.resize(512 * 512 * 2)
			var textures := [rd.texture_create(format, RDTextureView.new(), [zero.to_byte_array()]),
				rd.texture_create(format, RDTextureView.new(), [zero.to_byte_array()])]
			var params := PackedFloat32Array([-64, -64, -64, -64, 0.05, 2.4, count, 0.25, 0.9, 1.2, 128, 1, 1.8, 0.65, 0.08, 0.34])
			var buffer := rd.uniform_buffer_create(64, params.to_byte_array())
			var data := PackedFloat32Array()
			data.resize(24 * 12)
			for i in count:
				data[i * 12] = (i % 4) * 3.0
				data[i * 12 + 1] = (i / 4) * 3.0
				data[i * 12 + 2] = 1.0
				data[i * 12 + 5] = -1.0
			var stamps := rd.storage_buffer_create(data.size() * 4, data.to_byte_array())
			var sets := []
			for i in 2:
				var uniforms: Array[RDUniform] = []
				for binding in 4:
					var u := RDUniform.new()
					u.binding = binding
					u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE if binding < 2 else (RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER if binding == 2 else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)
					u.add_id(textures[i] if binding == 0 else (textures[1-i] if binding == 1 else (buffer if binding == 2 else stamps)))
					uniforms.append(u)
				sets.append(rd.uniform_set_create(uniforms, shader, 0))
			var times := []
			var wall_times := []
			for update in 160:
				var start := Time.get_ticks_usec()
				rd.capture_timestamp("wake_begin")
				var list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(list, pipeline)
				rd.compute_list_bind_uniform_set(list, sets[update % 2], 0)
				rd.compute_list_dispatch(list, 64, 64, 1)
				rd.compute_list_end()
				rd.capture_timestamp("wake_end")
				rd.submit()
				rd.sync()
				if update >= 40:
					wall_times.append(float(Time.get_ticks_usec() - start) / 1000.0)
					var begin := -1
					for i in rd.get_captured_timestamps_count():
						if rd.get_captured_timestamp_name(i) == "wake_begin": begin = rd.get_captured_timestamp_gpu_time(i)
						if rd.get_captured_timestamp_name(i) == "wake_end" and begin >= 0:
							# 4.7 Vulkan backend returns nanoseconds (verified in engine source).
							times.append(float(rd.get_captured_timestamp_gpu_time(i) - begin) / 1000000.0)
			var raw := rd.texture_get_data(textures[0], 0).to_float32_array()
			var max_green := 0.0
			for i in range(1, raw.size(), 2): max_green = maxf(max_green, raw[i])
			result.append({"variant": variant, "stamps": count, "gpu_ms": times, "submit_sync_wall_ms": wall_times, "max_green": max_green})
			for rid in sets + textures + [stamps, buffer, pipeline, shader]: rd.free_rid(rid)
	rd.free()
	FileAccess.open("res://temp/f1_f2/compute_report.json", FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	print("F1F2_COMPUTE_COMPLETE")
	quit()
