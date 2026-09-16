extends SceneTree
## H3.1 SSPR temporal lifecycle stress test.
##
## The matrix checks exercise the exact production packing function.  The GPU
## section then drives the compositor through moving-camera, invalidation,
## Temporal OFF, and rapid shutdown/initialize sequences.  It waits on
## observable dispatch/readiness state; it does not use sleeps as a barrier.

const SCENE := preload("res://validation/p5_reflections.tscn")
const EFFECT := preload("res://addons/ocean/reflections/ocean_sspr_effect.gd")
const REBUILD_CYCLES := 6
const STARTUP_TIMEOUT_FRAMES := 240
const REBUILD_TIMEOUT_FRAMES := 240

var _scene: Node
var _ocean: Ocean
var _open_ocean: Node
var _sspr: Node
var _effect: OceanSSPREffect
var _surface: Node
var _camera: Camera3D
var _phase := 0
var _phase_frames := 0
var _phase_timeout_frames := 0
var _wait_dispatch_count := 0
var _wait_frames := 0
var _motion_index := 0
var _motion_expected_previous := Projection()
var _motion_pending := false
var _active_off_frame_seen := false
var _off_baseline: Dictionary = {}
var _rebuild_cycle := 0
var _failed := false


func _initialize() -> void:
	if not _run_matrix_contracts() or not _run_source_contract():
		quit(1)
		return
	_scene = SCENE.instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node_or_null(^"P0/Ocean") as Ocean
	_camera = _scene.get_node_or_null(^"P0/FreeCamera") as Camera3D
	if _ocean == null or _camera == null:
		_fail("H3.1 fixture is missing Ocean or FreeCamera")
		return
	# A null RD means this environment cannot execute the mandatory GPU half.
	# Keep the mathematical markers above, but never report a GPU PASS.
	var probe := EFFECT.new()
	if probe.get("_rd") == null:
		print("GPU_RUNTIME_BLOCKED_BY_ENVIRONMENT")
		quit(2)
		return


func _process(_delta: float) -> bool:
	if _failed:
		return false
	if _phase == 0:
		return _await_startup()
	if _open_ocean == null or not is_instance_valid(_open_ocean):
		_open_ocean = _ocean.get("_open_ocean") as Node
	if _phase >= 15 and (_open_ocean == null or not is_instance_valid(_open_ocean)):
		_wait_frames += 1
		if _wait_frames > REBUILD_TIMEOUT_FRAMES:
			_fail("replacement OpenOceanFFT timed out")
		return false
	if _phase < 15 and (_effect == null or not is_instance_valid(_effect)):
		_wait_frames += 1
		if _wait_frames > STARTUP_TIMEOUT_FRAMES:
			_fail("SSPR effect disappeared during temporal lifecycle test")
		return false
	if _phase < 15:
		_wait_frames = 0
	if _phase >= 15:
		return _run_rebuild_phase()
	return _run_temporal_phases()


func _await_startup() -> bool:
	_open_ocean = _ocean.get("_open_ocean") as Node
	if _open_ocean == null:
		_wait_frames += 1
		if _wait_frames > STARTUP_TIMEOUT_FRAMES:
			_fail("OpenOceanFFT startup timed out")
		return false
	_sspr = _open_ocean.get("_sspr") as Node
	_effect = _sspr.get("_effect") as OceanSSPREffect if _sspr != null else null
	_surface = _open_ocean.get_underwater_medium_raster_surface() if _open_ocean.has_method(&"get_underwater_medium_raster_surface") else null
	if _effect == null or _surface == null:
		_wait_frames += 1
		if _wait_frames > STARTUP_TIMEOUT_FRAMES:
			_fail("SSPR effect/surface startup timed out")
		return false
	var state := _effect.get_temporal_runtime_state()
	if int(state.get("temporal_dispatch_count", 0)) < 2 or not bool(state.get("fresh_output", false)):
		_wait_frames += 1
		if _wait_frames > STARTUP_TIMEOUT_FRAMES:
			_fail("Temporal ON did not produce a stable output: %s" % state)
		return false
	if not bool(state.get("history_valid", false)) or not bool(state.get("last_temporal_history_input", false)):
		_fail("Temporal ON did not acquire history after stabilization: %s" % state)
		return false
	if state.get("last_resolve_output_kind", "") != "raw":
		_fail("Temporal ON did not resolve through raw output: %s" % state)
		return false
	_phase = 1
	_wait_frames = 0
	print("OCEAN_SSPR_TEMPORAL_ON_BASELINE_PASS dispatches=%d" % int(state.temporal_dispatch_count))
	return false


func _run_temporal_phases() -> bool:
	var state: Dictionary = _effect.get_temporal_runtime_state()
	match _phase:
		1:
			_motion_index = 0
			_motion_pending = false
			_phase = 2
		2:
			if not _motion_pending:
				_motion_expected_previous = state.previous_view_projection
				_camera.global_position.x = [0.0, 1.0, 3.0, 7.0][_motion_index]
				_camera.rotation = Vector3(deg_to_rad(10.0 + _motion_index * 0.5), deg_to_rad(_motion_index * 2.0), 0.0)
				_wait_dispatch_count = int(state.temporal_dispatch_count)
				_motion_pending = true
				return false
			if int(state.temporal_dispatch_count) <= _wait_dispatch_count:
				return false
			if not _validate_temporal_frame(state, true, _motion_expected_previous, "moving camera %d" % _motion_index):
				return false
			_motion_expected_previous = state.previous_view_projection
			_motion_index += 1
			_motion_pending = false
			if _motion_index >= 4:
				print("OCEAN_SSPR_MOVING_CAMERA_REPROJECTION_PASS frames=4")
				_phase = 3
			return false
		3:
			var resized: OceanReflectionProfile = _ocean.reflection_profile.duplicate(true)
			resized.sspr_resolution_scale = 0.50 if is_equal_approx(resized.sspr_resolution_scale, 0.40) else 0.40
			_ocean.reflection_profile = resized
			state = _effect.get_temporal_runtime_state()
			if bool(state.get("history_valid", true)):
				_fail("resize/configure did not invalidate temporal history immediately")
				return false
			_wait_dispatch_count = int(state.temporal_dispatch_count)
			_phase = 4
		4:
			if int(state.temporal_dispatch_count) <= _wait_dispatch_count:
				return false
			if not _validate_temporal_frame(state, false, state.previous_view_projection, "first frame after resize"):
				return false
			_phase = 5
			_wait_dispatch_count = int(state.temporal_dispatch_count)
		5:
			if int(state.temporal_dispatch_count) <= _wait_dispatch_count:
				return false
			if not _validate_temporal_frame(state, true, state.previous_view_projection, "second frame after resize"):
				return false
			_phase = 6
			print("OCEAN_SSPR_HISTORY_INVALIDATION_PASS resize_first_frame=no_history second_frame=history")
		6:
			_sspr.set_runtime_active(false)
			state = _effect.get_temporal_runtime_state()
			if bool(state.get("active", true)) or bool(state.get("history_valid", true)):
				_fail("SSPR disable did not invalidate active/history state")
				return false
			_wait_dispatch_count = int(state.temporal_dispatch_count)
			_active_off_frame_seen = false
			_phase = 7
		7:
			if int(state.temporal_dispatch_count) != _wait_dispatch_count:
				_fail("SSPR disabled frame still dispatched temporal work")
				return false
			_active_off_frame_seen = true
			_sspr.set_runtime_active(true)
			state = _effect.get_temporal_runtime_state()
			if not bool(state.get("active", false)) or bool(state.get("history_valid", true)):
				_fail("SSPR reactivation did not start with invalid history")
				return false
			_wait_dispatch_count = int(state.temporal_dispatch_count)
			_phase = 8
		8:
			if int(state.temporal_dispatch_count) <= _wait_dispatch_count:
				return false
			if not _validate_temporal_frame(state, false, state.previous_view_projection, "first frame after reactivation"):
				return false
			_phase = 9
			_wait_dispatch_count = int(state.temporal_dispatch_count)
		9:
			if int(state.temporal_dispatch_count) <= _wait_dispatch_count:
				return false
			if not _validate_temporal_frame(state, true, state.previous_view_projection, "second frame after reactivation"):
				return false
			_phase = 10
		10:
			_off_baseline = _effect.get_temporal_runtime_state()
			var off_profile: OceanReflectionProfile = _ocean.reflection_profile.duplicate(true)
			off_profile.temporal_enabled = false
			_ocean.reflection_profile = off_profile
			state = _effect.get_temporal_runtime_state()
			if bool(state.get("history_valid", true)):
				_fail("Temporal OFF did not invalidate history")
				return false
			_wait_dispatch_count = int(state.temporal_dispatch_count)
			_phase_frames = 0
			_phase_timeout_frames = 0
			_phase = 11
		11:
			_phase_timeout_frames += 1
			if _phase_timeout_frames > STARTUP_TIMEOUT_FRAMES:
				_fail("Temporal OFF Project/Resolve dispatches timed out")
				return false
			if int(state.temporal_dispatch_count) != int(_off_baseline.temporal_dispatch_count):
				_fail("Temporal OFF dispatched temporal work")
				return false
			if int(state.history_write_count) != int(_off_baseline.history_write_count):
				_fail("Temporal OFF wrote history")
				return false
			if int(state.history_swap_count) != int(_off_baseline.history_swap_count):
				_fail("Temporal OFF swapped history")
				return false
			var depth_project_frames := int(state.project_depth_dispatch_count) - int(_off_baseline.project_depth_dispatch_count)
			var source_project_frames := int(state.project_source_dispatch_count) - int(_off_baseline.project_source_dispatch_count)
			var resolve_frames := int(state.resolve_dispatch_count) - int(_off_baseline.resolve_dispatch_count)
			if depth_project_frames < 3 or source_project_frames < 3 or resolve_frames < 3:
				return false
			_phase_frames = mini(mini(depth_project_frames, source_project_frames), resolve_frames)
			if not _validate_temporal_off(state):
				return false
			print("OCEAN_SSPR_TEMPORAL_OFF_DISPATCH_PASS frames=%d" % _phase_frames)
			print("OCEAN_SSPR_TEMPORAL_OFF_OUTPUT_PASS resolve=mip0 fresh=true surface_bound=true")
			_phase = 12
		12:
			var on_profile: OceanReflectionProfile = _ocean.reflection_profile.duplicate(true)
			on_profile.temporal_enabled = true
			_ocean.reflection_profile = on_profile
			state = _effect.get_temporal_runtime_state()
			_wait_dispatch_count = int(state.temporal_dispatch_count)
			_phase = 13
		13:
			if int(state.temporal_dispatch_count) <= _wait_dispatch_count:
				return false
			if not _validate_temporal_frame(state, false, state.previous_view_projection, "first frame after Temporal ON"):
				return false
			_phase = 14
			_wait_dispatch_count = int(state.temporal_dispatch_count)
		14:
			if int(state.temporal_dispatch_count) <= _wait_dispatch_count:
				return false
			if not _validate_temporal_frame(state, true, state.previous_view_projection, "second frame after Temporal ON"):
				return false
			_rebuild_cycle = 0
			_wait_frames = 0
			print("OCEAN_SSPR_TEMPORAL_HISTORY_LIFECYCLE_PASS off_writes=0 off_swaps=0 reactivation_first_frame=no_history second_frame=history")
			_phase = 15
	return false


func _run_rebuild_phase() -> bool:
	if _phase == 15:
		_ocean.shutdown()
		if not _ocean.initialize():
			_fail("Ocean.initialize() failed during rapid SSPR rebuild %d" % _rebuild_cycle)
		_phase = 16
		_wait_frames = 0
		return false
	_open_ocean = _ocean.get("_open_ocean") as Node
	if _open_ocean == null:
		_wait_frames += 1
		return false
	_sspr = _open_ocean.get("_sspr") as Node
	_effect = _sspr.get("_effect") as OceanSSPREffect if _sspr != null else null
	_surface = _open_ocean.get_underwater_medium_raster_surface() if _open_ocean.has_method(&"get_underwater_medium_raster_surface") else null
	if _effect == null or _surface == null:
		_wait_frames += 1
		if _wait_frames > REBUILD_TIMEOUT_FRAMES:
			_fail("SSPR replacement did not appear during rebuild %d" % _rebuild_cycle)
		return false
	var state := _effect.get_temporal_runtime_state()
	if bool(state.get("failed", false)):
		_fail("SSPR effect reported lifecycle failure after rebuild %d: %s" % [_rebuild_cycle, state])
		return false
	if int(state.get("project_depth_dispatch_count", 0)) < 2 or int(state.get("project_source_dispatch_count", 0)) < 2 or int(state.get("resolve_dispatch_count", 0)) < 2:
		_fail("SSPR depth/source/resolve pipelines did not dispatch after rebuild %d: %s" % [_rebuild_cycle, state])
		return false
	if int(state.get("temporal_dispatch_count", 0)) < 2 or not bool(state.get("history_valid", false)):
		_wait_frames += 1
		if _wait_frames > REBUILD_TIMEOUT_FRAMES:
			_fail("SSPR replacement did not stabilize after rebuild %d: %s" % [_rebuild_cycle, state])
		return false
	if not bool(state.get("output_valid", false)) or not bool(state.get("fresh_output", false)):
		_fail("SSPR replacement published no valid output after rebuild %d: %s" % [_rebuild_cycle, state])
		return false
	if not bool(_surface.get("_reflection_texture_available")):
		_fail("Surface did not receive fresh SSPR texture after rebuild %d" % _rebuild_cycle)
		return false
	_rebuild_cycle += 1
	if _rebuild_cycle < REBUILD_CYCLES:
		_phase = 15
		return false
	print("OCEAN_SSPR_REBUILD_LIFECYCLE_PASS cycles=%d" % REBUILD_CYCLES)
	print("OCEAN_SSPR_DEPTH_ARBITRATION_REBUILD_PASS cycles=%d depth_project=%d source_project=%d resolve=%d" % [REBUILD_CYCLES, int(state.get("project_depth_dispatch_count", 0)), int(state.get("project_source_dispatch_count", 0)), int(state.get("resolve_dispatch_count", 0))])
	quit(0)
	return true


func _validate_temporal_frame(state: Dictionary, expect_history: bool, expected_previous: Projection, context: String) -> bool:
	if bool(state.get("last_temporal_history_input", false)) != expect_history:
		_fail("%s history input mismatch: expected=%s state=%s" % [context, expect_history, state])
		return false
	var params: PackedFloat32Array = state.get("last_temporal_params", PackedFloat32Array())
	if params.size() != 44:
		_fail("%s temporal params size mismatch: %d" % [context, params.size()])
		return false
	# With invalid history the shader is forbidden from reading this slot. The
	# production callback sends current VP as a safe placeholder, so only a
	# history-bearing frame has an observable previous-VP contract here.
	if expect_history and not _assert_packed_matrix(params, 64, expected_previous, context + " previous_vp"):
		return false
	return true


func _validate_temporal_off(state: Dictionary) -> bool:
	var before_temporal := int(_off_baseline.get("temporal_dispatch_count", -1))
	var before_writes := int(_off_baseline.get("history_write_count", -1))
	var before_swaps := int(_off_baseline.get("history_swap_count", -1))
	if int(state.get("temporal_dispatch_count", -2)) != before_temporal:
		_fail("Temporal OFF dispatched temporal work: before=%d after=%d" % [before_temporal, state.temporal_dispatch_count])
		return false
	if int(state.get("history_write_count", -2)) != before_writes or int(state.get("history_swap_count", -2)) != before_swaps:
		_fail("Temporal OFF wrote/swapped history: before=%s after=%s" % [_off_baseline, state])
		return false
	if int(state.get("project_depth_dispatch_count", 0)) <= int(_off_baseline.get("project_depth_dispatch_count", 0)) or int(state.get("project_source_dispatch_count", 0)) <= int(_off_baseline.get("project_source_dispatch_count", 0)) or int(state.get("resolve_dispatch_count", 0)) <= int(_off_baseline.get("resolve_dispatch_count", 0)):
		_fail("Temporal OFF did not keep ProjectDepth/ProjectSource/Resolve dispatches alive: %s" % state)
		return false
	if bool(state.get("history_valid", true)) or state.get("last_resolve_output_kind", "") != "mip0":
		_fail("Temporal OFF output/history state is inconsistent: %s" % state)
		return false
	if not bool(state.get("fresh_output", false)) or not bool(state.get("output_valid", false)) or not bool(_surface.get("_reflection_texture_available")):
		_fail("Temporal OFF did not publish a fresh Surface output: %s" % state)
		return false
	return true


func _run_matrix_contracts() -> bool:
	var probe := EFFECT.new()
	var p0 := _make_projection(0.0, 0.0, 0.0)
	var p1 := _make_projection(1.0, 0.03, 0.01)
	var p2 := _make_projection(2.0, 0.06, 0.02)
	var frame0: PackedFloat32Array = probe.build_temporal_params_for_validation(p0, p0, Vector2i(320, 180), 0.0, false)
	var frame1: PackedFloat32Array = probe.build_temporal_params_for_validation(p1, p0, Vector2i(320, 180), 0.0, true)
	var frame2: PackedFloat32Array = probe.build_temporal_params_for_validation(p2, p1, Vector2i(320, 180), 0.0, true)
	if frame0.size() != 44 or frame1.size() != 44 or frame2.size() != 44 or frame0[135] != 0.0:
		_fail("Temporal parameter contract has invalid size/history flag")
		return false
	if not _assert_packed_matrix(frame0, 64, p0, "frame 0 placeholder previous_vp") or not _assert_packed_matrix(frame1, 64, p0, "frame 1 previous_vp") or not _assert_packed_matrix(frame2, 64, p1, "frame 2 previous_vp"):
		return false
	print("OCEAN_SSPR_PREVIOUS_VP_CONTRACT_PASS frame0=no_history frame1=VP0 frame2=VP1")
	var previous := _make_projection(0.0, 0.0, 0.0)
	for index in range(4):
		var current := _make_projection([0.0, 1.0, 3.0, 7.0][index], deg_to_rad(float(index) * 2.0), deg_to_rad(float(index) * 0.5))
		var params: PackedFloat32Array = probe.build_temporal_params_for_validation(current, previous, Vector2i(320, 180), 0.0, true)
		if not _assert_packed_matrix(params, 64, previous, "moving camera %d previous_vp" % index):
			return false
		previous = current
	print("OCEAN_SSPR_MOVING_CAMERA_MATH_PASS positions=0,1,3,7")
	return true


func _run_source_contract() -> bool:
	var source := FileAccess.get_file_as_string("res://addons/ocean/reflections/ocean_sspr_effect.gd")
	var shader := FileAccess.get_file_as_string("res://addons/ocean/reflections/shaders/ocean_sspr_temporal.glsl")
	if source.is_empty() or shader.is_empty():
		_fail("SSPR source/shader missing")
		return false
	if source.contains("_pack_temporal(\n\t\tview_projection.inverse(),\n\t\tview_projection,"):
		_fail("old-current-VP temporal packing path remains")
		return false
	for token in ["var resolve_output := _raw if temporal_enabled else _mips[0]", "if temporal_enabled:\n\t\ttemporal_set = _temporal_set()", "_history_valid = temporal_enabled", "compute_list_add_barrier(list)"]:
		if not source.contains(token):
			_fail("SSPR lifecycle source contract missing: " + token)
			return false
	if not shader.contains("params.previous_view_projection") or not shader.contains("params.temporal_settings.w"):
		_fail("temporal shader does not consume previous VP/history guard")
		return false
	return true


func _make_projection(x: float, yaw: float, pitch: float) -> Projection:
	var projection := Projection()
	projection.x = Vector4(1.0, yaw, 0.0, 0.0)
	projection.y = Vector4(0.0, 1.0, pitch, 0.0)
	projection.z = Vector4(0.0, 0.0, 1.0, 0.0)
	projection.w = Vector4(x * 0.25, yaw * 0.5, pitch * 0.5, 1.0)
	return projection


func _assert_packed_matrix(params: PackedFloat32Array, offset: int, expected: Projection, context: String) -> bool:
	var values := PackedFloat32Array()
	for column in [expected.x, expected.y, expected.z, expected.w]:
		values.append_array([column.x, column.y, column.z, column.w])
	for index in values.size():
		if not is_equal_approx(params[offset + index], values[index]):
			_fail("%s mismatch at %d: expected=%f actual=%f" % [context, index, values[index], params[offset + index]])
			return false
	return true


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	push_error("OCEAN_SSPR_TEMPORAL_LIFECYCLE_FAIL: " + reason)
	quit(1)
