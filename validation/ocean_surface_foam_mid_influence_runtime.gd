extends SceneTree

const EPSILON: float = 0.000001

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
		"float mid_influence = clamp(surface_foam_mid_fold_influence, 0.0, 1.0);",
		"float mid_gate = mix(1.0, mid_eligibility, mid_influence);",
		"mask *= mid_gate;",
	]
	for contract_line in required_contract:
		if not shader_source.contains(contract_line):
			return _fail("Missing MID influence source contract: %s" % contract_line)

	if shader_source.contains("mid_eligibility * clamp(surface_foam_mid_fold_influence"):
		return _fail("The old multiplicative MID influence contract is still authoritative")

	if not shader_source.contains("uniform float surface_foam_mid_fold_influence = 0.0;"):
		return _fail("The Surface Foam MID influence default was changed")

	print("OCEAN_SURFACE_FOAM_MID_SOURCE_CONTRACT_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_full_influence_parity():
		return false
	print("OCEAN_SURFACE_FOAM_MID_FULL_INFLUENCE_PARITY_PASS")

	if not _check_zero_influence():
		return false
	print("OCEAN_SURFACE_FOAM_MID_ZERO_INFLUENCE_PASS")

	if not _check_required_blends():
		return false
	print("OCEAN_SURFACE_FOAM_MID_BLEND_CONTRACT_PASS")

	if not _check_monotonicity():
		return false
	print("OCEAN_SURFACE_FOAM_MID_MONOTONICITY_PASS")

	return true


func _check_full_influence_parity() -> bool:
	var eligibilities := [0.0, 0.2, 0.5, 0.8, 1.0]
	for eligibility_value in eligibilities:
		var eligibility := float(eligibility_value)
		if not _approximately_equal(_mid_gate_reference(eligibility, 1.0), eligibility):
			return _fail("Full influence changed MID eligibility for %f" % eligibility)
	return true


func _check_zero_influence() -> bool:
	var eligibilities := [0.0, 0.2, 0.5, 0.8, 1.0]
	for eligibility_value in eligibilities:
		var eligibility := float(eligibility_value)
		if not _approximately_equal(_mid_gate_reference(eligibility, 0.0), 1.0):
			return _fail("Zero influence did not preserve the base Surface Foam mask")
	return true


func _check_required_blends() -> bool:
	var expected_for_point_two := [1.0, 0.8, 0.6, 0.4, 0.2]
	var required_influences := [0.0, 0.25, 0.5, 0.75, 1.0]
	for index in required_influences.size():
		var influence := float(required_influences[index])
		var expected := float(expected_for_point_two[index])
		var actual := _mid_gate_reference(0.2, influence)
		if not _approximately_equal(actual, expected):
			return _fail("Eligibility 0.2 produced %f at influence %f; expected %f" % [actual, influence, expected])

	var eligibilities := [0.0, 0.2, 0.5, 0.8, 1.0]
	var intermediate_influences := [0.25, 0.5, 0.75]
	for eligibility_value in eligibilities:
		var eligibility := float(eligibility_value)
		for influence_value in intermediate_influences:
			var influence := float(influence_value)
			var expected := 1.0 + (eligibility - 1.0) * influence
			if not _approximately_equal(_mid_gate_reference(eligibility, influence), expected):
				return _fail("Blend contract mismatch for eligibility %f and influence %f" % [eligibility, influence])

	for influence_value in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var influence := float(influence_value)
		if not _approximately_equal(_mid_gate_reference(1.0, influence), 1.0):
			return _fail("Eligibility 1.0 was not neutral at influence %f" % influence)
	return true


func _check_monotonicity() -> bool:
	var eligibilities := [0.0, 0.1, 0.25, 0.5, 0.75]
	var ordered_influences := [0.0, 0.25, 0.5, 0.75, 1.0]
	for eligibility_value in eligibilities:
		var eligibility := float(eligibility_value)
		var previous_gate := _mid_gate_reference(eligibility, float(ordered_influences[0]))
		for influence_index in range(1, ordered_influences.size()):
			var influence := float(ordered_influences[influence_index])
			var gate := _mid_gate_reference(eligibility, influence)
			if gate > previous_gate + EPSILON:
				return _fail("Increasing influence increased the gate for eligibility %f" % eligibility)
			previous_gate = gate
	return true


func _mid_gate_reference(eligibility: float, influence: float) -> float:
	var clamped_influence := clampf(influence, 0.0, 1.0)
	return 1.0 + (eligibility - 1.0) * clamped_influence


func _approximately_equal(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_SURFACE_FOAM_MID_INFLUENCE_FAIL: %s" % reason)
	return false
