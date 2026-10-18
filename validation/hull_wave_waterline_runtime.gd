extends SceneTree
## GPU regression: local crests/troughs must affect BOTH the camera medium and
## the rasterized surface exit. All GPU readback below is validation-only.
var ocean: Ocean
var director: Node
var effect: OceanUnderwaterMediumEffect
var camera: Camera3D
var _probe_ready:=false
var _probe_values:=PackedFloat32Array()
var _raster_inverse:=Projection()
var _above_face:=-1.0
var _probe_shader:=RID()
var _probe_pipeline:=RID()
var _probe_output:=RID()
var _probe_sampler:=RID()
var _field_ready:=false
var _packet_image: Image
var results: Array[Dictionary]=[]
const OUTPUT:="res://temp/hull_wave_waterline"

func _initialize() -> void:
	run.call_deferred()

func settle(frames:=30) -> void:
	for frame in frames: await process_frame

func expected_height(current: float, previous: float, blend: float, cap: float) -> float:
	# Independent scalar reference, including the soft safety cap.
	var h:=lerpf(previous,current,blend)
	var knee:=cap*0.75
	if absf(h)>knee: h=signf(h)*(knee+(cap-knee)*(1.0-exp(-(absf(h)-knee)/(cap-knee))))
	return h

func raster_probe() -> void:
	var rd: RenderingDevice=effect.get("_rd")
	if not _probe_shader.is_valid():
		var source:=RDShaderSource.new()
		source.source_compute="""#version 450
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
layout(set=0,binding=0) uniform sampler2D mask_field;
layout(set=0,binding=1) uniform sampler2D depth_field;
layout(set=0,binding=2,std430) buffer Probe { vec4 values[16]; } probe;
void main() {
  for(int y=0;y<4;y++) for(int x=0;x<4;x++) {
    vec2 uv=vec2(0.2+float(x)*0.2,0.2+float(y)*0.2);
    ivec2 size=textureSize(mask_field,0);
    uv=(vec2(ivec2(uv*vec2(size)))+vec2(0.5))/vec2(size);
    probe.values[y*4+x]=vec4(textureLod(mask_field,uv,0.0).rg,textureLod(depth_field,uv,0.0).r,uv.y);
  }
}"""
		var spirv:=rd.shader_compile_spirv_from_source(source)
		assert(spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE).is_empty())
		_probe_shader=rd.shader_create_from_spirv(spirv)
		_probe_pipeline=rd.compute_pipeline_create(_probe_shader)
		_probe_output=rd.storage_buffer_create(16*16)
		_probe_sampler=rd.sampler_create(RDSamplerState.new())
	var uniforms: Array[RDUniform]=[]
	for binding in 3:
		var uniform:=RDUniform.new()
		uniform.binding=binding
		uniform.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER if binding==2 else RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		if binding<2: uniform.add_id(_probe_sampler)
		uniform.add_id(_probe_output if binding==2 else effect.get("_mask_texture" if binding==0 else "_ocean_depth_texture"))
		uniforms.append(uniform)
	var set:=UniformSetCacheRD.get_cache(_probe_shader,0,uniforms)
	var list:=rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,_probe_pipeline)
	rd.compute_list_bind_uniform_set(list,set,0)
	rd.compute_list_dispatch(list,1,1,1)
	rd.compute_list_end()
	_probe_values=rd.buffer_get_data(_probe_output).to_float32_array()
	var params:=rd.buffer_get_data(effect.get("_raster_params")).to_float32_array()
	var columns: Array[Vector4]=[]
	for column in 4:
		var offset:=16+column*4
		columns.append(Vector4(params[offset],params[offset+1],params[offset+2],params[offset+3]))
	_raster_inverse=Projection(columns[0],columns[1],columns[2],columns[3])
	_probe_ready=true

func sample_case(test: Dictionary) -> void:
	var origin:=Vector2(-64,-64)
	camera.position=Vector3(test.get("x",0.0),test.get("camera_y",0.2),0)
	camera.reset_physics_interpolation()
	var field: RefCounted=director.wave_field
	_field_ready=false
	RenderingServer.call_on_render_thread(func():
		var rd: RenderingDevice=field.get("_rd")
		rd.texture_clear(field.texture_rid,Color(test.current,0,0,0),0,1,0,1)
		rd.texture_clear(field.previous_texture_rid,Color(test.previous,0,0,0),0,1,0,1)
		_field_ready=true)
	for frame in 300:
		await process_frame
		if _field_ready: break
	assert(_field_ready)
	var state: Dictionary={"hull_waves_enabled":test.get("enabled",true),
		"hull_waves_texture":field.texture_rid,"hull_waves_previous_texture":field.previous_texture_rid,
		"hull_waves_origin":origin,"hull_waves_previous_origin":origin+Vector2(0.25,-0.25),
		"hull_waves_blend":test.blend,"hull_waves_max_height":test.cap,
		"hull_waves_physical":test.get("physical",true)}
	if test.get("invalid",false): state["hull_waves_texture"]=RID()
	# Use the actual renderer's atlas and its normal Ocean publication route.
	for key in state:
		if key.ends_with("texture"): continue
		director.surface._set_surface_shader_parameter(key,state[key])
	ocean.publish_hull_wave_render_state(state)
	var expected:=expected_height(test.current,test.previous,test.blend,test.cap)
	var x: float=test.get("x",0.0)
	if absf(x)>64.0: expected=0.0
	elif test.get("physical",true): expected*=1.0-smoothstep(56.0,64.0,absf(x))
	if not test.get("enabled",true) or test.get("invalid",false): expected=0.0
	var sensor: Dictionary={}
	for frame in 600:
		await process_frame
		sensor=ocean.get_waterline_state()
		if frame>30 and sensor.get("valid",false) and absf(float(sensor.water_surface_y)-expected)<0.004: break
	assert(sensor.get("valid",false),"Missing GPU camera sensor")
	assert(absf(float(sensor.water_surface_y)-expected)<0.004,"Camera ignores hull wave: "+str(test.name)+" "+str(sensor))
	assert(absf(float(sensor.signed_distance_to_surface)-(camera.position.y-expected))<0.004)
	await settle()
	_probe_ready=false
	RenderingServer.call_on_render_thread(raster_probe)
	for frame in 300:
		await process_frame
		if _probe_ready: break
	assert(_probe_ready and _probe_values.size()==64)
	var covered:=0
	var wrong_faces:=0
	var depth_error:=0.0
	if not test.get("skip_faces",false):
		for i in 16:
			if _probe_values[i*4+1]<0.5: continue
			covered+=1
			var front: bool=camera.position.y>expected
			if test.name=="disabled": _above_face=_probe_values[i*4]
			# Calibrate the backend's native winding once. More importantly,
			# inverse-project the actual raster depth to check the water's height.
			var face:=_above_face if front else 1.0-_above_face
			if absf(_probe_values[i*4]-face)>0.1: wrong_faces+=1
			assert(_probe_values[i*4+2]>0.0,"Missing deformed water exit depth")
			var uv:=Vector2(0.2+(i%4)*0.2,_probe_values[i*4+3])
			var h:=_raster_inverse*Vector4(uv.x*2.0-1.0,uv.y*2.0-1.0,_probe_values[i*4+2],1.0)
			depth_error=maxf(depth_error,absf(h.y/h.w-expected))
		assert(covered>=4 and wrong_faces==0,"Raster ignores hull wave: "+str(test.name)+" covered="+str(covered)+" wrong="+str(wrong_faces))
		assert(depth_error<0.002,"Water exit depth mismatch: "+str(test.name)+" "+str(depth_error))
	results.append({"name":test.name,"expected_height":expected,"gpu_height":sensor.water_surface_y,"covered":covered,"wrong_faces":wrong_faces,"depth_error_m":depth_error})
	if test.name in ["crest","depression"]:
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OUTPUT+"/"+str(test.name)+".png")

func packet_height(xz: Vector2) -> float:
	var grid: Vector2=(xz+Vector2.ONE*64.0)*4.0-Vector2.ONE*0.5
	var cell:=Vector2i(grid.floor())
	var f:=grid-grid.floor()
	return lerpf(lerpf(_packet_image.get_pixel(cell.x,cell.y).r,_packet_image.get_pixel(cell.x+1,cell.y).r,f.x),
		lerpf(_packet_image.get_pixel(cell.x,cell.y+1).r,_packet_image.get_pixel(cell.x+1,cell.y+1).r,f.x),f.y)

func sample_packet() -> void:
	var packets: Array[Dictionary]=[{"owner":23,"position":Vector2.ZERO,"forward":Vector2(0,-1),
		"amplitude":0.8,"speed":0.7,"width":1.0,"wavelength":4.0,"life":8.0,"half_length":1.0,
		"impact":true,"born":0.0,"start_radius":0.3,"rise":0.1,"fade":2.0}]
	var field: RefCounted=director.wave_field
	_field_ready=false
	RenderingServer.call_on_render_thread(func():
		field.draw(packets,Vector2(-64,-64),2.0)
		field.draw(packets,Vector2(-64,-64),2.0)
		var rd: RenderingDevice=field.get("_rd")
		_packet_image=Image.create_from_data(512,512,false,Image.FORMAT_RGBAH,rd.texture_get_data(field.texture_rid,0))
		_field_ready=true)
	for frame in 300:
		await process_frame
		if _field_ready: break
	assert(_field_ready)
	var xz:=Vector2(1.125,0.125)
	var expected:=packet_height(xz)
	assert(absf(expected)>0.1,"Generated packet is not a meaningful camera test")
	var slope:=Vector2(packet_height(xz+Vector2(0.05,0))-packet_height(xz-Vector2(0.05,0)),
		packet_height(xz+Vector2(0,0.05))-packet_height(xz-Vector2(0,0.05)))/0.1
	var expected_normal:=Vector3(-slope.x,1.0,-slope.y).normalized()
	camera.position=Vector3(xz.x,expected-0.1,xz.y)
	camera.reset_physics_interpolation()
	var state: Dictionary={"hull_waves_enabled":true,"hull_waves_texture":field.texture_rid,
		"hull_waves_previous_texture":field.previous_texture_rid,"hull_waves_origin":Vector2(-64,-64),
		"hull_waves_previous_origin":Vector2(-64,-64),"hull_waves_blend":0.67,"hull_waves_max_height":2.0,"hull_waves_physical":true}
	for key in state:
		if not key.ends_with("texture"): director.surface._set_surface_shader_parameter(key,state[key])
	ocean.publish_hull_wave_render_state(state)
	await settle(60)
	var sensor:=ocean.get_waterline_state()
	assert(sensor.get("valid",false))
	assert(absf(sensor.water_surface_y-expected)<0.002,"Generated wave height differs from waterline")
	assert(sensor.normal.distance_to(expected_normal)<0.02,"Waterline tangent ignores the generated wave slope")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUTPUT+"/wave_packet.png")

func run() -> void:
	seed(24017)
	Engine.max_fps=120
	root.size=Vector2i(960,540)
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	var world: Node3D=load("res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn").instantiate()
	ocean=world.get_node("Ocean")
	ocean.hull_foam_settings=ocean.get_hull_foam_settings().duplicate(true)
	ocean.hull_foam_settings.wave_physics_enabled=false
	ocean.hull_foam_settings.deformation_enabled=true
	ocean.wave_height_scale=0.0
	ocean.wind_speed_mps=3.0
	ocean.underwater_bubbles=false
	ocean.underwater_sunrays=false
	root.add_child(world)
	for frame in 1800:
		await process_frame
		director=ocean.get_hull_foam_runtime()
		if world.ready_to_drive and director!=null and director.wave_field!=null and director.wave_field.ready and not director.get_wave_render_state().is_empty(): break
	assert(director!=null and director.wave_field!=null and director.wave_field.ready)
	world.get_node("JetSki/CameraRig").process_mode=Node.PROCESS_MODE_DISABLED
	world.get_node("JetSki").freeze=true
	camera=Camera3D.new()
	camera.near=0.05
	camera.far=50.0
	world.add_child(camera)
	camera.make_current()
	await settle(90)
	effect=ocean.get("_underwater_medium").get_effect_identity()
	assert(effect!=null)
	var live: Dictionary=director.get_wave_render_state()
	assert(live.hull_waves_texture==effect.get("_hull_wave_sources").get("hull_waves_texture"),"Atlas publication differs from display")
	director.set_process(false)
	for test in [
		{"name":"disabled","current":0.9,"previous":0.3,"blend":0.5,"cap":2.0,"enabled":false},
		{"name":"crest","current":0.9,"previous":0.3,"blend":0.5,"cap":2.0},
		{"name":"depression","current":-1.1,"previous":-0.7,"blend":0.25,"cap":2.0,"camera_y":-0.2},
		{"name":"soft_cap","current":3.0,"previous":2.0,"blend":0.7,"cap":1.0},
		{"name":"visual_only","current":1.0,"previous":0.2,"blend":0.25,"cap":2.0,"physical":false},
		{"name":"previous_frame","current":0.9,"previous":0.1,"blend":0.0,"cap":2.0},
		{"name":"border_fade","current":1.0,"previous":1.0,"blend":1.0,"cap":2.0,"x":60.0,"skip_faces":true},
		{"name":"outside_atlas","current":1.0,"previous":1.0,"blend":1.0,"cap":2.0,"x":80.0},
		{"name":"retired_atlas","current":1.0,"previous":1.0,"blend":1.0,"cap":2.0,"invalid":true}]:
		await sample_case(test)
	# Restore actual emission, then rebuild Ocean and disable deformation.
	assert(results.size()==9,"A waterline case failed")
	await sample_packet()
	director.set_process(true)
	ocean.wind_speed_mps=8.0
	for frame in 600:
		await process_frame
		if frame>180 and not director._surface_pending and director.wave_field.ready: break
	assert(not director._surface_pending and director.wave_field.ready)
	effect=ocean.get("_underwater_medium").get_effect_identity()
	await settle(30)
	assert(director.get_wave_render_state().hull_waves_texture==effect.get("_hull_wave_sources").get("hull_waves_texture"))
	ocean.hull_foam_settings.deformation_enabled=false
	await settle(30)
	assert(effect.get("_hull_wave_sources").is_empty(),"Retired wave atlas remains active underwater")
	var report: Dictionary={"passed":true,"cases":results,"packet_sensor_and_normal":true,"shared_atlas":true,"wind_rebuild":true,"disable_clears_binding":true,"extra_wave_fields":0}
	FileAccess.open(OUTPUT+"/report.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("HULL_WAVE_WATERLINE_PASS ",JSON.stringify(report))
	RenderingServer.call_on_render_thread(func():
		var rd: RenderingDevice=effect.get("_rd")
		for rid in [_probe_output,_probe_pipeline,_probe_shader,_probe_sampler]:
			if rid.is_valid(): rd.free_rid(rid))
	await settle(3)
	world.queue_free()
	await settle(5)
	quit()
