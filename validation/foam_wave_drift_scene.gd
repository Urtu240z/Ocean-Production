extends SceneTree
## Live ABBA cost, then a paired old-trail comparison sharing one real FFT.
const History=preload("res://addons/ocean/surface/foam2d/projected_wake_history.gd")
var boats:=1
var output: String
var world: Node3D
var ocean: Ocean
var director: Node
var baseline: RefCounted
var baseline_ready:=false
var baseline_textures: Array[Texture2DRD]=[]
var flow_snapshot: Dictionary={}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--boats="): boats=int(arg.get_slice("=",1))
	output="res://temp/wave_drift/boats_"+str(boats)
	run.call_deferred()

func stats(values: Array) -> Dictionary:
	if values.is_empty(): return {"mean":0.0,"p95":0.0,"samples":0}
	var sorted:=values.duplicate()
	sorted.sort()
	var total:=0.0
	for value in sorted: total+=float(value)
	return {"mean":total/sorted.size(),"p95":sorted[mini(int(sorted.size()*0.95),sorted.size()-1)],"samples":sorted.size()}

func run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=120
	DirAccess.make_dir_recursive_absolute(output)
	world=load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	world.development_window_size=Vector2i(1280,720)
	world.validation_sea_state=0
	ocean=world.get_node("Production/Ocean")
	ocean.hull_foam_settings=ocean.get_hull_foam_settings().duplicate(true)
	var style: Resource=ocean.hull_foam_settings
	style.filament_deformation=0.0
	style.filament_speed=0.0
	style.wave_drift_enabled=false
	ocean.wind_speed_mps=18.0
	ocean.set("foam_enabled",true)
	ocean.set("foam_mode","combined")
	root.add_child(world)
	for frame in 1800:
		await process_frame
		if world.ready_to_drive: break
	assert(world.ready_to_drive)
	# Keep every measured run offshore: the authored island lies on the default
	# straight driving route and can otherwise turn this into a land test.
	var offshore: Transform3D=world.ski.global_transform
	offshore.origin+=Vector3(4096,0,4096)
	world.ski.set_respawn_transform(offshore)
	world.ski.maximum_distance_from_spawn=10000.0
	world.ski.reset_vehicle(&"wave_drift_validation")
	var driving_camera: Camera3D=root.get_camera_3d()
	for index in range(1,boats):
		var ski: JetSkiController=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
		ski.position=world.ski.global_position+Vector3((index%3)*5.0,0,(index/3)*5.0)
		ski.configure_ocean(ocean)
		world.add_child(ski)
		ski.maximum_distance_from_spawn=10000.0
		ski.get_node("CameraRig").process_mode=Node.PROCESS_MODE_DISABLED
	# Clone cameras become current during _ready, before their rigs are disabled.
	# Restore the driver's camera so the camera-centred history follows the boats.
	driving_camera.make_current()
	var recorder: Node=world.water.get("_perf1_capture")
	if is_instance_valid(recorder): recorder.queue_free()
	world.water.perf2_stage_measurements_enabled=false
	world.water.native.call("perf1_set_enabled",false)
	director=ocean.get_hull_foam_runtime()
	assert(director!=null)
	Input.action_press("throttle",0.8)
	var end:=Time.get_ticks_msec()+5000
	while Time.get_ticks_msec()<end: await process_frame
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	Engine.max_fps=0
	var rows: Array=[]
	for enabled in ([] if "--visual-only" in OS.get_cmdline_user_args() else [false,true,true,false]):
		style.wave_drift_enabled=enabled
		director.metrics_active=false
		end=Time.get_ticks_msec()+1500
		while Time.get_ticks_msec()<end: await process_frame
		director.effect_gpu_ms.clear()
		director.metrics_active=true
		var ram_start:=OS.get_static_memory_usage()
		var frame_ms: Array=[]
		var gpu: Array=[]
		var cpu: Array=[]
		var physics: Array=[]
		var contact_cpu: Array=[]
		var previous:=Time.get_ticks_usec()
		end=Time.get_ticks_msec()+4000
		while Time.get_ticks_msec()<end:
			await process_frame
			var now:=Time.get_ticks_usec()
			frame_ms.append((now-previous)/1000.0)
			previous=now
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
			cpu.append(Performance.get_monitor(Performance.TIME_PROCESS)*1000.0)
			physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0)
			contact_cpu.append(director.contact_update_us/1000.0)
		director.metrics_active=false
		var row:={"enabled":enabled,"frame_ms":stats(frame_ms),"gpu_ms":stats(gpu),"cpu_ms":stats(cpu),"physics_cpu_ms":stats(physics),
			"contact_cpu_ms":stats(contact_cpu),"foam_gpu_ms":stats(director.effect_gpu_ms.duplicate()),"static_ram_growth_bytes":OS.get_static_memory_usage()-ram_start,
			"history":director.history.diagnostic_state()}
		rows.append(row)
		print("WAVE_DRIFT_RUN ",JSON.stringify(row))
	Input.action_release("throttle")
	# Stop emitters, but keep V1 ticking: CPU Lite publishes the authoritative
	# wave clock from gameplay contacts. Freezing all bodies also freezes FFT time.
	for body: RigidBody3D in world.find_children("*","RigidBody3D",true,false):
		body.get_node("CameraRig").process_mode=Node.PROCESS_MODE_DISABLED
		body.get_node("BowSprayRoot").visible=false
		body.get_node("BowSprayRoot").process_mode=Node.PROCESS_MODE_DISABLED
	director.set_process(false)
	for i in 5: await process_frame
	baseline=History.new()
	baseline.set_appearance(style.history_parameters())
	baseline.set_motion(style.motion_parameters())
	baseline.set_edges(style.edge_parameters())
	baseline.set_outward(style.outward_parameters())
	baseline.set_shape(style.shape_parameters())
	baseline.set_update_hz(style.wake_update_hz)
	RenderingServer.call_on_render_thread(clone_history)
	while not baseline_ready: await process_frame
	for i in 3: baseline_textures.append(Texture2DRD.new())
	style.wave_drift_enabled=true
	var camera:=Camera3D.new()
	root.add_child(camera)
	var back: Vector3=world.ski.global_basis.z
	back.y=0.0
	back=back.normalized()
	camera.position=world.ski.global_position+back*18.0+Vector3.UP*18.0
	camera.look_at(world.ski.global_position+back*8.0)
	camera.fov=60
	camera.make_current()
	Engine.max_fps=60
	var previous:=Time.get_ticks_usec()
	var start:=previous
	var next_capture:=0
	var stopped_emission: int=director.history.submitted_stamps
	var wave_time_before: float=director.fft.get("_visual_wave_time")
	while Time.get_ticks_usec()<start+3000000:
		await process_frame
		var now:=Time.get_ticks_usec()
		var delta: float=(now-previous)/1000000.0
		previous=now
		var center:=Vector2(camera.position.x,camera.position.z)
		director.history.set_view_center(center)
		baseline.set_view_center(center)
		RenderingServer.call_on_render_thread(baseline.advance.bind(delta))
		bind_history(false)
		if now-start>=next_capture*500000:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output+"/moving_%02d.png"%next_capture)
			next_capture+=1
	assert(director.history.submitted_stamps==stopped_emission,"Visual fixture continued emitting new foam")
	director.field_readback={}
	RenderingServer.call_on_render_thread(director.read_field)
	while director.field_readback.is_empty(): await process_frame
	RenderingServer.call_on_render_thread(inspect_flow)
	while flow_snapshot.is_empty(): await process_frame
	flow_snapshot.wave_time_before=wave_time_before
	flow_snapshot.wave_time_after=director.fft.get("_visual_wave_time")
	print("WAVE_DRIFT_FLOW ",JSON.stringify(flow_snapshot))
	if flow_snapshot.mean_offset_m<=0.005:
		print("FOAM_WAVE_DRIFT_SCENE_FAIL real wave transport absent")
		quit(1)
		return
	var material: ShaderMaterial=director.surface.get("_material")
	print("WAVE_DRIFT_VISUAL ",JSON.stringify({"field":director.field_readback,"camera":str(camera.position),"boat":str(world.ski.global_position),
		"air":material.get_shader_parameter("surface_air_blend"),"camera_distance":material.get_shader_parameter("underwater_camera_signed_distance_m"),
		"contact":material.get_shader_parameter("foam2d_contact_enabled"),"wake":material.get_shader_parameter("foam2d_wake_enabled"),
		"drift":material.get_shader_parameter("foam2d_wave_drift_enabled"),"drift_sources":director.history.diagnostic_state().wave_drift_sources}))
	# Identical ocean/lighting/boat pose and birth pigment; only drift differs.
	director.fft.set_process(false)
	for body: RigidBody3D in world.find_children("*","RigidBody3D",true,false):
		body.freeze=true
		body.linear_velocity=Vector3.ZERO
		body.angular_velocity=Vector3.ZERO
		body.reset_physics_interpolation()
	for i in 4: await process_frame
	var frozen_updates: int=director.history.completed_updates
	for enabled in [false,true]:
		style.wave_drift_enabled=enabled
		bind_history(not enabled)
		for i in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+("/after.png" if enabled else "/before.png"))
		material.set_shader_parameter("foam2d_debug",1)
		for i in 4: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+("/mask_after.png" if enabled else "/mask_before.png"))
		material.set_shader_parameter("foam2d_debug",0)
	assert(director.history.completed_updates==frozen_updates)
	camera.position=world.ski.global_position+back*12.0+Vector3.UP*28.0
	camera.look_at(world.ski.global_position+back*12.0,Vector3.FORWARD)
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output+"/top.png")
	# A fixed view isolates fragment cost from live driving and wave phase.
	# GPU transport cost is measured separately above by Foam2D timestamps.
	for node: Node in world.find_children("*","Node",true,false): node.process_mode=Node.PROCESS_MODE_DISABLED
	world.process_mode=Node.PROCESS_MODE_DISABLED
	Engine.max_fps=0
	var frozen_rows: Array=[]
	for enabled in [false,true,true,false]:
		style.wave_drift_enabled=enabled
		bind_history(false)
		for frame in 45: await process_frame
		var gpu: Array=[]
		var cpu: Array=[]
		var wall: Array=[]
		var before:=Time.get_ticks_usec()
		var until:=before+1200000
		while Time.get_ticks_usec()<until:
			await process_frame
			var now:=Time.get_ticks_usec()
			wall.append((now-before)/1000.0)
			before=now
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
			cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
		frozen_rows.append({"enabled":enabled,"gpu_ms":stats(gpu),"render_cpu_ms":stats(cpu),"frame_ms":stats(wall)})
	assert(director.history.completed_updates==frozen_updates)
	var report:={"boats":boats,"wind_mps":18.0,"order":"off,on,on,off","runs":rows,"shared_history_bytes":director.history.diagnostic_state().history_bytes,
		"paired_visual":"same initial pigment, one live FFT, 3 s drift; final FFT frozen for A/B","flow":flow_snapshot,"frozen_render_runs":frozen_rows,"extra_water_queries":0,"new_fft":0,"passed":true}
	FileAccess.open(output+"/report.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("FOAM_WAVE_DRIFT_SCENE_PASS ",JSON.stringify(report))
	for texture in baseline_textures: texture.texture_rd_rid=RID()
	RenderingServer.call_on_render_thread(baseline.shutdown)
	bind_history(false)
	world.queue_free()
	camera.queue_free()
	for i in 12: await process_frame
	quit()

func clone_history() -> void:
	baseline.initialize()
	assert(baseline.ready)
	baseline.region_origin=director.history.region_origin
	baseline._flow_time=director.history._flow_time
	baseline._elapsed=director.history._elapsed
	var rd:=RenderingServer.get_rendering_device()
	var source:=RDShaderSource.new()
	source.source_compute="""#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(rgba16f,set=0,binding=0) readonly uniform image2D old_field;
layout(rgba16f,set=0,binding=1) writeonly uniform image2D new_field;
layout(rg16f,set=0,binding=2) readonly uniform image2D old_speed;
layout(rg16f,set=0,binding=3) writeonly uniform image2D new_speed;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);imageStore(new_field,p,imageLoad(old_field,p));imageStore(new_speed,p,imageLoad(old_speed,p));}
"""
	var shader:=rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
	var pipeline:=rd.compute_pipeline_create(shader)
	var uniforms: Array[RDUniform]=[]
	for i in 4:
		var u:=RDUniform.new()
		u.binding=i
		u.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE
		u.add_id([director.history.texture_rid,baseline.texture_rid,director.history.speed_texture_rid,baseline.speed_texture_rid][i])
		uniforms.append(u)
	var bindings:=rd.uniform_set_create(uniforms,shader,0)
	var list:=rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,bindings,0)
	rd.compute_list_dispatch(list,64,64,1)
	rd.compute_list_end()
	for rid in [bindings,pipeline,shader]: rd.free_rid(rid)
	baseline_ready=true

func bind_history(use_baseline: bool) -> void:
	var h: RefCounted=baseline if use_baseline else director.history
	var textures: Array=[]
	if use_baseline:
		for i in 3: baseline_textures[i].texture_rd_rid=[h.texture_rid,h.speed_texture_rid,h.transport_texture_rid][i]
		textures=baseline_textures
	else:
		textures=[director._history_sampling_texture(),director._speed_sampling_texture(),director._transport_sampling_texture()]
	for i in 3: director._bind_projection_texture(["interaction_foam_texture","foam2d_speed_texture","foam2d_transport_texture"][i],textures[i],true)
	director.surface._set_surface_shader_parameter("interaction_foam_origin_xz",h.region_origin)

func inspect_flow() -> void:
	var rd:=RenderingServer.get_rendering_device()
	var source:=RDShaderSource.new()
	source.source_compute="""#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(rgba16f,set=0,binding=0) readonly uniform image2D field;
layout(rgba16f,set=0,binding=1) readonly uniform image2D flow;
layout(std430,set=0,binding=2) writeonly buffer Out { vec4 data[]; } out_data;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);vec4 f=imageLoad(flow,p);out_data.data[p.y*512+p.x]=vec4(imageLoad(field,p).r,length(f.rg),f.ba);}
"""
	var shader:=rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
	var pipeline:=rd.compute_pipeline_create(shader)
	var buffer:=rd.storage_buffer_create(512*512*16)
	var uniforms: Array[RDUniform]=[]
	for i in 3:
		var u:=RDUniform.new()
		u.binding=i
		u.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE if i<2 else RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		u.add_id([director.history.texture_rid,director.history.transport_texture_rid,buffer][i])
		uniforms.append(u)
	var bindings:=rd.uniform_set_create(uniforms,shader,0)
	var list:=rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list,pipeline)
	rd.compute_list_bind_uniform_set(list,bindings,0)
	rd.compute_list_dispatch(list,64,64,1)
	rd.compute_list_end()
	var data:=rd.buffer_get_data(buffer).to_float32_array()
	var mass:=0.0
	var offset_mass:=0.0
	var max_displacement:=0.0
	var max_gradient:=0.0
	for i in 512*512:
		mass+=data[i*4]
		offset_mass+=Vector2(data[i*4+2],data[i*4+3]).length()
		max_displacement=maxf(max_displacement,data[i*4+1])
		if i%512<511 and data[i*4]>0.02 and data[(i+1)*4]>0.02:
			var a:=Vector2(data[i*4+2],data[i*4+3])/data[i*4]
			var b:=Vector2(data[(i+1)*4+2],data[(i+1)*4+3])/data[(i+1)*4]
			max_gradient=maxf(max_gradient,a.distance_to(b))
	flow_snapshot={"mass":mass,"mean_offset_m":offset_mass/maxf(mass,0.00001),"maximum_wave_displacement_m":max_displacement,"maximum_adjacent_offset_change_m":max_gradient}
	for rid in [bindings,buffer,pipeline,shader]: rd.free_rid(rid)
