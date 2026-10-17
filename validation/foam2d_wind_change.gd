extends SceneTree
var scene: Node
var world: Node
var ocean: Node
var director: Node
var camera: Camera3D
var rows: Array[Dictionary] = []
var observe_only := false
var history_buffers: Array = []
var with_waves := false
var wave_field_id := 0

func _initialize() -> void:
	observe_only = "--observe-only" in OS.get_cmdline_user_args()
	with_waves = "--with-waves" in OS.get_cmdline_user_args()
	run.call_deferred()

func run() -> void:
	seed(24017)
	scene = load("res://validation/foam2d_playground.tscn").instantiate()
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.get_foam_runtime() != null and scene.get_foam_runtime().history != null: break
	director = scene.get_foam_runtime()
	world = scene.get_child(0)
	ocean = world.get_node("Production/Ocean")
	camera = Camera3D.new()
	world.add_child(camera)
	camera.make_current()
	for layer in world.find_children("*","CanvasLayer",true,false): layer.hide()
	for frame in 180: await tick()
	if with_waves:
		director.style.deformation_enabled = true
		for frame in 30: await tick()
		assert(director.wave_field != null and director.wave_field.ready)
		wave_field_id = director.wave_field.get_instance_id()
	var output := "res://temp/foam2d/wind_change_before" if observe_only else "res://temp/foam2d/wind_change"
	if with_waves: output = "res://temp/foam2d/ocean_controls/wind_waves"
	DirAccess.make_dir_recursive_absolute(output)
	var history_id: int = director.history.get_instance_id()
	history_buffers = director.history.get("_textures").duplicate()
	# Non-default user styling must survive each runtime replacement too.
	if not observe_only:
		director.style.roughness = 0.73
		director.style.specular = 0.37
	var original_wind: float = ocean.wind_speed_mps
	await record("initial",output,history_id)
	var winds := [3.0] if observe_only else [3.0,0.0,18.0,0.0]
	for wind in winds:
		var previous: int = ocean.get("_open_ocean").get_instance_id()
		ocean.wind_speed_mps = wind
		for frame in 600:
			await tick()
			var current: Node = ocean.get("_open_ocean")
			if is_instance_valid(current) and current.get_instance_id() != previous and current.get("_surface_initialized"): break
		for frame in 100: await tick()
		await record("wind_%s_%s" % [wind,rows.size()],output,history_id)
	if not observe_only:
		# An actual flat-water case, beyond just reducing wind while swell remains.
		ocean.wave_height_scale = 0.0
		for frame in 240: await tick()
		await record("flat_water",output,history_id)
	var passed := rows.all(func(row: Dictionary): return row.surface_bound and row.history_same and row.history_buffers_same and row.history_ready and row.all_variants and row.max_foam > 0.01 and row.wet > 0.02 and row.wave_binding)
	FileAccess.open(output.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify({"passed":passed,"rows":rows},"\t"))
	print("FOAM2D_WIND_CHANGE passed=",passed," rows=",rows.size()," observe_only=",observe_only)
	# Restore authoring values in this disposable runtime before closing.
	if with_waves: director.style.deformation_enabled = false
	ocean.wind_speed_mps = original_wind
	await world._close_gracefully()

func tick() -> void:
	var ski: Node3D = director.vehicles[0]
	camera.global_position = ski.global_position + Vector3(0,4.5,0.5)
	camera.look_at(ski.global_position)
	await process_frame

func record(label: String, output: String, history_id: int) -> void:
	var current: Node = ocean.get("_open_ocean")
	var bound: bool = is_instance_valid(director.surface) and director.surface == current.get("_surface")
	var variants := false
	var wave_binding := true
	if with_waves:
		var texture: Texture2DRD = director.surface.get("_material").get_shader_parameter("hull_waves_texture")
		wave_binding = director.wave_field != null and director.wave_field.ready and director.wave_field.get_instance_id() == wave_field_id and texture != null and texture.texture_rd_rid == director.wave_field.texture_rid and director.surface.get("_material").get_shader_parameter("hull_waves_enabled") == true
	if bound:
		variants = true
		for material: ShaderMaterial in director.surface.get("_variant_materials").values():
			if material.get_shader_parameter("foam2d_contact_enabled") != true: variants = false
			if material.get_shader_parameter("foam2d_wake_enabled") != true: variants = false
			var expected: Dictionary = director.style.shader_parameters()
			for parameter in expected:
				var actual = material.get_shader_parameter(parameter)
				var target = expected[parameter]
				if actual == null:
					variants = false
				elif target is Color:
					var color: Color = actual if actual is Color else Color(actual.x,actual.y,actual.z,actual.w)
					if not color.is_equal_approx(target): variants = false
				elif target is Vector3:
					if not (actual as Vector3).is_equal_approx(target): variants = false
				elif not is_equal_approx(float(actual),float(target)): variants = false
	if director.history.ready:
		RenderingServer.call_on_render_thread(director.read_field)
		for frame in 4: await tick()
	var wet_max := 0.0
	for contact in director.wet:
		wet_max = maxf(wet_max,maxf(maxf(contact.x,contact.y),maxf(contact.z,contact.w)))
	rows.append({"label":label,"wind":ocean.wind_speed_mps,"wave_height_scale":ocean.wave_height_scale,
		"wave_binding":wave_binding,
		"surface_bound":bound,"all_variants":variants,"history_ready":director.history.ready,
		"history_same":director.history.get_instance_id()==history_id,"updates":director.history.completed_updates,
		"history_buffers_same":director.history.get("_textures")==history_buffers,"surface_bindings":director.surface_bindings,
		"max_foam":director.field_readback.get("max_foam",0.0),"wet":wet_max})
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join(label+".png"))
