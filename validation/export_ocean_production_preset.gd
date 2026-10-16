extends SceneTree
## Export an exact effective Ocean snapshot from the current gameplay scene.
## --mode=export|verify --result=<JSON>. No source scene/resources are modified.
const DEST := "res://addons/ocean/presets/ocean_production/"
var args := {}
var failures: Array[String] = []
var dependencies := {}
var roots := {}
var root_paths := {}
var expected := {}
var node_values := {}
var inactive_resources := {}
var world: Node

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok and not failures.has(label):
		failures.append(label)
		push_error("PRODUCTION_PRESET: " + label)

func canonical(value: Variant) -> Variant:
	if value is String:
		value = dependencies.get(value, root_paths.get(value, value))
		if value.begins_with("res://.godot/imported/"):
			for source_path in dependencies:
				value = value.replace(str(source_path).md5_text(), str(dependencies[source_path]).md5_text())
	if value is Script:
		return {"script": value.resource_path}
	if value is Resource:
		var properties := {}
		for property in value.get_property_list():
			if (int(property.usage) & PROPERTY_USAGE_STORAGE) == 0 or str(property.name) in ["resource_path", "resource_scene_unique_id"]:
				continue
			properties[str(property.name)] = canonical(value.get(property.name))
		return {"class": value.get_class(), "properties": properties}
	if value is Array:
		var values: Array = []
		for item in value:
			values.append(canonical(item))
		return {"array_type": str(value.get_typed_builtin()), "values": values}
	if value is Dictionary:
		var values := {}
		for key in value:
			values[str(key)] = canonical(value[key])
		return values
	return {"variant_type": str(typeof(value)), "bytes": Marshalls.raw_to_base64(var_to_bytes(value))}

func gather(value: Variant) -> void:
	if value is Script:
		check(value.resource_path.begins_with("res://addons/ocean/"), "resource script is inside Ocean: " + value.resource_path)
		return
	if value is Resource:
		var path: String = value.resource_path
		if path.begins_with("res://") and not path.contains("::") and not path.begins_with("res://addons/ocean/") and not root_paths.has(path):
			dependencies[path] = DEST + "assets/" + path.get_file()
		for property in value.get_property_list():
			if (int(property.usage) & PROPERTY_USAGE_STORAGE) != 0 and str(property.name) not in ["resource_path", "resource_scene_unique_id"]:
				gather(value.get(property.name))
	elif value is Array or value is Dictionary:
		for item in (value.values() if value is Dictionary else value):
			gather(item)

func run() -> void:
	if str(args.get("mode", "export")) == "runtime":
		await runtime()
		return
	if str(args.get("mode", "export")) == "verify":
		verify()
		return
	DirAccess.make_dir_recursive_absolute(DEST)
	world = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	root.add_child(world)
	for frame in 600:
		await process_frame
		if bool(world.get("ready_to_drive")):
			break
	check(bool(world.get("ready_to_drive")), "source production scene ready")
	var ocean: Ocean = world.get_node("Production/Ocean")
	for property in ocean.get_property_list():
		var usage := int(property.usage)
		if (usage & PROPERTY_USAGE_STORAGE) == 0 or (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var name := str(property.name)
		var value: Variant = ocean.get(name)
		if value is Resource:
			if name == "coastal_bake" and not ocean.coastal:
				inactive_resources[name] = {"path": value.resource_path,
					"reason": "Disabled in gameplay; this legacy bake belongs to the original island and requires validation/p4_paradise scripts. Preserve separately, do not activate in a different map."}
				continue
			roots[name] = value
			if not value.resource_path.is_empty():
				root_paths[value.resource_path] = DEST + name + ".tres"
		elif not value is Node and not value is Callable and name != "script":
			node_values[name] = value
	# This existing gameplay override is applied through the FFT runtime API.
	# Capture it explicitly rather than the facade's standalone default.
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var visual_profile := str(fft.get("_visual_horizontal_displacement_profile"))
	check(visual_profile in ["PHYSICS_ALIGNED", "FULL_CHOPPY_DEBUG"], "known production visual profile")
	node_values["visual_water_profile"] = 1 if visual_profile == "PHYSICS_ALIGNED" else 0
	var environment: WorldEnvironment = world.get_node("Production/WorldEnvironment")
	roots["lighting_environment"] = environment.environment
	root_paths[environment.environment.resource_path] = DEST + "lighting_environment.tres"
	for name in roots:
		gather(roots[name])
	for name in roots:
		expected[name] = canonical(roots[name])
	var preset := Ocean.new()
	preset.name = &"OceanProduction"
	for name in node_values:
		preset.set(name, node_values[name])
	for name in roots:
		var copy: Resource = roots[name].duplicate(true)
		var path := DEST + str(name) + ".tres"
		check(ResourceSaver.save(copy, path, ResourceSaver.FLAG_CHANGE_PATH) == OK, "save " + str(name))
		copy.take_over_path(path)
		if name != "lighting_environment":
			preset.set(name, copy)
	var packed := PackedScene.new()
	check(packed.pack(preset) == OK, "pack standalone production Ocean")
	check(ResourceSaver.save(packed, DEST + "ocean_production.tscn") == OK, "save standalone production Ocean")
	preset.free()
	var lighting := Node3D.new()
	lighting.name = &"ProductionLightingReference"
	var env := WorldEnvironment.new()
	lighting.add_child(env)
	env.name = &"WorldEnvironment"
	env.owner = lighting
	env.environment = load(DEST + "lighting_environment.tres")
	var sun: Node = world.get_node("Production/Sun").duplicate()
	lighting.add_child(sun)
	sun.owner = lighting
	var light_scene := PackedScene.new()
	check(light_scene.pack(lighting) == OK, "pack optional production lighting")
	check(ResourceSaver.save(light_scene, DEST + "lighting_reference.tscn") == OK, "save optional production lighting")
	lighting.free()
	var values := {}
	var encoded := {}
	for name in node_values:
		values[name] = var_to_str(node_values[name])
		encoded[name] = canonical(node_values[name])
	var file := FileAccess.open(DEST + "source_manifest.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"source_scene": "res://gameplay/jet_ski_ocean.tscn",
		"source_ocean": "Production/Ocean", "effective_runtime_capture": true,
		"resources": expected, "node_values": values, "node_values_exact": encoded,
		"root_path_map": root_paths, "external_assets": dependencies,
		"inactive_resources_preserved_separately": inactive_resources,
		"visual_profile": visual_profile,
		"sun_reference": "Assign your destination sun to Ocean. Optional lighting_reference.tscn contains the original lighting.",
		"failures": failures}, "\t"))
	file.close()
	world.queue_free()
	for frame in 5:
		await process_frame
	finish({"phase": "export", "profiles": roots.keys(), "dependencies": dependencies})

func verify() -> void:
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(DEST + "source_manifest.json"))
	dependencies = manifest.external_assets
	root_paths = manifest.root_path_map
	var verified: Array[String] = []
	var differences := {}
	for name in manifest.resources:
		var path := DEST + str(name) + ".tres"
		var resource := load(path)
		check(resource != null, "load standalone profile " + str(name))
		if resource != null:
			var actual: Variant = canonical(resource)
			check(actual == manifest.resources[name], "exact resource values " + str(name))
			if actual != manifest.resources[name]:
				differences[name] = {"actual": actual, "expected": manifest.resources[name]}
			verified.append(str(name))
	var preset: Ocean = load(DEST + "ocean_production.tscn").instantiate()
	for name in manifest.node_values_exact:
		check(canonical(preset.get(name)) == manifest.node_values_exact[name], "exact Ocean node setting " + str(name))
	check(preset.get_script().resource_path == "res://addons/ocean/ocean.gd", "standalone Ocean script")
	preset.free()
	var lighting: Node = load(DEST + "lighting_reference.tscn").instantiate()
	check(lighting.has_node("Sun") and lighting.has_node("WorldEnvironment"), "optional lighting scene")
	lighting.free()
	finish({"phase": "verify", "profiles_verified": verified, "node_properties_verified": manifest.node_values_exact.size(), "differences": differences})

func runtime() -> void:
	world = Node3D.new()
	root.add_child(world)
	current_scene = world
	var lighting: Node = load(DEST + "lighting_reference.tscn").instantiate()
	world.add_child(lighting)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 5, 12)
	camera.look_at(Vector3(0, 0, -20))
	camera.current = true
	var ocean: Ocean = load(DEST + "ocean_production.tscn").instantiate()
	world.add_child(ocean)
	ocean.underwater_sun_light = lighting.get_node("Sun")
	for frame in 120:
		await process_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	check(fft.is_surface_initialized(), "preset surface initialized")
	check(str(fft.get("_visual_horizontal_displacement_profile")) == "PHYSICS_ALIGNED", "exact production visual profile active")
	check(fft.get("_visual_horizontal_displacement_multipliers") == Vector3(0, 0, 1), "exact production visual multipliers")
	check(ocean.get("_underwater_medium") != null and ocean.get("_caustics_manager") != null, "preset underwater and caustics initialized")
	var water := ocean.get_water_provider()
	check(water.configure(ocean, CpuFftWaterProvider.Backend.CPU_LITE_B, false), "preset CPU Lite configuration")
	water.set_water_race_mode(true)
	var contexts := [water.create_consumer_context(), water.create_consumer_context()]
	var points := PackedVector3Array([Vector3(-0.4, 0, -1), Vector3(0.4, 0, -1), Vector3(-0.4, 0, 1), Vector3(0.4, 0, 1)])
	var start_time := ocean.get_wave_time()
	var valid := 0
	var builds := water.field_update_count
	for tick in 60:
		await physics_frame
		var before := water.field_update_count
		for index in 2:
			water.select_consumer(contexts[index])
			var pose := Transform3D(Basis.IDENTITY, Vector3(index * 20, 0, -tick * 0.1))
			water.prepare_water_queries(pose, points, PackedVector3Array(), 1.0 / 60.0)
			var batch := water.sample_surface_batch(PackedVector3Array([pose.origin]))
			check(batch.size() == 1 and batch[0].valid, "valid preset water samples")
			if batch.size() == 1 and batch[0].valid:
				valid += 1
		check(water.field_update_count - before == 1, "one preset FFT build per tick")
	check(ocean.get_wave_time() > start_time, "preset waves animate")
	check(water.field_update_failures == 0, "no preset FFT failures")
	check(RenderingServer.get_current_rendering_method() == "forward_plus", "Forward+ renderer")
	root.get_texture().get_image().save_png(str(args.result).get_base_dir().path_join("preset_runtime.png"))
	var report := {"phase": "runtime", "valid_samples": valid,
		"field_builds": water.field_update_count - builds, "field_failures": water.field_update_failures,
		"wave_time_delta": ocean.get_wave_time() - start_time, "visual_profile": "PHYSICS_ALIGNED",
		"renderer": RenderingServer.get_current_rendering_method()}
	world.queue_free()
	for frame in 5:
		await process_frame
	finish(report)

func finish(report: Dictionary) -> void:
	report["passed"] = failures.is_empty()
	report["failures"] = failures
	var file := FileAccess.open(str(args.result), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("PRODUCTION_PRESET_RESULT=" + str(report.passed))
	quit(0 if failures.is_empty() else 1)
