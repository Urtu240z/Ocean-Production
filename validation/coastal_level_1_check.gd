extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	if not ClassDB.class_exists("Terrain3D"):
		push_error("Terrain3D is not installed.")
		quit(1)
		return
	var terrain = ClassDB.instantiate("Terrain3D")
	terrain.set("vertex_spacing", 5.0)
	terrain.set("data_directory", "res://Level_1_Data")
	root.add_child(terrain)
	await process_frame
	var data = terrain.get("data")
	print("LEVEL_1_TERRAIN regions=", data.get_region_locations().size(), " spawn_height=", data.get_height(Vector3(1625.1366, 0, 1613.5929)))
	var author = load("res://addons/ocean/coastal/baking/coastal_bake_authoring.gd").new()
	author.terrain = terrain
	var ocean = load("res://addons/ocean/ocean.tscn").instantiate()
	ocean.set("sea_level", 2.0)
	author.ocean = ocean
	author.apply_after_bake = false
	author.sea_level_y = 2.0
	author.coast_id = "level_1_complete"
	author.output_root = "res://coastal_bakes"
	var result = author.bake_coastal_asset()
	if result == null or not result.is_valid():
		push_error("LEVEL_1_COASTAL_FAILED")
		quit(1)
		return
	print("LEVEL_1_COASTAL_PASS ", result.describe(), " land=", result.bathymetry.land_water_mask.count(0), " water=", result.bathymetry.land_water_mask.count(1))
	print("LEVEL_1_COMPLETE_BOUNDS ", result.bathymetry.world_origin_xz, " -> ", result.bathymetry.world_max_xz(), " spacing=", result.bathymetry.cell_size_m, " region_size=", terrain.get("region_size"))
	author.free()
	ocean.free()
	terrain.queue_free()
	await process_frame
	quit()
