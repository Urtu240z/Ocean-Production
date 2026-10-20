extends SceneTree
## Installation harness, copied beside project.godot AFTER ZIP extraction.
## No validation resource, MCP, production parameter override or backend selector.
var failures: Array[String] = []
var result: Dictionary = {}

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label)

func run() -> void:
	var args := OS.get_cmdline_user_args()
	var extension: Resource = load("res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension")
	check(extension != null,"descriptor loads")
	for name in ["OceanQueryNative","HullBuoyancyGeometryNative"]:
		check(ClassDB.class_exists(name),name+" registered")
	if not failures.is_empty(): finish("native"); return
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	check(native.has_method("get_dynamic_lite_async_stats"),"Async Lite interface present")
	var hull: Object = ClassDB.instantiate("HullBuoyancyGeometryNative")
	check(hull != null,"native HULL instance created")
	native = null
	hull = null
	if "--native-only" in args: finish("native"); return
	check(RenderingServer.get_rendering_device() != null,"RenderingDevice available")
	check(Engine.physics_ticks_per_second == 60,"physics 60 Hz")
	check(Engine.max_fps == 0,"uncapped frame rate")
	var complete := "--complete" in args
	var path := "res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn" if complete else "res://addons/ocean/ocean.tscn"
	var packed: PackedScene = load(path)
	check(packed != null,"addon scene loads")
	if not failures.is_empty(): finish("complete" if complete else "ocean"); return
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	current_scene = scene
	var ocean: Node = scene.get_node("Ocean") if complete else scene
	if not complete:
		var camera := Camera3D.new()
		scene.add_child(camera)
		camera.position = Vector3(0,20,35)
		camera.look_at(Vector3.ZERO)
		camera.current = true
		var sun := DirectionalLight3D.new()
		scene.add_child(sun)
		sun.rotation_degrees = Vector3(-45,-30,0)
		var environment := WorldEnvironment.new()
		environment.environment = Environment.new()
		environment.environment.background_mode = Environment.BG_COLOR
		environment.environment.background_color = Color(0.25,0.4,0.6)
		scene.add_child(environment)
	for i in 1800:
		var ready: bool = bool(scene.get("ready_to_drive")) if complete else str(ocean.get_physics_source_state().get("status","")) == "OK"
		if ready: break
		await process_frame
	var provider: CpuFftWaterProvider = ocean.get_water_provider()
	if not complete:
		check(provider.configure(ocean),"standalone provider configured")
		provider.set_water_race_mode(true)
	for i in 180: await physics_frame
	await process_frame
	check(provider.field_ready,"CPU FFT field ready")
	check(provider.backend == CpuFftWaterProvider.Backend.CPU_LITE_B,"CPU Lite production backend")
	check(provider.lite_resolutions == PackedInt32Array([128,128,128]),"128 cubic resolutions")
	check(provider.lite_interpolation_modes == PackedInt32Array([1,1,1]),"cubic interpolation")
	var stats: Dictionary = provider.native.get_dynamic_lite_async_stats()
	check(stats.get("mode",-1) == 1 and stats.get("workers",-1) == 3,"three real Async workers")
	check(stats.get("failures",1) == 0,"no Async failures")
	var sample := provider.sample_water(Vector3(0,0,60),WaterSample3D.new())
	check(sample.valid and sample.normal.is_finite() and sample.velocity.is_finite(),"finite FFT water query")
	result["async"] = stats
	result["scene"] = path
	if complete:
		var body: RigidBody3D = scene.get_node("JetSki")
		var physics: Node = body.get("water_physics_system")
		var geometry: RefCounted = physics.get("hull_buoyancy")
		check(ProjectSettings.get_setting("physics/3d/physics_engine") == "Jolt Physics","Jolt enabled")
		check(bool(scene.get("ready_to_drive")),"demo startup ready")
		check(physics.get("buoyancy_mode") == 1,"HULL V1 selected")
		check(geometry.is_native_ready() and geometry.native_batch_count > 0,"native HULL integrates")
		check(not body.freeze,"vehicle unfreezes")
		var start: Vector3 = body.global_position
		Input.action_press("throttle")
		var propelled := false
		for i in 180:
			await physics_frame
			propelled = propelled or bool(body.get("drive_system").state.is_propelling)
		Input.action_release("throttle")
		check(propelled,"propulsion exercised")
		check(body.global_position.distance_to(start) > 0.1,"vehicle moves")
		check(root.get_camera_3d() != null,"vehicle camera active")
		body.reset_vehicle()
		for i in 60: await physics_frame
		check(body.global_transform.is_finite() and body.linear_velocity.is_finite(),"finite after respawn")
		check(geometry.is_native_ready() and geometry.native_batch_count > 0,"native HULL after reset")
		result["native_batches"] = geometry.native_batch_count
		result["vehicle_position"] = str(body.global_position)
		result["propulsion"] = propelled
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	check(image != null and not image.is_empty(),"rendered frame available")
	if image != null: image.save_png("res://smoke_"+("complete" if complete else "ocean")+".png")
	finish("complete" if complete else "ocean")

func finish(kind: String) -> void:
	result["kind"] = kind
	result["failures"] = failures
	result["godot"] = Engine.get_version_info().get("string")
	result["driver"] = RenderingServer.get_current_rendering_driver_name()
	result["physics_hz"] = Engine.physics_ticks_per_second
	var file := FileAccess.open("res://smoke_"+kind+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t"))
	file.close()
	print("ADDONS_RELEASE_SMOKE ",JSON.stringify(result))
	quit(0 if failures.is_empty() else 1)
