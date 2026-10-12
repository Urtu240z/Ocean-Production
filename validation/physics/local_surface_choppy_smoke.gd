extends SceneTree
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
var failures: Array[String] = []
var scene: Node
var provider: Node
var ski: JetSkiController
var ocean: Node


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	if not ok:
		failures.append(message)
		push_error("LOCAL_CHOPPY_SMOKE: " + message)


func _wait_sync() -> void:
	for frame in 240:
		await process_frame
		if provider.call("get_water_sync_status").status == "OK": return
	check(false, "weather reconstruction becomes available")


func _key_l() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_L
	event.pressed = true
	for child in ski.get_children():
		if child.get_script() == load("res://gameplay/vehicles/common/visual/jet_ski_buoyancy_hud.gd"):
			child.call("_unhandled_key_input", event)


func _phase(label: String, ticks: int) -> void:
	var imports := int(provider.get("spectrum_sync_generation"))
	var before_builds := int(provider.get("local_surface_build_count"))
	var before_misses := int(provider.get("local_surface_missed_queries"))
	var before_seams := int(provider.get("local_surface_branch_jump_count"))
	var max_height_step := 0.0
	var last_contact_query_us := 0
	var previous: WaterSample3D
	for tick in ticks:
		await physics_frame
		await process_frame
		last_contact_query_us = int(provider.get("local_surface_contact_query_us"))
		var position := ski.global_position
		var sample: WaterSample3D = provider.call("sample_water", position)
		check(sample.valid and sample.surface_position.is_finite() and sample.velocity.is_finite(), label + ": finite surface")
		check(sample.normal.is_finite() and absf(sample.normal.length() - 1.0) < 0.0001,
			label + ": unit geometric normal")
		check(absf(sample.signed_depth - (sample.surface_position.y - position.y)) < 0.0001,
			label + ": world depth agrees")
		if previous != null: max_height_step = maxf(max_height_step, absf(sample.surface_position.y - previous.surface_position.y))
		previous = sample
		check(ski.global_transform.is_finite() and ski.linear_velocity.is_finite() and ski.angular_velocity.is_finite(),
			label + ": finite hull motion")
		var patch: Dictionary = provider.get("local_surface_patch_summary")
		check(not patch.is_empty() and int(patch.vertex_count) <= 65 * 65, label + ": bounded local mesh")
		check(absf(float(patch.get("field_time", -1.0)) - float(provider.get("current_field_time"))) < 0.000001,
			label + ": patch uses current CPU Lite time")
		check(int(patch.get("debug_wire_vertex_count", -1)) == 0, label + ": gameplay creates no debug geometry")
		if label == "FLAT":
			check(absf(sample.surface_position.y - float(provider.get("sea_level"))) < 0.00001,
				"flat water remains at sea level")
			check(sample.normal.distance_to(Vector3.UP) < 0.00001 and sample.velocity.length() < 0.00001,
				"flat water has upright normal and zero velocity")
	check(int(provider.get("spectrum_sync_generation")) == imports, label + ": no extra FFT/spectrum import")
	print("LOCAL_CHOPPY_PHASE: %s | ticks=%d builds=%d misses=%d branch_seams=%d height_step=%.4f | build/query %.3f/%.3f ms" % [
		label, ticks, int(provider.get("local_surface_build_count")) - before_builds,
		int(provider.get("local_surface_missed_queries")) - before_misses,
		int(provider.get("local_surface_branch_jump_count")) - before_seams, max_height_step,
		float(provider.get("local_surface_last_build_us")) / 1000.0, float(last_contact_query_us) / 1000.0])


func _compare_surface() -> void:
	var points := PackedVector3Array()
	for z in [-1.0, 0.0, 1.0]:
		for x in [-1.0, 0.0, 1.0]: points.append(ski.global_position + Vector3(x, 0, z))
	var local: Array = provider.call("sample_water_batch", points)
	var direct: Array = provider.call("_sample_direct_water_batch", points)
	var native: Object = provider.get("native")
	var contract: Dictionary = provider.call("get_surface_query_contract")
	var camera: Vector2 = contract.camera_world_xz
	var center: Vector3 = provider.get("_local_patch_center")
	var modes: PackedInt32Array = provider.get("lite_interpolation_modes")
	var multipliers: Vector3 = provider.call("_get_local_horizontal_multipliers")
	var summary: Dictionary = native.call("build_dynamic_lite_local_surface", center.x, center.z,
		camera.x, camera.y, 4.0, 0.15, float(provider.get("sea_level")),
		float(contract.clipmap_geometry_scale), float(contract.ocean_surface_scale),
		float(contract.horizontal_displacement_bound_world_m), contract.fade_ranges, modes, multipliers, 129, false)
	var reference: PackedFloat64Array = native.call("sample_dynamic_lite_local_surface_batch", points)
	check(not summary.is_empty() and reference.size() == 1 + points.size() * 7, "same-time geometric reference available")
	var local_error := 0.0
	var direct_error := 0.0
	if reference.size() == 1 + points.size() * 7:
		for index in points.size():
			check(reference[1 + index * 7] > 0.5 and local[index].valid and direct[index].valid, "comparison samples valid")
			local_error += absf(local[index].surface_position.y - reference[2 + index * 7])
			direct_error += absf(direct[index].surface_position.y - reference[2 + index * 7])
		local_error /= points.size()
		direct_error /= points.size()
		check(local_error <= direct_error + 0.02, "local geometry agrees with refined reference within discretization tolerance")
	# Restore the actual gameplay mesh synchronously, before any physics tick.
	native.call("build_dynamic_lite_local_surface", center.x, center.z, camera.x, camera.y,
		provider.get("local_surface_useful_radius_m"), provider.get("local_surface_spacing_m"),
		provider.get("sea_level"), contract.clipmap_geometry_scale, contract.ocean_surface_scale,
		contract.horizontal_displacement_bound_world_m, contract.fade_ranges, modes, multipliers,
		provider.get("local_surface_max_vertices_per_side"), false)
	print("LOCAL_CHOPPY_GEOMETRY: local/direct mean error %.5f/%.5f m | CPU same-time reference; not GPU readback" % [
		local_error, direct_error])


func _run() -> void:
	scene = Gameplay.instantiate()
	ocean = scene.get_node("Production/Ocean")
	ocean.set("wave_height_scale", 0.0)
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")): break
	check(bool(scene.get("ready_to_drive")), "gameplay loads")
	if not bool(scene.get("ready_to_drive")): quit(1); return
	provider = scene.get("water")
	ski = scene.get("ski")
	ski.water_physics_system.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	for tick in 8: await physics_frame
	var mass := ski.mass
	var inertia := ski.inertia
	var force_source := ski.water_physics_system
	await process_frame
	check(int(provider.get("query_mode")) == 0, "starts DIRECT")
	_key_l()
	check(int(provider.get("query_mode")) == 3, "L selects LOCAL_SURFACE without experimental inversor")
	await _phase("FLAT", 100)
	check(absf(ski.linear_velocity.y) < 0.15, "flat water reaches stable vertical equilibrium")
	ocean.call("set_sea_state", {"sea_state_mode": 0, "wind_speed_mps": 12.0, "swell": 0.4, "wave_height_scale": 1.0})
	await _wait_sync()
	Input.action_press("throttle", 0.25)
	await _phase("NORMAL", 60)
	Input.action_release("throttle")
	check(ski.drive_system.state.propulsion_force > 0.0, "propulsion remains active")
	_key_l()
	check(int(provider.get("query_mode")) == 0, "L selects DIRECT")
	for tick in 12: await physics_frame
	_key_l()
	check(int(provider.get("query_mode")) == 3, "L returns to LOCAL_SURFACE")
	ocean.call("set_sea_state", {"sea_state_mode": 0, "wind_speed_mps": 40.0, "swell": 0.8, "wave_height_scale": 1.0})
	await _wait_sync()
	await _phase("STORM", 90)
	_compare_surface()
	var native: Object = provider.get("native")
	var selection: Dictionary = native.call("validate_local_surface_contact_selection")
	for label in selection: check(bool(selection[label]), "crossing fixture: " + str(label))
	print("LOCAL_CHOPPY_CROSSINGS: " + str(selection))
	check(ski.mass == mass and ski.inertia == inertia and ski.water_physics_system == force_source,
		"A/B preserves mass, inertia and the exact same hull force system")
	# Missing local intersections recover using current DIRECT data, with a visible diagnosis.
	var far := ski.global_position + Vector3(1000, 0, 1000)
	var fallbacks := int(provider.get("local_surface_fallback_count"))
	check(provider.call("sample_water", far).valid, "outside patch uses a fresh finite direct sample")
	check(int(provider.get("local_surface_fallback_count")) == fallbacks + 1, "failed query diagnosed")
	for child in ski.get_children():
		if child.get_script() == load("res://gameplay/vehicles/common/visual/jet_ski_buoyancy_hud.gd"):
			child.call("_update_label")
			var text: String = child.get("_mode_label").text
			check(text.contains("LOCAL_SURFACE") and text.contains("query"), "HUD shows selection and query time")
	print("LOCAL_CHOPPY_SMOKE: %s | errors=%d | imports=%d" % [
		"PASS" if failures.is_empty() else "FAIL", failures.size(), provider.get("spectrum_sync_generation")])
	if failures.is_empty(): scene.call("_close_gracefully")
	else: quit(1)
