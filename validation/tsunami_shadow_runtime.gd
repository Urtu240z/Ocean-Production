extends SceneTree
## Real shadow-map receiver test. Saved production scenes/settings stay untouched.
class FixedBoundary extends Node3D:
	var snapshot = preload("res://addons/ocean/events/ocean_tsunami_state.gd").new()
	func advance(_tick: int,_delta: float) -> void: pass

var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool,label: String) -> void:
	if not ok: failures.append(label); push_error("TSUNAMI_SHADOW_FAIL "+label)
func frames(count: int) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func image(name: String) -> Image:
	var result := root.get_texture().get_image()
	result.save_png("res://temp/tsunami_shadow/"+name+".png")
	return result

func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://temp/tsunami_shadow")
	root.size = Vector2i(800,600)
	var world := Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(150,160,180)
	camera.look_at(Vector3.ZERO)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 260
	camera.far = 1000
	camera.current = true
	var sun := DirectionalLight3D.new()
	world.add_child(sun)
	sun.rotation_degrees = Vector3(-40,-25,0)
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.15,0.25,0.35)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.08
	world.add_child(environment)
	var receiver := MeshInstance3D.new()
	receiver.mesh = PlaneMesh.new()
	receiver.mesh.size = Vector2(340,340)
	receiver.position.y = 1.0
	receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.8,0.08,0.04)
	red.roughness = 1.0
	receiver.material_override = red
	world.add_child(receiver)
	var ocean: Ocean = load("res://addons/ocean/ocean.tscn").instantiate()
	for key in ["coastal","reflections","optics","crest_foam","surface_foam","surface_detail","enable_spindrift","underwater_medium"]: ocean.set(key,false)
	ocean.wave_height_scale = 0.0
	world.add_child(ocean)
	var boundary := FixedBoundary.new()
	world.add_child(boundary)
	check(ocean.register_boundary_tsunami(boundary),"boundary registered")
	for i in 1200:
		await process_frame
		if ocean.get_physics_source_state().get("status","") == "OK": break
	await frames(20)
	var surface: OceanClipmapSurface = ocean.get_node("OpenOceanFFT/OceanClipmapSurface")
	check(surface.get("_tsunami_shadow_instances").is_empty(),"no allocation without tsunami")
	boundary.snapshot.center_radius = Vector4(0,0,80,30)
	boundary.snapshot.shape = Vector4(15,25,18,180)
	boundary.snapshot.motion = Vector4(0,0,0.25,0)
	boundary.snapshot.cast_shadows = false
	await frames(20)
	var without := image("wave_without_shadow")
	var physical_samples := []
	for x in [0.0,40.0,65.0,80.0,100.0]: physical_samples.append(boundary.snapshot.sample(Vector2(x,0)))
	var physical_buffer: PackedFloat32Array = boundary.snapshot.packed()
	boundary.snapshot.cast_shadows = true
	await frames(30)
	var with_shadow := image("wave_with_shadow")
	check(surface.get("_tsunami_shadows_active"),"shadow active")
	var shadows: Array = surface.get("_tsunami_shadow_instances")
	var levels: Array = surface.get("_levels")
	check(shadows.size() == levels.size(),"one shared caster per clipmap level")
	for i in shadows.size():
		check(shadows[i].mesh == levels[i].mesh,"mesh buffer reused")
		check(shadows[i].custom_aabb == levels[i].custom_aabb,"same expanded culling bounds")
		check(shadows[i].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,"shadow-only draw")
		check(levels[i].cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"flat ocean stays non-casting")
	var darkened_red_pixels := 0
	for y in without.get_height():
		for x in without.get_width():
			var a := without.get_pixel(x,y)
			var b := with_shadow.get_pixel(x,y)
			if a.r > 0.2 and a.r > a.g*2.0 and a.r > a.b*2.0 and a.r-b.r > 0.05: darkened_red_pixels += 1
	check(darkened_red_pixels > 200,"wave actually shadows the red receiver")
	for i in physical_samples.size(): check(physical_samples[i] == boundary.snapshot.sample(Vector2([0.0,40.0,65.0,80.0,100.0][i],0)),"CPU sample bit exact")
	check(physical_buffer == boundary.snapshot.packed(),"physical packed data unchanged")
	var option := OceanBoundaryTsunami.new()
	option.cast_shadows = false
	check(not option.snapshot.cast_shadows,"Inspector switch propagated")
	option.free()
	boundary.snapshot.cast_shadows = false
	await frames(15)
	check(not surface.get("_tsunami_shadows_active"),"live disable")
	boundary.snapshot.cast_shadows = true
	boundary.snapshot.clear()
	await frames(15)
	check(not surface.get("_tsunami_shadows_active"),"wave end disables shadow")
	for shadow in shadows: check(not shadow.visible,"inactive caster hidden")
	image("wave_finished")
	# Hide color geometry by layer to observe the same caster on a submerged receiver.
	# This also proves flat water is discarded only in tsunami-only mode.
	camera.cull_mask = 1
	sun.light_cull_mask = 1
	for level in levels: level.layers = 2
	receiver.position.y = -5.0
	await frames(15)
	var sea_off := image("sea_without_shadow")
	ocean.cast_shadows = true
	await frames(20)
	check(surface.get("_tsunami_shadows_active"),"whole ocean live enable")
	var shadow_material: ShaderMaterial = surface.get("_tsunami_shadow_material")
	check(not shadow_material.get_shader_parameter("ocean_shadow_crest_only"),"full ocean does not clip flat water")
	check(surface.get("_tsunami_shadow_instances") == shadows,"full ocean reuses existing casters")
	var sea_on := image("sea_with_shadow")
	var sea_pixels := 0
	for y in sea_off.get_height():
		for x in sea_off.get_width():
			var a := sea_off.get_pixel(x,y)
			var b := sea_on.get_pixel(x,y)
			if a.r > 0.2 and a.r > a.g*2.0 and a.r-b.r > 0.05: sea_pixels += 1
	check(sea_pixels > 200,"whole ocean actually shadows submerged receiver")
	ocean.cast_shadows = false
	await frames(10)
	check(not surface.get("_tsunami_shadows_active"),"whole ocean live disable")
	var result := {"failures":failures,"receiver_shadow_pixels":darkened_red_pixels,"sea_shadow_pixels":sea_pixels,"shared_casters":shadows.size(),"driver":RenderingServer.get_current_rendering_driver_name()}
	var file := FileAccess.open("res://temp/tsunami_shadow/results.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t")); file.close()
	print("TSUNAMI_SHADOW_RESULT ",JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)
