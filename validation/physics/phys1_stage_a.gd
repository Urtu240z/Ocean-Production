extends SceneTree
## PHYS-1 Stage A only. Run with the project renderer (not --headless):
## godot --path . --script res://validation/physics/phys1_stage_a.gd

const OCEAN_SCENE := preload("res://addons/ocean/ocean.tscn")
const SpectrumAdapter := preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const OFFSETS := [0.0, 0.25, 0.5, 1.0]
const STRIDE := 15
const INDEX_DX := 2
const INDEX_DY := 3
const INDEX_DZ := 4
const INDEX_NX := 5
const INDEX_NY := 6
const INDEX_NZ := 7
const INDEX_VX := 8
const INDEX_VY := 9
const INDEX_VZ := 10

var _ocean: Node
var _fft: Node
var _solver: Object
var _rd: RenderingDevice
var _native: Object
var _positions := PackedVector3Array()
var _grid_cells: Array[Vector2i] = []
var _domain_m := 0.0
var _report: Dictionary = {"stage": "A", "samples": [], "scalar_batch": {}}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# A .gdextension descriptor is loaded as a Resource; it is not auto-loaded
	# merely because it exists in the project tree.
	var native_extension: Resource = load("res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension")
	if native_extension == null:
		_fail("OceanQueryNative GDExtension descriptor could not be loaded.")
		return
	if not ClassDB.class_exists("OceanQueryNative"):
		_fail("OceanQueryNative GDExtension is not loaded; build the Windows release first.")
		return
	_ocean = OCEAN_SCENE.instantiate()
	_ocean.set("long_enabled", true)
	_ocean.set("mid_enabled", false)
	_ocean.set("short_enabled", false)
	_ocean.set("coastal", false)
	_ocean.set("breakers", false)
	_ocean.set("crest_foam", false)
	_ocean.set("surface_foam", false)
	_ocean.set("long_band_scale", 1.0)
	_ocean.set("wave_height_scale", 1.0)
	_ocean.set("ocean_scale", 1.0)
	_ocean.set("clipmap_geometry_scale", 1.0)
	root.add_child(_ocean)
	for _frame in 4:
		await process_frame
	_fft = _ocean.get_node_or_null("OpenOceanFFT")
	if _fft == null or not _fft.has_method("get_phys1_long_spectrum_snapshot"):
		_fail("Production OpenOceanFFT did not expose the LONG CPU spectrum snapshot.")
		return
	var snapshot: Dictionary = _fft.call("get_phys1_long_spectrum_snapshot")
	if snapshot.is_empty():
		_fail("LONG spectrum snapshot is empty.")
		return
	_domain_m = float(snapshot["domain_size_m"])
	_solver = _fft.get("_solvers")[0]
	_rd = _solver.get("_rd") as RenderingDevice
	if _rd == null:
		_fail("Production RenderingDevice is unavailable; run this harness with the project renderer.")
		return
	_native = ClassDB.instantiate("OceanQueryNative")
	var setup: Dictionary = SpectrumAdapter.configure_long(_native, snapshot, float(_ocean.get("sea_level")))
	if not bool(setup.get("ok", false)):
		_fail(str(setup.get("error", "Native spectrum setup failed.")))
		return
	_make_deterministic_samples(int(snapshot["resolution"]))
	_report["spectrum"] = setup
	_report["scale_contract"] = {
		"long_band_scale": float(_ocean.get("long_band_scale")),
		"wave_height_scale": float(_ocean.get("wave_height_scale")),
		"ocean_scale": float(snapshot["ocean_scale"]),
		"clipmap_geometry_scale": float(snapshot["clipmap_geometry_scale"]),
		"long_choppiness": float(snapshot["choppiness"]),
	}
	var base_time := float(_ocean.call("get_wave_time"))
	var captures: Array[Dictionary] = []
	for offset in OFFSETS:
		await _wait_for_wave_time(base_time + float(offset))
		await process_frame
		var wave_time := float(_ocean.call("get_wave_time"))
		_rd.submit()
		_rd.sync()
		var gpu_bytes: PackedByteArray = _rd.texture_get_data(_solver.get("displacement_rid"), 0)
		if gpu_bytes.size() != int(snapshot["resolution"]) * int(snapshot["resolution"]) * 16:
			_fail("LONG displacement readback has an unexpected byte count.")
			return
		var native_batch: PackedFloat64Array = _native.call("sample_material_q_batch", wave_time, _positions)
		var capture := _compare_capture(gpu_bytes, native_batch, wave_time, int(snapshot["resolution"]))
		captures.append(capture)
		_report["samples"].append(capture)
		print("PHYS1_STAGE_A_CAPTURE " + JSON.stringify(capture))
	_report["temporal_velocity"] = _compare_surface_velocity(captures)
	_report["scalar_batch"] = _check_scalar_batch()
	var json := JSON.stringify(_report, "\t")
	var out := FileAccess.open("user://phys1_stage_a.json", FileAccess.WRITE)
	if out != null:
		out.store_string(json + "\n")
	print("PHYS1_STAGE_A_REPORT " + json)
	print("PHYS1_STAGE_A_COMPLETE; review measured error before enabling Stage B")
	quit(0)


func _make_deterministic_samples(n: int) -> void:
	for i in 16:
		var x := (i * 37 + 13) % n
		var y := (i * 71 + 29) % n
		_grid_cells.append(Vector2i(x, y))
		var qx := ((float(x) + 0.5) / float(n) - 0.5) * _domain_m
		var qz := ((float(y) + 0.5) / float(n) - 0.5) * _domain_m
		_positions.append(Vector3(qx, 0.0, qz))


func _compare_capture(gpu: PackedByteArray, native: PackedFloat64Array, wave_time: float, n: int) -> Dictionary:
	var errors := [[], [], []]
	var gpu_values: Array[Vector3] = []
	var native_values: Array[Vector3] = []
	for point in _positions.size():
		var cell := _grid_cells[point]
		var pixel := (cell.y * n + cell.x) * 16
		var gpu_xyz := Vector3(gpu.decode_float(pixel), gpu.decode_float(pixel + 4), gpu.decode_float(pixel + 8))
		var base := point * STRIDE
		var cpu_xyz := Vector3(native[base + INDEX_DX], native[base + INDEX_DY], native[base + INDEX_DZ])
		gpu_values.append(gpu_xyz)
		native_values.append(cpu_xyz)
		errors[0].append(absf(gpu_xyz.x - cpu_xyz.x))
		errors[1].append(absf(gpu_xyz.y - cpu_xyz.y))
		errors[2].append(absf(gpu_xyz.z - cpu_xyz.z))
	var axes: Array[Dictionary] = []
	for axis in 3:
		var maximum := 0.0
		var sum := 0.0
		var squares := 0.0
		for value in errors[axis]:
			maximum = maxf(maximum, value)
			sum += value
			squares += value * value
		axes.append({"max": maximum, "mean_abs": sum / float(errors[axis].size()), "rms": sqrt(squares / float(errors[axis].size()))})
	return {"wave_time": wave_time, "point_count": _positions.size(), "axes_xyz": axes,
		"gpu_xyz": gpu_values, "native_xyz": native_values}


func _compare_surface_velocity(captures: Array[Dictionary]) -> Dictionary:
	var gpu_axis_error := [[], [], []]
	var native_axis_error := [[], [], []]
	if captures.size() < 2:
		return {"valid": false, "reason": "Need at least two shared-clock captures."}
	for sample_index in _positions.size():
		for frame in range(1, captures.size()):
			var t0 := float(captures[frame - 1]["wave_time"])
			var t1 := float(captures[frame]["wave_time"])
			if t1 <= t0: continue
			var p: Vector3 = _positions[sample_index]
			var a: PackedFloat64Array = _native.call("sample_material_q", p.x, p.z, t0)
			var b: PackedFloat64Array = _native.call("sample_material_q", p.x, p.z, t1)
			var middle: PackedFloat64Array = _native.call("sample_material_q", p.x, p.z, (t0 + t1) * 0.5)
			var gpu_a: Vector3 = captures[frame - 1]["gpu_xyz"][sample_index]
			var gpu_b: Vector3 = captures[frame]["gpu_xyz"][sample_index]
			for axis in 3:
				var disp_index: int = [INDEX_DX, INDEX_DY, INDEX_DZ][axis]
				var vel_index: int = [INDEX_VX, INDEX_VY, INDEX_VZ][axis]
				var gpu_fd := (gpu_b[axis] - gpu_a[axis]) / (t1 - t0)
				var native_fd := (b[disp_index] - a[disp_index]) / (t1 - t0)
				gpu_axis_error[axis].append(absf(gpu_fd - middle[vel_index]))
				native_axis_error[axis].append(absf(native_fd - middle[vel_index]))
	return {"valid": true, "meaning": "surface_velocity = temporal derivative of LONG surface displacement",
		"gpu_fd_max_abs_xyz": [_max(gpu_axis_error[0]), _max(gpu_axis_error[1]), _max(gpu_axis_error[2])],
		"gpu_fd_mean_abs_xyz": [_mean(gpu_axis_error[0]), _mean(gpu_axis_error[1]), _mean(gpu_axis_error[2])],
		"native_fd_max_abs_xyz": [_max(native_axis_error[0]), _max(native_axis_error[1]), _max(native_axis_error[2])],
		"native_fd_mean_abs_xyz": [_mean(native_axis_error[0]), _mean(native_axis_error[1]), _mean(native_axis_error[2])]}


func _check_scalar_batch() -> Dictionary:
	var result := {}
	for count in [1, 4, 8, 16]:
		var points := PackedVector3Array()
		for i in count: points.append(_positions[i])
		var t := float(_ocean.call("get_wave_time"))
		var batch: PackedFloat64Array = _native.call("sample_material_q_batch", t, points)
		var max_error := 0.0
		for i in count:
			var point: Vector3 = points[i]
			var scalar: PackedFloat64Array = _native.call("sample_material_q", point.x, point.z, t)
			for field in STRIDE:
				max_error = maxf(max_error, absf(batch[i * STRIDE + field] - scalar[field]))
		result[str(count)] = max_error
	return result


func _wait_for_wave_time(target: float) -> void:
	while float(_ocean.call("get_wave_time")) < target:
		await process_frame


func _max(values: Array) -> float:
	var result := 0.0
	for value in values: result = maxf(result, float(value))
	return result


func _mean(values: Array) -> float:
	if values.is_empty(): return 0.0
	var sum := 0.0
	for value in values: sum += float(value)
	return sum / float(values.size())


func _fail(message: String) -> void:
	push_error("PHYS1_STAGE_A FAIL: " + message)
	quit(1)
