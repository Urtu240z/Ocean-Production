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
var _perf2 := false
var _frame_windows: Dictionary = {}
var _discarded_frame_windows := 0
var _last_frame := -1
@export var frame_hitch_threshold_ms := 25.0

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
	_perf2 = native.has_method("get_perf2_capture")
	if _perf2:
		_metadata["capture"] = "PERF-2"
		_metadata["windows_correlation"] = native.call("perf2_initialize")
		_metadata["frame_threshold_us"] = int(frame_hitch_threshold_ms * 1000.0)
		_metadata["frame_context_each_side"] = 32
		_metadata["stage_names"] = ["controller", "contacts", "water_physics", "cell_integration",
			"tetra_loop", "query_batch", "source_validity", "ocean_source", "native_build", "report_save"]
		get_tree().process_frame.connect(_on_frame_boundary)
	_last_error = _thread.start(_worker, Thread.PRIORITY_LOW)
	set_process(_last_error == OK)
	set_physics_process(_last_error == OK)
	if _last_error != OK:
		push_error("PERF-1 reporting thread could not start: %s" % _last_error)
	else:
		_request_snapshot()

func _physics_process(_delta: float) -> void:
	native.call("perf1_record_tick", Engine.get_physics_frames(), Engine.get_process_frames(), Engine.get_frames_drawn())

func _on_frame_boundary() -> void:
	native.call("perf2_frame_boundary", Engine.get_process_frames(), Engine.get_frames_drawn(),
		int(frame_hitch_threshold_ms * 1000.0))

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
	if _perf2 and get_tree().process_frame.is_connected(_on_frame_boundary):
		get_tree().process_frame.disconnect(_on_frame_boundary)
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
		var frame := -1
		if _perf2:
			capture["perf2"] = native.call("get_perf2_capture")
			frame = int(capture.perf2.last_frame)
		if int(capture.sequence) != _last_sequence or frame != _last_frame or stopping:
			var started := Time.get_ticks_usec()
			_save(capture)
			if _perf2:
				native.call("perf2_record_span", 9, frame, -1, started, Time.get_ticks_usec(), 1)
			_last_sequence = int(capture.sequence)
			_last_frame = frame
		if stopping: break

func _save(capture: Dictionary) -> void:
	var frames_by_id: Dictionary = {}
	for frame: Dictionary in capture.physics_frames:
		frames_by_id[int(frame.process_frame)] = frame
	if _perf2:
		for window: Dictionary in capture.perf2.frame_hitch_windows:
			var key := int(window.trigger_frame)
			var builds: Dictionary = {}
			if _frame_windows.has(key):
				for row: Dictionary in _frame_windows[key].build_records: builds[int(row.sequence)] = row
			for row: Dictionary in window.build_records: builds[int(row.sequence)] = row
			window.build_records = builds.values()
			window.missing_build_records = maxi(0, int(window.expected_build_records) - builds.size())
			for frame: Dictionary in window.frames:
				frame["physics_steps"] = int(frames_by_id.get(int(frame.process_frame), {}).get("physics_steps", 0))
			_frame_windows[key] = window
		while _frame_windows.size() > MAX_SAVED_WINDOWS:
			_frame_windows.erase(_frame_windows.keys()[0])
			_discarded_frame_windows += 1
		capture.perf2.frame_hitch_windows = _frame_windows.values()
		capture.perf2["discarded_saved_frame_windows"] = _discarded_frame_windows
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
