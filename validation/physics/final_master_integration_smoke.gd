extends SceneTree
## Load the saved gameplay scene. Never selects a worker or geometry backend.
var failures: Array[String] = []

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label)

func run() -> void:
	check(ClassDB.class_exists("OceanQueryNative"),"OceanQueryNative registered")
	check(ClassDB.class_exists("HullBuoyancyGeometryNative"),"native HULL registered")
	if not failures.is_empty(): finish({}); return
	var scene: Node = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	var world: Node = scene.get_node("JetSkiOcean")
	for i in 1800:
		if world.ready_to_drive: break
		await process_frame
	check(world.ready_to_drive,"saved gameplay ready")
	if not world.ready_to_drive: finish({}); return
	var provider: CpuFftWaterProvider = world.water
	var body: RigidBody3D = world.ski
	var physics: Node = body.get("water_physics_system")
	var geometry: RefCounted = physics.hull_buoyancy
	check(Engine.physics_ticks_per_second == 60,"production physics 60 Hz")
	check(ProjectSettings.get_setting("physics/3d/physics_engine") == "Jolt Physics","Jolt selected")
	check(provider.fft_execution_mode == CpuFftWaterProvider.FftExecutionMode.ASYNC_3_WORKERS,"production default Async 3")
	check(physics.buoyancy_mode == JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1,"saved HULL V1")
	var uploads: int = geometry.native_geometry_uploads
	var batches: int = geometry.native_batch_count
	for i in 120: await physics_frame
	await process_frame
	var stats: Dictionary = provider.native.get_dynamic_lite_async_stats()
	check(stats.get("mode",-1) == 1 and stats.get("workers",-1) == 3,"runtime pool has three workers")
	check(stats.get("failures",1) == 0,"no async failures")
	check(provider.field_ready and geometry.is_native_ready(),"native dependencies ready")
	check(geometry.native_geometry_uploads == uploads and uploads == 1,"one geometry upload")
	check(geometry.native_batch_count > batches,"native HULL advances")
	check(body.global_transform.is_finite() and body.linear_velocity.is_finite(),"finite physical vehicle")
	var sample: WaterSample3D = provider.sample_water(body.global_position,WaterSample3D.new())
	check(sample.valid and sample.normal.is_finite() and sample.velocity.is_finite(),"production water sample valid")
	finish({"mode":stats.get("mode"),"workers":stats.get("workers"),"native_batches":geometry.native_batch_count,
		"geometry_uploads":geometry.native_geometry_uploads,"physics_hz":Engine.physics_ticks_per_second,
		"main_scene":ProjectSettings.get_setting("application/run/main_scene"),
		"gameplay_scene":scene.scene_file_path})

func finish(state: Dictionary) -> void:
	state["failures"] = failures
	DirAccess.make_dir_recursive_absolute("res://temp/final_integration")
	var file := FileAccess.open("res://temp/final_integration/production_smoke.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(state,"\t")); file.close()
	print("FINAL_MASTER_SMOKE ",JSON.stringify(state))
	quit(0 if failures.is_empty() else 1)
