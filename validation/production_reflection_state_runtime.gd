extends SceneTree
## Checks the saved scene's real resource, including live toggles and variant changes.
var failures: Array[String] = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label); push_error("PRODUCTION_REFLECTION_FAIL " + label)
func frames(count: int) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://temp/tsunami_shadow")
	root.size = Vector2i(800,450)
	var scene_path := "res://validation/p0_open_ocean.tscn"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--scene="): scene_path = arg.trim_prefix("--scene=")
	var scene: Node = load(scene_path).instantiate()
	root.add_child(scene)
	var matches := scene.find_children("Ocean","",true,false)
	check(matches.size() == 1,"single authored Ocean")
	if matches.is_empty(): quit(1); return
	var ocean: Ocean = matches[0]
	for i in 1200:
		await process_frame
		if ocean.get_physics_source_state().get("status","") == "OK": break
	await frames(40)
	var surface: OceanClipmapSurface = ocean.get_node("OpenOceanFFT/OceanClipmapSurface")
	var profile := ocean.reflection_profile
	var initial := profile.base_roughness
	var initial_path := profile.resource_path
	if scene_path.ends_with("hull_wave_physics_playground.tscn"):
		var caster: ShaderMaterial = surface.get("_tsunami_shadow_material")
		check(caster != null and caster.shader.code.contains("if (hull_waves_enabled)"),"shadow source retains Hull Foam vertex deformation")
	# Freeze only this fixture after real startup; compare the same water and view.
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	for node in scene.find_children("*","",true,false):
		node.process_mode = Node.PROCESS_MODE_DISABLED
		if node is RigidBody3D: node.freeze = true
	var original_shadows := ocean.cast_shadows
	for shadows_on in [false,true]:
		ocean.cast_shadows = shadows_on
		await frames(10)
		root.get_texture().get_image().save_png("res://temp/tsunami_shadow/"+scene_path.get_file().get_basename()+"_shadow_"+str(shadows_on)+".png")
	ocean.cast_shadows = original_shadows
	for value in [initial,0.0,0.08,0.25,0.5,1.0]:
		profile.base_roughness = value
		for reflections_on in [false,true]:
			ocean.reflections = reflections_on
			await frames(6)
			check(ocean.reflection_profile == profile,"authored profile retained")
			check(profile.base_roughness == value,"profile roughness retained")
			if reflections_on:
				var material: ShaderMaterial = surface.get("_material")
				check(material.shader.code.contains("ROUGHNESS = reflection_base_roughness;"),"roughness assignment exists in active shader")
				check(is_equal_approx(float(material.get_shader_parameter("reflection_base_roughness")),value),"material roughness follows profile")
				if value == 0.0 or value == 1.0:
					root.get_texture().get_image().save_png("res://temp/tsunami_shadow/"+scene_path.get_file().get_basename()+"_roughness_"+str(int(value))+".png")
	for optics_on in [false,true,false,true]:
		ocean.optics = optics_on
		await frames(8)
		var material: ShaderMaterial = surface.get("_material")
		check(is_equal_approx(float(material.get_shader_parameter("reflection_base_roughness")),1.0),"roughness survives Optics variant")
	for mode in [OceanReflectionProfile.ReflectionMode.PLANAR,OceanReflectionProfile.ReflectionMode.SCREEN_SPACE]:
		profile.reflection_mode = mode
		await frames(10)
		var material: ShaderMaterial = surface.get("_material")
		check(material.shader.code.contains("ROUGHNESS = reflection_base_roughness;"),"roughness assignment survives SSPR/Planar switch")
		check(is_equal_approx(float(material.get_shader_parameter("reflection_base_roughness")),1.0),"roughness survives SSPR/Planar switch")
	# Separate water from the independently authored foam layers at an identical view.
	var original_material: ShaderMaterial = surface.get("_material")
	var no_foam := ShaderMaterial.new()
	no_foam.shader = original_material.shader
	for entry in no_foam.shader.get_shader_uniform_list():
		no_foam.set_shader_parameter(entry.name,original_material.get_shader_parameter(entry.name))
	for key in ["crest_foam_enabled","surface_foam_enabled","interaction_foam_enabled"]:
		no_foam.set_shader_parameter(key,false)
	surface.call("_assign_material_to_surface_geometry",no_foam)
	var water_images: Array[Image] = []
	for roughness in [0.0,1.0]:
		no_foam.set_shader_parameter("reflection_base_roughness",roughness)
		await frames(12)
		var water_image := root.get_texture().get_image()
		water_image.save_png("res://temp/tsunami_shadow/"+scene_path.get_file().get_basename()+"_no_foam_roughness_"+str(int(roughness))+".png")
		water_images.append(water_image)
	check(water_images[0].get_data() != water_images[1].get_data(),"roughness changes rendered water in real production scene")
	surface.call("_assign_material_to_surface_geometry",original_material)
	var result := {"scene":scene_path,"profile":initial_path,"saved_roughness":initial,"failures":failures}
	DirAccess.make_dir_recursive_absolute("res://temp/tsunami_shadow")
	var name := "res://temp/tsunami_shadow/roughness_"+scene_path.get_file().get_basename()+".json"
	var file := FileAccess.open(name,FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t")); file.close()
	print("PRODUCTION_REFLECTION_RESULT ",JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)
