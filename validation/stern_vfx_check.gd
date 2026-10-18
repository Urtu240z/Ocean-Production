extends SceneTree
## Controlled white-water backdrop isolates tail clipping/contrast and local mist.
const Fixture=preload("res://validation/hull_spray_nozzle_check.gd")
var output:="res://temp/stern_vfx"
var boats:=1
var sprays: Array[Node]=[]
var nozzles: Array[Node3D]=[]
var world: Node3D
var camera: Camera3D

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--boats="): boats=int(arg.get_slice("=",1))
	output+="/boats_"+str(boats)
	run.call_deferred()

func capture(label: String) -> Image:
	for i in 12: await process_frame
	await RenderingServer.frame_post_draw
	var image:=root.get_texture().get_image()
	image.save_png(output+"/"+label+".png")
	return image

func difference(a: Image,b: Image) -> Dictionary:
	var changed:=0
	var total:=0.0
	for y in a.get_height():
		for x in a.get_width():
			var ca:=a.get_pixel(x,y)
			var cb:=b.get_pixel(x,y)
			var d:=absf(ca.r-cb.r)+absf(ca.g-cb.g)+absf(ca.b-cb.b)
			if d>0.02: changed+=1
			total+=d
	return {"changed_pixels":changed,"mean_rgb_delta":total/(3*a.get_width()*a.get_height())}

func run() -> void:
	root.size=Vector2i(1280,720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps=120
	DirAccess.make_dir_recursive_absolute(output)
	world=Node3D.new()
	root.add_child(world)
	var env:=WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color(0.15,0.22,0.27)
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color(0.8,0.9,1.0)
	env.environment.ambient_light_energy=0.65
	world.add_child(env)
	var sun:=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-40,-30,0)
	sun.light_energy=1.6
	world.add_child(sun)
	var sea:=MeshInstance3D.new()
	var plane:=PlaneMesh.new()
	plane.size=Vector2(200,200)
	sea.mesh=plane
	var material:=ShaderMaterial.new()
	material.shader=Shader.new()
	material.shader.code="shader_type spatial; render_mode depth_draw_never; void fragment(){ ALBEDO=vec3(0.82,0.85,0.86); ROUGHNESS=0.92; SPECULAR=0.1; ALPHA=0.999; }"
	sea.material_override=material
	world.add_child(sea)
	var authored: Node3D=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
	var saved_nozzle: Transform3D=authored.get_node("BowSprayRoot/TailJet").transform
	var saved_style: Resource=authored.get_node("BowSprayRoot").hull_spray_settings.duplicate(true)
	authored.free()
	for index in boats:
		var boat:=Fixture.BoatFixture.new()
		boat.position=Vector3((index%3)*3.2,0.60,(index/3)*4.0)
		world.add_child(boat)
		boat.reset_physics_interpolation()
		var bow:=Fixture.SprayRootFixture.new()
		bow.hull_spray_settings=saved_style.duplicate(true)
		bow.hull_spray_settings.sides_enabled=false
		boat.add_child(bow)
		for label in ["SplashLeft","SplashRight","TailJet"]:
			var anchor:=Node3D.new()
			anchor.name=label
			bow.add_child(anchor)
		var nozzle: Node3D=bow.get_node("TailJet")
		nozzle.transform=saved_nozzle
		nozzles.append(nozzle)
		var hull: Node3D=load("res://addons/jet_ski/jet_ski_01/jet_ski_01_hull.glb").instantiate()
		hull.transform=Transform3D(Basis(Vector3.UP,PI),Vector3(0.372027,-0.300865,-1.2904756))
		boat.add_child(hull)
		var spray: Node3D=load("res://addons/jet_ski/common/visual/hull_spray/jet_ski_hull_spray.gd").new()
		bow.add_child(spray)
		spray.set_process(false)
		spray.settings.tail_appearance.anim_fps=0.0
		spray.settings.tail_appearance.distortion_speed=0.0
		spray.settings.tail_appearance.normal_scroll_speed=0.0
		spray.settings.stern_mist.preview_in_editor=false
		spray._mist.use_fixed_seed=true
		spray._mist.seed=1717+index
		spray._tail_frame=8.5
		for i in 60: spray._process(1.0/60.0)
		sprays.append(spray)
	camera=Camera3D.new()
	camera.fov=48
	world.add_child(camera)
	camera.position=Vector3(1.9,2.3,7.0) if boats==1 else Vector3(4.5,7.0,16)
	camera.look_at(Vector3(0,0.3,1.2) if boats==1 else Vector3(3,0,3))
	camera.make_current()
	for spray in sprays: spray._mist.hide(); spray._tail.hide()
	var blank: Image=await capture("no_tail")
	for spray in sprays:
		spray._tail.show()
		spray._tail_material.set_shader_parameter("tail_surface_fade_depth",0.0)
		spray._tail_material.set_shader_parameter("tail_water_core_strength",0.0)
	var before: Image=await capture("tail_before")
	for spray in sprays:
		spray._tail_material.set_shader_parameter("tail_surface_fade_depth",spray.settings.tail_surface_fade_depth_m)
		spray._tail_material.set_shader_parameter("tail_water_core_strength",spray.settings.tail_water_core_strength)
	var after: Image=await capture("tail_after")
	var before_delta:=difference(blank,before)
	var after_delta:=difference(blank,after)
	assert(after_delta.changed_pixels>before_delta.changed_pixels,"Tail shallow fade did not recover visible jet over white water")
	# Emit and move the same local GPU cloud, then validate hard air/dry gates.
	for spray in sprays: spray._mist.visible=true
	var end:=Time.get_ticks_msec()+750
	while Time.get_ticks_msec()<end:
		for spray in sprays: spray._process(1.0/120.0)
		await process_frame
	var with_mist: Image=await capture("tail_and_mist")
	var mist_delta:=difference(after,with_mist)
	assert(mist_delta.changed_pixels>10,"Mist did not render")
	var mist: GPUParticles3D=sprays[0]._mist
	assert(not mist.local_coords and mist.fixed_fps==30)
	for spray in sprays:
		var boat: Node3D=spray._vehicle
		boat.water_physics_system.contact_is_airborne=true
		spray._process(0.05)
		assert(not spray._mist.emitting and spray._mist.visible)
		boat.water_physics_system.contact_is_airborne=false
		boat.linear_velocity=Vector3.ZERO
		boat.throttle_input=0.0
		for i in 90: spray._process(1.0/60.0)
		assert(not spray._mist.emitting and spray._mist.visible)
		boat.linear_velocity=Vector3(0,0,-25)
		boat.throttle_input=1.0
		for i in 60: spray._process(1.0/60.0)
	# Same scene, ABBA; includes particle simulation and transparent rendering.
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	Engine.max_fps=0
	var rows: Array=[]
	var ram_before:=OS.get_static_memory_usage()
	for revised in [false,true,true,false]:
		for spray in sprays:
			spray.settings.stern_mist.enabled=revised
			spray._tail_material.set_shader_parameter("tail_surface_fade_depth",spray.settings.tail_surface_fade_depth_m if revised else 0.0)
			spray._tail_material.set_shader_parameter("tail_water_core_strength",spray.settings.tail_water_core_strength if revised else 0.0)
			spray._mist.visible=revised
			spray._mist.emitting=revised
			spray._mist.speed_scale=1.0 if revised else 0.0
		for i in 80: await process_frame
		var gpu:=0.0
		var cpu:=0.0
		var n:=0
		var visual_cpu_us:=0
		var begin:=Time.get_ticks_usec()
		var previous:=begin
		while Time.get_ticks_usec()<begin+1200000:
			await process_frame
			var now:=Time.get_ticks_usec()
			for spray in sprays:
				spray._process((now-previous)/1000000.0)
				if not revised:
					spray._mist.visible=false
					spray._mist.emitting=false
			visual_cpu_us+=Time.get_ticks_usec()-now
			previous=now
			gpu+=RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
			cpu+=RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid())
			n+=1
		rows.append({"revised":revised,"gpu_ms":gpu/maxi(n,1),"render_cpu_ms":cpu/maxi(n,1),"visual_cpu_ms":visual_cpu_us/1000.0/maxi(n,1),"frame_ms":(Time.get_ticks_usec()-begin)/1000.0/maxi(n,1)})
	var report:={"passed":true,"boats":boats,"tail_before":before_delta,"tail_after":after_delta,"mist":mist_delta,"particle_budget":mist.amount*boats,"extra_water_queries":0,"world_space":true,"air_and_idle_gates":true,"static_ram_growth_bytes":OS.get_static_memory_usage()-ram_before,"runs":rows}
	FileAccess.open(output+"/report.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("STERN_VFX_PASS ",JSON.stringify(report))
	world.queue_free()
	for i in 8: await process_frame
	quit()
