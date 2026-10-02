extends "res://validation/physics/phys_weather_velocity_runner.gd"
## Frozen time/camera comparison. Only the coverage factor is removed for BEFORE.
## Viewport images are visual validation; no ocean texture is downloaded.
func _run() -> void:
	root.size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED); Engine.max_fps = 0
	var camera := Camera3D.new(); root.add_child(camera); camera.current = true
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL; camera.size = 90.0; camera.far = 2000.0
	var environment := WorldEnvironment.new(); environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.45, 0.6, 0.75)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE; environment.environment.ambient_light_energy = 0.7
	root.add_child(environment)
	var sun := DirectionalLight3D.new(); sun.rotation_degrees = Vector3(-60, -30, 0); root.add_child(sun)
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	ocean.set("wave_speed_multiplier", 0.0); ocean.set("_wave_time", 2.25)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 40: await RenderingServer.frame_post_draw
	var bake: Dictionary = ocean.get_node("OpenOceanFFT").call("get_phys3_coastal_snapshot")
	var materials: Array = []; var seen := {}
	for mesh in ocean.find_children("*", "MeshInstance3D", true, false):
		var material: ShaderMaterial = mesh.material_override as ShaderMaterial
		if material == null or seen.has(material.get_instance_id()): continue
		seen[material.get_instance_id()] = true
		var code: String = material.shader.code
		if not code.contains("coastal_coverage_edge_weight(coast_uv"): continue
		var previous := Shader.new()
		previous.code = code.replace("* coastal_coverage_edge_weight(coast_uv, textureSize(coastal_field, 0))", "")
		var parameters := {}
		for uniform in material.shader.get_shader_uniform_list(): parameters[uniform.name] = material.get_shader_parameter(uniform.name)
		materials.append({"material": material, "before": previous, "after": material.shader, "parameters": parameters})
	if materials.is_empty(): _fail("visual Coastal materials not found"); return
	var viewport := root.get_viewport_rid()
	var gpu_supported := RenderingServer.has_method("viewport_set_measure_render_time")
	if gpu_supported: RenderingServer.call("viewport_set_measure_render_time", viewport, true)
	var origin: Vector2 = bake.field_origin; var extent: Vector2 = bake.field_extent
	var points := [origin + Vector2(0, extent.y * 0.46), origin + Vector2(extent.x, extent.y * 0.46),
		origin + Vector2(extent.x * 0.46, 0), origin + Vector2(extent.x * 0.46, extent.y)]
	var report := {"wave_time": ocean.call("get_wave_time"), "resolution": [1280, 720], "camera_size": 90,
		"vsync": "disabled", "fft": "all three full bands", "coastal": true, "breakers": false,
		"gpu_measurement": "total viewport, not isolated Coastal pass", "edges": {}}
	report.material_source = {"coastal": materials[0].parameters.get("coastal_enabled"),
		"domain": materials[0].parameters.get("domain_long_m"), "displacement": str(materials[0].parameters.get("displacement_long"))}
	var wireframe := OS.get_cmdline_user_args().has("--wireframe")
	var suffix := "_wireframe" if wireframe else ""
	if wireframe: root.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME
	report.wireframe = wireframe
	for edge in 4:
		var target := Vector3(points[edge].x, 0, points[edge].y)
		camera.position = target + Vector3(-25, 55, 35); camera.look_at(target)
		var rows := {}
		for mode in ["before", "after", "before", "after"]:
			for row in materials:
				row.material.shader = row[mode]
				for parameter in row.parameters: row.material.set_shader_parameter(parameter, row.parameters[parameter])
			for _i in 60: await RenderingServer.frame_post_draw
			var samples: Array = []
			for _i in 180:
				await RenderingServer.frame_post_draw
				if gpu_supported: samples.append(RenderingServer.call("viewport_get_measured_render_time_gpu", viewport))
			if not rows.has(mode):
				root.get_texture().get_image().save_png("res://.godot/coverage_visual%s_%s_%s.png" % [suffix, ["left", "right", "top", "bottom"][edge], mode])
				rows[mode] = []
			rows[mode].append(_metrics(samples))
		report.edges[["left", "right", "top", "bottom"][edge]] = rows
	var file := FileAccess.open("res://.godot/phys_coastal_coverage_visual%s.json" % suffix, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("COVERAGE_VISUAL_COMPLETE"); quit(0)
