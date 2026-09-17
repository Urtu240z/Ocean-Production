extends SceneTree

## H4.10 validation. The Coastal reference below is independent from the
## production shader helpers and models only the approved Field/Warp contract.

const TEST_EPSILON: float = 0.000001

var _failed := false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	if passed:
		passed = _run_signature_contract()
	if passed:
		passed = _run_borrowed_rid_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var visible := _read("res://addons/ocean/shaders/ocean_surface.gdshader")
	var open_ocean := _read("res://addons/ocean/fft/open_ocean_fft.gd")
	var medium := _read("res://addons/ocean/underwater/ocean_underwater_medium.gd")
	var effect := _read("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")
	var raster := _read("res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl")
	var camera_state := _read("res://addons/ocean/underwater/shaders/ocean_waterline_camera_state.glsl")
	var bubbles := _read("res://addons/ocean/underwater/bubbles/ocean_underwater_bubbles.gd")
	var bubble_update := _read("res://addons/ocean/underwater/bubbles/shaders/ocean_underwater_bubbles_update.glsl")
	var bubble_render := _read("res://addons/ocean/underwater/shaders/ocean_underwater_medium_bubbles.inc")
	if visible.is_empty() or open_ocean.is_empty() or medium.is_empty() or effect.is_empty() or raster.is_empty() or camera_state.is_empty() or bubbles.is_empty() or bubble_update.is_empty() or bubble_render.is_empty():
		return _fail("H4.10 source missing")

	for token in [
		"vec4 field = texture(coastal_field, coast_uv);",
		"vec4 warp = texture(coastal_warp, clamp(coastal_uv(world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));",
		"float confidence = field.a * coastal_confidence(warp);",
		"long_displacement = mix(long_displacement, texture(displacement_long, world_uv(warp.xy, domain_long_m)).xyz, confidence);",
		"long_displacement.y *= mix(1.0, field.g, confidence);",
	]:
		if not visible.contains(token):
			return _fail("Visible Coastal sequence missing: %s" % token)

	var source_function := _function_body(open_ocean, "func get_underwater_medium_raster_sources()", "func get_runtime_feature_state()")
	for token in [
		"\"coastal_enabled\": coastal_enabled",
		"\"coastal_field\": coastal_field_rid",
		"\"coastal_warp\": coastal_warp_rid",
		"\"coastal_origin\": coastal_origin",
		"\"coastal_extent\": coastal_extent",
		"\"coastal_warp_origin\": coastal_warp_origin",
		"\"coastal_warp_extent\": coastal_warp_extent",
		"\"coastal_warp_detj_safe\": coastal_warp_detj_safe",
	]:
		if not source_function.contains(token):
			return _fail("Open Ocean Coastal source packet missing: %s" % token)
	for forbidden in ["phase", "metrics", "jacobian"]:
		if source_function.contains("\"%s\"" % forbidden):
			return _fail("H4.10 source packet publishes forbidden Coastal data: %s" % forbidden)
	if not source_function.contains("_coastal_waves_active and _coastal_source_data_valid()"):
		return _fail("coastal_enabled is not gated by wave activity and valid data")

	for token in [
		"func _texture2d_rd_rid(texture: Texture2D) -> RID:",
		"texture.get_rid()",
		"RenderingServer.texture_get_rd_texture(texture_rid, false)",
	]:
		if not open_ocean.contains(token):
			return _fail("Borrowed Coastal RID conversion missing: %s" % token)

	for token in [
		"vec4 coastal_origin_extent",
		"vec4 coastal_warp_origin_extent",
		"vec4 coastal_control",
		"vec2 coastal_uv_from_world",
		"float coastal_confidence_value",
		"vec3 authored_long_at",
		"params.coastal_control.x <= 0.5",
		"long_displacement.y *= mix(1.0, field.g, confidence);",
	]:
		if not raster.contains(token) or not camera_state.contains(token):
			return _fail("Raster/Camera Coastal helper parity missing: %s" % token)
	if raster.contains("coastal_metrics") or raster.contains("coastal_phase") or raster.contains("coastal_jacobian") or camera_state.contains("coastal_metrics") or camera_state.contains("coastal_phase") or camera_state.contains("coastal_jacobian"):
		return _fail("H4.10 introduced forbidden Coastal textures")

	for token in [
		"const RASTER_PARAMS_BYTES := 272",
		"const CAMERA_STATE_PARAMS_BYTES := 144",
		"_coastal_sampler",
		"SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE",
		"sources.get(\"coastal_field\", long_rid)",
		"sources.get(\"coastal_warp\", long_rid)",
		"_pack_raster_params",
		"_pack_camera_state_params",
	]:
		if not effect.contains(token):
			return _fail("Waterline Coastal CPU/lifecycle contract missing: %s" % token)
	if not effect.contains("UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4") or not effect.contains("UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 5") or not effect.contains("UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6"):
		return _fail("Waterline Coastal bindings missing")

	for token in [
		"const UPDATE_PARAMS_BYTES := 16 * 16",
		"const RENDER_PARAMS_BYTES := 21 * 16",
		"var _coastal_sampler := RID()",
		"func get_coastal_sampler_rid() -> RID:",
		"UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 7",
		"UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8",
	]:
		if not bubbles.contains(token):
			return _fail("Bubble Coastal CPU/lifecycle contract missing: %s" % token)

	for token in [
		"layout(set = 0, binding = 4) uniform sampler2D coastal_field;",
		"layout(set = 0, binding = 5) uniform sampler2D coastal_warp;",
		"vec4 coastal_origin_extent",
		"vec4 coastal_warp_origin_extent",
		"vec4 coastal_control",
		"vec3 authored_long_at",
	]:
		if not raster.contains(token) or not camera_state.contains(token):
			return _fail("Waterline GLSL Coastal layout missing: %s" % token)
	for token in [
		"layout(set = 0, binding = 7) uniform sampler2D coastal_field;",
		"layout(set = 0, binding = 8) uniform sampler2D coastal_warp;",
		"vec3 authored_long = cascade_sample(displacement_long, q, params.domains.x).xyz;",
		"authored_long * fade_weight(distance_m, params.long_fade.xy)",
	]:
		if not bubble_update.contains(token):
			return _fail("Bubble Update Coastal sequence missing: %s" % token)
	for token in [
		"layout(set = 0, binding = 14) uniform sampler2D bubble_coastal_field;",
		"layout(set = 0, binding = 15) uniform sampler2D bubble_coastal_warp;",
		"vec3 authored_long = bubble_cascade_sample(bubble_displacement_long, q, bubbles.domains.x).xyz;",
		"authored_long * bubble_fade_weight(distance_m, bubbles.long_fade.xy)",
	]:
		if not bubble_render.contains(token):
			return _fail("Bubble Render Coastal sequence missing: %s" % token)

	print("OCEAN_VISIBLE_UNDERWATER_COASTAL_CONTRACT_PASS")
	print("OCEAN_UNDERWATER_COASTAL_DYNAMIC_SOURCE_PASS")
	return true


func _run_math_contract() -> bool:
	if not _approximately_equal_vector(_apply_coastal(Vector3(2.0, 3.0, -4.0), Vector3(10.0, 8.0, -6.0), 1.0, 1.0, 1.0, 1.0, 0.5, false), Vector3(2.0, 3.0, -4.0)):
		return _fail("Coastal OFF changed Open Ocean displacement")
	print("OCEAN_UNDERWATER_COASTAL_OFF_PARITY_PASS")

	var base := Vector3(2.0, 3.0, -4.0)
	var warped := Vector3(10.0, 8.0, -6.0)
	var outside := _apply_coastal(base, warped, 1.0, 1.0, 0.5, 1.0, 0.5, false)
	if not _approximately_equal_vector(outside, base):
		return _fail("Outside Coastal extent did not preserve LONG")
	print("OCEAN_UNDERWATER_COASTAL_OUTSIDE_EXTENT_PASS")

	for zero_case in [Vector3(0.0, 1.0, 1.0), Vector3(1.0, 0.0, 1.0), Vector3(1.0, 1.0, 0.0)]:
		var zero_confidence := _apply_coastal(base, warped, zero_case.x, zero_case.y, zero_case.z, 1.0, 0.5, true)
		if not _approximately_equal_vector(zero_confidence, base):
			return _fail("Zero Coastal confidence changed LONG")
	print("OCEAN_UNDERWATER_COASTAL_ZERO_CONFIDENCE_PASS")

	var full := _apply_coastal(base, warped, 1.0, 1.0, 1.0, 1.0, 0.5, true)
	if not _approximately_equal_vector(full, Vector3(warped.x, warped.y, warped.z)):
		return _fail("Full Coastal confidence did not select warped LONG")
	var shoaled := _apply_coastal(base, warped, 1.0, 1.0, 1.0, 0.25, 0.5, true)
	if not _approximately_equal(shoaled.x, warped.x) or not _approximately_equal(shoaled.z, warped.z) or not _approximately_equal(shoaled.y, warped.y * 0.25):
		return _fail("Coastal shoaling modified more than Y")
	print("OCEAN_UNDERWATER_COASTAL_FULL_CONFIDENCE_PASS")
	print("OCEAN_UNDERWATER_COASTAL_SHOALING_VERTICAL_ONLY_PASS")

	var world := _scale_ocean_space(full, 2.0, 0.5)
	if not _approximately_equal_vector(world, Vector3(full.x * 2.0, full.y * 0.5, full.z * 2.0)):
		return _fail("H/V was not applied after Coastal")
	print("OCEAN_UNDERWATER_COASTAL_OCEAN_SPACE_ORDER_PASS")

	var base_domain := 512.0
	var published_domain := base_domain * 2.0
	var sample_q := Vector2(64.0, -32.0)
	var expected_uv := sample_q / published_domain + Vector2(0.5, 0.5)
	var double_scaled_uv := sample_q / (published_domain * 2.0) + Vector2(0.5, 0.5)
	if not _approximately_equal_vector(Vector3(expected_uv.x, expected_uv.y, 0.0), Vector3(0.625, 0.46875, 0.0)) or _approximately_equal_vector(Vector3(expected_uv.x, expected_uv.y, 0.0), Vector3(double_scaled_uv.x, double_scaled_uv.y, 0.0)):
		return _fail("Coastal LONG domain was double-scaled")
	print("OCEAN_UNDERWATER_DOMAIN_NO_DOUBLE_SCALE_PASS")
	return true


func _run_signature_contract() -> bool:
	var off := _signature(false, 0, 0, Vector2.ZERO, Vector2.ONE, Vector2.ZERO, Vector2.ONE, 0.5)
	var on := _signature(true, 11, 12, Vector2(10.0, 20.0), Vector2(80.0, 60.0), Vector2(12.0, 22.0), Vector2(76.0, 56.0), 0.45)
	var on_same := _signature(true, 11, 12, Vector2(10.0, 20.0), Vector2(80.0, 60.0), Vector2(12.0, 22.0), Vector2(76.0, 56.0), 0.45)
	var off_again := _signature(false, 0, 0, Vector2.ZERO, Vector2.ONE, Vector2.ZERO, Vector2.ONE, 0.5)
	if off == on or on != on_same or on == off_again:
		return _fail("Coastal source signature did not model OFF/ON/republication transitions")
	var publications := 0
	var previous := off
	for current in [on, on_same, off_again]:
		if current != previous:
			publications += 1
		previous = current
	if publications != 2:
		return _fail("Coastal same-data ON state republished redundantly")
	print("OCEAN_UNDERWATER_COASTAL_TOGGLE_SIGNATURE_PASS")
	return true


func _run_borrowed_rid_contract() -> bool:
	var open_ocean := _read("res://addons/ocean/fft/open_ocean_fft.gd")
	var effect := _read("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")
	var bubbles := _read("res://addons/ocean/underwater/bubbles/ocean_underwater_bubbles.gd")
	if open_ocean.contains("free_rid(coastal_field") or open_ocean.contains("free_rid(coastal_warp") or effect.contains("free_rid(coastal_field") or effect.contains("free_rid(coastal_warp") or bubbles.contains("free_rid(coastal_field") or bubbles.contains("free_rid(coastal_warp"):
		return _fail("Borrowed Coastal RID is owned/freed by Underwater")
	print("OCEAN_UNDERWATER_COASTAL_BORROWED_RID_PASS")
	return true


func _apply_coastal(base: Vector3, warped: Vector3, field_alpha: float, warp_w: float, warp_z: float, field_g: float, detj_safe: float, inside_extent: bool) -> Vector3:
	if not inside_extent:
		return base
	var confidence := field_alpha * _smoothstep(0.0, detj_safe, warp_z) * warp_w
	var result := base.lerp(warped, confidence)
	result.y *= lerpf(1.0, field_g, confidence)
	return result


func _scale_ocean_space(authored: Vector3, horizontal_scale: float, vertical_scale: float) -> Vector3:
	return Vector3(authored.x * horizontal_scale, authored.y * vertical_scale, authored.z * horizontal_scale)


func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var denominator := edge1 - edge0
	if absf(denominator) <= TEST_EPSILON:
		return 0.0 if value < edge0 else 1.0
	var t := clampf((value - edge0) / denominator, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _signature(enabled: bool, field_id: int, warp_id: int, origin: Vector2, extent: Vector2, warp_origin: Vector2, warp_extent: Vector2, detj_safe: float) -> Array:
	return [enabled, field_id if enabled else 0, warp_id if enabled else 0, origin if enabled else Vector2.ZERO, extent if enabled else Vector2.ONE, warp_origin if enabled else Vector2.ZERO, warp_extent if enabled else Vector2.ONE, detj_safe if enabled else 0.5]


func _function_body(source: String, start_marker: String, end_marker: String) -> String:
	var start := source.find(start_marker)
	var end := source.find(end_marker, start + start_marker.length())
	if start < 0 or end < 0:
		return ""
	return source.substr(start, end - start)


func _approximately_equal(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= TEST_EPSILON


func _approximately_equal_vector(actual: Vector3, expected: Vector3) -> bool:
	return actual.is_finite() and actual.distance_to(expected) <= TEST_EPSILON


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_UNDERWATER_COASTAL_PARITY_FAIL: %s" % reason)
	return false
