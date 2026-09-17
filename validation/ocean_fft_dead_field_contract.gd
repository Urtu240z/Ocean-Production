extends Node
## H4.18 validates removal of dead internal FFT fields without changing the
## authored legacy storage contract or the JONSWAP spectrum.

const CONFIG_SCRIPT := preload("res://addons/ocean/core/ocean_fft_config.gd")
const BAND_SCRIPT := preload("res://addons/ocean/core/ocean_wave_band_profile.gd")
const PROFILE_SCRIPT := preload("res://addons/ocean/core/ocean_wave_profile.gd")
const SPECTRUM_SCRIPT := preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const ROUGH_PROFILE_PATH := "res://validation/profiles/rough_validation.tres"
const LEGACY_FIELDS := [&"energy", &"directional_spread", &"short_wave_damping_m"]
const LEGACY_STORAGE_FIELDS := [&"directional_spread", &"short_wave_damping_m"]
const LEGACY_STORAGE_PATH := "user://ocean_fft_h418_legacy_storage.tres"

var _failed := false


func _ready() -> void:
	call_deferred("_initialize")


func _initialize() -> void:
	if not _check_h0_invariance():
		_fail("H0 changed when only legacy fields changed")
		return
	print("OCEAN_FFT_LEGACY_FIELDS_H0_INVARIANT_PASS")
	if not _check_dead_config_fields_removed():
		_fail("Dead fields still exist on OceanFftConfig")
		return
	print("OCEAN_FFT_DEAD_CONFIG_FIELDS_REMOVED_PASS")
	if not _check_legacy_storage_contract():
		_fail("Legacy storage contract is not preserved")
		return
	print("OCEAN_FFT_LEGACY_STORAGE_COMPAT_PASS")
	if not _check_existing_profiles():
		_fail("Existing WaveProfile compatibility failed")
		return
	print("OCEAN_FFT_EXISTING_PROFILE_COMPAT_PASS")
	if not _check_source_contract():
		_fail("Dead field source contract failed")
		return
	print("OCEAN_FFT_DEAD_FIELD_SOURCE_CONTRACT_PASS")
	get_tree().quit(0)


func _check_h0_invariance() -> bool:
	var profile_a: Resource = _make_profile(0.0, 0.0)
	var profile_b: Resource = _make_profile(100.0, 100.0)
	var configs_a: Array = profile_a.build_fft_configs()
	var configs_b: Array = profile_b.build_fft_configs()
	if configs_a.size() != 3 or configs_b.size() != 3:
		return false
	for index in 3:
		var config_a: Resource = configs_a[index]
		var config_b: Resource = configs_b[index]
		if not config_a.is_valid() or not config_b.is_valid():
			return false
		var h0_a: PackedByteArray = SPECTRUM_SCRIPT.build_h0_rgba32f(config_a, 4180, false)
		var h0_b: PackedByteArray = SPECTRUM_SCRIPT.build_h0_rgba32f(config_b, 4180, false)
		if h0_a != h0_b:
			return false
	return true


func _make_profile(legacy_directional_spread: float, legacy_damping: float) -> Resource:
	var profile: Resource = PROFILE_SCRIPT.new()
	profile.profile_name = "H4.18 dead field contract"
	profile.wind_speed_mps = 16.0
	profile.long_band = _make_band(2.0, 3.0, Vector2(1.0, 0.1), 25000.0, 0.8, 0.05, 16.0, 128.0, 4.0, legacy_directional_spread, legacy_damping)
	profile.mid_band = _make_band(0.3, 1.0, Vector2(1.0, 0.38), 3000.0, 0.45, 0.35, 4.0, 20.0, 0.75, legacy_directional_spread, legacy_damping)
	profile.short_band = _make_band(0.12, 1.0, Vector2(1.0, 0.62), 300.0, 0.15, 0.75, 0.5, 5.0, 0.15, legacy_directional_spread, legacy_damping)
	return profile


func _make_band(hs: float, chop: float, direction: Vector2, fetch: float, swell: float, spread: float, min_wavelength: float, max_wavelength: float, transition: float, legacy_directional_spread: float, legacy_damping: float) -> Resource:
	var band: Resource = BAND_SCRIPT.new()
	band.significant_wave_height_m = hs
	band.choppiness = chop
	band.wind_direction = direction
	band.fetch_length_m = fetch
	band.swell = swell
	band.jonswap_spread = spread
	band.min_wavelength_m = min_wavelength
	band.max_wavelength_m = max_wavelength
	band.transition_width_m = transition
	band.directional_spread = legacy_directional_spread
	band.short_wave_damping_m = legacy_damping
	return band


func _check_dead_config_fields_removed() -> bool:
	var config: Resource = CONFIG_SCRIPT.new()
	var property_names: Array[StringName] = []
	for entry in config.get_property_list():
		property_names.append(StringName(entry.get("name", "")))
	for field in LEGACY_FIELDS:
		if property_names.has(field):
			return false
	var configs: Array = _make_profile(0.0, 0.0).build_fft_configs()
	return configs.size() == 3 and configs.all(func(value: Variant) -> bool: return value is Resource and value.is_valid())


func _check_legacy_storage_contract() -> bool:
	var band: Resource = BAND_SCRIPT.new()
	var property_usage: Dictionary = {}
	for entry in band.get_property_list():
		var name: StringName = StringName(entry.get("name", ""))
		property_usage[name] = int(entry.get("usage", 0))
	for field in LEGACY_STORAGE_FIELDS:
		if not property_usage.has(field):
			return false
		var usage: int = int(property_usage[field])
		if (usage & PROPERTY_USAGE_STORAGE) == 0 or (usage & PROPERTY_USAGE_EDITOR) != 0:
			return false
	band.directional_spread = 77.0
	band.short_wave_damping_m = 88.0
	var save_error: Error = ResourceSaver.save(band, LEGACY_STORAGE_PATH)
	if save_error != OK:
		return false
	var loaded: Resource = ResourceLoader.load(LEGACY_STORAGE_PATH) as Resource
	return loaded != null \
		and is_equal_approx(float(loaded.get("directional_spread")), 77.0) \
		and is_equal_approx(float(loaded.get("short_wave_damping_m")), 88.0)


func _check_existing_profiles() -> bool:
	var profile: Resource = ResourceLoader.load(ROUGH_PROFILE_PATH) as Resource
	if profile == null or not profile.has_method(&"build_fft_configs"):
		return false
	var configs: Array = profile.build_fft_configs()
	if configs.size() != 3:
		return false
	for config in configs:
		if not config.is_valid():
			return false
	return true


func _check_source_contract() -> bool:
	var config_source: String = _read("res://addons/ocean/core/ocean_fft_config.gd")
	var profile_source: String = _read("res://addons/ocean/core/ocean_wave_profile.gd")
	var band_source: String = _read("res://addons/ocean/core/ocean_wave_band_profile.gd")
	var spectrum_source: String = _read("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
	if config_source.is_empty() or profile_source.is_empty() or band_source.is_empty() or spectrum_source.is_empty():
		return false
	for field in ["energy", "directional_spread", "short_wave_damping_m"]:
		if config_source.contains("var " + field):
			return false
	if profile_source.contains("config.directional_spread") or profile_source.contains("config.short_wave_damping_m"):
		return false
	for field in LEGACY_STORAGE_FIELDS:
		if not band_source.contains("@export_storage var " + String(field)):
			return false
	if spectrum_source.contains("config.energy") or spectrum_source.contains("config.directional_spread") or spectrum_source.contains("config.short_wave_damping_m"):
		return false
	return true


func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	_failed = true
	push_error("OCEAN_FFT_DEAD_FIELD_CONTRACT_FAIL: " + message)
	get_tree().quit(1)
