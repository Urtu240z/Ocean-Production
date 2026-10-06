extends SceneTree

## Audits actual initialized Production H0 uploads, without substituting nominal
## band configuration for the authored coefficients.
const WORLD := preload("res://gameplay/jet_ski_ocean.tscn")
const TARGET_RESOLUTIONS := [64, 128, 256]
const MEANINGFUL_MODE_FRACTION := 1.0e-8

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var world: Node = WORLD.instantiate()
	world.physics_water_backend = 1
	world.contact_debug = false
	world.follow_camera = false
	root.add_child(world)
	for _frame in 360:
		await process_frame
		if bool(world.get("ready_to_drive")): break
	if not bool(world.get("ready_to_drive")):
		printerr("PHYS_CPU_LITE_SPECTRAL_AUDIT_FAIL=scene did not initialize")
		quit(1)
		return
	var fft: Node = world.get_node("Production/Ocean/OpenOceanFFT")
	fft.set("_wave_speed_multiplier", 0.0)
	fft.set("_wave_time", 0.5)
	var snapshots: Array = fft.call("get_phys2_band_spectrum_snapshots")
	var configs: Array = fft.get("_wave_configs")
	if snapshots.size() != 3 or configs.size() != 3:
		printerr("PHYS_CPU_LITE_SPECTRAL_AUDIT_FAIL=missing Production band snapshots")
		quit(1)
		return
	var bands: Array[Dictionary] = []
	for band in 3:
		bands.append(_audit_band(snapshots[band], configs[band]))
	var report := {"status": "CAPTURED_REVIEW_REQUIRED", "source": "exact Current Production H0 RGBA32F uploads",
		"simulation_time_s": 0.5, "energy_definition": "phase-averaged per-mode height power = |H0|²+|H0n|²; vertical-velocity power weights the same by omega²; ratios sum retained centered signed modes with |kx_bin|,|kz_bin| < N/2",
		"meaningful_coefficient_threshold": "per-mode phase-averaged height power >= 1e-8 of total band power",
		"bands": bands}
	var file := FileAccess.open("res://.godot/phys_cpu_lite_spectral_support.json", FileAccess.WRITE)
	if file == null:
		printerr("PHYS_CPU_LITE_SPECTRAL_AUDIT_FAIL=cannot write output")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("PHYS_CPU_LITE_SPECTRAL_AUDIT_RESULT=res://.godot/phys_cpu_lite_spectral_support.json")
	await world.call("_close_gracefully")

func _audit_band(snapshot: Dictionary, config: Resource) -> Dictionary:
	var n := int(snapshot.resolution)
	var domain := float(snapshot.domain_size_m)
	var gravity := float(snapshot.gravity_mps2)
	var packed: PackedFloat32Array = snapshot.h0_rgba32f.to_float32_array()
	var modes: Array[Dictionary] = []
	modes.resize(n * n)
	var total_h := 0.0
	var total_v := 0.0
	var exact_min := INF
	var exact_max := 0.0
	var meaningful_min := INF
	var meaningful_max := 0.0
	var exact_count := 0
	for y in n:
		for x in n:
			var index := y * n + x
			var base := index * 4
			var bin_x := x - n / 2
			var bin_z := y - n / 2
			var kx := float(bin_x) * TAU / domain
			var kz := float(bin_z) * TAU / domain
			var k := sqrt(kx * kx + kz * kz)
			var omega := sqrt(gravity * k)
			var height_power := float(packed[base]) ** 2 + float(packed[base + 1]) ** 2 + \
				float(packed[base + 2]) ** 2 + float(packed[base + 3]) ** 2
			var velocity_power := height_power * omega * omega
			var wavelength := INF if k <= 0.0 else TAU / k
			modes[index] = {"bin_x": bin_x, "bin_z": bin_z, "wavelength": wavelength,
				"height_power": height_power, "velocity_power": velocity_power}
			total_h += height_power
			total_v += velocity_power
			if height_power > 0.0:
				exact_count += 1
				exact_min = minf(exact_min, wavelength)
				exact_max = maxf(exact_max, wavelength)
	var meaningful_threshold := total_h * MEANINGFUL_MODE_FRACTION
	for mode: Dictionary in modes:
		if float(mode.height_power) >= meaningful_threshold and meaningful_threshold > 0.0:
			meaningful_min = minf(meaningful_min, float(mode.wavelength))
			meaningful_max = maxf(meaningful_max, float(mode.wavelength))
	var retention: Array[Dictionary] = []
	for resolution in TARGET_RESOLUTIONS:
		var retained_h := 0.0
		var retained_v := 0.0
		var retained_count := 0
		for mode: Dictionary in modes:
			if absi(int(mode.bin_x)) >= resolution / 2 or absi(int(mode.bin_z)) >= resolution / 2:
				continue
			retained_count += 1
			retained_h += float(mode.height_power)
			retained_v += float(mode.velocity_power)
		retention.append({"resolution": resolution, "grid_spacing_m": domain / float(resolution),
			"axis_nyquist_wavelength_m": 2.0 * domain / float(resolution),
			"shortest_corner_wavelength_m": domain / (sqrt(2.0) * (resolution / 2 - 1)),
			"source_modes_retained": retained_count, "source_modes_total": n * n,
			"height_spectral_energy_fraction": retained_h / maxf(total_h, 1.0e-30),
			"vertical_velocity_spectral_energy_fraction": retained_v / maxf(total_v, 1.0e-30)})
	var min_wave := float(config.get("min_wavelength_m"))
	var max_wave := float(config.get("max_wavelength_m"))
	var width := float(config.get("transition_width_m"))
	return {"band": String(config.get("id")), "domain_size_m": domain, "source_resolution": n,
		"source_grid_spacing_m": domain / float(n),
		"profile_min_max_transition_m": [min_wave, max_wave, width],
		"smoothstep_effective_nonzero_wavelength_interval_m": [maxf(0.0, min_wave - width), max_wave + width],
		"actual_h0_nonzero_mode_count": exact_count,
		"actual_h0_nonzero_wavelength_range_m": [exact_min, exact_max],
		"meaningful_mode_threshold_fraction_of_total_height_power": MEANINGFUL_MODE_FRACTION,
		"meaningful_mode_wavelength_range_m": [meaningful_min, meaningful_max],
		"phase_averaged_total_height_spectral_power": total_h,
		"phase_averaged_total_vertical_velocity_spectral_power": total_v,
		"retention": retention}
