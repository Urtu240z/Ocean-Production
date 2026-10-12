extends SceneTree
## Bounded runtime authoring check, using the actual gameplay scene and CPU Lite grids.
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
var failures: Array[String] = []
var scene: Node
var ocean: Node
var provider: Node
var ski: JetSkiController
var probes := PackedVector3Array([Vector3(-17, -0.7, 13), Vector3(2, 0.3, -9), Vector3(19, 1.2, 7)])


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("OCEAN_SPACE_SMOKE: " + message)


func _check_samples(vertical: float, horizontal: float, stencil: bool) -> void:
	provider.set("water_race_normal_enabled", stencil)
	var samples: Array = provider.call("sample_water_batch", probes)
	_check(samples.size() == probes.size(), "all batched samples available")
	if samples.size() != probes.size(): return
	var native: Object = provider.get("native")
	var level := float(provider.get("sea_level"))
	var rate := float(provider.get("wave_time_rate"))
	var modes: PackedInt32Array = provider.get("lite_interpolation_modes")
	for index in probes.size():
		var point := probes[index]
		var q := Vector3(point.x / horizontal, point.y, point.z / horizontal)
		var points := PackedVector3Array([q])
		if stencil:
			var step := 0.4 / horizontal
			points.append(q + Vector3(-step, 0, 0))
			points.append(q + Vector3(step, 0, 0))
			points.append(q + Vector3(0, 0, -step))
			points.append(q + Vector3(0, 0, step))
		var raw: PackedFloat64Array = native.call("sample_dynamic_lite_contacts", points, level, modes)
		_check(raw.size() == 1 + points.size() * 6, "native reference samples available")
		if raw.size() != 1 + points.size() * 6: continue
		var height := level + (raw[2] - level) * vertical
		var velocity := raw[3] * vertical * rate
		var normal := Vector3(raw[4] * vertical / horizontal, raw[5], raw[6] * vertical / horizontal).normalized()
		if stencil:
			normal = Vector3(-(raw[14] - raw[8]) * vertical / 0.8,
				1.0, -(raw[26] - raw[20]) * vertical / 0.8).normalized()
		var sample: WaterSample3D = samples[index]
		_check(sample.valid, "scaled sample valid")
		_check(absf(sample.surface_position.y - height) < 0.00002, "height scaled about sea level")
		_check(absf(sample.signed_depth - (height - point.y)) < 0.00002, "depth uses scaled world surface")
		_check(absf(sample.velocity.y - velocity) < 0.00002, "vertical velocity includes Ocean Scale")
		_check(sample.normal.distance_to(normal) < 0.00002, "normal uses actual scaled domains and vertical slope")
		_check(is_equal_approx(sample.normal.length(), 1.0), "Jolt receives a unit normal")
		_check(sample.surface_position.x == point.x and sample.surface_position.z == point.z,
			"direct sample stays at world XZ; no fabricated choppiness")
		var single: WaterSample3D = provider.call("sample_water", point)
		_check(single.valid and single.surface_position.distance_to(sample.surface_position) < 0.00002,
			"single-contact interface agrees with batch")
	print("OCEAN_SPACE_SAMPLES: V=%.2f H=%.2f stencil=%s | y=%.5f vy=%.5f normal=%s" % [
		vertical, horizontal, stencil, samples[0].surface_position.y, samples[0].velocity.y, samples[0].normal])


func _change_scales(vertical: float, horizontal: float) -> void:
	var before: Dictionary = provider.call("get_water_sync_status")
	var imports := int(provider.get("spectrum_sync_generation"))
	var builds := int(provider.get("field_update_count"))
	ocean.set("ocean_scale", vertical)
	ocean.set("clipmap_geometry_scale", horizontal)
	var source: Dictionary = ocean.call("get_physics_source_state")
	var changed := int(source.ocean_space.revision) != int(before.ocean_space_revision)
	if changed:
		_check(provider.call("get_water_sync_status").status == "UPDATING", "scale change shows UPDATING immediately")
		_check(not provider.call("sample_water", probes[0]).valid, "old single samples rejected")
		_check(provider.call("sample_water_batch", probes).is_empty(), "old batch samples rejected")
		_check(not provider.call("has_usable_contacts"), "old contact cache cannot support the craft")
		_check(bool(provider.call("_refresh_runtime_spectrum_if_needed")), "same-tick scale synchronization succeeds")
		_check(int(provider.get("field_update_count")) == builds, "scale-only update does not rebuild fields")
	var sync: Dictionary = provider.call("get_water_sync_status")
	_check(sync.status == "OK", "updated Ocean Space is OK")
	_check(int(sync.ocean_space_revision) == int(source.ocean_space.revision), "space revisions agree")
	_check(int(sync.fft_instance_id) == int(before.fft_instance_id), "scales keep the same FFT instance")
	_check(int(sync.spectrum_version) == int(before.spectrum_version), "scales keep the same spectrum version")
	_check(int(provider.get("spectrum_sync_generation")) == imports, "scales do not copy H0")
	var surface: Dictionary = provider.call("get_surface_query_contract")
	_check(is_equal_approx(float(surface.ocean_surface_scale), vertical), "visual height scale agrees")
	_check(is_equal_approx(float(surface.clipmap_geometry_scale), horizontal), "visual horizontal scale agrees")
	var bands: Array = provider.get("imported_spectrum_bands")
	_check(is_equal_approx(float(surface.domain_long_m), float(bands[0].domain_size_m) * horizontal),
		"world-to-lattice mapping follows the actual shader domain")
	_check_samples(vertical, horizontal, false)
	_check_samples(vertical, horizontal, true)
	# Exercise the regular contact-prefetch path in each buoyancy mode too.
	for tick in 4: await physics_frame
	await process_frame
	_check(provider.call("get_water_sync_status").status == "OK", "normal gameplay contact phase stays synchronized")


func _run() -> void:
	scene = Gameplay.instantiate()
	ocean = scene.get_node("Production/Ocean")
	# Nonzero sea level tests the scaling pivot without changing scene authoring.
	ocean.set("sea_level", 3.0)
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")): break
	_check(bool(scene.get("ready_to_drive")), "gameplay initializes")
	if not bool(scene.get("ready_to_drive")):
		quit(1)
		return
	provider = scene.get("water")
	ski = scene.get("ski")
	await process_frame
	var original_stencil := bool(provider.get("water_race_normal_enabled"))
	for mode in [JetSkiWaterPhysicsSystem.BuoyancyMode.LEGACY_4POINT, JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1]:
		ski.water_physics_system.set_buoyancy_mode(mode)
		for scales in [Vector2(1, 1), Vector2(0.5, 1), Vector2(2, 1), Vector2(1, 1),
				Vector2(1, 0.5), Vector2(1, 2), Vector2(0.5, 2), Vector2(2, 0.5), Vector2(1, 1)]:
			await _change_scales(scales.x, scales.y)
		print("OCEAN_SPACE_MODE: " + ski.water_physics_system.get_buoyancy_mode_name())
	# A spectrum rebuild may reset the per-instance Ocean Space revision.
	# Keep non-unit scales across one real wind edit to exercise that boundary.
	await _change_scales(0.5, 2.0)
	var before: Dictionary = provider.call("get_water_sync_status")
	var imports := int(provider.get("spectrum_sync_generation"))
	ocean.set("wind_speed_mps", float(ocean.get("wind_speed_mps")) + 1.0)
	_check(provider.call("get_water_sync_status").status == "UPDATING", "wind rebuild invalidates scaled contacts")
	for frame in 240:
		await process_frame
		var sync: Dictionary = provider.call("get_water_sync_status")
		if sync.status == "OK" and int(sync.fft_instance_id) != int(before.fft_instance_id): break
	var rebuilt: Dictionary = provider.call("get_water_sync_status")
	_check(rebuilt.status == "OK" and int(rebuilt.fft_instance_id) != int(before.fft_instance_id),
		"new instance publishes a valid scaled space")
	_check(int(provider.get("spectrum_sync_generation")) == imports + 1, "wind rebuild imports H0 once")
	_check(is_equal_approx(float(rebuilt.ocean_scale), 0.5)
		and is_equal_approx(float(rebuilt.clipmap_geometry_scale), 2.0), "non-unit scales survive the wind rebuild")
	_check_samples(0.5, 2.0, false)
	_check_samples(0.5, 2.0, true)
	await _change_scales(1.0, 1.0)
	provider.set("water_race_normal_enabled", original_stencil)
	var count := int(provider.get("ocean_space_sync_count"))
	# An unchanged slider value must not invalidate contacts or sync again.
	ocean.set("ocean_scale", 1.0)
	ocean.set("clipmap_geometry_scale", 1.0)
	for tick in 8: await physics_frame
	await process_frame
	_check(int(provider.get("ocean_space_sync_count")) == count, "unchanged space does not resynchronize per tick")
	for child in ski.get_children():
		if child.get_script() == load("res://gameplay/vehicles/common/visual/jet_ski_buoyancy_hud.gd"):
			var text: String = child.get("_mode_label").text
			_check(text.contains("WATER SYNC: OK") and text.contains("Ocean Space r"), "HUD shows state and space revision")
	print("OCEAN_SPACE_SMOKE: %s | errors=%d | spectrum imports=%d | space syncs=%d" % [
		"PASS" if failures.is_empty() else "FAIL", failures.size(), provider.get("spectrum_sync_generation"), count])
	if failures.is_empty(): scene.call("_close_gracefully")
	else: quit(1)
