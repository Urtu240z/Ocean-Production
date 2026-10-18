extends SceneTree
## Frozen production-view ABBA draw-cost comparison. This isolates material
## cost; it is not a driving/physics benchmark or multi-vehicle release gate.
var boats:=1
var output: String

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--boats="): boats=int(arg.get_slice("=",1))
	output="res://temp/foam_relief/scene_"+str(boats)
	run.call_deferred()

func stats(values: Array) -> Dictionary:
	values.sort()
	var sum:=0.0
	for v in values: sum+=float(v)
	return {"mean":sum/maxi(values.size(),1),"median":values[values.size()/2],"p95":values[mini(values.size()-1,int(values.size()*0.95))]}

func run() -> void:
	seed(24017)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=120
	DirAccess.make_dir_recursive_absolute(output)
	var world: Node3D=load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	world.development_window_size=Vector2i(1280,720)
	world.validation_sea_state=0
	var ocean: Ocean=world.get_node("Production/Ocean")
	var original: Resource=ocean.get_hull_foam_settings()
	ocean.hull_foam_settings=original.duplicate(true)
	var style: Resource=ocean.hull_foam_settings
	ocean.wind_speed_mps=18.0
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
	var water: Node=world.water
	var recorder: Node=water.get("_perf1_capture")
	if is_instance_valid(recorder): recorder.queue_free()
	water.perf2_stage_measurements_enabled=false
	Input.action_press("throttle",0.8)
	var warm_end:=Time.get_ticks_msec()+6500
	while Time.get_ticks_msec()<warm_end: await process_frame
	Input.action_release("throttle")
	for body: RigidBody3D in world.find_children("*","RigidBody3D",true,false):
		body.freeze=true
		body.linear_velocity=Vector3.ZERO
		body.angular_velocity=Vector3.ZERO
		body.reset_physics_interpolation()
	for frame in 4: await physics_frame
	for node: Node in world.find_children("*","Node",true,false): node.process_mode=Node.PROCESS_MODE_DISABLED
	world.process_mode=Node.PROCESS_MODE_DISABLED
	var director: Node=ocean.get_hull_foam_runtime()
	assert(director!=null and director.history.ready)
	assert(director._presentation_enabled,"Performance test did not enable hull foam")
	for material: ShaderMaterial in director.surface.get("_variant_materials").values():
		assert(material.get_shader_parameter("foam2d_relief_enabled")==style.relief_enabled)
		assert(is_equal_approx(material.get_shader_parameter("foam2d_relief_height_m"),style.relief_height_m))
	Engine.max_fps=0
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	var runs: Array[Dictionary]=[]
	for enabled in [false,true,true,false]:
		style.relief_enabled=enabled
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
		runs.append({"enabled":enabled,"gpu_ms":stats(gpu),"render_cpu_ms":stats(cpu),"frame_ms":stats(wall)})
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output+("/on.png" if enabled else "/off.png"))
	var report: Dictionary={"boats":boats,"order":"off,on,on,off","frozen_view":true,"runs":runs,"shader_variants":director.surface.get("_variant_materials").size()}
	FileAccess.open(output+"/report.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("FOAM_RELIEF_SCENE_PASS ",JSON.stringify(report))
	world.queue_free()
	for frame in 8: await process_frame
	quit()
