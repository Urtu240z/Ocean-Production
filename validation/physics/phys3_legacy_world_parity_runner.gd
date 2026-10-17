extends "res://validation/physics/phys3_coastal_probe_runner.gd"
## Fixed-input diagnostic. Records the known 1e-8 gate failure without relaxing it.
## Exit 0 means the diagnostic ran; `gate_passed` is the numerical result.
func _run() -> void:
	load(NATIVE_DESCRIPTOR)
	_ocean = OCEAN_SCENE.instantiate()
	for name in ["long_enabled", "mid_enabled", "short_enabled", "coastal"]:
		_ocean.set(name, true)
	_ocean.set("coastal_bake", COASTAL_BAKE)
	for name in ["breakers", "crest_foam", "surface_foam"]:
		_ocean.set(name, false)
	for name in ["long_band_scale", "mid_band_scale", "short_band_scale", "wave_height_scale", "ocean_scale", "clipmap_geometry_scale"]:
		_ocean.set(name, 1.0)
	root.add_child(_ocean)
	for frame in 6: await RenderingServer.frame_post_draw
	_ocean.set("wave_speed_multiplier", 0.0)
	_fft = _ocean.get_node("OpenOceanFFT")
	_spectra = _fft.call("get_phys2_band_spectrum_snapshots")
	_bake_snapshot = _fft.call("get_phys3_coastal_snapshot")
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if not SPECTRUM_ADAPTER.configure_bands(native, _spectra, float(_ocean.get("sea_level")), 7).ok \
			or not SPECTRUM_ADAPTER.configure_coastal(native, _bake_snapshot).ok:
		_fail("legacy diagnostic source configuration"); return
	var t := 0.473258666666665
	var batch := _validate_batch(native, _make_bake_texel_samples(64, 1).slice(36, 40), t)
	var report := {"build_id": native.call("get_dynamic_async_build_id"), "time": t, "batch": batch,
		"unchanged_world_gate_m": 1e-8, "gate_passed": batch.world_scalar_vs_batch_m.max <= 1e-8}
	var file := FileAccess.open("res://.godot/phys3_legacy_world_parity.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("LEGACY_WORLD_PARITY_DIAGNOSTIC=" + JSON.stringify(report))
	native = null
	quit(0)
