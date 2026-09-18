extends SceneTree

const EPSILON: float = 0.00001
const TEST_EPSILON: float = 0.000001

var _failed: bool = false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var shader_path := "res://addons/ocean/shaders/fft/update_crest_foam.glsl"
	var spindrift_path := "res://addons/ocean/spindrift/ocean_spindrift_v4.gd"
	var surface_path := "res://addons/ocean/shaders/ocean_surface.gdshader"
	for path in [shader_path, spindrift_path, surface_path]:
		if not FileAccess.file_exists(path):
			return _fail("Required source file is missing: %s" % path)

	var shader_source := FileAccess.get_file_as_string(shader_path)
	var spindrift_source := FileAccess.get_file_as_string(spindrift_path)
	var surface_source := FileAccess.get_file_as_string(surface_path)
	var required_contract := [
		"float whitecap = max(params.fresh.x, 0.0);",
		"float compression = max(0.0, whitecap - jacobian);",
		"float normalization_span = max(whitecap, 0.00001);",
		"float normalized_source = clamp(compression / normalization_span, 0.0, 1.0);",
		"layout(set = 0, binding = 4) uniform sampler2D legacy_fresh_previous;",
		"layout(r16f, set = 0, binding = 5) uniform restrict writeonly image2D legacy_fresh_next;",
		"float previous_legacy_fresh = textureLod(legacy_fresh_previous, backtrace_uv, 0.0).r;",
		"float residual_target = clamp(compression * max(params.fresh.z, 0.0), 0.0, 1.0);",
		"float legacy_fresh = mix(previous_legacy_fresh, residual_target, temporal_factor);",
		"float breaking_activity = whitecap > 0.00001 ? clamp(legacy_fresh / normalization_span, 0.0, 1.0) : 0.0;",
		"imageStore(legacy_fresh_next, coord, vec4(legacy_fresh, 0.0, 0.0, 0.0));",
	]
	for contract_line in required_contract:
		if not shader_source.contains(contract_line):
			return _fail("Missing Crest activity source contract: %s" % contract_line)

	if shader_source.contains("previous_residual_scale_fresh") or shader_source.contains("previous.g * normalization_span"):
		return _fail("Lossy reconstruction of legacy fresh from public G remains authoritative")
	if not shader_source.contains("float fresh_rate = residual_target > previous_legacy_fresh ? max(params.fresh.y, 0.0) : fresh_release_rate;"):
		return _fail("Fresh attack/release no longer uses private legacy history")
	if not shader_source.contains("vec4(clamp(residual, 0.0, 1.0), breaking_activity, 0.0, 1.0)"):
		return _fail("G is not published as normalized breaking activity")
	if not shader_source.contains("imageStore(legacy_fresh_next"):
		return _fail("Private legacy fresh history is not written")
	var solver_source := FileAccess.get_file_as_string("res://addons/ocean/fft/gpu_stockham_fft.gd")
	if not solver_source.contains("var _crest_legacy_fresh: Array[RID] = [RID(), RID()]") or not solver_source.contains("RenderingDevice.DATA_FORMAT_R16_SFLOAT"):
		return _fail("Private R16F legacy fresh ping-pong is missing")
	if not solver_source.contains("_sampler_uniform(4, previous_legacy_fresh)") or not solver_source.contains("legacy_output.binding = 5"):
		return _fail("Private legacy fresh bindings are not wired")
	if not solver_source.contains("\"crest_legacy_fresh_history\""):
		return _fail("Private legacy fresh resource state is not diagnosable")
	if not spindrift_source.contains("breaking_activity_authority") or not spindrift_source.contains("crest_g_long"):
		return _fail("Spindrift breaking activity authority changed")
	if not surface_source.contains("texture(crest_foam_long") or not surface_source.contains(".r * long_weight"):
		return _fail("Crest presentation no longer reads residual R")

	print("OCEAN_SPINDRIFT_BREAKING_API_CONTRACT_PASS")
	print("OCEAN_CREST_ACTIVITY_SOURCE_CONTRACT_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_zero_threshold_safety():
		return false
	print("OCEAN_BREAKING_ACTIVITY_ZERO_THRESHOLD_SAFE_PASS")

	if not _check_residual_scale_parity():
		return false
	print("OCEAN_CREST_RESIDUAL_SCALE_PARITY_PASS")

	if not _check_normalization():
		return false
	print("OCEAN_BREAKING_ACTIVITY_NORMALIZATION_PASS")

	if not _check_threshold_invariance():
		return false
	print("OCEAN_BREAKING_ACTIVITY_THRESHOLD_INVARIANCE_PASS")

	if not _check_monotonicity():
		return false
	print("OCEAN_BREAKING_ACTIVITY_MONOTONICITY_PASS")

	if not _check_bounds():
		return false
	print("OCEAN_BREAKING_ACTIVITY_BOUNDS_PASS")

	if not _check_saturated_attack_history():
		return false
	print("OCEAN_CREST_LEGACY_FRESH_SATURATED_HISTORY_PASS")

	if not _check_saturated_release_history():
		return false
	print("OCEAN_CREST_LEGACY_FRESH_SATURATED_RELEASE_PASS")

	if not _check_negative_j_parity():
		return false
	print("OCEAN_CREST_RESIDUAL_NEGATIVE_J_PARITY_PASS")

	if not _check_weight_parity():
		return false
	print("OCEAN_CREST_RESIDUAL_WEIGHT_PARITY_PASS")

	print("OCEAN_BREAKING_ACTIVITY_VALIDATOR_PASS")
	return true


func _check_zero_threshold_safety() -> bool:
	var result := _breaking_activity_reference(0.0, -1.0, 1.0)
	if not is_finite(result) or not _approximately_equal(result, 0.0):
		return _fail("Zero whitecap threshold produced a non-zero or non-finite activity")
	return true


func _check_residual_scale_parity() -> bool:
	var thresholds := [0.4, 0.62, 0.8]
	var fractions := [1.0, 0.75, 0.5, 0.25, 0.0]
	for threshold_value in thresholds:
		var threshold := float(threshold_value)
		for fraction_value in fractions:
			var fraction: float = float(fraction_value)
			var jacobian: float = threshold * fraction
			var old_source: float = maxf(0.0, threshold - jacobian)
			var new_residual_target: float = _residual_target_reference(threshold, jacobian, 1.0)
			if not _approximately_equal(new_residual_target, clampf(old_source, 0.0, 1.0)):
				return _fail("Residual scale parity failed for threshold %f fraction %f" % [threshold, fraction])

			var previous_legacy_fresh: float = threshold * 0.3
			var previous_breaking: float = previous_legacy_fresh / threshold
			var reconstructed_previous: float = previous_breaking * threshold
			for temporal_factor_value in [0.0, 0.25, 0.5, 1.0]:
				var temporal_factor: float = float(temporal_factor_value)
				var old_legacy_fresh: float = lerpf(previous_legacy_fresh, clampf(old_source, 0.0, 1.0), temporal_factor)
				var new_legacy_fresh: float = lerpf(reconstructed_previous, new_residual_target, temporal_factor)
				if not _approximately_equal(new_legacy_fresh, old_legacy_fresh):
					return _fail("Temporal residual scale parity failed for threshold %f fraction %f" % [threshold, fraction])
	return true


func _check_normalization() -> bool:
	var thresholds := [0.4, 0.62, 0.8]
	for threshold_value in thresholds:
		var threshold := float(threshold_value)
		var expected_values := [0.0, 0.5, 1.0]
		var fractions := [1.0, 0.5, 0.0]
		for index in fractions.size():
			var jacobian := threshold * float(fractions[index])
			var activity := _breaking_activity_reference(threshold, jacobian, 1.0)
			if not _approximately_equal(activity, float(expected_values[index])):
				return _fail("Normalization failed for threshold %f at fraction %f" % [threshold, float(fractions[index])])
	return true


func _check_threshold_invariance() -> bool:
	for threshold in [0.4, 0.8]:
		var activity := _breaking_activity_reference(float(threshold), float(threshold) * 0.5, 1.0)
		if not _approximately_equal(activity, 0.5):
			return _fail("Relative compression was not threshold-invariant for %f" % float(threshold))
	return true


func _check_monotonicity() -> bool:
	var threshold := 0.62
	var jacobians := [0.62, 0.5, 0.4, 0.3, 0.2, 0.1, 0.0]
	var previous := _breaking_activity_reference(threshold, float(jacobians[0]), 1.0)
	for index in range(1, jacobians.size()):
		var current := _breaking_activity_reference(threshold, float(jacobians[index]), 1.0)
		if current + TEST_EPSILON < previous:
			return _fail("Breaking Activity decreased as Jacobian decreased")
		previous = current
	return true


func _check_bounds() -> bool:
	var thresholds := [0.0, 0.000001, 0.4, 0.62, 0.8]
	var jacobians := [-100.0, -1.0, 0.0, 0.4, 1.0, 100.0]
	var weights := [0.0, 1.0, 2.0, 100.0]
	for threshold_value in thresholds:
		var threshold := float(threshold_value)
		for jacobian_value in jacobians:
			var jacobian := float(jacobian_value)
			for weight_value in weights:
				var activity := _breaking_activity_reference(threshold, jacobian, float(weight_value))
				if not is_finite(activity) or activity < -TEST_EPSILON or activity > 1.0 + TEST_EPSILON:
					return _fail("Breaking Activity escaped [0,1]")
	return true


func _check_saturated_attack_history() -> bool:
	var previous_legacy_fresh := 0.80
	var residual_target := 0.90
	var attack_rate := 2.0
	var release_rate := 0.5
	var delta_s := 0.25
	var actual := _legacy_fresh_reference(previous_legacy_fresh, residual_target, attack_rate, release_rate, delta_s)
	var expected := lerpf(previous_legacy_fresh, residual_target, 1.0 - exp(-attack_rate * delta_s))
	var lossy_previous := 0.62
	var lossy_rate := release_rate
	var lossy_result := lerpf(lossy_previous, residual_target, 1.0 - exp(-lossy_rate * delta_s))
	if not _approximately_equal(actual, expected) or _approximately_equal(actual, lossy_result):
		return _fail("Saturated legacy history did not preserve 0.80 and select ATTACK")
	return true


func _check_saturated_release_history() -> bool:
	var previous_legacy_fresh := 0.90
	var residual_target := 0.75
	var attack_rate := 2.0
	var release_rate := 0.5
	var delta_s := 0.25
	var actual := _legacy_fresh_reference(previous_legacy_fresh, residual_target, attack_rate, release_rate, delta_s)
	var expected := lerpf(previous_legacy_fresh, residual_target, 1.0 - exp(-release_rate * delta_s))
	if not _approximately_equal(actual, expected):
		return _fail("Saturated legacy history did not select RELEASE")
	return true


func _check_negative_j_parity() -> bool:
	var threshold := 0.62
	var previous_legacy_fresh := 0.30
	var jacobians := [0.62, 0.31, 0.0, -0.10, -0.30, -1.0]
	for jacobian_value in jacobians:
		var jacobian := float(jacobian_value)
		var old_target := clampf(maxf(0.0, threshold - jacobian), 0.0, 1.0)
		var new_target := _residual_target_reference(threshold, jacobian, 1.0)
		var old_fresh := _legacy_fresh_reference(previous_legacy_fresh, old_target, 1.0, 0.5, 0.25)
		var new_fresh := _legacy_fresh_reference(previous_legacy_fresh, new_target, 1.0, 0.5, 0.25)
		if not _approximately_equal(new_target, old_target) or not _approximately_equal(new_fresh, old_fresh):
			return _fail("Negative Jacobian residual parity failed at %f" % jacobian)
	return true


func _check_weight_parity() -> bool:
	var threshold := 0.62
	for weight_value in [1.0, 1.5, 2.0, 4.0]:
		var weight := float(weight_value)
		for jacobian in [0.31, -0.30]:
			var old_target := clampf(maxf(0.0, threshold - float(jacobian)) * weight, 0.0, 1.0)
			var new_target := _residual_target_reference(threshold, float(jacobian), weight)
			if not _approximately_equal(new_target, old_target):
				return _fail("Residual weight parity failed for weight %f" % weight)
	return true


func _residual_target_reference(whitecap: float, jacobian: float, weight: float) -> float:
	var compression := maxf(0.0, maxf(whitecap, 0.0) - jacobian)
	return clampf(compression * maxf(weight, 0.0), 0.0, 1.0)


func _legacy_fresh_reference(previous: float, target: float, attack_rate: float, release_rate: float, delta_s: float) -> float:
	var rate := attack_rate if target > previous else release_rate
	return lerpf(previous, target, 1.0 - exp(-rate * delta_s))


func _breaking_activity_reference(whitecap_input: float, jacobian: float, weight: float) -> float:
	var whitecap := maxf(whitecap_input, 0.0)
	var compression := maxf(0.0, whitecap - jacobian)
	var normalization_span := maxf(whitecap, EPSILON)
	var normalized_source := clampf(compression / normalization_span, 0.0, 1.0)
	var breaking_target := clampf(normalized_source * maxf(weight, 0.0), 0.0, 1.0)
	if whitecap <= EPSILON:
		return 0.0
	return breaking_target


func _approximately_equal(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= TEST_EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_BREAKING_ACTIVITY_FAIL: %s" % reason)
	return false
