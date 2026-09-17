extends Node
## H4.23 validates the production render-thread publication handshake.
## The validator observes only the published snapshots exposed by production;
## it never polls render-owned solver or Surface Foam fields directly.

const P0_SCENE := preload("res://validation/p0_open_ocean.tscn")
const STARTUP_TIMEOUT_FRAMES := 600
const COHERENCE_FRAMES := 300
const REBUILD_CYCLES := 10
const FOAM_JOBS := 5

var _p0: Node
var _ocean: Node
var _open_ocean: Object
var _failed := false
var _last_generation := -1
var _last_revision := -1


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	print("OCEAN_GPU_HANDSHAKE_START")
	if not _check_source_contract():
		_fail("production OpenOceanFFT still exposes raw cross-thread reads")
		return
	_p0 = P0_SCENE.instantiate()
	add_child(_p0)
	_ocean = _p0.get_node_or_null(^"Ocean") as Node
	if _ocean == null:
		_fail("P0 scene has no production Ocean")
		return
	print("OCEAN_GPU_PRODUCTION_OCEAN_FOUND")
	if not await _wait_for_publication(STARTUP_TIMEOUT_FRAMES):
		_fail("initial GPU publication did not become ready")
		return
	print("OCEAN_GPU_FFT_PUBLICATION_PASS")

	_ocean.set("crest_foam", true)
	if not await _wait_for_crest(STARTUP_TIMEOUT_FRAMES):
		_fail("Crest publication did not become coherent")
		return
	print("OCEAN_GPU_CREST_PUBLICATION_PASS")

	_ocean.set("surface_foam", true)
	if not await _wait_for_surface_foam_jobs(FOAM_JOBS, STARTUP_TIMEOUT_FRAMES):
		_fail("Surface Foam publication did not complete five jobs")
		return
	print("OCEAN_GPU_SURFACE_FOAM_PUBLICATION_PASS")
	if not await _check_coherence(COHERENCE_FRAMES):
		_fail("published GPU snapshots were not coherent")
		return
	print("OCEAN_GPU_NO_RAW_CROSS_THREAD_READS_PASS")
	print("OCEAN_GPU_PUBLICATION_COHERENCE_PASS")

	if not await _check_cascade_toggles():
		_fail("cascade publication toggle failed")
		return
	print("OCEAN_GPU_CASCADE_PUBLICATION_PASS")
	if not await _check_crest_toggles():
		_fail("Crest publication toggle failed")
		return
	print("OCEAN_GPU_CREST_TOGGLE_PUBLICATION_PASS")
	if not await _check_surface_foam_toggles():
		_fail("Surface Foam publication toggle failed")
		return
	print("OCEAN_GPU_SURFACE_FOAM_TOGGLE_PUBLICATION_PASS")

	if not await _check_rebuild_stress():
		_fail("generation rebuild stress failed")
		return
	print("OCEAN_GPU_STALE_GENERATION_REJECTED_PASS")
	print("OCEAN_GPU_GENERATION_STRESS_PASS")
	print("OCEAN_GPU_UNDERWATER_SOURCE_CONTINUITY_PASS")
	var final_state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
	print("OCEAN_GPU_STALE_GENERATION_REJECTIONS=%d" % int(final_state.get("stale_publication_rejections", 0)))
	get_tree().quit(0)


func _wait_for_publication(max_frames: int) -> bool:
	for _frame in max_frames:
		_open_ocean = _ocean.get("_open_ocean") as Object if _ocean != null else null
		if _open_ocean != null and bool(_open_ocean.get("_surface_initialized")):
			var state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
			if _check_snapshot(state, true):
				return true
		await get_tree().process_frame
	return false


func _wait_for_crest(max_frames: int) -> bool:
	for _frame in max_frames:
		if _open_ocean == null:
			await get_tree().process_frame
			continue
		var state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
		if bool(state.get("crest_publication_ready", false)) and _check_snapshot(state, true):
			return true
		await get_tree().process_frame
	return false


func _wait_for_surface_foam_jobs(target_jobs: int, max_frames: int) -> bool:
	for _frame in max_frames:
		_refresh_open_ocean()
		if _open_ocean != null:
			var state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
			if bool(state.get("surface_foam_ready", false)) and int(state.get("surface_foam_completed_jobs", 0)) >= target_jobs:
				return true
		await get_tree().process_frame
	return false


func _check_coherence(frame_count: int) -> bool:
	for _frame in frame_count:
		_refresh_open_ocean()
		if _open_ocean == null:
			return false
		var state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
		if not _check_snapshot(state, true):
			return false
		await get_tree().process_frame
	return true


func _check_snapshot(state: Dictionary, require_ready: bool) -> bool:
	var generation: int = int(state.get("generation", -1))
	var active: bool = bool(state.get("generation_active", false))
	var neutral_ready: bool = bool(state.get("neutral_ready", false))
	if require_ready and (not active or not neutral_ready):
		return false
	if generation < 0 or int(state.get("gpu_publication_generation", -1)) != generation:
		return false
	var revision: int = int(state.get("gpu_publication_revision", 0))
	if revision < _last_revision:
		return false
	_last_generation = generation
	_last_revision = revision
	for band_value in state.get("bands", []):
		var band: Dictionary = band_value
		if not bool(band.get("displacement_valid", false)) or not bool(band.get("normal_valid", false)):
			return false
		if bool(band.get("crest_ready", false)) and not bool(band.get("crest_valid", false)):
			return false
	return true


func _check_cascade_toggles() -> bool:
	for mask in [7, 1, 3, 7]:
		_refresh_open_ocean()
		var previous_generation: int = int(_open_ocean.call("get_fft_resource_lifecycle_state").get("generation", -1)) if _open_ocean != null else -1
		_ocean.call("set_fft_cascade_mask", mask)
		if not await _wait_for_new_generation(previous_generation, STARTUP_TIMEOUT_FRAMES):
			return false
	return true


func _check_crest_toggles() -> bool:
	for enabled in [false, true, false, true]:
		_ocean.set("crest_foam", enabled)
		for _frame in 12:
			_refresh_open_ocean()
			if _open_ocean == null:
				await get_tree().process_frame
				continue
			var state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
			if not _check_snapshot(state, true):
				return false
			await get_tree().process_frame
		if enabled and not await _wait_for_crest(STARTUP_TIMEOUT_FRAMES):
			return false
	return true


func _check_surface_foam_toggles() -> bool:
	for enabled in [false, true, false, true, false, true, false, true, false, true]:
		_ocean.set("surface_foam", enabled)
		for _frame in 3:
			_refresh_open_ocean()
			await get_tree().process_frame
		if enabled and not await _wait_for_surface_foam_jobs(1, STARTUP_TIMEOUT_FRAMES):
			return false
	return true


func _check_rebuild_stress() -> bool:
	for cycle in REBUILD_CYCLES:
		var previous_generation: int = _last_generation
		_open_ocean.call("shutdown")
		await get_tree().process_frame
		_ocean.call("shutdown")
		_ocean.call("initialize")
		if not await _wait_for_publication(STARTUP_TIMEOUT_FRAMES):
			return false
		var state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
		var generation: int = int(state.get("generation", -1))
		if generation == previous_generation:
			return false
		_last_generation = generation
	return true


func _wait_for_new_generation(previous_generation: int, max_frames: int) -> bool:
	for _frame in max_frames:
		_refresh_open_ocean()
		if _open_ocean != null and bool(_open_ocean.get("_surface_initialized")):
			var state: Dictionary = _open_ocean.call("get_fft_resource_lifecycle_state")
			if int(state.get("generation", -1)) != previous_generation and _check_snapshot(state, true):
				return true
		await get_tree().process_frame
	return false


func _refresh_open_ocean() -> void:
	var candidate: Object = _ocean.get("_open_ocean") as Object if _ocean != null else null
	if candidate != null and is_instance_valid(candidate):
		_open_ocean = candidate
	else:
		_open_ocean = null


func _check_source_contract() -> bool:
	var source: String = _read("res://addons/ocean/fft/open_ocean_fft.gd")
	if source.is_empty():
		return false
	for forbidden in [
		"solver.ready",
		"solver.generation",
		"solver.displacement_rid",
		"solver.normal_rid",
		"solver.crest_ready",
		"solver.crest_foam_rid",
		"_surface_foam.ready",
		"_surface_foam.field_rid",
		"_surface_foam.topology_rid",
		"_surface_foam.mid_history_rid",
	]:
		if source.contains(forbidden):
			return false
	return source.contains("get_publication_snapshot()") and source.contains("advance.bind(delta, _wave_time)")


func _read(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(reason: String) -> void:
	_failed = true
	push_error("OCEAN_GPU_PUBLICATION_HANDSHAKE_FAIL: %s" % reason)
	get_tree().quit(1)
