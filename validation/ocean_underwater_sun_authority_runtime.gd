extends Node

const P0_SCENE: PackedScene = preload("res://validation/p0_open_ocean.tscn")
const P7_SCENE: PackedScene = preload("res://validation/p7_breakers.tscn")
const RUNTIME_TIMEOUT_FRAMES: int = 900
const VECTOR_TOLERANCE: float = 0.0001
const COLOR_TOLERANCE: float = 0.0001

var _failed: bool = false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("OCEAN_UNDERWATER_SUN_AUTHORITY_BEGIN")
	if not _run_shared_packet_audit():
		_finish()
		return

	var root: Node = P0_SCENE.instantiate()
	if root == null:
		_fail("Could not instantiate P0")
		_finish()
		return
	var sun_a: DirectionalLight3D = root.find_child(&"Sun", true, false) as DirectionalLight3D
	if sun_a == null:
		_fail("P0 has no AUTO candidate Sun")
		_finish()
		return
	sun_a.name = "SunA"
	sun_a.light_color = Color(0.95, 0.85, 0.70, 1.0)
	sun_a.light_energy = 1.25
	var sun_b: DirectionalLight3D = DirectionalLight3D.new()
	sun_b.name = "SunB"
	sun_b.rotation_degrees = Vector3(23.0, -37.0, 11.0)
	sun_b.light_color = Color(0.17, 0.63, 0.91, 1.0)
	sun_b.light_energy = 4.25
	root.add_child(sun_b)
	add_child(root)

	var ocean: Node = root.find_child(&"Ocean", true, false) as Node
	if ocean == null:
		_fail("P0 has no Ocean")
		root.queue_free()
		_finish()
		return
	if not await _wait_for_ready(root, false):
		root.queue_free()
		_finish()
		return

	ocean.set("underwater_sun_light", null)
	var auto_state: Dictionary = await _wait_for_sun(ocean, "AUTO", true, sun_a.get_instance_id(), 2)
	if auto_state.is_empty():
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_AUTO_PASS")

	var open_ocean: Node = ocean.get_node_or_null(^"OpenOceanFFT")
	var medium: Node = ocean.get_node_or_null(^"OceanUnderwaterMedium")
	if open_ocean == null or medium == null:
		_fail("P0 runtime nodes missing")
		root.queue_free()
		_finish()
		return
	var open_ocean_id: int = open_ocean.get_instance_id()
	var medium_id: int = medium.get_instance_id()
	var effect_identity: Object = medium.call("get_effect_identity") as Object if medium.has_method(&"get_effect_identity") else null
	if effect_identity == null:
		_fail("Underwater effect identity was not published")
		root.queue_free()
		_finish()
		return

	ocean.set("underwater_sun_light", sun_b)
	var explicit_state: Dictionary = await _wait_for_sun(ocean, "EXPLICIT", true, sun_b.get_instance_id(), 0)
	if explicit_state.is_empty():
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_EXPLICIT_PASS")

	var expected_into_water: Vector3 = -sun_b.global_transform.basis.z.normalized()
	var reported_into_water: Variant = explicit_state.get("sun_light_into_water", Vector3.ZERO)
	if not reported_into_water is Vector3 or not _approximately_equal_vector(reported_into_water as Vector3, expected_into_water):
		_fail("Explicit sun packet direction does not match DirectionalLight basis")
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_DIRECTION_PASS")

	var reported_color: Variant = explicit_state.get("sun_light_color", Color.BLACK)
	var reported_energy: float = float(explicit_state.get("sun_light_energy", 0.0))
	if not reported_color is Color or not _approximately_equal_color(reported_color as Color, sun_b.light_color) or absf(reported_energy - sun_b.light_energy) > COLOR_TOLERANCE:
		_fail("Explicit sun packet photometry does not match SunB")
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_PHOTOMETRY_PASS")

	ocean.set("underwater_sun_light", sun_a)
	var switched_state: Dictionary = await _wait_for_sun(ocean, "EXPLICIT", true, sun_a.get_instance_id(), 0)
	if switched_state.is_empty():
		root.queue_free()
		_finish()
		return
	if not _same_runtime_identities(ocean, open_ocean_id, medium_id, effect_identity):
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_RUNTIME_SWITCH_PASS")

	ocean.set("underwater_sun_light", sun_b)
	if (await _wait_for_sun(ocean, "EXPLICIT", true, sun_b.get_instance_id(), 0)).is_empty():
		root.queue_free()
		_finish()
		return
	root.remove_child(sun_b)
	var invalid_state: Dictionary = await _wait_for_sun(ocean, "EXPLICIT", false, 0, 0)
	if invalid_state.is_empty() or bool(invalid_state.get("sunrays_runtime_active", true)):
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_NO_SILENT_FALLBACK_PASS")

	root.add_child(sun_b)
	if (await _wait_for_sun(ocean, "EXPLICIT", true, sun_b.get_instance_id(), 0)).is_empty():
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_REENTRY_PASS")

	ocean.set("underwater_sun_light", null)
	if (await _wait_for_sun(ocean, "AUTO", true, sun_a.get_instance_id(), 2)).is_empty():
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_CLEAR_TO_AUTO_PASS")

	var disposable: DirectionalLight3D = DirectionalLight3D.new()
	disposable.name = "SunDisposable"
	root.add_child(disposable)
	ocean.set("underwater_sun_light", disposable)
	if (await _wait_for_sun(ocean, "EXPLICIT", true, disposable.get_instance_id(), 0)).is_empty():
		root.queue_free()
		_finish()
		return
	disposable.queue_free()
	var freed_state: Dictionary = await _wait_for_sun(ocean, "EXPLICIT", false, 0, 0)
	if freed_state.is_empty() or bool(freed_state.get("sunrays_runtime_active", true)):
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_INVALIDATION_SAFE_PASS")

	ocean.set("underwater_sun_light", null)
	if (await _wait_for_sun(ocean, "AUTO", true, sun_a.get_instance_id(), 2)).is_empty():
		root.queue_free()
		_finish()
		return
	root.remove_child(sun_a)
	if (await _wait_for_sun(ocean, "AUTO", true, sun_b.get_instance_id(), 1)).is_empty():
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_AUTO_RECOVERY_PASS")

	ocean.set("underwater_sunrays", false)
	var gated_state: Dictionary = await _wait_for_sun(ocean, "AUTO", true, sun_b.get_instance_id(), 1)
	if gated_state.is_empty() or bool(gated_state.get("sunrays_runtime_active", true)):
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_GATE_PASS")

	if not _same_runtime_identities(ocean, open_ocean_id, medium_id, effect_identity):
		root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_NO_REBUILD_PASS")
	root.queue_free()
	await get_tree().process_frame

	var p7_root: Node = P7_SCENE.instantiate()
	if p7_root == null:
		_fail("Could not instantiate P7")
		_finish()
		return
	add_child(p7_root)
	if not await _wait_for_ready(p7_root, true):
		p7_root.queue_free()
		_finish()
		return
	print("OCEAN_UNDERWATER_SUN_P0_P7_RUNTIME_PASS")
	p7_root.queue_free()
	_finish()


func _finish() -> void:
	get_tree().quit(1 if _failed else 0)


func _fail(message: String) -> bool:
	_failed = true
	push_error("OCEAN_UNDERWATER_SUN_AUTHORITY_FAIL: %s" % message)
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


func _run_shared_packet_audit() -> bool:
	var medium: String = _read("res://addons/ocean/underwater/ocean_underwater_medium.gd")
	var effect: String = _read("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")
	var bubbles: String = _read("res://addons/ocean/underwater/shaders/ocean_underwater_medium_bubbles.inc")
	if medium.is_empty() or effect.is_empty() or bubbles.is_empty():
		return false
	if bubbles.find("params.sun_direction_energy") < 0 or medium.find("\"light_into_water\"") < 0 or effect.find("light_into_water") < 0:
		return _fail("Bubble/sunray shared packet contract is missing")
	if medium.find("_resolve_sun_light") < 0:
		return _fail("Underwater sun resolver is missing")
	print("OCEAN_UNDERWATER_SUN_SHARED_PACKET_AUDIT_PASS")
	return true


func _runtime_dictionary(node: Node, method: StringName) -> Dictionary:
	if node == null or not is_instance_valid(node) or not node.has_method(method):
		return {}
	var raw: Variant = node.call(method)
	if raw is Dictionary:
		return raw
	return {}


func _wait_for_ready(root: Node, expect_p7: bool) -> bool:
	var ocean: Node = root.find_child(&"Ocean", true, false) as Node
	if ocean == null:
		return _fail("Validation scene has no Ocean")
	for _frame: int in range(RUNTIME_TIMEOUT_FRAMES):
		await get_tree().process_frame
		if not is_instance_valid(ocean):
			return _fail("Ocean was freed before READY")
		var feature: Dictionary = _runtime_dictionary(ocean, &"get_runtime_feature_state")
		var waterline: Dictionary = _runtime_dictionary(ocean, &"get_waterline_state")
		var fft: Node = ocean.get_node_or_null(^"OpenOceanFFT")
		var cascade: Dictionary = _runtime_dictionary(fft, &"get_cascade_runtime_state")
		var medium: Node = ocean.get_node_or_null(^"OceanUnderwaterMedium")
		var attachment: Dictionary = _runtime_dictionary(medium, &"get_compositor_attachment_state")
		var target_value: Variant = attachment.get("target_size", Vector2i.ZERO)
		var target_size: Vector2i = target_value as Vector2i if target_value is Vector2i else Vector2i.ZERO
		var ready: bool = bool(feature.get("surface_present", false)) and bool(feature.get("underwater", false)) and bool(feature.get("waterline_raster_active", false)) and bool(waterline.get("valid", false)) and int(waterline.get("source_render_frame_id", 0)) > 0 and target_size.x > 0 and target_size.y > 0 and String(cascade.get("mode", "")) == "FULL"
		if expect_p7:
			var open_feature: Dictionary = _runtime_dictionary(fft, &"get_runtime_feature_state")
			var coastal_runtime: Variant = open_feature.get("coastal_runtime", {})
			var coastal_active: bool = coastal_runtime is Dictionary and bool((coastal_runtime as Dictionary).get("active", false))
			ready = ready and coastal_active and bool(feature.get("breakers_runtime_active", false))
		if ready:
			return true
	return _fail("Graphical scene did not reach READY")


func _wait_for_sun(ocean: Node, mode: String, valid: bool, expected_id: int, minimum_candidates: int) -> Dictionary:
	for _frame: int in range(RUNTIME_TIMEOUT_FRAMES):
		await get_tree().process_frame
		var state: Dictionary = _runtime_dictionary(ocean, &"get_runtime_feature_state")
		var state_mode: String = String(state.get("sun_authority_mode", ""))
		var state_valid: bool = bool(state.get("sun_light_valid", false))
		var state_id: int = int(state.get("sun_light_instance_id", 0))
		var candidates: int = int(state.get("sun_candidate_count", 0))
		if state_mode == mode and state_valid == valid and candidates >= minimum_candidates and (not valid or state_id == expected_id):
			return state
	_fail("Sun state did not reach %s valid=%s id=%d candidates>=%d" % [mode, valid, expected_id, minimum_candidates])
	return {}


func _same_runtime_identities(ocean: Node, open_ocean_id: int, medium_id: int, effect_identity: Object) -> bool:
	var open_ocean: Node = ocean.get_node_or_null(^"OpenOceanFFT")
	var medium: Node = ocean.get_node_or_null(^"OceanUnderwaterMedium")
	if open_ocean == null or medium == null:
		return _fail("Runtime identity nodes disappeared")
	var current_effect_identity: Object = medium.call("get_effect_identity") as Object if medium.has_method(&"get_effect_identity") else null
	if open_ocean.get_instance_id() != open_ocean_id or medium.get_instance_id() != medium_id or current_effect_identity != effect_identity:
		return _fail("Sun authority change rebuilt a runtime owner")
	return true


func _approximately_equal_vector(actual: Vector3, expected: Vector3) -> bool:
	return actual.distance_to(expected) <= VECTOR_TOLERANCE


func _approximately_equal_color(actual: Color, expected: Color) -> bool:
	return absf(actual.r - expected.r) <= COLOR_TOLERANCE and absf(actual.g - expected.g) <= COLOR_TOLERANCE and absf(actual.b - expected.b) <= COLOR_TOLERANCE and absf(actual.a - expected.a) <= COLOR_TOLERANCE
