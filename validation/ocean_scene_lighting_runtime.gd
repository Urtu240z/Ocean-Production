extends SceneTree
## Run with the real Forward+ renderer and -- --output=<absolute directory>.
## Fixtures alter only their own resources, never authored production profiles.
var output := ""
var failures: Array[String] = []
var report := {"underwater": {}, "spray": {}}
var world: Node3D
var camera: Camera3D
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var environment: WorldEnvironment
var ocean: Ocean

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("SCENE_LIGHTING: " + message)

func settle(frames := 20) -> void:
	for frame in frames: await process_frame
	await RenderingServer.frame_post_draw

func capture(label: String) -> Dictionary:
	await settle()
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(label + ".png"))
	var rgb := Vector3.ZERO
	var maximum := 0.0
	var pixels := 0
	for y in range(40, image.get_height() - 40, 2):
		for x in range(40, image.get_width() - 40, 2):
			var color := image.get_pixel(x, y)
			rgb += Vector3(color.r, color.g, color.b)
			maximum = maxf(maximum, maxf(color.r, maxf(color.g, color.b)))
			pixels += 1
	rgb /= maxf(pixels, 1)
	return {"rgb": [rgb.x, rgb.y, rgb.z], "luma": rgb.dot(Vector3(0.2126, 0.7152, 0.0722)), "maximum": maximum}

func run() -> void:
	check(not output.is_empty(), "output path supplied")
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(800, 500)
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.BLACK
	environment.environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	world.add_child(environment)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-60, -20, 0)
	world.add_child(sun)
	moon = DirectionalLight3D.new()
	moon.rotation_degrees = Vector3(-45, 35, 0)
	moon.light_color = Color(0.55, 0.75, 1.0)
	moon.light_energy = 0.0
	world.add_child(moon)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, -3, 0)
	camera.current = true
	ocean = load("res://addons/ocean/presets/ocean_production/ocean_production.tscn").instantiate()
	ocean.underwater_medium_profile = ocean.underwater_medium_profile.duplicate()
	ocean.underwater_sun_light = sun
	ocean.underwater_moon_light = moon
	ocean.underwater_environment = environment
	world.add_child(ocean)
	await settle(120)
	var medium: OceanUnderwaterMedium = ocean.get_node("OceanUnderwaterMedium")
	var effect := medium.get_effect_identity()
	for mode in ["day", "sunset", "moon", "dark"]:
		sun.light_color = Color(1.0, 0.32, 0.08) if mode == "sunset" else Color.WHITE
		sun.light_energy = 1.0 if mode in ["day", "sunset"] else 0.0
		moon.light_energy = 0.05 if mode == "moon" else 0.0
		var image := await capture("underwater_" + mode)
		var irradiance: Vector3 = effect.get("_scene_irradiance")
		var rays: Dictionary = effect.get("_sunray_settings")
		var caustics: Object = ocean.get_node("OceanCausticsManager").get("_effect") if ocean.has_node("OceanCausticsManager") else null
		image["irradiance"] = [irradiance.x, irradiance.y, irradiance.z]
		image["ray_energy"] = rays.get("light_energy", -1.0)
		image["ray_color"] = str(rays.get("light_color"))
		var surface: Object = ocean.get_node("OpenOceanFFT/OceanClipmapSurface") if ocean.has_node("OpenOceanFFT/OceanClipmapSurface") else ocean.get_node("OpenOceanFFT").get("_surface")
		image["reflection_gain"] = surface.get("_low_light_gain")
		image["caustics_irradiance"] = str(caustics.get("_scene_irradiance")) if caustics != null else "unavailable"
		report.underwater[mode] = image
		if mode == "dark":
			check(irradiance == Vector3.ZERO, "no incident light in complete darkness")
			check(float(rays.get("light_energy")) == 0.0, "no rays without a directional source")
		if mode == "moon": check(float(rays.get("light_energy")) > 0.0, "moon becomes the ray source")
		if mode == "sunset": check(irradiance.x > irradiance.y * 3.0 and irradiance.y > irradiance.z, "warm sunset incident light")
		if mode == "day": check(is_equal_approx(float(image.reflection_gain), 1.0), "daytime reflection intensity unchanged")
		if mode == "dark": check(float(image.reflection_gain) > 1.0, "low-light reflection response applied")
	check(report.underwater.dark.luma < report.underwater.day.luma * 0.15, "underwater darkness visible in rendered output")
	ocean.underwater_medium_profile.scene_lighting_influence = 0.0
	await settle()
	check(float(effect.get("_scene_lighting_influence")) == 0.0, "artistic legacy illumination remains selectable")
	ocean.queue_free()
	await settle(10)
	camera.position = Vector3(3.0, 2.0, 4.0)
	camera.look_at(Vector3(0.4, 0.3, 1.0))
	var sheet := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.subdivide_width = 30
	mesh.subdivide_depth = 20
	sheet.mesh = mesh
	sheet.custom_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	var material := ShaderMaterial.new()
	material.shader = load("res://addons/jet_ski/common/visual/bow_spray/bow_spray.gdshader")
	material.set_shader_parameter("has_image_sequence", true)
	var png: Texture2D = load("res://addons/jet_ski/common/visual/bow_spray/sequences/Splash_1/004.png")
	# Uniform coverage makes the lighting assertion cover the whole curved sheet;
	# production PNGs are checked separately in the complete scene.
	var coverage := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	coverage.fill(Color(0.8, 0.8, 0.8, 1.0))
	png = ImageTexture.create_from_image(coverage)
	for key in ["sequence_texture", "sequence_next_texture", "sequence_previous_texture", "sequence_following_texture"]:
		material.set_shader_parameter(key, png)
	material.set_shader_parameter("speed_factor", 1.0)
	material.set_shader_parameter("contact_factor", 1.0)
	material.set_shader_parameter("side_fade_strength", 0.0)
	material.set_shader_parameter("has_distortion", false)
	sheet.material_override = material
	world.add_child(sheet)
	var local := OmniLight3D.new()
	local.omni_range = 8.0
	local.position = Vector3(1.0, 1.5, 1.0)
	local.light_color = Color(1.0, 0.25, 0.06)
	local.light_energy = 0.0
	world.add_child(local)
	for mode in ["day", "dark", "local"]:
		sun.light_energy = 1.0 if mode == "day" else 0.0
		local.light_energy = 6.0 if mode == "local" else 0.0
		report.spray[mode] = await capture("spray_" + mode)
	check(report.spray.day.maximum > 0.1, "spray visible in daylight")
	check(report.spray.dark.maximum < 0.01, "spray has no emissive output in darkness")
	check(report.spray.local.maximum > 0.1, "spray responds to a local light")
	report["failures"] = failures
	report["passed"] = failures.is_empty()
	FileAccess.open(output.path_join("result.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	world.queue_free()
	await settle(5)
	print("SCENE_LIGHTING_COMPLETE passed=", failures.is_empty())
	quit(0 if failures.is_empty() else 1)
