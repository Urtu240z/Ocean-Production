extends SceneTree
const AreaScene := preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
var failures: Array[String] = []

func _initialize() -> void:
	Engine.max_fps = 120
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error(label)

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 12, 25)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	var light := DirectionalLight3D.new()
	world.add_child(light)
	light.rotation_degrees = Vector3(-45,-30,0)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.3,0.5,0.7)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.5,0.6,0.7)
	world.add_child(environment)
	var ocean: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	ocean.set("coastal", false)
	ocean.set("reflections", false)
	ocean.set("surface_detail", false)
	ocean.set("enable_spindrift", false)
	ocean.set("underwater_bubbles", false)
	ocean.set("underwater_sunrays", false)
	ocean.set("underwater_medium", true)
	ocean.set("sea_level", 0.0)
	var area = AreaScene.instantiate()
	area.ocean = ocean
	area.wave_height_m = 0.0
	world.add_child(area)
	world.add_child(ocean)
	var provider: Node
	for i in 3600:
		await process_frame
		if ocean.get_physics_source_state().get("status", "") == "OK": break
	provider = ocean.get_water_provider()
	check(provider.configure(ocean), "CPU provider configures")
	provider.begin_contacts(Transform3D.IDENTITY, PackedVector3Array([Vector3.ZERO]))
	var flat = provider.sample_water(Vector3.ZERO)
	check(flat.valid and absf(flat.surface_position.y) < 0.0001, "flat harbor physics")
	var surface: Node = ocean.get_node("OpenOceanFFT/OceanClipmapSurface")
	await physics_frame
	await process_frame
	var material: ShaderMaterial = surface.get("_material")
	check(material.get_shader_parameter("wave_area_count") == 1, "surface area uniforms")
	area.wave_height_m = 0.8
	area.wind_direction_degrees = 70.0
	area.wave_speed = 1.3
	for i in 20: await process_frame
	provider.begin_contacts(Transform3D.IDENTITY, PackedVector3Array([Vector3.ZERO]))
	var rough = provider.sample_water(Vector3.ZERO)
	var state = ocean.get_wave_area_runtime()
	state.time_s = provider.current_field_time
	var expected: Vector4 = state.compose(Vector2.ZERO, Vector4.ZERO)
	check(rough.valid and absf(rough.surface_position.y - expected.x) < 0.0001, "local waves reach real CPU contacts")
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://temp/wave_areas")
	root.get_texture().get_image().save_png("res://temp/wave_areas/runtime.png")
	# The underwater sensor must see the same calm surface, not the FFT below it.
	area.wave_height_m = 0.0
	ocean.set_waterline_state_readback_enabled(true)
	camera.position = Vector3(0, -1.0, 0)
	camera.rotation = Vector3.ZERO
	for i in 45: await process_frame
	var waterline: Dictionary = ocean.get_waterline_state()
	check(waterline.get("valid", false) and absf(float(waterline.get("water_surface_y", 999))) < 0.001, "underwater sensor sees local waves")
	print("WAVE_AREA_RUNTIME_RESULT failures=", failures, " waterline=", waterline.get("water_surface_y", 999))
	world.queue_free()
	for i in 5: await process_frame
	quit(0 if failures.is_empty() else 1)
