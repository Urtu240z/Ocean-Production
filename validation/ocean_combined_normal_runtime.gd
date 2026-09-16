extends SceneTree

const EPSILON: float = 0.00001
const FALLBACK_NORMAL := Vector3(0.0, 1.0, 0.0)

var _failed: bool = false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var shader_path := "res://addons/ocean/shaders/ocean_surface.gdshader"
	if not FileAccess.file_exists(shader_path):
		return _fail("Surface shader is missing")

	var shader_source := FileAccess.get_file_as_string(shader_path)
	if shader_source.is_empty():
		return _fail("Surface shader could not be read")

	var required_contract := [
		"vec3 safe_ocean_world_normal(vec3 candidate)",
		"any(isnan(candidate)) || any(isinf(candidate))",
		"float length_squared = dot(candidate, candidate);",
		"length_squared <= epsilon * epsilon",
		"vec3 mid_normal =",
		"vec3 short_normal =",
		"vec3 combined_normal_world =",
		"safe_ocean_world_normal(combined_normal_world)",
		"vec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);",
	]
	for contract_line in required_contract:
		if not shader_source.contains(contract_line):
			return _fail("Missing combined normal source contract: %s" % contract_line)

	if shader_source.contains("vec3 shading_normal_world = normalize(long_normal * long_weight"):
		return _fail("Direct normalization of the weighted normal sum remains authoritative")

	if not shader_source.contains("return vec3(0.0, 1.0, 0.0);"):
		return _fail("World-space flat fallback is missing")

	print("OCEAN_COMBINED_NORMAL_SOURCE_CONTRACT_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_valid_parity():
		return false
	print("OCEAN_COMBINED_NORMAL_VALID_PARITY_PASS")

	if not _check_zero_weight_fallback():
		return false
	print("OCEAN_COMBINED_NORMAL_ZERO_WEIGHT_FALLBACK_PASS")

	if not _check_near_zero_fallback():
		return false
	print("OCEAN_COMBINED_NORMAL_NEAR_ZERO_FALLBACK_PASS")

	if not _check_cancellation_fallback():
		return false
	print("OCEAN_COMBINED_NORMAL_CANCELLATION_PASS")

	if not _check_finite_contract():
		return false
	print("OCEAN_COMBINED_NORMAL_FINITE_PASS")

	return true


func _check_valid_parity() -> bool:
	var candidates := [
		Vector3(1.0, 2.0, 3.0),
		Vector3(-2.0, 0.5, 1.25),
		Vector3(0.0, 1.0, 0.0),
	]
	for candidate_value in candidates:
		var candidate: Vector3 = candidate_value
		var expected := candidate.normalized()
		var actual := _safe_normal_reference(candidate)
		if not _approximately_equal_vector(actual, expected):
			return _fail("Safe normal changed a valid candidate: %s" % candidate)
	return true


func _check_zero_weight_fallback() -> bool:
	var candidate := Vector3.ZERO
	var actual := _safe_normal_reference(candidate)
	if not _approximately_equal_vector(actual, FALLBACK_NORMAL):
		return _fail("Zero weighted sum did not use the flat world-space fallback")
	return true


func _check_near_zero_fallback() -> bool:
	var candidate := Vector3(1e-10, -1e-10, 1e-10)
	var actual := _safe_normal_reference(candidate)
	if not _approximately_equal_vector(actual, FALLBACK_NORMAL):
		return _fail("Near-zero weighted sum did not use the flat world-space fallback")
	return true


func _check_cancellation_fallback() -> bool:
	var long_contribution := Vector3(1.0, 0.0, 0.0)
	var mid_contribution := Vector3(-1.0, 0.0, 0.0)
	var short_contribution := Vector3.ZERO
	var candidate := long_contribution + mid_contribution + short_contribution
	var actual := _safe_normal_reference(candidate)
	if not _approximately_equal_vector(actual, FALLBACK_NORMAL):
		return _fail("Artificially cancelled contributions did not use the fallback")
	return true


func _check_finite_contract() -> bool:
	var candidates := [
		Vector3(NAN, 0.0, 1.0),
		Vector3(0.0, INF, 1.0),
	]
	for candidate_value in candidates:
		var candidate: Vector3 = candidate_value
		var actual := _safe_normal_reference(candidate)
		if not actual.is_finite() or not _approximately_equal_vector(actual, FALLBACK_NORMAL):
			return _fail("Non-finite candidate escaped the safe normal contract")
	return true


func _safe_normal_reference(candidate: Vector3) -> Vector3:
	if not candidate.is_finite():
		return FALLBACK_NORMAL
	var length_squared := candidate.length_squared()
	if not is_finite(length_squared) or length_squared <= EPSILON * EPSILON:
		return FALLBACK_NORMAL
	return candidate.normalized()


func _approximately_equal_vector(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_COMBINED_NORMAL_FAIL: %s" % reason)
	return false
