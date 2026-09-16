extends SceneTree

const TEST_EPSILON: float = 0.000001

var _failed: bool = false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var sources := {
		"open": "res://addons/ocean/fft/open_ocean_fft.gd",
		"medium": "res://addons/ocean/underwater/ocean_underwater_medium.gd",
		"effect": "res://addons/ocean/underwater/ocean_underwater_medium_effect.gd",
		"bubbles": "res://addons/ocean/underwater/bubbles/ocean_underwater_bubbles.gd",
		"profile": "res://addons/ocean/underwater/bubbles/ocean_underwater_bubble_profile.gd",
		"update": "res://addons/ocean/underwater/bubbles/shaders/ocean_underwater_bubbles_update.glsl",
		"debug": "res://addons/ocean/underwater/shaders/ocean_underwater_medium_bubbles.inc",
		"spindrift": "res://addons/ocean/spindrift/ocean_spindrift_v4.gd",
	}
	var code := {}
	for key in sources:
		var path: String = sources[key]
		if not FileAccess.file_exists(path):
			return _fail("Missing H4.6 source: %s" % path)
		code[key] = FileAccess.get_file_as_string(path)

	var open_source: String = code["open"]
	var medium_source: String = code["medium"]
	var effect_source: String = code["effect"]
	var bubbles_source: String = code["bubbles"]
	var profile_source: String = code["profile"]
	var update_source: String = code["update"]
	var debug_source: String = code["debug"]
	var spindrift_source: String = code["spindrift"]

	for contract_line in [
		"\"breaking_activity_long\": _crest_foam_textures[0].texture_rd_rid",
		"\"breaking_activity_channel\": 1",
		"\"breaking_activity_range\": Vector2(0.0, 1.0)",
		"\"breaking_activity_generation\": _published_generation",
	]:
		if not open_source.contains(contract_line):
			return _fail("OpenOceanBreakingActivity publication contract missing: %s" % contract_line)

	for contract_line in [
		"var _published_source_signature: Array[RID] = []",
		"sources.get(\"breaking_activity_long\", RID())",
		"signature != _published_source_signature",
		"_effect.set_raster_sources(sources)",
		"_published_source_signature.clear()",
	]:
		if not medium_source.contains(contract_line):
			return _fail("Dynamic underwater source signature contract missing: %s" % contract_line)

	if medium_source.contains("_bubble_crest_profile") or medium_source.contains("crest_profile: OceanCrestFoamProfile"):
		return _fail("Underwater Bubbles still depends on Crest profile detector settings")
	if not effect_source.contains("[\"long\", \"mid\", \"short\", \"breaking_activity_long\"]") or not effect_source.contains("_sources = sources.duplicate()"):
		return _fail("Effect source packet does not preserve Crest G under the mutex")

	for contract_line in [
		"layout(set = 0, binding = 6) uniform sampler2D breaking_activity_long;",
		"float breaking_activity_at(vec2 q)",
		"textureLod(breaking_activity_long, q / max(params.domains.x, 0.001) + vec2(0.5), 0.0).g",
		"float shape_breaking_for_injection(float raw_activity, float start_threshold, float full_threshold)",
		"float raw_breaking = breaking_activity_at(q);",
		"breaking_source = shape_breaking_for_injection(raw_breaking, params.breaking_gate.x, params.breaking_gate.y);",
	]:
		if not update_source.contains(contract_line):
			return _fail("Bubble compute Crest G contract missing: %s" % contract_line)

	for contract_line in [
		"layout(set = 0, binding = 13) uniform sampler2D bubble_breaking_activity_long;",
		"textureLod(bubble_breaking_activity_long, q / max(bubbles.domains.x, 0.001) + vec2(0.5), 0.0).g",
		"float bubble_shape_breaking_for_injection(float raw_activity, float start_threshold, float full_threshold)",
		"float raw_breaking = textureLod(bubble_breaking_activity_long",
		"bubble_shape_breaking_for_injection(raw_breaking, bubbles.breaking_gate.x, bubbles.breaking_gate.y)",
	]:
		if not debug_source.contains(contract_line):
			return _fail("Bubble debug Crest G contract missing: %s" % contract_line)

	if update_source.contains("source_thresholds") or update_source.contains("source_weights") or update_source.contains("params.source_thresholds") or update_source.contains("sample_long.w") or update_source.contains("sample_mid.w") or update_source.contains("sample_short.w"):
		return _fail("Bubble compute still contains the duplicate Jacobian detector")
	if debug_source.contains("source_thresholds") or debug_source.contains("source_weights") or debug_source.contains("sample_long.w"):
		return _fail("Bubble debug still contains the duplicate Jacobian detector")
	if not bubbles_source.contains("breaking_activity_rid") or not bubbles_source.contains("_surface_sampler, breaking_activity_rid") or not bubbles_source.contains("breaking_activity_long"):
		return _fail("Bubble controller does not bind or validate Crest G")
	for contract_line in [
		"var breaking_injection_start := 0.45",
		"var breaking_injection_full := 0.75",
	]:
		if not profile_source.contains(contract_line):
			return _fail("Breaking injection gate authoring packet is incomplete: %s" % contract_line)
	for contract_line in [
		"\"breaking_injection_start\": profile.breaking_injection_start if profile != null else 0.45",
		"\"breaking_injection_full\": profile.breaking_injection_full if profile != null else 0.75",
		"breaking_injection_start, breaking_injection_full, 0.0, 0.0",
	]:
		if contract_line.begins_with("\"") and not medium_source.contains(contract_line):
			return _fail("Breaking injection gate packet publication is incomplete: %s" % contract_line)
		if not contract_line.begins_with("\"") and not bubbles_source.contains(contract_line):
			return _fail("Breaking injection gate packet publication is incomplete: %s" % contract_line)
	if not profile_source.contains("set(value): breaking_injection_start = clampf(value, 0.0, 1.0); emit_changed()") or not profile_source.contains("set(value): breaking_injection_full = clampf(value, 0.0, 1.0); emit_changed()"):
		return _fail("Breaking injection gate sliders do not emit Resource.changed")
	if not spindrift_source.contains("crest_g_long"):
		return _fail("Spindrift no longer declares Crest LONG.G authority")

	print("OCEAN_BUBBLES_NO_DUPLICATE_BREAKING_DETECTOR_PASS")
	print("OCEAN_BUBBLES_DEBUG_SOURCE_PARITY_PASS")
	print("OCEAN_BUBBLES_INJECTION_DEBUG_GATE_PARITY_PASS")
	print("OCEAN_BUBBLES_BREAKING_GATE_RUNTIME_AUTHORING_PASS")
	print("OCEAN_SHARED_BREAKING_ACTIVITY_AUTHORITY_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_gate_below_start():
		return false
	print("OCEAN_BUBBLES_BREAKING_GATE_BELOW_START_PASS")

	if not _check_gate_full():
		return false
	print("OCEAN_BUBBLES_BREAKING_GATE_FULL_PASS")

	if not _check_gate_monotonicity():
		return false
	print("OCEAN_BUBBLES_BREAKING_GATE_MONOTONICITY_PASS")

	if not _check_gate_shape():
		return false
	print("OCEAN_BUBBLES_BREAKING_GATE_SHAPE_PASS")

	if not _check_gate_invalid_range():
		return false
	print("OCEAN_BUBBLES_BREAKING_GATE_INVALID_RANGE_SAFE_PASS")

	if not _check_gate_finite():
		return false
	print("OCEAN_BUBBLES_BREAKING_GATE_FINITE_PASS")

	if not _check_bounds():
		return false
	print("OCEAN_BUBBLES_BREAKING_ACTIVITY_BOUNDS_PASS")

	if not _check_neutral_source():
		return false
	print("OCEAN_BUBBLES_NEUTRAL_BREAKING_SOURCE_PASS")

	if not _check_dynamic_rid_signature():
		return false
	print("OCEAN_UNDERWATER_DYNAMIC_BREAKING_RID_PASS")

	return true


func _check_gate_below_start() -> bool:
	for value in [0.0, 0.10, 0.25, 0.44, 0.45]:
		if not _approximately_equal(_shape_breaking_for_injection(float(value), 0.45, 0.75), 0.0):
			return _fail("Breaking gate emitted below start at %f" % float(value))
	return true


func _check_gate_full() -> bool:
	for value in [0.75, 0.80, 1.0]:
		if not _approximately_equal(_shape_breaking_for_injection(float(value), 0.45, 0.75), 1.0):
			return _fail("Breaking gate did not reach full at %f" % float(value))
	return true


func _check_gate_monotonicity() -> bool:
	var previous := -1.0
	for index in 101:
		var value := _shape_breaking_for_injection(float(index) / 100.0, 0.45, 0.75)
		if not is_finite(value) or value + TEST_EPSILON < previous:
			return _fail("Breaking gate was not monotonic")
		previous = value
	return true


func _check_gate_shape() -> bool:
	return _approximately_equal(_shape_breaking_for_injection(0.45, 0.45, 0.75), 0.0) and _approximately_equal(_shape_breaking_for_injection(0.60, 0.45, 0.75), 0.5) and _approximately_equal(_shape_breaking_for_injection(0.75, 0.45, 0.75), 1.0)


func _check_gate_invalid_range() -> bool:
	var values := [0.0, 0.79, 0.80, 0.8005, 0.801, 0.9, 1.0]
	var previous := -1.0
	for value in values:
		var shaped := _shape_breaking_for_injection(float(value), 0.8, 0.3)
		if not is_finite(shaped) or shaped + TEST_EPSILON < previous:
			return _fail("Invalid breaking gate range was not safely sanitized")
		previous = shaped
	return _approximately_equal(_shape_breaking_for_injection(0.8, 0.8, 0.3), 0.0) and _approximately_equal(_shape_breaking_for_injection(1.0, 0.8, 0.3), 1.0)


func _check_gate_finite() -> bool:
	for value in [NAN, INF]:
		if not _approximately_equal(_shape_breaking_for_injection(value, 0.45, 0.75), 0.0):
			return _fail("Non-finite raw Crest G was not rejected")
		if not _approximately_equal(_shape_breaking_for_injection(0.8, value, 0.75), 0.0):
			return _fail("Non-finite breaking start was not rejected")
		if not _approximately_equal(_shape_breaking_for_injection(0.8, 0.45, value), 0.0):
			return _fail("Non-finite breaking full was not rejected")
	return true


func _check_bounds() -> bool:
	var values := [-100.0, -0.1, 0.0, 0.25, 1.0, 2.0, 100.0, NAN, INF]
	for value in values:
		var activity := _breaking_activity_reference(float(value))
		if not is_finite(activity) or activity < -TEST_EPSILON or activity > 1.0 + TEST_EPSILON:
			return _fail("Breaking Activity escaped finite [0,1] bounds")
	return true


func _check_neutral_source() -> bool:
	var historical_density := 0.65
	var decay_multiplier := 0.90
	var injection := _shape_breaking_for_injection(0.0, 0.45, 0.75) * 1.0 * 1.0 * 1.0
	var next_density := historical_density * decay_multiplier + injection
	if not _approximately_equal(injection, 0.0) or not _approximately_equal(next_density, historical_density * decay_multiplier):
		return _fail("Neutral Crest G created new Bubble injection or erased history")
	return true


func _check_dynamic_rid_signature() -> bool:
	var published: Array = []
	var first := _publish_if_changed(["long-A", "mid-A", "short-A", "crest-A"], published)
	published = first[1]
	var second := _publish_if_changed(["long-A", "mid-A", "short-A", "crest-B"], published)
	published = second[1]
	var third := _publish_if_changed(["long-A", "mid-A", "short-A", "crest-A"], published)
	published = third[1]
	var unchanged := _publish_if_changed(["long-A", "mid-A", "short-A", "crest-A"], published)
	if not bool(first[0]) or not bool(second[0]) or not bool(third[0]) or bool(unchanged[0]):
		return _fail("Dynamic Crest RID signature did not republish A->B->A correctly")
	return true


func _publish_if_changed(signature: Array, published: Array) -> Array:
	if signature == published:
		return [false, published]
	return [true, signature.duplicate()]


func _breaking_activity_reference(value: float) -> float:
	if not is_finite(value):
		return 0.0
	return clampf(value, 0.0, 1.0)


func _shape_breaking_for_injection(raw_activity: float, start_threshold: float, full_threshold: float) -> float:
	if not is_finite(raw_activity) or not is_finite(start_threshold) or not is_finite(full_threshold):
		return 0.0
	var start_value := clampf(start_threshold, 0.0, 1.0)
	var full_value := clampf(full_threshold, 0.0, 1.0)
	var raw_value := clampf(raw_activity, 0.0, 1.0)
	if start_value >= 1.0:
		return 1.0 if raw_value >= 1.0 else 0.0
	full_value = minf(maxf(full_value, start_value + 0.001), 1.001)
	return _smoothstep(start_value, full_value, raw_value)


func _smoothstep(edge_start: float, edge_end: float, value: float) -> float:
	var t := clampf((value - edge_start) / maxf(edge_end - edge_start, 0.001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _approximately_equal(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= TEST_EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_BUBBLES_BREAKING_ACTIVITY_FAIL: %s" % reason)
	return false
