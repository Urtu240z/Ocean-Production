extends SceneTree

const TEST_EPSILON: float = 0.000001
const DIRECTION_EPSILON: float = 0.00001

var _failed: bool = false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var bubble_path := "res://addons/ocean/underwater/shaders/ocean_underwater_medium_bubbles.inc"
	var medium_path := "res://addons/ocean/underwater/shaders/ocean_underwater_medium.glsl.source"
	if not FileAccess.file_exists(bubble_path) or not FileAccess.file_exists(medium_path):
		return _fail("Missing H4.8 shader source")
	var bubble_source := FileAccess.get_file_as_string(bubble_path)
	var medium_source := FileAccess.get_file_as_string(medium_path)
	for token in [
		"params.sun_direction_energy.xyz",
		"params.sun_direction_energy.w",
		"vec3 bubble_water_to_light_direction()",
		"intersect_aabb(world_position, water_to_sun, bounds_min, bounds_max, box_near, box_far)",
		"float surface_distance = (bubbles.camera_sea.w - world_position.y) / water_to_sun.y;",
		"world_position + water_to_sun * ((float(shadow_index) + 0.5) * shadow_step_length)",
		"shadow_density += max(light_density, 0.0) * shadow_step_length;",
		"return exp(-shadow_density * shadow_strength);",
	]:
		if not bubble_source.contains(token):
			return _fail("H4.8 shadow source contract missing: %s" % token)
	if bubble_source.contains("+Y is the coherent light direction until a real sun vector is published") or bubble_source.contains("light_target_y") or bubble_source.contains("sunray_field"):
		return _fail("Obsolete vertical-only or Sunrays-gated shadow authority remains")
	if not medium_source.contains("vec4 sun_direction_energy; // xyz light_into_water, w DirectionalLight energy"):
		return _fail("Medium shader does not publish the real sun direction")
	print("OCEAN_BUBBLE_SHADOW_REAL_SUN_SOURCE_CONTRACT_PASS")
	print("OCEAN_BUBBLE_SHADOW_INDEPENDENT_OF_SUNRAYS_GATE_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_vertical_parity():
		return false
	print("OCEAN_BUBBLE_SHADOW_VERTICAL_SUN_PARITY_PASS")
	if not _check_oblique_direction():
		return false
	print("OCEAN_BUBBLE_SHADOW_OBLIQUE_DIRECTION_PASS")
	if not _check_full_3d_direction():
		return false
	print("OCEAN_BUBBLE_SHADOW_FULL_3D_DIRECTION_PASS")
	if not _check_normalization():
		return false
	print("OCEAN_BUBBLE_SHADOW_DIRECTION_NORMALIZATION_PASS")
	if not _check_invalid_fallback():
		return false
	print("OCEAN_BUBBLE_SHADOW_INVALID_SUN_FALLBACK_PASS")
	if not _check_below_horizon_fallback():
		return false
	print("OCEAN_BUBBLE_SHADOW_BELOW_HORIZON_SAFE_PASS")
	if not _check_surface_cap():
		return false
	print("OCEAN_BUBBLE_SHADOW_SURFACE_DISTANCE_PASS")
	if not _check_volume_exit():
		return false
	print("OCEAN_BUBBLE_SHADOW_VOLUME_EXIT_PASS")
	return true


func _check_vertical_parity() -> bool:
	var bounds_min := Vector3(-4.0, -10.0, -4.0)
	var bounds_max := Vector3(4.0, 8.0, 4.0)
	var world_position := Vector3(0.0, -5.0, 0.0)
	var direction := _water_to_sun(Vector3(0.0, -1.0, 0.0), 1.0)
	var expected_distance := minf(bounds_max.y - world_position.y, 0.0 - world_position.y)
	var actual_distance := _shadow_distance(world_position, bounds_min, bounds_max, 0.0, direction)
	for index in 4:
		var expected_position := world_position + Vector3(0.0, (float(index) + 0.5) * expected_distance / 4.0, 0.0)
		var actual_position := world_position + direction * ((float(index) + 0.5) * actual_distance / 4.0)
		if not _approximately_equal_vector(expected_position, actual_position):
			return _fail("Vertical sun changed legacy shadow samples")
	return _approximately_equal(actual_distance, expected_distance)


func _check_oblique_direction() -> bool:
	var direction := _water_to_sun(Vector3(0.6, -0.8, 0.0), 1.0)
	var sample := Vector3.ZERO + direction * 2.0
	return _approximately_equal_vector(direction, Vector3(-0.6, 0.8, 0.0)) and absf(sample.x) > TEST_EPSILON and absf(sample.y) > TEST_EPSILON and _approximately_equal(sample.z, 0.0)


func _check_full_3d_direction() -> bool:
	var direction := _water_to_sun(Vector3(-0.4, -0.75, 0.52), 1.0)
	var sample := Vector3(1.0, -2.0, 3.0) + direction * 2.0
	return absf(direction.x) > TEST_EPSILON and direction.y > TEST_EPSILON and absf(direction.z) > TEST_EPSILON and not _approximately_equal(sample.x, 1.0) and not _approximately_equal(sample.y, -2.0) and not _approximately_equal(sample.z, 3.0)


func _check_normalization() -> bool:
	var first := _water_to_sun(Vector3(0.5, -1.0, 0.2), 1.0)
	var second := _water_to_sun(Vector3(5.0, -10.0, 2.0), 1.0)
	var first_sample := Vector3(2.0, -3.0, 4.0) + first * 3.25
	var second_sample := Vector3(2.0, -3.0, 4.0) + second * 3.25
	return _approximately_equal_vector(first, second) and _approximately_equal_vector(first_sample, second_sample)


func _check_invalid_fallback() -> bool:
	var invalid_directions := [Vector3.ZERO, Vector3(NAN, 0.0, 0.0), Vector3(INF, -1.0, 0.0)]
	for invalid_direction in invalid_directions:
		var fallback := _water_to_sun(invalid_direction, 1.0)
		if not _approximately_equal_vector(fallback, Vector3.UP):
			return _fail("Invalid sun direction did not use +Y fallback")
	for invalid_energy in [0.0, NAN]:
		var fallback := _water_to_sun(Vector3(0.0, -1.0, 0.0), float(invalid_energy))
		if not _approximately_equal_vector(fallback, Vector3.UP):
			return _fail("Invalid sun energy did not use +Y fallback")
	return true


func _check_below_horizon_fallback() -> bool:
	var fallback := _water_to_sun(Vector3(0.0, 1.0, 0.0), 1.0)
	return _approximately_equal_vector(fallback, Vector3.UP) and fallback.is_finite()


func _check_surface_cap() -> bool:
	var direction := _water_to_sun(Vector3(0.6, -0.8, 0.0), 1.0)
	var distance := _shadow_distance(Vector3(0.0, -5.0, 0.0), Vector3(-100.0, -10.0, -100.0), Vector3(100.0, 10.0, 100.0), 0.0, direction)
	return _approximately_equal(distance, 6.25)


func _check_volume_exit() -> bool:
	var direction := _water_to_sun(Vector3(0.6, -0.8, 0.0), 1.0)
	var distance := _shadow_distance(Vector3(0.0, -5.0, 0.0), Vector3(-1.0, -10.0, -1.0), Vector3(1.0, 10.0, 1.0), 0.0, direction)
	return _approximately_equal(distance, 1.0 / 0.6) and distance < 6.25


func _water_to_sun(light_into_water: Vector3, energy: float) -> Vector3:
	if not light_into_water.is_finite() or light_into_water.length() <= DIRECTION_EPSILON or not is_finite(energy) or energy <= DIRECTION_EPSILON:
		return Vector3.UP
	var direction := -light_into_water.normalized()
	if not direction.is_finite() or direction.y <= DIRECTION_EPSILON:
		return Vector3.UP
	return direction


func _shadow_distance(origin: Vector3, bounds_min: Vector3, bounds_max: Vector3, sea_level: float, direction: Vector3) -> float:
	var box := _intersect_aabb(origin, direction, bounds_min, bounds_max)
	if not bool(box[0]):
		return 0.0
	var distance := maxf(float(box[2]), 0.0)
	if direction.y > DIRECTION_EPSILON:
		var surface_distance := (sea_level - origin.y) / direction.y
		if surface_distance > 0.0:
			distance = minf(distance, surface_distance)
	return distance


func _intersect_aabb(origin: Vector3, direction: Vector3, bounds_min: Vector3, bounds_max: Vector3) -> Array:
	var safe_direction := direction
	if absf(safe_direction.x) <= DIRECTION_EPSILON:
		safe_direction.x = DIRECTION_EPSILON
	if absf(safe_direction.y) <= DIRECTION_EPSILON:
		safe_direction.y = DIRECTION_EPSILON
	if absf(safe_direction.z) <= DIRECTION_EPSILON:
		safe_direction.z = DIRECTION_EPSILON
	var t0 := (bounds_min - origin) / safe_direction
	var t1 := (bounds_max - origin) / safe_direction
	var lower := Vector3(minf(t0.x, t1.x), minf(t0.y, t1.y), minf(t0.z, t1.z))
	var upper := Vector3(maxf(t0.x, t1.x), maxf(t0.y, t1.y), maxf(t0.z, t1.z))
	var near_t := maxf(lower.x, maxf(lower.y, lower.z))
	var far_t := minf(upper.x, minf(upper.y, upper.z))
	return [far_t >= maxf(near_t, 0.0), near_t, far_t]


func _approximately_equal(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= TEST_EPSILON


func _approximately_equal_vector(actual: Vector3, expected: Vector3) -> bool:
	return actual.is_finite() and actual.distance_to(expected) <= TEST_EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_BUBBLE_SHADOW_DIRECTION_FAIL: %s" % reason)
	return false
