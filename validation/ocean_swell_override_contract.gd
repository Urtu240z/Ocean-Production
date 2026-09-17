extends SceneTree
## H4.15 swell_override contract validation.
## Every result is produced by the real OceanWaveProfile API.

const PROFILE := preload("res://addons/ocean/core/ocean_wave_profile.gd")
const BAND := preload("res://addons/ocean/core/ocean_wave_band_profile.gd")
const EPSILON := 0.000001


func _initialize() -> void:
	if not _check_no_override():
		_fail("swell_override=-1 changed authored swell")
		return
	print("OCEAN_SWELL_NO_OVERRIDE_PRESERVES_PROFILE_PASS")
	if not _check_ratio_preservation():
		_fail("positive LONG swell ratio was not preserved")
		return
	print("OCEAN_SWELL_RATIO_PRESERVATION_PASS")
	if not _check_zero_override():
		_fail("zero swell override did not zero every band")
		return
	print("OCEAN_SWELL_ZERO_OVERRIDE_PASS")
	if not _check_zero_reference_override():
		_fail("zero LONG reference did not isolate positive override to LONG")
		return
	print("OCEAN_SWELL_ZERO_REFERENCE_OVERRIDE_PASS")
	if not _check_all_zero_profile():
		_fail("positive override could not create LONG swell from all-zero profile")
		return
	print("OCEAN_SWELL_CAN_CREATE_FROM_ZERO_PASS")
	if not _check_existing_profile_compatibility():
		_fail("existing WaveProfile compatibility regressed")
		return
	print("OCEAN_SWELL_EXISTING_PROFILE_COMPAT_PASS")
	quit(0)


func _check_no_override() -> bool:
	var values := _swell_values(_make_profile([0.8, 0.4, 0.2]), -1.0)
	return _values_match(values, [0.8, 0.4, 0.2])


func _check_ratio_preservation() -> bool:
	var values := _swell_values(_make_profile([0.8, 0.4, 0.2]), 0.4)
	return _values_match(values, [0.4, 0.2, 0.1])


func _check_zero_override() -> bool:
	var positive_long := _swell_values(_make_profile([0.8, 0.4, 0.2]), 0.0)
	var zero_long := _swell_values(_make_profile([0.0, 0.4, 0.2]), 0.0)
	return _values_match(positive_long, [0.0, 0.0, 0.0]) and _values_match(zero_long, [0.0, 0.0, 0.0])


func _check_zero_reference_override() -> bool:
	var values := _swell_values(_make_profile([0.0, 0.35, 0.10]), 0.65)
	return _values_match(values, [0.65, 0.35, 0.10])


func _check_all_zero_profile() -> bool:
	var values := _swell_values(_make_profile([0.0, 0.0, 0.0]), 0.7)
	return _values_match(values, [0.7, 0.0, 0.0])


func _check_existing_profile_compatibility() -> bool:
	var profile: Resource = load("res://validation/profiles/rough_validation.tres")
	if profile == null:
		return false
	var long_band: Resource = profile.get("long_band")
	var mid_band: Resource = profile.get("mid_band")
	var short_band: Resource = profile.get("short_band")
	if long_band == null or mid_band == null or short_band == null:
		return false
	var authored_long := float(long_band.get("swell"))
	if authored_long <= EPSILON:
		return false
	var authored := [authored_long, float(mid_band.get("swell")), float(short_band.get("swell"))]
	var override := 0.35
	var values := _swell_values(profile, override)
	var scale := override / authored_long
	return _values_match(values, [authored[0] * scale, authored[1] * scale, authored[2] * scale])


func _make_profile(swells: Array) -> Resource:
	var profile: Resource = PROFILE.new()
	profile.set("long_band", _make_band(float(swells[0])))
	profile.set("mid_band", _make_band(float(swells[1])))
	profile.set("short_band", _make_band(float(swells[2])))
	return profile


func _make_band(swell: float) -> Resource:
	var band: Resource = BAND.new()
	band.set("swell", swell)
	return band


func _swell_values(profile: Resource, override: float) -> Array:
	var configs: Array = profile.build_fft_configs(-1.0, -1.0, -1000.0, override, 1.0)
	return [
		float(configs[0].get("swell")),
		float(configs[1].get("swell")),
		float(configs[2].get("swell")),
	]


func _values_match(actual: Array, expected: Array) -> bool:
	if actual.size() != expected.size():
		return false
	for index in actual.size():
		if not is_equal_approx(float(actual[index]), float(expected[index])):
			return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
