extends SceneTree
const Boundary=preload("res://addons/ocean/events/ocean_boundary_tsunami.gd")
var failures: Array[String]=[]
var rows: Array[Dictionary]=[]
func _initialize() -> void:
	Engine.max_fps=120
	call_deferred("run")
func check(ok: bool,label: String) -> void:
	if not ok: failures.append(label); push_error(label)
func frames(n: int) -> void:
	for i in n: await process_frame
func run() -> void:
	root.size=Vector2i(320,240)
	var world:=Node3D.new()
	root.add_child(world)
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.current=true
	camera.position=Vector3(310,5,0)
	var ocean: Node3D=load("res://addons/ocean/ocean.tscn").instantiate()
	for key in ["coastal","reflections","surface_detail","enable_spindrift","underwater_bubbles","underwater_sunrays"]: ocean.set(key,false)
	ocean.set("underwater_medium",true)
	ocean.set("sea_level",0.0)
	ocean.set("sea_state_mode",1)
	ocean.set("significant_wave_height_m",0.0)
	ocean.set("visual_water_profile",1)
	world.add_child(ocean)
	var target:=Node3D.new()
	world.add_child(target)
	var boundary=Boundary.new()
	boundary.ocean=ocean
	boundary.target=target
	boundary.fade_time_s=100000
	world.add_child(boundary)
	boundary.state=Boundary.State.CAUGHT
	boundary.radius=400
	boundary._hit_amplitude=60
	boundary.snapshot.center_radius=Vector4(0,0,400,60)
	boundary.snapshot.shape=Vector4(30,90,36,120)
	for i in 2400:
		await process_frame
		if ocean.get_physics_source_state().get("status","")=="OK": break
	ocean.set_waterline_state_readback_enabled(true)
	var provider: Node=ocean.get_water_provider()
	check(provider.configure(ocean),"native provider ready")
	var cases: Array[Dictionary]=[
		{"name":"before_trough","p":Vector3(310,5,0)},
		{"name":"trough_air","p":Vector3(340,5,0)},
		{"name":"front_still_air","p":Vector3(360,5,0)},
		{"name":"front_submerged","p":Vector3(368,5,0)},
		{"name":"crest_submerged","p":Vector3(400,20,0)},
		{"name":"above_back","p":Vector3(440,80,0)},
		{"name":"outside_arc","p":Vector3(-400,5,0)},
		{"name":"feather_still_air","p":Vector3(cos(deg_to_rad(110))*400,30,sin(deg_to_rad(110))*400)},
		{"name":"past_arc_edge","p":Vector3(cos(deg_to_rad(124))*400,5,sin(deg_to_rad(124))*400)}]
	for item in cases:
		camera.position=item.p
		await frames(15)
		var state: Dictionary=ocean.get_waterline_state()
		var expected: Vector4=boundary.snapshot.sample(Vector2(item.p.x,item.p.z))
		provider.begin_contacts(Transform3D.IDENTITY,PackedVector3Array([item.p]))
		var cpu=provider.sample_water(item.p)
		var actual: float=state.get("water_surface_y",-999)
		var error: float=absf(actual-expected.x)
		var medium: Node=ocean.get("_underwater_medium")
		var runtime_state: StringName=medium.get("_runtime_water_state")
		check(state.get("valid",false) and error<0.02,item.name+" GPU/visible profile alignment")
		check(cpu.valid and absf(cpu.surface_position.y-expected.x)<0.001,item.name+" native/visible profile alignment")
		if item.p.y-expected.x>2.0: check(runtime_state==&"AIR_SAFE",item.name+" remains air before contact")
		elif item.p.y-expected.x< -2.0: check(runtime_state==&"UNDERWATER_SAFE",item.name+" enters only below surface")
		rows.append({"case":item.name,"expected_y":expected.x,"gpu_y":actual,"error_m":error,"runtime_state":runtime_state})
	print("TSUNAMI_ALIGNMENT_RESULT failures=",failures," rows=",JSON.stringify(rows))
	var output:=FileAccess.open("res://temp/tsunami_alignment_result.json",FileAccess.WRITE)
	output.store_string(JSON.stringify({"failures":failures,"rows":rows},"\t"))
	output.close()
	world.queue_free()
	await frames(10)
	quit(0 if failures.is_empty() else 1)
