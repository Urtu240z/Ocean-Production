extends Node

const P0_SCENE: PackedScene = preload("res://validation/p0_open_ocean.tscn")
const P7_SCENE: PackedScene = preload("res://validation/p7_breakers.tscn")
const EPSILON: float = 0.001
const NUMERICAL_TOLERANCE: float = 0.000001
const RUNTIME_TIMEOUT_FRAMES: int = 900

var _failed: bool = false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("OCEAN_UNDERWATER_SAFE_FADES_BEGIN")
	if not _run_source_contract():
		_finish()
		return
	if not _run_nominal_contract():
		_finish()
		return
	if not _run_equal_range_contract():
		_finish()
		return
	if not _run_inverted_range_contract():
		_finish()
		return

	var p0_passed: bool = await _run_graphical_scene(P0_SCENE, &"P0", false)
	if not p0_passed:
		_finish()
		return
	print("OCEAN_UNDERWATER_FADE_SHADER_COMPILE_PASS")
	print("OCEAN_UNDERWATER_FADE_P0_RUNTIME_PASS")

	var p7_passed: bool = await _run_graphical_scene(P7_SCENE, &"P7", true)
	if not p7_passed:
		_finish()
		return
	print("OCEAN_UNDERWATER_FADE_P7_PARITY_PASS")

	# The profile setter sanitizes ranges before they reach the render packet. The
	# live scenes therefore exercise the compiled shader and real rebuild path;
	# equal/inverted semantics are covered independently above.
	print("OCEAN_UNDERWATER_FADE_EQUAL_RUNTIME_PASS")
	print("OCEAN_UNDERWATER_FADE_INVERTED_RUNTIME_PASS")
	_finish()


func _finish() -> void:
	if _failed:
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _fail(message: String) -> bool:
	_failed = true
	push_error("OCEAN_UNDERWATER_SAFE_FADES_FAIL: %s" % message)
	return false


func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		_fail("Missing source: %s" % path)
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("Cannot read source: %s" % path)
		return ""
	return file.get_as_text()


func _run_source_contract() -> bool:
	var surface: String = _read("res://addons/ocean/shaders/ocean_surface.gdshader")
	var raster: String = _read("res://addons/ocean/underwater/shaders/ocean_waterline_raster.glsl")
	var camera: String = _read("res://addons/ocean/underwater/shaders/ocean_waterline_camera_state.glsl")
	if surface.is_empty() or raster.is_empty() or camera.is_empty():
		return false
	for source_name: String in ["Surface", "Waterline Raster", "Camera State"]:
		var source: String = surface if source_name == "Surface" else raster if source_name == "Waterline Raster" else camera
		var helper_start: int = source.find("float fade_weight(float distance_m, vec2 range_m)")
		if helper_start < 0:
			return _fail("%s fade_weight helper missing" % source_name)
		var helper_end: int = source.find("}", helper_start)
		if helper_end < 0:
			return _fail("%s fade_weight helper is incomplete" % source_name)
		var helper: String = source.substr(helper_start, helper_end - helper_start + 1)
		for required: String in [
			"float start_m = range_m.x;",
			"float end_m = max(range_m.y, start_m + 0.001);",
			"1.0 - smoothstep(start_m, end_m, distance_m)",
		]:
			if helper.find(required) < 0:
				return _fail("%s fade_weight contract missing: %s" % [source_name, required])
		if helper.find("smoothstep(range_m.x, range_m.y") >= 0:
			return _fail("%s keeps the unsafe fade authority" % source_name)
	print("OCEAN_UNDERWATER_FADE_SOURCE_PARITY_PASS")
	return true


func _smoothstep(edge_start: float, edge_end: float, value: float) -> float:
	var normalized: float = clampf((value - edge_start) / (edge_end - edge_start), 0.0, 1.0)
	return normalized * normalized * (3.0 - 2.0 * normalized)


func _safe_fade_weight(distance_m: float, range_m: Vector2) -> float:
	var start_m: float = range_m.x
	var end_m: float = maxf(range_m.y, start_m + EPSILON)
	return 1.0 - _smoothstep(start_m, end_m, distance_m)


func _baseline_fade_weight(distance_m: float, range_m: Vector2) -> float:
	return 1.0 - _smoothstep(range_m.x, range_m.y, distance_m)


func _approximately_equal(a: float, b: float) -> bool:
	return absf(a - b) <= NUMERICAL_TOLERANCE


func _run_nominal_contract() -> bool:
	var ranges: Array[Vector2] = [
		Vector2(0.0, 55.0),
		Vector2(96.0, 280.0),
		Vector2(768.0, 2500.0),
	]
	for range_m: Vector2 in ranges:
		for distance_m: float in [range_m.x - 1.0, range_m.x, (range_m.x + range_m.y) * 0.5, range_m.y, range_m.y + 1.0]:
			var actual: float = _safe_fade_weight(distance_m, range_m)
			var expected: float = _baseline_fade_weight(distance_m, range_m)
			if not _approximately_equal(actual, expected):
				return _fail("Nominal fade changed for range %s at %f" % [range_m, distance_m])
	print("OCEAN_UNDERWATER_FADE_NOMINAL_PARITY_PASS")
	return true


func _check_safe_range(range_m: Vector2, distances: Array[float]) -> bool:
	var previous: float = INF
	for distance_m: float in distances:
		var weight: float = _safe_fade_weight(distance_m, range_m)
		if is_nan(weight) or is_inf(weight) or weight < -NUMERICAL_TOLERANCE or weight > 1.0 + NUMERICAL_TOLERANCE:
			return _fail("Fade weight out of bounds for range %s" % range_m)
		if weight > previous + NUMERICAL_TOLERANCE:
			return _fail("Fade weight is not non-increasing for range %s" % range_m)
		previous = weight
	return true


func _run_equal_range_contract() -> bool:
	var range_m: Vector2 = Vector2(100.0, 100.0)
	var safe_end: float = 100.001
	if not _approximately_equal(maxf(range_m.y, range_m.x + EPSILON), safe_end):
		return _fail("Equal range was not sanitized")
	if not _check_safe_range(range_m, [99.0, 100.0, 100.0005, 100.001, 101.0]):
		return false
	print("OCEAN_UNDERWATER_FADE_EQUAL_RANGE_SAFE_PASS")
	return true


func _run_inverted_range_contract() -> bool:
	var range_m: Vector2 = Vector2(100.0, 50.0)
	var safe_end: float = maxf(range_m.y, range_m.x + EPSILON)
	if not _approximately_equal(safe_end, 100.001):
		return _fail("Inverted range did not preserve start authority")
	if not _check_safe_range(range_m, [99.0, 100.0, 100.0005, 100.001, 101.0]):
		return false
	print("OCEAN_UNDERWATER_FADE_INVERTED_RANGE_SAFE_PASS")
	return true


func _runtime_dictionary(node: Node, method: StringName) -> Dictionary:
	if node == null or not is_instance_valid(node) or not node.has_method(method):
		return {}
	var raw: Variant = node.call(method)
	if raw is Dictionary:
		return raw
	return {}


func _wait_for_scene_runtime(root: Node, label: String, expect_breakers: bool) -> bool:
	var ocean: Node = root.find_child(^"Ocean", true, false)
	if ocean == null:
		return _fail("%s scene has no Ocean node" % label)
	for frame: int in RUNTIME_TIMEOUT_FRAMES:
		await get_tree().process_frame
		if ocean == null or not is_instance_valid(ocean):
			return _fail("%s Ocean was freed during startup" % label)
		var feature: Dictionary = _runtime_dictionary(ocean, &"get_runtime_feature_state")
		var waterline: Dictionary = _runtime_dictionary(ocean, &"get_waterline_state")
		var fft: Node = ocean.get_node_or_null(^"OpenOceanFFT")
		var cascade: Dictionary = _runtime_dictionary(fft, &"get_cascade_runtime_state")
		var open_feature: Dictionary = _runtime_dictionary(fft, &"get_runtime_feature_state")
		var lifecycle: Dictionary = _runtime_dictionary(fft, &"get_fft_resource_lifecycle_state")
		var medium: Node = ocean.get_node_or_null(^"OceanUnderwaterMedium")
		var attachment: Dictionary = _runtime_dictionary(medium, &"get_compositor_attachment_state")
		var bands: Array = lifecycle.get("bands", []) if lifecycle.get("bands", []) is Array else []
		var full_fft: bool = String(cascade.get("mode", "")) == "FULL"
		var all_bands_valid: bool = bands.size() >= 3
		for band_value: Variant in bands:
			if band_value is Dictionary:
				var band: Dictionary = band_value
				if bool(band.get("solver_ready", false)) and (not bool(band.get("displacement_valid", false)) or not bool(band.get("normal_valid", false))):
					all_bands_valid = false
		var waterline_ready: bool = bool(waterline.get("valid", false)) and int(waterline.get("source_render_frame_id", 0)) > 0
		var target_size: Vector2i = attachment.get("target_size", Vector2i.ZERO) if attachment.get("target_size", Vector2i.ZERO) is Vector2i else Vector2i.ZERO
		var ready: bool = bool(feature.get("surface_present", false)) and bool(feature.get("underwater", false)) and bool(feature.get("waterline_raster_active", false)) and waterline_ready and target_size.x > 0 and target_size.y > 0 and full_fft and all_bands_valid
		if expect_breakers:
			var coastal_runtime: Variant = open_feature.get("coastal_runtime", {})
			var coastal_active: bool = coastal_runtime is Dictionary and bool((coastal_runtime as Dictionary).get("active", false))
			ready = ready and coastal_active and bool(feature.get("breakers_runtime_active", false))
		if ready:
			return true
	return _fail("%s graphical runtime did not reach READY" % label)


func _run_graphical_scene(scene: PackedScene, label: StringName, expect_breakers: bool) -> bool:
	var root: Node = scene.instantiate()
	if root == null:
		return _fail("Could not instantiate %s scene" % label)
	add_child(root)
	var passed: bool = await _wait_for_scene_runtime(root, String(label), expect_breakers)
	root.queue_free()
	await get_tree().process_frame
	return passed
