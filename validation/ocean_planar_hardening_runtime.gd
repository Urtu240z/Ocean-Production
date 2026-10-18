extends SceneTree
var scene: Node3D
var ocean: Ocean
var surface: OceanClipmapSurface
var owner: Node
var planar: Node
var source: Camera3D
var profile: OceanReflectionProfile
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred(&"run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
		push_error("PLANAR_HARDENING_FAIL: " + label)

func frames(count: int) -> void:
	for frame in count: await process_frame
	await RenderingServer.frame_post_draw

func box(position: Vector3, size: Vector3, color: Color, clipped := false) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.mesh.size = size
	mesh.position = position
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode unshaded; uniform vec4 tint : source_color; void fragment() { ALBEDO = tint.rgb; }"
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"tint", color)
	mesh.material_override = material
	if clipped: mesh.add_to_group(&"ocean_planar_clip")
	scene.add_child(mesh)
	return mesh

func red_pixels(image: Image) -> int:
	var result := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.r > 0.5 and pixel.g < pixel.r * 0.15 and pixel.b < pixel.r * 0.15: result += 1
	return result

func run() -> void:
	scene = load("res://validation/p5_reflections.tscn").instantiate()
	ocean = scene.get_node(^"P0/Ocean")
	ocean.coastal = false
	ocean.sea_level = 7.0
	profile = OceanReflectionProfile.new()
	ocean.reflection_profile = profile
	root.add_child(scene)
	var sun: DirectionalLight3D = scene.get_node(^"P0/Sun")
	sun.light_cull_mask = 1
	await frames(5)
	owner = ocean.get_node(^"OpenOceanFFT/OceanSSPR")
	check(owner.get("_planar") == null, "SSR does not instantiate planar")
	profile.reflection_mode = OceanReflectionProfile.ReflectionMode.PLANAR
	source = Camera3D.new()
	scene.add_child(source)
	source.position = Vector3(0, 17, 30)
	source.rotation_degrees.x = -60
	source.cull_mask = 1
	source.current = true
	scene.get_node(^"ReflectionObjects").visible = false
	var marker := box(Vector3(0, 22, 0), Vector3(6, 6, 6), Color(1, 0, 0))
	var occluder := box(Vector3(0, 4, 25), Vector3(10, 8, 1), Color(0, 1, 0))
	var original_material := occluder.material_override
	var submerged := box(Vector3(20, 2, 15), Vector3(2, 2, 2), Color(0, 0, 1))
	submerged.layers = 2
	var spectator := Camera3D.new()
	scene.add_child(spectator)
	spectator.cull_mask = 1
	var selective := Camera3D.new()
	scene.add_child(selective)
	selective.cull_mask = 2
	await frames(14)
	planar = owner.get("_planar")
	var viewport: SubViewport = planar.get("_viewport")
	var capture: Camera3D = planar.get("_camera")
	check(is_equal_approx(capture.global_position.y, -3.0), "nonzero sea level rendered camera")
	var before := red_pixels(viewport.get_texture().get_image())
	occluder.add_to_group(&"ocean_planar_clip")
	profile.emit_changed()
	await frames(12)
	var after_image := viewport.get_texture().get_image()
	var after := red_pixels(after_image)
	check(before == 0 and after > 20, "partial coastal clip reveals previously occluded offscreen marker")
	check(occluder.material_override != original_material, "clip uses a private material variant")
	check(planar.get_state().clip_geometry.clipped_surfaces > 0, "clipped surfaces reported")
	check(planar.get_state().excluded_objects > 0, "wholly submerged geometry omitted")
	var water: VisualInstance3D = surface_instance()
	check((spectator.cull_mask & water.layers) != 0, "second camera sees water with original layer20 disabled")
	check((sun.light_cull_mask & water.layers) != 0, "selective lighting still reaches water")
	check((selective.cull_mask & water.layers) == 0, "selective camera still excludes originally invisible water")
	check((selective.cull_mask & submerged.layers) != 0, "selective camera retains excluded scene object")
	DirAccess.make_dir_recursive_absolute("res://temp/planar_validation")
	after_image.convert(Image.FORMAT_RGBA8)
	after_image.save_png("res://temp/planar_validation/coastal_clip_level_7.png")
	var conflict := box(Vector3(30, 20, 0), Vector3(1, 1, 1), Color.WHITE)
	conflict.layers = 1 << 19
	profile.planar_water_layer = 20
	await frames(4)
	check(planar.get_state().status == &"LAYER_CONFLICT", "explicit layer collision suspends capture")
	check(conflict.layers == 1 << 19 and spectator.cull_mask == 1, "collision preserves existing layer and restores cameras")
	check(occluder.material_override == original_material, "suspend restores clipped material")
	profile.planar_water_layer = 0
	await frames(7)
	check((planar.get_state().managed_layer_mask & (1 << 19)) == 0, "Auto avoids occupied layer20")
	surface = ocean.get_node(^"OpenOceanFFT/OceanClipmapSurface")
	surface.visible = false
	await frames(3)
	var count: int = planar.get_state().captures
	await frames(4)
	check(planar.get_state().captures == count and planar.get_state().status == &"WATER_NOT_VISIBLE", "invisible water stops capture")
	surface.visible = true
	source.position.y = 500
	source.rotation_degrees.x = 80
	await frames(4)
	check(planar.get_state().status == &"WATER_NOT_VISIBLE", "off-frustum water stops capture")
	source.position.y = 17
	source.rotation_degrees.x = -60
	await frames(6)
	profile.planar_update_fps = 1.0
	await frames(4)
	count = planar.get_state().captures
	var matrix: Projection = planar.get("_view_projection")
	source.position.x += 0.25
	await frames(3)
	check(planar.get_state().captures == count and planar.get("_view_projection") == matrix, "throttled frame keeps capture matrix")
	profile.planar_update_fps = 0.0
	var switched := Camera3D.new()
	scene.add_child(switched)
	switched.transform = source.transform
	switched.position.x = 35
	switched.current = true
	await frames(8)
	check(planar.get("_last_source") == switched and is_equal_approx(capture.global_position.x, 35.0), "camera replacement refreshes capture")
	check(bool(surface.get("_reflection_texture_available")), "replacement waits for fresh texture then resumes")
	# Production wave/detail/foam paths remain ON. Exercise moving camera and
	# opt-in spatial roughness blend, rather than flattening the ocean fixture.
	profile.kawase_enabled = true
	profile.planar_roughness_blur = true
	profile.distortion_strength = 1.0
	for index in 30:
		switched.position += Vector3(0.2, 0, -0.4)
		switched.rotation_degrees.y += 0.5
		await process_frame
	await frames(4)
	check(ocean.wave_height_scale > 0.0 and ocean.crest_foam and ocean.surface_foam, "production waves and foam remain enabled")
	check(bool(surface.get("_reflection_texture_available")), "moving wavy ocean retains reflection")
	check(surface.get("_material").get_shader_parameter(&"reflection_planar_roughness_blur"), "spatial roughness filtering bound")
	ocean.reflections = false
	await frames(3)
	check(spectator.cull_mask == 1 and selective.cull_mask == 2, "all camera masks restored")
	check(sun.light_cull_mask == 1, "light mask restored")
	check(occluder.material_override == original_material, "original material restored on disable")
	print("PLANAR_HARDENING_RESULT before=", before, " after=", after, " failures=", failures)
	scene.queue_free()
	await frames(3)
	quit(0 if failures.is_empty() else 1)

func surface_instance() -> VisualInstance3D:
	return ocean.get_node(^"OpenOceanFFT/OceanClipmapSurface").find_children("*", "VisualInstance3D", true, false)[0]
