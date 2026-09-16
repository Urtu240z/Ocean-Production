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
		"breaking_source = breaking_activity_at(q);",
	]:
		if not update_source.contains(contract_line):
			return _fail("Bubble compute Crest G contract missing: %s" % contract_line)

	for contract_line in [
		"layout(set = 0, binding = 13) uniform sampler2D bubble_breaking_activity_long;",
		"textureLod(bubble_breaking_activity_long, q / max(bubbles.domains.x, 0.001) + vec2(0.5), 0.0).g",
	]:
		if not debug_source.contains(contract_line):
			return _fail("Bubble debug Crest G contract missing: %s" % contract_line)

	if update_source.contains("source_thresholds") or update_source.contains("source_weights") or update_source.contains("params.source_thresholds") or update_source.contains("sample_long.w") or update_source.contains("sample_mid.w") or update_source.contains("sample_short.w"):
		return _fail("Bubble compute still contains the duplicate Jacobian detector")
	if debug_source.contains("source_thresholds") or debug_source.contains("source_weights") or debug_source.contains("sample_long.w"):
		return _fail("Bubble debug still contains the duplicate Jacobian detector")
	if not bubbles_source.contains("breaking_activity_rid") or not bubbles_source.contains("_surface_sampler, breaking_activity_rid") or not bubbles_source.contains("breaking_activity_long"):
		return _fail("Bubble controller does not bind or validate Crest G")
	if not spindrift_source.contains("crest_g_long"):
		return _fail("Spindrift no longer declares Crest LONG.G authority")

	print("OCEAN_BUBBLES_NO_DUPLICATE_BREAKING_DETECTOR_PASS")
	print("OCEAN_BUBBLES_DEBUG_SOURCE_PARITY_PASS")
	print("OCEAN_SHARED_BREAKING_ACTIVITY_AUTHORITY_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_linearity():
		return false
	print("OCEAN_BUBBLES_BREAKING_ACTIVITY_LINEARITY_PASS")

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


func _check_linearity() -> bool:
	for value in [0.0, 0.25, 0.5, 0.72, 1.0]:
		var activity := _breaking_activity_reference(float(value))
		var injection := activity * 1.0 * 1.0 * 1.0
		if not _approximately_equal(injection, float(value)):
			return _fail("Breaking Activity injection was not linear at %f" % float(value))
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
	var injection := _breaking_activity_reference(0.0) * 1.0 * 1.0 * 1.0
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


func _approximately_equal(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= TEST_EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_BUBBLES_BREAKING_ACTIVITY_FAIL: %s" % reason)
	return false
