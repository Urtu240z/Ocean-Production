extends SceneTree
## Real GPU fixture: moving a stopped emitter must leave its live mist behind.
var mist: GPUParticles3D
var failures: Array[String] = []

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func capture() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func center(image: Image) -> Vector3:
	var sum := Vector2.ZERO
	var weight := 0.0
	for y in image.get_height():
		for x in image.get_width():
			var c := image.get_pixel(x,y)
			var v := maxf(c.r,maxf(c.g,c.b))
			if v>0.02:
				sum+=Vector2(x,y)*v
				weight+=v
	return Vector3(sum.x/maxf(weight,0.001),sum.y/maxf(weight,0.001),weight)

func run() -> void:
	root.size=Vector2i(640,360)
	Engine.max_fps=120
	var packed := load("res://addons/jet_ski/common/visual/bow_spray/bow_spray.tscn") as PackedScene
	var spray := packed.instantiate()
	mist=spray.get_node("SternMist")
	spray.remove_child(mist)
	spray.free()
	# Keep the original free-particle contract covered alongside the guided flow.
	mist.process_material=mist.get_meta("original_particle_process_material").duplicate(true)
	mist.lifetime=0.5
	root.add_child(mist)
	var style := load("res://addons/jet_ski/common/visual/hull_spray/stern_mist_style.tres").duplicate(true)
	mist.configure(style)
	check(not mist.local_coords,"world coordinates")
	check(is_equal_approx(mist.lifetime,0.5),"half second lifetime")
	var material := mist.process_material as ParticleProcessMaterial
	material.initial_velocity_min=0.0
	material.initial_velocity_max=0.0
	material.turbulence_enabled=false
	material.gravity=Vector3.ZERO
	material.emission_box_extents=Vector3(0.4,0.1,0.1)
	material.spread=17.0
	mist.amount=1000
	mist.amount_ratio=0.7
	var gradient := Gradient.new()
	gradient.offsets=PackedFloat32Array([0.0,0.2,0.8,1.0])
	gradient.colors=PackedColorArray([Color(1,1,1,0),Color.WHITE,Color.WHITE,Color(1,1,1,0)])
	var ramp := GradientTexture1D.new()
	ramp.gradient=gradient
	material.color_ramp=ramp
	var authored_shader := mist.draw_pass_1.material as ShaderMaterial
	authored_shader.set_shader_parameter("mist_opacity",0.73)
	mist.configure(style)
	style.amount=1000
	style.opacity=0.15
	style.color=Color.RED
	style.emit_changed()
	check(is_equal_approx(material.spread,17.0) and mist.amount==1000,"1000 native particles survive configure/profile changes")
	check(material.color_ramp==ramp and is_zero_approx(gradient.sample(0.0).a) and is_zero_approx(gradient.sample(1.0).a) and gradient.sample(0.5)==Color.WHITE,"native lifetime ramp preserved")
	check(is_equal_approx(authored_shader.get_shader_parameter("mist_opacity"),0.73),"native shader opacity survives profile changes")
	mist.step(0.02,Transform3D.IDENTITY,-2.0,20.0,1.0,1.0)
	check(is_equal_approx(mist.amount_ratio,0.7),"native amount ratio survives step")
	mist.stop()
	mist.step(0.2,Transform3D.IDENTITY,-2.0,20.0,0.0,1.0)
	check(mist.emitting,"wet coasting emits mist without throttle")
	mist.step(1.0,Transform3D.IDENTITY,-2.0,0.0,0.0,1.0)
	check(not mist.emitting,"stationary hull does not emit mist")
	mist.step(0.2,Transform3D.IDENTITY,-2.0,20.0,0.0,0.0)
	check(not mist.emitting,"dry hull does not emit mist")
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
	camera.position=Vector3(0,1,8)
	camera.look_at(Vector3(0,1,0))
	mist.position=Vector3(0,1,0)
	mist.visible=true
	mist.amount_ratio=1.0
	mist.emitting=true
	(mist.draw_pass_1.material as ShaderMaterial).set_shader_parameter("waterline_y",-2.0)
	await create_timer(0.2).timeout
	var before := await capture()
	mist.stop()
	mist.position.x=8.0
	var after := await capture()
	var a := center(before)
	var b := center(after)
	check(a.z>0.1 and b.z>0.1,"live particles remain visible after stopping")
	check(Vector2(a.x,a.y).distance_to(Vector2(b.x,b.y))<30.0,"live particles stay at world origin when emitter moves 8m")
	await create_timer(0.65).timeout
	var expired := await capture()
	check(center(expired).z<0.1,"particles expire after half second")
	# Verify that GPU color-ramp alpha actually reaches the spatial shader.
	mist.position=Vector3(0,1,0)
	mist.lifetime=2.0
	gradient.colors=PackedColorArray([Color(1,1,1,0),Color(1,1,1,0),Color(1,1,1,0),Color(1,1,1,0)])
	mist.emitting=true
	await create_timer(0.15).timeout
	var transparent := await capture()
	check(center(transparent).z<0.1,"GPU ramp transparent alpha hides mist")
	gradient.colors=PackedColorArray([Color.WHITE,Color.WHITE,Color.WHITE,Color.WHITE])
	await create_timer(0.15).timeout
	var opaque := await capture()
	check(center(opaque).z>0.1,"GPU ramp white alpha shows mist")
	gradient.colors=PackedColorArray([Color(1,1,1,0),Color(1,1,1,0),Color(1,1,1,0),Color(1,1,1,0)])
	await create_timer(0.15).timeout
	var transparent_again := await capture()
	check(center(transparent_again).z<0.1,"GPU ramp transparent alpha hides live mist again")
	DirAccess.make_dir_recursive_absolute("res://temp/stern_mist_world")
	before.save_png("res://temp/stern_mist_world/before.png")
	after.save_png("res://temp/stern_mist_world/after.png")
	print("STERN_MIST_WORLD ",JSON.stringify({"failures":failures,"before":str(a),"after":str(b)}))
	quit(0 if failures.is_empty() else 1)
