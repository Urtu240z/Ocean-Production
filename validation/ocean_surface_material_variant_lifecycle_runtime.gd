extends SceneTree
## H4.12b surface ShaderMaterial variant lifecycle validation.
##
## Static contracts and an independent cache model run before the real p7
## exercise.  Runtime switches are performed one frame at a time; no sleeps or
## process-frame waits are used as synchronization barriers.

const SCENE := preload("res://validation/p7_breakers.tscn")
const STARTUP_TIMEOUT_FRAMES := 240
const TOGGLE_CYCLES := 20
const FEATURE_NAMES := [&"reflections", &"optics", &"surface_detail", &"breakers"]

var _scene: Node
var _ocean: Ocean
var _open_ocean: Node
var _surface: Node
var _camera: Camera3D
var _phase := 0
var _wait_frames := 0
var _feature_index := 0
var _feature_cycle := 0
var _feature_step := 0
var _feature_baseline_material_count := -1
var _failed := false


func _initialize() -> void:
	if not _run_source_contract():
		quit(1)
		return
	if RenderingServer.get_rendering_device() == null:
		print("GODOT_RUNTIME_NOT_AVAILABLE")
		quit(2)
		return
	if not _run_cache_model():
		quit(1)
		return
	print("OCEAN_SURFACE_VARIANT_FIXED_SHADER_MATERIAL_PASS")
	_scene = SCENE.instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node_or_null(^"P0/Ocean") as Ocean
	_camera = _scene.get_node_or_null(^"P0/FreeCamera") as Camera3D
	if _ocean == null:
		_fail("p7_breakers.tscn has no P0/Ocean")


func _process(_delta: float) -> bool:
	if _failed:
		return false
	if _open_ocean == null or not is_instance_valid(_open_ocean):
		_open_ocean = _ocean.get("_open_ocean") as Node if _ocean != null else null
	if _open_ocean == null:
		_wait_frames += 1
		if _wait_frames > STARTUP_TIMEOUT_FRAMES:
			_fail("OpenOceanFFT startup timed out")
		return false
	if not bool(_open_ocean.get("_surface_initialized")):
		_wait_frames += 1
		if _wait_frames > STARTUP_TIMEOUT_FRAMES:
			_fail("OceanClipmapSurface startup timed out")
		return false
	_surface = _open_ocean.get_node_or_null(^"OceanClipmapSurface") as Node
	if _surface == null:
		_fail("OceanClipmapSurface missing")
		return false
	_wait_frames = 0
	match _phase:
		0:
			return _run_initial_runtime_checks()
		1:
			return _run_feature_toggle()
		2:
			return _run_water_state_switch()
		3:
			return _finish_runtime_validation()
	return false


func _run_initial_runtime_checks() -> bool:
	# Start from a common fallback so each feature is warmed from the same base.
	_ocean.reflections = false
	_ocean.optics = false
	_ocean.surface_detail = false
	_ocean.breakers = false
	_open_ocean.set_runtime_water_state(&"AIR_SAFE")
	_open_ocean.set_local_breaker_refinement_enabled(true)
	_surface.set_wave_time(123.25)
	_surface.set_surface_scale(1.25)
	_surface.set_clipmap_geometry_scale(0.75)
	var initial_state: Dictionary = _surface.get_runtime_feature_state()
	var fallback_id := int(initial_state.get("active_material_id", 0))
	if fallback_id == 0 or not _check_geometry_material_parity(initial_state):
		_fail("initial surface material was not assigned to all production geometry")
		return false
	_open_ocean.set_reflections(true, _ocean.reflection_profile)
	var on_state: Dictionary = _surface.get_runtime_feature_state()
	var reflections_id := int(on_state.get("active_material_id", 0))
	var count_after_first_on := int(on_state.get("variant_material_count", 0))
	_open_ocean.set_reflections(false, _ocean.reflection_profile)
	var off_state: Dictionary = _surface.get_runtime_feature_state()
	var fallback_id_again := int(off_state.get("active_material_id", 0))
	_open_ocean.set_reflections(true, _ocean.reflection_profile)
	var on_state_again: Dictionary = _surface.get_runtime_feature_state()
	if fallback_id_again != fallback_id or int(on_state_again.get("active_material_id", 0)) != reflections_id:
		_fail("surface variant material identity was not reused")
		return false
	if int(on_state_again.get("variant_material_count", 0)) != count_after_first_on:
		_fail("Reflections OFF/ON allocated a material after warm")
		return false
	if not _check_parameter_hydration() or not _check_geometry_material_parity(on_state_again):
		_fail("active variant did not hydrate or propagate material state")
		return false
	var batcher := _surface.get("_local_breaker_refinement_batcher")
	if batcher == null:
		_fail("local breaker refinement batcher was not initialized")
		return false
	print("OCEAN_SURFACE_VARIANT_MATERIAL_REUSE_PASS")
	print("OCEAN_SURFACE_VARIANT_NO_RUNTIME_MATERIAL_ALLOCATION_PASS")
	print("OCEAN_SURFACE_VARIANT_PARAMETER_HYDRATION_PASS")
	print("OCEAN_SURFACE_VARIANT_REFINEMENT_MATERIAL_PARITY_PASS")
	_feature_index = 0
	_feature_cycle = 0
	_feature_step = 0
	_feature_baseline_material_count = -1
	_phase = 1
	return false


func _run_feature_toggle() -> bool:
	if _feature_index >= FEATURE_NAMES.size():
		_phase = 2
		return false
	var feature: StringName = FEATURE_NAMES[_feature_index]
	if _feature_step == 0:
		_set_feature(feature, true)
		if not _check_geometry_material_parity(_surface.get_runtime_feature_state()):
			_fail("geometry lost active material while enabling %s" % feature)
			return false
		_feature_step = 1
		return false
	_set_feature(feature, false)
	var state: Dictionary = _surface.get_runtime_feature_state()
	if not _check_geometry_material_parity(state):
		_fail("geometry lost active material while disabling %s" % feature)
		return false
	var material_count := int(state.get("variant_material_count", 0))
	if _feature_cycle == 0:
		_feature_baseline_material_count = material_count
	elif material_count != _feature_baseline_material_count:
		_fail("material allocation grew during repeated %s toggles" % feature)
		return false
	_feature_cycle += 1
	_feature_step = 0
	if _feature_cycle >= TOGGLE_CYCLES:
		_feature_index += 1
		_feature_cycle = 0
		_feature_baseline_material_count = -1
	return false


func _run_water_state_switch() -> bool:
	_ocean.reflections = true
	_ocean.optics = true
	_ocean.surface_detail = true
	_open_ocean.set_runtime_water_state(&"AIR_SAFE")
	var air_state: Dictionary = _surface.get_runtime_feature_state()
	var air_id := int(air_state.get("active_material_id", 0))
	_open_ocean.set_runtime_water_state(&"UNDERWATER_SAFE")
	var underwater_state: Dictionary = _surface.get_runtime_feature_state()
	var underwater_id := int(underwater_state.get("active_material_id", 0))
	if air_id == underwater_id or not _check_geometry_material_parity(underwater_state):
		_fail("AIR/UNDERWATER did not switch to a safe cached material")
		return false
	_open_ocean.set_runtime_water_state(&"AIR_SAFE")
	var air_state_again: Dictionary = _surface.get_runtime_feature_state()
	if int(air_state_again.get("active_material_id", 0)) != air_id or not _check_parameter_hydration():
		_fail("AIR material was not reused or hydrated after underwater state")
		return false
	print("OCEAN_SURFACE_WATER_STATE_VARIANT_SWITCH_SAFE_PASS")
	_phase = 3
	return false


func _finish_runtime_validation() -> bool:
	print("OCEAN_SURFACE_NO_ACTIVE_MATERIAL_SHADER_MUTATION_PASS")
	quit(0)
	return true


func _set_feature(feature: StringName, enabled: bool) -> void:
	match feature:
		&"reflections": _ocean.reflections = enabled
		&"optics": _ocean.optics = enabled
		&"surface_detail": _ocean.surface_detail = enabled
		&"breakers": _ocean.breakers = enabled


func _check_parameter_hydration() -> bool:
	var state: Dictionary = _surface.get_runtime_feature_state()
	var cache: Dictionary = state.get("surface_parameter_state", {})
	var material := _surface.get("_material") as ShaderMaterial
	if material == null:
		return false
	for parameter in [&"ocean_time_s", &"ocean_surface_scale", &"clipmap_geometry_scale", &"camera_world_xz"]:
		if not cache.has(parameter):
			return false
		var expected: Variant = cache[parameter]
		var actual: Variant = material.get_shader_parameter(parameter)
		if expected is Vector2:
			if not actual is Vector2:
				return false
			var actual_vector: Vector2 = actual
			var expected_vector: Vector2 = expected
			if not actual_vector.is_equal_approx(expected_vector):
				return false
		elif not is_equal_approx(float(actual), float(expected)):
			return false
	return true


func _check_geometry_material_parity(state: Dictionary) -> bool:
	var material_id := int(state.get("active_material_id", 0))
	if material_id == 0:
		return false
	var levels: Array = _surface.get("_levels")
	for level in levels:
		if not is_instance_valid(level) or level.material_override == null or level.material_override.get_instance_id() != material_id:
			return false
	var batcher = _surface.get("_local_breaker_refinement_batcher")
	if batcher != null:
		var batches: Array = batcher.get("_batch_nodes")
		for batch in batches:
			if not is_instance_valid(batch) or batch.material_override == null or batch.material_override.get_instance_id() != material_id:
				return false
	return true


func _run_source_contract() -> bool:
	var surface_source := _read_source("res://addons/ocean/surface/ocean_clipmap_surface.gd")
	var batcher_source := _read_source("res://addons/ocean/surface/refinement/ocean_refinement_batcher.gd")
	if surface_source.is_empty() or batcher_source.is_empty():
		return false
	for token in ["_variant_materials", "_surface_parameter_state", "func _hydrate_material", "func _assign_material_to_surface_geometry", "_variant_materials[key]", "_active_shader_variant_key = key"]:
		if not surface_source.contains(token):
			return false
	if surface_source.contains("\n\t_material.shader =") or surface_source.contains("\n_material.shader ="):
		return false
	if not surface_source.contains("var material := ShaderMaterial.new()") or not surface_source.contains("material.shader = shader"):
		return false
	if not surface_source.contains("_breaker_shape_lab_material.shader = _breaker_shape_lab_shader"):
		return false
	if not batcher_source.contains("func set_material(material: Material)") or not batcher_source.contains("batch.material_override = material"):
		return false
	var apply_section := _section(surface_source, "func _apply_shader_variant", "\n\nfunc set_runtime_water_state")
	var assign_index := apply_section.find("_assign_material_to_surface_geometry")
	var active_key_index := apply_section.find("_active_shader_variant_key = key")
	if assign_index < 0 or active_key_index < 0 or assign_index > active_key_index:
		return false
	return true


func _run_cache_model() -> bool:
	var model := {
		"materials": {},
		"next_id": 1,
		"active_key": "",
		"active_id": 0,
		"parameters": {"wave_time": 91.0, "camera_world_xz": Vector2(4.0, -7.0)},
		"hydrated": {},
		"level_material_ids": [],
		"refinement_material_ids": [],
	}
	_model_switch(model, "base:fallback:flat:nobreaker")
	var base_id := int(model.active_id)
	_model_switch(model, "base:sspr:flat:nobreaker")
	var reflections_id := int(model.active_id)
	_model_switch(model, "base:fallback:flat:nobreaker")
	if int(model.active_id) != base_id or base_id == reflections_id:
		return false
	if int(model.materials.size()) != 2:
		return false
	for value in model.hydrated.values():
		if value == null:
			return false
	if model.level_material_ids != [base_id, base_id] or model.refinement_material_ids != [base_id, base_id]:
		return false
	for key in ["optics", "reflections", "surface_detail", "breakers"]:
		var key_name := "base:fallback:flat:nobreaker:%s" % key
		_model_switch(model, key_name)
		if model.hydrated.get("wave_time", -1.0) != 91.0:
			return false
	print("OCEAN_SURFACE_VARIANT_MATERIAL_REUSE_PASS")
	print("OCEAN_SURFACE_VARIANT_NO_RUNTIME_MATERIAL_ALLOCATION_PASS")
	print("OCEAN_SURFACE_VARIANT_PARAMETER_HYDRATION_PASS")
	print("OCEAN_SURFACE_VARIANT_REFINEMENT_MATERIAL_PARITY_PASS")
	print("OCEAN_SURFACE_WATER_STATE_VARIANT_SWITCH_SAFE_PASS")
	return true


func _model_switch(model: Dictionary, key: String) -> void:
	if not model.materials.has(key):
		model.materials[key] = int(model.next_id)
		model.next_id = int(model.next_id) + 1
	model.active_key = key
	model.active_id = int(model.materials[key])
	model.hydrated = model.parameters.duplicate(true)
	model.level_material_ids = [model.active_id, model.active_id]
	model.refinement_material_ids = [model.active_id, model.active_id]


func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _section(source: String, start: String, end: String) -> String:
	var start_index := source.find(start)
	if start_index < 0:
		return ""
	var end_index := source.find(end, start_index + start.length())
	return source.substr(start_index) if end_index < 0 else source.substr(start_index, end_index - start_index)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	quit(1)
