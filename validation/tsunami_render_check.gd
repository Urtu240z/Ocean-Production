extends SceneTree
const Boundary=preload("res://addons/ocean/events/ocean_boundary_tsunami.gd")
class TestBody extends RigidBody3D:
	var water_physics_system: Node
class TestPhysics extends Node:
	var point_sample_valid: Array=[false,false,false,false]
	var point_depths:=PackedFloat32Array([0,0,0,0])
	var point_relative_normal_speeds:=PackedFloat32Array([0,0,0,0])
	var contact_is_airborne:=true
var failures: Array[String]=[]
func _initialize() -> void:
	Engine.max_fps=120
	call_deferred("run")
func check(ok: bool,label: String) -> void:
	if not ok: failures.append(label); push_error(label)
func frames(count: int) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func run() -> void:
	root.size=Vector2i(320,240)
	var world:=Node3D.new()
	root.add_child(world)
	var ocean: Node3D=load("res://addons/ocean/ocean.tscn").instantiate()
	for key in ["coastal","reflections","surface_detail","enable_spindrift","underwater_bubbles","underwater_sunrays"]: ocean.set(key,false)
	ocean.set("underwater_medium",true)
	ocean.set("sea_level",0.0)
	ocean.set("sea_state_mode",1)
	ocean.set("significant_wave_height_m",0.0)
	ocean.set("visual_water_profile",1)
	ocean.set("foam_enabled",true)
	ocean.get_hull_foam_settings().deformation_enabled=false
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.position=Vector3(400,250,0)
	camera.rotation_degrees=Vector3(-90,0,0)
	camera.projection=Camera3D.PROJECTION_ORTHOGONAL
	camera.size=220
	camera.far=1000
	camera.current=true
	var light:=DirectionalLight3D.new()
	world.add_child(light)
	light.rotation_degrees=Vector3(-50,-30,0)
	var environment:=WorldEnvironment.new()
	environment.environment=Environment.new()
	environment.environment.background_mode=Environment.BG_COLOR
	environment.environment.background_color=Color(0.2,0.4,0.6)
	environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color=Color(0.5,0.6,0.7)
	world.add_child(environment)
	var target:=Node3D.new()
	world.add_child(target)
	target.position=Vector3(400,0,0)
	world.add_child(ocean)
	var boundary=Boundary.new()
	boundary.ocean=ocean
	boundary.target=target
	boundary.fade_time_s=100000.0
	world.add_child(boundary)
	boundary.state=Boundary.State.CAUGHT
	boundary.radius=400.0
	boundary._hit_amplitude=60.0
	boundary.snapshot.center_radius=Vector4(0,0,400,60)
	boundary.snapshot.shape=Vector4(30,90,36,66)
	var body:=TestBody.new()
	body.freeze=true
	body.position=target.position
	var physics:=TestPhysics.new()
	body.add_child(physics)
	body.water_physics_system=physics
	world.add_child(body)
	ocean.register_hull_foam_vehicle(body)
	for i in 2400:
		await process_frame
		if is_instance_valid(ocean.get_hull_foam_runtime()) and ocean.get_physics_source_state().get("status","")=="OK": break
	check(is_instance_valid(ocean.get_hull_foam_runtime()),"actual foam material starts")
	if not is_instance_valid(ocean.get_hull_foam_runtime()): quit(1); return
	ocean.get_hull_foam_runtime().set_process(false)
	await frames(20)
	var surface: Node=ocean.get_node("OpenOceanFFT/OceanClipmapSurface")
	var material: ShaderMaterial=surface.get("_material")
	check(material.shader.code.contains("tsunami_math.gdshaderinc"),"actual foam shader includes tsunami")
	check(float(material.get_shader_parameter("tsunami_center_radius").w)>59.9,"tsunami published to surface")
	check(surface.get("_tsunami_height_bound")>=74.9,"huge wave included in clipmap culling bounds")
	DirAccess.make_dir_recursive_absolute("res://temp/tsunami")
	root.get_texture().get_image().save_png("res://temp/tsunami/surface.png")
	camera.projection=Camera3D.PROJECTION_PERSPECTIVE
	camera.position=Vector3(320,8,20)
	camera.look_at(Vector3(400,35,0))
	await frames(5)
	root.get_texture().get_image().save_png("res://temp/tsunami/approaching.png")
	var provider: Node=ocean.get_water_provider()
	check(provider.configure(ocean),"real water provider starts")
	var points:=PackedVector3Array([Vector3(400,0,0),Vector3(370,0,0),Vector3(440,0,0),Vector3(320,0,0)])
	provider.begin_contacts(Transform3D.IDENTITY,points)
	var samples: Array=provider.sample_water_batch(points)
	var max_error:=0.0
	for i in points.size():
		var expected: Vector4=boundary.snapshot.sample(Vector2(points[i].x,points[i].z))
		check(samples[i].valid,"real contact valid")
		max_error=maxf(max_error,absf(samples[i].surface_position.y-expected.x))
	check(max_error<0.001,"real CPU contacts receive full tsunami height")
	ocean.set_waterline_state_readback_enabled(true)
	camera.position=Vector3(400,20,0)
	camera.rotation=Vector3.ZERO
	camera.projection=Camera3D.PROJECTION_PERSPECTIVE
	await frames(40)
	var waterline: Dictionary=ocean.get_waterline_state()
	var expected_height: float=boundary.snapshot.sample(Vector2(400,0)).x
	var waterline_error: float=absf(float(waterline.get("water_surface_y",-999))-expected_height)
	check(waterline.get("valid",false) and waterline_error<0.01,"GPU underwater sensor sees same 60m tsunami")
	check(int(waterline.get("water_state",0))!=0 or expected_height>camera.position.y,"camera is below tsunami surface")
	print("TSUNAMI_RENDER_RESULT failures=",failures," cpu_error_m=",max_error," waterline_error_m=",waterline_error," crest_y=",expected_height)
	world.queue_free()
	await frames(8)
	quit(0 if failures.is_empty() else 1)
