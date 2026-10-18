extends SceneTree
## GPU check: speed follows its own foam through transport, fade and recentering.
const History:=preload("res://addons/ocean/surface/foam2d/projected_wake_history.gd")
var finished:=false
var result: Dictionary={}

func _initialize() -> void:
	RenderingServer.call_on_render_thread(exercise)
	wait_for_result.call_deferred()

func wait_for_result() -> void:
	while not finished: await process_frame
	print("FOAM_SPEED_HISTORY_", "PASS " if result.passed else "FAIL ", JSON.stringify(result))
	quit(0 if result.passed else 1)

func snapshot(history: RefCounted) -> Dictionary:
	var rd:=RenderingServer.get_rendering_device()
	var source:=RDShaderSource.new()
	source.source_compute="""#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(rgba16f,set=0,binding=0) readonly uniform image2D fields;
layout(rg16f,set=0,binding=1) readonly uniform image2D speeds;
layout(std430,set=0,binding=2) writeonly buffer Out { vec4 values[]; } output_data;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);output_data.values[p.y*512+p.x]=vec4(imageLoad(fields,p).r,imageLoad(speeds,p).rg,0);}
"""
	var shader:=rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
	var pipeline:=rd.compute_pipeline_create(shader)
	var buffer:=rd.storage_buffer_create(512*512*16)
	var uniforms: Array[RDUniform]=[]
	for i in 3:
		var u:=RDUniform.new()
		u.binding=i
		u.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE if i<2 else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.add_id([history.texture_rid,history.speed_texture_rid,buffer][i])
		uniforms.append(u)
	var bindings:=rd.uniform_set_create(uniforms,shader,0)
	var list:=rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,bindings,0)
	rd.compute_list_dispatch(list,64,64,1)
	rd.compute_list_end()
	var values:=rd.buffer_get_data(buffer).to_float32_array()
	var coverage:=[0.0,0.0]
	var mass:=[0.0,0.0]
	var fresh:=[0.0,0.0]
	var stern_fresh:=0.0
	var bow_fresh:=0.0
	var max_error:=0.0
	for y in 512:
		for x in 512:
			var at: int=(y*512+x)*4
			var c: float=values[at]
			var world_x: float=history.region_origin.x+(x+0.5)*0.25
			var side: int=0 if world_x<0.0 else 1
			coverage[side]+=c
			mass[side]+=values[at+1]
			fresh[side]+=values[at+2]
			var world_y: float=history.region_origin.y+(y+0.5)*0.25
			if world_y>0.35: stern_fresh+=values[at+2]
			if world_y< -0.35: bow_fresh+=values[at+2]
			if c>0.003: max_error=maxf(max_error,absf(values[at+1]/c-(0.0 if side==0 else 10.0)))
	for rid in [bindings,buffer,pipeline,shader]: rd.free_rid(rid)
	return {"coverage":coverage,"mean_mps":[mass[0]/maxf(coverage[0],0.00001),mass[1]/maxf(coverage[1],0.00001)],"mean_fresh":[fresh[0]/maxf(coverage[0],0.00001),fresh[1]/maxf(coverage[1],0.00001)],"stern_fresh":stern_fresh,"bow_fresh":bow_fresh,"max_error_mps":max_error}

func exercise() -> void:
	var history:=History.new()
	history.initialize()
	if not history.ready:
		result={"passed":false,"error":history.last_error}
		finished=true
		return
	history.set_view_center(Vector2.ZERO)
	history.set_motion(Vector3.ZERO)
	for i in 15:
		for side in 2:
			var p:=Vector2(-8 if side==0 else 8,0)
			history.submit_hull(p,p,Vector2(0,-1),0.0 if side==0 else 10.0,Vector4.ONE,Vector4.ONE,0.075)
		history.advance(0.075)
	var birth:=snapshot(history)
	# Only a stopped hull continues depositing; the old fast wake keeps its speed.
	history.set_view_center(Vector2(3,2))
	for i in 20:
		history.submit_hull(Vector2(-8,0),Vector2(-8,0),Vector2(0,-1),0.0,Vector4.ONE,Vector4.ONE,0.075)
		history.advance(0.075)
	var aged:=snapshot(history)
	var passed: bool=birth.coverage.min()>0.1 and aged.coverage.min()>0.1 and birth.max_error_mps<0.12 and aged.max_error_mps<0.2
	# Dense pigment now reaches both ends of the wet hull, with a soft bow edge.
	passed=passed and birth.stern_fresh>0.01 and birth.bow_fresh>0.01
	passed=passed and aged.mean_fresh[1]<birth.mean_fresh[1]*0.4
	result={"passed":passed,"birth":birth,"after_transport_fade_recenter":aged,"history_bytes":history.diagnostic_state().history_bytes}
	history.shutdown()
	passed=passed and not history.speed_texture_rid.is_valid()
	result.passed=passed
	finished=true
