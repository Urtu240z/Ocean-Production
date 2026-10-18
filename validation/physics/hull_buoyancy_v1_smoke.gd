extends SceneTree
## Bounded scene/mode smoke only; no benchmark or long gameplay replay.

const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("HULL_V1_SMOKE: " + message)


func _run() -> void:
	var scene := Gameplay.instantiate()
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")):
			break
	_check(bool(scene.get("ready_to_drive")), "gameplay scene initializes CPU Lite")
	var ski: JetSkiController = scene.get("ski")
	var physics := ski.water_physics_system
	var hull = physics.hull_buoyancy
	_check(hull.local_points.size() == 12 and hull.total_volume_m3 > 0.3, "twelve finite-volume hull cells")
	_check(physics.get_buoyancy_mode_name() == "HULL_BUOYANCY_V1", "Buoyancy Physics is the standard")
	var sample := WaterSample3D.new()
	sample.valid = true
	sample.normal = Vector3.UP
	var full_volume := 0.0
	var dry_volume := 0.0
	for index in hull.local_points.size():
		sample.surface_position = Vector3(0.0, 10.0, 0.0)
		full_volume += float(hull.integrate_cell(index, Transform3D.IDENTITY, sample, 0.0).volume)
		sample.surface_position.y = -10.0
		dry_volume += float(hull.integrate_cell(index, Transform3D.IDENTITY, sample, 0.0).volume)
	_check(absf(full_volume - hull.total_volume_m3) < 0.00001 and dry_volume < 0.00001,
		"dry/full clipping conserves hull volume")
	# Complementary half spaces exercise partial clipping and tilted centroids.
	var partial_volume := 0.0
	var complement_volume := 0.0
	sample.surface_position = Vector3(0.0, -0.10, 0.0)
	for index in hull.local_points.size():
		sample.normal = Vector3(0.3, 1.0, 0.2).normalized()
		var partial: Dictionary = hull.integrate_cell(index, Transform3D.IDENTITY, sample, 0.0)
		partial_volume += float(partial.volume)
		_check((partial.center as Vector3).is_finite(), "partial volume centroid is finite")
		sample.normal = -sample.normal
		complement_volume += float(hull.integrate_cell(index, Transform3D.IDENTITY, sample, 0.0).volume)
	_check(absf(partial_volume + complement_volume - hull.total_volume_m3) < 0.00001,
		"partial clipping conserves volume across complementary planes")
	var hud := ski.get_child(ski.get_child_count() - 1)
	var hud_script = load("res://addons/jet_ski/debug/jet_ski_buoyancy_hud.gd")
	for child in ski.get_children():
		if child.get_script() == hud_script:
			hud = child
	var toggle := InputEventKey.new()
	toggle.keycode = KEY_H
	toggle.pressed = true
	# Legacy is retained only as an explicit comparison setup.
	physics.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.LEGACY_4POINT)
	ski.buoyancy_mode=0
	# Exercise the real H handler, including its visible mode label.
	hud.call("_unhandled_key_input", toggle)
	_check(physics.get_buoyancy_mode_name() == "HULL_BUOYANCY_V1", "H selects distributed mode")
	_check(physics.get_water_query_local_points().size() == 12, "batch prefetch uses twelve hull samples")
	_check(str(hud.get("_mode_label").text).contains("Buoyancy Physics"), "HUD shows standard buoyancy name")
	for tick in 60:
		await physics_frame
	_check(hull.submerged_volume_m3 > 0.0, "distributed mode reaches water and produces displacement")
	_check(physics.point_depths.size() == 4 and physics.state.raw_contact_mask < 16,
		"four-contact navigation/landing contract")
	_check(physics.total_buoyancy_force_vector.is_finite() and physics.total_buoyancy_torque.is_finite(),
		"distributed forces and moments remain finite")
	hud.call("_unhandled_key_input", toggle)
	_check(physics.get_buoyancy_mode_name() == "LEGACY_4POINT", "H restores legacy")
	_check(physics.get_water_query_local_points().size() == 4, "legacy restores original batch layout")
	for tick in 6:
		await physics_frame
	print("HULL_V1_SMOKE: %s | samples=12 | hull_volume=%.4f m3 | errors=%d" % [
		"PASS" if failures.is_empty() else "FAIL", hull.total_volume_m3, failures.size()])
	if failures.is_empty():
		scene.call("_close_gracefully")
	else:
		quit(1)
