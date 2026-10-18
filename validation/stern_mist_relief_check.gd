extends SceneTree
## GPU particle material A/B with real directional lighting and frozen geometry.
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func capture() -> Image:
	for frame in 8: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func delta(a: Image,b: Image) -> float:
	var total := 0.0
	for y in a.get_height():
		for x in a.get_width():
			var ca := a.get_pixel(x,y)
			var cb := b.get_pixel(x,y)
			total+=absf(ca.r-cb.r)+absf(ca.g-cb.g)+absf(ca.b-cb.b)
	return total/(a.get_width()*a.get_height()*3.0)

func run() -> void:
	root.size=Vector2i(640,360)
	Engine.max_fps=120
	var source: Node=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
	var mist: GPUParticles3D=source.get_node("BowSprayRoot/SternMist")
	mist.get_parent().remove_child(mist)
	source.free()
	root.add_child(mist)
	var material := mist.draw_pass_1.material as ShaderMaterial
	var saved_normal_strength: float=material.get_shader_parameter("droplet_normal_strength")
	var normal := material.get_shader_parameter("droplet_normal") as NoiseTexture2D
	if normal==null or not normal.as_normal_map: failures.append("procedural normal texture missing")
	var mask := material.get_shader_parameter("mist_noise") as NoiseTexture2D
	if mask==null or mask.as_normal_map: failures.append("scalar mask must remain scalar")
	material.set_shader_parameter("mist_opacity",0.75)
	material.set_shader_parameter("turbulence",0.0)
	material.set_shader_parameter("waterline_y",-3.0)
	material.set_shader_parameter("speed_kmh",60.0)
	material.set_shader_parameter("breakup_strength",0.35)
	var p := ParticleProcessMaterial.new()
	p.gravity=Vector3.ZERO
	mist.process_material=p
	mist.global_transform=Transform3D.IDENTITY
	mist.draw_pass_1.size=Vector2(2,2)
	mist.amount=1
	mist.amount_ratio=1.0
	mist.lifetime=20.0
	mist.randomness=0.0
	mist.preprocess=1.0
	mist.visible=true
	mist.emitting=true
	var env := WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color(0.015,0.025,0.035)
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color.WHITE
	env.environment.ambient_light_energy=0.12
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-25,-35,0)
	sun.light_energy=2.0
	root.add_child(sun)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.position=Vector3(0,0,2.6)
	camera.look_at(Vector3.ZERO)
	await create_timer(0.3).timeout
	mist.speed_scale=0.0
	material.set_shader_parameter("droplet_relief_enabled",false)
	var flat := await capture()
	material.set_shader_parameter("droplet_relief_enabled",true)
	var relief := await capture()
	var relief_delta := delta(flat,relief)
	if relief_delta<0.0001: failures.append("normal relief did not affect particle lighting")
	sun.rotation_degrees=Vector3(15,35,0)
	var moved_light := await capture()
	var light_delta := delta(relief,moved_light)
	if light_delta<0.0001: failures.append("relief did not respond to light direction")
	material.set_shader_parameter("droplet_normal_strength",0.0)
	var no_normal := await capture()
	var strength_delta := delta(moved_light,no_normal)
	if strength_delta<0.0001: failures.append("normal strength did not affect lighting")
	material.set_shader_parameter("droplet_normal_strength",saved_normal_strength)
	material.set_shader_parameter("droplet_specular",0.0)
	var no_specular := await capture()
	var specular_delta := delta(moved_light,no_specular)
	if specular_delta<0.00001: failures.append("specular control did not affect highlights")
	DirAccess.make_dir_recursive_absolute("res://temp/stern_mist_relief")
	flat.save_png("res://temp/stern_mist_relief/flat.png")
	relief.save_png("res://temp/stern_mist_relief/relief.png")
	moved_light.save_png("res://temp/stern_mist_relief/moved_light.png")
	print("STERN_MIST_RELIEF ",JSON.stringify({"failures":failures,"relief_delta":relief_delta,"light_delta":light_delta,"strength_delta":strength_delta,"specular_delta":specular_delta}))
	quit(0 if failures.is_empty() else 1)
