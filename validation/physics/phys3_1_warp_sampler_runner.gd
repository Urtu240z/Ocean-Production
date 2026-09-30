extends SceneTree
## Focused PHYS-3.1 diagnostic: GPU hardware filtering, texelFetch/manual GPU
## filtering, and CPU bake-array sampling. No native queries or texture readback.

const OCEAN_SCENE: PackedScene = preload("res://addons/ocean/ocean.tscn")
const BAKE: Resource = preload("res://validation/p4_paradise/coastal_bake.tres")
const PROBE_SCRIPT = preload("res://validation/physics/phys3_1_sampler_probe.gd")
const SCAN_SHADER_PATH := "res://validation/physics/phys3_1_sampler_scan.glsl"
const DETAIL_SHADER_PATH := "res://validation/physics/phys3_1_sampler_detail.glsl"
const SCAN_COUNT := 8192
const SCAN_VECS := 2
const DETAIL_VECS := 22

signal _packet_done
signal _probe_init_done
signal _formats_done

var _ocean: Node
var _fft: Node
var _snapshot: Dictionary
var _probe: RefCounted
var _next_id := 0
var _completed: Dictionary = {}
var _report: Dictionary = {}
var _probe_ready := false
var _probe_init_error := ""
var _texture_format_data: Dictionary = {}
var _formats_ready := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("PHYS31_STAGE ocean_create")
	_ocean = OCEAN_SCENE.instantiate()
	_ocean.set("long_enabled", true)
	_ocean.set("mid_enabled", true)
	_ocean.set("short_enabled", true)
	_ocean.set("coastal_bake", BAKE)
	_ocean.set("coastal", true)
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
	for _i in 8: await RenderingServer.frame_post_draw
	print("PHYS31_STAGE ocean_ready")
	_fft = _ocean.get_node_or_null("OpenOceanFFT")
	if _fft == null:
		_finish_error("OpenOceanFFT missing")
		return
	_snapshot = _fft.call("get_phys3_coastal_snapshot")
	print("PHYS31_STAGE snapshot_ready")
	if _snapshot.is_empty() or not bool(_snapshot.get("active", false)):
		_finish_error("No active Coastal CPU snapshot")
		return
	var data: Dictionary = _fft.get("_coastal_data")
	var field_texture := data.get("field") as Texture2D
	var warp_texture := data.get("warp") as Texture2D
	if field_texture == null or warp_texture == null:
		_finish_error("Active Coastal GPU texture references missing")
		return
	var field_rid := RenderingServer.texture_get_rd_texture(field_texture.get_rid(), false)
	var warp_rid := RenderingServer.texture_get_rd_texture(warp_texture.get_rid(), false)
	print("PHYS31_STAGE texture_rids", field_rid.is_valid(), warp_rid.is_valid())
	var scan_file := load(SCAN_SHADER_PATH) as RDShaderFile
	var detail_file := load(DETAIL_SHADER_PATH) as RDShaderFile
	print("PHYS31_STAGE shader_resources", scan_file != null, detail_file != null)
	if scan_file == null or detail_file == null:
		_finish_error("PHYS-3.1 compute shader import unavailable")
		return
	_probe = PROBE_SCRIPT.new()
	_probe.connect("completed", _on_sampler_probe_completed)
	_probe.connect("initialized", _on_sampler_probe_initialized)
	_probe.connect("texture_formats", _on_sampler_texture_formats)
	var coastal_textures: Array[RID] = [field_rid, warp_rid]
	print("PHYS31_STAGE initialize_schedule")
	RenderingServer.call_on_render_thread(func():
		print("PHYS31_STAGE render_thread_callable")
		_probe.initialize(self, coastal_textures, scan_file, detail_file))
	while not _probe_ready: await process_frame
	print("PHYS31_STAGE probe_ready")
	if not _probe_init_error.is_empty():
		_finish_error(_probe_init_error)
		return
	RenderingServer.call_on_render_thread(_probe.request_texture_formats)
	while not _formats_ready: await process_frame
	print("PHYS31_STAGE formats_ready")
	_report["texture_contract"] = _texture_contract(field_texture, warp_texture)
	var scan_samples := _make_scan_samples()
	print("PHYS31_STAGE scan_dispatch count=%d" % scan_samples.size())
	var scan_response := await _dispatch(scan_samples, false)
	print("PHYS31_STAGE scan_readback")
	if not bool(scan_response.get("ok", false)):
		_finish_error(str(scan_response.get("error", "scan failed")))
		return
	var scan := _scan_result(scan_samples, scan_response["bytes"])
	print("PHYS31_STAGE scan_analyzed")
	var worst_r: Array[Dictionary] = scan["worst_r"]
	var worst_g: Array[Dictionary] = scan["worst_g"]
	var lattice_g: Array[Dictionary] = scan["lattice_g"]
	var lattice_r: Array[Dictionary] = scan["lattice_r"]
	_report["scan"] = {"samples": scan_samples.size(), "field": scan["field_stats"], "warp": scan["warp_stats"],
		"original_64_lattice_packet": {"samples": 64, "warp": scan["lattice_warp_stats"],
			"worst_r": _public_top(scan["lattice_r"]), "worst_g": _public_top(scan["lattice_g"])},
		"top_warp_r": _public_top(worst_r), "top_warp_g": _public_top(worst_g),
		"distribution": _distribution(worst_g, warp_texture.get_width(), warp_texture.get_height())}
	var detailed_samples := _union_samples(worst_r, worst_g)
	detailed_samples = _union_samples(detailed_samples, lattice_g)
	detailed_samples = _union_samples(detailed_samples, lattice_r)
	detailed_samples.append_array(_edge_samples(warp_texture.get_width(), warp_texture.get_height()))
	print("PHYS31_STAGE detail_dispatch count=%d" % detailed_samples.size())
	var detail := await _dispatch(detailed_samples, true)
	print("PHYS31_STAGE detail_readback")
	if not bool(detail.get("ok", false)):
		_finish_error(str(detail.get("error", "detail probe failed")))
		return
	_report["details"] = _build_details(detailed_samples, detail["bytes"], warp_texture.get_width(), warp_texture.get_height())
	print("PHYS31_STAGE report_ready")
	_report["generation"] = _generation_contract(data, field_texture, warp_texture)
	_report["float32"] = _float_precision()
	_report["status"] = "PHYS-3.1-DIAGNOSED"
	print("PHYS31_WARP_REPORT ", JSON.stringify(_report, "\t"))
	var report_path := OS.get_environment("TEMP").path_join("PHYS-3.1-RECHECK.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(_report, "\t"))
		report_file.close()
	print("PHYS31_WARP_COMPLETE")
	RenderingServer.call_on_render_thread(_probe.shutdown)
	quit(0)


func _texture_contract(field: Texture2D, warp: Texture2D) -> Dictionary:
	return {"cpu_field_resolution": _snapshot["field_resolution"], "cpu_warp_resolution": _snapshot["warp_resolution"],
		"resource_field_dimensions": Vector2i(field.get_width(), field.get_height()),
		"resource_warp_dimensions": Vector2i(warp.get_width(), warp.get_height()),
		"gpu_field_format": _texture_format_data.get("field"), "gpu_warp_format": _texture_format_data.get("warp"),
		"field_uv": "(material_q-field_origin)/field_extent", "warp_uv": "(material_q-warp_origin)/warp_extent",
		"field_origin": _snapshot["field_origin"], "field_extent": _snapshot["field_extent"],
		"warp_origin": _snapshot["warp_origin"], "warp_extent": _snapshot["warp_extent"],
		"field_cell_spacing": Vector2(_snapshot["field_extent"]) / Vector2(Vector2i(_snapshot["field_resolution"]) - Vector2i.ONE),
		"warp_cell_spacing": Vector2(_snapshot["warp_extent"]) / Vector2(Vector2i(_snapshot["warp_resolution"]) - Vector2i.ONE),
		"global_rd": true, "full_texture_readback": false}


func _generation_contract(data: Dictionary, field: Texture2D, warp: Texture2D) -> Dictionary:
	var runtime: Object = _fft.get("_coastal_runtime")
	var state: Dictionary = runtime.call("get_runtime_state")
	var bake: Resource = _ocean.get("coastal_bake")
	var propagation: Resource = bake.get("propagation")
	var warp_resource: Resource = bake.get("warp")
	return {"bake_instance_id": bake.get_instance_id(), "propagation_instance_id": propagation.get_instance_id(),
		"warp_resource_instance_id": warp_resource.get_instance_id(), "runtime_generation": state.get("generation"),
		"snapshot_generation": _snapshot.get("generation"), "generation_matches": state.get("generation") == _snapshot.get("generation"),
		"active_bake_instance_id": state.get("active_bake_instance_id"),
		"resident_bake_instance_id": state.get("resident_bake_instance_id"),
		"field_texture_instance_id": field.get_instance_id(), "warp_texture_instance_id": warp.get_instance_id(),
		"field_rid": RenderingServer.texture_get_rd_texture(field.get_rid(), false).get_id(),
		"warp_rid": RenderingServer.texture_get_rd_texture(warp.get_rid(), false).get_id(),
		"build_count": state.get("build_count"), "cache_dirty": state.get("cache_dirty"),
		"textures_and_arrays_from_active_runtime_cache": bool(state.get("active", false)) and not bool(state.get("cache_dirty", true))}


func _make_scan_samples() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x31C0A57
	for y in 64:
		for x in 128:
			var uv := Vector2((float(x) + rng.randf()) / 128.0, (float(y) + rng.randf()) / 64.0)
			result.append(_sample_for_uv(uv, "scan_%d" % result.size()))
	# Re-include the 64 deterministic PHYS-3 texel probes to retain the known outlier family.
	var size := Vector2i(_snapshot["warp_resolution"])
	var origin := Vector2(_snapshot["warp_origin"])
	var extent := Vector2(_snapshot["warp_extent"])
	for candidate in 64:
		var ix := 1 + posmod(candidate * 37 + 11, size.x - 2)
		var iy := 1 + posmod(candidate * 53 + 17, size.y - 2)
		var q := origin + Vector2((float(ix) + 0.5) / float(size.x) * extent.x,
			(float(iy) + 0.5) / float(size.y) * extent.y)
		result.append(_sample_for_q(q, "phys3_lattice_%d" % candidate))
	return result


func _edge_samples(width: int, height: int) -> Array[Dictionary]:
	var uv_tests := [
		["u_below_zero", Vector2(-0.0001, 0.5)], ["u_zero", Vector2(0.0, 0.5)],
		["u_epsilon", Vector2(0.0001, 0.5)], ["u_half_texel", Vector2(0.5 / width, 0.5)],
		["u_one_minus_half_texel", Vector2(1.0 - 0.5 / width, 0.5)],
		["u_one_minus_epsilon", Vector2(0.9999, 0.5)], ["u_one", Vector2(1.0, 0.5)],
		["u_above_one", Vector2(1.0001, 0.5)],
		["v_below_zero", Vector2(0.5, -0.0001)], ["v_zero", Vector2(0.5, 0.0)],
		["v_epsilon", Vector2(0.5, 0.0001)], ["v_half_texel", Vector2(0.5, 0.5 / height)],
		["v_one_minus_half_texel", Vector2(0.5, 1.0 - 0.5 / height)],
		["v_one_minus_epsilon", Vector2(0.5, 0.9999)], ["v_one", Vector2(0.5, 1.0)],
		["v_above_one", Vector2(0.5, 1.0001)],
	]
	var out: Array[Dictionary] = []
	for test in uv_tests:
		var sample := _sample_for_uv(test[1], String(test[0]))
		sample["edge_test"] = String(test[0])
		out.append(sample)
	return out


func _sample_for_q(q: Vector2, label: String) -> Dictionary:
	var field_uv := (q - Vector2(_snapshot["field_origin"])) / Vector2(_snapshot["field_extent"])
	var warp_uv := (q - Vector2(_snapshot["warp_origin"])) / Vector2(_snapshot["warp_extent"])
	return {"label": label, "q": q, "field_uv": field_uv, "warp_uv": warp_uv}


func _sample_for_uv(uv: Vector2, label: String) -> Dictionary:
	var q := Vector2(_snapshot["warp_origin"]) + uv * Vector2(_snapshot["warp_extent"])
	return {"label": label, "q": q, "field_uv": uv, "warp_uv": uv}


func _dispatch(samples: Array[Dictionary], detail: bool) -> Dictionary:
	var coords := PackedFloat32Array()
	for sample in samples:
		var f: Vector2 = sample["field_uv"]
		var w: Vector2 = sample["warp_uv"]
		coords.append_array(PackedFloat32Array([f.x, f.y, w.x, w.y]))
	_next_id += 1
	var request := {"id": _next_id, "sample_count": samples.size(), "samples": samples, "detail": detail}
	RenderingServer.call_on_render_thread(_probe.dispatch.bind(request, coords, detail))
	while not _completed.has(_next_id): await _packet_done
	var response: Dictionary = _completed[_next_id]
	_completed.erase(_next_id)
	return response


func _on_sampler_probe_completed(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	_completed[int(request["id"])] = {"ok": error.is_empty(), "bytes": bytes, "error": error}
	_packet_done.emit()


func _on_sampler_probe_initialized(ok: bool, error: String) -> void:
	_probe_ready = true
	_probe_init_error = "" if ok else error
	_probe_init_done.emit()


func _on_sampler_texture_formats(field: Dictionary, warp: Dictionary) -> void:
	_texture_format_data = {"field": field, "warp": warp}
	_formats_ready = true
	_formats_done.emit()


func _scan_result(samples: Array[Dictionary], bytes: PackedByteArray) -> Dictionary:
	var field_errors: Array = [[], [], [], []]
	var warp_errors: Array = [[], [], [], []]
	var lattice_warp_errors: Array = [[], [], [], []]
	var all_records: Array[Dictionary] = []
	var warp_size := Vector2i(_snapshot["warp_resolution"])
	for i in samples.size():
		var field_gpu := _read_vec4(bytes, i * 32)
		var warp_gpu := _read_vec4(bytes, i * 32 + 16)
		var field_cpu := _cpu_sample_field(samples[i]["field_uv"])
		var warp_cpu := _cpu_sample_warp(samples[i]["warp_uv"])
		var error_r := absf(warp_gpu.x - warp_cpu.x)
		var error_g := absf(warp_gpu.y - warp_cpu.y)
		var record := {"label": samples[i]["label"], "q": samples[i]["q"], "field_uv": samples[i]["field_uv"],
			"warp_uv": samples[i]["warp_uv"], "gpu": warp_gpu, "cpu": warp_cpu,
			"error_r": error_r, "error_g": error_g, "error_all": _max_error(warp_gpu, warp_cpu)}
		all_records.append(record)
		for c in 4:
			field_errors[c].append(absf(field_gpu[c] - field_cpu[c]))
			warp_errors[c].append(absf(warp_gpu[c] - warp_cpu[c]))
			if String(samples[i]["label"]).begins_with("phys3_lattice_"):
				lattice_warp_errors[c].append(absf(warp_gpu[c] - warp_cpu[c]))
	var top_r := all_records.duplicate()
	var top_g := all_records.duplicate()
	top_r.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["error_r"]) > float(b["error_r"]))
	top_g.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["error_g"]) > float(b["error_g"]))
	var lattice := all_records.filter(func(a: Dictionary) -> bool: return String(a["label"]).begins_with("phys3_lattice_"))
	var lattice_r := lattice.duplicate()
	var lattice_g := lattice.duplicate()
	lattice_r.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["error_r"]) > float(b["error_r"]))
	lattice_g.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["error_g"]) > float(b["error_g"]))
	if top_r.size() > 16: top_r.resize(16)
	if top_g.size() > 16: top_g.resize(16)
	if lattice_r.size() > 16: lattice_r.resize(16)
	if lattice_g.size() > 16: lattice_g.resize(16)
	for record in top_r + top_g + lattice_r + lattice_g:
		record["region"] = _classify_uv(record["warp_uv"], warp_size, _cpu_mask_neighbors(record["warp_uv"]))
	return {"field_stats": _stats_channels(field_errors), "warp_stats": _stats_channels(warp_errors),
		"lattice_warp_stats": _stats_channels(lattice_warp_errors),
		"worst_r": top_r, "worst_g": top_g, "lattice_r": lattice_r, "lattice_g": lattice_g}


func _build_details(samples: Array[Dictionary], bytes: PackedByteArray, _width: int, _height: int) -> Dictionary:
	var rows: Array[Dictionary] = []
	var raw_errors: Array = [[], [], [], []]
	var field_raw_errors: Array = [[], [], [], []]
	var exact_raw_mismatches := [0, 0, 0, 0]
	var exact_field_raw_mismatches := [0, 0, 0, 0]
	var compare_errors := {"warp_hardware_vs_gpu_manual": [], "warp_gpu_manual_vs_cpu_manual": [],
		"warp_hardware_vs_cpu_manual": [], "field_hardware_vs_gpu_manual": [],
		"field_gpu_manual_vs_cpu_manual": [], "field_hardware_vs_cpu_manual": [],
		"warp_alternative_mapping_vs_hardware": [], "field_alternative_mapping_vs_hardware": [],
		"warp_nearest_1_256_vs_hardware": [], "warp_truncated_1_256_vs_hardware": []}
	for i in samples.size():
		var base := i * DETAIL_VECS * 16
		var sample: Dictionary = samples[i]
		var field_detail := _decode_detail(bytes, base, true, sample["field_uv"], _snapshot["field_resolution"], sample["q"])
		var warp_detail := _decode_detail(bytes, base, false, sample["warp_uv"], _snapshot["warp_resolution"], sample["q"])
		for channel in 4:
			for texel in 4:
				var gpu_raw: Vector4 = warp_detail["gpu_texels"][texel]
				var cpu_raw := _cpu_raw_warp(warp_detail["gpu_indices"][texel])
				var difference := absf(gpu_raw[channel] - cpu_raw[channel])
				raw_errors[channel].append(difference)
				if difference != 0.0: exact_raw_mismatches[channel] += 1
				var gpu_field_raw: Vector4 = field_detail["gpu_texels"][texel]
				var cpu_field_raw := _cpu_raw_field(field_detail["gpu_indices"][texel])
				var field_difference := absf(gpu_field_raw[channel] - cpu_field_raw[channel])
				field_raw_errors[channel].append(field_difference)
				if field_difference != 0.0: exact_field_raw_mismatches[channel] += 1
		for key in compare_errors.keys():
			var d: Dictionary = warp_detail if key.begins_with("warp") else field_detail
			if key.contains("hardware_vs_gpu_manual"):
				compare_errors[key].append(_max_error(d["gpu_hardware"], d["gpu_manual"]))
			elif key.contains("gpu_manual_vs_cpu_manual"):
				compare_errors[key].append(_max_error(d["gpu_manual"], d["cpu_manual"]))
			elif key.contains("hardware_vs_cpu_manual"):
				compare_errors[key].append(_max_error(d["gpu_hardware"], d["cpu_manual"]))
			elif key.contains("alternative_mapping"):
				compare_errors[key].append(_max_error(d["gpu_hardware"], d["gpu_alt_manual"]))
			elif key.contains("nearest_1_256"):
				compare_errors[key].append(_max_error(d["gpu_hardware"], d["gpu_round_256_manual"]))
			elif key.contains("truncated_1_256"):
				compare_errors[key].append(_max_error(d["gpu_hardware"], d["gpu_trunc_256_manual"]))
		rows.append({"label": sample["label"], "edge_test": sample.get("edge_test", ""),
			"classification": warp_detail["classification"], "warp": warp_detail, "field": field_detail})
	return {"samples": rows.size(), "rows": rows, "raw_warp_texel_abs_error": _stats_channels(raw_errors),
		"raw_warp_texel_mismatch_count": exact_raw_mismatches,
		"raw_field_texel_abs_error": _stats_channels(field_raw_errors), "raw_field_texel_mismatch_count": exact_field_raw_mismatches,
		"filter_comparison": _stats_dict(compare_errors),
		"top_warp_g_traces": _trace_for_top(rows, "error_g"),
		"top_warp_r_traces": _trace_for_top(rows, "error_r"),
		"original_64_lattice_top_warp_g_traces": _trace_for_top(rows, "error_g", "phys3_lattice_"),
		"original_64_lattice_top_warp_r_traces": _trace_for_top(rows, "error_r", "phys3_lattice_"),
		"edge_tests": rows.filter(func(row: Dictionary) -> bool: return not String(row["edge_test"]).is_empty())}


func _decode_detail(bytes: PackedByteArray, base: int, field: bool, uv: Vector2, resolution: Vector2i, q: Vector2) -> Dictionary:
	var at := 0 if field else 9
	var hardware := _read_vec4(bytes, base + at * 16)
	var meta0 := _read_vec4(bytes, base + (at + 1) * 16)
	var meta1 := _read_vec4(bytes, base + (at + 2) * 16)
	var weights := _read_vec4(bytes, base + (at + 3) * 16)
	var texels: Array[Vector4] = []
	for k in 4: texels.append(_read_vec4(bytes, base + (at + 4 + k) * 16))
	var gpu_manual := _read_vec4(bytes, base + (at + 8) * 16)
	var alt_manual := _read_vec4(bytes, base + (18 if field else 19) * 16)
	var round_256 := _read_vec4(bytes, base + 20 * 16)
	var trunc_256 := _read_vec4(bytes, base + 21 * 16)
	var gpu_indices := [Vector2i(int(meta1.x), int(meta1.y)), Vector2i(int(meta1.z), int(meta1.y)),
		Vector2i(int(meta1.x), int(meta1.w)), Vector2i(int(meta1.z), int(meta1.w))]
	var indices := _indices_for_uv(uv, resolution, false)
	var cpu_texels: Array[Vector4] = []
	for index in indices:
		cpu_texels.append(_cpu_raw_field(index) if field else _cpu_raw_warp(index))
	var gpu_cpu_texels: Array[Vector4] = []
	for index in gpu_indices:
		gpu_cpu_texels.append(_cpu_raw_field(index) if field else _cpu_raw_warp(index))
	var cpu_weights := _weights_for_uv(uv, resolution, false)
	var cpu_manual := _bilinear_cpu(cpu_texels, cpu_weights.x, cpu_weights.y)
	var cpu_alt_indices := _indices_for_uv(uv, resolution, true)
	var cpu_alt_texels: Array[Vector4] = []
	for index in cpu_alt_indices:
		cpu_alt_texels.append(_cpu_raw_field(index) if field else _cpu_raw_warp(index))
	var cpu_alt_weights := _weights_for_uv(uv, resolution, true)
	var cpu_alt_manual := _bilinear_cpu(cpu_alt_texels, cpu_alt_weights.x, cpu_alt_weights.y)
	var q_raw := uv * Vector2(resolution) - Vector2(0.5, 0.5)
	var clamped := Vector2(clampf(q_raw.x, 0.0, float(resolution.x - 1)), clampf(q_raw.y, 0.0, float(resolution.y - 1)))
	return {"material_q": q, "uv_raw": uv, "uv_clamped": Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0)),
		"resolution": resolution, "texel_coordinate": q_raw, "shader_texel_coordinate": Vector2(meta0.z, meta0.w),
		"clamped_texel_coordinate": clamped, "x0_x1_y0_y1": [int(meta1.x), int(meta1.z), int(meta1.y), int(meta1.w)],
		"shader_indices": meta1, "fx_fy": Vector2(weights.x, weights.y), "gpu_hardware": hardware,
		"indices": indices, "gpu_indices": gpu_indices, "gpu_texels": texels, "cpu_texels": cpu_texels,
		"cpu_texels_at_gpu_indices": gpu_cpu_texels, "gpu_manual": gpu_manual, "cpu_manual": cpu_manual,
		"cpu_alt_manual": cpu_alt_manual, "gpu_alt_manual": alt_manual,
		"gpu_round_256_manual": round_256, "gpu_trunc_256_manual": trunc_256,
		"classification": _classify_uv(uv, resolution, _cpu_mask_neighbors(uv) if not field else Vector2(-1, -1))}


func _cpu_sample_field(uv: Vector2) -> Vector4:
	var size := Vector2i(_snapshot["field_resolution"])
	var ids := _indices_for_uv(uv, size, false)
	var weights := _weights_for_uv(uv, size, false)
	var phases: PackedFloat32Array = _snapshot["phase_offset"]
	var shoaling: PackedFloat32Array = _snapshot["shoaling"]
	var local_k: PackedFloat32Array = _snapshot["local_k"]
	var mask: PackedByteArray = _snapshot["field_valid"]
	return Vector4(_interpolate(phases, size.x, ids, weights), _interpolate(shoaling, size.x, ids, weights),
		_interpolate(local_k, size.x, ids, weights), _interpolate_byte_mask(mask, size.x, ids, weights))


func _cpu_sample_warp(uv: Vector2) -> Vector4:
	var size := Vector2i(_snapshot["warp_resolution"])
	var ids := _indices_for_uv(uv, size, false)
	var weights := _weights_for_uv(uv, size, false)
	return Vector4(_interpolate(_snapshot["warp_x"], size.x, ids, weights), _interpolate(_snapshot["warp_z"], size.x, ids, weights),
		_interpolate(_snapshot["warp_det_j"], size.x, ids, weights), _interpolate_byte_mask(_snapshot["warp_valid"], size.x, ids, weights))


func _interpolate(values: PackedFloat32Array, width: int, ids: Array[Vector2i], weights: Vector2) -> float:
	var a := values[int(ids[0].y) * width + int(ids[0].x)]
	var b := values[int(ids[1].y) * width + int(ids[1].x)]
	var c := values[int(ids[2].y) * width + int(ids[2].x)]
	var d := values[int(ids[3].y) * width + int(ids[3].x)]
	return lerpf(lerpf(a, b, weights.x), lerpf(c, d, weights.x), weights.y)


func _interpolate_byte_mask(values: PackedByteArray, width: int, ids: Array[Vector2i], weights: Vector2) -> float:
	var a := 1.0 if values[int(ids[0].y) * width + int(ids[0].x)] != 0 else 0.0
	var b := 1.0 if values[int(ids[1].y) * width + int(ids[1].x)] != 0 else 0.0
	var c := 1.0 if values[int(ids[2].y) * width + int(ids[2].x)] != 0 else 0.0
	var d := 1.0 if values[int(ids[3].y) * width + int(ids[3].x)] != 0 else 0.0
	return lerpf(lerpf(a, b, weights.x), lerpf(c, d, weights.x), weights.y)


func _cpu_linear(values: PackedFloat32Array, size: Vector2i, uv: Vector2) -> float:
	var ids := _indices_for_uv(uv, size, false)
	var a := values[int(ids[0].y) * size.x + int(ids[0].x)]
	var b := values[int(ids[1].y) * size.x + int(ids[1].x)]
	var c := values[int(ids[2].y) * size.x + int(ids[2].x)]
	var d := values[int(ids[3].y) * size.x + int(ids[3].x)]
	var weights := _weights_for_uv(uv, size, false)
	return lerpf(lerpf(a, b, weights.x), lerpf(c, d, weights.x), weights.y)


func _cpu_linear_bytes(values: PackedByteArray, size: Vector2i, uv: Vector2) -> float:
	var ids := _indices_for_uv(uv, size, false)
	var vals: Array[float] = []
	for p in ids: vals.append(1.0 if values[int(p.y) * size.x + int(p.x)] != 0 else 0.0)
	var w := _weights_for_uv(uv, size, false)
	return lerpf(lerpf(vals[0], vals[1], w.x), lerpf(vals[2], vals[3], w.x), w.y)


func _cpu_raw_warp(index: Vector2) -> Vector4:
	var width := int(Vector2i(_snapshot["warp_resolution"]).x)
	var i := int(index.y) * width + int(index.x)
	return Vector4(_snapshot["warp_x"][i], _snapshot["warp_z"][i], _snapshot["warp_det_j"][i],
		1.0 if _snapshot["warp_valid"][i] != 0 else 0.0)


func _cpu_raw_field(index: Vector2) -> Vector4:
	var width := int(Vector2i(_snapshot["field_resolution"]).x)
	var i := int(index.y) * width + int(index.x)
	return Vector4(_snapshot["phase_offset"][i], _snapshot["shoaling"][i], _snapshot["local_k"][i],
		1.0 if _snapshot["field_valid"][i] != 0 else 0.0)


func _cpu_rgba(values: PackedFloat32Array, width: int, x: int, y: int) -> Vector4:
	var i := (y * width + x) * 4
	return Vector4(values[i], values[i + 1], values[i + 2], values[i + 3])


func _indices_for_uv(uv: Vector2, size: Vector2i, alternate: bool) -> Array[Vector2i]:
	var tc := uv * Vector2(size - Vector2i.ONE) if alternate else uv * Vector2(size) - Vector2(0.5, 0.5)
	tc = Vector2(clampf(tc.x, 0.0, float(size.x - 1)), clampf(tc.y, 0.0, float(size.y - 1)))
	var x0 := floori(tc.x); var y0 := floori(tc.y)
	var x1 := mini(x0 + 1, size.x - 1); var y1 := mini(y0 + 1, size.y - 1)
	return [Vector2i(x0, y0), Vector2i(x1, y0), Vector2i(x0, y1), Vector2i(x1, y1)]


func _weights_for_uv(uv: Vector2, size: Vector2i, alternate: bool) -> Vector2:
	var tc := uv * Vector2(size - Vector2i.ONE) if alternate else uv * Vector2(size) - Vector2(0.5, 0.5)
	tc = Vector2(clampf(tc.x, 0.0, float(size.x - 1)), clampf(tc.y, 0.0, float(size.y - 1)))
	return Vector2(tc.x - floorf(tc.x), tc.y - floorf(tc.y))


func _bilinear_cpu(v: Array[Vector4], fx: float, fy: float) -> Vector4:
	return v[0].lerp(v[1], fx).lerp(v[2].lerp(v[3], fx), fy)


func _cpu_mask_neighbors(uv: Vector2) -> Vector2:
	var size := Vector2i(_snapshot["warp_resolution"])
	var ids := _indices_for_uv(uv, size, false)
	var mask: PackedByteArray = _snapshot["warp_valid"]
	var lo := 1.0; var hi := 0.0
	for p in ids:
		var v := 1.0 if mask[int(p.y) * size.x + int(p.x)] != 0 else 0.0
		lo = minf(lo, v); hi = maxf(hi, v)
	return Vector2(lo, hi)


func _classify_uv(uv: Vector2, size: Vector2i, mask_range: Vector2) -> String:
	var horizontal := ""
	var vertical := ""
	if uv.x < 0.5 / size.x or uv.x < 2.0 / size.x: horizontal = "near U=0"
	elif uv.x > 1.0 - 2.0 / size.x: horizontal = "near U=1"
	if uv.y < 0.5 / size.y or uv.y < 2.0 / size.y: vertical = "near V=0"
	elif uv.y > 1.0 - 2.0 / size.y: vertical = "near V=1"
	if not horizontal.is_empty() and not vertical.is_empty(): return "corner %s/%s" % [horizontal, vertical]
	if mask_range.x >= 0.0 and mask_range.x < mask_range.y: return "mask transition (invalid/valid)"
	if not horizontal.is_empty(): return horizontal
	if not vertical.is_empty(): return vertical
	return "interior"


func _read_vec4(bytes: PackedByteArray, offset: int) -> Vector4:
	return Vector4(bytes.decode_float(offset), bytes.decode_float(offset + 4), bytes.decode_float(offset + 8), bytes.decode_float(offset + 12))


func _push_top(top: Array[Dictionary], item: Dictionary, key: String) -> void:
	top.append(item)
	top.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a[key]) > float(b[key]))
	if top.size() > 16: top.resize(16)


func _public_top(rows: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row in rows:
		out.append({"label": row["label"], "material_q": row["q"], "field_uv": row["field_uv"], "warp_uv": row["warp_uv"],
			"gpu_warp_rgba": row["gpu"], "cpu_warp_rgba": row["cpu"],
			"abs_error_rgba": Vector4(row["error_r"], row["error_g"], absf(row["gpu"].z-row["cpu"].z), absf(row["gpu"].w-row["cpu"].w)),
			"region": row["region"]})
	return out


func _union_samples(a: Array[Dictionary], b: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var labels := {}
	for rows in [a, b]:
		for row in rows:
			if labels.has(row["label"]): continue
			labels[row["label"]] = true
			out.append(_sample_for_q(row["q"], row["label"]))
	return out


func _stats_channels(channels: Array) -> Dictionary:
	var out := {}
	for c in 4: out[["R", "G", "B", "A"][c]] = _stats(channels[c])
	return out


func _stats_dict(channels: Dictionary) -> Dictionary:
	var out := {}
	for key in channels: out[key] = _stats(channels[key])
	return out


func _stats(values: Array) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var sorted := values.duplicate(); sorted.sort()
	var total := 0.0
	for value in values: total += float(value)
	return {"mean": total / values.size(), "p95": float(sorted[mini(sorted.size() - 1, int(ceil(sorted.size() * 0.95)) - 1)]), "max": float(sorted[-1])}


func _max_error(a: Vector4, b: Vector4) -> float:
	return maxf(maxf(absf(a.x-b.x), absf(a.y-b.y)), maxf(absf(a.z-b.z), absf(a.w-b.w)))


func _distribution(top: Array[Dictionary], width: int, height: int) -> Dictionary:
	var rows := {}; var columns := {}; var region_counts := {}
	for row in top:
		var uv: Vector2 = row["warp_uv"]
		var p := _indices_for_uv(uv, Vector2i(width, height), false)[0]
		var yk := str(p.y); var xk := str(p.x); var region := String(row["region"])
		rows[yk] = int(rows.get(yk, 0)) + 1; columns[xk] = int(columns.get(xk, 0)) + 1
		region_counts[region] = int(region_counts.get(region, 0)) + 1
	return {"worst_g_same_row_counts": rows, "worst_g_same_column_counts": columns, "worst_g_region_counts": region_counts}


func _trace_for_top(rows: Array[Dictionary], key: String, label_prefix: String = "") -> Array[Dictionary]:
	var matching: Array[Dictionary] = []
	for row in rows:
		var label := String(row["label"])
		if not label_prefix.is_empty() and not label.begins_with(label_prefix): continue
		if label.begins_with("u_") or label.begins_with("v_"): continue
		var d: Dictionary = row["warp"]
		var channel := 1 if key == "error_g" else 0
		d["label"] = row["label"]
		d["channel_error"] = absf(d["gpu_hardware"][channel] - d["cpu_manual"][channel])
		matching.append(d)
	matching.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["channel_error"]) > float(b["channel_error"]))
	if matching.size() > 16: matching.resize(16)
	return matching


func _float_precision() -> Dictionary:
	var max_abs := 0.0
	for channel in ["warp_x", "warp_z"]:
		for value in _snapshot[channel]: max_abs = maxf(max_abs, absf(float(value)))
	var exponent := floorf(log(maxf(max_abs, 1.0)) / log(2.0))
	var ulp := pow(2.0, exponent - 23.0)
	return {"max_abs_baked_warp_coordinate_m": max_abs, "estimated_float32_ulp_m_at_max": ulp,
		"observed_warp_g_max_residual_m": 0.012717, "residual_in_ulp": 0.012717 / ulp}


func _finish_error(message: String) -> void:
	_report["status"] = "PHYS-3.1-HARNESS-ERROR"
	_report["error"] = message
	print("PHYS31_WARP_REPORT ", JSON.stringify(_report, "\t"))
	print("PHYS31_WARP_COMPLETE")
	if _probe != null: RenderingServer.call_on_render_thread(_probe.shutdown)
	quit(1)
