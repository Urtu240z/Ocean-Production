extends SceneTree
## --vehicles=1|12 --result=<JSON>. Scene has no host setup script.
var args := {}
var failures: Array[String] = []

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok and not failures.has(label):
		failures.append(label)
		push_error(label)

func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	current_scene = world
	var ocean: Ocean = load("res://addons/ocean/ocean.tscn").instantiate()
	ocean.name = &"Ocean"
	world.add_child(ocean)
	ocean.owner = world
	var vehicles: Array[JetSkiController] = []
	var count := int(args.get("vehicles", "1"))
	for index in count:
		var ski: JetSkiController = load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate()
		ski.name = "JetSki%d" % index
		# Equivalent to dragging Ocean into the exported field in the inspector.
		ski.ocean = ocean
		ski.position = Vector3(index * 12, 3, 20)
		ski.collision_layer = 0
		ski.collision_mask = 0
		world.add_child(ski)
		ski.owner = world
		vehicles.append(ski)
	var packed := PackedScene.new()
	check(packed.pack(world) == OK, "scene serialization")
	var restored := packed.instantiate()
	check(restored.get_node("JetSki0").get("ocean") == restored.get_node("Ocean"), "Ocean inspector reference survives serialization")
	restored.free()
	for frame in 600:
		await process_frame
		var all_ready := true
		for ski in vehicles:
			all_ready = all_ready and bool(ski.get_node("OceanConnection").get("ready_to_drive"))
		if all_ready:
			break
	var water := ocean.get_water_provider()
	check(is_instance_valid(water.native), "shared CPU Lite native object created")
	var native_id := water.native.get_instance_id() if is_instance_valid(water.native) else 0
	var contexts := {}
	for ski in vehicles:
		check(bool(ski.get_node("OceanConnection").get("ready_to_drive")) and not ski.freeze, "inspector startup releases vehicle")
		check(ski.get_water_provider() == water, "same Ocean provider for every vehicle")
		var context: RefCounted = ski.get("_water_consumer_context")
		check(context != null and not contexts.has(context.get_instance_id()), "isolated contact contexts")
		if context != null:
			contexts[context.get_instance_id()] = true
	var max_contact := 0.0
	var max_speed := 0.0
	var max_builds := 0
	var last_builds := water.field_update_count
	var last_tick := Engine.get_physics_frames()
	for tick in 240:
		if tick == 60:
			Input.action_press("throttle", 0.85)
		await physics_frame
		var now_tick := Engine.get_physics_frames()
		var builds := water.field_update_count - last_builds
		max_builds = maxi(max_builds, builds)
		check(builds <= now_tick - last_tick, "at most one FFT construction per physics tick")
		last_builds = water.field_update_count
		last_tick = now_tick
		for ski in vehicles:
			check(ski.global_transform.is_finite() and ski.linear_velocity.is_finite(), "finite driving state")
			max_contact = maxf(max_contact, ski.water_contact_ratio)
			max_speed = maxf(max_speed, Vector2(ski.linear_velocity.x, ski.linear_velocity.z).length())
	Input.action_release("throttle")
	check(max_contact > 0.0 and max_speed > 3.0, "actual buoyancy and propulsion")
	check(water.native.get_instance_id() == native_id, "shared native object retained")
	check(water.field_update_failures == 0, "no native field failures")
	check(ocean.get("_editor_preview_node") == null, "no preview object at runtime")
	check(world.get_script() == null, "root has no integration script")
	var report := {"passed": failures.is_empty(), "failures": failures, "vehicles": count,
		"contexts": contexts.size(), "max_contact": max_contact, "max_speed_mps": max_speed,
		"max_builds_per_tick": max_builds, "field_failures": water.field_update_failures,
		"root_script": false, "editor_preview_at_runtime": false}
	var file := FileAccess.open(str(args.result), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("INSPECTOR_OCEAN_RESULT=" + str(report.passed))
	world.queue_free()
	for frame in 5:
		await process_frame
	quit(0 if failures.is_empty() else 1)
