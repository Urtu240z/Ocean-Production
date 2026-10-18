extends SceneTree
const AreaScene := preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
class TestBody extends RigidBody3D:
	var water_physics_system: Node
class TestPhysics extends Node:
	var point_sample_valid := [false,false,false,false]
	var point_depths := PackedFloat32Array([0,0,0,0])
	var point_relative_normal_speeds := PackedFloat32Array([0,0,0,0])
	var contact_is_airborne := true

var failures: Array[String] = []
func _initialize() -> void:
	Engine.max_fps = 120
	call_deferred("run")
func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error(label)
func frames(count: int) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func variance(image: Image) -> float:
	var mean := 0.0
	var mean_sq := 0.0
	var n := 0
	for y in range(32,224,3):
		for x in range(32,224,3):
			var v := image.get_pixel(x,y).r
			mean += v
			mean_sq += v*v
			n += 1
	return mean_sq/n-pow(mean/n,2)
func run() -> void:
	root.size = Vector2i(256,256)
	var world := Node3D.new()
	root.add_child(world)
	var ocean: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	for property in ["coastal","reflections","surface_detail","enable_spindrift","underwater_bubbles","underwater_sunrays","underwater_medium"]: ocean.set(property,false)
	ocean.set("surface_detail",true)
	ocean.set("sea_level",0.0)
	ocean.set("sea_state_mode",1)
	ocean.set("significant_wave_height_m",2.5)
	ocean.set("foam_enabled",true)
	ocean.set("foam_mode","combined")
	ocean.get_hull_foam_settings().deformation_enabled = false
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(1625,60,1613)
	camera.rotation_degrees = Vector3(-90,0,0)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 35
	camera.far = 200
	camera.current = true
	var area = AreaScene.instantiate()
	area.ocean = ocean
	area.position = Vector3(1625,0,1613)
	area.wave_height_m = 0.0
	area.blend_distance_m = 100.0
	world.add_child(area)
	world.add_child(ocean)
	var body := TestBody.new()
	var physics := TestPhysics.new()
	body.add_child(physics)
	body.water_physics_system = physics
	body.freeze = true
	body.position = Vector3(1625,0,1613)
	world.add_child(body)
	ocean.register_hull_foam_vehicle(body)
	for i in 3600:
		await process_frame
		if is_instance_valid(ocean.get_hull_foam_runtime()): break
	check(is_instance_valid(ocean.get_hull_foam_runtime()),"foam runtime starts")
	if not is_instance_valid(ocean.get_hull_foam_runtime()): quit(1); return
	ocean.get_hull_foam_runtime().set_process(false)
	await frames(30)
	var surface: Node = ocean.get_node("OpenOceanFFT/OceanClipmapSurface")
	var material: ShaderMaterial = surface.get("_material")
	check(material.shader.code.contains("wave_area_surface.gdshaderinc"),"active foam shader includes wave areas")
	var shader := Shader.new()
	var code := material.shader.code
	var end := code.rfind("}")
	code = code.substr(0,end)+"\nALBEDO=vec3(0.0);EMISSION=vec3(clamp(0.5+ocean_world_position.y*0.1,0.0,1.0));\n"+code.substr(end)
	shader.code = code
	material.shader = shader
	surface._hydrate_material(material)
	# A controlled non-flat displacement map makes this a geometry regression
	# test, independent of asynchronous FFT publication during test startup.
	var field := Image.create(64,64,false,Image.FORMAT_RGBAF)
	for z in 64:
		for x in 64:
			field.set_pixel(x,z,Color(0,2.0*sin(x*TAU/64.0)+0.8*cos(z*TAU/64.0),0,1))
	var neutral := Image.create(1,1,false,Image.FORMAT_RGBAF)
	neutral.set_pixel(0,0,Color(0,0,0,1))
	surface._set_surface_shader_parameter("displacement_long",ImageTexture.create_from_image(field))
	surface._set_surface_shader_parameter("displacement_mid",ImageTexture.create_from_image(neutral))
	surface._set_surface_shader_parameter("displacement_short",ImageTexture.create_from_image(neutral))
	surface._set_surface_shader_parameter("domain_long_m",40.0)
	area.enabled = false
	await frames(12)
	var outside := root.get_texture().get_image()
	area.enabled = true
	await frames(12)
	var calm := root.get_texture().get_image()
	area.wave_height_m = 1.5
	area.swell_height_m = 0.4
	area.ripple_height_m = 0.06
	area.cross_sea_amount = 0.6
	await frames(12)
	var local := root.get_texture().get_image()
	var outside_variance := variance(outside)
	var calm_variance := variance(calm)
	var local_variance := variance(local)
	check(outside_variance > 0.000001,"exterior displacement visible in height render")
	check(calm_variance < outside_variance*0.02,"foam shader renders calm local geometry even with 100 m blend")
	check(local_variance > 0.000001,"irregular local waves visible in height render")
	DirAccess.make_dir_recursive_absolute("res://temp/wave_areas")
	outside.save_png("res://temp/wave_areas/foam_fft_height.png")
	calm.save_png("res://temp/wave_areas/foam_calm_height.png")
	local.save_png("res://temp/wave_areas/foam_local_height.png")
	print("WAVE_AREA_FOAM_RENDER_RESULT failures=",failures," variances=",Vector3(outside_variance,calm_variance,local_variance))
	world.queue_free()
	await frames(5)
	quit(0 if failures.is_empty() else 1)
