extends Node
## PERF-1: captures only. Snapshot conversion, JSON and disk I/O run on a low
## priority reporting thread; the synchronous water builders remain unchanged.
const DIRECTORY := "user://perf1"
const INTERVAL_SECONDS := 2.0
const MAX_SAVED_WINDOWS := 128
var native: Object
var report_path := ""
var _thread := Thread.new()
var _wake := Semaphore.new()
var _mutex := Mutex.new()
var _pending := false
var _stopping := false
var _elapsed := 0.0
var _metadata: Dictionary
var _windows: Dictionary = {}
var _discarded_saved_windows := 0
var _last_sequence := -1
var _last_error := OK

func configure(source: Object) -> void:
	native = source
	name = "Perf1Capture"
	report_path = DIRECTORY.path_join("capture_%d_%d.json" % [int(Time.get_unix_time_from_system()), OS.get_process_id()])
	_metadata = {
		"capture": "PERF-1", "started_utc": Time.get_datetime_string_from_system(true),
		"project": ProjectSettings.get_setting("application/config/name", ""),
		"project_path": ProjectSettings.globalize_path("res://"),
		"scene": get_tree().current_scene.scene_file_path if get_tree().current_scene != null else "",
		"cpu": OS.get_processor_name(), "os": OS.get_name(), "engine": Engine.get_version_info(),
		"threshold_us": 8000, "report_interval_seconds": INTERVAL_SECONDS,
		"phase_reasons": {"0": "recurrence", "1": "first_or_reset", "2": "rewind", "3": "time_jump_gt_0.25s", "4": "periodic_600"},
		"configure_reason_bits": {"1": "resolution", "2": "minimum_wavelength", "4": "field_not_ready"},
		"limits": "memory = field storage, not OS working set; Windows thread CPU is quantized; FULL_CPU workers excluded from calling thread CPU; current frame can be incomplete",
		"context": "16 builds before and after; comparison builds counted separately; physics_steps counts actual Node physics callbacks per process frame"
	}
	_last_error = _thread.start(_worker, Thread.PRIORITY_LOW)
	set_process(_last_error == OK)
	set_physics_process(_last_error == OK)
	if _last_error != OK:
		push_error("PERF-1 reporting thread could not start: %s" % _last_error)
	else:
		_request_snapshot()

func _physics_process(_delta: float) -> void:
	native.call("perf1_record_tick", Engine.get_physics_frames(), Engine.get_process_frames(), Engine.get_frames_drawn())

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed >= INTERVAL_SECONDS:
		_elapsed = 0.0
		_request_snapshot()
	_mutex.lock()
	var error := _last_error
	_mutex.unlock()
	if error != OK:
		set_process(false)
		push_error("PERF-1 could not save capture: %s" % error)

func _request_snapshot() -> void:
	_mutex.lock()
	if not _pending:
		_pending = true
		_wake.post()
	_mutex.unlock()

func _exit_tree() -> void:
	if not _thread.is_started(): return
	_mutex.lock()
	_stopping = true
	_mutex.unlock()
	_wake.post()
	_thread.wait_to_finish() # Final flush at scene shutdown, outside physics.

func _worker() -> void:
	while true:
		_wake.wait()
		_mutex.lock()
		var stopping := _stopping
		_pending = false
		_mutex.unlock()
		var capture: Dictionary = native.call("get_perf1_capture")
		if int(capture.sequence) != _last_sequence or stopping:
			_save(capture)
			_last_sequence = int(capture.sequence)
		if stopping: break

func _save(capture: Dictionary) -> void:
	var frames_by_id: Dictionary = {}
	for frame: Dictionary in capture.physics_frames:
		frames_by_id[int(frame.process_frame)] = frame
	for window: Dictionary in capture.hitch_windows:
		var key := int(window.trigger_sequence)
		var associated: Dictionary = {}
		for row: Dictionary in window.records:
			var frame_id := int(row.process_frame)
			if frames_by_id.has(frame_id): associated[frame_id] = frames_by_id[frame_id]
		window["physics_frames"] = associated.values()
		_windows[key] = window
	while _windows.size() > MAX_SAVED_WINDOWS:
		_windows.erase(_windows.keys()[0])
		_discarded_saved_windows += 1
	capture.hitch_windows = _windows.values()
	capture["discarded_saved_windows"] = _discarded_saved_windows
	capture["metadata"] = _metadata
	capture["saved_utc"] = Time.get_datetime_string_from_system(true)
	capture["session_path"] = ProjectSettings.globalize_path(report_path)
	var json := JSON.stringify(capture)
	var directory := ProjectSettings.globalize_path(DIRECTORY)
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error == OK:
		error = _replace(report_path, json)
	if error == OK:
		error = _replace(DIRECTORY.path_join("latest.json"), json)
	_mutex.lock()
	_last_error = error
	_mutex.unlock()

func _replace(path: String, json: String) -> Error:
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null: return FileAccess.get_open_error()
	file.store_string(json)
	var error := file.get_error()
	file.close()
	if error != OK: return error
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary), ProjectSettings.globalize_path(path))
