extends Node
## H4.19 validates the published Sunray distance against the real world-slice
## integration contract without reimplementing the shader's beam math.

const PROFILE_SCRIPT := preload("res://addons/ocean/underwater/sunrays/ocean_underwater_sunray_profile.gd")
const PROFILE_SOURCE_PATH := "res://addons/ocean/underwater/sunrays/ocean_underwater_sunray_profile.gd"
const SHADER_SOURCE_PATH := "res://addons/ocean/underwater/shaders/ocean_underwater_medium.glsl.source"
const TEST_PHASES := [0.0, 0.001, 3.5, 7.0, 13.999, -0.001, -7.0, -13.999]
const TEST_LENGTHS := [1.0, 14.0, 15.0, 30.0, 42.0, 56.0, 57.0, 70.0, 84.0, 98.0, 99.0, 100.0]


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var profile: Resource = PROFILE_SCRIPT.new()
	var profile_source: String = _read(PROFILE_SOURCE_PATH)
	var shader_source: String = _read(SHADER_SOURCE_PATH)
	var spacing: float = _extract_float_constant(shader_source, "SUNRAY_WORLD_SLICE_SPACING_M")
	var max_slices: int = _extract_int_constant(shader_source, "SUNRAY_MAX_WORLD_SLICES")
	var max_distance: float = 0.0
	if not _check_profile_contract(profile, profile_source):
		_fail("Sunray profile does not publish the required 1..100 m contract")
		return
	print("OCEAN_SUNRAY_PROFILE_DISTANCE_CONTRACT_PASS")
	if not _check_source_contract(shader_source, spacing, max_slices):
		_fail("Sunray slice source contract is incomplete")
		return
	print("OCEAN_SUNRAY_SLICE_SOURCE_CONTRACT_PASS")
	max_distance = float(profile.max_distance_m)
	if not _check_distance_coverage(max_distance, spacing, max_slices):
		_fail("Published maximum distance is not covered")
		return
	print("OCEAN_SUNRAY_PROFILE_DISTANCE_COVERAGE_PASS")
	if not _check_worst_phase_bound(spacing, max_slices):
		_fail("Worst-phase slice count exceeded the compile-time bound")
		return
	print("OCEAN_SUNRAY_WORST_PHASE_SLICE_BOUND_PASS")
	if not _check_old_bound_was_insufficient(spacing):
		_fail("The old four-slice bound was not demonstrated as insufficient")
		return
	print("OCEAN_SUNRAY_OLD_BOUND_WAS_INSUFFICIENT_PASS")
	if not _check_default_compatibility(spacing, max_slices):
		_fail("The 30 m default changed its effective slice IDs")
		return
	print("OCEAN_SUNRAY_DEFAULT_SLICE_COMPAT_PASS")
	if not _check_long_distance_coverage(spacing, max_slices, max_distance):
		_fail("The 100 m route does not cover all required slice IDs")
		return
	print("OCEAN_SUNRAY_LONG_DISTANCE_COVERAGE_PASS")
	if not _check_early_exit_contract(shader_source):
		_fail("The early exit contract is missing")
		return
	print("OCEAN_SUNRAY_EARLY_EXIT_CONTRACT_PASS")
	get_tree().quit(0)


func _check_profile_contract(profile: Resource, profile_source: String) -> bool:
	if not is_equal_approx(float(profile.max_distance_m), 30.0):
		return false
	profile.max_distance_m = 100.0
	if not is_equal_approx(float(profile.max_distance_m), 100.0):
		return false
	if not profile_source.contains("@export_range(1.0, 100.0, 1.0, \"suffix: m\") var max_distance_m"):
		return false
	for entry in profile.get_property_list():
		if StringName(entry.get("name", "")) != &"max_distance_m":
			continue
		return int(entry.get("hint", 0)) == PROPERTY_HINT_RANGE
	return false


func _check_source_contract(shader_source: String, spacing: float, max_slices: int) -> bool:
	if not is_equal_approx(spacing, 14.0) or max_slices != 9:
		return false
	if shader_source.contains("slice_offset < 4"):
		return false
	if not shader_source.contains("slice_offset < SUNRAY_MAX_WORLD_SLICES"):
		return false
	for function_name in [
		"sunray_phase_response(", "sunray_beam_coord(", "sunray_wave_focus(",
		"sunray_wave_modulation(", "sunray_beam_field(", "sunray_reach_factor("
	]:
		if not shader_source.contains(function_name):
			return false
	return true


func _check_distance_coverage(max_distance: float, spacing: float, max_slices: int) -> bool:
	return (float(max_slices) - 1.0) * spacing >= max_distance


func _check_worst_phase_bound(spacing: float, max_slices: int) -> bool:
	for phase in TEST_PHASES:
		for length_m in TEST_LENGTHS:
			if _required_slice_count(phase, phase + length_m, spacing) > max_slices:
				return false
	return true


func _check_old_bound_was_insufficient(spacing: float) -> bool:
	for phase in TEST_PHASES:
		for length_m in TEST_LENGTHS:
			if _required_slice_count(phase, phase + length_m, spacing) > 4:
				return true
	return false


func _check_default_compatibility(spacing: float, max_slices: int) -> bool:
	for phase in TEST_PHASES:
		var first: int = _slice_id(phase, spacing)
		var last: int = _slice_id(phase + 30.0, spacing)
		var required: int = last - first + 1
		if required > 4 or required > max_slices:
			return false
		if _slice_ids(phase, phase + 30.0, spacing, 4) != _slice_ids(phase, phase + 30.0, spacing, max_slices):
			return false
	return true


func _check_long_distance_coverage(spacing: float, max_slices: int, max_distance: float) -> bool:
	for phase in TEST_PHASES:
		var first: int = _slice_id(phase, spacing)
		var last: int = _slice_id(phase + max_distance, spacing)
		var ids: Array[int] = _slice_ids(phase, phase + max_distance, spacing, max_slices)
		if ids.size() != last - first + 1 or ids.front() != first or ids.back() != last:
			return false
	return true


func _check_early_exit_contract(shader_source: String) -> bool:
	return shader_source.contains("if (slice_id > last_slice_id) break;")


func _required_slice_count(longitudinal_begin: float, longitudinal_end: float, spacing: float) -> int:
	return _slice_id(maxf(longitudinal_begin, longitudinal_end), spacing) \
		- _slice_id(minf(longitudinal_begin, longitudinal_end), spacing) + 1


func _slice_id(longitudinal: float, spacing: float) -> int:
	return int(floor(longitudinal / spacing))


func _slice_ids(longitudinal_begin: float, longitudinal_end: float, spacing: float, bound: int) -> Array[int]:
	var first: int = _slice_id(minf(longitudinal_begin, longitudinal_end), spacing)
	var last: int = _slice_id(maxf(longitudinal_begin, longitudinal_end), spacing)
	var ids: Array[int] = []
	for slice_offset in bound:
		var slice_id: int = first + slice_offset
		if slice_id > last:
			break
		ids.append(slice_id)
	return ids


func _extract_float_constant(source: String, constant_name: String) -> float:
	var regex := RegEx.new()
	regex.compile("const\\s+float\\s+" + constant_name + "\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)")
	var match: RegExMatch = regex.search(source)
	return float(match.get_string(1)) if match != null else NAN


func _extract_int_constant(source: String, constant_name: String) -> int:
	var regex := RegEx.new()
	regex.compile("const\\s+int\\s+" + constant_name + "\\s*=\\s*([0-9]+)")
	var match: RegExMatch = regex.search(source)
	return int(match.get_string(1)) if match != null else -1


func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	push_error("OCEAN_SUNRAY_SLICE_CONTRACT_FAIL: " + message)
	get_tree().quit(1)
