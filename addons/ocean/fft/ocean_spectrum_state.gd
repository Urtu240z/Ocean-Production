extends RefCounted
## Shared Production H0 preparation. Receives exclusively owned config
## resources, so runtime weather may execute this on a persistent worker.
const Spectrum = preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")

static func build(configs: Array, seed: int, overall_hs: float, profile_hs: float,
		wave_height_scale: float, band_scales: Array, mid_fill: float, active_mask := 7, native_builder: Object = null) -> Dictionary:
	if configs.size() != 3 or not configs.all(func(c): return c.is_valid()): return {}
	var global_hs := overall_hs if overall_hs >= 0.0 else profile_hs
	var raw_h0: Array[PackedByteArray] = []
	var relative: Array[float] = []
	var variance := 0.0
	for band in 3:
		var config: Resource = configs[band]
		if (active_mask & (1 << band)) == 0:
			raw_h0.append(PackedByteArray()); relative.append(0.0); continue
		var band_seed := Spectrum.derive_cascade_seed(seed, config.id)
		var raw: PackedByteArray
		if native_builder != null:
			var values := {}
			for property in config.get_property_list():
				if (int(property.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
					values[property.name] = config.get(property.name)
			var produced: Dictionary = native_builder.call("build_production_h0", values, band_seed)
			if produced.is_empty(): return {}
			raw = produced.h0_rgba32f; config.measured_hs_m = produced.measured_hs_m
		else:
			raw = Spectrum.build_h0_rgba32f(config, band_seed, false)
		var amplitude := 1.0 if overall_hs < 0.0 else float(config.target_hs_m / global_hs if global_hs > 0.0000001 else 0.0)
		amplitude *= float(band_scales[band]) if overall_hs < 0.0 else 1.0
		if band == 1: amplitude *= clampf(mid_fill, 0.0, 1.5)
		relative.append(amplitude)
		raw_h0.append(native_builder.call("scale_production_h0", raw, amplitude) if native_builder != null else Spectrum.scale_packed_h0(raw, amplitude))
		variance += pow(config.measured_hs_m * amplitude / 4.0, 2.0)
	var common := wave_height_scale if overall_hs < 0.0 else float(global_hs / (4.0 * sqrt(variance)) if variance > 0.0000000001 else 0.0)
	var result: Array[Dictionary] = []
	var bounds := Vector3.ZERO
	for band in 3:
		var config: Resource = configs[band]
		var effective_hs := absf(float(config.measured_hs_m)) * absf(relative[band]) * absf(common)
		bounds.x += effective_hs * maxf(float(config.choppiness), 0.0)
		bounds.y += effective_hs
		bounds.z = maxf(bounds.z, maxf(float(config.choppiness), 0.0))
		var h0: PackedByteArray = PackedByteArray()
		if not raw_h0[band].is_empty():
			h0 = native_builder.call("scale_production_h0", raw_h0[band], common) if native_builder != null else Spectrum.scale_packed_h0(raw_h0[band], common)
		config.measured_hs_m *= common
		result.append({"band": String(config.id), "resolution": config.resolution,
			"wind_direction": config.wind_direction, "wind_speed_mps": config.wind_speed_mps,
			"domain_size_m": config.domain_size_m, "gravity_mps2": config.gravity_mps2,
			"choppiness": config.choppiness, "h0_rgba32f": h0,
			"effective_amplitude_scale": relative[band] * common})
	return {"bands": result, "bounds": bounds}
