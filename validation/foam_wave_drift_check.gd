extends SceneTree
## Real GPU transport with analytically known wave motion; no gameplay changes.
const History=preload("res://addons/ocean/surface/foam2d/projected_wake_history.gd")
var finished:=false
var result: Dictionary={}

func _initialize() -> void:
	RenderingServer.call_on_render_thread(exercise)
	wait_result.call_deferred()

func wait_result() -> void:
	while not finished: await process_frame
	print("FOAM_WAVE_DRIFT_", "PASS " if result.passed else "FAIL ",JSON.stringify(result))
	quit(0 if result.passed else 1)

func wave_data(x: float,z: float,crest:=0.0) -> PackedByteArray:
	var data:=PackedFloat32Array()
	for i in 16: data.append_array(PackedFloat32Array([x,crest,z,1]))
	return data.to_byte_array()

func snapshot(h: RefCounted) -> Dictionary:
	var rd:=RenderingServer.get_rendering_device()
	var source:=RDShaderSource.new()
	source.source_compute="""#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(rgba16f,set=0,binding=0) readonly uniform image2D field;
layout(rgba16f,set=0,binding=1) readonly uniform image2D flow;
layout(rg16f,set=0,binding=2) readonly uniform image2D speed;
layout(std430,set=0,binding=3) writeonly buffer Out { vec4 data[]; } out_data;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);int at=(p.y*512+p.x)*2;
vec4 f=imageLoad(field,p);out_data.data[at]=vec4(f.r,imageLoad(flow,p).ba,f.a);
out_data.data[at+1]=vec4(imageLoad(speed,p).rg,0,0);}
"""
	var shader:=rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
	var pipeline:=rd.compute_pipeline_create(shader)
	var buffer:=rd.storage_buffer_create(512*512*32)
	var uniforms: Array[RDUniform]=[]
	for i in 4:
		var u:=RDUniform.new()
		u.binding=i
		u.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE if i<3 else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.add_id([h.texture_rid,h.transport_texture_rid,h.speed_texture_rid,buffer][i])
		uniforms.append(u)
	var bindings:=rd.uniform_set_create(uniforms,shader,0)
	var list:=rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,bindings,0)
	rd.compute_list_dispatch(list,64,64,1)
	rd.compute_list_end()
	var data:=rd.buffer_get_data(buffer).to_float32_array()
	var mass:=0.0
	var position:=Vector2.ZERO
	var offset:=Vector2.ZERO
	var agitation:=0.0
	var speed:=0.0
	var fresh:=0.0
	var finite:=true
	for i in 512*512:
		var at:=i*8
		for j in 6: finite=finite and is_finite(data[at+j])
		var c:=data[at]
		mass+=c
		position+=(h.region_origin+(Vector2(i%512,i/512)+Vector2.ONE*0.5)*0.25)*c
		offset+=Vector2(data[at+1],data[at+2])
		agitation+=data[at+3]
		speed+=data[at+4]
		fresh+=data[at+5]
	for rid in [bindings,buffer,pipeline,shader]: rd.free_rid(rid)
	return {"centroid":position/maxf(mass,0.00001),"offset":offset/maxf(mass,0.00001),
		"mass":mass,"speed":speed/maxf(mass,0.00001),"fresh":fresh/maxf(mass,0.00001),"agitation":agitation/maxf(mass,0.00001),"finite":finite}

func exercise() -> void:
	var rd:=RenderingServer.get_rendering_device()
	if rd==null:
		result={"passed":false,"error":"RenderingDevice unavailable"}
		finished=true
		return
	var format:=RDTextureFormat.new()
	format.width=4
	format.height=4
	format.format=RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits=RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT|RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var wave:=rd.texture_create(format,RDTextureView.new(),[wave_data(0,0)])
	var neutral:=rd.texture_create(format,RDTextureView.new(),[wave_data(0,0)])
	var crest:=rd.texture_create(format,RDTextureView.new(),[wave_data(0,0,0.8)])
	var wrappers: Array[Texture2DRD]=[]
	for rid in [wave,neutral,neutral,crest]:
		var texture:=Texture2DRD.new()
		texture.texture_rd_rid=rid
		wrappers.append(texture)
	var histories: Array[RefCounted]=[]
	for enabled in [false,true]:
		var h:=History.new()
		h.initialize()
		if not h.ready:
			result={"passed":false,"error":h.last_error}
			finished=true
			return
		h.set_wave_sources(wrappers,Vector3.ONE*64.0,1.0,1)
		h.set_motion(Vector3.ZERO)
		h.set_outward(Vector2.ZERO)
		# Deposit identical trails before enabling their analytically known flow.
		for i in 60:
			h.submit_hull(Vector2.ZERO,Vector2.ZERO,Vector2(0,-1),10.0,Vector4.ONE,Vector4.ZERO,1.0/30.0)
			h.advance(1.0/30.0)
		h.set_wave_drift(Vector3(1.0 if enabled else 0.0,2.0,1.0 if enabled else 0.0))
		h.advance(1.0/30.0)
		histories.append(h)
	var birth:=snapshot(histories[1])
	for i in 60:
		rd.texture_update(wave,0,wave_data((i+1)*0.5/30.0,(i+1)*0.2/30.0))
		for h in histories: h.advance(1.0/30.0)
	var off:=snapshot(histories[0])
	var on:=snapshot(histories[1])
	var delta: Vector2=on.centroid-off.centroid
	var passed: bool=delta.distance_to(Vector2(1.0,0.4))<0.16 and on.offset.distance_to(Vector2(1.0,0.4))<0.12
	passed=passed and on.finite and off.finite and absf(on.speed-10.0)<0.15 and absf(off.speed-10.0)<0.15
	passed=passed and absf(on.fresh-off.fresh)<0.025 and on.fresh<birth.fresh*0.16
	passed=passed and on.agitation>off.agitation+0.1
	# A new wind generation changes the map discontinuously: retain the old
	# pigment coordinates, but seed the new wave sample without a false impulse.
	histories[1].set_view_center(Vector2(3,2))
	rd.texture_update(wave,0,wave_data(30,0))
	histories[1].set_wave_sources(wrappers,Vector3.ONE*64.0,1.0,2)
	histories[1].advance(1.0/30.0)
	var rebound:=snapshot(histories[1])
	passed=passed and rebound.centroid.distance_to(on.centroid)<0.07 and rebound.offset.distance_to(on.offset)<0.04
	# Borrowed FFT resources may disappear before the main thread rebinds them.
	rd.free_rid(wave)
	histories[1].advance(1.0/30.0)
	var retired:=snapshot(histories[1])
	passed=passed and retired.finite and retired.centroid.distance_to(rebound.centroid)<0.07
	passed=passed and retired.offset.distance_to(rebound.offset)<0.04
	result={"passed":passed,"expected_translation":"(1.0,0.4)","translation":str(delta),"off":off,"on":on,
		"after_generation_change":rebound,"after_retired_source":retired,"history_bytes":histories[1].diagnostic_state().history_bytes}
	for h in histories:
		var rid: RID=h.transport_texture_rid
		h.shutdown()
		passed=passed and not h.transport_texture_rid.is_valid() and not rd.texture_is_valid(rid)
	for texture in wrappers: texture.texture_rd_rid=RID()
	for rid in [neutral,crest]: rd.free_rid(rid)
	result.passed=passed
	finished=true
