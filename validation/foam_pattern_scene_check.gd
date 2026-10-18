extends SceneTree
## Frozen real Ocean comparison, keeping the user's preset untouched.
var boats:=1
var output: String
var fresh_mode:=false
var field_snapshot: Dictionary={}

func inspect_history(history: RefCounted) -> void:
	var rd:=RenderingServer.get_rendering_device()
	var src:=RDShaderSource.new()
	src.source_compute="""#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(rgba16f,set=0,binding=0) readonly uniform image2D fields;
layout(rg16f,set=0,binding=1) readonly uniform image2D metadata;
layout(std430,set=0,binding=2) writeonly buffer Out { vec4 values[]; } output_data;
void main(){ivec2 p=ivec2(gl_GlobalInvocationID.xy);output_data.values[p.y*512+p.x]=vec4(imageLoad(fields,p).r,imageLoad(metadata,p).rg,0);}
"""
	var shader:=rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(src))
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
	var max_speed:=0.0
	var max_fresh:=0.0
	var freshest_position:=Vector2.ZERO
	var fast_fresh_pixels:=0
	for i in 512*512:
		var c:=values[i*4]
		if c>0.02:
			var speed:=values[i*4+1]/c
			var fresh:=values[i*4+2]/c
			max_speed=maxf(max_speed,speed)
			if fresh>max_fresh:
				max_fresh=fresh
				freshest_position=history.region_origin+(Vector2(i%512,i/512)+Vector2.ONE*0.5)*0.25
			if speed>10.0 and fresh>0.6: fast_fresh_pixels+=1
	for rid in [bindings,buffer,pipeline,shader]: rd.free_rid(rid)
	field_snapshot={"max_speed_mps":max_speed,"max_freshness":max_fresh,"freshest_position":str(freshest_position),"fast_fresh_pixels":fast_fresh_pixels}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--boats="): boats=int(arg.get_slice("=",1))
		if arg=="--fresh-wake": fresh_mode=true
	output=("res://temp/fresh_wake/scene_" if fresh_mode else "res://temp/foam_pattern/scene_")+str(boats)
	run.call_deferred()

func mean(values: Array) -> float:
	var sum:=0.0
	for v in values: sum+=float(v)
	return sum/maxi(values.size(),1)

func run() -> void:
	seed(24017)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=120
	DirAccess.make_dir_recursive_absolute(output)
	var world: Node3D=load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	world.development_window_size=Vector2i(1280,720)
	world.validation_sea_state=0
	var ocean: Ocean=world.get_node("Production/Ocean")
	ocean.hull_foam_settings=ocean.get_hull_foam_settings().duplicate(true)
	var style: Resource=ocean.hull_foam_settings
	style.patch_size=0.85
	style.low_speed_white_strength=1.0
	style.high_speed_white_strength=1.0
	if fresh_mode:
		style.low_speed_white_strength=0.3
		style.high_speed_white_strength=0.57
		style.filament_deformation=0.0
		style.filament_speed=0.0
		if "--flat-sea" in OS.get_cmdline_user_args():
			ocean.wave_height_scale=0.0
			style.deformation_enabled=false
			output+="_flat"
			DirAccess.make_dir_recursive_absolute(output)
	ocean.wind_speed_mps=3.0
	ocean.set("foam_enabled",true)
	ocean.set("foam_mode","combined")
	root.add_child(world)
	for frame in 1800:
		await process_frame
		if world.ready_to_drive: break
	assert(world.ready_to_drive)
	for i in range(1,boats):
		var ski: JetSkiController=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
		ski.position=world.ski.global_position+Vector3((i%3)*5.0,0,(i/3)*5.0)
		ski.configure_ocean(ocean)
		world.add_child(ski)
		ski.get_node("CameraRig").process_mode=Node.PROCESS_MODE_DISABLED
	var recorder: Node=world.water.get("_perf1_capture")
	if is_instance_valid(recorder): recorder.queue_free()
	world.water.perf2_stage_measurements_enabled=false
	Input.action_press("throttle",0.8)
	var warm_end:=Time.get_ticks_msec()+6500
	while Time.get_ticks_msec()<warm_end:
		await process_frame
		if fresh_mode and Time.get_ticks_msec()>warm_end-4000 and Vector2(world.ski.linear_velocity.x,world.ski.linear_velocity.z).length()>8.0 and absf(world.ski.linear_velocity.y)<0.5: break
	Input.action_release("throttle")
	for body: RigidBody3D in world.find_children("*","RigidBody3D",true,false):
		body.freeze=true
		body.linear_velocity=Vector3.ZERO
		body.angular_velocity=Vector3.ZERO
		body.reset_physics_interpolation()
	for frame in 4: await physics_frame
	# Production explicitly uses PAUSABLE, overriding the disabled root. Freeze
	# every descendant so neither FFT nor pigment ages during the comparison.
	for node: Node in world.find_children("*","Node",true,false): node.process_mode=Node.PROCESS_MODE_DISABLED
	world.process_mode=Node.PROCESS_MODE_DISABLED
	for frame in 3: await process_frame
	var director: Node=ocean.get_hull_foam_runtime()
	assert(director!=null and director.history.ready)
	director._bind_projection_texture("interaction_foam_texture",director._history_sampling_texture(),true)
	director._bind_projection_texture("foam2d_speed_texture",director._speed_sampling_texture(),true)
	director.surface._set_surface_shader_parameter("interaction_foam_origin_xz",director.history.region_origin)
	var frozen_updates: int=director.history.completed_updates
	if fresh_mode:
		RenderingServer.call_on_render_thread(inspect_history.bind(director.history))
		while field_snapshot.is_empty(): await process_frame
		print("FRESH_WAKE_FIELD ",JSON.stringify(field_snapshot))
		assert(field_snapshot.fast_fresh_pixels>0,"Visual test did not contain fresh fast-moving stern pigment")
	var surface: Node=director.surface
	var current: ShaderMaterial=surface.get("_material")
	var rear_camera: Camera3D
	if fresh_mode:
		# The saved gameplay camera crops the stern from this fixture. Review the
		# actual fresh trail from farther behind without changing gameplay cameras.
		rear_camera=Camera3D.new()
		root.add_child(rear_camera)
		var forward: Vector3=-world.ski.global_basis.z
		forward.y=0.0
		forward=forward.normalized()
		rear_camera.fov=55.0
		rear_camera.position=world.ski.global_position-forward*9.0+Vector3.UP*4.5
		rear_camera.look_at(world.ski.global_position-forward*1.8)
		rear_camera.make_current()
		var state: Dictionary={"mode":director.mode,"enabled":director._presentation_enabled,"origin":str(director.history.region_origin),"boat":str(world.ski.global_position)}
		for key in ["foam2d_wake_enabled","foam2d_contact_enabled","foam2d_fresh_wake_enabled","foam2d_fresh_wake_strength","foam2d_white_speed_kmh","underwater_camera_signed_distance_m","interaction_foam_origin_xz"]: state[key]=str(current.get_shader_parameter(key))
		state["settling_s"]=str(current.get_shader_parameter("foam2d_fresh_wake_settling_s"))
		state["air_blend"]=str(current.get_shader_parameter("surface_air_blend"))
		state["opacity"]=str(current.get_shader_parameter("foam2d_opacity"))
		for key in ["interaction_foam_texture","foam2d_speed_texture"]:
			var texture: Texture2D=current.get_shader_parameter(key)
			state[key]=str(texture.get_size())+":"+str(texture.texture_rd_rid if texture is Texture2DRD else "neutral")
		print("FRESH_WAKE_MATERIAL ",JSON.stringify(state))
		if "--inspect-only" in OS.get_cmdline_user_args():
			for debug in [1,3]:
				current.set_shader_parameter("foam2d_debug",debug)
				for frame in 8: await process_frame
				await RenderingServer.frame_post_draw
				root.get_texture().get_image().save_png(output+"/inspect_"+str(debug)+".png")
			world.queue_free()
			for frame in 8: await process_frame
			quit()
			return
	if "--stern-vfx" in OS.get_cmdline_user_args():
		var back: Vector3=world.ski.global_basis.z
		back.y=0
		back=back.normalized()
		rear_camera.position=world.ski.global_position+back*5.0+Vector3.UP*2.0
		rear_camera.look_at(world.ski.global_position+back*0.8)
		await capture_stern_vfx(world, director, frozen_updates)
		return
	var old_source: String=current.shader.code
	for pair in [["contact_projection.gdshaderinc","contact_projection.gdshaderinc"],["projected_fragment.inc","projected_fragment.inc"]]:
		var fresh:=FileAccess.get_file_as_string("res://addons/ocean/surface/foam2d/"+pair[0])
		var previous:=FileAccess.get_file_as_string("res://validation/pattern_before/"+pair[1])
		assert(old_source.contains(fresh),"Comparison source replacement failed: "+pair[0])
		old_source=old_source.replace(fresh,previous)
	var before:=ShaderMaterial.new()
	before.shader=Shader.new()
	before.shader.code=old_source
	for uniform in current.shader.get_shader_uniform_list():
		var value=current.get_shader_parameter(uniform.name)
		if value!=null: before.set_shader_parameter(uniform.name,value)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	Engine.max_fps=0
	var runs: Array[Dictionary]=[]
	for revised in [false,true,true,false]:
		var material: ShaderMaterial=current if revised or fresh_mode else before
		if fresh_mode: ocean.set("foam_fresh_wake_enabled",revised)
		surface.set("_material",material)
		surface._assign_material_to_surface_geometry(material)
		for frame in 45: await process_frame
		var gpu: Array=[]
		var cpu: Array=[]
		var wall: Array=[]
		var end:=Time.get_ticks_msec()+1200
		var previous:=Time.get_ticks_usec()
		while Time.get_ticks_msec()<end:
			await process_frame
			var now:=Time.get_ticks_usec()
			wall.append((now-previous)/1000.0)
			previous=now
			gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
			cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()))
		runs.append({"revised":revised,"gpu_ms":mean(gpu),"render_cpu_ms":mean(cpu),"frame_ms":mean(wall)})
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+("/after.png" if revised else "/before.png"))
	surface.set("_material",current)
	surface._assign_material_to_surface_geometry(current)
	if fresh_mode:
		for enabled in [false,true]:
			ocean.set("foam_fresh_wake_enabled",enabled)
			current.set_shader_parameter("foam2d_debug",1)
			for frame in 8: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output+("/mask_on.png" if enabled else "/mask_off.png"))
		current.set_shader_parameter("foam2d_debug",0)
	# A/B the real production material, including white generated by tint.
	for enabled in [false,true]:
		ocean.set("foam_relief_enabled",enabled)
		assert(current.get_shader_parameter("foam2d_relief_enabled")==enabled,"Ocean export did not reach the rendered material")
		for frame in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+("/relief_on.png" if enabled else "/relief_off.png"))
	var close_camera:=Camera3D.new()
	root.add_child(close_camera)
	close_camera.fov=40.0
	close_camera.position=world.ski.global_position+Vector3(-2.0,4.0,1.0)
	close_camera.look_at(world.ski.global_position+Vector3(-2.0,0.0,-0.4))
	close_camera.make_current()
	# A finer puff scale makes centimetre-height shading easier to judge up close.
	style.relief_detail_size_m=0.18
	for enabled in [false,true]:
		ocean.set("foam_relief_enabled",enabled)
		for frame in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+("/close_on.png" if enabled else "/close_off.png"))
	var report: Dictionary={"boats":boats,"wind_mps":3.0,"patch_size":0.85,"frozen_view":true,"order":"before,after,after,before","runs":runs,"history_bytes":director.history.diagnostic_state().history_bytes}
	assert(director.history.completed_updates==frozen_updates,"Foam history advanced during the frozen comparison")
	FileAccess.open(output+"/report.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("FOAM_PATTERN_SCENE_PASS ",JSON.stringify(report))
	world.queue_free()
	close_camera.queue_free()
	if rear_camera!=null: rear_camera.queue_free()
	for frame in 8: await process_frame
	quit()

func capture_stern_vfx(world: Node3D, director: Node, frozen_updates: int) -> void:
	# Reuse the real FFT surface/history and frozen hull pose. Replay just the
	# visual inputs from its published V1 contacts, without advancing physics.
	var fixture=load("res://validation/hull_spray_nozzle_check.gd")
	var boat: Node3D=fixture.BoatFixture.new()
	root.add_child(boat)
	boat.global_transform=world.ski.global_transform
	boat.reset_physics_interpolation()
	var water: Node=world.ski.water_physics_system
	boat.water_physics_system.point_sample_valid=water.point_sample_valid.duplicate()
	boat.water_physics_system.point_depths=water.point_depths.duplicate()
	boat.water_physics_system.point_water_surface_positions=water.point_water_surface_positions.duplicate()
	var spray: Node=world.ski.get_node("BowSprayRoot/HullSprays")
	spray.configure_settings(spray.settings.duplicate(true))
	spray.settings.sides_enabled=false
	spray._vehicle=boat
	spray.settings.tail_appearance.anim_fps=0.0
	spray._tail_frame=8.5
	spray._mist.process_mode=Node.PROCESS_MODE_ALWAYS
	for slot in spray._slots: slot.sheet.hide(); slot.age=-1.0
	for i in 60: spray._process(1.0/60.0)
	var pose: Transform3D=spray._tail.global_transform
	var line: float=spray._tail_material.get_shader_parameter("sprite_waterline_y")
	var state:={"nozzle_y":pose.origin.y,"stern_waterline_y":line,"nozzle_back_y":pose.basis.z.y,"tail_visible":spray._tail.visible,"tail_intensity":spray._tail_intensity,"hull_foam_updates":frozen_updates}
	var folder:=output+"_stern"
	DirAccess.make_dir_recursive_absolute(folder)
	for stage in ["no_tail","tail_before","tail_after","tail_and_mist"]:
		spray._tail.visible=stage!="no_tail"
		spray._tail_material.set_shader_parameter("tail_surface_fade_depth",spray.settings.tail_surface_fade_depth_m if stage in ["tail_after","tail_and_mist"] else 0.0)
		spray._tail_material.set_shader_parameter("tail_water_core_strength",spray.settings.tail_water_core_strength if stage in ["tail_after","tail_and_mist"] else 0.0)
		spray._mist.visible=stage=="tail_and_mist"
		var end:=Time.get_ticks_msec()+700
		while Time.get_ticks_msec()<end:
			if stage=="tail_and_mist": spray._process(1.0/120.0)
			await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(folder+"/"+stage+".png")
	assert(director.history.completed_updates==frozen_updates)
	state.mist_visible=spray._mist.visible
	state.mist_weight=spray._mist._weight
	state.mist_center_y=spray._mist.global_position.y
	FileAccess.open(folder+"/report.json",FileAccess.WRITE).store_string(JSON.stringify(state,"\t"))
	print("STERN_OCEAN_PASS ",JSON.stringify(state))
	boat.queue_free()
	world.queue_free()
	for frame in 8: await process_frame
	quit()
