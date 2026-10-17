extends SceneTree
## Inspect material samplers at the invalidation boundary, not just after rebuild.
var rows: Array[Dictionary] = []
var scene: Node
var ocean: Ocean
var director: Node
var observe_only := false
var failures: Array[String] = []

func _initialize() -> void:
	observe_only = "--observe-only" in OS.get_cmdline_user_args()
	run.call_deferred()

func run() -> void:
	scene = load("res://validation/foam2d_playground.tscn").instantiate()
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.find_child("AjustesSalpicaduras",true,false) != null: break
	var world: Node = scene.get_node("JetSkiOcean")
	ocean = world.get_node("Production/Ocean")
	director = scene.get_foam_runtime()
	var recorder: Node = world.water.get("_perf1_capture")
	if is_instance_valid(recorder): recorder.queue_free()
	await process_frame
	world.water.perf2_stage_measurements_enabled = false
	world.water.native.perf1_set_enabled(false)
	ocean.wind_speed_mps = 35.0
	for frame in 120: await process_frame
	for frame in 900:
		if not director._surface_pending and is_instance_valid(director.surface): break
		await process_frame
	ocean.set("foam_deformation_enabled",true)
	for frame in 90: await process_frame
	var history_id: int = director.history.get_instance_id()
	var wave_id: int = director.wave_field.get_instance_id()
	var history_textures: Array = director.history.get("_textures").duplicate()
	inspect_materials("initial")
	var winds := [3.0] if observe_only else [3.0,35.0,3.0,35.0,3.0,0.0]
	for index in winds.size():
		var wind: float = winds[index]
		var old_fft: Node = ocean.get("_open_ocean")
		# Alternate update phases to expose render/main thread ordering differences.
		if index%2 == 1: await RenderingServer.frame_pre_draw
		ocean.wind_speed_mps = wind
		inspect_materials("invalidated_%s" % wind)
		for frame in 8:
			await process_frame
			if is_instance_valid(director.surface): inspect_materials("pending_%s_%s" % [wind,frame])
		for frame in 900:
			await process_frame
			if is_instance_valid(director.fft) and director.fft != old_fft and not director._surface_pending: break
		for frame in 6: await process_frame
		inspect_materials("rebound_%s" % wind)
		if director.history.get_instance_id() != history_id or director.history.get("_textures") != history_textures:
			failures.append("Foam history was replaced")
		if director.wave_field.get_instance_id() != wave_id: failures.append("Wave field was replaced during wind edit")
	# Disabled samplers still need a valid texture for the material's GPU layout.
	for cycle in (1 if observe_only else 3):
		ocean.set("foam_deformation_enabled",false)
		inspect_materials("wave_off_%s" % cycle)
		for frame in 8: await process_frame
		ocean.set("foam_deformation_enabled",true)
		inspect_materials("wave_starting_%s" % cycle)
		for frame in 15: await process_frame
		inspect_materials("wave_ready_%s" % cycle)
		if director.wave_field == null or not director.wave_field.ready: failures.append("Wave field did not recover")
	# Actually draw each prepared material, including the cached fallback paths.
	var surface: Node = director.surface
	var original_key: String = surface.get("_active_shader_variant_key")
	for key in surface.get("_variant_materials").keys():
		var material: ShaderMaterial = surface.get("_variant_materials")[key]
		surface.set("_material",material)
		surface._hydrate_material(material)
		surface._assign_material_to_surface_geometry(material)
		surface.set("_active_shader_variant_key",key)
		inspect_materials("variant_start_%s" % key)
		for frame in 8: await process_frame
		inspect_materials("variant_drawn_%s" % key)
	var restored: ShaderMaterial = surface.get("_variant_materials")[original_key]
	surface.set("_material",restored)
	surface._hydrate_material(restored)
	surface._assign_material_to_surface_geometry(restored)
	surface.set("_active_shader_variant_key",original_key)
	var passed := failures.is_empty() and rows.all(func(row: Dictionary): return row.invalid.is_empty())
	var output := "res://temp/foam2d/binding_fix_before" if observe_only else "res://temp/foam2d/binding_fix"
	DirAccess.make_dir_recursive_absolute(output)
	FileAccess.open(output.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify({"passed":passed,"rows":rows,"failures":failures,"observe_only":observe_only},"\t"))
	print("FOAM2D_REBIND_BINDINGS passed=",passed," samples=",rows.size()," failures=",failures)
	await world._close_gracefully()
	if not passed and not observe_only: quit(1)

func inspect_materials(stage: String) -> void:
	var invalid: Array[String] = []
	var checked := 0
	var bindings := []
	for key in director.surface.get("_variant_materials"):
		var material: ShaderMaterial = director.surface.get("_variant_materials")[key]
		for parameter in ["interaction_foam_texture","hull_waves_texture","hull_waves_previous_texture"]:
			var texture: Texture2D = material.get_shader_parameter(parameter)
			if texture == null: invalid.append("%s:%s:unset" % [key,parameter])
			elif texture.get_width() <= 0 or texture.get_height() <= 0: invalid.append("%s:%s:unpublished" % [key,parameter])
			if texture is Texture2DRD and not texture.texture_rd_rid.is_valid(): invalid.append("%s:%s" % [key,parameter])
			bindings.append({"variant":key,"parameter":parameter,"type":texture.get_class() if texture != null else "null","width":texture.get_width() if texture != null else 0})
			checked += 1
	rows.append({"stage":stage,"invalid":invalid,"checked":checked,"pending":director._surface_pending,"bindings":bindings,"wind":ocean.wind_speed_mps})
