extends SceneTree

## Open-ocean CPU Physics FFT Lite prototype. Uses the exact H0 bytes retained
## by the live Production OpenOceanFFT instance; no new seed or spectrum.
const OCEAN_SCENE: PackedScene = preload("res://addons/ocean/ocean.tscn")
const CANDIDATES := [
	{"name": "A_128_128_128", "n": [128, 128, 128]},
	{"name": "B_128_128_64", "n": [128, 128, 64]},
	{"name": "C_128_64_64", "n": [128, 64, 64]},
	{"name": "D_64_64_64", "n": [64, 64, 64]},
	{"name": "E_128_128_32", "n": [128, 128, 32]},
	{"name": "F_128_128_2_DC_only_short", "n": [128, 128, 2]},
]
const WARMUP_TICKS := 300
const MEASURED_TICKS := 10000

func _initialize() -> void:
	call_deferred("_run")

func _fail(message: String) -> void:
	printerr("PHYS_CPU_LITE_FAIL=" + message)
	quit(1)

func _run() -> void:
	if not ClassDB.class_exists("OceanQueryNative"):
		_fail("OceanQueryNative is not registered")
		return
	var ocean := OCEAN_SCENE.instantiate()
	ocean.set("coastal", false)
	ocean.set("breakers", false)
	ocean.set("crest_foam", false)
	ocean.set("surface_foam", false)
	root.add_child(ocean)
	for _frame in 20:
		await physics_frame
	var fft: Node = ocean.get_node_or_null("OpenOceanFFT")
	if fft == null:
		_fail("OpenOceanFFT is missing")
		return
	var snapshots: Array = fft.call("get_phys2_band_spectrum_snapshots")
	if snapshots.size() != 3:
		_fail("Production did not publish all three retained H0 snapshots")
		return
	for band in 3:
		if int(snapshots[band].get("resolution", 0)) != 256 or snapshots[band].get("h0_rgba32f", PackedByteArray()).is_empty():
			_fail("Production H0 snapshot is incomplete at band %d" % band)
			return
	var wave_time := float(ocean.call("get_wave_time"))
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if not native.call("set_production_spectrum", snapshots):
		_fail("native import rejected Production snapshots")
		return
	var single_mode_tests: Array = []
	var bin_mapping_audits: Array = []
	var test_resolutions := PackedInt32Array([256, 128, 64])
	for band in 3:
		var mapping_rows: Array = native.call("audit_dynamic_lite_bin_mapping", band, test_resolutions)
		if mapping_rows.is_empty():
			_fail("bin mapping audit returned no results for band %d" % band)
			return
		bin_mapping_audits.append_array(mapping_rows)
		var band_modes: Array = native.call("validate_dynamic_lite_single_modes", band, test_resolutions)
		if band_modes.is_empty():
			_fail("single-mode mapping validation returned no results for band %d" % band)
			return
		single_mode_tests.append_array(band_modes)
	var full_resolutions := PackedInt32Array([256, 256, 256])
	if not native.call("build_dynamic_physics_fields", wave_time):
		_fail("full-resolution native reference build failed")
		return
	if not native.call("build_dynamic_physics_lite", wave_time, full_resolutions):
		_fail("full-resolution packed Lite identity build failed")
		return
	var packed_identity: Array[Dictionary] = []
	for band in 3:
		packed_identity.append(native.call("compare_dynamic_lite_to_full", band, 1))
		if packed_identity[band].is_empty():
			_fail("full-resolution packed comparison failed at band %d" % band)
			return
	if OS.get_cmdline_user_args().has("--direct-oracle-only"):
		var direct_reports: Array[Dictionary] = []
		for candidate: Dictionary in CANDIDATES:
			var candidate_resolutions := PackedInt32Array(candidate.n)
			if not native.call("build_dynamic_physics_lite", wave_time, candidate_resolutions):
				_fail("direct-oracle Lite build failed for " + String(candidate.name)); return
			var band_rows: Array[Dictionary] = []
			for band in 3: band_rows.append(native.call("compare_dynamic_lite_to_direct_spectrum", band, 64))
			direct_reports.append({"candidate": candidate.name, "resolutions": candidate_resolutions,
				"bands": band_rows})
		var direct_path := "res://.godot/phys_cpu_lite_direct_oracle.json"
		var direct_file := FileAccess.open(direct_path, FileAccess.WRITE)
		if direct_file == null: _fail("could not save direct-spectrum oracle result"); return
		direct_file.store_string(JSON.stringify({"candidates": direct_reports, "simulation_time": wave_time}, "\t"))
		direct_file.close()
		print("PHYS_CPU_LITE_DIRECT_ORACLE=" + JSON.stringify(direct_reports))
		print("PHYS_CPU_LITE_DIRECT_ORACLE_RESULT=" + direct_path)
		quit(0); return

	var reports: Array[Dictionary] = []
	for candidate: Dictionary in CANDIDATES:
		var resolutions := PackedInt32Array(candidate.n)
		# Reuse the full-field oracle at wave_time. The Lite builder resets its
		# phase accumulator if the previous candidate's benchmark advanced beyond it.
		if not native.call("build_dynamic_physics_lite", wave_time, resolutions):
			_fail("Lite build failed for " + String(candidate.name))
			return
		var comparison: Array[Dictionary] = []
		var direct_spectrum: Array[Dictionary] = []
		for band in 3:
			comparison.append(native.call("compare_dynamic_lite_to_full", band, 2))
			if comparison[band].is_empty():
				_fail("field comparison failed for %s band %d" % [candidate.name, band])
				return
			direct_spectrum.append(native.call("compare_dynamic_lite_to_direct_spectrum", band, 64))
			if direct_spectrum[band].is_empty():
				_fail("direct-spectrum comparison failed for %s band %d" % [candidate.name, band])
				return
		var combined_comparison: Dictionary = native.call("compare_dynamic_lite_combined_to_full", 4096)
		if combined_comparison.is_empty():
			_fail("combined full-reference comparison failed for " + String(candidate.name))
			return
		var timings := {"update": _new_samples(), "phase": _new_samples(), "spectrum_evolution": _new_samples(),
			"packing": _new_samples(), "ifft": _new_samples(), "ifft_row_x": _new_samples(),
			"ifft_transpose": _new_samples(), "ifft_row_z": _new_samples(), "field_publication": _new_samples(),
			"band_update": [_new_samples(), _new_samples(), _new_samples()],
			"band_evolution": [_new_samples(), _new_samples(), _new_samples()],
			"band_phase": [_new_samples(), _new_samples(), _new_samples()],
			"band_packing": [_new_samples(), _new_samples(), _new_samples()],
			"band_ifft": [_new_samples(), _new_samples(), _new_samples()],
			"band_row_x": [_new_samples(), _new_samples(), _new_samples()],
			"band_transpose": [_new_samples(), _new_samples(), _new_samples()],
			"band_row_z": [_new_samples(), _new_samples(), _new_samples()],
			"band_publication": [_new_samples(), _new_samples(), _new_samples()]}
		var native_samples := PackedInt64Array(); native_samples.resize(MEASURED_TICKS)
		var runner_call_samples := PackedInt64Array(); runner_call_samples.resize(MEASURED_TICKS)
		var runner_iteration_samples := PackedInt64Array(); runner_iteration_samples.resize(MEASURED_TICKS)
		var slow_samples: Array[Dictionary] = []
		var memory_bytes := 0
		for tick in WARMUP_TICKS + MEASURED_TICKS:
			var time := wave_time + float(tick + 1) / 60.0
			var iteration_begin := Time.get_ticks_usec()
			var call_begin := Time.get_ticks_usec()
			if not native.call("build_dynamic_physics_lite", time, resolutions):
				_fail("timed field build failed for " + String(candidate.name))
				return
			var call_end := Time.get_ticks_usec()
			var runner_call_us := call_end - call_begin
			var profile: Dictionary = native.call("get_dynamic_lite_profile")
			if not bool(profile.get("valid", false)):
				_fail("Lite profile invalid for " + String(candidate.name))
				return
			memory_bytes = int(profile.memory_bytes)
			if tick < WARMUP_TICKS:
				continue
			var sample_index := tick - WARMUP_TICKS
			var native_us := int(profile.update_us)
			timings.update[sample_index] = native_us
			var evolution_sum := 0
			var phase_sum := 0
			var packing_sum := 0
			var ifft_sum := 0
			var row_x_sum := 0
			var transpose_sum := 0
			var row_z_sum := 0
			var publication_sum := 0
			for band in 3:
				var build_us := int(profile.band_build_us[band])
				var evolution_us := int(profile.spectrum_evolution_us[band])
				var ifft_us := int(profile.ifft_us[band])
				var publication_us := int(profile.field_publication_us[band])
				var phase_us := int(profile.phase_us[band])
				var packing_us := int(profile.packing_us[band])
				var row_x_us := int(profile.ifft_row_x_us[band])
				var transpose_us := int(profile.ifft_transpose_us[band])
				var row_z_us := int(profile.ifft_row_z_us[band])
				timings.band_update[band][sample_index] = build_us
				timings.band_phase[band][sample_index] = phase_us
				timings.band_evolution[band][sample_index] = evolution_us
				timings.band_packing[band][sample_index] = packing_us
				timings.band_ifft[band][sample_index] = ifft_us
				timings.band_row_x[band][sample_index] = row_x_us
				timings.band_transpose[band][sample_index] = transpose_us
				timings.band_row_z[band][sample_index] = row_z_us
				timings.band_publication[band][sample_index] = publication_us
				phase_sum += phase_us
				evolution_sum += evolution_us
				packing_sum += packing_us
				ifft_sum += ifft_us
				row_x_sum += row_x_us
				transpose_sum += transpose_us
				row_z_sum += row_z_us
				publication_sum += publication_us
			timings.spectrum_evolution[sample_index] = evolution_sum
			timings.phase[sample_index] = phase_sum
			timings.packing[sample_index] = packing_sum
			timings.ifft[sample_index] = ifft_sum
			timings.ifft_row_x[sample_index] = row_x_sum
			timings.ifft_transpose[sample_index] = transpose_sum
			timings.ifft_row_z[sample_index] = row_z_sum
			timings.field_publication[sample_index] = publication_sum
			var iteration_end := Time.get_ticks_usec()
			var iteration_us := iteration_end - iteration_begin
			native_samples[sample_index] = native_us
			runner_call_samples[sample_index] = runner_call_us
			runner_iteration_samples[sample_index] = iteration_us
			if native_us > 1250 or runner_call_us > 1250 or iteration_us - runner_call_us > 1000:
				var stage_rows: Array[Dictionary] = []
				for band in 3:
					stage_rows.append({"band": ["LONG", "MID", "SHORT"][band],
						"phase_us": profile.phase_us[band], "evolution_us": profile.spectrum_evolution_us[band],
						"packing_us": profile.packing_us[band], "ifft_row_x_us": profile.ifft_row_x_us[band],
						"ifft_transpose_us": profile.ifft_transpose_us[band],
						"ifft_row_z_us": profile.ifft_row_z_us[band],
						"publication_us": profile.field_publication_us[band],
						"band_build_us": profile.band_build_us[band]})
				slow_samples.append({"update_index": sample_index + 1, "native_update_us": native_us,
					"native_call_wall_us": runner_call_us, "runner_iteration_wall_us": iteration_us,
					"runner_outside_native_call_us": iteration_us - runner_call_us,
					"over_1250us": native_us > 1250, "over_1500us": native_us > 1500,
					"over_2000us": native_us > 2000, "stages": stage_rows})
		var timing_summary := {}
		for key in ["update", "phase", "spectrum_evolution", "packing", "ifft", "ifft_row_x", "ifft_transpose", "ifft_row_z", "field_publication"]:
			timing_summary[key + "_us"] = _stats(timings[key])
		timing_summary["runner_call_wall_us"] = _stats(Array(runner_call_samples))
		timing_summary["runner_iteration_wall_us"] = _stats(Array(runner_iteration_samples))
		var per_band: Array[Dictionary] = []
		for band in 3:
			per_band.append({
				"band": ["LONG", "MID", "SHORT"][band],
				"resolution": resolutions[band],
				"update_us": _stats(timings.band_update[band]),
				"phase_us": _stats(timings.band_phase[band]),
				"spectrum_evolution_us": _stats(timings.band_evolution[band]),
				"packing_us": _stats(timings.band_packing[band]),
				"ifft_us": _stats(timings.band_ifft[band]),
				"ifft_row_x_us": _stats(timings.band_row_x[band]),
				"ifft_transpose_us": _stats(timings.band_transpose[band]),
				"ifft_row_z_us": _stats(timings.band_row_z[band]),
				"field_publication_us": _stats(timings.band_publication[band]),
			})
		reports.append({
			"candidate": candidate.name,
			"resolutions": resolutions,
			"memory_bytes": memory_bytes,
			"timings": timing_summary,
			"per_band_timings": per_band,
			"full_resolution_cpu_reference": comparison,
			"combined_full_resolution_cpu_reference": combined_comparison,
			"direct_retained_spectrum_oracle": direct_spectrum,
			"timing_samples_native_update_us": native_samples,
			"timing_samples_runner_call_wall_us": runner_call_samples,
			"timing_samples_runner_iteration_wall_us": runner_iteration_samples,
			"slow_samples": slow_samples,
		})

	var report := {
		"status": "PROTOTYPE_ONLY",
		"authority": "OpenOceanFFT retained Production H0",
		"simulation_time": wave_time,
		"source_resolutions": [256, 256, 256],
		"packing_identity_256": packed_identity,
		"bin_mapping_audit": bin_mapping_audits,
		"single_mode_validation": single_mode_tests,
		"candidates": reports,
		"hardware": {"gpu": RenderingServer.get_video_adapter_name(), "cpu": OS.get_processor_name(),
			"cpu_identifier": _processor_name(), "logical_processor_count": OS.get_processor_count(),
			"renderer": RenderingServer.get_current_rendering_method(), "driver": RenderingServer.get_current_rendering_driver_name()},
		"native_build": {"target": "template_release", "optimization": "Godot godot-cpp default release speed (/O2 on MSVC)",
			"avx2_translation_units": true, "runtime_avx2_supported": bool(native.call("get_cpu_supports_avx2")),
			"runtime_fft_dispatch": "AVX2 when runtime CPU support is present; scalar fallback otherwise",
			"assertions": "NDEBUG in template_release", "debug_features": false},
		"ifft_contract": "F+iG; output real=HEIGHT and imag=VERTICAL_VELOCITY after centered-bin parity correction",
		"reduction_contract": "source signed bin (kx,kz), source array (128+kx,128+kz) -> destination signed bin (kx,kz), array (N/2+kx,N/2+kz); strict component cutoff |kx|,|kz|<N/2; H0 scale=(N/256)^2; domain and delta-k unchanged",
		"benchmark_contract": {"warmup_updates_per_candidate": WARMUP_TICKS, "measured_updates_per_candidate": MEASURED_TICKS,
			"native_and_runner_call_wall_samples_retained": true, "slow_sample_threshold_us": 1250},
		"oracle_limit": "full-resolution native Production CPU field plus direct sum of the evolved retained reduced spectrum; GPU PHYSICAL_HEIGHTFIELD oracle not yet connected",
	}
	var file := FileAccess.open("res://.godot/phys_cpu_lite_prototype.json", FileAccess.WRITE)
	if file == null:
		_fail("could not save prototype measurements")
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	var mode_max_error := 0.0
	var mode_direct_max_error := 0.0
	for row: Dictionary in single_mode_tests:
		mode_max_error = maxf(mode_max_error, float(row.height_max_error_m))
		mode_direct_max_error = maxf(mode_direct_max_error, float(row.direct_spectrum_sample_error_m))
	var console_candidates: Array[Dictionary] = []
	for row: Dictionary in reports:
		console_candidates.append({"candidate": row.candidate, "timings": row.timings,
			"memory_bytes": row.memory_bytes, "slow_sample_count": row.slow_samples.size(),
			"direct_retained_spectrum_oracle": row.direct_retained_spectrum_oracle})
	print("PHYS_CPU_LITE_DIAGNOSTICS=" + JSON.stringify({"single_mode_count": single_mode_tests.size(),
		"single_mode_max_error_m": mode_max_error, "single_mode_direct_error_m": mode_direct_max_error,
		"candidates": console_candidates, "hardware": report.hardware}))
	print("PHYS_CPU_LITE_RESULT=res://.godot/phys_cpu_lite_prototype.json")
	quit(0)

func _new_samples() -> PackedInt64Array:
	var values := PackedInt64Array()
	values.resize(MEASURED_TICKS)
	return values

func _stats(source: Variant) -> Dictionary:
	if source.is_empty():
		return {"count": 0}
	var values: Array = Array(source)
	values.sort()
	var sum := 0.0
	var square_sum := 0.0
	var over_1250 := 0
	var over_1000 := 0
	var over_1500 := 0
	var over_2000 := 0
	for value in values:
		sum += float(value)
		square_sum += float(value) * float(value)
		if float(value) > 1000.0: over_1000 += 1
		if float(value) > 1250.0: over_1250 += 1
		if float(value) > 1500.0: over_1500 += 1
		if float(value) > 2000.0: over_2000 += 1
	var mean := sum / values.size()
	var variance := maxf(0.0, square_sum / values.size() - mean * mean)
	return {
		"count": values.size(),
		"mean": mean,
		"stddev": sqrt(variance),
		"p50": values[int(ceil(values.size() * 0.50)) - 1],
		"p90": values[int(ceil(values.size() * 0.90)) - 1],
		"p95": values[int(ceil(values.size() * 0.95)) - 1],
		"p99": values[int(ceil(values.size() * 0.99)) - 1],
		"p99_5": values[int(ceil(values.size() * 0.995)) - 1],
		"p99_9": values[int(ceil(values.size() * 0.999)) - 1],
		"max": values.back(),
		"over_1250_us": over_1250,
		"over_1000_us": over_1000,
		"over_1500_us": over_1500,
		"over_2000_us": over_2000,
	}

func _processor_name() -> String:
	var env_name := OS.get_environment("PROCESSOR_IDENTIFIER")
	return env_name if not env_name.is_empty() else "unavailable to this process"
