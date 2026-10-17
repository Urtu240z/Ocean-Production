extends SceneTree

const OCEAN_SCENE: PackedScene = preload("res://addons/ocean/ocean.tscn")
const ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const BUILD_ID := preload("res://validation/physics/phys_native_build_contract.gd").ID

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("long_enabled", true)
	ocean.set("mid_enabled", true)
	ocean.set("short_enabled", true)
	ocean.set("coastal", true)
	ocean.set("breakers", false)
	ocean.set("crest_foam", false)
	ocean.set("surface_foam", false)
	root.add_child(ocean)
	for _i in 8: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node_or_null("OpenOceanFFT")
	if fft == null:
		_fail("OpenOceanFFT missing")
		return
	var snapshots: Array[Dictionary] = fft.call("get_phys2_band_spectrum_snapshots")
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if snapshots.size() != 3 or native == null:
		_fail("initial spectrum/native unavailable")
		return
	var setup: Dictionary = ADAPTER.configure_bands(native, snapshots, float(ocean.get("sea_level")), 7)
	if not bool(setup.get("ok", false)):
		_fail("initial spectrum setup failed")
		return
	var now := float(ocean.call("get_wave_time"))
	if not bool(native.call("start_dynamic_async_fields", now, 0)) or String(native.call("get_dynamic_async_build_id")) != BUILD_ID:
		_fail("async publisher/build id invalid")
		return
	var tick_id := 0
	var initial: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	var initial_version := int(initial[3])
	var transition_rows: Array[Dictionary] = []
	var original_hs := float(ocean.get("significant_wave_height_m"))
	var original_wind := float(ocean.get("wind_speed_mps"))
	var original_direction := float(ocean.get("wind_direction_degrees"))
	var original_profile: Resource = ocean.get("wave_profile")
	var profile: Resource = original_profile.duplicate(true)
	ocean.set("wave_profile", profile)
	for target in [
		{"name": "storm", "hs": 3.0, "wind": 18.0, "direction": 75.0, "chop": 2.0},
		{"name": "calm", "hs": 0.8, "wind": 4.0, "direction": 20.0, "chop": 0.8},
	]:
		var before: PackedFloat64Array = native.call("sample_dynamic_material_q", 31.25, -72.5)
		ocean.set("significant_wave_height_m", float(target["hs"]))
		ocean.set("wind_speed_mps", float(target["wind"]))
		ocean.set("wind_direction_degrees", float(target["direction"]))
		var wave_profile: Resource = ocean.get("wave_profile")
		wave_profile.get("long_band").set("choppiness", float(target["chop"]))
		var config_start := Time.get_ticks_usec()
		if not bool(ocean.call("initialize")):
			_fail("Production initialize failed for " + String(target["name"]))
			return
		await RenderingServer.frame_post_draw
		fft = ocean.get_node_or_null("OpenOceanFFT")
		snapshots = fft.call("get_phys2_band_spectrum_snapshots")
		for band in 3:
			var configured: Dictionary = ADAPTER._configure_band(native, snapshots[band], band)
			if not bool(configured.get("ok", false)):
				_fail("native band update failed: " + str(configured))
				return
		native.call("finalize_spectrum")
		var config_ms := float(Time.get_ticks_usec() - config_start) / 1000.0
		var wanted_version := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
		var published := false
		var coherent := false
		var published_time := -1.0
		for _wait in 900:
			await physics_frame
			tick_id += 1
			now = float(ocean.call("get_wave_time"))
			native.call("advance_dynamic_async", tick_id, now, now, 1.0 / 60.0)
			var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
			if info.size() >= 5 and int(info[0]) == 1 and int(info[3]) == wanted_version:
				var times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
				coherent = times.size() == 3 and times[0] == times[1] and times[1] == times[2]
				published_time = float(info[1]) / 1000000000.0
				published = true
				break
		if not published or not coherent:
			_fail("new coherent snapshot did not publish for " + String(target["name"]))
			return
		var after: PackedFloat64Array = native.call("sample_dynamic_material_q", 31.25, -72.5)
		var displacement_delta := 0.0
		if before.size() >= 5 and after.size() >= 5:
			displacement_delta = Vector3(after[2] - before[2], after[3] - before[3], after[4] - before[4]).length()
		transition_rows.append({"state": target["name"], "config_version": wanted_version,
			"configuration_ms": config_ms, "published_time": published_time,
			"bands_coherent": coherent, "displacement_change_m": displacement_delta,
			"phase_history_resets": int((native.call("get_dynamic_async_stats") as PackedInt64Array)[33])})
		if wanted_version <= initial_version:
			_fail("configuration version did not advance")
			return
		initial_version = wanted_version

	# Verify a paused Production clock does not enqueue changing snapshots.
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 5: await physics_frame
	var frozen_time := float(ocean.call("get_wave_time"))
	var frozen_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	for _i in 4:
		await physics_frame
		tick_id += 1
		native.call("advance_dynamic_async", tick_id, frozen_time, frozen_time, 1.0 / 60.0)
	var frozen_after := float(ocean.call("get_wave_time"))
	var frozen_info_after: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	var freeze_ok := is_equal_approx(frozen_time, frozen_after) and frozen_info[1] == frozen_info_after[1]
	ocean.set("wave_speed_multiplier", 1.0)
	var resume_start := float(ocean.call("get_wave_time"))
	for _i in 8:
		await physics_frame
		tick_id += 1
		now = float(ocean.call("get_wave_time"))
		native.call("advance_dynamic_async", tick_id, now, now, 1.0 / 60.0)
	var resume_end := float(ocean.call("get_wave_time"))
	print("PHYS_OPT_2E_CONFIG=" + JSON.stringify({"build_id": BUILD_ID,
		"transition": transition_rows, "freeze_time": [frozen_time, frozen_after],
		"freeze_snapshot_ns": [frozen_info[1], frozen_info_after[1]], "freeze_passed": freeze_ok,
		"resume_time": [resume_start, resume_end], "resume_advanced": resume_end > resume_start,
		"passed": transition_rows.size() == 2 and freeze_ok and resume_end > resume_start,
		"gpu_readback": false}))
	quit(0 if transition_rows.size() == 2 and freeze_ok and resume_end > resume_start else 1)

func _fail(message: String) -> void:
	printerr("PHYS_OPT_2E_CONFIG_FAIL=" + message)
	quit(1)
