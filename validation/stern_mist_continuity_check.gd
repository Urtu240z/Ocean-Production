extends SceneTree
## Render the actual saved artist preset while its emitter moves through the world.
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func energy(image: Image) -> float:
	var sum := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x,y)
			sum+=maxf(c.r,maxf(c.g,c.b))
	return sum

func run() -> void:
	root.size=Vector2i(640,360)
	Engine.max_fps=120
	var source: Node=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
	var mist: GPUParticles3D=source.get_node("BowSprayRoot/SternMist")
	mist.get_parent().remove_child(mist)
	source.free()
	root.add_child(mist)
	var saved_amount := mist.amount
	var saved_lifetime := mist.lifetime
	var style: Resource=load("res://addons/jet_ski/common/visual/hull_spray/stern_mist_style.tres").duplicate(true)
	mist.configure(style)
	check(mist.amount==saved_amount and is_equal_approx(mist.lifetime,saved_lifetime),"saved count and lifetime preserved")
	check(mist.fixed_fps==0 and mist.randomness==0 and mist.explosiveness==0,"uniform frame-rate emission")
	check(mist.interpolate and mist.fract_delta and not mist.local_coords,"world-space interpolated simulation")
	var p := mist.process_material as ShaderMaterial
	var ramp := p.get_shader_parameter("color_ramp") as GradientTexture1D
	check(ramp!=null,"artist ramp retained")
	check(is_zero_approx(ramp.gradient.sample(0).a) and is_zero_approx(ramp.gradient.sample(1).a),"transparent ramp endpoints")
	var saved_opacity: float=(mist.draw_pass_1.material as ShaderMaterial).get_shader_parameter("mist_opacity")
	var env := WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color.BLACK
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color.WHITE
	env.environment.ambient_light_energy=1.0
	root.add_child(env)
	var camera := Camera3D.new()
	root.add_child(camera)
	var elapsed := 0.0
	var samples: Array[float] = []
	var captured := false
	DirAccess.make_dir_recursive_absolute("res://temp/stern_mist_continuity")
	for frame in 110:
		await process_frame
		var dt := root.get_process_delta_time()
		elapsed+=dt
		var center := Vector3(elapsed*12.0,0.4,0)
		mist.step(dt,Transform3D(Basis.IDENTITY,center),0.0,12.0,0.0,1.0)
		camera.position=center+Vector3(-3,2,5)
		camera.look_at(center+Vector3(-1,0,0))
		await RenderingServer.frame_post_draw
		if elapsed>0.5:
			var image := root.get_texture().get_image()
			samples.append(energy(image))
			if not captured:
				image.save_png("res://temp/stern_mist_continuity/moving_coast.png")
				captured=true
	var minimum := INF
	var maximum := 0.0
	var total := 0.0
	for sample in samples:
		minimum=minf(minimum,sample)
		maximum=maxf(maximum,sample)
		total+=sample
	check(not samples.is_empty() and minimum>1.0,"steady coasting has no blank emission frames")
	# Freeze identical particles/camera so only the speed-driven material changes.
	mist.speed_scale=0.0
	var material := mist.draw_pass_1.material as ShaderMaterial
	mist.step(2.0,mist.global_transform,0.0,10.0/3.6,0.0,1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var slow := root.get_texture().get_image()
	var slow_energy := energy(slow)
	mist.step(2.0,mist.global_transform,0.0,60.0/3.6,0.0,1.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var fast := root.get_texture().get_image()
	var fast_energy := energy(fast)
	check(fast_energy>slow_energy*1.5,"same particles are more opaque at 60 than 10 km/h")
	check(is_equal_approx(material.get_shader_parameter("mist_opacity"),saved_opacity),"speed response preserves authored base opacity")
	slow.save_png("res://temp/stern_mist_continuity/speed_10.png")
	fast.save_png("res://temp/stern_mist_continuity/speed_60.png")
	print("STERN_MIST_CONTINUITY ",JSON.stringify({"failures":failures,"frames":samples.size(),"minimum_energy":minimum,"maximum_energy":maximum,"mean_energy":total/maxi(samples.size(),1),"speed_10_energy":slow_energy,"speed_60_energy":fast_energy}))
	quit(0 if failures.is_empty() else 1)
