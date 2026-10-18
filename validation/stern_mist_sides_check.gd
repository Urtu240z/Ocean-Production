extends SceneTree
## Actual saved GPU emitters: mirrored hull contours and detached straight tails.
var failures: Array[String] = []
var emitters: Array[GPUParticles3D] = []
var style: Resource

func _initialize() -> void:
	run.call_deferred()

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func capture(label: String) -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png("res://temp/stern_mist_sides/"+label+".png")
	return image

func region_energy(image: Image,rect: Rect2i) -> float:
	var sum := 0.0
	for y in range(rect.position.y,rect.end.y):
		for x in range(rect.position.x,rect.end.x):
			var c := image.get_pixel(x,y)
			sum+=maxf(c.r,maxf(c.g,c.b))
	return sum

func settle(pose: Transform3D,seconds: float) -> void:
	var elapsed := 0.0
	while elapsed<seconds:
		await process_frame
		var dt := root.get_process_delta_time()
		elapsed+=dt
		for emitter in emitters: emitter.step(dt,pose,0.0,12.0,0.0,1.0)

func run() -> void:
	root.size=Vector2i(720,720)
	Engine.max_fps=120
	DirAccess.make_dir_recursive_absolute("res://temp/stern_mist_sides")
	var source: Node=load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
	for name in ["SternMist","SternMistRight"]:
		var emitter: GPUParticles3D=source.get_node("BowSprayRoot/"+name)
		emitter.get_parent().remove_child(emitter)
		emitters.append(emitter)
	source.free()
	style=load("res://addons/jet_ski/common/visual/hull_spray/stern_mist_style.tres").duplicate(true)
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
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=6.0
	camera.position=Vector3(0,6,0.5)
	camera.look_at(Vector3(0,0,0.5),Vector3(0,0,-1))
	for index in emitters.size():
		var emitter := emitters[index]
		root.add_child(emitter)
		var saved_amount := emitter.amount
		var saved_lifetime := emitter.lifetime
		emitter.configure(style)
		var process := emitter.process_material as ShaderMaterial
		check(process!=null,"guided process material")
		check(process.get_shader_parameter("side")==(-1.0 if index==0 else 1.0),"mirrored side")
		check(emitter.amount==saved_amount and is_equal_approx(emitter.lifetime,saved_lifetime),"artist budget and lifetime preserved")
		var draw := emitter.draw_pass_1.material as ShaderMaterial
		draw.set_shader_parameter("mist_opacity",0.35)
		draw.set_shader_parameter("droplet_relief_enabled",false)
		draw.set_shader_parameter("mist_color",Color(0.3,0.8,1) if index==0 else Color(1,0.65,0.2))
		emitter.draw_pass_1.size=Vector2(0.12,0.12)
	check(emitters[0].process_material!=emitters[1].process_material,"independent process materials")
	check(emitters[0].draw_pass_1.material!=emitters[1].draw_pass_1.material,"independent draw materials")
	var pose := Transform3D(Basis.IDENTITY,Vector3(0,0,1.25))
	await settle(pose,1.2)
	var contours := await capture("contours")
	var left := region_energy(contours,Rect2i(230,80,110,540))
	var right := region_energy(contours,Rect2i(380,80,110,540))
	check(left>10 and right>10,"both GPU contours render")
	var common_tail := Rect2i(342,625,36,45)
	var long_energy := region_energy(contours,common_tail)
	check(long_energy>1.0,"both streams merge into the central metre-long tail")
	# Check native GPU scale changes, including growing back from an exact zero.
	for emitter in emitters:
		(emitter.process_material as ShaderMaterial).set_shader_parameter("birth_size",0.0)
		(emitter.process_material as ShaderMaterial).set_shader_parameter("end_size",0.0)
	await settle(pose,0.8)
	var zero_size := await capture("zero_size")
	check(region_energy(zero_size,Rect2i(0,0,720,720))<0.1,"zero birth/end size hides particles")
	for emitter in emitters:
		(emitter.process_material as ShaderMaterial).set_shader_parameter("birth_size",0.2)
		(emitter.process_material as ShaderMaterial).set_shader_parameter("end_size",1.5)
	await settle(pose,0.8)
	var growing := await capture("growing")
	check(region_energy(growing,Rect2i(0,0,720,720))>10.0,"particles recover from zero and grow over lifetime")
	for emitter in emitters:
		(emitter.process_material as ShaderMaterial).set_shader_parameter("birth_size",1.0)
		(emitter.process_material as ShaderMaterial).set_shader_parameter("end_size",1.0)
	for emitter in emitters:
		(emitter.process_material as ShaderMaterial).set_shader_parameter("tail_length_m",0.2)
	await settle(pose,0.8)
	var short_tail := await capture("short_tail")
	var short_energy := region_energy(short_tail,common_tail)
	check(long_energy>short_energy*2.0+1.0,"metric tail control extends beyond the short-tail fixture")
	for emitter in emitters:
		emitter.lifetime=1.0
		(emitter.process_material as ShaderMaterial).set_shader_parameter("tail_length_m",1.0)
	await settle(pose,1.2)
	var one_second := await capture("one_second")
	check(region_energy(one_second,common_tail)>1.0,"one-second lifetime retains the metre-long central tail")
	for emitter in emitters:
		emitter.stop()
		emitter.global_position+=Vector3(20,0,0)
	await create_timer(0.1).timeout
	var detached := await capture("detached")
	check(region_energy(detached,Rect2i(230,80,260,580))>10,"stopped particles remain in world after emitter moves")
	await create_timer(1.1).timeout
	var expired := await capture("expired")
	check(region_energy(expired,Rect2i(0,0,720,720))<0.1,"guided particles expire")
	print("STERN_MIST_SIDES ",JSON.stringify({"failures":failures,"left_energy":left,"right_energy":right,"one_metre_tail_energy":long_energy,"short_tail_energy":short_energy}))
	quit(0 if failures.is_empty() else 1)
