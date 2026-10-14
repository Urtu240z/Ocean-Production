extends SceneTree
const Hull := preload("res://gameplay/vehicles/common/systems/jet_ski_hull_buoyancy_v1.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if not native.has_method("get_perf2_capture"):
		failures.append("PERF2 API missing"); _finish({}); return
	var metadata: Dictionary = native.call("perf2_initialize")
	var source := PackedFloat32Array()
	source.resize(128 * 128 * 4)
	var bands: Array = []
	for band in 3:
		bands.append({"resolution":128,"domain_size_m":256.0,"gravity_mps2":9.81,
			"choppiness":1.0,"h0_rgba32f":source.to_byte_array()})
	if not native.call("set_production_spectrum", bands): failures.append("fixture import failed")
	for frame in 100:
		native.call("perf1_set_context", frame, frame, frame, 1, false, 1)
		if not native.call("build_dynamic_physics_lite", float(frame) / 60.0, PackedInt32Array([128,128,128])):
			failures.append("fixture build failed")
		if frame == 50: OS.delay_msec(63) # Isolated trigger fixture, never gameplay.
		native.call("perf2_frame_boundary", frame, frame, 25000)
	var frames: Dictionary = native.call("get_perf2_capture")
	var target: Dictionary = {}
	for window: Dictionary in frames.frame_hitch_windows:
		if int(window.trigger_frame) == 50: target = window
	if target.is_empty(): failures.append("63 ms frame did not trigger window")
	else:
		if not target.complete or target.frames.size() != 65: failures.append("incomplete frame context")
		if not target.has("build_records") or target.build_records.size() != 65: failures.append("individual builds absent from frame window")
		if int(target.missing_build_records) != 0: failures.append("lost native records")
		var parsed: Variant = JSON.parse_string(JSON.stringify(target))
		if not parsed is Dictionary or parsed.frames.size() != 65: failures.append("frame window JSON invalid")
	# Golden hash captured from the implementation before PERF-2, 144 cell cases.
	const CELL_BASELINE_SHA256 := "9f4a127425bddceae7292922d1fcb5e78fbc238db7dce05b2faf0acaeee14e3e"
	var hull := Hull.new()
	var collision := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	var points := PackedVector3Array()
	for x in [-0.5, 0.5]:
		for y in [-0.3, 0.3]:
			for z in [-1.5, 1.5]: points.append(Vector3(x,y,z))
	shape.points = points; collision.shape = shape
	if not hull.configure(collision): failures.append("hull fixture setup failed")
	hull.perf2_sink = native
	var comparisons := 0
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	for pitch in [-0.8, 0.0, 0.8]:
		for height in [-0.6, -0.1, 0.3, 0.9]:
			var transform := Transform3D(Basis.from_euler(Vector3(pitch,0.2,0.1)),Vector3(0,height,0))
			var sample := WaterSample3D.new()
			sample.surface_position = Vector3.ZERO
			sample.normal = Vector3(0.1,1.0,0.2).normalized()
			for cell in 12:
				var actual: Dictionary = hull.integrate_cell(cell,transform,sample,0.05)
				var center: Vector3 = actual.center
				digest.update(PackedFloat64Array([actual.volume,center.x,center.y,center.z,actual.depth]).to_byte_array())
				comparisons += 1
	collision.free()
	var hash := digest.finish().hex_encode()
	if hash != CELL_BASELINE_SHA256: failures.append("cell results changed from pre-PERF2 baseline")
	_finish({"metadata":metadata,"cell_comparisons":comparisons,"cell_baseline_sha256":hash,"frame_windows":frames.frame_hitch_windows.size()})

func _finish(result: Dictionary) -> void:
	result.failures = failures
	result.status = "PASS" if failures.is_empty() else "FAIL"
	var file := FileAccess.open("res://temp/perf2_validation_result.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t")); file.close()
	print("PERF2_VALIDATION ", result)
	quit(0 if failures.is_empty() else 1)
