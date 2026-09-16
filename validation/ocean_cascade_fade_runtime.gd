extends SceneTree

const FADE_EPSILON: float = 0.001
const TEST_EPSILON: float = 0.000001

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
		"float start_m = range_m.x;",
		"float end_m = max(range_m.y, start_m + 0.001);",
		"return 1.0 - smoothstep(start_m, end_m, distance_m);",
	]
	for contract_line in required_contract:
		if not shader_source.contains(contract_line):
			return _fail("Missing cascade fade source contract: %s" % contract_line)

	if shader_source.contains("smoothstep(range_m.x, range_m.y, distance_m)"):
		return _fail("The unsanitized fade helper remains authoritative")

	print("OCEAN_CASCADE_FADE_SOURCE_CONTRACT_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_valid_parity():
		return false
	print("OCEAN_CASCADE_FADE_VALID_PARITY_PASS")

	if not _check_zero_width():
		return false
	print("OCEAN_CASCADE_FADE_ZERO_WIDTH_PASS")

	if not _check_inverted_range():
		return false
	print("OCEAN_CASCADE_FADE_INVERTED_RANGE_PASS")

	if not _check_bounds():
		return false
	print("OCEAN_CASCADE_FADE_BOUNDS_PASS")

	if not _check_monotonicity():
		return false
	print("OCEAN_CASCADE_FADE_MONOTONICITY_PASS")

	return true


func _check_valid_parity() -> bool:
	var start_m := 10.0
	var end_m := 20.0
	var distances := [0.0, 10.0, 15.0, 20.0, 30.0]
	var expected := [1.0, 1.0, 0.5, 0.0, 0.0]
	for index in distances.size():
		var actual := _fade_weight_reference(float(distances[index]), start_m, end_m)
		if not _approximately_equal(actual, float(expected[index])):
			return _fail("Valid range parity mismatch at distance %f: %f" % [float(distances[index]), actual])

	var parity_distances := [-50.0, 5.0, 12.5, 19.9, 100.0]
	for distance_value in parity_distances:
		var distance_m := float(distance_value)
		var baseline := 1.0 - _smoothstep(start_m, end_m, distance_m)
		var actual := _fade_weight_reference(distance_m, start_m, end_m)
		if not _approximately_equal(actual, baseline):
			return _fail("Sanitized helper changed a valid range at distance %f" % distance_m)
	return true


func _check_zero_width() -> bool:
	var start_m := 20.0
	var safe_end := maxf(start_m, start_m + FADE_EPSILON)
	var distances := [19.0, 20.0, 20.0005, 20.001, 21.0]
	for distance_value in distances:
		var distance_m := float(distance_value)
		var actual := _fade_weight_reference(distance_m, start_m, start_m)
		var expected := 1.0 - _smoothstep(start_m, safe_end, distance_m)
		if not _approximately_equal(actual, expected) or not is_finite(actual):
			return _fail("Zero-width range was not sanitized to start=20 end=20.001")
	return true


func _check_inverted_range() -> bool:
	var start_m := 20.0
	var requested_end := 10.0
	var safe_end := maxf(requested_end, start_m + FADE_EPSILON)
	if not _approximately_equal(safe_end, 20.001):
		return _fail("Inverted range did not preserve range.x as the start authority")

	var distances := [15.0, 20.0, 20.0005, 20.001, 25.0]
	for distance_value in distances:
		var distance_m := float(distance_value)
		var actual := _fade_weight_reference(distance_m, start_m, requested_end)
		var expected := 1.0 - _smoothstep(start_m, safe_end, distance_m)
		if not _approximately_equal(actual, expected):
			return _fail("Inverted range did not use the sanitized forward fade")
	if not _approximately_equal(_fade_weight_reference(15.0, start_m, requested_end), 1.0):
		return _fail("Inverted range appears to have swapped start and end")
	return true


func _check_bounds() -> bool:
	var ranges := [
		Vector2(10.0, 20.0),
		Vector2(20.0, 20.0),
		Vector2(20.0, 10.0),
		Vector2(-100.0, -50.0),
	]
	var distances := [-100000.0, -1.0, 0.0, 10.0, 20.0, 20.0005, 100000.0]
	for range_value in ranges:
		var fade_range: Vector2 = range_value
		for distance_value in distances:
			var weight := _fade_weight_reference(float(distance_value), fade_range.x, fade_range.y)
			if not is_finite(weight) or weight < -TEST_EPSILON or weight > 1.0 + TEST_EPSILON:
				return _fail("Fade weight escaped [0,1] for range %s" % fade_range)
	return true


func _check_monotonicity() -> bool:
	var ranges := [
		Vector2(10.0, 20.0),
		Vector2(20.0, 20.0),
		Vector2(20.0, 10.0),
		Vector2(-5.0, 3.0),
	]
	var distances := [-10.0, 0.0, 10.0, 19.0, 20.0, 20.0005, 21.0, 100.0]
	for range_value in ranges:
		var fade_range: Vector2 = range_value
		var previous := _fade_weight_reference(float(distances[0]), fade_range.x, fade_range.y)
		for index in range(1, distances.size()):
			var current := _fade_weight_reference(float(distances[index]), fade_range.x, fade_range.y)
			if current > previous + TEST_EPSILON:
				return _fail("Fade weight increased with distance for range %s" % fade_range)
			previous = current
	return true


func _fade_weight_reference(distance_m: float, start_m: float, end_m: float) -> float:
	var safe_end := maxf(end_m, start_m + FADE_EPSILON)
	return 1.0 - _smoothstep(start_m, safe_end, distance_m)


func _smoothstep(edge_start: float, edge_end: float, value: float) -> float:
	var t := clampf((value - edge_start) / (edge_end - edge_start), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _approximately_equal(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= TEST_EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_CASCADE_FADE_FAIL: %s" % reason)
	return false
