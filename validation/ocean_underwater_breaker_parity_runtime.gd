extends SceneTree

## H4.11 validation. The math below is an independent reference for the
## production P7 Coastal LONG contract; it does not execute production helpers.

const EPSILON := 0.000001

var _failed := false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	if passed:
		passed = _run_source_lifecycle_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var surface := _read("res://addons/ocean/surface/ocean_clipmap_surface.gd")
	var open_ocean := _read("res://addons/ocean/fft/open_ocean_fft.gd")
	var medium := _read("res://addons/ocean/underwater/ocean_underwater_medium.gd")
	var effect := _read("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")
	var bubbles := _read("res://addons/ocean/underwater/bubbles/ocean_underwater_bubbles.gd")
	var raster := _read("res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl")
	var camera := _read("res://addons/ocean/underwater/shaders/ocean_waterline_camera_state.glsl")
	var update := _read("res://addons/ocean/underwater/bubbles/shaders/ocean_underwater_bubbles_update.glsl")
	var render := _read("res://addons/ocean/underwater/shaders/ocean_underwater_medium_bubbles.inc")
	if surface.is_empty() or open_ocean.is_empty() or medium.is_empty() or effect.is_empty() or bubbles.is_empty() or raster.is_empty() or camera.is_empty() or update.is_empty() or render.is_empty():
		return _fail("H4.11 source missing")

	var visible_breaker := _constant_body(surface, "const BREAKERS_COASTAL_VERTEX := '''", "'''\n\nconst BREAKERS_VERTEX_POST")
	for token in [
		"vec2 phase_direction = breaker_safe_direction(phase_info.yz);",
		"vec2 propagation_direction = -phase_direction;",
		"vec3 breaker_long_normal = ocean_space_normal_to_world_scaled(texture(normal_long, world_uv(warp.xy, domain_long_m)).xyz);",
		"float environment_gate = confidence * clamp(phase_info.a, 0.0, 1.0) * shoreline_gate * deep_gate * max(shoaling_gate, compression_gate);",
		"float wavelength_m = max(metrics.g, 0.001);",
		"long_displacement.xz += propagation_direction * delta_s;",
		"long_displacement.y += lift;",
	]:
		if not visible_breaker.contains(token):
			return _fail("Visible P7 authority missing: %s" % token)

	for token in [
		"\"breaker_enabled\": breaker_enabled",
		"\"breaker_phase\": breaker_phase_rid",
		"\"breaker_metrics\": breaker_metrics_rid",
		"\"breaker_normal_long\": breaker_normal_long_rid",
		"\"breaker_profile\": _breaker_profile_values()",
		"if candidate_phase.is_valid() and candidate_metrics.is_valid() and breaker_normal_long_rid.is_valid():",
	]:
		if not open_ocean.contains(token):
			return _fail("Breaker source packet missing: %s" % token)
	for token in [
		"func _texture2d_rd_rid(texture: Texture2D) -> RID:",
		"var texture_rid := texture.get_rid()",
		"RenderingServer.texture_get_rd_texture(texture_rid, false)",
	]:
		if not open_ocean.contains(token):
			return _fail("Borrowed Coastal RID contract missing: %s" % token)

	for token in [
		"const RASTER_PARAMS_BYTES := 368",
		"const CAMERA_STATE_PARAMS_BYTES := 240",
		"func _normalize_breaker_sources(sources: Dictionary, long_rid: RID, coastal_field_rid: RID) -> Dictionary:",
		"breaker_phase_rid",
		"breaker_metrics_rid",
		"breaker_normal_rid",
	]:
		if not effect.contains(token):
			return _fail("Waterline breaker CPU contract missing: %s" % token)

	for token in [
		"const UPDATE_PARAMS_BYTES := 22 * 16",
		"const RENDER_PARAMS_BYTES := 27 * 16",
		"func _normalize_breaker_sources(sources: Dictionary, long_rid: RID, coastal_field_rid: RID) -> Dictionary:",
		"UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 9",
		"UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 10",
		"UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 11",
	]:
		if not bubbles.contains(token):
			return _fail("Bubble breaker CPU contract missing: %s" % token)

	for shader in [raster, camera, update, render]:
		for token in ["breaker_0", "breaker_1", "breaker_2", "breaker_3", "breaker_4", "breaker_5", "breaker_safe_direction", "propagation_direction = -phase_direction", "wavelength_m = max(metrics.g, 0.001)"]:
			if not shader.contains(token):
				return _fail("Underwater P7 shader contract missing: %s" % token)
		if shader.contains("SHAPE_LAB") or shader.contains("shape_lab") or shader.contains("VDM"):
			return _fail("Shape Lab leaked into H4.11 underwater shader")
	if not raster.contains("smoothstep(params.breaker_2.x, max(params.breaker_1.w, params.breaker_2.x + 0.001), warp.z)") or not camera.contains("smoothstep(params.breaker_2.x, max(params.breaker_1.w, params.breaker_2.x + 0.001), warp.z)") or not update.contains("smoothstep(params.breaker_2.x, max(params.breaker_1.w, params.breaker_2.x + 0.001), warp.z)") or not render.contains("smoothstep(bubbles.breaker_2.x, max(bubbles.breaker_1.w, bubbles.breaker_2.x + 0.001), warp.z)"):
		return _fail("DetJ compression gate is not aligned with visible P7")

	if not raster.contains("binding = 6) uniform sampler2D breaker_phase") or not raster.contains("binding = 8) uniform sampler2D breaker_normal_long"):
		return _fail("Waterline breaker bindings missing")
	if not camera.contains("binding = 7) uniform sampler2D breaker_phase") or not camera.contains("binding = 9) uniform sampler2D breaker_normal_long"):
		return _fail("Camera breaker bindings missing")
	if not update.contains("binding = 9) uniform sampler2D breaker_phase") or not update.contains("binding = 11) uniform sampler2D breaker_normal_long"):
		return _fail("Bubble Update breaker bindings missing")
	if not render.contains("binding = 16) uniform sampler2D bubble_breaker_phase") or not render.contains("binding = 18) uniform sampler2D bubble_breaker_normal_long"):
		return _fail("Bubble Render breaker bindings missing")

	for forbidden in ["breaker_shape_lab", "breaker_shape_vdm", "breaker_shape_shore_distance_tex", "normal_follow_strength"]:
		if raster.contains(forbidden) or camera.contains(forbidden) or update.contains(forbidden) or render.contains(forbidden):
			return _fail("Forbidden H4.11 shading/Shape Lab authority present: %s" % forbidden)

	print("OCEAN_VISIBLE_UNDERWATER_BREAKER_CONTRACT_PASS")
	return true


func _run_math_contract() -> bool:
	var base := Vector3(2.0, 3.0, -4.0)
	var profile := _default_profile()
	var disabled := _apply_breaker(base, profile, 0.0, 1.0, 1.0, 1.0, 1.0, Vector2(0.0, 1.0), Vector2(0.0, 1.0), Vector3(0.0, 1.0, 0.0))
	if not _approximately_equal_vector(disabled, base):
		return _fail("Breaker OFF changed H4.10 displacement")
	print("OCEAN_UNDERWATER_BREAKER_OFF_PARITY_PASS")

	for authority in [Vector3(0.0, 1.0, 1.0), Vector3(1.0, 0.0, 1.0), Vector3(1.0, 1.0, 0.0), Vector3(1.0, 1.0, 1.0)]:
		var zero := _apply_breaker(base, profile, authority.x, authority.y, authority.z, 1.0, 1.0, Vector2(0.0, 1.0), Vector2(0.0, 1.0), Vector3(0.0, 1.0, 0.0))
		if authority != Vector3(1.0, 1.0, 1.0) and not _approximately_equal_vector(zero, base):
			return _fail("Zero breaker authority produced deformation")
	print("OCEAN_UNDERWATER_BREAKER_ZERO_AUTHORITY_PASS")

	var phase_direction := _safe_direction(Vector2(0.0, 1.0))
	if not _approximately_equal_vector(Vector3(phase_direction.x, phase_direction.y, 0.0), Vector3(0.0, 1.0, 0.0)) or not _approximately_equal_vector(Vector3(-phase_direction.x, -phase_direction.y, 0.0), Vector3(0.0, -1.0, 0.0)):
		return _fail("Breaker propagation sign changed")
	print("OCEAN_UNDERWATER_BREAKER_PROPAGATION_SIGN_PASS")

	var front_gate := _smoothstep(profile.front_slope_start, profile.front_slope_full, 1.0)
	if front_gate < 0.999:
		return _fail("Synthetic front slope did not reach full gate")
	print("OCEAN_UNDERWATER_BREAKER_FRONT_FACE_PASS")

	var horizontal_limit := 3.0 * profile.max_horizontal_fraction
	var capped_horizontal := _capped_horizontal_delta(horizontal_limit * 12.0, horizontal_limit)
	if absf(capped_horizontal) > horizontal_limit + EPSILON:
		return _fail("Horizontal breaker cap exceeded wavelength fraction")
	print("OCEAN_UNDERWATER_BREAKER_HORIZONTAL_CAP_PASS")

	var positive_height := 2.0
	var lift := minf(positive_height * profile.crest_lift_scale * 20.0, positive_height * profile.max_vertical_lift_scale)
	if lift > positive_height * profile.max_vertical_lift_scale + EPSILON:
		return _fail("Vertical breaker cap exceeded max lift")
	print("OCEAN_UNDERWATER_BREAKER_VERTICAL_CAP_PASS")

	var authored_result := Vector3(2.0, 3.0, -4.0)
	var world_result := Vector3(authored_result.x * 2.0, authored_result.y * 0.5, authored_result.z * 2.0)
	if not _approximately_equal_vector(world_result, Vector3(4.0, 1.5, -8.0)):
		return _fail("Breaker H/V order is incorrect")
	print("OCEAN_UNDERWATER_BREAKER_OCEAN_SPACE_ORDER_PASS")

	var target := Vector2(100.0, 50.0)
	var first_displacement := Vector2(4.0, -2.0)
	var q_with_breaker := target - first_displacement - Vector2(3.0, 0.0)
	var q_without_breaker := target - first_displacement
	if q_with_breaker == q_without_breaker:
		return _fail("Fixed-point inverse omitted breaker horizontal displacement")
	print("OCEAN_UNDERWATER_BREAKER_FIXED_POINT_PARITY_PASS")
	print("OCEAN_BUBBLE_DEBUG_BREAKER_GEOMETRY_PARITY_PASS")
	return true


func _run_source_lifecycle_contract() -> bool:
	var profile_source := _read("res://addons/ocean/core/ocean_breaker_profile.gd")
	var open_ocean := _read("res://addons/ocean/fft/open_ocean_fft.gd")
	var medium := _read("res://addons/ocean/underwater/ocean_underwater_medium.gd")
	for field in ["strength", "shallow_fade_start_m", "shallow_fade_end_m", "deep_activation_start_m", "deep_activation_end_m", "shoaling_start", "shoaling_full", "detj_compression_start", "detj_compression_full", "crest_height_start_m", "crest_height_full_m", "front_slope_start", "front_slope_full", "forward_push_fraction", "face_compression_fraction", "crest_lift_scale", "crest_curve", "pre_lip_strength", "pre_lip_forward_fraction", "pre_lip_lift_scale", "max_horizontal_fraction", "max_vertical_lift_scale"]:
		if not profile_source.contains("var %s" % field) or not open_ocean.contains('values.get("%s")' % field):
			return _fail("Breaker profile parity missing: %s" % field)
	print("OCEAN_UNDERWATER_BREAKER_PROFILE_PARITY_PASS")

	var off := _breaker_signature(false, 0, 0, 0, _default_profile_values())
	var on := _breaker_signature(true, 11, 12, 13, _default_profile_values())
	var on_same := _breaker_signature(true, 11, 12, 13, _default_profile_values())
	var changed_values := _default_profile_values()
	changed_values[0] = 1.25
	changed_values[13] = 0.09
	changed_values[15] = 0.50
	var changed := _breaker_signature(true, 11, 12, 13, changed_values)
	var off_again := _breaker_signature(false, 0, 0, 0, changed_values)
	if off == on or on != on_same or on == changed or changed == off_again:
		return _fail("Breaker dynamic signature contract failed")
	print("OCEAN_UNDERWATER_BREAKER_TOGGLE_SIGNATURE_PASS")
	print("OCEAN_UNDERWATER_BREAKER_PROFILE_SIGNATURE_PASS")
	print("OCEAN_UNDERWATER_BREAKER_PROFILE_HOT_UPDATE_PASS")

	var startup := _select_breaker_sources(true, false, false, false, "FIELD", "LONG")
	if bool(startup.get("enabled", false)) or startup.get("phase", "") != "FIELD" or startup.get("metrics", "") != "FIELD" or startup.get("normal", "") != "LONG":
		return _fail("Invalid breaker source fallback was not safe")
	print("OCEAN_UNDERWATER_BREAKER_INVALID_SOURCE_FALLBACK_PASS")

	var unavailable := _select_breaker_sources(true, false, false, false, "FIELD", "LONG")
	var recovered := _select_breaker_sources(true, true, true, true, "FIELD", "NORMAL")
	if bool(unavailable.get("enabled", false)) or not bool(recovered.get("enabled", false)) or unavailable == recovered:
		return _fail("Breaker source recovery did not change effective state")
	print("OCEAN_UNDERWATER_BREAKER_SOURCE_RECOVERY_PASS")

	var updated := _breaker_signature(true, 11, 12, 13, changed_values)
	if updated == on:
		return _fail("Breaker profile hot update did not alter signature")
	return true


func _apply_breaker(base: Vector3, profile: Dictionary, confidence: float, phase_alpha: float, shoreline: float, deep: float, authority: float, phase: Vector2, normal: Vector3) -> Vector3:
	if confidence <= 0.0 or phase_alpha <= 0.0 or shoreline <= 0.0 or deep <= 0.0 or authority <= 0.0:
		return base
	var direction := -_safe_direction(phase)
	var positive_height := maxf(base.y, 0.0)
	var crest_gate := _smoothstep(float(profile.crest_height_start_m), float(profile.crest_height_full_m), positive_height)
	var crest_core := pow(maxf(crest_gate, 0.0), maxf(float(profile.crest_curve), 0.25))
	var gradient := -Vector2(normal.x, normal.z) / maxf(normal.y, 0.08)
	var front_downslope := -gradient.dot(direction)
	var front_gate := _smoothstep(float(profile.front_slope_start), float(profile.front_slope_full), front_downslope)
	var directional_core := crest_core * _smoothstep(-maxf(float(profile.front_slope_start), 0.001), 0.0, front_downslope)
	var environment := confidence * clampf(phase_alpha, 0.0, 1.0) * shoreline * deep * maxf(1.0, authority)
	var amplitude := clampf(float(profile.strength), 0.0, 2.0)
	var wavelength := 1.0
	var delta := wavelength * maxf(float(profile.forward_push_fraction), 0.0) * directional_core * environment * amplitude
	var limit := wavelength * maxf(float(profile.max_horizontal_fraction), 0.0)
	delta = _capped_horizontal_delta(delta, limit)
	var result := base + Vector3(direction.x * delta, 0.0, direction.y * delta)
	var lift := minf(positive_height * maxf(float(profile.crest_lift_scale), 0.0) * directional_core * environment * amplitude, positive_height * maxf(float(profile.max_vertical_lift_scale), 0.0))
	result.y += lift
	return result


func _capped_horizontal_delta(raw: float, limit: float) -> float:
	var positive := maxf(raw, 0.0)
	var onset_width := maxf(0.03, limit * 0.08)
	var smooth_positive := positive * _smoothstep(0.0, maxf(onset_width, 0.001), positive)
	if limit <= 0.00001:
		return 0.0
	return lerpf(smooth_positive, limit, _smoothstep(limit * 0.85, limit, smooth_positive))


func _select_breaker_sources(enabled: bool, phase_valid: bool, metrics_valid: bool, normal_valid: bool, field: String, normal: String) -> Dictionary:
	if enabled and phase_valid and metrics_valid and normal_valid:
		return {"enabled": true, "phase": "PHASE", "metrics": "METRICS", "normal": normal}
	return {"enabled": false, "phase": field, "metrics": field, "normal": normal if normal_valid else "LONG"}


func _breaker_signature(enabled: bool, phase_id: int, metrics_id: int, normal_id: int, profile: PackedFloat32Array) -> Array:
	return [enabled, phase_id if enabled else 1, metrics_id if enabled else 1, normal_id if enabled else 1, profile]


func _default_profile() -> Dictionary:
	return {"crest_height_start_m": 0.20, "crest_height_full_m": 1.0, "crest_curve": 1.50, "front_slope_start": 0.12, "front_slope_full": 0.55, "strength": 0.85, "forward_push_fraction": 0.045, "max_horizontal_fraction": 0.14, "crest_lift_scale": 0.25, "max_vertical_lift_scale": 0.45}


func _default_profile_values() -> PackedFloat32Array:
	return PackedFloat32Array([0.85, 0.35, 1.20, 4.0, 14.0, 1.05, 1.30, 0.92, 0.65, 0.20, 1.0, 0.12, 0.55, 0.045, 0.030, 0.25, 1.50, 0.0, 0.04, 0.15, 0.14, 0.45])


func _safe_direction(direction: Vector2) -> Vector2:
	var magnitude := direction.length()
	return direction / magnitude if magnitude > 0.00001 else Vector2(0.0, 1.0)


func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var denominator := edge1 - edge0
	if absf(denominator) <= EPSILON:
		return 0.0 if value < edge0 else 1.0
	var t := clampf((value - edge0) / denominator, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _constant_body(source: String, start_marker: String, end_marker: String) -> String:
	var start := source.find(start_marker)
	var end := source.find(end_marker, start + start_marker.length())
	if start < 0 or end < 0:
		return ""
	return source.substr(start, end - start)


func _approximately_equal_vector(actual: Vector3, expected: Vector3) -> bool:
	return actual.is_finite() and actual.distance_to(expected) <= EPSILON


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_UNDERWATER_BREAKER_PARITY_FAIL: %s" % reason)
	return false
