extends SceneTree
## H4.13 WIND_DRIVEN target Hs contract validation.
## Uses JonswapHasselmannSpectrum directly; the validator does not reimplement
## the production spectral formula.

const SPECTRUM := preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const CONFIG := preload("res://addons/ocean/core/ocean_fft_config.gd")
const SEED := 0x13579bdf
const EPSILON := 0.0000001
const INVARIANCE_TOLERANCE := 0.00000001


func _initialize() -> void:
	if not _source_contract():
		_fail("WIND_DRIVEN source contract is not strict")
		return
	if not _zero_target_energy():
		_fail("target_hs_m=0 suppressed WIND_DRIVEN energy")
		return
	print("OCEAN_WIND_DRIVEN_ZERO_TARGET_ENERGY_PASS")
	if not _target_invariance(1.0):
		_fail("WIND_DRIVEN H0 depends on target_hs_m")
		return
	print("OCEAN_WIND_DRIVEN_TARGET_HS_INVARIANT_PASS")
	if not _target_invariance(1.5):
		_fail("dominant_wavelength_scale reintroduced target_hs_m authority")
		return
	print("OCEAN_WIND_DRIVEN_SPACING_TARGET_INVARIANT_PASS")
	if not _manual_target_normalization():
		_fail("MANUAL_HS target normalization regressed")
		return
	print("OCEAN_MANUAL_TARGET_HS_NORMALIZATION_PASS")
	if not _manual_zero_target():
		_fail("MANUAL_HS zero target did not produce zero energy")
		return
	print("OCEAN_MANUAL_ZERO_TARGET_PASS")
	print("OCEAN_WIND_DRIVEN_PRODUCTION_CALL_CONTRACT_PASS")
	quit(0)


func _source_contract() -> bool:
	var spectrum_source := _read_source("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
	var open_ocean_source := _read_source("res://addons/ocean/fft/open_ocean_fft.gd")
	if spectrum_source.is_empty() or open_ocean_source.is_empty():
		return false
	if spectrum_source.contains("config.target_hs_m <= 0.0") or spectrum_source.contains("spacing_changed"):
		return false
	if not spectrum_source.contains("else 1.0") or not spectrum_source.contains("if normalize_to_target"):
		return false
	return open_ocean_source.contains("Spectrum.build_h0_rgba32f(config, Spectrum.derive_cascade_seed(seed, config.id), false)")


func _zero_target_energy() -> bool:
	var config := _make_config(0.0, 1.0)
	var packed: PackedByteArray = SPECTRUM.build_h0_rgba32f(config, SEED, false)
	return not packed.is_empty() and _packed_energy(packed) > EPSILON and float(config.measured_hs_m) > EPSILON


func _target_invariance(spacing: float) -> bool:
	var reference := SPECTRUM.build_h0_rgba32f(_make_config(0.0, spacing), SEED, false).to_float32_array()
	for target in [0.5, 5.0]:
		var candidate := SPECTRUM.build_h0_rgba32f(_make_config(target, spacing), SEED, false).to_float32_array()
		if not _arrays_equal(reference, candidate, INVARIANCE_TOLERANCE):
			return false
	return true


func _manual_target_normalization() -> bool:
	var config := _make_config(1.25, 1.0)
	var packed: PackedByteArray = SPECTRUM.build_h0_rgba32f(config, SEED, true)
	return not packed.is_empty() and is_equal_approx(float(config.measured_hs_m), 1.25)


func _manual_zero_target() -> bool:
	var config := _make_config(0.0, 1.0)
	var packed: PackedByteArray = SPECTRUM.build_h0_rgba32f(config, SEED, true)
	return not packed.is_empty() and _packed_energy(packed) <= EPSILON and float(config.measured_hs_m) <= EPSILON


func _make_config(target_hs: float, spacing: float) -> Resource:
	var config = CONFIG.new()
	config.id = &"TEST"
	config.resolution = 32
	config.domain_size_m = 256.0
	config.gravity_mps2 = 9.81
	config.min_wavelength_m = 3.0
	config.max_wavelength_m = 96.0
	config.transition_width_m = 0.75
	config.wind_direction = Vector2(1.0, 0.0)
	config.wind_speed_mps = 18.0
	config.fetch_length_m = 1000.0
	config.swell = 0.5
	config.jonswap_alpha = 0.0081
	config.jonswap_spread = 0.2
	config.detail = 1.0
	config.target_hs_m = target_hs
	config.dominant_wavelength_scale = spacing
	return config


func _packed_energy(packed: PackedByteArray) -> float:
	var values := packed.to_float32_array()
	var energy := 0.0
	for value in values:
		energy += float(value) * float(value)
	return energy


func _arrays_equal(left: PackedFloat32Array, right: PackedFloat32Array, tolerance: float) -> bool:
	if left.size() != right.size():
		return false
	for index in left.size():
		if absf(left[index] - right[index]) > tolerance:
			return false
	return true


func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
