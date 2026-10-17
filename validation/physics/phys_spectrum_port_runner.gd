extends SceneTree
const Profile = preload("res://addons/ocean/resources/default_wave_profile.tres")
const Spectrum = preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const State = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	var rows: Array = []
	for state in [[0.8, 4.0, 20.0, 0.8], [3.0, 18.0, 75.0, 2.0], [3.0, 18.0, 20.0, 2.0]]:
		var a: Array = Profile.build_fft_configs(state[0], state[1], state[2], 0.8, 1.0)
		var b: Array = Profile.build_fft_configs(state[0], state[1], state[2], 0.8, 1.0)
		a[0].choppiness = state[3]; b[0].choppiness = state[3]
		var at := Time.get_ticks_usec()
		var legacy := State.build(a, 1, state[0], Profile.combined_significant_wave_height_m(), 1.0, [1.0, 1.0, 1.0], 1.0)
		var legacy_ms := (Time.get_ticks_usec() - at) / 1000.0
		at = Time.get_ticks_usec()
		var port := State.build(b, 1, state[0], Profile.combined_significant_wave_height_m(), 1.0, [1.0, 1.0, 1.0], 1.0, 7, native)
		var native_ms := (Time.get_ticks_usec() - at) / 1000.0
		var bands: Array = []
		var error_gate := 0.0
		for band in 3:
			var x: PackedFloat32Array = legacy.bands[band].h0_rgba32f.to_float32_array()
			var y: PackedFloat32Array = port.bands[band].h0_rgba32f.to_float32_array()
			var max_error := 0.0; var total := 0.0; var different := 0
			for j in x.size():
				var error := absf(x[j] - y[j]); total += error; max_error = maxf(max_error, error)
				if error != 0.0: different += 1
			error_gate = maxf(error_gate, max_error / float(256 * 256))
			bands.append({"band": band, "mean_h0_error": total / x.size(), "max_h0_error": max_error, "different_floats": different})
		var authority: Object = ClassDB.instantiate("OceanQueryNative")
		var candidate: Object = ClassDB.instantiate("OceanQueryNative")
		if not authority.call("set_production_spectrum", legacy.bands) or not candidate.call("set_production_spectrum", port.bands):
			quit(1); return
		var points := PackedVector3Array([Vector3(0, 0, 0), Vector3(-255, 0, 255), Vector3(123.456, 0, -78.9), Vector3(1024, 0, -512)])
		var field_error := 0.0
		for time in [0.0, 1.25, 17.5]:
			var x: PackedFloat64Array = authority.call("sample_material_q_batch", time, points)
			var y: PackedFloat64Array = candidate.call("sample_material_q_batch", time, points)
			for j in x.size(): field_error = maxf(field_error, absf(x[j] - y[j]))
		rows.append({"state": state, "legacy_ms": legacy_ms, "native_ms": native_ms, "bands": bands, "all_output_max_error": field_error})
		if field_error > 0.00001:
			printerr("PHYS_SPECTRUM_PORT_FAIL=" + JSON.stringify(rows)); quit(1); return
		if error_gate > 0.00001:
			printerr("PHYS_SPECTRUM_PORT_FAIL=" + JSON.stringify(rows)); quit(1); return
	var file := FileAccess.open("res://.godot/phys_spectrum_port.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t")); file.close()
	print("PHYS_SPECTRUM_PORT=" + JSON.stringify(rows)); quit(0)
