extends SceneTree
## Phase A: actual global-device depth raster -> compute -> async buffer read.
var report: Dictionary = {"phase":"PHYS-GPU-ENVELOPE-1/A", "errors":[], "api":{}, "results":[]}
var rd: RenderingDevice
var owned: Array[RID] = []
var done := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	report.environment = {"engine":Engine.get_version_info(), "gpu":RenderingServer.get_video_adapter_name(), "cpu":OS.get_processor_name(), "driver":RenderingServer.get_current_rendering_driver_name(), "renderer":RenderingServer.get_current_rendering_method()}
	var required := ["render_pipeline_create","framebuffer_create","draw_list_begin","draw_list_draw","texture_is_format_supported_for_usage","compute_list_bind_uniform_set","buffer_get_data_async"]
	for method in ClassDB.class_get_method_list("RenderingDevice"):
		if method.name in required: report.api[method.name] = method
	RenderingServer.call_on_render_thread(_proof)
	for frame in 300:
		await process_frame
		if done: break
	if not done: report.errors.append("async result timeout")
	RenderingServer.call_on_render_thread(_release)
	for frame in 8: await process_frame
	FileAccess.open("res://.godot/phys_gpu_envelope_feasibility.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("ENVELOPE_A="+JSON.stringify(report))
	quit(0 if report.errors.is_empty() else 1)

func _own(rid: RID) -> RID:
	if rid.is_valid(): owned.append(rid)
	else: report.errors.append("invalid RID")
	return rid

func _compile(stages: Dictionary) -> RID:
	var source := RDShaderSource.new()
	for stage in stages: source.set_stage_source(stage,stages[stage])
	var spirv := rd.shader_compile_spirv_from_source(source)
	for stage in stages:
		var error := spirv.get_stage_compile_error(stage)
		if not error.is_empty(): report.errors.append(error); return RID()
	return _own(rd.shader_create_from_spirv(spirv))

func _proof() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null: report.errors.append("no global RD"); done=true; return
	report.global_device = true
	var color_usage := RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var depth_usage := RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT
	report.rgba32f = rd.texture_is_format_supported_for_usage(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,color_usage)
	report.d32 = rd.texture_is_format_supported_for_usage(RenderingDevice.DATA_FORMAT_D32_SFLOAT,depth_usage)
	if not report.rgba32f or not report.d32: report.errors.append("unsupported formats"); done=true; return
	var color := _target(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,color_usage)
	var depth := _target(RenderingDevice.DATA_FORMAT_D32_SFLOAT,depth_usage)
	var framebuffer := _own(rd.framebuffer_create([color,depth]))
	var raster := _compile({RenderingDevice.SHADER_STAGE_VERTEX:"""#version 450
layout(location=0) flat out vec4 winner;
void main() {
    vec2 p[3]=vec2[3](vec2(-1,-1),vec2(3,-1),vec2(-1,3));
    float h=gl_InstanceIndex==0?0.8:0.2;
    gl_Position=vec4(p[gl_VertexIndex],h,1);
    winner=vec4(float(gl_InstanceIndex),h,37,1);
}""",RenderingDevice.SHADER_STAGE_FRAGMENT:"""#version 450
layout(location=0) flat in vec4 winner;
layout(location=0) out vec4 output_value;
void main() { output_value=winner; }
"""})
	var depth_state := RDPipelineDepthStencilState.new()
	depth_state.enable_depth_test=true; depth_state.enable_depth_write=true
	depth_state.depth_compare_operator=RenderingDevice.COMPARE_OP_GREATER_OR_EQUAL
	var blend := RDPipelineColorBlendState.new(); blend.attachments=[RDPipelineColorBlendStateAttachment.new()]
	var pipeline := _own(rd.render_pipeline_create(raster,rd.framebuffer_get_format(framebuffer),-1,RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,RDPipelineRasterizationState.new(),RDPipelineMultisampleState.new(),depth_state,blend))
	var compute := _compile({RenderingDevice.SHADER_STAGE_COMPUTE:"""#version 450
layout(local_size_x=1) in;
layout(set=0,binding=0) uniform sampler2D atlas;
layout(std430,set=0,binding=1) buffer Result { vec4 value; };
void main() { value=texelFetch(atlas,ivec2(4,4),0); }
"""})
	var compute_pipeline := _own(rd.compute_pipeline_create(compute))
	var sampler := _own(rd.sampler_create(RDSamplerState.new()))
	var result := _own(rd.storage_buffer_create(16))
	var u := RDUniform.new(); u.uniform_type=RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u.binding=0; u.add_id(sampler); u.add_id(color)
	var b := RDUniform.new(); b.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; b.binding=1; b.add_id(result)
	var uniforms := _own(rd.uniform_set_create([u,b],compute,0))
	if not report.errors.is_empty(): done=true; return
	var draw := rd.draw_list_begin(framebuffer,RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH,PackedColorArray([Color(0,0,0,0)]),0.0)
	rd.draw_list_bind_render_pipeline(draw,pipeline)
	rd.draw_list_draw(draw,false,2,3)
	rd.draw_list_end()
	# Separate lists on global RD: tracked attachment -> sampled texture ordering.
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,compute_pipeline); rd.compute_list_bind_uniform_set(list,uniforms,0)
	rd.compute_list_dispatch(list,1,1,1); rd.compute_list_end()
	var error := rd.buffer_get_data_async(result,_received,0,16)
	if error!=OK: report.errors.append("async error "+str(error)); done=true

func _target(format: int, usage: int) -> RID:
	var f := RDTextureFormat.new(); f.width=8; f.height=8; f.format=format; f.usage_bits=usage
	return _own(rd.texture_create(f,RDTextureView.new()))

func _received(bytes: PackedByteArray) -> void:
	if bytes.size()!=16: report.errors.append("wrong bytes")
	else:
		var values: Array=[]
		for i in 4: values.append(bytes.decode_float(i*4))
		report.results.append(values)
		if absf(values[0])>0.001 or absf(values[1]-0.8)>0.00001 or values[2]!=37 or values[3]!=1: report.errors.append("depth/order mismatch")
	done=true

func _release() -> void:
	if rd==null: return
	for i in range(owned.size()-1,-1,-1): rd.free_rid(owned[i])
	owned.clear(); report.resources_after_shutdown=owned.size()
