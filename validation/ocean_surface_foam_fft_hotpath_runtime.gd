extends Node
## H4.21 validates the real Surface Foam FFT resource and dispatch lifecycle.
## The test uses the production P0 scene and waits on observed readiness/jobs.

const P0_SCENE := preload("res://validation/p0_open_ocean.tscn")
const FOAM_SCRIPT := preload("res://addons/ocean/surface/ocean_surface_foam.gd")
const FOAM_SOURCE_PATH := "res://addons/ocean/surface/ocean_surface_foam.gd"
const STAGE_COUNT := 18
const SOURCE_RESOLUTION := 512
const EXPECTED_TOTAL_PASSES := 32
const EXPECTED_PASS_BUDGET := 24
const EXPECTED_UPDATE_HZ := 30.0

var _p0: Node
var _ocean: Node
var _open_ocean: Object
var _foam: Object
var _lifecycle_done := false


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var source: String = _read(FOAM_SOURCE_PATH)
	if not _check_source_contract(source):
		_fail("Surface Foam FFT source contract failed")
		return
	_p0 = P0_SCENE.instantiate()
	add_child(_p0)
	_ocean = _p0.get_node_or_null("Ocean") as Node
	if _ocean == null:
		_fail("P0 scene did not provide its production Ocean")
		return
	_foam = await _wait_for_ready_foam(600)
	if _foam == null:
		_fail("Production Surface Foam did not become ready")
		return
	_open_ocean = _ocean.get("_open_ocean") as Object
	if _open_ocean == null:
		_fail("Production OpenOceanFFT is unavailable")
		return
	if not _check_stage_params():
		_fail("Static FFT stage parameters are invalid")
		return
	print("OCEAN_SURFACE_FOAM_FFT_STATIC_PARAMS_PASS")
	if not _check_dispatch_order():
		_fail("FFT dispatch order is invalid")
		return
	print("OCEAN_SURFACE_FOAM_FFT_DISPATCH_ORDER_PASS")
	if not _check_ping_pong():
		_fail("FFT ping-pong mapping changed")
		return
	print("OCEAN_SURFACE_FOAM_FFT_PING_PONG_COMPAT_PASS")
	if not await _wait_for_jobs(5, 900):
		_fail("Surface Foam did not complete five real jobs")
		return
	var job_state: Dictionary = _foam.call("diagnostic_state")
	if int(job_state.get("fft_runtime_param_updates", -1)) != 0 or int(job_state.get("last_job_fft_dispatches", -1)) != 18:
		_fail("FFT runtime updates or dispatch count is inconsistent")
		return
	print("OCEAN_SURFACE_FOAM_FFT_RUNTIME_UPDATES_ZERO_PASS")
	if not _check_scheduler(job_state):
		_fail("Surface Foam scheduler contract changed")
		return
	print("OCEAN_SURFACE_FOAM_JOB_SCHEDULER_COMPAT_PASS")
	if not _check_publication(job_state):
		_fail("Surface Foam publication is not ready and complete")
		return
	print("OCEAN_SURFACE_FOAM_PUBLICATION_COMPAT_PASS")
	if not _check_execution_contract(source, job_state):
		_fail("Surface Foam execution contract changed")
		return
	print("OCEAN_SURFACE_FOAM_FFT_EXECUTION_CONTRACT_PASS")
	if not await _check_profile_independence():
		_fail("Profile update rebuilt immutable FFT stage resources")
		return
	print("OCEAN_SURFACE_FOAM_FFT_PROFILE_INDEPENDENCE_PASS")
	if not await _check_rate_independence():
		_fail("Update rate rebuilt immutable FFT stage resources")
		return
	print("OCEAN_SURFACE_FOAM_FFT_RATE_INDEPENDENCE_PASS")
	if not await _check_lifecycle_stress():
		_fail("Surface Foam lifecycle stress failed")
		return
	print("OCEAN_SURFACE_FOAM_FFT_LIFECYCLE_PASS")
	print("OCEAN_SURFACE_FOAM_FFT_HOTPATH_REDUCTION_PASS")
	print("OCEAN_SURFACE_FOAM_FFT_SOURCE_CONTRACT_PASS")
	get_tree().quit(0)


func _check_source_contract(source: String) -> bool:
	if source.is_empty() or source.contains("_fft_buffer") or source.contains("_fft_sets"):
		return false
	if not source.contains("var _fft_stage_buffers: Array[RID] = []") or not source.contains("var _fft_stage_sets: Array[RID] = []"):
		return false
	if not source.contains("for fft_index in 18:") or not source.contains("_rd.uniform_buffer_create(16, PackedInt32Array"):
		return false
	var dispatch_source: String = _section(source, "func _dispatch_job_pass()", "func diagnostic_state()")
	if dispatch_source.is_empty() or dispatch_source.contains("_rd.buffer_update(_fft") or dispatch_source.contains("_fft_buffer"):
		return false
	if not dispatch_source.contains("_dispatch(1, _fft_stage_sets[fft_index]"):
		return false
	var shutdown_source: String = _section(source, "func shutdown()", "func _dispatch(")
	if shutdown_source.is_empty() or not shutdown_source.contains("_fft_stage_buffers") or not shutdown_source.contains("_fft_stage_buffers.clear()"):
		return false
	if not source.contains("return 22 + _downsample_sets[0].size() + 1"):
		return false
	return source.contains("const UPDATE_HZ := 30.0") and source.contains("const PASS_BUDGET := 24")


func _check_stage_params() -> bool:
	var state: Dictionary = _foam.call("diagnostic_state")
	if not bool(_foam.get("ready")) or int(state.get("fft_stage_count", 0)) != STAGE_COUNT or int(state.get("fft_static_param_buffer_count", 0)) != STAGE_COUNT:
		return false
	var params: Array = state.get("fft_stage_params", [])
	var buffers: Array = _foam.get("_fft_stage_buffers")
	var sets: Array = _foam.get("_fft_stage_sets")
	if params.size() != STAGE_COUNT or buffers.size() != STAGE_COUNT or sets.size() != STAGE_COUNT:
		return false
	for fft_index in STAGE_COUNT:
		var parameter: Vector4i = params[fft_index]
		var expected_axis: int = fft_index / 9
		var expected_stage: int = fft_index % 9
		if parameter != Vector4i(2 << expected_stage, expected_axis, SOURCE_RESOLUTION, 1):
			return false
		var buffer: RID = buffers[fft_index]
		var set_rid: RID = sets[fft_index]
		if not buffer.is_valid() or not set_rid.is_valid():
			return false
	return true


func _check_dispatch_order() -> bool:
	var state: Dictionary = _foam.call("diagnostic_state")
	var params: Array = state.get("fft_stage_params", [])
	if params.size() != STAGE_COUNT:
		return false
	for fft_index in STAGE_COUNT:
		var parameter: Vector4i = params[fft_index]
		if parameter.x != (2 << (fft_index % 9)) or parameter.y != fft_index / 9:
			return false
	return params[0] == Vector4i(2, 0, 512, 1) \
		and params[8] == Vector4i(512, 0, 512, 1) \
		and params[9] == Vector4i(2, 1, 512, 1) \
		and params[17] == Vector4i(512, 1, 512, 1)


func _check_ping_pong() -> bool:
	var state: Dictionary = _foam.call("diagnostic_state")
	var mapping: Array = state.get("fft_ping_pong", [])
	if mapping.size() != STAGE_COUNT:
		return false
	for fft_index in STAGE_COUNT:
		var entry: Dictionary = mapping[fft_index]
		if int(entry.get("index", -1)) != fft_index or int(entry.get("source_slot", -1)) != fft_index % 2 or int(entry.get("destination_slot", -1)) != 1 - (fft_index % 2):
			return false
	return true


func _check_scheduler(state: Dictionary) -> bool:
	return is_equal_approx(float(state.get("update_hz", -1.0)), EXPECTED_UPDATE_HZ) \
		and int(state.get("pass_budget", -1)) == EXPECTED_PASS_BUDGET \
		and int(state.get("total_job_passes", -1)) == EXPECTED_TOTAL_PASSES \
		and int(state.get("completed_jobs", 0)) >= 5


func _check_publication(state: Dictionary) -> bool:
	var field: RID = _foam.get("field_rid")
	var topology: RID = _foam.get("topology_rid")
	var mid_history: RID = _foam.get("mid_history_rid")
	return bool(_foam.get("ready")) and field.is_valid() and topology.is_valid() and mid_history.is_valid() \
		and int(state.get("last_job_fft_dispatches", 0)) == 18


func _check_execution_contract(source: String, state: Dictionary) -> bool:
	var dispatch_source: String = _section(source, "elif _job_pass >= fft_first", "elif _job_pass == assemble_pass")
	return dispatch_source.contains("_dispatch(1, _fft_stage_sets[fft_index]") \
		and dispatch_source.contains("source_groups, source_groups") \
		and int(state.get("ifft_butterfly_dispatches", 0)) == 18


func _wait_for_jobs(target_jobs: int, max_frames: int) -> bool:
	for _frame in max_frames:
		if _foam != null:
			var state: Dictionary = _foam.call("diagnostic_state")
			if int(state.get("completed_jobs", 0)) >= target_jobs:
				return true
		await get_tree().process_frame
	return false


func _check_profile_independence() -> bool:
	var buffers_before: Array[int] = _rid_ids(_foam.get("_fft_stage_buffers"))
	var sets_before: Array[int] = _rid_ids(_foam.get("_fft_stage_sets"))
	var profile: Resource = _ocean.get("surface_foam_profile") as Resource
	if profile == null:
		return false
	var threshold: float = float(profile.get("whitecap_threshold"))
	profile.set("whitecap_threshold", threshold + 0.01)
	var state: Dictionary = _foam.call("diagnostic_state")
	return buffers_before == _rid_ids(_foam.get("_fft_stage_buffers")) \
		and sets_before == _rid_ids(_foam.get("_fft_stage_sets")) \
		and int(state.get("fft_static_param_buffer_count", 0)) == STAGE_COUNT \
		and int(state.get("fft_runtime_param_updates", -1)) == 0


func _check_rate_independence() -> bool:
	var buffers_before: Array[int] = _rid_ids(_foam.get("_fft_stage_buffers"))
	var sets_before: Array[int] = _rid_ids(_foam.get("_fft_stage_sets"))
	_foam.call("set_update_hz", 10.0)
	var low_state: Dictionary = _foam.call("diagnostic_state")
	_foam.call("set_update_hz", 30.0)
	var high_state: Dictionary = _foam.call("diagnostic_state")
	return is_equal_approx(float(low_state.get("update_hz", -1.0)), 10.0) \
		and is_equal_approx(float(high_state.get("update_hz", -1.0)), 30.0) \
		and buffers_before == _rid_ids(_foam.get("_fft_stage_buffers")) \
		and sets_before == _rid_ids(_foam.get("_fft_stage_sets")) \
		and int(high_state.get("fft_runtime_param_updates", -1)) == 0


func _check_lifecycle_stress() -> bool:
	var solvers: Array = _open_ocean.get("_solvers")
	var mid_resolution: int = int(_open_ocean.get("_mid_resolution"))
	if solvers.size() < 2 or mid_resolution <= 0:
		return false
	var mid_solver: Object = solvers[1] as Object
	var mid_rid: RID = mid_solver.get("displacement_rid")
	if not mid_rid.is_valid():
		return false
	var profile: Resource = _ocean.get("surface_foam_profile") as Resource
	if profile == null:
		return false
	var probe: Object = FOAM_SCRIPT.new()
	probe.set_profile(profile)
	for cycle in 10:
		_lifecycle_done = false
		RenderingServer.call_on_render_thread(_lifecycle_initialize.bind(probe, 20260820 + cycle, mid_rid, mid_resolution))
		if not await _wait_for_lifecycle(600) or not bool(probe.get("ready")):
			return false
		var state: Dictionary = probe.call("diagnostic_state")
		if int(state.get("fft_stage_count", 0)) != STAGE_COUNT or int(state.get("fft_static_param_buffer_count", 0)) != STAGE_COUNT:
			return false
		_lifecycle_done = false
		RenderingServer.call_on_render_thread(_lifecycle_shutdown.bind(probe))
		if not await _wait_for_lifecycle(600):
			return false
		var retired_buffers: Array = probe.get("_fft_stage_buffers")
		var retired_sets: Array = probe.get("_fft_stage_sets")
		if bool(probe.get("ready")) or not retired_buffers.is_empty() or not retired_sets.is_empty():
			return false
	return true


func _lifecycle_initialize(probe: Object, seed: int, mid_rid: RID, mid_resolution: int) -> void:
	probe.initialize(seed, mid_rid, mid_resolution)
	_lifecycle_done = true


func _lifecycle_shutdown(probe: Object) -> void:
	probe.shutdown()
	_lifecycle_done = true


func _wait_for_lifecycle(max_frames: int) -> bool:
	for _frame in max_frames:
		if _lifecycle_done:
			return true
		await get_tree().process_frame
	return false


func _wait_for_ready_foam(max_frames: int) -> Object:
	for _frame in max_frames:
		if _ocean != null:
			var open_ocean: Object = _ocean.get("_open_ocean") as Object
			if open_ocean != null:
				var candidate: Object = open_ocean.get("_surface_foam") as Object
				if candidate != null and bool(candidate.get("ready")):
					return candidate
		await get_tree().process_frame
	return null


func _rid_ids(values: Array) -> Array[int]:
	var result: Array[int] = []
	for value in values:
		var rid: RID = value
		result.append(rid.get_id())
	return result


func _section(source: String, start_token: String, end_token: String) -> String:
	var start: int = source.find(start_token)
	var end: int = source.find(end_token, start + start_token.length())
	return source.substr(start, end - start) if start >= 0 and end > start else ""


func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	push_error("OCEAN_SURFACE_FOAM_FFT_CONTRACT_FAIL: " + message)
	get_tree().quit(1)
