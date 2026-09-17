extends SceneTree

## H4.12 validation. The numerical checks below are independent references for
## the value-space Coastal reprojection contract; they do not call production
## shader helpers.

const EPSILON := 0.000001

var _failed := false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var surface := _read("res://addons/ocean/shaders/ocean_surface.gdshader")
	var surface_runtime := _read("res://addons/ocean/surface/ocean_clipmap_surface.gd")
	var update := _read("res://addons/ocean/underwater/bubbles/shaders/ocean_underwater_bubbles_update.glsl")
	var bubble_render := _read("res://addons/ocean/underwater/shaders/ocean_underwater_medium_bubbles.inc")
	var raw_crest := _read("res://addons/ocean/shaders/fft/update_crest_foam.glsl")
	if surface.is_empty() or surface_runtime.is_empty() or update.is_empty() or bubble_render.is_empty() or raw_crest.is_empty():
		return _fail("H4.12 source missing")

	for token in [
		"varying vec2 crest_long_coastal_warp_xz;",
		"varying float crest_long_coastal_confidence;",
		"crest_long_coastal_warp_xz = wave_sample_xz;",
		"crest_long_coastal_confidence = 0.0;",
		"crest_long_coastal_warp_xz = warp.xy;",
		"crest_long_coastal_confidence = clamp(confidence, 0.0, 1.0);",
		"vec2 sample_coastal_crest_long(vec2 base_xz)",
		"vec2 base_sample = texture(crest_foam_long, world_uv(base_xz, domain_long_m)).rg;",
		"vec2 warped_sample = texture(crest_foam_long, world_uv(crest_long_coastal_warp_xz, domain_long_m)).rg;",
		"return mix(base_sample, warped_sample, confidence);",
		"float long_foam = sample_coastal_crest_long(ocean_wave_sample_xz).r * long_weight;",
	]:
		if not surface.contains(token):
			return _fail("Surface Crest Coastal mapping missing: %s" % token)
	var crest_helper := _section(surface, "vec2 sample_coastal_crest_long", "\n}\n\nfloat surface_foam_stochastic_hash12")
	if crest_helper.contains("coastal_field") or crest_helper.contains("coastal_warp") or crest_helper.contains("mix(base_xz") or crest_helper.contains("field.g"):
		return _fail("Surface Crest helper re-samples Coastal or mixes coordinates")
	if surface.contains("mix(ocean_wave_sample_xz, crest_long_coastal_warp_xz") or surface.contains("mix(wave_sample_xz, warp.xy"):
		return _fail("Surface Crest mapping mixes coordinates")
	print("OCEAN_SURFACE_CREST_COASTAL_OFF_SINGLE_SAMPLE_PASS")
	print("OCEAN_CREST_RG_COASTAL_MAPPING_PARITY_PASS")

	for source in [update, bubble_render]:
		var mapping_function := "vec3 displacement_at_with_coastal_mapping" if source == update else "vec3 bubble_displacement_at_with_coastal_mapping"
		for token in [
			mapping_function,
			"crest_warp_xz = q;",
			"crest_confidence = 0.0;",
			"crest_warp_xz = warp.xy;",
			"crest_confidence = clamp(confidence, 0.0, 1.0);",
			"float breaking_activity_coastal",
			"base_value = textureLod(",
			"warped_value = textureLod(",
			"mix(base_value, clamp(warped_value, 0.0, 1.0), clamp(confidence, 0.0, 1.0))",
		]:
			if not source.contains(token):
				return _fail("Bubble Crest Coastal mapping missing: %s" % token)
		if source.contains("mix(q, warp") or source.contains("mix(target_xz"):
			return _fail("Bubble Crest mapping mixes coordinates")
		var breaking_section_start := "float breaking_activity_coastal" if source == update else "float bubble_breaking_activity_coastal"
		var breaking_section_end := "\n}\n\nfloat shape_breaking_for_injection" if source == update else "\n}\n\nfloat bubble_shape_breaking_for_injection"
		var breaking_section := _section(source, breaking_section_start, breaking_section_end)
		for forbidden in ["field.g", "breaker_activation", "environment_gate", "breaker_strength", "crest_core"]:
			if breaking_section.contains(forbidden):
				return _fail("Bubble Crest G depends on non-Crest authority: %s" % forbidden)

	for token in [
		"vec2 crest_warp_xz;",
		"float crest_confidence;",
		"displacement_at_with_coastal_mapping(q, crest_warp_xz, crest_confidence)",
		"float raw_breaking = breaking_activity_coastal(q, crest_warp_xz, crest_confidence);",
		"breaking_source = shape_breaking_for_injection(raw_breaking, params.breaking_gate.x, params.breaking_gate.y);",
	]:
		if not update.contains(token):
			return _fail("Bubble Update final mapping/gate order missing: %s" % token)
	for token in [
		"vec2 crest_warp_xz;",
		"float crest_confidence;",
		"bubble_displacement_at_with_coastal_mapping(q, crest_warp_xz, crest_confidence)",
		"float raw_breaking = bubble_breaking_activity_coastal(q, crest_warp_xz, crest_confidence);",
		"float breaking = bubble_shape_breaking_for_injection(raw_breaking, bubbles.breaking_gate.x, bubbles.breaking_gate.y);",
	]:
		if not bubble_render.contains(token):
			return _fail("Bubble Debug final mapping/gate order missing: %s" % token)

	for forbidden in ["coastal_field", "coastal_warp", "breaker_phase", "breaker_metrics"]:
		if raw_crest.contains(forbidden):
			return _fail("Raw Crest compute acquired Coastal/P7 authority: %s" % forbidden)
	for token in [
		"float jacobian =",
		"float residual =",
		"float breaking_activity =",
		"imageStore(foam_next, coord, vec4(clamp(residual, 0.0, 1.0), breaking_activity, 0.0, 1.0));",
	]:
		if not raw_crest.contains(token):
			return _fail("Raw Crest R/G authority changed: %s" % token)
	print("OCEAN_CREST_RAW_AUTHORITY_UNCHANGED_PASS")

	if update.contains("breaking_activity_at(q)") or bubble_render.contains("float raw_breaking = textureLod(bubble_breaking_activity_long"):
		return _fail("Bubble final Crest sample bypasses Coastal mapping")
	if update.contains("ocean_space") and _section(update, "float breaking_activity_coastal", "\n}\n\nfloat shape_breaking_for_injection").contains("ocean_space"):
		return _fail("Bubble Crest mapping applies H/V scaling")
	if _section(bubble_render, "float bubble_breaking_activity_coastal", "\n}\n\nfloat bubble_shape_breaking_for_injection").contains("ocean_space"):
		return _fail("Bubble Debug Crest mapping applies H/V scaling")
	print("OCEAN_SURFACE_BUBBLE_CREST_COASTAL_MAPPING_PARITY_PASS")
	return true


func _run_math_contract() -> bool:
	var base := Vector2(0.20, 0.30)
	var warped := Vector2(0.90, 0.80)
	if not _approximately_equal_vector(_mix_values(base, warped, 0.0), base):
		return _fail("Coastal OFF/zero confidence changed Crest RG")
	print("OCEAN_CREST_COASTAL_OFF_PARITY_PASS")
	if not _approximately_equal_vector(_mix_values(base, base, 0.0), base):
		return _fail("Outside Coastal extent did not preserve base Crest RG")
	print("OCEAN_CREST_COASTAL_OUTSIDE_EXTENT_PASS")
	print("OCEAN_CREST_COASTAL_ZERO_CONFIDENCE_PASS")

	if not _approximately_equal_vector(_mix_values(base, warped, 1.0), warped):
		return _fail("Full confidence did not select warped Crest RG")
	print("OCEAN_CREST_COASTAL_FULL_CONFIDENCE_PASS")

	var partial := _mix_values(base, warped, 0.25)
	if not _approximately_equal_vector(partial, Vector2(0.375, 0.425)):
		return _fail("Partial Crest RG mix is not value-space linear interpolation")
	print("OCEAN_CREST_COASTAL_BLEND_PARITY_PASS")

	var q := 0.30
	var warp_x := 1.40
	var confidence := 0.25
	var value_mix := lerpf(sin(q), sin(warp_x), confidence)
	var coordinate_mix := sin(lerpf(q, warp_x, confidence))
	if not is_finite(value_mix) or absf(value_mix - coordinate_mix) <= 0.0001:
		return _fail("Synthetic non-linear mapping did not distinguish value/coordinate mix")
	if absf(value_mix - lerpf(sin(q), sin(warp_x), confidence)) > EPSILON:
		return _fail("Crest non-linear reference is not value-space mix")
	print("OCEAN_CREST_COASTAL_MIX_VALUES_NOT_COORDINATES_PASS")

	var raw_mixed := lerpf(0.30, 0.90, 0.50)
	var start := 0.45
	var full := 0.75
	var shaped_after := _smoothstep(start, full, raw_mixed)
	var witness_base := 0.50
	var witness_warped := 0.90
	var shaped_before := lerpf(_smoothstep(start, full, witness_base), _smoothstep(start, full, witness_warped), 0.50)
	var witness_shaped_after := _smoothstep(start, full, lerpf(witness_base, witness_warped, 0.50))
	if not _approximately_equal(raw_mixed, 0.60):
		return _fail("Breaking gate fixture invalid")
	if absf(shaped_before - witness_shaped_after) <= 0.0001:
		return _fail("Gate-order witness did not distinguish shape-after-mapping")
	if not _approximately_equal(shaped_after, _smoothstep(start, full, raw_mixed)):
		return _fail("Breaking shaping did not consume mixed raw G")
	print("OCEAN_BUBBLE_BREAKING_GATE_AFTER_COASTAL_MAPPING_PASS")
	print("OCEAN_BUBBLE_DEBUG_CREST_COASTAL_PARITY_PASS")
	return true


func _mix_values(base: Vector2, warped: Vector2, confidence: float) -> Vector2:
	return base + (warped - base) * clampf(confidence, 0.0, 1.0)


func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, EPSILON), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _approximately_equal(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= EPSILON


func _approximately_equal_vector(actual: Vector2, expected: Vector2) -> bool:
	return actual.is_finite() and actual.distance_to(expected) <= EPSILON


func _section(source: String, start_marker: String, end_marker: String) -> String:
	var start := source.find(start_marker)
	var end := source.find(end_marker, start + start_marker.length())
	if start < 0 or end < 0:
		return ""
	return source.substr(start, end - start)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_CREST_COASTAL_MAPPING_FAIL: %s" % reason)
	return false
