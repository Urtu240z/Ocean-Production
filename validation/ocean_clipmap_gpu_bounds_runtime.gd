extends SceneTree
## H2.3 clipmap bounds contract and temporal GPU lifecycle check.
## The first block is renderer-independent and validates every L0..Ln AABB.
## The second block drives the real P0 scene when a RenderingDevice exists.

const Surface := preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
const QualityProfile := preload("res://addons/ocean/core/ocean_quality_profile.gd")
const FftConfig := preload("res://addons/ocean/core/ocean_fft_config.gd")
const CrestProfile := preload("res://addons/ocean/core/ocean_crest_foam_profile.gd")

const H_VALUES := [0.5, 1.0, 2.0, 4.0]
const V_VALUES := [0.5, 1.0, 2.0, 4.0]
const PITCH_SEQUENCE := [-25.0, -10.0, 0.0, 10.0, 25.0, 40.0]
const RUNTIME_H_SEQUENCE := [1.0, 0.5, 2.0, 4.0, 1.0]
const RUNTIME_V_SEQUENCE := [1.0, 0.5, 2.0, 4.0, 1.0]
const BREAKER_AUTHORING_DISPLACEMENT := Vector3(3.25, 1.75, -2.5)
const CPU_REBUILD_CYCLES := 16
const GPU_LIFECYCLE_CYCLES := 4
const READY_TIMEOUT_FRAMES := 240

var _cpu_surface: Node
var _test_camera: Camera3D
var _scene: Node
var _ocean: Node
var _gpu_stage := 0
var _gpu_cycle := 0
var _gpu_wait_frames := 0
var _waiting_generation := -1
var _gpu_scale_checked := false
var _failed := false


func _initialize() -> void:
	if not _run_cpu_bounds_contract():
		quit(1)
		return
	_scene = load("res://validation/p0_open_ocean.tscn").instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"Ocean")
	if _ocean == null:
		_fail("H2.3 p0 scene/Ocean unavailable")


func _process(_delta: float) -> bool:
	if _failed:
		return false
	var open_ocean: Node = _ocean.get("_open_ocean") as Node if _ocean != null else null
	if open_ocean == null:
		_gpu_wait_frames += 1
		if _gpu_wait_frames >= READY_TIMEOUT_FRAMES:
			if RenderingServer.get_rendering_device() == null:
				print("OCEAN_CLIPMAP_GPU_RUNTIME_BLOCKED reason=RenderingDevice global no disponible")
				quit(2)
			else:
				_fail("H2.3 OpenOceanFFT startup")
		return false
	_gpu_wait_frames = 0
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	var gpu_ready := int(state.get("generation", -1)) >= 0 and int(state.get("published_generation", -1)) == int(state.get("generation", -1)) and bool(state.get("neutral_ready", false)) and bool(state.get("surface_initialized", false))
	if not gpu_ready:
		_gpu_wait_frames += 1
		if _gpu_wait_frames >= READY_TIMEOUT_FRAMES:
			if RenderingServer.get_rendering_device() == null:
				print("OCEAN_CLIPMAP_GPU_RUNTIME_BLOCKED reason=RenderingDevice global no disponible")
				quit(2)
			else:
				_fail("H2.3 resource expected ready after stabilization: %s" % state)
		return false
	_gpu_wait_frames = 0
	if not _validate_gpu_ready(open_ocean, state):
		return false
	if _gpu_stage == 0:
		if not _gpu_scale_checked:
			if not _validate_gpu_scale_sequence(open_ocean):
				return false
			_gpu_scale_checked = true
		_ocean.crest_foam = false
		_gpu_stage = 1
		return false
	if _gpu_stage == 1:
		_ocean.crest_foam = true
		var profile := CrestProfile.new()
		profile.intensity = 0.91 + float(_gpu_cycle) * 0.01
		_ocean.crest_foam_profile = profile
		_gpu_stage = 2
		return false
	if _gpu_stage == 2:
		_waiting_generation = int(state.get("generation", -1))
		_ocean.long_wave_spacing = 1.01
		_ocean.call("_rebuild_if_ready")
		_gpu_stage = 3
		return false
	if _gpu_stage == 3:
		if int(state.get("generation", -1)) == _waiting_generation:
			return false
		_gpu_stage = 4
		return false
	if _gpu_stage == 4:
		_waiting_generation = int(state.get("generation", -1))
		_ocean.long_wave_spacing = 1.0
		_ocean.call("_rebuild_if_ready")
		_gpu_stage = 5
		return false
	if _gpu_stage == 5:
		if int(state.get("generation", -1)) == _waiting_generation:
			return false
		_gpu_cycle += 1
		if _gpu_cycle >= GPU_LIFECYCLE_CYCLES:
			print("OCEAN_CLIPMAP_GPU_LIFECYCLE_PASS cycles=%d" % _gpu_cycle)
			quit(0)
		_gpu_stage = 0
	return false


func _run_cpu_bounds_contract() -> bool:
	_cpu_surface = Surface.new()
	root.add_child(_cpu_surface)
	var quality := QualityProfile.new()
	quality.cells_per_side = 64
	quality.base_spacing_m = 0.25
	quality.level_count = 6
	var configs: Array = []
	for item in [[&"LONG", 512.0, 2.0, 3.0, 16.0, 128.0], [&"MID", 137.0, 0.30, 1.0, 4.0, 20.0], [&"SHORT", 37.0, 0.12, 1.0, 0.5, 5.0]]:
		var config := FftConfig.new()
		config.id = item[0]
		config.domain_size_m = item[1]
		config.measured_hs_m = item[2]
		config.target_hs_m = item[2]
		config.choppiness = item[3]
		config.min_wavelength_m = item[4]
		config.max_wavelength_m = item[5]
		configs.append(config)
	var displacements: Array[Texture2DRD] = []
	var normals: Array[Texture2DRD] = []
	var crest: Array[Texture2DRD] = []
	for _index in 3:
		displacements.append(Texture2DRD.new())
		normals.append(Texture2DRD.new())
		crest.append(Texture2DRD.new())
	_cpu_surface.initialize(quality, 0.0, configs, displacements, normals, crest)
	if not _validate_breaker_source_contract():
		return false
	if not _validate_breaker_horizontal_scale_parity():
		return false
	print("OCEAN_BREAKER_HORIZONTAL_SCALE_PARITY_PASS")
	if not _validate_breaker_axis_scale_contract():
		return false
	print("OCEAN_BREAKER_AXIS_SCALE_CONTRACT_PASS")
	if not _validate_breaker_baseline_parity():
		return false
	print("OCEAN_BREAKER_BASELINE_PARITY_PASS")
	if not _validate_cpu_contract():
		return false
	print("OCEAN_CLIPMAP_GPU_BOUNDS_AUDIT_PASS scales=%d*%d levels=%d" % [H_VALUES.size(), V_VALUES.size(), _cpu_surface.get_clipmap_culling_bounds_contract().size()])
	print("OCEAN_CLIPMAP_BOUNDS_CONTRACT_PASS levels=%d" % _cpu_surface.get_clipmap_culling_bounds_contract().size())
	if not _validate_real_camera_culling():
		return false
	print("OCEAN_CLIPMAP_CULLING_PITCH_PASS pitches=%d camera=Camera3D" % PITCH_SEQUENCE.size())
	print("OCEAN_CLIPMAP_REAL_CAMERA_CULLING_PASS pitches=%d scales=%d" % [PITCH_SEQUENCE.size(), H_VALUES.size()])
	if not _validate_runtime_scale_sequence():
		return false
	print("OCEAN_CLIPMAP_RUNTIME_BOUNDS_PASS stages=%d" % RUNTIME_H_SEQUENCE.size())
	if not _validate_bounds_sanity():
		return false
	print("OCEAN_CLIPMAP_BOUNDS_SANITY_PASS cycles=%d" % CPU_REBUILD_CYCLES)
	_cpu_surface.shutdown()
	_cpu_surface.queue_free()
	_cpu_surface = null
	return true


func _validate_cpu_contract() -> bool:
	var contract: Array = _cpu_surface.get_clipmap_culling_bounds_contract()
	if contract.size() != 6:
		_fail("H2.3 expected all L0..Ln bounds, got %d" % contract.size())
		return false
	for entry in contract:
		var authored: AABB = entry["authored_aabb"]
		var custom: AABB = entry["custom_aabb"]
		if not _aabb_contains(custom, authored):
			_fail("H2.3 custom AABB does not contain authored mesh at level %d" % int(entry["level"]))
			return false
		if float(entry["extra_cull_margin"]) != 4.0:
			_fail("H2.3 safety margin changed unexpectedly")
			return false
	var updates_before_noop := int(_cpu_surface.get_clipmap_culling_bounds_state().get("update_count", -1))
	_cpu_surface.set_clipmap_geometry_scale(1.0)
	_cpu_surface.set_surface_scale(1.0)
	var updates_after_noop := int(_cpu_surface.get_clipmap_culling_bounds_state().get("update_count", -1))
	if updates_after_noop != updates_before_noop:
		_fail("H2.3 unchanged scale performed a redundant bounds update")
		return false
	for horizontal in H_VALUES:
		for vertical in V_VALUES:
			_cpu_surface.set_clipmap_geometry_scale(horizontal)
			_cpu_surface.set_surface_scale(vertical)
			if not _validate_expected_aabbs(_cpu_surface.get_clipmap_culling_bounds_contract()):
				return false
	_cpu_surface.set_clipmap_geometry_scale(1.0)
	_cpu_surface.set_surface_scale(1.0)
	return true


func _validate_breaker_source_contract() -> bool:
	var source := FileAccess.get_file_as_string("res://addons/ocean/surface/ocean_clipmap_surface.gd")
	if not source.contains("float wavelength_m = max(metrics.g, 0.001);"):
		_fail("H2.4 breaker wavelength is not authored in Ocean Space")
		return false
	if source.contains("metrics.g * clipmap_geometry_scale"):
		_fail("H2.4 breaker source still contains horizontal H² wavelength scaling")
		return false
	if source.contains("ocean_surface_scale * ocean_surface_scale"):
		_fail("H2.4 breaker source contains vertical V² scaling")
		return false
	var breaker_displacement := source.find("long_displacement.xz += propagation_direction * delta_s")
	var final_horizontal_scale := source.find("surface_displacement.xz *= clipmap_geometry_scale")
	var final_vertical_scale := source.find("surface_displacement.y *= ocean_surface_scale")
	if breaker_displacement < 0 or final_horizontal_scale < 0 or final_vertical_scale < 0 or breaker_displacement > final_horizontal_scale or breaker_displacement > final_vertical_scale:
		_fail("H2.4 breaker displacement is not followed by the single final surface transform")
		return false
	return true


func _breaker_world_displacement(authoring: Vector3, horizontal_scale: float, vertical_scale: float) -> Vector3:
	return Vector3(authoring.x * absf(horizontal_scale), authoring.y * absf(vertical_scale), authoring.z * absf(horizontal_scale))


func _validate_breaker_horizontal_scale_parity() -> bool:
	for horizontal in H_VALUES:
		var actual := _breaker_world_displacement(BREAKER_AUTHORING_DISPLACEMENT, horizontal, 1.0)
		var expected := Vector3(BREAKER_AUTHORING_DISPLACEMENT.x * horizontal, BREAKER_AUTHORING_DISPLACEMENT.y, BREAKER_AUTHORING_DISPLACEMENT.z * horizontal)
		if not actual.is_equal_approx(expected) or actual.is_equal_approx(_breaker_world_displacement(BREAKER_AUTHORING_DISPLACEMENT, horizontal * horizontal, 1.0)) and not is_equal_approx(horizontal, 1.0):
			_fail("H2.4 breaker horizontal scale is not linear at H=%s" % horizontal)
			return false
	return true


func _validate_breaker_axis_scale_contract() -> bool:
	for pair in [[0.5, 1.0], [2.0, 1.0], [1.0, 0.5], [1.0, 2.0], [0.5, 0.5], [2.0, 2.0]]:
		var horizontal: float = pair[0]
		var vertical: float = pair[1]
		var actual := _breaker_world_displacement(BREAKER_AUTHORING_DISPLACEMENT, horizontal, vertical)
		var expected := Vector3(BREAKER_AUTHORING_DISPLACEMENT.x * horizontal, BREAKER_AUTHORING_DISPLACEMENT.y * vertical, BREAKER_AUTHORING_DISPLACEMENT.z * horizontal)
		if not actual.is_equal_approx(expected) or not is_equal_approx(actual.y, BREAKER_AUTHORING_DISPLACEMENT.y * vertical):
			_fail("H2.4 breaker axis scale cross-coupling at H=%s V=%s" % [horizontal, vertical])
			return false
	return true


func _validate_breaker_baseline_parity() -> bool:
	var baseline := _breaker_world_displacement(BREAKER_AUTHORING_DISPLACEMENT, 1.0, 1.0)
	if not baseline.is_equal_approx(BREAKER_AUTHORING_DISPLACEMENT):
		_fail("H2.4 breaker H=1/V=1 baseline changed")
		return false
	return true


func _validate_real_camera_culling() -> bool:
	_cpu_surface.rotation = Vector3.ZERO
	_cpu_surface.set_surface_scale(1.0)
	_test_camera = Camera3D.new()
	_test_camera.name = &"H23RealCullingCamera"
	_test_camera.position = Vector3(0.0, 8.0, 16.0)
	_test_camera.near = 0.05
	_test_camera.far = 2000.0
	_test_camera.fov = 75.0
	_test_camera.current = true
	root.add_child(_test_camera)
	var expected_samples := 0
	for horizontal in H_VALUES:
		_cpu_surface.set_clipmap_geometry_scale(horizontal)
		for pitch in PITCH_SEQUENCE:
			_test_camera.rotation_degrees = Vector3(pitch, 0.0, 0.0)
			var planes: Array = _test_camera.get_frustum()
			if planes.size() != 6:
				_fail("H2.4 Camera3D returned %d frustum planes at H=%s pitch=%s" % [planes.size(), horizontal, pitch])
				return false
			var forward := -_test_camera.global_transform.basis.z.normalized()
			var inside_point := _test_camera.global_position + forward * ((_test_camera.near + _test_camera.far) * 0.5)
			for entry in _cpu_surface.get_clipmap_culling_bounds_contract():
				var authored_effective := Surface.build_gpu_culling_aabb(entry["authored_aabb"], horizontal, 1.0, 0.0, 0.0)
				var expected_world := _transform_aabb(authored_effective, _cpu_surface.global_transform)
				var custom_world := _transform_aabb(entry["custom_aabb"] as AABB, _cpu_surface.global_transform)
				var should_intersect := _aabb_intersects_frustum(expected_world, planes, inside_point)
				if should_intersect:
					expected_samples += 1
					if not _aabb_intersects_frustum(custom_world, planes, inside_point):
						_fail("H2.4 real camera would cull expected L%d at H=%s pitch=%s" % [int(entry["level"]), horizontal, pitch])
						return false
			if not _cpu_surface.rotation.is_equal_approx(Vector3.ZERO):
				_fail("H2.4 pitch test rotated the Ocean Surface")
				return false
	if expected_samples == 0:
		_fail("H2.4 Camera3D frustum did not intersect any expected clipmap geometry")
		return false
	_cpu_surface.set_clipmap_geometry_scale(1.0)
	_cpu_surface.set_surface_scale(1.0)
	_test_camera.queue_free()
	_test_camera = null
	return true


func _aabb_intersects_frustum(aabb: AABB, planes: Array, inside_point: Vector3) -> bool:
	for plane in planes:
		var inside_distance: float = plane.distance_to(inside_point)
		if inside_distance >= 0.0:
			if plane.distance_to(aabb.get_support(plane.normal)) < -0.0001:
				return false
		else:
			if plane.distance_to(aabb.get_support(-plane.normal)) > 0.0001:
				return false
	return true


func _validate_runtime_scale_sequence() -> bool:
	var baseline: Array = _cpu_surface.get_clipmap_culling_bounds_contract()
	var baseline_ids := _instance_and_mesh_ids(baseline)
	var baseline_bounds := _aabbs(baseline)
	for index in RUNTIME_H_SEQUENCE.size():
		_cpu_surface.set_clipmap_geometry_scale(RUNTIME_H_SEQUENCE[index])
		_cpu_surface.set_surface_scale(RUNTIME_V_SEQUENCE[index])
		var contract: Array = _cpu_surface.get_clipmap_culling_bounds_contract()
		if _instance_and_mesh_ids(contract) != baseline_ids:
			_fail("H2.3 runtime scale rebuilt mesh instances or meshes at stage %d" % index)
			return false
		if not _validate_expected_aabbs(contract):
			return false
	_cpu_surface.set_clipmap_geometry_scale(1.0)
	_cpu_surface.set_surface_scale(1.0)
	var restored := _aabbs(_cpu_surface.get_clipmap_culling_bounds_contract())
	if restored != baseline_bounds:
		_fail("H2.3 baseline AABB did not restore exactly")
		return false
	return true


func _validate_expected_aabbs(contract: Array) -> bool:
	var bounds: Dictionary = _cpu_surface.get_clipmap_culling_bounds_state()
	for entry in contract:
		var expected := Surface.build_gpu_culling_aabb(entry["authored_aabb"], bounds["horizontal_scale"], bounds["vertical_scale"], bounds["horizontal_displacement_world_m"], bounds["vertical_displacement_world_m"])
		if not _aabb_equal(entry["custom_aabb"], expected):
			_fail("H2.3 runtime AABB diverged at L%d" % int(entry["level"]))
			return false
	return true


func _validate_bounds_sanity() -> bool:
	for _cycle in CPU_REBUILD_CYCLES:
		_cpu_surface.set_crest_foam_enabled(false)
		_cpu_surface.set_crest_foam_enabled(true)
		var profile := CrestProfile.new()
		profile.intensity = 0.75 + float(_cycle % 4) * 0.05
		_cpu_surface.set_crest_foam_profile(profile)
		_cpu_surface.shutdown()
		if not _cpu_surface.get_clipmap_culling_bounds_contract().is_empty():
			_fail("H2.3 shutdown left published clipmap bounds")
			return false
		var quality := QualityProfile.new()
		quality.cells_per_side = 64
		quality.base_spacing_m = 0.25
		quality.level_count = 6
		var configs: Array = []
		for item in [[&"LONG", 512.0, 2.0, 3.0, 16.0, 128.0], [&"MID", 137.0, 0.30, 1.0, 4.0, 20.0], [&"SHORT", 37.0, 0.12, 1.0, 0.5, 5.0]]:
			var config := FftConfig.new()
			config.id = item[0]
			config.domain_size_m = item[1]
			config.measured_hs_m = item[2]
			config.target_hs_m = item[2]
			config.choppiness = item[3]
			config.min_wavelength_m = item[4]
			config.max_wavelength_m = item[5]
			configs.append(config)
		var d: Array[Texture2DRD] = [Texture2DRD.new(), Texture2DRD.new(), Texture2DRD.new()]
		var n: Array[Texture2DRD] = [Texture2DRD.new(), Texture2DRD.new(), Texture2DRD.new()]
		var c: Array[Texture2DRD] = [Texture2DRD.new(), Texture2DRD.new(), Texture2DRD.new()]
		_cpu_surface.initialize(quality, 0.0, configs, d, n, c)
		if not _validate_cpu_contract() or not _validate_expected_aabbs(_cpu_surface.get_clipmap_culling_bounds_contract()):
			return false
	return true


func _validate_gpu_ready(open_ocean: Node, state: Dictionary) -> bool:
	var generation := int(state.get("generation", -1))
	if generation < 0 or int(state.get("published_generation", -1)) != generation or not bool(state.get("neutral_ready", false)) or not bool(state.get("surface_initialized", false)):
		return false
	for band in state.get("bands", []):
		for key in ["displacement_valid", "normal_valid", "crest_valid"]:
			if not bool(band.get(key, false)):
				_fail("H2.3 invalid published RID in generation %d" % generation)
				return false
		if int(band.get("solver_generation", -1)) != generation or int(band.get("published_generation", -1)) != generation:
			_fail("H2.3 old generation published over current generation")
			return false
	var surface: Node = open_ocean.get_underwater_medium_raster_surface() as Node
	if surface == null or surface.get_clipmap_culling_bounds_contract().is_empty():
		_fail("H2.3 runtime surface bounds unavailable")
		return false
	return true


func _validate_gpu_scale_sequence(open_ocean: Node) -> bool:
	var surface: Node = open_ocean.get_underwater_medium_raster_surface() as Node
	if surface == null:
		_fail("H2.3 runtime surface unavailable for scale sequence")
		return false
	var baseline_generation := int(open_ocean.get_fft_resource_lifecycle_state().get("generation", -1))
	var baseline_contract: Array = surface.get_clipmap_culling_bounds_contract()
	var baseline_ids := _instance_and_mesh_ids(baseline_contract)
	var baseline_state: Dictionary = surface.get_clipmap_culling_bounds_state()
	for index in RUNTIME_H_SEQUENCE.size():
		_ocean.clipmap_geometry_scale = RUNTIME_H_SEQUENCE[index]
		_ocean.ocean_scale = RUNTIME_V_SEQUENCE[index]
		var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
		var contract: Array = surface.get_clipmap_culling_bounds_contract()
		if int(state.get("generation", -1)) != baseline_generation:
			_fail("H2.3 runtime scale triggered an FFT rebuild at stage %d" % index)
			return false
		if _instance_and_mesh_ids(contract) != baseline_ids or contract.size() != 6:
			_fail("H2.3 runtime scale changed clipmap resources at stage %d" % index)
			return false
		if not bool(surface.visible) or not _validate_expected_aabbs_runtime(surface, contract):
			_fail("H2.3 runtime scale left surface/bounds inconsistent at stage %d" % index)
			return false
	var updates_before_noop := int(surface.get_clipmap_culling_bounds_state().get("update_count", -1))
	_ocean.clipmap_geometry_scale = RUNTIME_H_SEQUENCE[-1]
	_ocean.ocean_scale = RUNTIME_V_SEQUENCE[-1]
	if int(surface.get_clipmap_culling_bounds_state().get("update_count", -1)) != updates_before_noop:
		_fail("H2.3 runtime repeated scale caused a redundant AABB update")
		return false
	_ocean.clipmap_geometry_scale = 1.0
	_ocean.ocean_scale = 1.0
	if int(open_ocean.get_fft_resource_lifecycle_state().get("generation", -1)) != baseline_generation:
		_fail("H2.3 runtime scale restore changed FFT generation")
		return false
	if _aabbs(surface.get_clipmap_culling_bounds_contract()) != _aabbs(baseline_contract):
		_fail("H2.3 runtime scale baseline bounds did not restore")
		return false
	if baseline_state.get("horizontal_scale", 1.0) != 1.0 or baseline_state.get("vertical_scale", 1.0) != 1.0:
		_fail("H2.3 unexpected runtime scale baseline")
		return false
	return true


func _validate_expected_aabbs_runtime(surface: Node, contract: Array) -> bool:
	var bounds: Dictionary = surface.get_clipmap_culling_bounds_state()
	for entry in contract:
		var expected := Surface.build_gpu_culling_aabb(entry["authored_aabb"], bounds["horizontal_scale"], bounds["vertical_scale"], bounds["horizontal_displacement_world_m"], bounds["vertical_displacement_world_m"])
		if not _aabb_equal(entry["custom_aabb"], expected):
			return false
	return true


func _instance_and_mesh_ids(contract: Array) -> Array:
	var ids: Array = []
	for entry in contract:
		ids.append([entry["instance_id"], entry["mesh_id"]])
	return ids


func _aabbs(contract: Array) -> Array:
	var result: Array = []
	for entry in contract:
		result.append(entry["custom_aabb"])
	return result


func _aabb_equal(a: AABB, b: AABB) -> bool:
	return a.position.is_equal_approx(b.position) and a.size.is_equal_approx(b.size)


func _aabb_contains(container: AABB, contained: AABB) -> bool:
	var container_max := container.position + container.size
	var contained_max := contained.position + contained.size
	return container.position.x <= contained.position.x and container.position.y <= contained.position.y and container.position.z <= contained.position.z and container_max.x >= contained_max.x and container_max.y >= contained_max.y and container_max.z >= contained_max.z


func _transform_aabb(source: AABB, transform: Transform3D) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for x in [source.position.x, source.position.x + source.size.x]:
		for y in [source.position.y, source.position.y + source.size.y]:
			for z in [source.position.z, source.position.z + source.size.z]:
				var point := transform * Vector3(x, y, z)
				minimum.x = minf(minimum.x, point.x)
				minimum.y = minf(minimum.y, point.y)
				minimum.z = minf(minimum.z, point.z)
				maximum.x = maxf(maximum.x, point.x)
				maximum.y = maxf(maximum.y, point.y)
				maximum.z = maxf(maximum.z, point.z)
	return AABB(minimum, maximum - minimum)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
