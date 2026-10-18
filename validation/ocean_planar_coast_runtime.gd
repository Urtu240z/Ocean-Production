extends SceneTree
## Real imported island, original StandardMaterial3D, rough waves and fast cuts.
## This records the accepted unsupported clip case; it cannot certify arbitrary coasts.
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred(&"run")

func frames(count: int) -> void:
	for index in count: await process_frame
	await RenderingServer.frame_post_draw

func run() -> void:
	var scene: Node3D = load("res://validation/p0_open_ocean.tscn").instantiate()
	var ocean: Ocean = scene.get_node(^"Ocean")
	ocean.coastal = false
	ocean.sea_state_mode = 1
	ocean.significant_wave_height_m = 3.0
	var profile := OceanReflectionProfile.new()
	profile.reflection_mode = OceanReflectionProfile.ReflectionMode.PLANAR
	profile.planar_resolution_scale = 0.35
	profile.kawase_enabled = true
	ocean.reflection_profile = profile
	root.size = Vector2i(1280, 720)
	root.add_child(scene)
	for path in [^"OceanDevPanel", ^"FFTCascadeGate", ^"FreeCamera"]:
		var node := scene.get_node_or_null(path)
		if node != null: node.queue_free()
	var island: Node3D = scene.get_node(^"testisland")
	var mesh: MeshInstance3D = island.find_children("*", "MeshInstance3D", true, false)[0]
	var original := mesh.get_surface_override_material(0)
	island.add_to_group(&"ocean_planar_clip")
	var bounds: AABB = mesh.global_transform * mesh.get_aabb()
	var center := bounds.get_center()
	center.y = ocean.sea_level + 2.0
	var radius := maxf(bounds.size.x, bounds.size.z) * 0.7
	var camera := Camera3D.new()
	scene.add_child(camera)
	camera.far = 6000
	camera.current = true
	DirAccess.make_dir_recursive_absolute("res://temp/planar_coast")
	for shot in 3:
		var angle := float(shot) * 0.65
		camera.global_position = center + Vector3(sin(angle) * radius, maxf(18.0, bounds.size.y * 0.35), cos(angle) * radius)
		camera.look_at(center)
		await frames(28)
		var owner := ocean.get_node(^"OpenOceanFFT/OceanSSPR")
		var planar: Node = owner.get("_planar")
		var state: Dictionary = planar.get_state()
		if state.clip_geometry.unsupported.is_empty(): failures.append("StandardMaterial incompatibility not reported")
		if mesh.get_surface_override_material(0) != original: failures.append("original island material changed")
		if not ocean.get_node(^"OpenOceanFFT/OceanClipmapSurface").get("_reflection_texture_available"): failures.append("reflection unavailable after camera cut")
		root.get_texture().get_image().save_png("res://temp/planar_coast/main_%d.png" % shot)
		var viewport: SubViewport = planar.get("_viewport")
		var image := viewport.get_texture().get_image()
		image.convert(Image.FORMAT_RGBA8)
		image.linear_to_srgb()
		image.save_png("res://temp/planar_coast/reflection_%d.png" % shot)
	print("PLANAR_REAL_COAST_RESULT failures=", failures, " original_material=", original.get_class(), " screenshots=res://temp/planar_coast/")
	scene.queue_free()
	await frames(3)
	quit(0 if failures.is_empty() else 1)
