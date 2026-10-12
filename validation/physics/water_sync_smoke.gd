extends SceneTree
## Three authoring rebuilds plus one metadata-version check; no benchmark.
const Gameplay = preload("res://gameplay/jet_ski_ocean.tscn")
var failures: Array[String] = []
var scene: Node
var ocean: Node
var provider: Node
var ski: JetSkiController
var probes := PackedVector3Array([
	Vector3(-20, 0, -20), Vector3(0, 0, -20), Vector3(20, 0, -20),
	Vector3(-20, 0, 0), Vector3.ZERO, Vector3(20, 0, 0),
	Vector3(-20, 0, 20), Vector3(0, 0, 20), Vector3(20, 0, 20)])


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("WATER_SYNC_SMOKE: " + message)


func _wait_for_sync(after_revision: int) -> bool:
	for frame in 240:
		await process_frame
		var source: Dictionary = ocean.call("get_physics_source_state")
		var sync: Dictionary = provider.call("get_water_sync_status")
		if source.status == "OK" and sync.status == "OK" \
				and int(sync.ocean_revision) > after_revision:
			return true
	return false


func _height_span() -> float:
	var samples: Array = provider.call("sample_water_batch", probes)
	_check(samples.size() == probes.size(), "all nine probes available after synchronization")
	var low := INF
	var high := -INF
	for sample in samples:
		_check(sample.valid, "probe is valid")
		low = minf(low, sample.surface_position.y)
		high = maxf(high, sample.surface_position.y)
	return high - low if not samples.is_empty() else -1.0


func _change_weather(label: String, values: Dictionary) -> float:
	var before: Dictionary = provider.call("get_spectrum_sync_diagnostics")
	var revision := int(before.ocean_revision)
	var retired_fft: Node = provider.get("fft")
	var wave_time := float(before.physics_wave_time)
	_check(bool(ocean.call("set_sea_state", values)), label + ": authoring update accepted")
	_check(provider.call("get_water_sync_status").status == "UPDATING", label + ": UPDATING immediately")
	_check(not bool(provider.call("has_usable_contacts")), label + ": no stale support")
	_check(not provider.call("sample_water", Vector3.ZERO).valid, label + ": no stale single sample")
	_check(provider.call("sample_water_batch", probes).is_empty(), label + ": no stale batch")
	_check(provider.call("get_surface_query_contract").is_empty(), label + ": no retiring source access")
	_check(await _wait_for_sync(revision), label + ": rebuilt spectrum becomes available")
	var after: Dictionary = provider.call("get_spectrum_sync_diagnostics")
	var source: Dictionary = ocean.call("get_physics_source_state")
	_check(after.status == "OK" and int(after.fft_instance_id) == int(source.fft_instance_id),
		label + ": physics uses the published FFT instance")
	_check(int(after.generation) == int(before.generation) + 1, label + ": spectrum imported exactly once")
	_check(float(after.physics_wave_time) >= wave_time, label + ": simulation time is continuous")
	_check(absf(float(after.physics_wave_time) - float(source.wave_time)) < 0.00001,
		label + ": physics and ocean clocks agree")
	_check(not is_instance_valid(retired_fft), label + ": retiring reference has been freed safely")
	var spectra: Array = provider.get("fft").call("get_phys2_band_spectrum_snapshots")
	for band in spectra.size():
		_check(int(after.bands[band].h0_hash) == hash(spectra[band].h0_rgba32f),
			label + ": physical H0 matches current visual spectrum")
		_check(is_equal_approx(float(after.bands[band].wind_speed_mps), float(values.wind_speed_mps)),
			label + ": imported wind matches authoring")
	var span := _height_span()
	print("WATER_SYNC_PHASE: %s | mode=%s | ocean=r%d spectrum=v%d | wind=%.1f | span=%.6f m" % [
		label, ski.water_physics_system.get_buoyancy_mode_name(), after.ocean_revision,
		after.spectrum_version, values.wind_speed_mps, span])
	return span


func _run() -> void:
	scene = Gameplay.instantiate()
	root.add_child(scene)
	for frame in 180:
		await process_frame
		if bool(scene.get("ready_to_drive")):
			break
	_check(bool(scene.get("ready_to_drive")), "gameplay initializes")
	ocean = scene.get_node("Production/Ocean")
	provider = scene.get("water")
	ski = scene.get("ski")
	if not bool(scene.get("ready_to_drive")):
		scene.call("_close_gracefully")
		return
	await process_frame
	var first_span := await _change_weather("WIND", {"wind_speed_mps": 23.0})
	_check(first_span > 0.01, "wind change produces a non-flat field")
	ski.water_physics_system.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1)
	var flat_span := await _change_weather("FLAT", {"sea_state_mode": 0,
		"wind_speed_mps": 1.0, "swell": 0.0, "wave_height_scale": 0.0})
	_check(flat_span >= 0.0 and flat_span < 0.00001, "rough-to-flat transition reaches flat physical water")
	var rough_span := await _change_weather("ROUGH", {"sea_state_mode": 0,
		"wind_speed_mps": 23.0, "swell": 0.8, "wave_height_scale": 1.0})
	_check(rough_span > 0.01, "flat-to-rough transition restores physical waves")
	# The branch exposes a spectrum version even without an instance replacement.
	# Advance metadata only to exercise that guard, without altering FFT rendering.
	var fft: Node = provider.get("fft")
	if fft.has_method("get_phys2_spectrum_generation"):
		var imported_before := int(provider.get("spectrum_sync_generation"))
		fft.set("_phys2_spectrum_generation", int(fft.call("get_phys2_spectrum_generation")) + 1)
		_check(not provider.call("sample_water", Vector3.ZERO).valid, "version change blocks cached sample")
		for tick in 3:
			await physics_frame
		_check(int(provider.get("spectrum_sync_generation")) == imported_before + 1,
			"same-instance version change imports once")
	ski.water_physics_system.set_buoyancy_mode(JetSkiWaterPhysicsSystem.BuoyancyMode.LEGACY_4POINT)
	var stable_import_count := int(provider.get("spectrum_sync_generation"))
	for tick in 12:
		await physics_frame
	_check(int(provider.get("spectrum_sync_generation")) == stable_import_count,
		"unchanged ocean does not recopy its spectrum per tick or on buoyancy switch")
	for child in ski.get_children():
		if child.get_script() == load("res://gameplay/vehicles/common/visual/jet_ski_buoyancy_hud.gd"):
			_check(str(child.get("_mode_label").text).contains("WATER SYNC: OK"), "HUD shows WATER SYNC: OK")
	print("WATER_SYNC_SMOKE: %s | errors=%d | imports=%d" % [
		"PASS" if failures.is_empty() else "FAIL", failures.size(), stable_import_count])
	if failures.is_empty():
		scene.call("_close_gracefully")
	else:
		quit(1)
