extends SceneTree

## CPU Lite open-ocean comparison against GPU PHYSICAL_HEIGHTFIELD.
## This runner deliberately uses identical world XZ and the GPU-returned field time.
const OCEAN_SCENE := preload("res://addons/ocean/ocean.tscn")
const PROFILE := preload("res://addons/ocean/resources/default_wave_profile.tres")
const STATE := preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
const QUERY := preload("res://addons/ocean/physics/gpu/ocean_surface_query.gd")
const DESCRIPTOR := "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"
const RESOLUTIONS := [128, 128, 64]
const TIMES := [0.36, 2.25, 16.89]
const SAMPLE_COUNT := 128
const NORMAL_EPSILON := 0.01
var _ocean: Node
var _fft: Node
var _gpu: RefCounted
var _tick := 0
var _report := {"status": "PARTIAL", "state_time_results": [], "failures": []}

func _initialize() -> void:
	call_deferred("_run")

func _fail(reason: String) -> void:
	_report.failures.append(reason)
	printerr("PHYS_CPU_LITE_GPU_PARITY_FAIL=" + reason)
	_report.status = "PARTIAL"
	var failed_output := FileAccess.open("res://.godot/phys_cpu_lite_gpu_parity.json", FileAccess.WRITE)
	if failed_output != null:
		failed_output.store_string(JSON.stringify(_report, "\t")); failed_output.close()
	quit(1)

func _run() -> void:
	if not ClassDB.class_exists("OceanQueryNative"):
		_fail("OceanQueryNative is not registered"); return
	_ocean = OCEAN_SCENE.instantiate()
	for property in ["coastal", "breakers", "crest_foam", "surface_foam"]: _ocean.set(property, false)
	root.add_child(_ocean)
	for _i in 16: await process_frame
	_fft = _ocean.get_node_or_null("OpenOceanFFT")
	if _fft == null: _fail("OpenOceanFFT is missing"); return
	_gpu = _fft.call("enable_gpu_surface_queries")
	for _i in 8: await process_frame
	if _gpu == null or not _gpu.get_stats().ready:
		_fail("GPU PHYSICAL_HEIGHTFIELD query unavailable: " + str(_gpu.get_stats() if _gpu else {})); return
	_gpu.set_validation_metrics_enabled(true)
	var states := _make_states(_fft.call("get_phys2_band_spectrum_snapshots"))
	var run_times: Array = TIMES
	if OS.get_cmdline_user_args().has("--smoke"):
		states = states.slice(0, 1)
		run_times = TIMES.slice(0, 1)
	for state: Dictionary in states:
		var publisher: Object = ClassDB.instantiate("OceanQueryNative")
		if not publisher.call("set_production_spectrum", state.bands) or \
				not publisher.call("start_dynamic_async_fields", 0.0, _tick):
			_fail("could not configure GPU state publisher for " + state.name); return
		for time: float in run_times:
			if not await _publish_state_at(publisher, time):
				_fail("could not publish %s at %.3f" % [state.name, time]); return
			var points := _make_points()
			var gpu_result: Dictionary = await _request_gpu(points)
			if gpu_result.is_empty(): return
			var field_time := float(gpu_result.sample_time)
			var cpu: Object = ClassDB.instantiate("OceanQueryNative")
			if not cpu.call("set_production_spectrum", state.bands) or \
					not cpu.call("build_dynamic_physics_fields", field_time) or \
					not cpu.call("build_dynamic_physics_lite", field_time, PackedInt32Array(RESOLUTIONS)):
				_fail("CPU reference/Lite build failed for %s at %.6f" % [state.name, field_time]); return
			var rows := _compare_points(cpu, points, gpu_result, field_time)
			if rows.is_empty(): _fail("invalid GPU or CPU sample for " + state.name); return
			_report.state_time_results.append({"state": state.name, "requested_time": time,
				"gpu_sample_time": field_time, "resolutions": RESOLUTIONS,
				"gpu": {"name": RenderingServer.get_video_adapter_name(),
					"renderer": RenderingServer.get_current_rendering_method(),
					"driver": RenderingServer.get_current_rendering_driver_name()},
				"comparisons": rows})
			print("PHYS_CPU_LITE_GPU_STATE_DONE=" + state.name + "@" + str(time))
		publisher.call("clear")
	_report.status = "PARTIAL" if not _report.failures.is_empty() else "GPU_MATRIX_CAPTURED_REVIEW_REQUIRED"
	_report["machine"] = {"cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "driver": RenderingServer.get_current_rendering_driver_name()}
	_report["coordinate_contract"] = "same world XZ; GPU PHYSICAL_HEIGHTFIELD q=XZ; CPU material q=XZ; CPU build uses exact returned GPU field sample_time"
	_report["comparison_contract"] = "full CPU vs GPU estimates implementation parity; Lite vs full CPU contains intentional spectral reduction plus separately measured bilinear interpolation; Lite vs GPU is total candidate error"
	var output := FileAccess.open("res://.godot/phys_cpu_lite_gpu_parity.json", FileAccess.WRITE)
	if output == null: _fail("cannot write GPU parity JSON"); return
	output.store_string(JSON.stringify(_report, "\t")); output.close()
	print("PHYS_CPU_LITE_GPU_PARITY_RESULT=res://.godot/phys_cpu_lite_gpu_parity.json")
	quit(0)

func _make_states(production_bands: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = [{"name": "Current_Production", "bands": production_bands}]
	var cases := [
		{"name": "Calm", "hs": 0.8, "wind": 4.0, "direction": 20.0, "chop": 0.8},
		{"name": "Normal", "hs": 1.8, "wind": 8.0, "direction": 35.0, "chop": 1.0},
		{"name": "Storm", "hs": 3.0, "wind": 18.0, "direction": 75.0, "chop": 2.0},
	]
	for spec: Dictionary in cases:
		var configs: Array = PROFILE.build_fft_configs(spec.hs, spec.wind, spec.direction, 0.8, 1.0)
		if float(spec.chop) >= 0.0: configs[0].choppiness = spec.chop
		var builder: Object = ClassDB.instantiate("OceanQueryNative")
		var state: Dictionary = STATE.build(configs, 1, spec.hs, PROFILE.combined_significant_wave_height_m(),
			1.0, [1.0, 1.0, 1.0], 1.0, 7, builder)
		if state.is_empty(): continue
		result.append({"name": spec.name, "bands": state.bands})
	return result

func _publish_state_at(native: Object, time: float) -> bool:
	_tick += 1
	for _attempt in 300:
		native.call("advance_dynamic_async", _tick, time, time, 1.0 / 60.0)
		var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
		if info.size() >= 4 and info[0] == 1 and absf(float(info[1]) / 1.0e9 - time) < 2.0e-9:
			var metadata: Array = native.call("get_dynamic_snapshot_spectrum", false)
			if metadata.size() == 3 and _fft.call("queue_dynamic_spectrum", native, metadata):
				_fft.set("_wave_time", time)
				for _frame in 3: await process_frame
				return true
		await process_frame
	return false

func _make_points() -> PackedVector3Array:
	var points := PackedVector3Array()
	for i in SAMPLE_COUNT:
		var hx := float((i + 1) * 2654435761 % 2147483647) / 2147483647.0
		var hz := float((i + 7) * 2246822519 % 2147483647) / 2147483647.0
		var x := (hx - 0.5) * 512.0
		var z := (hz - 0.5) * 512.0
		if i % 4 == 0: x = 256.0 - 0.0001 - float(i % 7) * 0.00001
		elif i % 4 == 1: x = -256.0 + 0.0001 + float(i % 7) * 0.00001
		if i % 8 == 2: z = 256.0 - 0.0001
		elif i % 8 == 3: z = -256.0 + 0.0001
		points.append(Vector3(x, 0.0, z))
	return points

func _request_gpu(points: PackedVector3Array) -> Dictionary:
	var generation: int = _gpu.submit(QUERY.pack_heightfield(points), Engine.get_physics_frames(), NAN, false)
	if generation < 0: _fail("GPU heightfield submit rejected"); return {}
	for _i in 180:
		await process_frame
		var result: Dictionary = _gpu.consume(Engine.get_physics_frames())
		if not result.is_empty():
			if int(result.generation) != generation: _fail("unexpected GPU query generation"); return {}
			return result
	_fail("GPU heightfield readback timeout: " + str(_gpu.get_stats())); return {}

func _compare_points(cpu: Object, points: PackedVector3Array, gpu_result: Dictionary, field_time: float) -> Array[Dictionary]:
	var groups := {"all": _new_errors(), "wrap": _new_errors(), "interior": _new_errors()}
	var bytes: PackedByteArray = gpu_result.bytes
	for i in points.size():
		var position := points[i]
		var gpu_sample: Dictionary = QUERY.decode_heightfield(bytes, i)
		if not bool(gpu_sample.valid): return []
		var full: PackedFloat64Array = cpu.call("sample_dynamic_material_q", position.x, position.z)
		if full.size() < 11: return []
		var lite_h := 0.0; var lite_v := 0.0
		for band in 3:
			var sample: PackedFloat64Array = cpu.call("sample_dynamic_lite_surface", band, position.x, position.z, 0.0)
			if sample.size() != 5: return []
			lite_h += sample[0]; lite_v += sample[1]
		# PHYSICAL_HEIGHTFIELD reports the normal of y(x,z), not the material
		# surface normal that includes horizontal displacement derivatives.
		# Match its centered 1 cm finite-difference operator on both CPU fields.
		var full_hxp: PackedFloat64Array = cpu.call("sample_dynamic_material_q", position.x + NORMAL_EPSILON, position.z)
		var full_hxm: PackedFloat64Array = cpu.call("sample_dynamic_material_q", position.x - NORMAL_EPSILON, position.z)
		var full_hzp: PackedFloat64Array = cpu.call("sample_dynamic_material_q", position.x, position.z + NORMAL_EPSILON)
		var full_hzm: PackedFloat64Array = cpu.call("sample_dynamic_material_q", position.x, position.z - NORMAL_EPSILON)
		if full_hxp.size() < 11 or full_hxm.size() < 11 or full_hzp.size() < 11 or full_hzm.size() < 11: return []
		var full_n := _heightfield_normal(full_hxp[1], full_hxm[1], full_hzp[1], full_hzm[1])
		var lite_xp := _sample_lite_height(cpu, position.x + NORMAL_EPSILON, position.z)
		var lite_xm := _sample_lite_height(cpu, position.x - NORMAL_EPSILON, position.z)
		var lite_zp := _sample_lite_height(cpu, position.x, position.z + NORMAL_EPSILON)
		var lite_zm := _sample_lite_height(cpu, position.x, position.z - NORMAL_EPSILON)
		var lite_n := _heightfield_normal(lite_xp, lite_xm, lite_zp, lite_zm)
		var gpu_n: Vector3 = gpu_sample.normal
		var err_row := {
			"lite_vs_full": {"height": absf(lite_h - full[1]), "vertical_velocity": absf(lite_v - full[9]),
				"normal_angle_degrees": rad_to_deg(lite_n.angle_to(full_n))},
			"full_cpu_vs_gpu": {"height": absf(full[1] - gpu_sample.displacement_y),
				"vertical_velocity": absf(full[9] - gpu_sample.surface_vertical_velocity),
				"normal_angle_degrees": rad_to_deg(full_n.angle_to(gpu_n))},
			"lite_vs_gpu": {"height": absf(lite_h - gpu_sample.displacement_y),
				"vertical_velocity": absf(lite_v - gpu_sample.surface_vertical_velocity),
				"normal_angle_degrees": rad_to_deg(lite_n.angle_to(gpu_n))}}
		var group_name := "wrap" if absf(position.x) > 255.0 or absf(position.z) > 255.0 else "interior"
		for axis in err_row:
			for metric in err_row[axis]:
				groups.all[axis][metric].append(float(err_row[axis][metric]))
				groups[group_name][axis][metric].append(float(err_row[axis][metric]))
	var output: Array[Dictionary] = []
	for group_name in ["all", "interior", "wrap"]:
		var summary := {}
		for axis in groups[group_name]:
			var row := {}
			for metric in groups[group_name][axis]: row[metric] = _stats(groups[group_name][axis][metric])
			summary[axis] = row
		output.append({"sample_group": group_name,
			"count": points.size() if group_name == "all" else groups[group_name].lite_vs_full.height.size(),
			"metrics": summary})
	return output

func _sample_lite_height(cpu: Object, x: float, z: float) -> float:
	var height := 0.0
	for band in 3:
		var sample: PackedFloat64Array = cpu.call("sample_dynamic_lite_surface", band, x, z, 0.0)
		if sample.size() != 5: return NAN
		height += sample[0]
	return height

func _heightfield_normal(hxp: float, hxm: float, hzp: float, hzm: float) -> Vector3:
	var hx := (hxp - hxm) / (2.0 * NORMAL_EPSILON)
	var hz := (hzp - hzm) / (2.0 * NORMAL_EPSILON)
	return Vector3(-hx, 1.0, -hz).normalized()

func _new_errors() -> Dictionary:
	var result := {}
	for axis in ["lite_vs_full", "full_cpu_vs_gpu", "lite_vs_gpu"]:
		result[axis] = {"height": [], "vertical_velocity": [], "normal_angle_degrees": []}
	return result

func _stats(source: Array) -> Dictionary:
	if source.is_empty(): return {"count": 0}
	var values := source.duplicate(); values.sort()
	var sum := 0.0; var squares := 0.0
	for value in values: sum += float(value); squares += float(value) * float(value)
	return {"count": values.size(), "mean": sum / values.size(), "rms": sqrt(squares / values.size()),
		"p95": values[ceili(values.size() * 0.95) - 1], "p99": values[ceili(values.size() * 0.99) - 1], "max": values.back()}
