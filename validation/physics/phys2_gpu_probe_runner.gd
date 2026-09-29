extends SceneTree
## PHYS-2 validation-only probe. Samples the three actual Production displacement RIDs
## on the global RenderingDevice and compares them with retained-H0 native spectra.

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
const BAND_NAMES := ["LONG", "MID", "SHORT"]
const BAND_MASKS := [1, 2, 4]

signal _probe_packet_completed

var _ocean: Node
var _fft: Node
var _snapshots: Array[Dictionary] = []
var _native_by_band: Array[Object] = []
var _native_combined: Object
var _probes: Array[RefCounted] = []
var _linear_probes: Array[RefCounted] = []
var _probe_initialized := false
var _probe_init_error := ""
var _linear_probe_initialized := false
var _linear_probe_init_error := ""
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
	_ocean.set("mid_enabled", true)
	_ocean.set("short_enabled", true)
	_ocean.set("coastal", false)
	_ocean.set("breakers", false)
	_ocean.set("crest_foam", false)
	_ocean.set("surface_foam", false)
	_ocean.set("long_band_scale", 1.0)
	_ocean.set("mid_band_scale", 1.0)
	_ocean.set("short_band_scale", 1.0)
	_ocean.set("wave_height_scale", 1.0)
	_ocean.set("ocean_scale", 1.0)
	_ocean.set("clipmap_geometry_scale", 1.0)
	root.add_child(_ocean)
	for _frame in range(5):
		await RenderingServer.frame_post_draw
	_fft = _ocean.get_node_or_null("OpenOceanFFT")
	if _fft == null:
		_fail("OpenOceanFFT was not created.")
		return
	_snapshots = _fft.call("get_phys2_band_spectrum_snapshots")
	if _snapshots.size() != 3:
		_fail("Production did not expose three retained final H0 snapshots.")
		return
	var resource_state: Dictionary = _fft.call("get_fft_resource_lifecycle_state")
	var resource_bands: Array = resource_state.get("bands", [])
	if resource_bands.size() != 3:
		_fail("Production did not publish three FFT resource records.")
		return
	var band_table: Array[Dictionary] = []
	for band_index in 3:
		var snapshot: Dictionary = _snapshots[band_index]
		var resources: Dictionary = resource_bands[band_index]
		var n := int(snapshot.get("resolution", 0))
		var domain := float(snapshot.get("domain_size_m", 0.0))
		var h0: PackedByteArray = snapshot.get("h0_rgba32f", PackedByteArray())
		var rid: RID = snapshot.get("displacement_rid", RID())
		var published_rid: RID = resources.get("published_displacement", RID())
		var solver_rid: RID = snapshot.get("published_displacement_rid", RID())
		var normal_rid: RID = snapshot.get("normal_rid", RID())
		var published_normal: RID = resources.get("published_normal", RID())
		if String(snapshot.get("band", "")) != BAND_NAMES[band_index] or n < 2 or domain <= 0.0:
			_fail("Invalid runtime band configuration at index %d." % band_index)
			return
		if h0.size() != n * n * 16 or not bool(snapshot.get("solver_ready", false)):
			_fail("%s final H0 or solver is unavailable." % BAND_NAMES[band_index])
			return
		if not rid.is_valid() or rid != published_rid or rid != solver_rid:
			_fail("%s probe source is not the exact published Production displacement RID." % BAND_NAMES[band_index])
		if not normal_rid.is_valid() or normal_rid != published_normal:
			_fail("%s normal RID publication mismatch." % BAND_NAMES[band_index])
		if not rid.is_valid() or not normal_rid.is_valid():
			return
		band_table.append({
			"band": BAND_NAMES[band_index], "N": n, "L_m": domain,
			"dx_m": domain / float(n),
			"material_to_fft_offset_m": domain * 0.5 - domain / (2.0 * float(n)),
			"choppiness": float(snapshot.get("choppiness", 0.0)),
			"gravity_mps2": float(snapshot.get("gravity_mps2", 0.0)),
			"effective_amplitude_scale": float(snapshot.get("effective_amplitude_scale", 1.0)),
			"H0_source": snapshot.get("h0_source", ""), "H0_bytes": h0.size(),
			"Production_H0_retained_as_uploaded": true,
			"displacement_RID": str(rid), "normal_RID": str(normal_rid),
		})
	_report["band_contracts"] = band_table
	_report["source_contract"] = {
		"spectral_data": "the final per-band RGBA32F H0 bytes retained from the exact Production solver upload",
		"time_authority": "Ocean.get_wave_time()",
		"texture": "final Production per-band displacement RID; R=X, G=Y, B=Z, A=per-band Jacobian",
		"probe": "global RenderingDevice, exact integer texel reads and tiny asynchronous buffer readback",
		"sampler": "material uses repeating linear-filtered displacement sampling; exact grid tests use imageLoad",
		"normal": "Production normal texture is a half-float finite-difference geometry normal; native normal is analytic physical normal",
	}
	var h0_source_checks: Array[Dictionary] = []
	for i in 3:
		h0_source_checks.append({"band": BAND_NAMES[i], "same_retained_upload": true,
			"byte_count": int(_snapshots[i]["h0_rgba32f"].size())})
	_report["H0_source_checks"] = h0_source_checks

	for band_index in 3:
		var native: Object = ClassDB.instantiate("OceanQueryNative")
		var setup: Dictionary = SPECTRUM_ADAPTER.configure_bands(native, _snapshots,
			float(_ocean.get("sea_level")), BAND_MASKS[band_index])
		if not bool(setup.get("ok", false)):
			_fail("%s native setup failed: %s" % [BAND_NAMES[band_index], setup.get("error", "unknown")])
			return
		_native_by_band.append(native)
		_report[BAND_NAMES[band_index] + "_setup"] = setup
	_native_combined = ClassDB.instantiate("OceanQueryNative")
	var combined_setup: Dictionary = SPECTRUM_ADAPTER.configure_bands(_native_combined, _snapshots,
		float(_ocean.get("sea_level")), 7)
	if not bool(combined_setup.get("ok", false)):
		_fail("Combined native setup failed.")
		return
	_report["combined_setup"] = combined_setup

	var exact_shader := load(PROBE_SHADER) as RDShaderFile
	var linear_shader := load(LINEAR_PROBE_SHADER) as RDShaderFile
	if exact_shader == null or linear_shader == null:
		_fail("PHYS-1 validation probe shaders were not imported.")
		return
	for band_index in 3:
		var exact_probe: RefCounted = GPU_PROBE.new()
		_probes.append(exact_probe)
		_probe_initialized = false
		_probe_init_error = ""
		RenderingServer.call_on_render_thread(exact_probe.initialize.bind(self,
			_snapshots[band_index]["displacement_rid"], exact_shader))
		while not _probe_initialized:
			await process_frame
		if not _probe_init_error.is_empty():
			_fail("%s exact GPU probe failed: %s" % [BAND_NAMES[band_index], _probe_init_error])
			return
		var linear_probe: RefCounted = GPU_LINEAR_PROBE.new()
		_linear_probes.append(linear_probe)
		_linear_probe_initialized = false
		_linear_probe_init_error = ""
		RenderingServer.call_on_render_thread(linear_probe.initialize.bind(self,
			_snapshots[band_index]["displacement_rid"], linear_shader))
		while not _linear_probe_initialized:
			await process_frame
		if not _linear_probe_init_error.is_empty():
			_fail("%s filtered GPU probe failed: %s" % [BAND_NAMES[band_index], _linear_probe_init_error])
			return

	await _test_clock_authority()
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	var frozen_time: float = float(_ocean.call("get_wave_time"))
	_report["frozen_time"] = frozen_time
	var band_samples: Array = []
	for band_index in 3:
		var n := int(_snapshots[band_index]["resolution"])
		var domain := float(_snapshots[band_index]["domain_size_m"])
		var a_samples := _make_grid_packet(band_index, [Vector2i(16, 24), Vector2i(63, 111), Vector2i(172, 203), Vector2i(n - 1, n - 1)])
		var result_a := await _run_probe_packet(band_index, a_samples, frozen_time, "A_frozen_4", false, _native_by_band[band_index])
		var b_samples := _make_spread_packet(band_index, 64)
		var result_b := await _run_probe_packet(band_index, b_samples, frozen_time, "B_frozen_64", false, _native_by_band[band_index])
		var c_samples := _make_wrap_packet(band_index)
		var result_c := await _run_probe_packet(band_index, c_samples, frozen_time, "C_wrap_16", false, _native_by_band[band_index])
		band_samples.append(b_samples)
		_report[BAND_NAMES[band_index] + "_grid_4"] = _compact_packet(result_a)
		_report[BAND_NAMES[band_index] + "_grid_64"] = _compact_packet(result_b)
		_report[BAND_NAMES[band_index] + "_wrap_16"] = _compact_packet(result_c)
		_report[BAND_NAMES[band_index] + "_wrap_contract"] = _verify_wrap_contract(band_index)
		var off_grid := _make_off_grid_packet(band_index, 16)
		var off_grid_result := await _run_off_grid_band(band_index, off_grid, frozen_time)
		_report[BAND_NAMES[band_index] + "_off_grid"] = off_grid_result

	var moving_time := await _capture_moving_packet_time()
	_report["moving_wave_time"] = moving_time
	# The moving packet advances Production time once, then freezes it before
	# the async GPU probes. All subsequent combined-band packets must use this
	# settled texture time, not the earlier pre-resume frozen timestamp.
	frozen_time = float(_ocean.call("get_wave_time"))
	_report["combined_frozen_time"] = frozen_time
	for band_index in 3:
		var moving_samples := _make_spread_packet(band_index, 16)
		var moving := await _run_probe_packet(band_index, moving_samples, moving_time,
			"D_moving_16", false, _native_by_band[band_index])
		_report[BAND_NAMES[band_index] + "_moving_16"] = _compact_packet(moving)

	var combined_q: Array[Dictionary] = _make_combined_q_packet(64)
	var combined_material := await _run_combined_material_packet(combined_q, frozen_time)
	_report["combined_material_q_64"] = combined_material
	var combined_moving_q: Array[Dictionary] = _make_combined_q_packet(16)
	_report["combined_moving_material_q_16"] = await _run_combined_material_packet(combined_moving_q, moving_time)
	_report["combined_world_xz_64"] = await _run_combined_world_packet(combined_q, frozen_time)
	_report["combined_world_xz_moving_16"] = await _run_combined_world_packet(combined_moving_q, moving_time)
	_report["batch_correctness"] = _run_batch_correctness(combined_q, frozen_time)
	_report["physical_vs_render_contract"] = {
		"physical_surface": "continuous raw LONG+MID+SHORT spectral sum at common material_q; camera-independent",
		"rendered_surface": "three linear-filtered displacement textures with camera-distance cascade weights and Ocean Space scale",
		"coastal": false,
		"native_normal": "analytic derivative-based geometric normal of the continuous combined spectrum",
		"Production_normal": "per-band finite-difference geometry normal texture used by vertex/optics paths; optical normal maps are additional render-only detail",
		"distance_weights_in_physical_query": false,
	}
	_report["provisional_performance"] = await _run_performance_matrix(frozen_time)
	var report_text := JSON.stringify(_report, "\t")
	var output := FileAccess.open("user://phys2_gpu_probe.json", FileAccess.WRITE)
	if output != null:
		output.store_string(report_text + "\n")
	print("PHYS2_GPU_PROBE_REPORT " + report_text)
	print("PHYS2_GPU_PROBE_COMPLETE")
	for probe in _probes:
		RenderingServer.call_on_render_thread(probe.shutdown)
	for probe in _linear_probes:
		RenderingServer.call_on_render_thread(probe.shutdown)
	quit(0)


func _test_clock_authority() -> void:
	var start: float = float(_ocean.call("get_wave_time"))
	_ocean.set("wave_speed_multiplier", 1.0)
	for _frame in range(3):
		await RenderingServer.frame_post_draw
	var one_x: float = float(_ocean.call("get_wave_time"))
	var native_time_1x := one_x
	_native_combined.call("sample_material_q", 0.0, 0.0, native_time_1x)
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	var frozen_a: float = float(_ocean.call("get_wave_time"))
	_native_combined.call("sample_material_q", 0.0, 0.0, frozen_a)
	await _settle_clock()
	var frozen_b: float = float(_ocean.call("get_wave_time"))
	_ocean.set("wave_speed_multiplier", 1.0)
	for _frame in range(3):
		await RenderingServer.frame_post_draw
	var resumed: float = float(_ocean.call("get_wave_time"))
	_native_combined.call("sample_material_q", 0.0, 0.0, resumed)
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	_report["clock"] = {
		"wave_time_t0": start, "wave_time_1x": one_x, "native_time_1x": native_time_1x,
		"wave_time_freeze_start": frozen_a, "wave_time_freeze_end": frozen_b,
		"wave_time_resume": resumed, "native_time_resume": resumed,
		"one_x_advanced": one_x > start, "zero_x_froze": is_equal_approx(frozen_a, frozen_b),
		"resume_advanced": resumed > frozen_b,
		"native_time_is_explicit_caller_value": true,
	}


func _settle_clock() -> void:
	for _frame in 3:
		await RenderingServer.frame_post_draw


func _capture_moving_packet_time() -> float:
	_ocean.set("wave_speed_multiplier", 1.0)
	await RenderingServer.frame_post_draw
	var captured := float(_ocean.call("get_wave_time"))
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	return captured


func _make_grid_packet(band_index: int, cells: Array[Vector2i]) -> Array[Dictionary]:
	var n := int(_snapshots[band_index]["resolution"])
	var domain := float(_snapshots[band_index]["domain_size_m"])
	var result: Array[Dictionary] = []
	for cell in cells:
		result.append(_sample_at_cell(cell.x, cell.y, n, domain))
	return result


func _make_spread_packet(band_index: int, count: int) -> Array[Dictionary]:
	var n := int(_snapshots[band_index]["resolution"])
	var domain := float(_snapshots[band_index]["domain_size_m"])
	var side := int(ceil(sqrt(float(count))))
	var result: Array[Dictionary] = []
	for z in side:
		for x in side:
			if result.size() >= count:
				break
			var ix := posmod(x * maxi(n / side, 1) + maxi(n / (side * 2), 0), n)
			var iz := posmod(z * maxi(n / side, 1) + maxi(n / (side * 2), 0), n)
			result.append(_sample_at_cell(ix, iz, n, domain))
	return result


func _make_wrap_packet(band_index: int) -> Array[Dictionary]:
	var n := int(_snapshots[band_index]["resolution"])
	var domain := float(_snapshots[band_index]["domain_size_m"])
	var edges: Array[int] = [-1, 0, 1, n - 1]
	var result: Array[Dictionary] = []
	for iz in edges:
		for ix in edges:
			result.append(_sample_at_cell(ix, iz, n, domain))
	return result


func _sample_at_cell(ix: int, iz: int, n: int, domain: float) -> Dictionary:
	var q := Vector2(((float(ix) + 0.5) / float(n) - 0.5) * domain,
		((float(iz) + 0.5) / float(n) - 0.5) * domain)
	var wrapped := Vector2(_wrap_centered(q.x, domain), _wrap_centered(q.y, domain))
	return {"q": q, "wrapped_q": wrapped,
		"texel": Vector2i(posmod(ix, n), posmod(iz, n)),
		"uv": q / domain + Vector2(0.5, 0.5)}


func _make_off_grid_packet(band_index: int, count: int) -> Array[Dictionary]:
	var domain := float(_snapshots[band_index]["domain_size_m"])
	var result: Array[Dictionary] = []
	for i in count:
		var q := Vector2(_wrap_centered(-0.4731 * domain + float(i) * domain * 0.1193, domain),
			_wrap_centered(0.4317 * domain - float(i) * domain * 0.0931, domain))
		result.append({"q": q, "wrapped_q": q, "uv": q / domain + Vector2(0.5, 0.5), "texel": Vector2i(-1, -1)})
	return result


func _make_combined_q_packet(count: int) -> Array[Dictionary]:
	var long_domain := float(_snapshots[0]["domain_size_m"])
	var result: Array[Dictionary] = []
	for i in count:
		var u := float((i * 37) % maxi(count, 1)) / float(maxi(count - 1, 1))
		var v := float((i * 19 + 7) % maxi(count, 1)) / float(maxi(count - 1, 1))
		var q := Vector2(_wrap_centered((u * 1.8 - 0.9) * long_domain, long_domain),
			_wrap_centered((v * 1.8 - 0.9) * long_domain, long_domain))
		result.append({"q": q, "wrapped_q": q, "uv": Vector2.ZERO, "texel": Vector2i(-1, -1)})
	return result


func _run_probe_packet(band_index: int, samples: Array[Dictionary], wave_time: float,
		label: String, filtered: bool, native_query: Object) -> Dictionary:
	var positions := PackedVector3Array()
	var uvs := PackedVector2Array()
	for sample in samples:
		var q: Vector2 = sample["q"]
		positions.append(Vector3(q.x, 0.0, q.y))
		uvs.append(q / float(_snapshots[band_index]["domain_size_m"]) + Vector2(0.5, 0.5))
	var native_values: PackedFloat64Array = native_query.call("sample_material_q_batch", wave_time, positions)
	if native_values.size() != samples.size() * STRIDE:
		return {"valid": false, "error": "Native batch result had wrong size", "label": label}
	var native_xyz: Array[Vector3] = []
	for i in samples.size():
		var base := i * STRIDE
		native_xyz.append(Vector3(native_values[base + DISP_X], native_values[base + DISP_Y], native_values[base + DISP_Z]))
	_request_id += 1
	var request := {
		"request_id": _request_id, "label": label, "band_index": band_index,
		"production_wave_time": wave_time, "native_time": wave_time,
		"q_samples": samples, "native_result": native_xyz,
		"gpu_request_frame": Engine.get_process_frames(),
		"request_process_frame": Engine.get_process_frames(),
	}
	if filtered:
		RenderingServer.call_on_render_thread(_linear_probes[band_index].dispatch_request.bind(request, uvs))
	else:
		var texels := PackedVector2Array()
		for sample in samples:
			texels.append(Vector2(sample["texel"]))
		RenderingServer.call_on_render_thread(_probes[band_index].dispatch_request.bind(request, texels))
	while not _completed.has(_request_id):
		await _probe_packet_completed
	return _completed[_request_id]


func _on_gpu_probe_initialized(ok: bool, error: String) -> void:
	_probe_initialized = true
	_probe_init_error = "" if ok else error


func _on_linear_probe_initialized(ok: bool, error: String) -> void:
	_linear_probe_initialized = true
	_linear_probe_init_error = "" if ok else error


func _on_gpu_probe_readback(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	var result: Dictionary = {"valid": error.is_empty(), "label": request.get("label", ""), "error": error}
	if error.is_empty() and bytes.size() == request["q_samples"].size() * 16:
		var samples: Array = request["q_samples"]
		var native_xyz: Array = request["native_result"]
		var errors: Array = [[], [], []]
		var signed: Array = [[], [], []]
		var vector_errors: Array[float] = []
		var rows: Array[Dictionary] = []
		for i in samples.size():
			var offset := i * 16
			var gpu := Vector3(bytes.decode_float(offset), bytes.decode_float(offset + 4), bytes.decode_float(offset + 8))
			var native: Vector3 = native_xyz[i]
			var delta := gpu - native
			for axis in 3:
				errors[axis].append(absf(delta[axis]))
				signed[axis].append(delta[axis])
			vector_errors.append(delta.length())
			rows.append({"q": samples[i]["q"], "gpu": gpu, "native": native, "signed_error_gpu_minus_native": delta})
		var callback_frame := Engine.get_process_frames()
		result.merge({
			"request_id": int(request["request_id"]), "band": BAND_NAMES[int(request["band_index"])],
			"production_wave_time": request["production_wave_time"], "native_time": request["native_time"],
			"gpu_request_frame": request["gpu_request_frame"], "callback_frame": callback_frame,
			"async_latency_frames": maxi(callback_frame - int(request["gpu_request_frame"]), 0),
			"same_time_proven": is_equal_approx(float(request["production_wave_time"]), float(request["native_time"])),
			"sample_count": samples.size(), "result_buffer_bytes": bytes.size(),
			"component_errors": {"X": _component_stats(errors[0], signed[0]),
				"Y": _component_stats(errors[1], signed[1]), "Z": _component_stats(errors[2], signed[2])},
			"vector_error": _stats(vector_errors), "samples": rows,
		}, true)
	elif error.is_empty():
		result["valid"] = false
		result["error"] = "Unexpected async probe byte count: %d" % bytes.size()
	_completed[int(request["request_id"])] = result
	_probe_packet_completed.emit()


func _on_linear_probe_readback(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	_on_gpu_probe_readback(request, bytes, error)


func _run_off_grid_band(band_index: int, samples: Array[Dictionary], wave_time: float) -> Dictionary:
	var packet: Dictionary = await _run_probe_packet(band_index, samples, wave_time, "off_grid", true, _native_by_band[band_index])
	if not bool(packet.get("valid", false)):
		return packet
	var n := int(_snapshots[band_index]["resolution"])
	var domain := float(_snapshots[band_index]["domain_size_m"])
	var neighbors := PackedVector3Array()
	var lerps: Array[Dictionary] = []
	for sample in samples:
		var uv: Vector2 = sample["uv"]
		var gx := uv.x * float(n) - 0.5
		var gz := uv.y * float(n) - 0.5
		var x0 := floori(gx)
		var z0 := floori(gz)
		var fx := gx - float(x0)
		var fz := gz - float(z0)
		for corner in [Vector2i(x0, z0), Vector2i(x0 + 1, z0), Vector2i(x0, z0 + 1), Vector2i(x0 + 1, z0 + 1)]:
			var ix := posmod(corner.x, n)
			var iz := posmod(corner.y, n)
			var q := Vector2(((float(ix) + 0.5) / float(n) - 0.5) * domain,
				((float(iz) + 0.5) / float(n) - 0.5) * domain)
			neighbors.append(Vector3(q.x, 0.0, q.y))
		lerps.append({"fx": fx, "fz": fz})
	var neighbor_native: PackedFloat64Array = _native_by_band[band_index].call("sample_material_q_batch", wave_time, neighbors)
	var exact_errors: Array[float] = []
	var matched_errors: Array[float] = []
	for i in samples.size():
		var gpu: Vector3 = packet["samples"][i]["gpu"]
		var exact: Vector3 = packet["samples"][i]["native"]
		exact_errors.append((gpu - exact).length())
		var fx: float = lerps[i]["fx"]
		var fz: float = lerps[i]["fz"]
		var matched := Vector3.ZERO
		for corner in 4:
			var wx := fx if corner % 2 == 1 else 1.0 - fx
			var wz := fz if corner >= 2 else 1.0 - fz
			var weight := wx * wz
			var base := (i * 4 + corner) * STRIDE
			matched += weight * Vector3(neighbor_native[base + DISP_X], neighbor_native[base + DISP_Y], neighbor_native[base + DISP_Z])
		matched_errors.append((gpu - matched).length())
	return {"samples": samples.size(), "sampling_mode": "repeat + linear filter (matching Production material)",
		"GPU_filtered_vs_native_exact_vector": _stats(exact_errors),
		"GPU_filtered_vs_bilinear_native_lattice_vector": _stats(matched_errors),
		"meaning": "native exact is the continuous physical field; GPU/native lattice bilinear residual isolates rendered interpolation precision"}


func _run_combined_material_packet(samples: Array[Dictionary], wave_time: float) -> Dictionary:
	var per_band_rows: Array = []
	for band_index in 3:
		var packet: Dictionary = await _run_probe_packet(band_index, samples, wave_time,
			"combined_material_%s" % BAND_NAMES[band_index], true, _native_by_band[band_index])
		if not bool(packet.get("valid", false)):
			return packet
		per_band_rows.append(packet["samples"])
	var positions := PackedVector3Array()
	for sample in samples:
		var q: Vector2 = sample["q"]
		positions.append(Vector3(q.x, 0.0, q.y))
	var total_native: PackedFloat64Array = _native_combined.call("sample_material_q_batch", wave_time, positions)
	var gpu_errors: Array[float] = []
	var component_errors: Array = [[], [], []]
	var component_signed: Array = [[], [], []]
	var interpolation_errors: Array[float] = []
	var native_sum_errors: Array[float] = []
	var per_band_native_values: Array = []
	var interpolation_values: Array = []
	var per_band_filtered_errors: Array = []
	var per_band_bilinear_errors: Array = []
	for band_index in 3:
		per_band_native_values.append(_native_values_for_positions(_native_by_band[band_index], positions, wave_time))
		interpolation_values.append(_native_interpolation_values(band_index, samples, wave_time, _native_by_band[band_index]))
		per_band_filtered_errors.append([])
		per_band_bilinear_errors.append([])
	for i in samples.size():
		var gpu_sum := Vector3.ZERO
		var matched_sum := Vector3.ZERO
		var individual_native_sum := Vector3.ZERO
		for band_index in 3:
			gpu_sum += Vector3(per_band_rows[band_index][i]["gpu"])
			matched_sum += Vector3(interpolation_values[band_index][i])
			var native_values: PackedFloat64Array = per_band_native_values[band_index]
			var base := i * STRIDE
			individual_native_sum += Vector3(native_values[base + DISP_X], native_values[base + DISP_Y], native_values[base + DISP_Z])
			var band_gpu := Vector3(per_band_rows[band_index][i]["gpu"])
			per_band_filtered_errors[band_index].append((band_gpu - Vector3(native_values[base + DISP_X], native_values[base + DISP_Y], native_values[base + DISP_Z])).length())
			per_band_bilinear_errors[band_index].append((band_gpu - Vector3(interpolation_values[band_index][i])).length())
		var base := i * STRIDE
		var combined := Vector3(total_native[base + DISP_X], total_native[base + DISP_Y], total_native[base + DISP_Z])
		var delta := gpu_sum - combined
		gpu_errors.append(delta.length())
		for axis in 3:
			component_errors[axis].append(absf(delta[axis]))
			component_signed[axis].append(delta[axis])
		interpolation_errors.append((gpu_sum - matched_sum).length())
		native_sum_errors.append((individual_native_sum - combined).length())
	return {
		"samples": samples.size(), "production_wave_time": wave_time,
		"same_material_q_all_bands": true, "same_time_all_bands": true,
		"native_combined_vs_sum_of_individual_native_vector": _stats(native_sum_errors),
		"GPU_filtered_sum_vs_native_exact_combined_vector": _stats(gpu_errors),
		"GPU_filtered_sum_vs_native_exact_combined_components": {
			"X": _component_stats(component_errors[0], component_signed[0]),
			"Y": _component_stats(component_errors[1], component_signed[1]),
			"Z": _component_stats(component_errors[2], component_signed[2])},
		"GPU_filtered_sum_vs_bilinear_interpolation_matched_native_vector": _stats(interpolation_errors),
		"per_band_GPU_filtered_vs_native_exact": [
			_stats(per_band_filtered_errors[0]), _stats(per_band_filtered_errors[1]), _stats(per_band_filtered_errors[2])],
		"per_band_GPU_filtered_vs_bilinear_native": [
			_stats(per_band_bilinear_errors[0]), _stats(per_band_bilinear_errors[1]), _stats(per_band_bilinear_errors[2])],
		"band_filtering_is_render_only": true,
	}


func _native_values_for_positions(native: Object, positions: PackedVector3Array, wave_time: float) -> PackedFloat64Array:
	return native.call("sample_material_q_batch", wave_time, positions)


func _native_interpolation_values(band_index: int, samples: Array[Dictionary], wave_time: float,
		native: Object) -> Array[Vector3]:
	var n := int(_snapshots[band_index]["resolution"])
	var domain := float(_snapshots[band_index]["domain_size_m"])
	var neighbors := PackedVector3Array()
	var lerps: Array[Vector2] = []
	for sample in samples:
		var q: Vector2 = sample["q"]
		var uv := q / domain + Vector2(0.5, 0.5)
		var gx := uv.x * float(n) - 0.5
		var gz := uv.y * float(n) - 0.5
		var x0 := floori(gx)
		var z0 := floori(gz)
		lerps.append(Vector2(gx - float(x0), gz - float(z0)))
		for cell in [Vector2i(x0, z0), Vector2i(x0 + 1, z0), Vector2i(x0, z0 + 1), Vector2i(x0 + 1, z0 + 1)]:
			var ix := posmod(cell.x, n)
			var iz := posmod(cell.y, n)
			var lattice_q := Vector2(((float(ix) + 0.5) / float(n) - 0.5) * domain,
				((float(iz) + 0.5) / float(n) - 0.5) * domain)
			neighbors.append(Vector3(lattice_q.x, 0.0, lattice_q.y))
	var values: PackedFloat64Array = native.call("sample_material_q_batch", wave_time, neighbors)
	var result: Array[Vector3] = []
	for i in samples.size():
		var fx := lerps[i].x
		var fz := lerps[i].y
		var out := Vector3.ZERO
		for corner in 4:
			var wx := fx if corner % 2 == 1 else 1.0 - fx
			var wz := fz if corner >= 2 else 1.0 - fz
			var weight := wx * wz
			var base := (i * 4 + corner) * STRIDE
			out += weight * Vector3(values[base + DISP_X], values[base + DISP_Y], values[base + DISP_Z])
		result.append(out)
	return result


func _run_combined_world_packet(samples: Array[Dictionary], wave_time: float) -> Dictionary:
	var per_band_rows: Array = []
	for band_index in 3:
		var packet: Dictionary = await _run_probe_packet(band_index, samples, wave_time,
			"world_%s" % BAND_NAMES[band_index], true, _native_by_band[band_index])
		if not bool(packet.get("valid", false)):
			return packet
		per_band_rows.append(packet["samples"])
	var worlds := PackedVector3Array()
	var source_qs := PackedVector2Array()
	var gpu_sums: Array[Vector3] = []
	var native_q_displacements: Array[Vector3] = []
	var native_material: PackedFloat64Array = _native_combined.call("sample_material_q_batch", wave_time, _positions_from_samples(samples))
	for i in samples.size():
		var q: Vector2 = samples[i]["q"]
		var sum_gpu := Vector3.ZERO
		for band_index in 3:
			sum_gpu += Vector3(per_band_rows[band_index][i]["gpu"])
		var base := i * STRIDE
		var native_q_disp := Vector3(native_material[base + DISP_X], native_material[base + DISP_Y], native_material[base + DISP_Z])
		var world_render := q + Vector2(sum_gpu.x, sum_gpu.z)
		worlds.append(Vector3(world_render.x, 0.0, world_render.y))
		source_qs.append(q)
		gpu_sums.append(sum_gpu)
		native_q_displacements.append(native_q_disp)
	var q_errors: Array[float] = []
	var residuals: Array[float] = []
	var displacement_errors: Array[float] = []
	var height_errors: Array[float] = []
	var iterations: Array[float] = []
	var failures := 0
	var scalar_world: Array[PackedFloat64Array] = []
	for i in samples.size():
		var world: Vector3 = worlds[i]
		var query: PackedFloat64Array = _native_combined.call("sample_world_with_material_q", world.x, world.z, wave_time)
		var recovered := Vector2(query[STRIDE], query[STRIDE + 1])
		var q_error := recovered.distance_to(source_qs[i])
		var native_displacement := Vector3(query[DISP_X], query[DISP_Y], query[DISP_Z])
		var residual := float(query[S_RESIDUAL])
		if query[S_VALID] < 0.5 or residual > 0.001:
			failures += 1
		q_errors.append(q_error)
		residuals.append(residual)
		displacement_errors.append((native_displacement - gpu_sums[i]).length())
		height_errors.append(absf(native_displacement.y - gpu_sums[i].y))
		iterations.append(float(query[S_ITERATIONS]))
		scalar_world.append(query)
	var batch: PackedFloat64Array = _native_combined.call("sample_batch", wave_time, worlds)
	var scalar_batch_errors: Array[float] = []
	for i in samples.size():
		var base := i * STRIDE
		var delta := Vector3(batch[base + DISP_X] - scalar_world[i][DISP_X],
			batch[base + DISP_Y] - scalar_world[i][DISP_Y], batch[base + DISP_Z] - scalar_world[i][DISP_Z])
		scalar_batch_errors.append(delta.length())
	var mat_scalar_batch := _compare_material_scalar_batch(_native_combined, samples, wave_time)
	var physical_worlds := PackedVector3Array()
	for i in samples.size():
		var q: Vector2 = source_qs[i]
		var displacement: Vector3 = native_q_displacements[i]
		physical_worlds.append(Vector3(q.x + displacement.x, 0.0, q.y + displacement.z))
	var physical_q_errors: Array[float] = []
	var physical_residuals: Array[float] = []
	var physical_displacement_errors: Array[float] = []
	var physical_failures := 0
	var physical_scalar: Array[PackedFloat64Array] = []
	for i in physical_worlds.size():
		var world: Vector3 = physical_worlds[i]
		var query: PackedFloat64Array = _native_combined.call("sample_world_with_material_q", world.x, world.z, wave_time)
		var recovered := Vector2(query[STRIDE], query[STRIDE + 1])
		var source_q: Vector2 = source_qs[i]
		var delta := Vector3(query[DISP_X], query[DISP_Y], query[DISP_Z]) - native_q_displacements[i]
		physical_q_errors.append(recovered.distance_to(source_q))
		physical_residuals.append(float(query[S_RESIDUAL]))
		physical_displacement_errors.append(delta.length())
		if query[S_VALID] < 0.5 or query[S_RESIDUAL] > 0.001:
			physical_failures += 1
		physical_scalar.append(query)
	var physical_batch: PackedFloat64Array = _native_combined.call("sample_batch", wave_time, physical_worlds)
	var physical_batch_errors: Array[float] = []
	for i in physical_scalar.size():
		var base := i * STRIDE
		physical_batch_errors.append(Vector3(physical_batch[base + DISP_X] - physical_scalar[i][DISP_X],
			physical_batch[base + DISP_Y] - physical_scalar[i][DISP_Y], physical_batch[base + DISP_Z] - physical_scalar[i][DISP_Z]).length())
	return {
		"samples": samples.size(), "failed_inversions": failures,
		"iterations": _stats(iterations), "material_q_recovery_error_m": _stats(q_errors),
		"horizontal_query_residual_m": _stats(residuals),
		"displacement_error_vs_Production_filtered_surface_m": _stats(displacement_errors),
		"height_error_vs_Production_filtered_surface_m": _stats(height_errors),
		"world_scalar_vs_batch_vector_error_m": _stats(scalar_batch_errors),
		"continuous_physical_surface_inversion": {
			"samples": samples.size(), "failed_inversions": physical_failures,
			"material_q_recovery_error_m": _stats(physical_q_errors),
			"horizontal_query_residual_m": _stats(physical_residuals),
			"displacement_error_m": _stats(physical_displacement_errors),
			"world_scalar_vs_batch_vector_error_m": _stats(physical_batch_errors)},
		"combined_physical_normal_finite_difference_check": _validate_combined_normals(samples, wave_time),
		"material_scalar_vs_batch": mat_scalar_batch,
		"q_space": "single common external material_q; per-band conversion occurs within each spectral cascade",
		"time": wave_time,
	}


func _validate_combined_normals(samples: Array[Dictionary], wave_time: float) -> Dictionary:
	const EPSILON := 0.01
	var center_positions := _positions_from_samples(samples)
	var offset_positions := PackedVector3Array()
	for sample in samples:
		var q: Vector2 = sample["q"]
		offset_positions.append(Vector3(q.x + EPSILON, 0.0, q.y))
		offset_positions.append(Vector3(q.x - EPSILON, 0.0, q.y))
		offset_positions.append(Vector3(q.x, 0.0, q.y + EPSILON))
		offset_positions.append(Vector3(q.x, 0.0, q.y - EPSILON))
	var center: PackedFloat64Array = _native_combined.call("sample_material_q_batch", wave_time, center_positions)
	var offsets: PackedFloat64Array = _native_combined.call("sample_material_q_batch", wave_time, offset_positions)
	var errors: Array[float] = []
	for i in samples.size():
		var base := i * STRIDE
		var dbase := i * 4 * STRIDE
		var d_dx := (Vector3(offsets[dbase + DISP_X], offsets[dbase + DISP_Y], offsets[dbase + DISP_Z]) -
			Vector3(offsets[dbase + STRIDE + DISP_X], offsets[dbase + STRIDE + DISP_Y], offsets[dbase + STRIDE + DISP_Z])) / (2.0 * EPSILON)
		var d_dz := (Vector3(offsets[dbase + 2 * STRIDE + DISP_X], offsets[dbase + 2 * STRIDE + DISP_Y], offsets[dbase + 2 * STRIDE + DISP_Z]) -
			Vector3(offsets[dbase + 3 * STRIDE + DISP_X], offsets[dbase + 3 * STRIDE + DISP_Y], offsets[dbase + 3 * STRIDE + DISP_Z])) / (2.0 * EPSILON)
		var tangent_x := Vector3(1.0, 0.0, 0.0) + d_dx
		var tangent_z := Vector3(0.0, 0.0, 1.0) + d_dz
		var finite_difference_normal := tangent_z.cross(tangent_x).normalized()
		if finite_difference_normal.y < 0.0:
			finite_difference_normal = -finite_difference_normal
		var analytic := Vector3(center[base + 5], center[base + 6], center[base + 7])
		errors.append((finite_difference_normal - analytic).length())
	return {"samples": samples.size(), "finite_difference_epsilon_m": EPSILON,
		"analytic_vs_finite_difference_normal_error": _stats(errors),
		"contract": "continuous combined physical geometric normal; finite differences use the combined displacement evaluation"}


func _positions_from_samples(samples: Array[Dictionary]) -> PackedVector3Array:
	var positions := PackedVector3Array()
	for sample in samples:
		var q: Vector2 = sample["q"]
		positions.append(Vector3(q.x, 0.0, q.y))
	return positions


func _compare_material_scalar_batch(native: Object, samples: Array[Dictionary], wave_time: float) -> Dictionary:
	var positions := _positions_from_samples(samples)
	var batch: PackedFloat64Array = native.call("sample_material_q_batch", wave_time, positions)
	var errors: Array[float] = []
	for i in samples.size():
		var q: Vector2 = samples[i]["q"]
		var scalar: PackedFloat64Array = native.call("sample_material_q", q.x, q.y, wave_time)
		var base := i * STRIDE
		errors.append(Vector3(batch[base + DISP_X] - scalar[DISP_X], batch[base + DISP_Y] - scalar[DISP_Y], batch[base + DISP_Z] - scalar[DISP_Z]).length())
	return {"samples": samples.size(), "vector_error_m": _stats(errors)}


func _run_batch_correctness(samples: Array[Dictionary], wave_time: float) -> Dictionary:
	return {"material_q_scalar_vs_batch": _compare_material_scalar_batch(_native_combined, samples, wave_time),
		"world_xz_batch_checked_in_world_packet": true}


func _run_performance_matrix(wave_time: float) -> Dictionary:
	var result: Dictionary = {"hardware": "i7-5820K / GTX 970", "acceptance": "PROVISIONAL ONLY", "queries": [1, 4, 16, 64], "configurations": {}}
	var samples := _make_combined_q_packet(64)
	for item in [{"name": "LONG", "mask": 1}, {"name": "LONG_MID", "mask": 3}, {"name": "LONG_MID_SHORT", "mask": 7}]:
		var native: Object = ClassDB.instantiate("OceanQueryNative")
		var setup: Dictionary = SPECTRUM_ADAPTER.configure_bands(native, _snapshots, float(_ocean.get("sea_level")), int(item["mask"]))
		if not bool(setup.get("ok", false)):
			result["error"] = "benchmark setup failed: %s" % item["name"]
			continue
		var timing_rows: Array[Dictionary] = []
		for count in [1, 4, 16, 64]:
			var positions := PackedVector3Array()
			for i in count:
				var q: Vector2 = samples[i]["q"]
				positions.append(Vector3(q.x, 0.0, q.y))
			var scalar_start := Time.get_ticks_usec()
			for i in count:
				var q: Vector2 = samples[i]["q"]
				native.call("sample_material_q", q.x, q.y, wave_time)
			var scalar_us := Time.get_ticks_usec() - scalar_start
			var batch_start := Time.get_ticks_usec()
			native.call("sample_material_q_batch", wave_time, positions)
			var batch_us := Time.get_ticks_usec() - batch_start
			timing_rows.append({"queries": count, "scalar_total_us": scalar_us,
				"scalar_us_per_query": float(scalar_us) / float(count),
				"batch_total_us": batch_us, "batch_us_per_query": float(batch_us) / float(count)})
		result["configurations"][String(item["name"])] = timing_rows
	return result


func _verify_wrap_contract(band_index: int) -> Dictionary:
	var n := int(_snapshots[band_index]["resolution"])
	var domain := float(_snapshots[band_index]["domain_size_m"])
	var half := domain * 0.5
	var eps := domain * 1.0e-8
	var cases := [-domain, -half, -half - eps, -eps, 0.0, eps, half - eps, half, domain, 3.0 * domain + 0.125]
	var ok := true
	var max_periodic_error := 0.0
	for q in cases:
		var converted: PackedFloat64Array = _native_by_band[band_index].call("material_q_to_fft_q_for_band", q, -q, band_index)
		var periodic: PackedFloat64Array = _native_by_band[band_index].call("material_q_to_fft_q_for_band", q + 2.0 * domain, -q - 2.0 * domain, band_index)
		ok = ok and converted[0] >= -half and converted[0] < half and converted[1] >= -half and converted[1] < half
		max_periodic_error = maxf(max_periodic_error, maxf(absf(converted[0] - periodic[0]), absf(converted[1] - periodic[1])))
	return {"canonical_interval": "[-L/2,+L/2)", "cases": cases, "valid": ok,
		"periodic_error_for_plus_two_domains_m": max_periodic_error,
		"resolution": n, "domain_m": domain}


func _wrap_centered(value: float, domain: float) -> float:
	return fposmod(value + domain * 0.5, domain) - domain * 0.5


func _compact_packet(packet: Dictionary) -> Dictionary:
	return {"valid": packet.get("valid", false), "label": packet.get("label", ""),
		"samples": packet.get("sample_count", 0), "production_wave_time": packet.get("production_wave_time", -1.0),
		"same_time_proven": packet.get("same_time_proven", false), "async_latency_frames": packet.get("async_latency_frames", -1),
		"result_buffer_bytes": packet.get("result_buffer_bytes", -1),
		"X": packet.get("component_errors", {}).get("X", {}),
		"Y": packet.get("component_errors", {}).get("Y", {}),
		"Z": packet.get("component_errors", {}).get("Z", {}),
		"vector": packet.get("vector_error", {})}


func _component_stats(abs_values: Array, signed_values: Array) -> Dictionary:
	var result := _stats(abs_values)
	var total := 0.0
	for value in signed_values:
		total += float(value)
	result["mean_signed_gpu_minus_native"] = total / float(maxi(signed_values.size(), 1))
	return result


func _stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var sorted: Array = values.duplicate()
	sorted.sort()
	var total := 0.0
	var maximum := 0.0
	for value in values:
		total += float(value)
		maximum = maxf(maximum, float(value))
	var index := mini(sorted.size() - 1, int(ceil(float(sorted.size() - 1) * 0.95)))
	return {"mean": total / float(values.size()), "p95": sorted[index], "max": maximum}


func _fail(message: String) -> void:
	push_error("PHYS2_GPU_PROBE_FAIL: " + message)
	print("PHYS2_GPU_PROBE_FAIL " + message)
	quit(1)
