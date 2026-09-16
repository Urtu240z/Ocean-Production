extends SceneTree

const TEST_EPSILON: float = 0.000001
const DIFFUSION_STABILITY_LIMIT: float = 0.45
const DIFFUSION_EPSILON: float = 0.00001

var _failed: bool = false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var shader_path := "res://addons/ocean/underwater/bubbles/shaders/ocean_underwater_bubbles_update.glsl"
	var profile_path := "res://addons/ocean/underwater/bubbles/ocean_underwater_bubble_profile.gd"
	if not FileAccess.file_exists(shader_path) or not FileAccess.file_exists(profile_path):
		return _fail("Missing H4.7 diffusion source")
	var shader := FileAccess.get_file_as_string(shader_path)
	var profile := FileAccess.get_file_as_string(profile_path)
	for token in [
		"const float DIFFUSION_STABILITY_LIMIT = 0.45;",
		"vec3 safe_voxel = voxel_size;",
		"vec3 inverse_h2 = 1.0 / (safe_voxel * safe_voxel);",
		"float inverse_h2_sum = inverse_h2.x + inverse_h2.y + inverse_h2.z;",
		"float max_stable_diffusion = DIFFUSION_STABILITY_LIMIT / max(diffusion_denominator, EPSILON);",
		"float requested_diffusion = max(params.dynamics.y, 0.0);",
		"float effective_diffusion = 0.0;",
		"effective_diffusion * dt * laplacian",
	]:
		if not shader.contains(token):
			return _fail("Missing diffusion stability source contract: %s" % token)
	if shader.contains("advected + diffusion * dt * laplacian") or shader.contains("params.dynamics.y * dt * laplacian"):
		return _fail("Unclamped diffusion remains authoritative")
	if not profile.contains("@export_range(0.0, 0.25, 0.005) var diffusion := 0.04"):
		return _fail("Diffusion authoring range/default changed")
	if not shader.contains("binding = 6) uniform sampler2D breaking_activity_long"):
		return _fail("H4.6 breaking activity binding was changed")
	print("OCEAN_BUBBLE_DIFFUSION_SOURCE_CONTRACT_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_default_parity():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_DEFAULT_PARITY_PASS")
	if not _check_zero_dt():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_ZERO_DT_PASS")
	if not _check_zero_request():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_ZERO_REQUEST_PASS")
	if not _check_stable_parity():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_STABLE_PARITY_PASS")
	if not _check_unstable_clamp():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_UNSTABLE_CLAMP_PASS")
	if not _check_cfl_contract():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_CFL_CONTRACT_PASS")
	if not _check_extreme_grid():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_EXTREME_GRID_SAFE_PASS")
	if not _check_anisotropic_grid():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_ANISOTROPIC_GRID_PASS")
	if not _check_finite_behavior():
		return false
	print("OCEAN_BUBBLE_DIFFUSION_FINITE_PASS")
	return true


func _check_default_parity() -> bool:
	var extent := Vector3(64.0, 18.0, 64.0)
	var resolution := Vector3(96.0, 32.0, 96.0)
	var effective := _effective_diffusion(0.04, 1.0 / 30.0, extent / resolution)
	return _approximately_equal(effective, 0.04)


func _check_zero_dt() -> bool:
	return _approximately_equal(_effective_diffusion(0.25, 0.0, Vector3.ONE), 0.0) and _approximately_equal(_effective_diffusion(0.25, DIFFUSION_EPSILON, Vector3.ONE), 0.0)


func _check_zero_request() -> bool:
	var requested := 0.0
	var effective := _effective_diffusion(requested, 1.0 / 30.0, Vector3(0.5, 0.5, 0.5))
	var advected := 0.73
	var laplacian := -91.0
	var after_diffusion := advected + effective * (1.0 / 30.0) * laplacian
	return _approximately_equal(effective, 0.0) and _approximately_equal(after_diffusion, advected)


func _check_stable_parity() -> bool:
	var voxel := Vector3(0.6666667, 0.5625, 0.6666667)
	var dt := 1.0 / 30.0
	var max_stable := _max_stable_diffusion(dt, voxel)
	var requested := minf(0.25, max_stable * 0.5)
	var default_grid_high_request := _effective_diffusion(0.25, dt, voxel)
	return requested > 0.0 and _approximately_equal(_effective_diffusion(requested, dt, voxel), requested) and _approximately_equal(default_grid_high_request, 0.25)


func _check_unstable_clamp() -> bool:
	var voxel := Vector3(8.0 / 192.0, 1.0 / 96.0, 8.0 / 192.0)
	var dt := 1.0
	var requested := 0.25
	var maximum := _max_stable_diffusion(dt, voxel)
	var effective := _effective_diffusion(requested, dt, voxel)
	return maximum < requested and _approximately_equal(effective, maximum)


func _check_cfl_contract() -> bool:
	var grids := [
		[Vector3(64.0, 18.0, 64.0), Vector3(96.0, 32.0, 96.0), 1.0 / 30.0, 0.04],
		[Vector3(64.0, 18.0, 64.0), Vector3(96.0, 32.0, 96.0), 1.0 / 30.0, 0.25],
		[Vector3(8.0, 1.0, 8.0), Vector3(192.0, 96.0, 192.0), 1.0, 0.25],
		[Vector3(1.0, 0.1, 2.0), Vector3.ONE, 0.25, 0.25],
	]
	for grid in grids:
		var voxel: Vector3 = grid[0] / grid[1]
		var dt: float = grid[2]
		var effective := _effective_diffusion(float(grid[3]), dt, voxel)
		var sigma := effective * dt * _inverse_h2_sum(voxel)
		if not is_finite(sigma) or sigma > DIFFUSION_STABILITY_LIMIT + TEST_EPSILON:
			return _fail("Diffusion coefficient exceeded stability limit")
	return true


func _check_extreme_grid() -> bool:
	var voxel := Vector3(8.0 / 192.0, 1.0 / 96.0, 8.0 / 192.0)
	var effective := _effective_diffusion(0.25, 1.0, voxel)
	return effective < 0.25 and _sigma(effective, 1.0, voxel) <= DIFFUSION_STABILITY_LIMIT + TEST_EPSILON


func _check_anisotropic_grid() -> bool:
	var voxel := Vector3(1.0, 0.10, 2.0)
	var dt := 0.25
	var effective := _effective_diffusion(0.25, dt, voxel)
	var expected := DIFFUSION_STABILITY_LIMIT / (dt * (1.0 + 100.0 + 0.25))
	return _approximately_equal(effective, expected) and _sigma(effective, dt, voxel) <= DIFFUSION_STABILITY_LIMIT + TEST_EPSILON


func _check_finite_behavior() -> bool:
	var finite_cases := [
		[0.25, 1.0 / 30.0, Vector3(1.0, 0.1, 2.0)],
		[NAN, 1.0 / 30.0, Vector3.ONE],
		[INF, 1.0 / 30.0, Vector3.ONE],
		[0.25, NAN, Vector3.ONE],
		[0.25, INF, Vector3.ONE],
		[0.25, 1.0 / 30.0, Vector3(NAN, 1.0, 1.0)],
		[0.25, 1.0 / 30.0, Vector3(INF, 1.0, 1.0)],
	]
	for test_case in finite_cases:
		var effective := _effective_diffusion(float(test_case[0]), float(test_case[1]), test_case[2])
		if not is_finite(effective) or effective < 0.0:
			return _fail("Non-finite diffusion input escaped safe fallback")
	return true


func _effective_diffusion(requested: float, dt: float, voxel: Vector3) -> float:
	if not is_finite(requested) or not is_finite(dt) or dt <= DIFFUSION_EPSILON or not voxel.is_finite():
		return 0.0
	var safe_voxel := Vector3(maxf(voxel.x, DIFFUSION_EPSILON), maxf(voxel.y, DIFFUSION_EPSILON), maxf(voxel.z, DIFFUSION_EPSILON))
	var inverse_h2 := Vector3(1.0 / (safe_voxel.x * safe_voxel.x), 1.0 / (safe_voxel.y * safe_voxel.y), 1.0 / (safe_voxel.z * safe_voxel.z))
	var inverse_h2_sum := inverse_h2.x + inverse_h2.y + inverse_h2.z
	var denominator := dt * inverse_h2_sum
	if not inverse_h2.is_finite() or not is_finite(inverse_h2_sum) or inverse_h2_sum <= 0.0 or not is_finite(denominator) or denominator <= 0.0:
		return 0.0
	var max_stable_diffusion := DIFFUSION_STABILITY_LIMIT / maxf(denominator, DIFFUSION_EPSILON)
	if not is_finite(max_stable_diffusion):
		return 0.0
	return minf(maxf(requested, 0.0), max_stable_diffusion)


func _max_stable_diffusion(dt: float, voxel: Vector3) -> float:
	if not is_finite(dt) or dt <= DIFFUSION_EPSILON or not voxel.is_finite():
		return 0.0
	var denominator := dt * _inverse_h2_sum(voxel)
	if not is_finite(denominator) or denominator <= 0.0:
		return 0.0
	return DIFFUSION_STABILITY_LIMIT / maxf(denominator, DIFFUSION_EPSILON)


func _inverse_h2_sum(voxel: Vector3) -> float:
	var safe_voxel := Vector3(maxf(voxel.x, DIFFUSION_EPSILON), maxf(voxel.y, DIFFUSION_EPSILON), maxf(voxel.z, DIFFUSION_EPSILON))
	return 1.0 / (safe_voxel.x * safe_voxel.x) + 1.0 / (safe_voxel.y * safe_voxel.y) + 1.0 / (safe_voxel.z * safe_voxel.z)


func _sigma(effective: float, dt: float, voxel: Vector3) -> float:
	return effective * dt * _inverse_h2_sum(voxel)


func _approximately_equal(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual - expected) <= TEST_EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_BUBBLE_DIFFUSION_FAIL: %s" % reason)
	return false
