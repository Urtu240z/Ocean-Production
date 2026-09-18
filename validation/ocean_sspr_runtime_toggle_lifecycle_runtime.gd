extends SceneTree
## H4.12a SSPR runtime toggle lifecycle validation.
##
## The state model is deliberately independent from RenderingDevice.  The
## runtime half then stresses the real p7 scene one state transition per frame;
## no sleeps are used as synchronization.

const SCENE := preload("res://validation/p7_breakers.tscn")
const STARTUP_TIMEOUT_FRAMES := 240
const OFF_STABILIZATION_FRAMES := 3
const STRESS_CYCLES := 20

var _scene: Node
var _ocean: Ocean
var _open_ocean: Node
var _camera: Camera3D
var _phase := 0
var _wait_frames := 0
var _off_frames := 0
var _off_baseline: Dictionary = {}
var _stress_cycle := 0
var _sspr_instance_id := 0
var _failed := false


func _initialize() -> void:
	if not _run_source_contract():
		quit(1)
		return
	if RenderingServer.get_rendering_device() == null:
		print("GODOT_RUNTIME_NOT_AVAILABLE")
		quit(2)
		return
	if not _run_state_model():
		quit(1)
		return
	_scene = SCENE.instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node_or_null(^"P0/Ocean") as Ocean
	_camera = _scene.get_node_or_null(^"P0/FreeCamera") as Camera3D
	if _ocean == null:
		_fail("p7_breakers.tscn has no P0/Ocean")
		return


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
				_fail("OpenOceanFFT surface initialization timed out")
			return false
	_wait_frames = 0
	match _phase:
		0:
			return _run_initial_state()
		1:
			return _run_off_stabilization()
		2:
			return _run_water_state_gate()
		3:
			return _run_underwater_toggle()
		4:
			return _run_stress_cycle()
		5:
			return _run_final_shutdown()
	return false


func _run_initial_state() -> bool:
	_open_ocean.set_runtime_water_state(&"AIR_SAFE")
	_open_ocean.set_reflections(true, _ocean.reflection_profile)
	var state: Dictionary = _open_ocean.get_runtime_feature_state()
	if not bool(state.get("sspr", false)) or not bool(state.get("sspr_runtime_active", false)):
		_fail("SSPR did not become resident and active in AIR_SAFE")
		return false
	var sspr := _open_ocean.get("_sspr") as Node
	if sspr == null:
		_fail("SSPR instance missing after enable")
		return false
	_sspr_instance_id = sspr.get_instance_id()
	_off_baseline = _sspr_state(sspr)
	_open_ocean.set_reflections(false, _ocean.reflection_profile)
	state = _open_ocean.get_runtime_feature_state()
	if not bool(state.get("sspr", false)) or bool(state.get("sspr_runtime_active", true)):
		_fail("Reflections OFF did not preserve resident inactive SSPR")
		return false
	_off_baseline = _sspr_state(sspr)
	_off_frames = 0
	_phase = 1
	return false


func _run_off_stabilization() -> bool:
	var state: Dictionary = _open_ocean.get_runtime_feature_state()
	var sspr := _open_ocean.get("_sspr") as Node
	if sspr == null or sspr.get_instance_id() != _sspr_instance_id:
		_fail("Reflections OFF recreated or removed OceanSSPR")
		return false
	if bool(state.get("sspr_runtime_active", true)):
		_fail("Reflections OFF became active during stabilization")
		return false
	var current: Dictionary = _sspr_state(sspr)
	for key in ["project_depth_dispatch_count", "project_source_dispatch_count", "resolve_dispatch_count", "temporal_dispatch_count", "mip_dispatch_count"]:
		if int(current.get(key, 0)) != int(_off_baseline.get(key, 0)):
			_fail("SSPR dispatched while runtime OFF: %s" % key)
			return false
	_off_frames += 1
	if _off_frames < OFF_STABILIZATION_FRAMES:
		return false
	_phase = 2
	return false


func _run_water_state_gate() -> bool:
	_open_ocean.set_runtime_water_state(&"TRANSITION")
	_open_ocean.set_runtime_water_state(&"AIR_SAFE")
	var state: Dictionary = _open_ocean.get_runtime_feature_state()
	if bool(state.get("sspr_runtime_active", true)):
		_fail("AIR state reactivated SSPR while reflections remained OFF")
		return false
	_phase = 3
	return false


func _run_underwater_toggle() -> bool:
	_open_ocean.set_runtime_water_state(&"UNDERWATER_SAFE")
	_open_ocean.set_reflections(true, _ocean.reflection_profile)
	var state: Dictionary = _open_ocean.get_runtime_feature_state()
	if not bool(state.get("sspr", false)) or bool(state.get("sspr_runtime_active", true)):
		_fail("UNDERWATER_SAFE enabled SSPR compute")
		return false
	_open_ocean.set_runtime_water_state(&"AIR_SAFE")
	state = _open_ocean.get_runtime_feature_state()
	if not bool(state.get("sspr_runtime_active", false)):
		_fail("SSPR did not reactivate after leaving UNDERWATER_SAFE")
		return false
	var sspr := _open_ocean.get("_sspr") as Node
	var effect := sspr.get("_effect") as OceanSSPREffect if sspr != null else null
	if effect == null or bool(effect.get_temporal_runtime_state().get("fresh_output", true)):
		_fail("SSPR reactivation did not require fresh output")
		return false
	_stress_cycle = 0
	_phase = 4
	return false


func _run_stress_cycle() -> bool:
	var enabled: bool = (_stress_cycle % 2) == 0
	var water_states: Array[StringName] = [&"AIR_SAFE", &"TRANSITION", &"UNDERWATER_SAFE"]
	var water_state: StringName = water_states[_stress_cycle % water_states.size()]
	_open_ocean.set_runtime_water_state(water_state)
	_open_ocean.set_reflections(enabled, _ocean.reflection_profile)
	if _camera != null:
		_camera.global_position.x = float(_stress_cycle) * 0.75
	var state: Dictionary = _open_ocean.get_runtime_feature_state()
	var expected_active: bool = enabled and water_state != &"UNDERWATER_SAFE"
	if not bool(state.get("sspr", false)) or bool(state.get("sspr_runtime_active", false)) != expected_active:
		_fail("SSPR toggle state mismatch at stress cycle %d" % _stress_cycle)
		return false
	var sspr := _open_ocean.get("_sspr") as Node
	if sspr == null or sspr.get_instance_id() != _sspr_instance_id:
		_fail("SSPR residency changed at stress cycle %d" % _stress_cycle)
		return false
	_stress_cycle += 1
	if _stress_cycle >= STRESS_CYCLES:
		_phase = 5
	return false


func _run_final_shutdown() -> bool:
	var sspr := _open_ocean.get("_sspr") as Node
	var effect := sspr.get("_effect") as OceanSSPREffect if sspr != null else null
	_open_ocean.shutdown()
	if _open_ocean.get("_sspr") != null:
		_fail("OpenOceanFFT final shutdown did not destroy SSPR")
		return false
	if effect != null and not bool(effect.get_temporal_runtime_state().get("shutdown_requested", false)):
		_fail("SSPR effect was freed without begin_shutdown")
		return false
	print("OCEAN_SSPR_RUNTIME_TOGGLE_LIFECYCLE_PASS cycles=%d" % STRESS_CYCLES)
	quit(0)
	return true


func _sspr_state(sspr: Node) -> Dictionary:
	var effect := sspr.get("_effect") as OceanSSPREffect if sspr != null else null
	return effect.get_temporal_runtime_state() if effect != null else {}


func _run_source_contract() -> bool:
	var open_source := _read_source("res://addons/ocean/fft/open_ocean_fft.gd")
	var sspr_source := _read_source("res://addons/ocean/reflections/ocean_sspr.gd")
	var effect_source := _read_source("res://addons/ocean/reflections/ocean_sspr_effect.gd")
	if open_source.is_empty() or sspr_source.is_empty() or effect_source.is_empty():
		return false
	var set_reflections := _section(open_source, "func set_reflections", "\n\nfunc set_reflection_profile")
	var shutdown := _section(open_source, "func shutdown", "\n\nfunc set_optics")
	if set_reflections.contains("_sspr.shutdown()") or set_reflections.contains("queue_free()") or set_reflections.contains("_sspr = null"):
		return false
	for token in ["sspr.shutdown()", "sspr.queue_free()", "_sspr = null"]:
		if not shutdown.contains(token):
			return false
	if not open_source.contains("_reflections_requested and state != &\"UNDERWATER_SAFE\""):
		return false
	if not set_reflections.contains("_reflections_requested and _runtime_water_state != &\"UNDERWATER_SAFE\""):
		return false
	if not sspr_source.contains("Runtime OFF keeps the compositor effect") or not sspr_source.contains("_effect.begin_shutdown()"):
		return false
	if not effect_source.contains("var _shutdown_requested := false") or not effect_source.contains("func begin_shutdown()"):
		return false
	var begin_shutdown := _section(effect_source, "func begin_shutdown", "\n\nfunc has_fresh_output")
	for token in ["_shutdown_requested = true", "_active = false", "_history_valid = false", "_fresh_output = false"]:
		if not begin_shutdown.contains(token):
			return false
	var render_callback := _section(effect_source, "func _render_callback", "\n\nfunc ")
	if not render_callback.contains("shutdown_requested") or not render_callback.contains("_ensure_pipelines()") or not render_callback.contains("_ensure_resources("):
		return false
	if render_callback.count("if shutdown_requested or not active") < 3:
		return false
	var free_resources := _section(effect_source, "func free_resources", "\n\nfunc _render_callback")
	if free_resources.contains("_shutdown_requested = false"):
		return false
	return true


func _run_state_model() -> bool:
	var state: Dictionary = _new_model_state()
	_set_requested(state, true)
	if not bool(state.resident) or not bool(state.runtime_active):
		return false
	_set_requested(state, false)
	var off_dispatches := int(state.dispatches)
	for _i in range(OFF_STABILIZATION_FRAMES):
		_step_model(state)
	if not bool(state.resident) or bool(state.runtime_active) or int(state.dispatches) != off_dispatches:
		return false
	print("OCEAN_SSPR_RUNTIME_OFF_RESIDENT_PASS")
	print("OCEAN_SSPR_RUNTIME_OFF_ZERO_DISPATCH_PASS")
	_set_water_state(state, &"TRANSITION")
	_set_water_state(state, &"AIR_SAFE")
	if bool(state.runtime_active):
		return false
	print("OCEAN_SSPR_REFLECTIONS_OFF_WATER_STATE_SAFE_PASS")
	_set_water_state(state, &"UNDERWATER_SAFE")
	_set_requested(state, true)
	if bool(state.runtime_active):
		return false
	print("OCEAN_SSPR_UNDERWATER_TOGGLE_GATE_PASS")
	_set_water_state(state, &"AIR_SAFE")
	if not bool(state.runtime_active) or not bool(state.fresh_pending) or bool(state.fresh_output):
		return false
	_step_model(state)
	if not bool(state.fresh_output):
		return false
	print("OCEAN_SSPR_REENABLE_FRESH_OUTPUT_PASS")
	for _i in range(STRESS_CYCLES):
		_set_requested(state, false)
		_step_model(state)
		_set_requested(state, true)
		_set_water_state(state, &"UNDERWATER_SAFE" if _i % 3 == 2 else &"AIR_SAFE")
		_step_model(state)
	_set_shutdown(state)
	var dispatches_before_shutdown := int(state.dispatches)
	_step_model(state)
	if not bool(state.shutdown_requested) or bool(state.runtime_active) or int(state.dispatches) != dispatches_before_shutdown:
		return false
	print("OCEAN_SSPR_SHUTDOWN_CALLBACK_GUARD_PASS")
	_set_final_teardown(state)
	if bool(state.resident) or not bool(state.resources_freed):
		return false
	print("OCEAN_SSPR_FINAL_TEARDOWN_PASS")
	return true


func _new_model_state() -> Dictionary:
	return {
		"resident": false,
		"reflections_requested": false,
		"water_state": &"TRANSITION",
		"runtime_active": false,
		"fresh_pending": false,
		"fresh_output": false,
		"dispatches": 0,
		"shutdown_requested": false,
		"resources_freed": false,
	}


func _set_requested(state: Dictionary, enabled: bool) -> void:
	if enabled and not bool(state.resident):
		state.resident = true
	state.reflections_requested = enabled
	_recompute_model_active(state)


func _set_water_state(state: Dictionary, water_state: StringName) -> void:
	state.water_state = water_state
	_recompute_model_active(state)


func _recompute_model_active(state: Dictionary) -> void:
	var next: bool = bool(state.reflections_requested) and state.water_state != &"UNDERWATER_SAFE" and not bool(state.shutdown_requested)
	var previous: bool = bool(state.runtime_active)
	state.runtime_active = next
	if next and not previous:
		state.fresh_pending = true
		state.fresh_output = false
	elif not next:
		state.fresh_pending = false
		state.fresh_output = false


func _step_model(state: Dictionary) -> void:
	if not bool(state.runtime_active):
		return
	state.dispatches = int(state.dispatches) + 1
	if bool(state.fresh_pending):
		state.fresh_pending = false
		state.fresh_output = true


func _set_shutdown(state: Dictionary) -> void:
	state.shutdown_requested = true
	state.reflections_requested = false
	state.runtime_active = false
	state.fresh_pending = false
	state.fresh_output = false


func _set_final_teardown(state: Dictionary) -> void:
	state.resident = false
	state.resources_freed = true


func _read_source(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _section(source: String, start: String, end: String) -> String:
	var start_index := source.find(start)
	if start_index < 0:
		return ""
	var end_index := source.find(end, start_index + start.length())
	if end_index < 0:
		return source.substr(start_index)
	return source.substr(start_index, end_index - start_index)


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	quit(1)
