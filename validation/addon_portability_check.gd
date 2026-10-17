extends SceneTree
## Copied into a clean test project after unpacking the source archives.
## The test itself is not part of either shipping addon.

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	seed(24017)
	var ocean_only := "--ocean-only" in OS.get_cmdline_user_args()
	var scene_path := "res://addons/ocean/ocean.tscn" if ocean_only else "res://addons/jet_ski/examples/ocean_jet_ski_demo.tscn"
	var scene: Node = load(scene_path).instantiate()
	var ocean: Node = scene if ocean_only else scene.get_node("Ocean")
	var reference := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--reference="): reference=argument.get_slice("=",1)
	if not reference.is_empty(): ocean.set("foam_mode",reference)
	root.add_child(scene)
	for frame in 1500:
		await process_frame
		if str(ocean.get_physics_source_state().get("status","")) == "OK": break
	assert(ocean.get_physics_source_state().status == "OK","Standalone Ocean did not initialize")
	if not ocean_only:
		for frame in 1500:
			await process_frame
			if scene.ready_to_drive and ocean.get_hull_foam_runtime() != null: break
		assert(scene.ready_to_drive,"Standalone demo did not configure its vehicle")
		var runtime: Node = ocean.get_hull_foam_runtime()
		assert(runtime != null and runtime.vehicles.size() == 1)
		for frame in 120: await process_frame
		assert(runtime.history.ready and runtime.history.last_error.is_empty())
		if reference.is_empty(): assert(runtime.wave_field != null and runtime.wave_field.ready)
		var ski: Node = scene.get_node("JetSki")
		assert(ski.has_node("VisualRoot/JetSkiVisual/HullModel/NewJetSki_Hull/hull"),"Hull model was not imported")
		assert(ski.has_node("VisualRoot/JetSkiVisual/HandlePivot/HandleModel/NewJetSki_Handle"),"Handle model was not imported")
		assert(ski.get_node("WaterContactFx").get_child_count() == 0,"Retired contact visuals returned")
		for anchor in ["BowSprayLeft","BowSprayRight","SplashLeft","SplashRight","TailJet"]:
			assert(ski.has_node("BowSprayRoot/"+anchor))
		if reference.is_empty():
			var before_stamps: int = runtime.history.submitted_stamps
			ocean.wind_speed_mps=3.0
			for frame in 120: await process_frame
			assert(runtime.history.ready and not runtime._surface_pending,"Effects failed to rebind after wind change")
			assert(runtime.vehicles.size() == 1 and runtime.history.submitted_stamps>before_stamps,"Vehicle stopped emitting after wind change")
			ocean.set("foam_wake_update_hz",60)
			assert(runtime.history.diagnostic_state().update_hz == 60)
		for frame in 60: await process_frame
		Input.action_press("throttle")
		for frame in 120: await process_frame
		Input.action_release("throttle")
		if reference.is_empty(): assert(runtime.history.submitted_stamps>0 and runtime.history.dropped_stamps == 0)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://portable_effects.png")
	print("ADDON_PORTABILITY_PASS ocean_only=",ocean_only," reference=",reference," development_folders=false")
	root.remove_child(scene)
	scene.queue_free()
	for frame in 20: await process_frame
	quit()
