extends SceneTree
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	var floats := PackedFloat32Array()
	floats.resize(128 * 128 * 4)
	for i in 128 * 128:
		floats[4*i] = sin(float(i)*0.71)*0.003
		floats[4*i+1] = cos(float(i)*0.37)*0.003
	var bands: Array = []
	for b in 3:
		bands.append({"resolution":128,"domain_size_m":256.0/(b+1),"gravity_mps2":9.81,"choppiness":1.0,"h0_rgba32f":floats.to_byte_array()})
	native.call("set_production_spectrum",bands)
	native.call("perf3_set_fft_probe",true,false,1000000000)
	for i in 151: native.call("build_dynamic_physics_lite",float(i)/60.0,PackedInt32Array([128,128,128]))
	var baseline := PackedFloat64Array()
	var copying := PackedFloat64Array()
	var copy_us := PackedFloat64Array()
	var sample_before: PackedFloat64Array = native.call("sample_dynamic_lite_surface",0,2.3,-4.7,0.0,1)
	for trial in 200:
		for step in 2:
			var enabled := (trial + step) % 2 == 0
			# Prevent freezing: measure steady copy overhead on identical spectra.
			native.call("perf3_set_fft_probe",enabled,false,1000000000)
			native.call("build_dynamic_physics_lite",2.5,PackedInt32Array([128,128,128]))
			var capture: Dictionary = native.call("get_perf1_capture")
			var row: Dictionary = capture.records[-1]
			if enabled:
				copying.append(float(row.wall_us))
				var total := 0.0
				for b: Dictionary in row.bands:
					for f: Dictionary in b.fft_environment: total += float(f.probe_input_copy_us)
				copy_us.append(total)
			else: baseline.append(float(row.wall_us))
	baseline.sort();copying.sort();copy_us.sort()
	var sample_after: PackedFloat64Array = native.call("sample_dynamic_lite_surface",0,2.3,-4.7,0.0,1)
	var unchanged: bool = sample_before.to_byte_array() == sample_after.to_byte_array()
	var result := {"query_unchanged":unchanged,"paired_trials":200,"baseline_median_us":baseline[100],"copying_median_us":copying[100],"input_copy_median_us":copy_us[100],"input_copy_p95_us":copy_us[189],"notes":"same spectrum/time, alternating order; timing variation remains possible; explicit fixture override without ETW"}
	var file := FileAccess.open("res://temp/perf3_probe_cost.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(result));file.close()
	print("PERF3_PROBE_COST ",JSON.stringify(result))
	native = null
	quit(0 if unchanged else 1)
