extends SceneTree
## Rendered matrix + live Resource.changed path used by the Inspector.
## All fixture overrides are in memory; no saved Ocean/physics values are edited.
var scene: Node3D
var ocean: Ocean
var camera: Camera3D
var profile: OceanReflectionProfile
var surface: OceanClipmapSurface
var failures: Array[String] = []
var cases: Array[Dictionary] = []
var output := "res://temp/reflection_fix"

func _initialize() -> void: call_deferred("run")

func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("REFLECTION_FIX_FAIL " + message)

func frames(count: int = 4) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw

func material() -> ShaderMaterial: return surface.get("_material")

func capture(name: String) -> Image:
	var image := root.get_texture().get_image()
	image.save_png(output+"/"+name+".png")
	return image

func camera_angle(kind: String) -> void:
	match kind:
		"top": camera.position = Vector3(0,40,0); camera.look_at(Vector3(0,0,-0.1))
		"oblique": camera.position = Vector3(0,30,25); camera.look_at(Vector3(0,0,-10))
		"grazing": camera.position = Vector3(0,4,45); camera.look_at(Vector3(0,0,-40))

func run() -> void:
	var foam_start := "--foam-on" in OS.get_cmdline_user_args()
	output += "/foam_on" if foam_start else "/foam_off"
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(800,450)
	scene = load("res://validation/p5_reflections.tscn").instantiate()
	ocean = scene.get_node("P0/Ocean")
	ocean.wave_height_scale = 0.0
	ocean.surface_detail = false
	ocean.breakers = false
	ocean.enable_spindrift = false
	ocean.crest_foam = foam_start
	ocean.surface_foam = foam_start
	ocean.optics = false
	profile = OceanReflectionProfile.new()
	profile.temporal_enabled = false
	profile.distortion_strength = 0.0
	profile.edge_fade = 0.0
	profile.radiance_exposure_ev = 0.0
	profile.radiance_saturation = 1.0
	profile.screen_space_weight = 1.0
	profile.planar_roughness_blur = true
	ocean.reflection_profile = profile
	root.add_child(scene)
	camera = Camera3D.new()
	scene.add_child(camera)
	camera.current = true
	camera_angle("oblique")
	await frames(40)
	surface = ocean.get_node("OpenOceanFFT/OceanClipmapSurface")
	var open: Node = ocean.get_node("OpenOceanFFT")
	open.set("_breaker_detector_capture_freeze_override",true)
	await frames(8)
	var changed := [0]
	profile.changed.connect(func(): changed[0] += 1)
	# Existing serialized resource has no new fields; new defaults must be neutral.
	var old_profile: OceanReflectionProfile = load("res://validation/profiles/p5_reflection_profile.tres")
	check(old_profile.fresnel_strength == 1.0 and old_profile.fresnel_power == 5.0 and old_profile.distance_roughness == 0.15,"old preset defaults")
	# Reflections OFF: non-neutral profile edits cannot affect the base shader/image.
	ocean.reflections = false
	await frames(8)
	var off_code := material().shader.code
	var off_before := capture("reflections_off_before")
	profile.base_roughness = 1.0
	profile.distance_roughness = 1.0
	profile.fresnel_strength = 2.0
	profile.fresnel_power = 0.1
	await frames(8)
	var off_after := capture("reflections_off_after")
	check(material().shader.code == off_code,"OFF shader unchanged")
	check(off_before.get_data() == off_after.get_data(),"OFF image bit exact after profile edits")
	# The capture-only freeze is unsuitable for reallocating crest FFT targets.
	# Exercise ordinary foam/Optics lifecycle with the normal solver advancing.
	open.set("_breaker_detector_capture_freeze_override",false)
	ocean.reflections = true
	profile.distance_roughness = 0.15
	profile.fresnel_strength = 1.0
	profile.fresnel_power = 5.0
	for mode in [0,1]:
		profile.reflection_mode = mode
		for kawase in [false,true]:
			profile.kawase_enabled = kawase
			for foam in [foam_start]:
				for optics in [false,true]:
					ocean.optics = optics
					for roughness in [0.0,0.08,0.25,0.5,1.0]:
						profile.base_roughness = roughness
						await frames(4)
						var bound: float = material().get_shader_parameter("reflection_base_roughness")
						check(is_equal_approx(bound,roughness),"live roughness binding")
						check(material().get_shader_parameter("reflection_distance_roughness") == 0.15,"distance independent of base")
						check(material().get_shader_parameter("reflection_fresnel_strength") == 1.0,"strength survives variants")
						var code := material().shader.code
						var assigned := code.find("ROUGHNESS = reflection_base_roughness;")
						check(assigned > 0 and assigned < code.find("ROUGHNESS = mix(ROUGHNESS, crest_foam_residual_roughness"),"base roughness precedes foam")
						if optics: check(assigned > code.find("float tir_filter_roughness"),"Optics/TIR retains its original roughness input")
						check(surface.get("_reflection_texture_available"),"reflection texture available")
						cases.append({"method":mode,"kawase":kawase,"foam":foam,"optics":optics,"roughness":roughness})
						if not foam and not optics: capture("roughness_m%d_k%d_%.2f" % [mode,int(kawase),roughness])
	# Compare the new neutral curve/default roughness against the old fragment.
	# Baseline is captured from the pre-edit Git blob, not a recreated formula.
	ocean.optics = false
	profile.base_roughness = 0.08
	profile.kawase_enabled = false
	await frames(8)
	open.set("_breaker_detector_capture_freeze_override",true)
	var baseline_source := FileAccess.get_file_as_string("res://temp/reflection_fix/baseline_clipmap.gd.txt")
	check(not baseline_source.is_empty(),"pre-edit baseline exists")
	var baseline_fragment := baseline_source.get_slice("const REFLECTIONS_FRAGMENT := '''",1).get_slice("'''",0)
	for mode in [0,1]:
		profile.reflection_mode = mode
		await frames(10)
		var current := material()
		var code := current.shader.code
		var old_shader := Shader.new()
		old_shader.code = code.replace(OceanClipmapSurface.get_reflections_fragment_block(),baseline_fragment).replace("ROUGHNESS = reflection_base_roughness;","")
		var old_material := ShaderMaterial.new()
		old_material.shader = old_shader
		for entry in current.shader.get_shader_uniform_list(): old_material.set_shader_parameter(entry.name,current.get_shader_parameter(entry.name))
		var neutral := capture("neutral_new_m%d" % mode)
		surface.call("_assign_material_to_surface_geometry",old_material)
		await frames(8)
		var original := capture("neutral_original_m%d" % mode)
		check(neutral.get_data() == original.get_data(),"neutral default exact legacy image method %d" % mode)
		surface.call("_assign_material_to_surface_geometry",current)
	# Non-vacuous GPU check: expose the actual post-foam ROUGHNESS as emission.
	# A forced full crest must retain its own 0.77, regardless of the water base.
	var original_material := material()
	var diagnostic_code := original_material.shader.code.replace("ALBEDO = mix(ALBEDO, crest_foam_residual_color, crest);", "crest = 1.0; ALBEDO = mix(ALBEDO, crest_foam_residual_color, crest);")
	var last_brace := diagnostic_code.rfind("\n}")
	diagnostic_code = diagnostic_code.insert(last_brace,"\n ALBEDO = vec3(0.0); EMISSION = vec3(ROUGHNESS); SPECULAR = 0.0; RADIANCE = vec4(0.0,0.0,0.0,1.0);")
	var diagnostic := ShaderMaterial.new()
	diagnostic.shader = Shader.new()
	diagnostic.shader.code = diagnostic_code
	for entry in original_material.shader.get_shader_uniform_list(): diagnostic.set_shader_parameter(entry.name,original_material.get_shader_parameter(entry.name))
	diagnostic.set_shader_parameter("crest_foam_enabled",true)
	diagnostic.set_shader_parameter("crest_foam_residual_roughness",0.77)
	diagnostic.set_shader_parameter("surface_foam_enabled",false)
	diagnostic.set_shader_parameter("interaction_foam_enabled",false)
	surface.call("_assign_material_to_surface_geometry",diagnostic)
	diagnostic.set_shader_parameter("reflection_base_roughness",0.0)
	await frames(8)
	var foam_zero := capture("foam_full_base_0")
	diagnostic.set_shader_parameter("reflection_base_roughness",1.0)
	await frames(8)
	var foam_one := capture("foam_full_base_1")
	check(foam_zero.get_data() == foam_one.get_data(),"full foam roughness unchanged by base (GPU)")
	diagnostic.set_shader_parameter("crest_foam_enabled",false)
	diagnostic.set_shader_parameter("reflection_base_roughness",0.0)
	await frames(8)
	var base_zero := capture("material_roughness_0")
	diagnostic.set_shader_parameter("reflection_base_roughness",1.0)
	await frames(8)
	var base_one := capture("material_roughness_1")
	check(base_zero.get_data() != base_one.get_data(),"base changes actual material roughness (GPU)")
	surface.call("_assign_material_to_surface_geometry",original_material)
	open.set("_breaker_detector_capture_freeze_override",false)
	# Angular sweeps share the PBR normal/view and the same captured radiance path.
	for mode in [0,1]:
		profile.reflection_mode = mode
		for kawase in [false,true]:
			profile.kawase_enabled = kawase
			for angle in ["top","oblique","grazing"]:
				camera_angle(angle)
				for power in [2.0,5.0,8.0]:
					profile.fresnel_power = power
					for strength in [0.0,1.0,2.0]:
						profile.fresnel_strength = strength
						await frames(4)
						check(material().get_shader_parameter("reflection_fresnel_power") == power,"live power binding")
						check(material().get_shader_parameter("reflection_fresnel_strength") == strength,"live strength binding")
						if strength == 1.0: capture("fresnel_m%d_k%d_%s_p%d" % [mode,int(kawase),angle,int(power)])
	check(changed[0] > 100,"Inspector Resource.changed path exercised")
	var file := FileAccess.open(output+"/results.json",FileAccess.WRITE)
	var result := {"failures":failures,"foam_initial_state":foam_start,"roughness_cases":cases,"angular_cases":108,"changed_signals":changed[0],"driver":RenderingServer.get_current_rendering_driver_name()}
	file.store_string(JSON.stringify(result,"\t")); file.close()
	print("REFLECTION_FIX_RESULT ",JSON.stringify({"failures":failures,"roughness_cases":cases.size(),"angular_cases":108,"changed_signals":changed[0]}))
	quit(0 if failures.is_empty() else 1)
