extends SceneTree
## Isolated reporting fixture. No vehicle or production ocean is instantiated.
class FixtureHost extends Node:
	var native: Object
	var frames := 0
	func _process(_delta: float) -> void:
		frames += 1
		native.call("perf1_set_context", Engine.get_physics_frames(), Engine.get_process_frames(), Engine.get_frames_drawn(), 1, false, 1)
		for build in 4:
			native.call("build_dynamic_physics_lite", float(frames) / 60.0, PackedInt32Array([128,128,128]))
		if frames == 60: OS.delay_msec(63)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	var data := PackedFloat32Array()
	data.resize(128 * 128 * 4)
	var bands: Array = []
	for band in 3: bands.append({"resolution":128,"domain_size_m":256.0,"gravity_mps2":9.81,"choppiness":1.0,"h0_rgba32f":data.to_byte_array()})
	assert(native.call("set_production_spectrum", bands))
	var reporter := preload("res://gameplay/water/perf1_capture.gd").new()
	root.add_child(reporter); reporter.configure(native)
	var host := FixtureHost.new(); host.native = native; root.add_child(host)
	for frame in 180: await process_frame
	host.set_process(false)
	var path: String = reporter.report_path
	reporter.queue_free(); host.queue_free()
	await process_frame
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var found := false
	var missing := 0
	for window: Dictionary in report.perf2.frame_hitch_windows:
		if window.complete:
			found = true
			missing += int(window.missing_build_records)
	var result := {"complete_frame_window":found,"missing_build_records":missing,"capture":report.metadata.capture,
		"window_count":report.perf2.frame_hitch_windows.size(),"report_path":path}
	var file := FileAccess.open("res://temp/perf2_automatic_validation.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t"));file.close()
	print("PERF2_AUTOMATIC_VALIDATION ", result)
	quit(0 if found and missing == 0 else 1)
