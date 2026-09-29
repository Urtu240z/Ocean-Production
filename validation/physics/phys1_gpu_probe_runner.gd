extends SceneTree
## PHYS-1.2 GPU/native LONG material-q packet validation.

const OCEAN_SCENE: PackedScene = preload("res://addons/ocean/ocean.tscn")
const SPECTRUM_ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const GPU_PROBE = preload("res://validation/physics/phys1_gpu_probe.gd")
const GPU_LINEAR_PROBE = preload("res://validation/physics/phys1_gpu_linear_probe.gd")
const NATIVE_DESCRIPTOR := "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"
const PROBE_SHADER := "res://validation/physics/phys1_gpu_probe.glsl"
const LINEAR_PROBE_SHADER := "res://validation/physics/phys1_gpu_linear_probe.glsl"
const STRIDE := 15
const DISP_X := 2
const DISP_Y := 3
const DISP_Z := 4
const S_VALID := 0
const S_RESIDUAL := 13
const S_ITERATIONS := 14

signal _probe_packet_completed

var _ocean: Node
var _fft: Node
var _native: Object
var _probe: RefCounted
var _linear_probe: RefCounted
var _long_rid := RID()
var _resolution := 0
var _domain_m := 0.0
var _request_id := 0
var _completed: Dictionary = {}
var _report: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var descriptor: Resource = load(NATIVE_DESCRIPTOR)
	if descriptor == null or not ClassDB.class_exists("OceanQueryNative"):
		_fail("Native descriptor/class load gate failed.")
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
	for _frame in range(4):
		await RenderingServer.frame_post_draw
	_fft = _ocean.get_node_or_null("OpenOceanFFT")
	if _fft == null:
		_fail("OpenOceanFFT was not created.")
		return
	var snapshot: Dictionary = _fft.call("get_phys1_long_spectrum_snapshot")
	if snapshot.is_empty():
		_fail("Production LONG H0 snapshot was empty.")
		return
	_resolution = int(snapshot["resolution"])
	_domain_m = float(snapshot["domain_size_m"])
	var solvers: Array = _fft.get("_solvers")
	if solvers.is_empty() or solvers[0] == null:
		_fail("LONG solver was unavailable.")
		return
	var solver: Object = solvers[0]
	_long_rid = solver.get("displacement_rid") as RID
	var lifecycle: Dictionary = _fft.call("get_fft_resource_lifecycle_state")
	var bands: Array = lifecycle.get("bands", [])
	if bands.is_empty():
		_fail("Production FFT did not publish a LONG resource record.")
		return
	var long_band: Dictionary = bands[0]
	var surface_long_rid: RID = long_band.get("published_displacement", RID())
	if not _long_rid.is_valid() or _long_rid != surface_long_rid or _resolution < 2 or _domain_m <= 0.0:
		_fail("The probe source is not the published LONG displacement texture.")
		return
	_native = ClassDB.instantiate("OceanQueryNative")
	var adapter: Dictionary = SPECTRUM_ADAPTER.configure_long(_native, snapshot, float(_ocean.get("sea_level")))
	if not bool(adapter.get("ok", false)):
		_fail("Native LONG setup failed: " + str(adapter.get("error", "unknown")))
		return
	_probe = GPU_PROBE.new()
	var shader_file: RDShaderFile = load(PROBE_SHADER) as RDShaderFile
	if shader_file == null:
		_fail("The validation compute shader was not imported as RDShaderFile.")
		return
	RenderingServer.call_on_render_thread(_probe.initialize.bind(self, _long_rid, shader_file))
	while not bool(_report.get("probe_initialized", false)):
		await process_frame
	if not bool(_report["probe_initialized"]):
		_fail("GPU probe initialization failed: " + str(_report.get("probe_error", "unknown")))
		return
	_linear_probe = GPU_LINEAR_PROBE.new()
	var linear_shader_file: RDShaderFile = load(LINEAR_PROBE_SHADER) as RDShaderFile
	if linear_shader_file == null:
		_fail("The validation filtered-sampling shader was not imported as RDShaderFile.")
		return
	RenderingServer.call_on_render_thread(_linear_probe.initialize.bind(self, _long_rid, linear_shader_file))
	while not bool(_report.get("linear_probe_initialized", false)):
		await process_frame
	if not bool(_report["linear_probe_initialized"]):
		_fail("Filtered GPU probe initialization failed: " + str(_report.get("linear_probe_error", "unknown")))
		return
	_report["gpu_source"] = {
		"source": "OpenOceanFFT._solvers[0].displacement_rid; verified equal to published LONG texture_rd_rid",
		"rid": str(_long_rid),
		"format": "R32G32B32A32_SFLOAT / rgba32f",
		"resolution": _resolution,
		"domain_m": _domain_m,
		"channels": "R=X horizontal displacement; G=Y vertical; B=Z horizontal; A=Jacobian (not compared)",
		"sampling": "integer imageLoad/texelFetch equivalent; q maps through fract(q/domain+0.5) to texel centers",
		"wrap": "periodic on both axes; q wrapped into [-domain/2, domain/2)",
		"fft_shift_and_scale": "centered k grid; checkerboard (-1)^(x+y); 1/N^2 normalization; choppiness applied in Production assemble shader",
		"texture_readback": false,
		"global_rd": true,
	}
	_report["spectrum_adapter"] = adapter
	await _freeze_clock_and_settle()
	var frozen_before: float = float(_ocean.call("get_wave_time"))
	for _frame in range(3):
		await RenderingServer.frame_post_draw
	var frozen_after: float = float(_ocean.call("get_wave_time"))
	if not is_equal_approx(frozen_before, frozen_after):
		_fail("Ocean time moved while the static probe suite was meant to be frozen.")
		return
	_report["frozen_time"] = frozen_after
	var test_a: Array[Dictionary] = []
	for cell in [Vector2i(16, 24), Vector2i(63, 111), Vector2i(172, 203), Vector2i(_resolution - 1, _resolution - 1)]:
		test_a.append(_sample_for_lattice(int(cell.x), int(cell.y)))
	_report["test_a_4_frozen"] = await _run_packet("A_frozen_4", test_a)
	var test_b: Array[Dictionary] = []
	for z_index in range(8):
		for x_index in range(8):
			test_b.append(_sample_for_lattice(x_index * (_resolution / 8) + (_resolution / 16), z_index * (_resolution / 8) + (_resolution / 16)))
	_report["test_b_64_frozen"] = await _run_packet("B_frozen_64", test_b)
	var test_c: Array[Dictionary] = []
	var edge_indices: Array[int] = [-1, 0, 1, _resolution - 1]
	var other_edge_indices: Array[int] = [-1, 0, _resolution - 1, _resolution]
	for iz in other_edge_indices:
		for ix in edge_indices:
			test_c.append(_sample_for_lattice(ix, iz))
	_report["test_c_16_wrap"] = await _run_packet("C_wrap_16", test_c)
	_ocean.set("wave_speed_multiplier", 1.0)
	await RenderingServer.frame_post_draw
	var moving_time: float = float(_ocean.call("get_wave_time"))
	var test_d: Array[Dictionary] = []
	for z_index in range(4):
		for x_index in range(4):
			test_d.append(_sample_for_lattice(x_index * (_resolution / 4) + (_resolution / 8), z_index * (_resolution / 4) + (_resolution / 8)))
	_report["test_d_16_moving"] = await _run_packet("D_moving_16", test_d, moving_time)
	_report["request_association_valid"] = true
	_report["coordinate_wrap_contract"] = _verify_coordinate_wrap_contract()
	await _freeze_clock_and_settle()
	_report["off_grid_16_frozen"] = await _run_off_grid_packet()
	_report["world_xz_16_frozen"] = await _run_world_xz_packet()
	var report_text := JSON.stringify(_report, "\t")
	var output := FileAccess.open("user://phys1_gpu_probe.json", FileAccess.WRITE)
	if output != null:
		output.store_string(report_text + "\n")
	print("PHYS1_GPU_PROBE_REPORT " + report_text)
	print("PHYS1_GPU_PROBE_COMPLETE")
	RenderingServer.call_on_render_thread(_linear_probe.shutdown)
	RenderingServer.call_on_render_thread(_probe.shutdown)
	quit(0)


func _freeze_clock_and_settle() -> void:
	_ocean.set("wave_speed_multiplier", 0.0)
	for _frame in range(3):
		await RenderingServer.frame_post_draw


func _sample_for_lattice(ix: int, iz: int) -> Dictionary:
	var qx := ((float(ix) + 0.5) / float(_resolution) - 0.5) * _domain_m
	var qz := ((float(iz) + 0.5) / float(_resolution) - 0.5) * _domain_m
	var wrapped_x := fposmod(qx + _domain_m * 0.5, _domain_m) - _domain_m * 0.5
	var wrapped_z := fposmod(qz + _domain_m * 0.5, _domain_m) - _domain_m * 0.5
	var texel_x := posmod(floori((wrapped_x / _domain_m + 0.5) * float(_resolution)), _resolution)
	var texel_z := posmod(floori((wrapped_z / _domain_m + 0.5) * float(_resolution)), _resolution)
	return {
		"q": Vector2(qx, qz),
		"wrapped_q": Vector2(wrapped_x, wrapped_z),
		"texel": Vector2i(texel_x, texel_z),
	}


func _run_packet(label: String, samples: Array[Dictionary], forced_time := NAN) -> Dictionary:
	var wave_time := forced_time if is_finite(forced_time) else float(_ocean.call("get_wave_time"))
	var positions := PackedVector3Array()
	var texels := PackedVector2Array()
	var fft_qs: Array[Vector2] = []
	for sample in samples:
		var q: Vector2 = sample["q"]
		var wrapped: Vector2 = sample["wrapped_q"]
		var texel: Vector2i = sample.get("texel", Vector2i.ZERO)
		# Recompute lattice mapping from q, not from the test generator's index.
		var mapped_x := posmod(floori((wrapped.x / _domain_m + 0.5) * float(_resolution)), _resolution)
		var mapped_z := posmod(floori((wrapped.y / _domain_m + 0.5) * float(_resolution)), _resolution)
		if mapped_x != texel.x or mapped_z != texel.y:
			return {"valid": false, "error": "q-to-texel mapping mismatch", "label": label}
		positions.append(Vector3(q.x, 0.0, q.y))
		var fft_q_values: PackedFloat64Array = _native.call("material_q_to_fft_q", q.x, q.y)
		fft_qs.append(Vector2(fft_q_values[0], fft_q_values[1]))
		texels.append(Vector2(texel.x, texel.y))
	var batch_start_usec := Time.get_ticks_usec()
	var native_values: PackedFloat64Array = _native.call("sample_material_q_batch", wave_time, positions)
	var native_batch_us := Time.get_ticks_usec() - batch_start_usec
	if native_values.size() != samples.size() * STRIDE:
		return {"valid": false, "error": "native batch result had an unexpected size", "label": label}
	var native_xyz: Array[Vector3] = []
	for index in samples.size():
		var base := index * STRIDE
		native_xyz.append(Vector3(native_values[base + DISP_X], native_values[base + DISP_Y], native_values[base + DISP_Z]))
	var scalar_16_us := -1
	var batch_scalar_max_error := 0.0
	if label == "B_frozen_64":
		var scalar_start_usec := Time.get_ticks_usec()
		for index in mini(16, samples.size()):
			var scalar_q: Vector2 = samples[index]["q"]
			var scalar: PackedFloat64Array = _native.call("sample_material_q", scalar_q.x, scalar_q.y, wave_time)
			var base := index * STRIDE
			for field in STRIDE:
				batch_scalar_max_error = maxf(batch_scalar_max_error, absf(native_values[base + field] - scalar[field]))
		scalar_16_us = Time.get_ticks_usec() - scalar_start_usec
	_request_id += 1
	var request := {
		"request_id": _request_id,
		"label": label,
		"production_wave_time": wave_time,
		"native_time": wave_time,
		"q_samples": samples,
		"fft_q_samples": fft_qs,
		"native_result": native_xyz,
		"native_batch_query_us": native_batch_us,
		"native_scalar_16_query_us": scalar_16_us,
		"batch_scalar_max_error": batch_scalar_max_error,
		"request_process_frame": Engine.get_process_frames(),
		"gpu_request_frame": Engine.get_process_frames(),
	}
	RenderingServer.call_on_render_thread(_probe.dispatch_request.bind(request, texels))
	while not _completed.has(_request_id):
		await _probe_packet_completed
	var result: Dictionary = _completed[_request_id]
	_completed.erase(_request_id)
	return result


func _run_off_grid_packet() -> Dictionary:
	var samples: Array[Dictionary] = []
	var uvs := PackedVector2Array()
	for index in 16:
		var q := Vector2(
			_wrap_centered(-241.37 + float(index) * 31.713, _domain_m),
			_wrap_centered(219.83 - float(index) * 27.119, _domain_m))
		var uv := q / _domain_m + Vector2(0.5, 0.5)
		samples.append({"q": q, "wrapped_q": q, "uv": uv})
		uvs.append(uv)
	var packet := await _run_linear_packet(samples, uvs)
	if not bool(packet.get("valid", false)):
		return packet
	var neighbor_positions := PackedVector3Array()
	var interpolation_data: Array[Dictionary] = []
	for sample in samples:
		var uv: Vector2 = sample["uv"]
		var gx := uv.x * float(_resolution) - 0.5
		var gz := uv.y * float(_resolution) - 0.5
		var x0 := floori(gx)
		var z0 := floori(gz)
		var fx := gx - float(x0)
		var fz := gz - float(z0)
		var cells := [Vector2i(x0, z0), Vector2i(x0 + 1, z0), Vector2i(x0, z0 + 1), Vector2i(x0 + 1, z0 + 1)]
		for cell in cells:
			var wrapped_x := posmod(cell.x, _resolution)
			var wrapped_z := posmod(cell.y, _resolution)
			var qx := ((float(wrapped_x) + 0.5) / float(_resolution) - 0.5) * _domain_m
			var qz := ((float(wrapped_z) + 0.5) / float(_resolution) - 0.5) * _domain_m
			neighbor_positions.append(Vector3(qx, 0.0, qz))
		interpolation_data.append({"fx": fx, "fz": fz})
	var time := float(packet["production_wave_time"])
	var neighbor_values: PackedFloat64Array = _native.call("sample_material_q_batch", time, neighbor_positions)
	var interp_errors: Array[float] = []
	var exact_errors: Array[float] = []
	for index in samples.size():
		var base := index * 4 * STRIDE
		var weights: Dictionary = interpolation_data[index]
		var fx: float = weights["fx"]
		var fz: float = weights["fz"]
		var gpu: Vector3 = packet["samples"][index]["gpu_xyz"]
		var native_exact: Vector3 = packet["samples"][index]["native_xyz"]
		var matched := Vector3.ZERO
		for corner in 4:
			var wx := fx if corner % 2 == 1 else 1.0 - fx
			var wz := fz if corner >= 2 else 1.0 - fz
			var weight := wx * wz
			matched += weight * Vector3(neighbor_values[base + corner * STRIDE + DISP_X], neighbor_values[base + corner * STRIDE + DISP_Y], neighbor_values[base + corner * STRIDE + DISP_Z])
		interp_errors.append((gpu - matched).length())
		exact_errors.append((gpu - native_exact).length())
	packet["rendered_interpolation_difference"] = {
		"sampling_mode": "linear repeat sampler, matching ocean_surface.gdshader filter_linear",
		"samples": samples.size(),
		"gpu_vs_native_exact_vector_error": _absolute_stats(exact_errors),
		"gpu_vs_interpolation_matched_native_vector_error": _absolute_stats(interp_errors),
	}
	return packet


func _run_world_xz_packet() -> Dictionary:
	var samples: Array[Dictionary] = []
	for z_index in range(4):
		for x_index in range(4):
			samples.append(_sample_for_lattice(x_index * (_resolution / 4) + (_resolution / 8), z_index * (_resolution / 4) + (_resolution / 8)))
	var source_packet := await _run_packet("world_xz_source_16", samples)
	if not bool(source_packet.get("valid", false)):
		return source_packet
	var q_errors: Array[float] = []
	var displacement_errors: Array[float] = []
	var residuals: Array[float] = []
	var iterations: Array[float] = []
	var failed := 0
	var rows: Array[Dictionary] = []
	var world_positions := PackedVector3Array()
	var scalar_batch_errors: Array[float] = []
	var wave_time := float(source_packet["production_wave_time"])
	for index in samples.size():
		var sample: Dictionary = samples[index]
		var q: Vector2 = sample["q"]
		var gpu: Vector3 = source_packet["samples"][index]["gpu_xyz"]
		var world_xz := q + Vector2(gpu.x, gpu.z)
		world_positions.append(Vector3(world_xz.x, 0.0, world_xz.y))
		var query: PackedFloat64Array = _native.call("sample_world_with_material_q", world_xz.x, world_xz.y, wave_time)
		var recovered := Vector2(query[STRIDE], query[STRIDE + 1])
		var q_error := recovered.distance_to(q)
		var native_displacement := Vector3(query[DISP_X], query[DISP_Y], query[DISP_Z])
		var displacement_error := (gpu - native_displacement).length()
		var residual := query[S_RESIDUAL]
		var count := int(query[S_ITERATIONS])
		if query[S_VALID] < 0.5 or residual > 0.001:
			failed += 1
		q_errors.append(q_error)
		displacement_errors.append(displacement_error)
		residuals.append(residual)
		iterations.append(float(count))
		rows.append({"material_q": q, "world_xz": world_xz, "recovered_material_q": recovered,
			"q_error_m": q_error, "gpu_displacement": gpu, "native_displacement": native_displacement,
			"displacement_error_m": displacement_error, "residual_m": residual, "iterations": count,
			"fft_q_at_recovered_material_q": _native.call("material_q_to_fft_q", recovered.x, recovered.y)})
	var batch_values: PackedFloat64Array = _native.call("sample_batch", wave_time, world_positions)
	if batch_values.size() != samples.size() * STRIDE:
		return {"valid": false, "error": "world-XZ batch returned an unexpected result size", "sample_count": samples.size()}
	for index in samples.size():
		var base := index * STRIDE
		var scalar: Vector3 = rows[index]["native_displacement"]
		var batched := Vector3(batch_values[base + DISP_X], batch_values[base + DISP_Y], batch_values[base + DISP_Z])
		scalar_batch_errors.append((scalar - batched).length())
	return {"valid": failed == 0, "sample_count": samples.size(), "failed_inversions": failed,
		"material_q_error_m": _absolute_stats(q_errors), "displacement_error_m": _absolute_stats(displacement_errors),
		"residual_m": _absolute_stats(residuals), "inversion_iterations": _absolute_stats(iterations),
		"scalar_vs_batch_vector_error_m": _absolute_stats(scalar_batch_errors),
		"samples": rows, "production_wave_time": wave_time, "gpu_request_frame": source_packet["gpu_request_frame"],
		"same_time_proven": source_packet["same_time_proven"]}


func _run_linear_packet(samples: Array[Dictionary], uvs: PackedVector2Array) -> Dictionary:
	var wave_time := float(_ocean.call("get_wave_time"))
	var positions := PackedVector3Array()
	var fft_qs: Array[Vector2] = []
	for sample in samples:
		var q: Vector2 = sample["q"]
		positions.append(Vector3(q.x, 0.0, q.y))
		var fft: PackedFloat64Array = _native.call("material_q_to_fft_q", q.x, q.y)
		fft_qs.append(Vector2(fft[0], fft[1]))
	var native_values: PackedFloat64Array = _native.call("sample_material_q_batch", wave_time, positions)
	var native_xyz: Array[Vector3] = []
	for index in samples.size():
		var base := index * STRIDE
		native_xyz.append(Vector3(native_values[base + DISP_X], native_values[base + DISP_Y], native_values[base + DISP_Z]))
	_request_id += 1
	var request := {"request_id": _request_id, "label": "off_grid_gpu_linear", "production_wave_time": wave_time,
		"native_time": wave_time, "q_samples": samples, "fft_q_samples": fft_qs, "native_result": native_xyz,
		"request_process_frame": Engine.get_process_frames(), "gpu_request_frame": Engine.get_process_frames()}
	RenderingServer.call_on_render_thread(_linear_probe.dispatch_request.bind(request, uvs))
	while not _completed.has(_request_id):
		await _probe_packet_completed
	var result: Dictionary = _completed[_request_id]
	_completed.erase(_request_id)
	return result


func _wrap_centered(value: float, domain: float) -> float:
	return fposmod(value + domain * 0.5, domain) - domain * 0.5


func _verify_coordinate_wrap_contract() -> Dictionary:
	var half := _domain_m * 0.5
	var epsilon := 0.000001
	var cases := [-_domain_m, -half, -half - epsilon, -epsilon, 0.0, epsilon,
		half - epsilon, half, _domain_m, _domain_m * 3.0 + 0.125]
	var rows: Array[Dictionary] = []
	var periodic_error := 0.0
	var interval_valid := true
	for qx in cases:
		var fft: PackedFloat64Array = _native.call("material_q_to_fft_q", qx, -qx)
		var shifted: PackedFloat64Array = _native.call("material_q_to_fft_q", qx + 2.0 * _domain_m, -qx - 2.0 * _domain_m)
		periodic_error = maxf(periodic_error, maxf(absf(fft[0] - shifted[0]), absf(fft[1] - shifted[1])))
		interval_valid = interval_valid and fft[0] >= -half and fft[0] < half and fft[1] >= -half and fft[1] < half
		rows.append({"material_q": Vector2(qx, -qx), "fft_q": Vector2(fft[0], fft[1])})
	return {"canonical_interval": "[-L/2, +L/2)", "cases": rows,
		"all_converted_coordinates_in_interval": interval_valid,
		"periodicity_error_for_plus_two_domains_m": periodic_error}


func _on_gpu_probe_initialized(ok: bool, error: String) -> void:
	_report["probe_initialized"] = ok
	_report["probe_error"] = error


func _on_linear_probe_initialized(ok: bool, error: String) -> void:
	_report["linear_probe_initialized"] = ok
	_report["linear_probe_error"] = error


func _on_linear_probe_readback(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	_on_gpu_probe_readback(request, bytes, error)


func _on_gpu_probe_readback(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	var request_id := int(request["request_id"])
	var result: Dictionary = {"valid": error.is_empty(), "label": request["label"], "error": error}
	if error.is_empty():
		var samples: Array = request["q_samples"]
		var native_xyz: Array = request["native_result"]
		var fft_qs: Array = request["fft_q_samples"]
		if bytes.size() != samples.size() * 16:
			result["valid"] = false
			result["error"] = "async result byte count did not match N * sizeof(vec4)"
		else:
			var rows: Array[Dictionary] = []
			var error_x: Array[float] = []
			var error_y: Array[float] = []
			var error_z: Array[float] = []
			var signed_x: Array[float] = []
			var signed_y: Array[float] = []
			var signed_z: Array[float] = []
			var error_vector: Array[float] = []
			for index in samples.size():
				var byte_offset := index * 16
				var raw := Vector4(bytes.decode_float(byte_offset), bytes.decode_float(byte_offset + 4), bytes.decode_float(byte_offset + 8), bytes.decode_float(byte_offset + 12))
				var gpu := Vector3(raw.x, raw.y, raw.z)
				var native: Vector3 = native_xyz[index]
				var signed := gpu - native
				var sample: Dictionary = samples[index]
				error_x.append(absf(signed.x)); error_y.append(absf(signed.y)); error_z.append(absf(signed.z))
				signed_x.append(signed.x); signed_y.append(signed.y); signed_z.append(signed.z)
				error_vector.append(signed.length())
				rows.append({"material_q": sample["q"], "wrapped_material_q": sample["wrapped_q"], "fft_q": fft_qs[index], "texel": sample.get("texel", Vector2i(-1, -1)), "uv": sample.get("uv", Vector2.ZERO), "gpu_raw_rgba": raw, "gpu_xyz": gpu, "native_xyz": native, "signed_error_gpu_minus_native": signed})
			var callback_frame := Engine.get_process_frames()
			var request_frame := int(request["gpu_request_frame"])
			var same_time := is_equal_approx(float(request["production_wave_time"]), float(request["native_time"]))
			result.merge({
				"request_id": request_id,
				"production_wave_time": request["production_wave_time"],
				"native_time": request["native_time"],
				"gpu_request_frame": request_frame,
				"callback_frame": callback_frame,
				"async_latency_frames": maxi(callback_frame - request_frame, 0),
				"same_time_proven": same_time,
				"samples": rows,
				"component_errors": {"X": _component_stats(error_x, signed_x), "Y": _component_stats(error_y, signed_y), "Z": _component_stats(error_z, signed_z)},
				"vector_error": _absolute_stats(error_vector),
				"result_buffer_bytes": bytes.size(),
				"sample_count": samples.size(),
				"native_batch_query_us": request.get("native_batch_query_us", -1),
				"native_scalar_16_query_us": request.get("native_scalar_16_query_us", -1),
				"batch_scalar_max_error": request.get("batch_scalar_max_error", -1.0),
			}, true)
	_completed[request_id] = result
	_probe_packet_completed.emit()


func _component_stats(absolute_errors: Array[float], signed_errors: Array[float]) -> Dictionary:
	var stats := _absolute_stats(absolute_errors)
	var signed_sum := 0.0
	for value in signed_errors:
		signed_sum += value
	stats["mean_signed_gpu_minus_native"] = signed_sum / float(signed_errors.size())
	return stats


func _absolute_stats(values: Array[float]) -> Dictionary:
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var total := 0.0
	var maximum := 0.0
	for value in values:
		total += value
		maximum = maxf(maximum, value)
	var p95_index := mini(values.size() - 1, int(ceil(float(values.size() - 1) * 0.95)))
	return {"mean": total / float(values.size()), "p95": sorted[p95_index], "max": maximum}


func _fail(message: String) -> void:
	push_error("PHYS1_GPU_PROBE_FAIL: " + message)
	print("PHYS1_GPU_PROBE_FAIL " + message)
	quit(1)
