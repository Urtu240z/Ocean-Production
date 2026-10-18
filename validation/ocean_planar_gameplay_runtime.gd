extends SceneTree
## Real gameplay ramp and wave-distorted coverage at the main view's edges.
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred(&"run")

func frames(count: int) -> void:
	for index in count: await process_frame
	await RenderingServer.frame_post_draw

func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
		push_error("PLANAR_GAMEPLAY_FAIL: " + label)

func coverage_shader(source: String) -> String:
	# Override the FINAL fragment outputs, after foam/optics. In the inherited
	# playground those paths otherwise recolor the diagnostic and count valid
	# foam pixels as missing reflections.
	var start := source.find("{", source.find("void fragment()"))
	var depth := 1
	var index := start + 1
	while index < source.length() and depth > 0:
		if source[index] == "{": depth += 1
		elif source[index] == "}": depth -= 1
		index += 1
	return source.insert(index - 1, "\nALBEDO=vec3(0.0); EMISSION=vec3(uv_inside,0.0,0.0); RADIANCE=vec4(0.0); SPECULAR=0.0; ALPHA=1.0;\n")

func run() -> void:
	var scene: Node = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	var gameplay: Node3D = scene.get_node(^"JetSkiOcean")
	var saved_ramp: MeshInstance3D = gameplay.get_node(^"MeshInstance3D")
	check(saved_ramp.material_override is ShaderMaterial, "actual inherited playground retains ramp clip material before entering tree")
	root.add_child(scene)
	await frames(45)
	var ocean: Ocean = gameplay.get_node(^"Production/Ocean")
	var profile: OceanReflectionProfile = ocean.reflection_profile.duplicate()
	ocean.reflection_profile = profile
	profile.reflection_mode = OceanReflectionProfile.ReflectionMode.PLANAR
	profile.planar_resolution_scale = 0.25
	profile.distortion_strength = 1.0
	profile.edge_fade = 0.0
	gameplay.get("ski").freeze = true
	gameplay.get("camera_rig").process_mode = Node.PROCESS_MODE_DISABLED
	var surface: OceanClipmapSurface = ocean.get_node(^"OpenOceanFFT/OceanClipmapSurface")
	var material: ShaderMaterial = surface.get("_material")
	var shader: Shader = material.shader
	var original := shader.code
	var coverage: Array[Dictionary] = []
	DirAccess.make_dir_recursive_absolute("res://temp/planar_gameplay")
	for overscan in [1.0, 1.5]:
		profile.planar_overscan = overscan
		shader.code = original
		await frames(8)
		root.get_texture().get_image().save_png("res://temp/planar_gameplay/normal_%s.png" % str(overscan))
		# Render the actual projected UV validity instead of inferring coverage
		# from texture existence. Leave the production wave/normal paths active.
		shader.code = coverage_shader(original)
		await frames(6)
		var image := root.get_texture().get_image()
		image.save_png("res://temp/planar_gameplay/coverage_%s.png" % str(overscan))
		var valid := 0
		var total := 0
		for y in range(image.get_height() / 2, image.get_height() - 20):
			for x in range(15, image.get_width() - 15):
				if x > 70 and x < image.get_width() - 70: continue
				total += 1
				var pixel := image.get_pixel(x, y)
				if pixel.r > pixel.g * 2.0 and pixel.r > 0.3: valid += 1
		coverage.append({"overscan": overscan, "valid": valid, "total": total})
		if overscan == 1.5: check(valid >= total * 0.98, "expanded capture covers side strips with waves and distortion")
	shader.code = original
	var planar: Node = ocean.get_node(^"OpenOceanFFT/OceanSSPR").get("_planar")
	var ramp: MeshInstance3D = gameplay.get_node(^"MeshInstance3D")
	var applied: ShaderMaterial = ramp.material_override
	check(ramp.is_in_group(&"ocean_planar_clip"), "saved ramp opts into partial clipping")
	check(planar.get_state().clip_geometry.clipped_surfaces >= 1, "real ramp receives a private clipped material")
	check("_ocean_planar_clip_camera" in applied.shader.code, "capture variant contains camera-only clip")
	var source: Camera3D = root.get_camera_3d()
	var capture: Camera3D = planar.get("_camera")
	var selected: Vector3 = ramp.get_instance_shader_parameter(&"_ocean_planar_clip_camera")
	check(selected.distance_to(capture.global_position) < 0.01 and selected.distance_to(source.global_position) > 0.01, "clip targets mirrored camera, preserves main geometry")
	profile.reflection_mode = OceanReflectionProfile.ReflectionMode.SCREEN_SPACE
	await frames(8)
	check(ramp.material_override != applied and ramp.material_override.shader.resource_path == "res://gameplay/materials/ramp_white.gdshader", "SSR restores original white ramp material")
	var capture_viewport: SubViewport = planar.get("_viewport")
	check(not planar.get_state().active and capture_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "SSR disables planar capture rendering")
	var captures: int = planar.get_state().captures
	await frames(12)
	check(planar.get_state().captures == captures, "SSR never schedules planar captures across subsequent frames")
	print("PLANAR_IDLE_PASS active=", planar.get_state().active, " viewport_update_mode=", capture_viewport.render_target_update_mode, " captures_before=", captures, " captures_after=", planar.get_state().captures, " viewport_retained=", is_instance_valid(capture_viewport))
	print("PLANAR_GAMEPLAY_RESULT coverage=", coverage, " failures=", failures)
	quit(0 if failures.is_empty() else 1)
