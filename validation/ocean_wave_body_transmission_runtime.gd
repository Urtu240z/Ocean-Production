extends SceneTree
## Forward+ image regression of the production optics block on a fixed wave.
## No source scene, profile or FFT is changed. --output=<absolute directory>
const Surface = preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
var output := ""
var failures: Array[String] = []
var results := {}
var world: Node3D
var camera: Camera3D
var wave: MeshInstance3D
var backdrop: MeshInstance3D
var material: ShaderMaterial
var candidate: Shader
var previous: Shader
var builder: Node3D
var profile := OceanOpticsProfile.new()

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			output = arg.trim_prefix("--output=")
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error("WAVE_BODY: " + label)

func texture_color(value: Color) -> ImageTexture:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	image.fill(value)
	return ImageTexture.create_from_image(image)

func build_wave(flat: bool) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for row in 161:
		var z := -10.0 + row / 16.0
		var y := 0.0 if flat else 1.8 * exp(-pow((z + 4.0) / 2.3, 2))
		for column in 3:
			vertices.append(Vector3(-16 + column * 16, y, z))
			normals.append(Vector3.UP)
	for row in 160:
		for column in 2:
			var i := row * 3 + column
			indices.append_array(PackedInt32Array([i, i + 3, i + 1, i + 1, i + 3, i + 4]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

func bind_profile() -> void:
	for property in profile.get_property_list():
		if (int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
			var key := str(property.name)
			if key in ["shallow_water_color", "deep_water_color", "horizon_water_color", "trough_tint", "crest_tint"]:
				key = "optics_" + key
			material.set_shader_parameter(key, profile.get(property.name))

func capture(name: String, shader: Shader, strength: float, submerged := false, snell_enabled := true) -> Image:
	material.shader = shader
	profile.wave_body_opacity = strength
	bind_profile()
	material.set_shader_parameter("underwater_snell_enabled", submerged and snell_enabled)
	material.set_shader_parameter("underwater_camera_signed_distance_m", -1.0 if submerged else 1.0)
	for frame in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(name + ".png"))
	return image

func difference(a: Image, b: Image, below_water_only := false) -> Dictionary:
	var maximum := 0.0
	var total := 0.0
	var count := 0
	var changed := 0
	for y in range(80, 450):
		for x in range(100, 700):
			if below_water_only:
				# Window capture pixels can differ from the project's stretched viewport.
				var pixel := Vector2(x + 0.5, y + 0.5) * camera.get_viewport().get_visible_rect().size / Vector2(a.get_size())
				var ray := camera.project_ray_normal(pixel)
				var wall_point := camera.global_position + ray * ((-12.0 - camera.global_position.z) / ray.z)
				if wall_point.y >= -0.3:
					continue
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b)))
			maximum = maxf(maximum, d)
			total += d
			count += 1
			if d > 0.005:
				changed += 1
	return {"max": maximum, "mean": total / maxi(count, 1), "pixels": count, "changed": changed}

func run() -> void:
	check(not output.is_empty(), "output directory provided")
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(800, 500)
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.55, 0.7, 0.9)
	world.add_child(environment)
	camera = Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 1, 5)
	camera.look_at(Vector3(0, 1, -12))
	camera.current = true
	builder = Surface.new()
	var source: String = builder.call("_build_shader_source", true, false, false, false)
	# Use unlit output only in this fixture to measure transmission without PBR.
	source = source.replace("diffuse_burley, specular_schlick_ggx;", "unshaded;")
	candidate = Shader.new()
	candidate.code = source
	var start := source.find("\t\t// WAVE_BODY_TRANSMISSION_BEGIN")
	var end := source.find("\t\t// WAVE_BODY_TRANSMISSION_END")
	check(start >= 0 and end > start, "production optics block found")
	previous = Shader.new()
	previous.code = source.substr(0, start) + source.substr(end + "\t\t// WAVE_BODY_TRANSMISSION_END".length())
	material = ShaderMaterial.new()
	material.shader = candidate
	for band in ["long", "mid", "short"]:
		material.set_shader_parameter("displacement_" + band, texture_color(Color(0, 0, 0, 0)))
		material.set_shader_parameter("normal_" + band, texture_color(Color(0, 0.5, 0.8660254, 0)))
	material.set_shader_parameter("crest_foam_enabled", false)
	material.set_shader_parameter("surface_foam_enabled", false)
	# A deliberately clear fixture makes added attenuation measurable; production
	# absorption values are never edited by this test or by the new effect.
	profile.absorption_coeff_rgb = Vector3.ZERO
	profile.refraction_max_offset_px = 0.0
	profile.shallow_scattering_strength = 0.0
	wave = MeshInstance3D.new()
	wave.mesh = build_wave(false)
	wave.material_override = material
	world.add_child(wave)
	backdrop = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(40, 40, 0.1)
	backdrop.mesh = box
	backdrop.position = Vector3(0, 0, -12)
	var backdrop_shader := Shader.new()
	backdrop_shader.code = "shader_type spatial; render_mode unshaded; void fragment(){ float grid=mod(floor(UV.x*32.0)+floor(UV.y*32.0),2.0); ALBEDO=mix(vec3(0.8,0.05,0.03),vec3(0.9),grid); }"
	var backdrop_material := ShaderMaterial.new()
	backdrop_material.shader = backdrop_shader
	backdrop.material_override = backdrop_material
	world.add_child(backdrop)
	var baseline := await capture("old", previous, 0.0)
	var off := await capture("off", candidate, 0.0)
	results.disabled = difference(baseline, off)
	check(results.disabled.max == 0.0, "zero intensity exactly matches old optics")
	var on := await capture("on", candidate, 1.0)
	results.wave = difference(off, on)
	check(results.wave.changed > 2000, "raised wave obscures emerged backdrop")
	var middle := await capture("half", candidate, 0.5)
	results.half = difference(off, middle)
	check(results.half.mean > 0.0 and results.half.mean < results.wave.mean, "intensity provides gradual attenuation")
	profile.wave_body_thickness_m = 20.0
	var thick := await capture("high_threshold", candidate, 1.0)
	results.threshold = difference(off, thick)
	check(results.threshold.mean < results.wave.mean * 0.1, "thickness threshold controls attenuation")
	profile.wave_body_thickness_m = 1.5
	var below_old := await capture("underwater_old", previous, 0.0, true)
	var below_new := await capture("underwater_new", candidate, 1.0, true)
	results.underwater = difference(below_old, below_new)
	check(results.underwater.max == 0.0, "fully underwater Snell unchanged")
	var below_no_snell_old := await capture("underwater_no_snell_old", previous, 0.0, true, false)
	var below_no_snell_new := await capture("underwater_no_snell_new", candidate, 1.0, true, false)
	results.underwater_no_snell = difference(below_no_snell_old, below_no_snell_new)
	check(results.underwater_no_snell.max == 0.0, "underwater remains unchanged with Snell disabled too")
	wave.mesh = build_wave(true)
	var flat_old := await capture("flat_old", previous, 0.0)
	var flat_new := await capture("flat_new", candidate, 1.0)
	results.flat = difference(flat_old, flat_new)
	check(results.flat.max == 0.0, "flat water unchanged")
	wave.mesh = build_wave(false)
	camera.position = Vector3(0, 2.5, 5)
	camera.look_at(Vector3(0, -1.5, -12))
	profile.absorption_coeff_rgb = Vector3(0.35, 0.14, 0.10)
	var seabed_old := await capture("seabed_old", previous, 0.0)
	var seabed_new := await capture("seabed_new", candidate, 1.0)
	results.seabed = difference(seabed_old, seabed_new, true)
	check(results.seabed.pixels > 10000 and results.seabed.max == 0.0, "submerged geometry retains exact original absorption")
	backdrop.hide()
	camera.position = Vector3(0, 1, 5)
	camera.look_at(Vector3(0, 1, -12))
	profile.absorption_coeff_rgb = Vector3.ZERO
	var sky_old := await capture("sky_old", previous, 0.0)
	var sky_new := await capture("sky_new", candidate, 1.0)
	results.sky = difference(sky_old, sky_new)
	check(results.sky.changed > 2000, "sky behind wave is attenuated too")
	results.renderer = RenderingServer.get_current_rendering_method()
	check(results.renderer == "forward_plus", "Forward+ renderer")
	results.new_profile_properties = {}
	var defaults := OceanOpticsProfile.new()
	for key in ["wave_body_opacity", "wave_body_thickness_m", "wave_body_softness_m"]:
		results.new_profile_properties[key] = {"variant_type": str(typeof(defaults.get(key))), "bytes": Marshalls.raw_to_base64(var_to_bytes(defaults.get(key)))}
	results.passed = failures.is_empty()
	results.failures = failures
	var file := FileAccess.open(output.path_join("result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(results, "\t"))
	file.close()
	builder.free()
	world.queue_free()
	for frame in 5:
		await process_frame
	print("WAVE_BODY_RESULT=" + str(results.passed))
	quit(0 if failures.is_empty() else 1)
