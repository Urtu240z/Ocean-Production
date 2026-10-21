extends SceneTree
## GPU regression: an authored sky ambient color must survive a sun/moon gap.
var output := "res://temp/underwater_ambient/regression"
var failures: Array[String] = []
var results := {}
var environment: Environment
var ocean: Ocean
var profile: OceanUnderwaterMediumProfile
var medium: OceanUnderwaterMedium
var effect: Object
func _initialize() -> void: run.call_deferred()
func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label); push_error("UNDERWATER_TINT_FAIL "+label)
func frames(count := 20) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func capture(label: String) -> Dictionary:
	await frames()
	var image := root.get_texture().get_image()
	image.save_png(output.path_join(label+".png"))
	var rgb := Vector3.ZERO
	var count := 0
	for y in range(80,image.get_height()-80,4):
		for x in range(80,image.get_width()-80,4):
			var color := image.get_pixel(x,y)
			rgb += Vector3(color.r,color.g,color.b)
			count += 1
	rgb /= maxf(count,1)
	return {"rgb":rgb,"bytes":image.get_data(),"luma":rgb.dot(Vector3(0.2126,0.7152,0.0722))}
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(640,400)
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var env := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_sky_contribution = 1.0
	env.environment = environment
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_energy = 0.0
	sun.rotation_degrees.x = 45.0
	world.add_child(sun)
	var moon := DirectionalLight3D.new()
	moon.light_energy = 0.0
	moon.rotation_degrees.x = 45.0
	world.add_child(moon)
	var camera := Camera3D.new()
	camera.position = Vector3(0,-3,0)
	world.add_child(camera)
	camera.current = true
	ocean = load("res://addons/ocean/presets/ocean_production/ocean_production.tscn").instantiate()
	ocean.underwater_medium_profile = ocean.underwater_medium_profile.duplicate()
	ocean.underwater_sun_light = sun
	ocean.underwater_moon_light = moon
	ocean.underwater_environment = env
	world.add_child(ocean)
	await frames(150)
	profile = ocean.underwater_medium_profile
	profile.ambient_debug_mode = 4
	profile.surface_light_strength = 0.35
	medium = ocean.get_node("OceanUnderwaterMedium")
	effect = medium.get_effect_identity()
	for tone in ["neutral","warm","blue"]:
		environment.ambient_light_color = {"neutral":Color.WHITE,"warm":Color(1,0.32,0.08),"blue":Color(0.3,0.5,1)}[tone]
		var shot := await capture(tone)
		results[tone] = {"rgb":str(shot.rgb),"luma":shot.luma}
		check(shot.luma > 0.05,tone+" volume survives zero direct/estimated sky energy")
		check(effect.get("_scene_irradiance") == Vector3.ZERO,"physical irradiance is not fabricated")
		check(not effect.get("_sunray_settings").get("enabled",true),"no rays fabricated below horizon")
		if tone == "warm": check(shot.rgb.x > shot.rgb.z*1.5,"warm ambient reaches medium")
		if tone == "blue": check(shot.rgb.z > shot.rgb.x*1.5,"night blue reaches medium")
		check(medium.get_effect_identity() == effect,"time/color edits retain compositor identity")
	# Low-light exposure is independent of palette and leaves daylight exact.
	environment.ambient_light_color = Color(1,0.32,0.08)
	profile.low_light_volume_strength = 1.0
	var full_night := await capture("low_light_full")
	profile.low_light_volume_strength = 0.20
	var dim_night := await capture("low_light_dim")
	check(dim_night.luma > 0.05 and dim_night.luma < full_night.luma*0.75,"low-light control dims without going black")
	check(dim_night.rgb.x > dim_night.rgb.z*1.5,"low-light dimming preserves warm hue")
	sun.rotation_degrees.x = -45.0
	sun.light_energy = 2.0
	profile.low_light_volume_strength = 1.0
	var full_day := await capture("day_control_one")
	profile.low_light_volume_strength = 0.20
	var retained_day := await capture("day_control_point_two")
	check(full_day.bytes == retained_day.bytes,"low-light control leaves daylight byte exact")
	check(is_equal_approx(effect.get("_scene_volume_gain"),1.0),"full daylight keeps unit exposure")
	results.low_light = {"full_luma":full_night.luma,"dim_luma":dim_night.luma,"day_byte_exact":full_day.bytes == retained_day.bytes}
	sun.light_energy = 0.0
	sun.rotation_degrees.x = 45.0
	# Exercise the optional bubble shader variant using the same ambient helper.
	ocean.underwater_bubbles = true
	await frames(100)
	check(medium.get_effect_identity() == effect,"bubble toggle retains medium compositor")
	ocean.underwater_bubbles = false
	await frames(20)
	# A real directional source still supplies ray direction/energy; only hue follows ambient.
	environment.ambient_light_color = Color(1,0.32,0.08)
	sun.rotation_degrees.x = -45.0
	sun.light_energy = 1.0
	await frames()
	var rays: Dictionary = effect.get("_sunray_settings")
	var ray_color: Color = rays.get("light_color",Color.BLACK)
	check(float(rays.get("light_energy",0.0)) > 0.0,"real sun supplies ray energy")
	check(ray_color.r > ray_color.b*2.0,"rays inherit warm ambient tint")
	sun.light_energy = 0.0
	sun.rotation_degrees.x = 45.0
	profile.scene_lighting_influence = 0.0
	environment.ambient_light_color = Color(1,0.32,0.08)
	var legacy_warm := await capture("legacy_warm")
	environment.ambient_light_color = Color(0.3,0.5,1)
	var legacy_blue := await capture("legacy_blue")
	check(legacy_warm.bytes == legacy_blue.bytes,"zero influence preserves exact authored color")
	profile.scene_lighting_influence = 1.0
	profile.scene_light_reference_energy = 1.0
	var reference_one := await capture("reference_one")
	profile.scene_light_reference_energy = 2.0
	var reference_two := await capture("reference_two")
	check(reference_two.luma < reference_one.luma,"reference energy remains an intensity control")
	profile.surface_light_strength = 0.0
	var zero_strength := await capture("zero_strength")
	check(zero_strength.luma < 0.01,"artistic surface strength can turn volume off")
	profile.surface_light_strength = 0.35
	profile.scattering_color = Color.BLACK
	var zero_color := await capture("zero_color")
	check(zero_color.luma < 0.01,"black authored scattering color can turn volume off")
	profile.scattering_color = Color(0.0024315654,0.09275196,0.13127226)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	var unlit := await capture("no_ambient_no_lights")
	check(unlit.luma < 0.01,"no ambient and no lights still produce darkness")
	results.failures = failures
	print("UNDERWATER_TINT_RESULT ",JSON.stringify(results))
	FileAccess.open(output.path_join("result.json"),FileAccess.WRITE).store_string(JSON.stringify(results,"\t"))
	quit(0 if failures.is_empty() else 1)
