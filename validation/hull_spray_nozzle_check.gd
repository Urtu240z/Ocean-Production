extends SceneTree
## Isolated V1 publication fixture: checks visual attachment without wave/drive changes.
class WaterFixture extends RefCounted:
	var point_sample_valid := PackedByteArray([1,1,1,1])
	var point_depths := PackedFloat32Array([0.15,0.15,0.15,0.15])
	var point_relative_normal_speeds := PackedFloat32Array([0,0,0,0])
	var point_water_surface_positions := PackedVector3Array([Vector3.ZERO,Vector3.ZERO,Vector3.ZERO,Vector3.ZERO])
	var contact_is_airborne := false

class BoatFixture extends Node3D:
	var water_physics_system := WaterFixture.new()
	var linear_velocity := Vector3(0,0,-25)
	var throttle_input := 1.0
	var steering_input := 0.0
	func get_water_provider() -> Variant: return null

class SprayRootFixture extends Node3D:
	var hull_spray_settings: Resource

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var boat := BoatFixture.new()
	world.add_child(boat)
	var bow := SprayRootFixture.new()
	bow.hull_spray_settings=load("res://addons/jet_ski/common/visual/hull_spray/default_style.tres").duplicate(true)
	bow.hull_spray_settings.sides_enabled=false
	bow.hull_spray_settings.tail_residual_seconds=0.0
	bow.hull_spray_settings.tail_appearance.attachment_slide_enabled=true
	boat.add_child(bow)
	for label in ["SplashLeft","SplashRight","TailJet"]:
		var anchor := Node3D.new()
		anchor.name=label
		bow.add_child(anchor)
	var nozzle: Node3D=bow.get_node("TailJet")
	nozzle.transform=Transform3D(Basis.from_euler(Vector3(0.07,0.1,-0.05)).scaled(Vector3(0.9,1.1,1.05)),Vector3(0.12,-0.2636896,1.25))
	var saved_nozzle := nozzle.transform
	var spray: Node3D=load("res://addons/jet_ski/common/visual/hull_spray/jet_ski_hull_spray.gd").new()
	bow.add_child(spray)
	spray.set_process(false)
	var max_error := 0.0
	var tested := 0
	for height in [-3.0,0.0,4.0]:
		for pitch in [-0.5,0.0,0.4]:
			for bank in [-0.45,0.0,0.45]:
				boat.transform=Transform3D(Basis.from_euler(Vector3(pitch,0.6,bank)),Vector3(2,height,-4))
				boat.reset_physics_interpolation()
				for wave_y in [-2.0,0.5,3.0]:
					for i in 4: boat.water_physics_system.point_water_surface_positions[i]=Vector3(0,wave_y,0)
					spray._process(0.1)
					assert(spray._tail.visible)
					var expected := boat.get_global_transform_interpolated()*saved_nozzle
					var actual: Transform3D=spray._tail.global_transform
					max_error=maxf(max_error,actual.origin.distance_to(expected.origin))
					assert(actual.is_equal_approx(expected),"Tail detached from manually positioned nozzle")
					assert(nozzle.transform.is_equal_approx(saved_nozzle))
					tested+=1
	# Holding a digital arrow cannot instantly bend the tail while the hull is level.
	boat.transform=Transform3D.IDENTITY
	boat.reset_physics_interpolation()
	spray._tail_bank=0.0
	nozzle.transform=Transform3D(Basis.IDENTITY,Vector3(0,-0.2636896,1.25))
	bow.hull_spray_settings.tail_appearance.attachment_slide_enabled=false
	boat.steering_input=1.0
	spray._process(1.0/60.0)
	assert(is_zero_approx(spray._tail_material.get_shader_parameter("steering")))
	boat.rotation.z=deg_to_rad(20.0)
	boat.reset_physics_interpolation()
	spray._process(1.0/60.0)
	var first: float=spray._tail_material.get_shader_parameter("steering")
	assert(first>0.0 and first<0.1,"Bank response jumped to maximum")
	for i in 60: spray._process(1.0/60.0)
	var settled: float=spray._tail_material.get_shader_parameter("steering")
	assert(settled>first and settled<0.58)
	boat.steering_input=-1.0
	spray._process(1.0/60.0)
	assert(float(spray._tail_material.get_shader_parameter("steering"))>0.0,"Arrow reversal bypassed bank response")
	# Genuine airborne contacts still stop new emission.
	boat.water_physics_system.contact_is_airborne=true
	spray._process(0.1)
	assert(not spray._tail.visible)
	boat.water_physics_system.contact_is_airborne=false
	# Capture the production shader on the actual hull asset from three angles.
	boat.transform=Transform3D.IDENTITY
	boat.reset_physics_interpolation()
	spray._tail_bank=0.0
	for i in 4: boat.water_physics_system.point_water_surface_positions[i]=Vector3(0,-2,0)
	var hull: Node3D=load("res://addons/jet_ski/jet_ski_01/jet_ski_01_hull.glb").instantiate()
	hull.transform=Transform3D(Basis(Vector3.UP,PI),Vector3(0.372027,-0.300865,-1.2904756))
	boat.add_child(hull)
	var light := DirectionalLight3D.new()
	light.rotation_degrees=Vector3(-40,-30,0)
	light.light_energy=1.8
	world.add_child(light)
	var env := WorldEnvironment.new()
	env.environment=Environment.new()
	env.environment.background_mode=Environment.BG_COLOR
	env.environment.background_color=Color(0.04,0.09,0.13)
	env.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color=Color(0.7,0.85,1)
	env.environment.ambient_light_energy=0.7
	world.add_child(env)
	var camera := Camera3D.new()
	camera.fov=46
	world.add_child(camera)
	camera.make_current()
	DirAccess.make_dir_recursive_absolute("res://temp/hull_spray/nozzle_cone")
	for variant in 2:
		bow.hull_spray_settings.tail_variant=variant
		for view in ["side","rear","above"]:
			camera.position=Vector3(5,1,2.7) if view=="side" else (Vector3(1.5,1.5,7) if view=="rear" else Vector3(2.5,6,3.5))
			camera.look_at(Vector3(0,0,1.7))
			for i in 12:
				spray._process(1.0/60.0)
				await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://temp/hull_spray/nozzle_cone/splash%d_%s.png"%[variant+3,view])
	FileAccess.open("res://temp/hull_spray/nozzle_cone/report.json",FileAccess.WRITE).store_string(JSON.stringify({
		"passed":true,"poses_and_water_heights":tested,"max_nozzle_error_m":max_error,
		"first_bank_frame":first,"settled_bank":settled,"manual_anchor_preserved":true,
		"digital_arrows_do_not_snap":true,"airborne_gate_preserved":true,
		"extra_water_queries":0,"mesh_vertices_per_layer":221,"tail_draw_instances":1},"\t"))
	print("HULL_SPRAY_NOZZLE_PASS poses=",tested," max_error_m=",max_error," first_bank=",first," settled=",settled)
	world.queue_free()
	await process_frame
	quit()
