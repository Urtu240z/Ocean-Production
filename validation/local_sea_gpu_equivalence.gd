extends "res://validation/local_sea_gpu_audit.gd"
var failures: Array = []
func run() -> void:
	root.size = Vector2i(320,240)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var world := Node3D.new()
	root.add_child(world)
	var ocean: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	for property in ["coastal","reflections","enable_spindrift","underwater_medium","underwater_bubbles","underwater_sunrays"]: ocean.set(property,false)
	ocean.local_sea_state_1.wave_speed_multiplier = 0.0
	ocean.local_sea_state_2.wave_speed_multiplier = 0.0
	ocean.local_sea_state_1.choppiness_scale = 2.0
	ocean.local_sea_state_2.choppiness_scale = 2.0
	world.add_child(ocean)
	var areas: Array = []
	for i in 2:
		var area = load("res://addons/ocean/areas/ocean_wave_area_3d.tscn").instantiate()
		area.ocean = ocean
		area.sea_state = i
		area.name = "GPUArea%d"%i
		area.influence = 0.65+i*0.2
		area.blend_distance_m = 30.0
		world.add_child(area)
		areas.append(area)
	var runtime: RefCounted
	for i in 1800:
		await process_frame
		runtime = ocean.get_wave_area_runtime()
		if runtime.states[0]!=null and runtime.states[1]!=null and runtime.states[0].ready and runtime.states[1].ready: break
	var viewports: Array = []
	var materials: Array = []
	for original in [true,false]:
		var view := SubViewport.new()
		view.size = Vector2i(256,128)
		view.use_hdr_2d = true
		view.disable_3d = true
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		root.add_child(view)
		viewports.append(view)
		var rect := ColorRect.new()
		rect.size = Vector2(view.size)
		view.add_child(rect)
		var material := ShaderMaterial.new()
		material.shader = Shader.new()
		var path := "res://validation/fixtures/local_sea_base/wave_area_surface.gdshaderinc" if original else "res://addons/ocean/areas/wave_area_surface.gdshaderinc"
		material.shader.code = kernel_source().replace("res://addons/ocean/areas/wave_area_surface.gdshaderinc",path)
		rect.material = material
		materials.append(material)
	var results: Array = []
	for layout in ["same_overlap","separate_overlap","separate_edges","rotated","sphere","cylinder"]:
		for i in 2:
			areas[i].sea_state = 0 if layout=="same_overlap" else i
			areas[i].position = Vector3(i*20.0,0,0)
			areas[i].rotation.y = 0.6*i if layout=="rotated" else 0.0
			var shape: Shape3D
			if layout=="sphere":
				shape = SphereShape3D.new()
				shape.radius = 30.0
			elif layout=="cylinder":
				shape = CylinderShape3D.new()
				shape.radius = 35.0
			else:
				shape = BoxShape3D.new()
				shape.size = Vector3(80,60,50) if layout=="separate_edges" else Vector3(150,60,100)
			areas[i].get_node("CollisionShape3D").shape = shape
		for i in 60: await process_frame
		runtime = ocean.get_wave_area_runtime()
		for horizontal in [Vector3.ONE,Vector3(0,0,1)]:
			for material in materials:
				for key in runtime.shader_parameters(): material.set_shader_parameter(key,runtime.shader_parameters()[key])
				material.set_shader_parameter("visual_horizontal_displacement_scale",horizontal)
			for i in 8: await process_frame
			await RenderingServer.frame_post_draw
			var a: Image = viewports[0].get_texture().get_image()
			var b: Image = viewports[1].get_texture().get_image()
			var max_error := 0.0
			for y in a.get_height():
				for x in a.get_width():
					var ca := a.get_pixel(x,y)
					var cb := b.get_pixel(x,y)
					max_error = maxf(max_error,maxf(absf(ca.r-cb.r),maxf(absf(ca.g-cb.g),absf(ca.b-cb.b))))
			var exact := a.get_data() == b.get_data()
			if max_error>0.00001: failures.append(layout+str(horizontal))
			results.append({"layout":layout,"horizontal":str(horizontal),"pixels":a.get_width()*a.get_height(),"max_rgb_error":max_error,"byte_identical":exact})
	DirAccess.make_dir_recursive_absolute("res://temp/local_sea_audit")
	var file := FileAccess.open("res://temp/local_sea_audit/phase4_equivalence.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"cases":results,"failures":failures},"\t"))
	file.close()
	print("LOCAL_SEA_GPU_EQ ",JSON.stringify({"cases":results.size(),"failures":failures,"max_error":results.map(func(row): return row.max_rgb_error).max()}))
	world.queue_free()
	for view in viewports: view.queue_free()
	for i in 10: await process_frame
	quit(0 if failures.is_empty() else 1)
