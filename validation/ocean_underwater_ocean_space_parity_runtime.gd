extends SceneTree

## H4.9 validation. The math reference is intentionally independent from the
## production shader helpers so it can detect an accidental shared wrong scale.

const TEST_EPSILON: float = 0.000001

var _failed := false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var visible := _read("res://addons/ocean/shaders/ocean_surface.gdshader")
	var raster := _read("res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl")
	var camera_state := _read("res://addons/ocean/underwater/shaders/ocean_waterline_camera_state.glsl")
	var underwater_effect := _read("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")
	var bubbles := _read("res://addons/ocean/underwater/bubbles/ocean_underwater_bubbles.gd")
	var bubbles_update := _read("res://addons/ocean/underwater/bubbles/shaders/ocean_underwater_bubbles_update.glsl")
	var bubbles_render := _read("res://addons/ocean/underwater/shaders/ocean_underwater_medium_bubbles.inc")
	var open_ocean := _read("res://addons/ocean/fft/open_ocean_fft.gd")
	if visible.is_empty() or raster.is_empty() or camera_state.is_empty() or underwater_effect.is_empty() or bubbles.is_empty() or bubbles_update.is_empty() or bubbles_render.is_empty() or open_ocean.is_empty():
		return _fail("H4.9 source missing")

	for token in [
		"VERTEX.xz *= clipmap_geometry_scale",
		"VERTEX.y *= ocean_surface_scale",
		"surface_displacement.xz *= clipmap_geometry_scale",
		"surface_displacement.y *= ocean_surface_scale",
	]:
		if not visible.contains(token):
			return _fail("Visible Ocean Space contract missing: %s" % token)

	for token in [
		"vec4 ocean_space; // x = H clipmap geometry scale, y = V ocean scale",
		"scaled_vertex.xz *= params.ocean_space.x",
		"scaled_vertex.y *= params.ocean_space.y",
		"vec3 ocean_space_displacement(vec3 authored_displacement)",
		"authored_displacement.x * horizontal_scale",
		"authored_displacement.y * vertical_scale",
		"authored_displacement.z * horizontal_scale",
	]:
		if not raster.contains(token):
			return _fail("Waterline Raster H/V contract missing: %s" % token)
	if raster.contains("params.domains.w") or raster.contains("effective_domain"):
		return _fail("Waterline Raster still uses domains.w or rescales domains")

	for token in [
		"vec4 ocean_space; // x = H clipmap geometry scale, y = V ocean scale",
		"return ocean_space_displacement(authored_displacement);",
		"q = params.camera_sea.xz - displacement.xz;",
		"float surface_y = params.camera_sea.w + final_displacement.y;",
	]:
		if not camera_state.contains(token):
			return _fail("Camera State H/V contract missing: %s" % token)
	if camera_state.contains("params.domains.w") or camera_state.contains("effective_domain"):
		return _fail("Camera State still uses domains.w or rescales domains")

	for token in [
		"const RASTER_PARAMS_BYTES := 368",
		"const CAMERA_STATE_PARAMS_BYTES := 240",
		"func _safe_ocean_space_scales(sources: Dictionary)",
		"clipmap_geometry_scale",
		"ocean_space.x, ocean_space.y, 0.0, 0.0",
	]:
		if not underwater_effect.contains(token):
			return _fail("CPU Waterline packet contract missing: %s" % token)
	if not underwater_effect.contains("values.append_array([camera.x, camera.y, camera.z, sea_level, domains.x, domains.y, domains.z, 0.0,"):
		return _fail("Raster domains.w was not reserved")

	for token in [
		"vec4 ocean_space; // x = H clipmap geometry scale, y = V ocean scale",
		"float horizontal_scale = params.ocean_space.x",
		"float vertical_scale = params.ocean_space.y",
		"surface_y = params.camera_sea.w + final_displacement.y;",
	]:
		if not bubbles_update.contains(token):
			return _fail("Bubble Update H/V contract missing: %s" % token)
	if bubbles_update.contains("params.domains.w") or bubbles_update.contains("effective_domain"):
		return _fail("Bubble Update still uses domains.w or rescales domains")

	for token in [
		"vec4 ocean_space; // x = H clipmap geometry scale, y = V ocean scale",
		"float horizontal_scale = bubbles.ocean_space.x",
		"float vertical_scale = bubbles.ocean_space.y",
		"float surface_y = bubbles.camera_sea.w + final_displacement.y;",
	]:
		if not bubbles_render.contains(token):
			return _fail("Bubble Render H/V contract missing: %s" % token)
	if bubbles_render.contains("bubbles.domains.w") or bubbles_render.contains("effective_domain"):
		return _fail("Bubble Render still uses domains.w or rescales domains")

	for token in [
		"const UPDATE_PARAMS_BYTES := 22 * 16",
		"const RENDER_PARAMS_BYTES := 27 * 16",
		"func _safe_ocean_space_scales(sources: Dictionary)",
		"ocean_space.x, ocean_space.y, 0.0, 0.0",
	]:
		if not bubbles.contains(token):
			return _fail("Bubble CPU packet contract missing: %s" % token)

	for token in [
		"get_underwater_medium_raster_sources()",
		"\"domains\": _ocean_space.ocean_domains(",
		"\"ocean_scale\": _ocean_space.ocean_scale",
		"\"clipmap_geometry_scale\": _ocean_space.clipmap_geometry_scale",
	]:
		if not open_ocean.contains(token):
			return _fail("Open Ocean source packet missing: %s" % token)

	for forbidden_source in [raster, camera_state, bubbles_update, bubbles_render]:
		if forbidden_source.contains("coastal_jacobian") or forbidden_source.contains("breaker_shape_lab") or forbidden_source.contains("BREAKER_SHAPE_LAB"):
			return _fail("Underwater introduced forbidden Coastal Jacobian or Shape Lab authority")

	print("OCEAN_VISIBLE_UNDERWATER_SPACE_CONTRACT_PASS")
	print("OCEAN_UNDERWATER_DOMAIN_NO_DOUBLE_SCALE_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_identity():
		return false
	print("OCEAN_UNDERWATER_OCEAN_SPACE_IDENTITY_PARITY_PASS")
	if not _check_anisotropic_a():
		return false
	print("OCEAN_UNDERWATER_OCEAN_SPACE_ANISOTROPIC_A_PASS")
	if not _check_anisotropic_b():
		return false
	print("OCEAN_UNDERWATER_OCEAN_SPACE_ANISOTROPIC_B_PASS")
	if not _check_base_geometry():
		return false
	print("OCEAN_WATERLINE_BASE_GEOMETRY_SCALE_PASS")
	if not _check_horizontal_inverse():
		return false
	print("OCEAN_UNDERWATER_HORIZONTAL_INVERSE_SCALE_PASS")
	if not _check_vertical_isolation():
		return false
	print("OCEAN_UNDERWATER_VERTICAL_SCALE_ISOLATION_PASS")
	if not _check_horizontal_isolation():
		return false
	print("OCEAN_UNDERWATER_HORIZONTAL_SCALE_ISOLATION_PASS")
	if not _check_bubble_parity():
		return false
	print("OCEAN_BUBBLE_DEBUG_OCEAN_SPACE_PARITY_PASS")
	return true


func _check_identity() -> bool:
	var authored := Vector3(1.0, 2.0, -3.0)
	return _approximately_equal_vector(_scale_ocean_space(authored, 1.0, 1.0), authored)


func _check_anisotropic_a() -> bool:
	return _approximately_equal_vector(_scale_ocean_space(Vector3(1.0, 2.0, -3.0), 2.0, 0.5), Vector3(2.0, 1.0, -6.0))


func _check_anisotropic_b() -> bool:
	return _approximately_equal_vector(_scale_ocean_space(Vector3(1.0, 2.0, -3.0), 0.5, 2.0), Vector3(0.5, 4.0, -1.5))


func _check_base_geometry() -> bool:
	var vertex := _scale_ocean_space(Vector3(10.0, 0.0, -5.0), 2.0, 0.5)
	return _approximately_equal_vector(vertex, Vector3(20.0, 0.0, -10.0))


func _check_horizontal_inverse() -> bool:
	var target := Vector2(100.0, 50.0)
	var authored := Vector3(2.0, 9.0, -1.0)
	var physical := _scale_ocean_space(authored, 2.0, 0.5)
	var q := target - Vector2(physical.x, physical.z)
	return _approximately_equal_vector(Vector3(q.x, q.y, 0.0), Vector3(96.0, 52.0, 0.0))


func _check_vertical_isolation() -> bool:
	var authored := Vector3(2.0, 3.0, -1.0)
	var low := _scale_ocean_space(authored, 2.0, 0.5)
	var high := _scale_ocean_space(authored, 2.0, 2.0)
	return _approximately_equal_vector(Vector3(low.x, 0.0, low.z), Vector3(high.x, 0.0, high.z)) and not _approximately_equal(low.y, high.y)


func _check_horizontal_isolation() -> bool:
	var authored := Vector3(2.0, 3.0, -1.0)
	var narrow := _scale_ocean_space(authored, 0.5, 2.0)
	var wide := _scale_ocean_space(authored, 2.0, 2.0)
	var base_domains := Vector3(512.0, 137.0, 37.0)
	return _approximately_equal(narrow.y, wide.y) and not _approximately_equal_vector(Vector3(narrow.x, 0.0, narrow.z), Vector3(wide.x, 0.0, wide.z)) and _approximately_equal_vector(base_domains * 0.5, Vector3(256.0, 68.5, 18.5)) and _approximately_equal_vector(base_domains * 2.0, Vector3(1024.0, 274.0, 74.0))


func _check_bubble_parity() -> bool:
	var authored := Vector3(-4.0, 1.25, 7.0)
	var expected := _scale_ocean_space(authored, 2.0, 0.5)
	var debug_source := _scale_ocean_space(authored, 2.0, 0.5)
	return _approximately_equal_vector(debug_source, expected)


func _scale_ocean_space(authored: Vector3, horizontal_scale: float, vertical_scale: float) -> Vector3:
	return Vector3(authored.x * horizontal_scale, authored.y * vertical_scale, authored.z * horizontal_scale)


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
		push_error("OCEAN_UNDERWATER_OCEAN_SPACE_PARITY_FAIL: %s" % reason)
	return false
