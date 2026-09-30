extends SceneTree
## PHYS-3 validation-only Coastal/physical-query probe. It samples the actual
## Production FFT and cached Coastal ImageTextures with tiny async GPU packets.

const OCEAN_SCENE: PackedScene = preload("res://addons/ocean/ocean.tscn")
const COASTAL_BAKE: Resource = preload("res://validation/p4_paradise/coastal_bake.tres")
const SPECTRUM_ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const PROBE_SCRIPT = preload("res://validation/physics/phys3_coastal_probe.gd")
const SHADER_PATH := "res://validation/physics/phys3_coastal_probe.glsl"
const NATIVE_DESCRIPTOR := "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"
const STRIDE := 15
const DX := 2
const DY := 3
const DZ := 4
const REQUEST_RESULT_BYTES_PER_SAMPLE := 288

signal _packet_completed

var _ocean: Node
var _fft: Node
var _bake_snapshot: Dictionary
var _spectra: Array[Dictionary] = []
var _probe: RefCounted
var _native_open_long: Object
var _native_mid: Object
var _native_short: Object
var _probe_ready := false
var _probe_error := ""
var _request_id := 0
var _completed: Dictionary = {}
var _report: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	printerr("PHYS32_STAGE start")
	var descriptor: Resource = load(NATIVE_DESCRIPTOR)
	if descriptor == null or not ClassDB.class_exists("OceanQueryNative"):
		_fail("Native extension/class registration is unavailable.")
		return
	_ocean = OCEAN_SCENE.instantiate()
	_ocean.set("long_enabled", true)
	_ocean.set("mid_enabled", true)
	_ocean.set("short_enabled", true)
	_ocean.set("coastal_bake", COASTAL_BAKE)
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
	for _frame in 6:
		await RenderingServer.frame_post_draw
	_fft = _ocean.get_node_or_null("OpenOceanFFT")
	if _fft == null:
		_fail("OpenOceanFFT was not created.")
		return
	_spectra = _fft.call("get_phys2_band_spectrum_snapshots")
	_bake_snapshot = _fft.call("get_phys3_coastal_snapshot")
	if _spectra.size() != 3 or _bake_snapshot.is_empty():
		_fail("Production did not publish three spectra and an active CPU Coastal bake snapshot.")
		return
	var state: Dictionary = _fft.call("get_fft_resource_lifecycle_state")
	var cascade_state: Dictionary = _fft.call("get_cascade_runtime_state")
	var coastal_state: Dictionary = cascade_state.get("features", {}).get("coastal_waves", {})
	if not bool(_bake_snapshot.get("active", false)) or not bool(coastal_state.get("runtime_active", false)):
		_fail("Production Coastal textures are not active: %s" % coastal_state)
		return
	_report["source"] = _source_contract(state)

	var native_long: Object = ClassDB.instantiate("OceanQueryNative")
	var setup_long: Dictionary = SPECTRUM_ADAPTER.configure_bands(native_long, _spectra,
		float(_ocean.get("sea_level")), 1)
	var coast_long := SPECTRUM_ADAPTER.configure_coastal(native_long, _bake_snapshot)
	var native_combined: Object = ClassDB.instantiate("OceanQueryNative")
	var setup_all: Dictionary = SPECTRUM_ADAPTER.configure_bands(native_combined, _spectra,
		float(_ocean.get("sea_level")), 7)
	var coast_all := SPECTRUM_ADAPTER.configure_coastal(native_combined, _bake_snapshot)
	var native_open: Object = ClassDB.instantiate("OceanQueryNative")
	var setup_open: Dictionary = SPECTRUM_ADAPTER.configure_bands(native_open, _spectra,
		float(_ocean.get("sea_level")), 7)
	_native_open_long = ClassDB.instantiate("OceanQueryNative")
	var setup_open_long: Dictionary = SPECTRUM_ADAPTER.configure_bands(_native_open_long, _spectra,
		float(_ocean.get("sea_level")), 1)
	_native_mid = ClassDB.instantiate("OceanQueryNative")
	var setup_mid: Dictionary = SPECTRUM_ADAPTER.configure_bands(_native_mid, _spectra,
		float(_ocean.get("sea_level")), 2)
	_native_short = ClassDB.instantiate("OceanQueryNative")
	var setup_short: Dictionary = SPECTRUM_ADAPTER.configure_bands(_native_short, _spectra,
		float(_ocean.get("sea_level")), 4)
	if not bool(setup_long.get("ok", false)) or not bool(coast_long.get("ok", false)) \
			or not bool(setup_all.get("ok", false)) or not bool(coast_all.get("ok", false)) \
			or not bool(setup_open.get("ok", false)) or not bool(setup_open_long.get("ok", false)) \
			or not bool(setup_mid.get("ok", false)) or not bool(setup_short.get("ok", false)):
		_fail("Native spectrum/Coastal setup failed: %s / %s" % [coast_long, coast_all])
		return
	_report["native_setup"] = {"long": coast_long, "combined": coast_all, "open_fallback": setup_open}

	var source_textures := _get_probe_textures()
	if source_textures.size() != 5:
		_fail("Could not resolve three Production FFT and two Coastal texture RIDs.")
		return
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		_fail("Coastal probe shader did not import as RDShaderFile.")
		return
	_probe = PROBE_SCRIPT.new()
	RenderingServer.call_on_render_thread(_probe.initialize.bind(self, source_textures, shader_file))
	while not _probe_ready:
		await process_frame
	if not _probe_error.is_empty():
		_fail("Coastal GPU probe initialization failed: %s" % _probe_error)
		return
	printerr("PHYS32_STAGE probe_ready")

	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	var frozen_time := float(_ocean.call("get_wave_time"))
	_report["clock"] = await _check_clock(native_combined, frozen_time)
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	frozen_time = float(_ocean.call("get_wave_time"))
	if OS.get_environment("PHYS32_SCAN_ONLY") == "1":
		var focused_scan := await _run_packet(_make_hardware_scan_samples(), frozen_time,
			native_long, native_combined, "PHYS32_hardware_8192", true)
		_report["hardware_filter_geometry_scan_8192"] = _summarize_hardware_scan(focused_scan)
		_report["result"] = "PHYS-3.2-SCAN-ONLY"
		_save_report_temp()
		print("PHYS3_COASTAL_REPORT ", JSON.stringify(_report, "\t"))
		_probe.shutdown()
		quit(0)
		return

	var smoke_samples := _make_bake_texel_samples(4, 0)
	printerr("PHYS32_STAGE smoke")
	_report["long_coastal_smoke_4"] = await _run_packet(smoke_samples, frozen_time, native_long, native_combined, "A_frozen_4")
	var interior_samples := _make_bake_texel_samples(64, 1)
	printerr("PHYS32_STAGE interior")
	var interior_result: Dictionary = await _run_packet(interior_samples, frozen_time, native_long, native_combined, "B_frozen_64")
	_report["interior_64"] = interior_result
	_report["coastal_field_sampling"] = _field_stats(interior_result)
	var boundaries := _make_boundary_samples()
	printerr("PHYS32_STAGE boundary")
	_report["boundaries_16"] = await _run_packet(boundaries, frozen_time, native_long, native_combined, "C_boundary_16")
	var outside_samples := _make_outside_samples()
	printerr("PHYS32_STAGE outside")
	var outside_packet: Dictionary = await _run_packet(outside_samples, frozen_time, native_long, native_combined, "outside_fallback")
	_report["open_ocean_fallback"] = _compare_native_open_fallback(outside_packet, native_combined, native_open, frozen_time, outside_samples)
	_report["world_xz"] = _validate_world_inversion(native_combined, interior_samples, frozen_time)
	_report["batch"] = _validate_batch(native_combined, interior_samples, frozen_time)
	_report["normals"] = _validate_normals(native_combined, interior_samples.slice(0, 16), frozen_time)
	_report["performance"] = _measure_performance(native_combined, interior_samples, frozen_time)
	printerr("PHYS32_STAGE regressions_done")
	var hardware_scan_samples := _make_hardware_scan_samples()
	var hardware_scan_packet: Dictionary = await _run_packet(hardware_scan_samples, frozen_time,
		native_long, native_combined, "PHYS32_hardware_8192", true)
	_report["hardware_filter_geometry_scan_8192"] = _summarize_hardware_scan(hardware_scan_packet)
	printerr("PHYS32_STAGE scan_done")

	_ocean.set("wave_speed_multiplier", 1.0)
	await process_frame
	await process_frame
	var moving_t0 := float(_ocean.call("get_wave_time"))
	await process_frame
	await process_frame
	var moving_time := float(_ocean.call("get_wave_time"))
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	moving_time = float(_ocean.call("get_wave_time"))
	var moving_packet_samples := _make_bake_texel_samples(16, 2)
	var moving_result: Dictionary = await _run_packet(moving_packet_samples, moving_time,
		native_long, native_combined, "D_moving_16")
	_report["moving_packet"] = {"t0": moving_t0, "t1": moving_time, "packet": moving_result,
		"time_association_valid": moving_time > moving_t0 and bool(moving_result.get("same_time_proven", false))}
	_report["clock"]["moving"] = moving_time > moving_t0
	_report["result"] = _classify()
	_report["pending_closure"] = {
		"Spindrift crest G clamp 0..1 discrepancy": "pending",
		"P3D.1 travelling phase after TIME-1 in initialized Ocean/Carrier": "pending",
		"P3E handoff after TIME-1 in initialized Ocean/Carrier": "pending",
		"TIME-1 gpu_stockham_fft.gd instrumentation disposition": "pending",
	}
	print("PHYS3_COASTAL_REPORT ", JSON.stringify(_report, "\t"))
	_save_report_temp()
	print("PHYS3_COASTAL_COMPLETE")
	_probe.shutdown()
	quit(0 if String(_report["result"]).begins_with("PHYS-3-A") else 1)


func _save_report_temp() -> void:
	var report_path := OS.get_environment("TEMP").path_join("PHYS-3.2-REPORT.json")
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(_report, "\t"))
		report_file.close()
		printerr("PHYS32_REPORT_FILE ", report_path)


func _get_probe_textures() -> Array[RID]:
	var snapshots: Array = _fft.call("get_phys2_band_spectrum_snapshots")
	var output: Array[RID] = []
	for snapshot in snapshots:
		var solver_rid: RID = snapshot.get("displacement_rid", RID())
		if not solver_rid.is_valid():
			return []
		output.append(solver_rid)
	var coastal_data: Dictionary = _fft.get("_coastal_data")
	for key in [&"field", &"warp"]:
		var texture := coastal_data.get(key) as Texture2D
		if texture == null:
			return []
		var rid := RenderingServer.texture_get_rd_texture(texture.get_rid(), false)
		if not rid.is_valid():
			return []
		output.append(rid)
	return output


func _make_bake_texel_samples(count: int, phase: int) -> Array[Dictionary]:
	var fw := Vector2i(_bake_snapshot["field_resolution"])
	var origin: Vector2 = _bake_snapshot["field_origin"]
	var extent: Vector2 = _bake_snapshot["field_extent"]
	var result: Array[Dictionary] = []
	var candidate := 0
	while result.size() < count and candidate < fw.x * fw.y:
		var ix := 1 + posmod(candidate * 37 + phase * 11, fw.x - 2)
		var iy := 1 + posmod(candidate * 53 + phase * 17, fw.y - 2)
		candidate += 1
		var q := origin + Vector2((float(ix) + 0.5) / float(fw.x) * extent.x,
			(float(iy) + 0.5) / float(fw.y) * extent.y)
		result.append({"q": q, "field_texel": Vector2i(ix, iy), "region": "inside"})
	return result


func _make_hardware_scan_samples() -> Array[Dictionary]:
	# Identical deterministic 128x64 stratified set used by PHYS-3.1's 8192-point scan.
	var result: Array[Dictionary] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x31C0A57
	var origin: Vector2 = _bake_snapshot["warp_origin"]
	var extent: Vector2 = _bake_snapshot["warp_extent"]
	for y in 64:
		for x in 128:
			var uv := Vector2((float(x) + rng.randf()) / 128.0, (float(y) + rng.randf()) / 64.0)
			result.append({"q": origin + uv * extent, "region": "scan_%d" % result.size()})
	return result


func _make_boundary_samples() -> Array[Dictionary]:
	var origin: Vector2 = _bake_snapshot["field_origin"]
	var extent: Vector2 = _bake_snapshot["field_extent"]
	var e := 0.001
	var center_x := origin.x + extent.x * 0.5
	var center_z := origin.y + extent.y * 0.5
	var points := [
		Vector2(origin.x - e, center_z), Vector2(origin.x, center_z), Vector2(origin.x + e, center_z),
		Vector2(origin.x + extent.x - e, center_z), Vector2(origin.x + extent.x, center_z), Vector2(origin.x + extent.x + e, center_z),
		Vector2(center_x, origin.y - e), Vector2(center_x, origin.y), Vector2(center_x, origin.y + e),
		Vector2(center_x, origin.y + extent.y - e), Vector2(center_x, origin.y + extent.y), Vector2(center_x, origin.y + extent.y + e),
		Vector2(origin.x, origin.y), Vector2(origin.x + extent.x, origin.y),
		Vector2(origin.x, origin.y + extent.y), Vector2(origin.x + extent.x, origin.y + extent.y),
	]
	var result: Array[Dictionary] = []
	for point in points:
		result.append({"q": point, "region": "boundary"})
	return result


func _make_outside_samples() -> Array[Dictionary]:
	var origin: Vector2 = _bake_snapshot["field_origin"]
	var extent: Vector2 = _bake_snapshot["field_extent"]
	return [
		{"q": origin + Vector2(-1.0, extent.y * 0.5), "region": "outside_left"},
		{"q": origin + Vector2(extent.x + 1.0, extent.y * 0.5), "region": "outside_right"},
		{"q": origin + Vector2(extent.x * 0.5, -1.0), "region": "outside_top"},
		{"q": origin + Vector2(extent.x * 0.5, extent.y + 1.0), "region": "outside_bottom"},
		{"q": Vector2(-6000.0, -6000.0), "region": "far_outside"},
		{"q": Vector2(5000.0, 6000.0), "region": "far_outside"},
	]


func _run_packet(samples: Array[Dictionary], wave_time: float, native_long: Object,
				native_combined: Object, label: String,
				use_gpu_lattice_reference: bool = false) -> Dictionary:
	printerr("PHYS32_PACKET begin %s count=%d" % [label, samples.size()])
	var positions := PackedVector3Array()
	var packed := PackedFloat32Array()
	var long_domain := float(_spectra[0]["domain_size_m"])
	var mid_domain := float(_spectra[1]["domain_size_m"])
	var short_domain := float(_spectra[2]["domain_size_m"])
	var field_origin: Vector2 = _bake_snapshot["field_origin"]
	var field_extent: Vector2 = _bake_snapshot["field_extent"]
	var warp_origin: Vector2 = _bake_snapshot["warp_origin"]
	var warp_extent: Vector2 = _bake_snapshot["warp_extent"]
	for sample in samples:
		var q: Vector2 = sample["q"]
		positions.append(Vector3(q.x, 0.0, q.y))
		var fuv := (q - field_origin) / field_extent
		var wuv := (q - warp_origin) / warp_extent
		var gpu_wuv := PackedFloat32Array([wuv.x, wuv.y])
		sample["warp_uv_gpu"] = Vector2(gpu_wuv[0], gpu_wuv[1])
		var luv := q / long_domain + Vector2(0.5, 0.5)
		var muv := q / mid_domain + Vector2(0.5, 0.5)
		var suv := q / short_domain + Vector2(0.5, 0.5)
		var manual_warp := _cpu_warp_sample(q)
		var warped_q := Vector2(manual_warp[0], manual_warp[1])
		var warped_uv := warped_q / long_domain + Vector2(0.5, 0.5)
		packed.append_array(PackedFloat32Array([fuv.x, fuv.y, wuv.x, wuv.y,
			luv.x, luv.y, long_domain, 0.0, muv.x, muv.y, suv.x, suv.y,
			warped_uv.x, warped_uv.y, long_domain, 0.0]))
	var native_long_values := PackedFloat64Array()
	var native_combined_values := PackedFloat64Array()
	var matched_long: Array[Vector3] = []
	var matched_combined: Array[Vector3] = []
	if not use_gpu_lattice_reference:
		native_long_values = native_long.call("sample_material_q_batch", wave_time, positions)
		native_combined_values = native_combined.call("sample_material_q_batch", wave_time, positions)
		var long_base_lattice := _interpolate_band(_native_open_long, samples, 0, wave_time, false)
		var mid_lattice := _interpolate_band(_native_mid, samples, 1, wave_time, false)
		var short_lattice := _interpolate_band(_native_short, samples, 2, wave_time, false)
		var long_warp_lattice := _interpolate_band(_native_open_long, samples, 0, wave_time, true)
		for i in samples.size():
			var q: Vector2 = samples[i]["q"]
			var field := _cpu_field_sample(q)
			var warp := _cpu_warp_sample(q)
			var uv := (q - Vector2(_bake_snapshot["field_origin"])) / Vector2(_bake_snapshot["field_extent"])
			var confidence := 0.0
			if uv.x >= 0.0 and uv.y >= 0.0 and uv.x <= 1.0 and uv.y <= 1.0:
				confidence = field[3] * smoothstep(0.0, float(_bake_snapshot["detj_safe"]), warp[2]) * warp[3]
			var coastal_long := long_base_lattice[i].lerp(long_warp_lattice[i], confidence)
			coastal_long.y *= lerpf(1.0, field[1], confidence)
			matched_long.append(coastal_long)
			matched_combined.append(coastal_long + mid_lattice[i] + short_lattice[i])
	_request_id += 1
	var request := {"request_id": _request_id, "label": label, "sample_count": samples.size(),
		"samples": samples, "native_long": native_long_values,
		"native_combined": native_combined_values, "matched_long": matched_long,
		"matched_combined": matched_combined, "production_wave_time": wave_time,
		"native_time": wave_time, "gpu_request_frame": Engine.get_process_frames()}
	request["use_gpu_lattice_reference"] = use_gpu_lattice_reference
	RenderingServer.call_on_render_thread(_probe.dispatch_request.bind(request, packed, float(_bake_snapshot["detj_safe"])))
	while not _completed.has(_request_id):
		await _packet_completed
	printerr("PHYS32_PACKET complete %s" % label)
	return _completed[_request_id]


func _interpolate_band(native: Object, samples: Array[Dictionary], band_index: int,
					   wave_time: float, use_coastal_warp: bool) -> Array[Vector3]:
	var snapshot: Dictionary = _spectra[band_index]
	var n := int(snapshot["resolution"])
	var domain := float(snapshot["domain_size_m"])
	var positions := PackedVector3Array()
	var weights: Array[Vector4] = []
	for sample in samples:
		var q: Vector2 = sample["q"]
		if use_coastal_warp:
			var w := _cpu_warp_sample(q)
			q = Vector2(w[0], w[1])
		var uv := q / domain + Vector2(0.5, 0.5)
		var gx := uv.x * float(n) - 0.5
		var gz := uv.y * float(n) - 0.5
		var x0 := floori(gx); var z0 := floori(gz)
		var tx := gx - float(x0); var tz := gz - float(z0)
		weights.append(Vector4(tx, tz, 0.0, 0.0))
		for cell in [Vector2i(x0, z0), Vector2i(x0 + 1, z0), Vector2i(x0, z0 + 1), Vector2i(x0 + 1, z0 + 1)]:
			var ix := posmod(cell.x, n); var iz := posmod(cell.y, n)
			var lattice_q := Vector2(((float(ix) + 0.5) / float(n) - 0.5) * domain,
				((float(iz) + 0.5) / float(n) - 0.5) * domain)
			positions.append(Vector3(lattice_q.x, 0.0, lattice_q.y))
	var values: PackedFloat64Array = native.call("sample_material_q_batch", wave_time, positions)
	var result: Array[Vector3] = []
	for i in samples.size():
		var tx := weights[i].x; var tz := weights[i].y
		var out := Vector3.ZERO
		for corner in 4:
			var wx := tx if corner % 2 == 1 else 1.0 - tx
			var wz := tz if corner >= 2 else 1.0 - tz
			var base := (i * 4 + corner) * STRIDE
			out += wx * wz * Vector3(values[base + DX], values[base + DY], values[base + DZ])
		result.append(out)
	return result


func _on_phys3_probe_initialized(ok: bool, error: String) -> void:
	_probe_ready = true
	_probe_error = "" if ok else error


func _on_phys3_probe_readback(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	var result: Dictionary = {"valid": error.is_empty(), "label": request.get("label", ""), "error": error}
	if error.is_empty() and bytes.size() == int(request["sample_count"]) * REQUEST_RESULT_BYTES_PER_SAMPLE:
		var field_errors: Array = [[], [], [], []]
		var warp_errors: Array = [[], [], [], []]
		var long_errors: Array[float] = []
		var combined_errors: Array[float] = []
		var long_matched_errors: Array[float] = []
		var combined_matched_errors: Array[float] = []
		var long_xyz_errors: Array = [[], [], []]
		var combined_xyz_errors: Array = [[], [], []]
		var combined_matched_xyz_errors: Array = [[], [], []]
		var combined_matched_vector_errors: Array[float] = []
		var manual_warp_vector_errors: Array[float] = []
		var manual_field_warp_vector_errors: Array[float] = []
		var manual_fft_warp_vector_errors: Array[float] = []
		var manual_fft_both_vector_errors: Array[float] = []
		var hardware_baseline_vector_errors: Array[float] = []
		var manual_warp_errors: Array = [[], [], [], []]
		var rows: Array[Dictionary] = []
		var confidence_buckets := {"zero": [], "0_to_0_01": [], "0_01_to_0_1": [],
			"0_1_to_0_5": [], "over_0_5": [], "over_0_9": []}
		var native_long: PackedFloat64Array = request["native_long"]
		var native_combined: PackedFloat64Array = request["native_combined"]
		for i in int(request["sample_count"]):
			var base_byte := i * REQUEST_RESULT_BYTES_PER_SAMPLE
			var field := _read_vec4(bytes, base_byte)
			var warp := _read_vec4(bytes, base_byte + 16)
			var open_and_confidence := _read_vec4(bytes, base_byte + 32)
			var long_coastal := _read_vec4(bytes, base_byte + 48)
			var combined := _read_vec4(bytes, base_byte + 64)
			var manual_warp := _read_vec4(bytes, base_byte + 9 * 16)
			var manual_warp_total := _read_vec4(bytes, base_byte + 10 * 16)
			var manual_field := _read_vec4(bytes, base_byte + 11 * 16)
			var manual_both_total := _read_vec4(bytes, base_byte + 12 * 16)
			var long_warped_hw := _read_vec4(bytes, base_byte + 13 * 16)
			var long_warped_manual := _read_vec4(bytes, base_byte + 14 * 16)
			var hardware_total_prechange := _read_vec4(bytes, base_byte + 15 * 16)
			var manual_fft_warp_total := _read_vec4(bytes, base_byte + 16 * 16)
			var manual_fft_both_total := _read_vec4(bytes, base_byte + 17 * 16)
			var q: Vector2 = request["samples"][i]["q"]
			var cpu_field := _cpu_field_sample(q)
			var cpu_warp := _cpu_warp_sample(q)
			var cpu_warp_same_uv := _cpu_warp_sample_uv(Vector2(request["samples"][i]["warp_uv_gpu"]))
			var use_gpu_lattice_reference := bool(request.get("use_gpu_lattice_reference", false))
			var manual_confidence := _manual_confidence(q, cpu_field, cpu_warp)
			var matched_l: Vector3
			var matched_c: Vector3
			if use_gpu_lattice_reference:
				var fft_base := base_byte + 80
				var long_open_lattice := _read_vec4(bytes, fft_base)
				var long_warp_lattice := _read_vec4(bytes, fft_base + 16)
				var mid_lattice := _read_vec4(bytes, fft_base + 32)
				var short_lattice := _read_vec4(bytes, fft_base + 48)
				matched_l = Vector3(long_open_lattice.x, long_open_lattice.y, long_open_lattice.z).lerp(
					Vector3(long_warp_lattice.x, long_warp_lattice.y, long_warp_lattice.z), manual_confidence)
				matched_l.y *= lerpf(1.0, cpu_field[1], manual_confidence)
				matched_c = matched_l + Vector3(mid_lattice.x, mid_lattice.y, mid_lattice.z) \
					+ Vector3(short_lattice.x, short_lattice.y, short_lattice.z)
			else:
				matched_l = request["matched_long"][i]
				matched_c = request["matched_combined"][i]
			for channel in 4:
				field_errors[channel].append(absf(field[channel] - cpu_field[channel]))
				warp_errors[channel].append(absf(warp[channel] - cpu_warp[channel]))
				manual_warp_errors[channel].append(absf(manual_warp[channel] - cpu_warp_same_uv[channel]))
			var lb := i * STRIDE
			var has_native := native_long.size() > lb + DZ and native_combined.size() > lb + DZ
			var native_l := Vector3(native_long[lb + DX], native_long[lb + DY], native_long[lb + DZ]) if has_native else Vector3.ZERO
			var native_c := Vector3(native_combined[lb + DX], native_combined[lb + DY], native_combined[lb + DZ]) if has_native else Vector3.ZERO
			var gpu_l := Vector3(long_coastal.x, long_coastal.y, long_coastal.z)
			var gpu_c := Vector3(combined.x, combined.y, combined.z)
			var dl := gpu_l - native_l
			var dc := gpu_c - native_c
			if has_native:
				long_errors.append(dl.length())
				combined_errors.append(dc.length())
			long_matched_errors.append((gpu_l - matched_l).length())
			combined_matched_errors.append((gpu_c - matched_c).length())
			for axis in 3:
				long_xyz_errors[axis].append(absf(dl[axis]))
				if has_native: combined_xyz_errors[axis].append(absf(dc[axis]))
				combined_matched_xyz_errors[axis].append(absf((gpu_c - matched_c)[axis]))
			var final_matched_error := (gpu_c - matched_c).length()
			combined_matched_vector_errors.append(final_matched_error)
			var manual_warp_error := (Vector3(manual_warp_total.x, manual_warp_total.y, manual_warp_total.z) - matched_c).length()
			var manual_both_error := (Vector3(manual_both_total.x, manual_both_total.y, manual_both_total.z) - matched_c).length()
			var hardware_baseline_error := (Vector3(hardware_total_prechange.x, hardware_total_prechange.y, hardware_total_prechange.z) - matched_c).length()
			var manual_fft_warp_error := (Vector3(manual_fft_warp_total.x, manual_fft_warp_total.y, manual_fft_warp_total.z) - matched_c).length()
			var manual_fft_both_error := (Vector3(manual_fft_both_total.x, manual_fft_both_total.y, manual_fft_both_total.z) - matched_c).length()
			manual_warp_vector_errors.append(manual_warp_error)
			manual_field_warp_vector_errors.append(manual_both_error)
			hardware_baseline_vector_errors.append(hardware_baseline_error)
			manual_fft_warp_vector_errors.append(manual_fft_warp_error)
			manual_fft_both_vector_errors.append(manual_fft_both_error)
			var raw_r_error := absf(warp.x - cpu_warp[0])
			var raw_g_error := absf(warp.y - cpu_warp[1])
			var manual_r_error := absf(manual_warp.x - cpu_warp_same_uv[0])
			var manual_g_error := absf(manual_warp.y - cpu_warp_same_uv[1])
			var confidence := float(open_and_confidence.w)
			var neighbor_span := _warp_neighbor_span(q)
			var raw_rg_error := Vector2(raw_r_error, raw_g_error).length()
			var row := {"sample_index": i, "q_material": q,
				"field_uv": (q - Vector2(_bake_snapshot["field_origin"])) / Vector2(_bake_snapshot["field_extent"]),
				"warp_uv_gpu": request["samples"][i]["warp_uv_gpu"],
				"warp_cpu_same_uv": cpu_warp_same_uv,
				"field_gpu": field, "field_cpu": cpu_field, "warp_gpu": warp, "warp_cpu": cpu_warp,
				"raw_warp_r_error": raw_r_error, "raw_warp_g_error": raw_g_error,
				"manual_warp_r_error": manual_r_error, "manual_warp_g_error": manual_g_error,
				"neighbor_warp_coordinate_span_m": neighbor_span,
				"estimated_effective_filter_weight_error": raw_rg_error / maxf(neighbor_span, 1.0e-12),
				"field_a_gpu": field.w, "warp_w_gpu": warp.w, "warp_z_gpu": warp.z,
				"detj_safe": float(_bake_snapshot["detj_safe"]),
				"confidence": confidence, "confidence_gpu": confidence, "confidence_cpu_manual": manual_confidence,
				"long_gpu_coastal": gpu_l, "long_native": native_l,
				"combined_gpu": gpu_c, "combined_native": native_c,
				"combined_cpu_manual_lattice": matched_c, "final_geometry_error": final_matched_error,
				"final_geometry_xyz_error": gpu_c - matched_c}
			_add_confidence_row(confidence_buckets, confidence, raw_r_error, raw_g_error,
				final_matched_error, manual_warp_error, manual_both_error, manual_fft_both_error,
				manual_r_error, manual_g_error)
			var top_trace := {"q_material": q, "confidence": confidence,
				"field_hardware": field, "field_manual": manual_field,
				"warp_hardware": warp, "warp_manual": manual_warp,
				"original_LONG": open_and_confidence,
				"hardware_warped_LONG": long_warped_hw,
				"manual_warped_LONG": long_warped_manual,
				"shoaling_scale_hardware": field.y,
				"hardware_Coastal_LONG": long_coastal,
				"manual_Warp_only_total": manual_warp_total,
				"manual_Field_and_Warp_total": manual_both_total,
				"manual_FFT_Warp_only_total": manual_fft_warp_total,
				"manual_FFT_Field_and_Warp_total": manual_fft_both_total,
				"hardware_total": combined,
				"hardware_total_prechange": hardware_total_prechange,
				"native_deterministic_total": matched_c,
				"hardware_error_m": final_matched_error,
				"hardware_prechange_error_m": hardware_baseline_error,
				"manual_Warp_error_m": manual_warp_error,
				"manual_Warp_R_error_m": manual_r_error, "manual_Warp_G_error_m": manual_g_error,
				"manual_Field_and_Warp_error_m": manual_both_error}
			top_trace["manual_FFT_Warp_only_error_m"] = manual_fft_warp_error
			top_trace["manual_FFT_Field_and_Warp_error_m"] = manual_fft_both_error
			row.merge(top_trace, true)
			rows.append(row)
		result.merge({
			"request_id": request["request_id"], "production_wave_time": request["production_wave_time"],
			"native_time": request["native_time"], "same_time_proven": is_equal_approx(float(request["production_wave_time"]), float(request["native_time"])),
			"fft_reference": "GPU texelFetch lattice + manual periodic bilinear; Coastal bake manual bilinear on CPU" if bool(request.get("use_gpu_lattice_reference", false)) else "native lattice queries + CPU bilinear",
			"gpu_request_frame": request["gpu_request_frame"], "callback_frame": Engine.get_process_frames(),
			"async_latency_frames": maxi(Engine.get_process_frames() - int(request["gpu_request_frame"]), 0),
			"sample_count": request["sample_count"], "result_buffer_bytes": bytes.size(),
			"field_abs_error_by_channel": _channel_stats(field_errors), "warp_abs_error_by_channel": _channel_stats(warp_errors),
			"manual_warp_abs_error_by_channel": _channel_stats(manual_warp_errors),
			"production_gpu_coastal_long_vs_native_continuous_vector": _stats(long_errors),
			"production_gpu_combined_vs_native_continuous_vector": _stats(combined_errors),
			"production_gpu_coastal_long_vs_native_lattice_interpolation_vector": _stats(long_matched_errors),
			"production_gpu_combined_vs_native_lattice_interpolation_vector": _stats(combined_matched_errors),
			"long_xyz_abs_error": _channel_stats(long_xyz_errors), "combined_xyz_abs_error": _channel_stats(combined_xyz_errors),
			"combined_matched_xyz_abs_error": _channel_stats_percentiles(combined_matched_xyz_errors),
			"combined_matched_vector_stats": _stats_percentiles(combined_matched_vector_errors),
			"manual_warp_only_vs_native_vector_stats": _stats_percentiles(manual_warp_vector_errors),
			"manual_field_and_warp_vs_native_vector_stats": _stats_percentiles(manual_field_warp_vector_errors),
			"manual_warp_and_fft_vs_native_vector_stats": _stats_percentiles(manual_fft_warp_vector_errors),
			"manual_field_warp_and_fft_vs_native_vector_stats": _stats_percentiles(manual_fft_both_vector_errors),
			"hardware_filter_baseline_vs_native_vector_stats": _stats_percentiles(hardware_baseline_vector_errors),
			"confidence_buckets": _summarize_confidence_buckets(confidence_buckets),
			"top_raw_warp_r": _top_scan_rows(rows, "raw_warp_r_error"),
			"top_raw_warp_g": _top_scan_rows(rows, "raw_warp_g_error"),
			"top_manual_warp_r": _top_scan_rows(rows, "manual_warp_r_error"),
			"top_manual_warp_g": _top_scan_rows(rows, "manual_warp_g_error"),
			"top_hardware_filter_final_geometry": _top_scan_rows(rows, "hardware_prechange_error_m", 16),
			"max_final_geometry": _top_scan_rows(rows, "final_geometry_error", 1),
			"max_final_geometry_confidence_gte_0_5": _max_geometry_in_confidence(rows, 0.5),
			"max_final_geometry_confidence_gte_0_9": _max_geometry_in_confidence(rows, 0.9),
			"boundary_pair_deltas": _boundary_deltas(rows) if String(request["label"]) == "C_boundary_16" else [],
			"sample_examples": rows.slice(0, mini(4, rows.size())),
		}, true)
	elif error.is_empty():
		result.merge({"valid": false, "error": "Unexpected async result size: %d" % bytes.size()})
	_completed[int(request["request_id"])] = result
	_packet_completed.emit()


func _manual_confidence(q: Vector2, field: PackedFloat32Array, warp: PackedFloat32Array) -> float:
	var origin: Vector2 = _bake_snapshot["field_origin"]
	var extent: Vector2 = _bake_snapshot["field_extent"]
	var uv := (q - origin) / extent
	if uv.x < 0.0 or uv.y < 0.0 or uv.x > 1.0 or uv.y > 1.0:
		return 0.0
	return field[3] * smoothstep(0.0, float(_bake_snapshot["detj_safe"]), warp[2]) * warp[3]


func _warp_neighbor_span(q: Vector2) -> float:
	var origin: Vector2 = _bake_snapshot["warp_origin"]
	var extent: Vector2 = _bake_snapshot["warp_extent"]
	var size: Vector2i = _bake_snapshot["warp_resolution"]
	var uv := (q - origin) / extent
	uv = Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0))
	var ix := _sample_linear_index(size, uv)
	var xs := [int(ix[0]), int(ix[1])]
	var ys := [int(ix[2]), int(ix[3])]
	var wx: PackedFloat32Array = _bake_snapshot["warp_x"]
	var wz: PackedFloat32Array = _bake_snapshot["warp_z"]
	var points: Array[Vector2] = []
	for y in ys:
		for x in xs:
			var index: int = y * size.x + x
			points.append(Vector2(wx[index], wz[index]))
	var span := 0.0
	for a in points.size():
		for b in range(a + 1, points.size()):
			span = maxf(span, points[a].distance_to(points[b]))
	return span


func _add_confidence_row(buckets: Dictionary, confidence: float, error_r: float,
			error_g: float, final_error: float, manual_warp_error: float,
			manual_both_error: float, manual_fft_error: float,
			manual_raw_r: float, manual_raw_g: float) -> void:
	var key := "zero"
	if confidence > 0.0 and confidence <= 0.01: key = "0_to_0_01"
	elif confidence > 0.01 and confidence <= 0.1: key = "0_01_to_0_1"
	elif confidence > 0.1 and confidence <= 0.5: key = "0_1_to_0_5"
	elif confidence > 0.5: key = "over_0_5"
	(buckets[key] as Array).append({"warp_r": error_r, "warp_g": error_g,
		"warp_rg_max": maxf(error_r, error_g), "final": final_error,
		"manual_warp_final": manual_warp_error, "manual_both_final": manual_both_error,
		"manual_fft_final": manual_fft_error, "manual_raw_r": manual_raw_r,
		"manual_raw_g": manual_raw_g})
	if confidence > 0.9:
		(buckets["over_0_9"] as Array).append({"warp_r": error_r, "warp_g": error_g,
			"warp_rg_max": maxf(error_r, error_g), "final": final_error,
			"manual_warp_final": manual_warp_error, "manual_both_final": manual_both_error,
			"manual_fft_final": manual_fft_error, "manual_raw_r": manual_raw_r,
			"manual_raw_g": manual_raw_g})


func _summarize_confidence_buckets(buckets: Dictionary) -> Dictionary:
	var out := {}
	for key in buckets:
		var items: Array = buckets[key]
		var raw: Array[float] = []
		var raw_r: Array[float] = []
		var raw_g: Array[float] = []
		var final: Array[float] = []
		var manual_warp_final: Array[float] = []
		var manual_both_final: Array[float] = []
		var manual_fft_final: Array[float] = []
		var manual_raw_r: Array[float] = []
		var manual_raw_g: Array[float] = []
		for item in items:
			raw.append(float(item["warp_rg_max"]))
			raw_r.append(float(item["warp_r"]))
			raw_g.append(float(item["warp_g"]))
			final.append(float(item["final"]))
			manual_warp_final.append(float(item["manual_warp_final"]))
			manual_both_final.append(float(item["manual_both_final"]))
			manual_fft_final.append(float(item["manual_fft_final"]))
			manual_raw_r.append(float(item["manual_raw_r"]))
			manual_raw_g.append(float(item["manual_raw_g"]))
		out[key] = {"samples": items.size(), "raw_warp_r_error": _stats(raw_r),
			"raw_warp_g_error": _stats(raw_g), "raw_warp_rg_max_error": _stats(raw),
			"max_raw_warp_rg_error": _stats(raw)["max"],
			"final_geometry_mean_p95_max": _stats(final),
			"manual_warp_final_mean_p95_max": _stats(manual_warp_final),
			"manual_field_warp_final_mean_p95_max": _stats(manual_both_final),
			"manual_coastal_and_fft_final_mean_p95_max": _stats(manual_fft_final),
			"manual_warp_raw_r": _stats(manual_raw_r),
			"manual_warp_raw_g": _stats(manual_raw_g)}
	return out


func _top_scan_rows(rows: Array[Dictionary], key: String, limit: int = 16) -> Array[Dictionary]:
	var ranked := rows.duplicate()
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a[key]) > float(b[key]))
	if ranked.size() > limit: ranked.resize(limit)
	return ranked


func _max_geometry_in_confidence(rows: Array[Dictionary], minimum_confidence: float) -> Dictionary:
	var eligible: Array[Dictionary] = rows.filter(func(row: Dictionary) -> bool:
		return float(row["confidence_gpu"]) >= minimum_confidence)
	var top := _top_scan_rows(eligible, "final_geometry_error", 1)
	return top[0] if not top.is_empty() else {}


func _stats_percentiles(values: Array) -> Dictionary:
	var out := _stats(values)
	if values.is_empty():
		out["p99"] = 0.0
		return out
	var sorted: Array = values.duplicate()
	sorted.sort()
	out["p99"] = float(sorted[clampi(ceili(sorted.size() * 0.99) - 1, 0, sorted.size() - 1)])
	return out


func _summarize_hardware_scan(packet: Dictionary) -> Dictionary:
	return {"samples": packet.get("sample_count", 0), "valid": packet.get("valid", false),
		"wave_time": packet.get("production_wave_time", 0.0), "request_id": packet.get("request_id", 0),
		"async_latency_frames": packet.get("async_latency_frames", 0),
		"result_buffer_bytes": packet.get("result_buffer_bytes", 0),
		"field_hardware_vs_manual": packet.get("field_abs_error_by_channel", {}),
		"warp_hardware_vs_manual": packet.get("warp_abs_error_by_channel", {}),
		"confidence_buckets": packet.get("confidence_buckets", {}),
		"combined_final_geometry_xyz_abs_error": packet.get("combined_matched_xyz_abs_error", {}),
		"combined_final_geometry_vector_error": packet.get("combined_matched_vector_stats", {}),
		"manual_warp_only_vs_native_vector_error": packet.get("manual_warp_only_vs_native_vector_stats", {}),
		"manual_field_and_warp_vs_native_vector_error": packet.get("manual_field_and_warp_vs_native_vector_stats", {}),
		"manual_warp_and_fft_vs_native_vector_error": packet.get("manual_warp_and_fft_vs_native_vector_stats", {}),
		"manual_field_warp_and_fft_vs_native_vector_error": packet.get("manual_field_warp_and_fft_vs_native_vector_stats", {}),
		"manual_warp_sampling_vs_cpu": packet.get("manual_warp_abs_error_by_channel", {}),
		"hardware_filter_baseline_vs_native_vector_error": packet.get("hardware_filter_baseline_vs_native_vector_stats", {}),
		"top_manual_warp_r": packet.get("top_manual_warp_r", []),
		"top_manual_warp_g": packet.get("top_manual_warp_g", []),
		"top_hardware_filter_final_geometry": packet.get("top_hardware_filter_final_geometry", []),
		"top_raw_warp_r": packet.get("top_raw_warp_r", []),
		"top_raw_warp_g": packet.get("top_raw_warp_g", []),
		"max_final_geometry": packet.get("max_final_geometry", []),
		"max_final_geometry_confidence_gte_0_5": packet.get("max_final_geometry_confidence_gte_0_5", {}),
		"max_final_geometry_confidence_gte_0_9": packet.get("max_final_geometry_confidence_gte_0_9", {})}


func _cpu_field_sample(q: Vector2) -> PackedFloat32Array:
	var origin: Vector2 = _bake_snapshot["field_origin"]
	var extent: Vector2 = _bake_snapshot["field_extent"]
	var size: Vector2i = _bake_snapshot["field_resolution"]
	var uv := (q - origin) / extent
	var phase_offset: PackedFloat32Array = _bake_snapshot["phase_offset"]
	var field_data: PackedFloat32Array = _bake_snapshot["shoaling"]
	var local_k: PackedFloat32Array = _bake_snapshot["local_k"]
	var valid_data: PackedByteArray = _bake_snapshot["field_valid"]
	var valid := _sample_linear_bytes(valid_data, size, uv)
	var shoaling := _sample_linear(field_data, size, uv)
	return PackedFloat32Array([_sample_linear(phase_offset, size, uv), shoaling,
		_sample_linear(local_k, size, uv), valid])


func _cpu_warp_sample(q: Vector2) -> PackedFloat32Array:
	var origin: Vector2 = _bake_snapshot["warp_origin"]
	var extent: Vector2 = _bake_snapshot["warp_extent"]
	var size: Vector2i = _bake_snapshot["warp_resolution"]
	var uv := (q - origin) / extent
	uv = Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0))
	return PackedFloat32Array([
		_sample_linear(_bake_snapshot["warp_x"], size, uv),
		_sample_linear(_bake_snapshot["warp_z"], size, uv),
		_sample_linear(_bake_snapshot["warp_det_j"], size, uv),
		_sample_linear_bytes(_bake_snapshot["warp_valid"], size, uv),
	])


func _cpu_warp_sample_uv(uv: Vector2) -> PackedFloat32Array:
	var size: Vector2i = _bake_snapshot["warp_resolution"]
	uv = Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0))
	return PackedFloat32Array([
		_sample_linear(_bake_snapshot["warp_x"], size, uv),
		_sample_linear(_bake_snapshot["warp_z"], size, uv),
		_sample_linear(_bake_snapshot["warp_det_j"], size, uv),
		_sample_linear_bytes(_bake_snapshot["warp_valid"], size, uv),
	])


func _sample_linear_index(size: Vector2i, uv: Vector2) -> PackedFloat64Array:
	var gx := clampf(uv.x * float(size.x) - 0.5, 0.0, float(size.x - 1))
	var gy := clampf(uv.y * float(size.y) - 0.5, 0.0, float(size.y - 1))
	var x0 := floori(gx); var y0 := floori(gy)
	return PackedFloat64Array([x0, mini(x0 + 1, size.x - 1), y0, mini(y0 + 1, size.y - 1), gx - float(x0), gy - float(y0)])


func _sample_linear(values: PackedFloat32Array, size: Vector2i, uv: Vector2) -> float:
	if values.size() != size.x * size.y:
		return 0.0
	var indices := _sample_linear_index(size, uv)
	var i00 := int(indices[2]) * size.x + int(indices[0])
	var i10 := int(indices[2]) * size.x + int(indices[1])
	var i01 := int(indices[3]) * size.x + int(indices[0])
	var i11 := int(indices[3]) * size.x + int(indices[1])
	var tx := float(indices[4]); var ty := float(indices[5])
	return lerpf(lerpf(values[i00], values[i10], tx), lerpf(values[i01], values[i11], tx), ty)


func _sample_linear_bytes(values: PackedByteArray, size: Vector2i, uv: Vector2) -> float:
	if values.size() != size.x * size.y:
		return 0.0
	var indices := _sample_linear_index(size, uv)
	var i00 := int(indices[2]) * size.x + int(indices[0])
	var i10 := int(indices[2]) * size.x + int(indices[1])
	var i01 := int(indices[3]) * size.x + int(indices[0])
	var i11 := int(indices[3]) * size.x + int(indices[1])
	var tx := float(indices[4]); var ty := float(indices[5])
	var v00 := 1.0 if values[i00] != 0 else 0.0
	var v10 := 1.0 if values[i10] != 0 else 0.0
	var v01 := 1.0 if values[i01] != 0 else 0.0
	var v11 := 1.0 if values[i11] != 0 else 0.0
	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), ty)


func _field_stats(packet: Dictionary) -> Dictionary:
	return {"field": packet.get("field_abs_error_by_channel", {}), "warp": packet.get("warp_abs_error_by_channel", {}),
		"texture_readback": false, "source": "authoritative CPU bake arrays vs GPU texture sampler"}


func _boundary_deltas(rows: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for pair in [[0, 1], [1, 2], [3, 4], [4, 5], [6, 7], [7, 8], [9, 10], [10, 11]]:
		var a: Dictionary = rows[int(pair[0])]
		var b: Dictionary = rows[int(pair[1])]
		result.append({"q_a": a["q_material"], "q_b": b["q_material"],
			"confidence_a": a["confidence"], "confidence_b": b["confidence"],
			"GPU_long_delta_m": (Vector3(b["long_gpu_coastal"]) - Vector3(a["long_gpu_coastal"])).length(),
			"native_long_delta_m": (Vector3(b["long_native"]) - Vector3(a["long_native"])).length(),
			"transition_difference_m": (Vector3(b["long_gpu_coastal"]) - Vector3(a["long_gpu_coastal"]) -
				(Vector3(b["long_native"]) - Vector3(a["long_native"]))).length()})
	return result


func _compare_native_open_fallback(packet: Dictionary, native_coastal: Object, native_open: Object, wave_time: float,
								   samples: Array[Dictionary]) -> Dictionary:
	var positions := PackedVector3Array()
	for item in samples:
		var q: Vector2 = item["q"]
		positions.append(Vector3(q.x, 0.0, q.y))
	var coastal_values: PackedFloat64Array = native_coastal.call("sample_material_q_batch", wave_time, positions)
	var open_values: PackedFloat64Array = native_open.call("sample_material_q_batch", wave_time, positions)
	var errors: Array[float] = []
	var outside_region := true
	for i in samples.size():
		var q: Vector2 = samples[i]["q"]
		var uv := (q - Vector2(_bake_snapshot["field_origin"])) / Vector2(_bake_snapshot["field_extent"])
		outside_region = outside_region and (uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0)
		var base := i * STRIDE
		var native_coast := Vector3(coastal_values[base + DX], coastal_values[base + DY], coastal_values[base + DZ])
		var native_raw := Vector3(open_values[base + DX], open_values[base + DY], open_values[base + DZ])
		errors.append((native_coast - native_raw).length())
	return {"samples": samples.size(), "all_outside": outside_region, "native_coastal_enabled_vs_PHYS2_open": _stats(errors),
		"zero_residual_expected": true}


func _validate_world_inversion(native: Object, samples: Array[Dictionary], wave_time: float) -> Dictionary:
	var chosen := samples.slice(0, 64)
	var queries := PackedVector3Array()
	var source_q: Array[Vector2] = []
	for sample in chosen:
		var q: Vector2 = sample["q"]
		var d: PackedFloat64Array = native.call("sample_material_q", q.x, q.y, wave_time)
		queries.append(Vector3(q.x + d[DX], 0.0, q.y + d[DZ]))
		source_q.append(q)
	var q_errors: Array[float] = []
	var residuals: Array[float] = []
	var iterations: Array[float] = []
	var failed_cases: Array[Dictionary] = []
	var failures := 0
	for i in queries.size():
		var world: Vector3 = queries[i]
		var qresult: PackedFloat64Array = native.call("sample_world_with_material_q", world.x, world.z, wave_time)
		var recovered := Vector2(qresult[STRIDE], qresult[STRIDE + 1])
		q_errors.append(recovered.distance_to(source_q[i]))
		residuals.append(float(qresult[13]))
		iterations.append(float(qresult[14]))
		if qresult[0] < 0.5:
			failures += 1
			var field := _cpu_field_sample(source_q[i])
			var warp := _cpu_warp_sample(source_q[i])
			failed_cases.append({"q_material": source_q[i], "target_world_xz": Vector2(world.x, world.z),
				"iterations": qresult[14], "residual_m": qresult[13],
				"local_horizontal_jacobian_determinant": qresult[11],
				"Coastal_field_shoaling": field[1], "Coastal_field_valid": field[3],
				"warp_xy_detj_valid": Vector4(warp[0], warp[1], warp[2], warp[3])})
	return {"samples": queries.size(), "failures": failures, "iterations": _stats(iterations),
		"q_recovery_m": _stats(q_errors), "horizontal_residual_m": _stats(residuals),
		"failed_cases": failed_cases}


func _validate_batch(native: Object, samples: Array[Dictionary], wave_time: float) -> Dictionary:
	var positions := PackedVector3Array()
	for sample in samples:
		var q: Vector2 = sample["q"]
		positions.append(Vector3(q.x, 0.0, q.y))
	var batch: PackedFloat64Array = native.call("sample_material_q_batch", wave_time, positions)
	var errors: Array[float] = []
	for i in positions.size():
		var q: Vector3 = positions[i]
		var scalar: PackedFloat64Array = native.call("sample_material_q", q.x, q.z, wave_time)
		var base := i * STRIDE
		errors.append(Vector3(batch[base + DX] - scalar[DX], batch[base + DY] - scalar[DY], batch[base + DZ] - scalar[DZ]).length())
	var worlds := PackedVector3Array()
	for position in positions:
		var q: PackedFloat64Array = native.call("sample_material_q", position.x, position.z, wave_time)
		worlds.append(Vector3(position.x + q[DX], 0.0, position.z + q[DZ]))
	var world_batch: PackedFloat64Array = native.call("sample_batch", wave_time, worlds)
	var world_errors: Array[float] = []
	for i in worlds.size():
		var world: Vector3 = worlds[i]
		var scalar: PackedFloat64Array = native.call("sample_world", world.x, world.z, wave_time)
		var base := i * STRIDE
		world_errors.append(Vector3(world_batch[base + DX] - scalar[DX], world_batch[base + DY] - scalar[DY], world_batch[base + DZ] - scalar[DZ]).length())
	return {"samples": positions.size(), "material_scalar_vs_batch_m": _stats(errors),
		"world_scalar_vs_batch_m": _stats(world_errors)}


func _validate_normals(native: Object, samples: Array[Dictionary], wave_time: float) -> Dictionary:
	const EPS := 0.01
	var errors: Array[float] = []
	var worst := {}
	for sample in samples:
		var q: Vector2 = sample["q"]
		var c: PackedFloat64Array = native.call("sample_material_q", q.x, q.y, wave_time)
		var xp: PackedFloat64Array = native.call("sample_material_q", q.x + EPS, q.y, wave_time)
		var xm: PackedFloat64Array = native.call("sample_material_q", q.x - EPS, q.y, wave_time)
		var zp: PackedFloat64Array = native.call("sample_material_q", q.x, q.y + EPS, wave_time)
		var zm: PackedFloat64Array = native.call("sample_material_q", q.x, q.y - EPS, wave_time)
		var tangent_x := Vector3(1.0, 0.0, 0.0) + (Vector3(xp[DX], xp[DY], xp[DZ]) - Vector3(xm[DX], xm[DY], xm[DZ])) / (2.0 * EPS)
		var tangent_z := Vector3(0.0, 0.0, 1.0) + (Vector3(zp[DX], zp[DY], zp[DZ]) - Vector3(zm[DX], zm[DY], zm[DZ])) / (2.0 * EPS)
		var normal := tangent_z.cross(tangent_x).normalized()
		if normal.y < 0.0: normal = -normal
		var error := (normal - Vector3(c[5], c[6], c[7])).length()
		errors.append(error)
		if worst.is_empty() or error > float(worst["error"]):
			worst = {"q_material": q, "fd_normal": normal, "native_normal": Vector3(c[5], c[6], c[7]), "error": error}
	return {"method": "centered finite differences of the final native Coastal displacement", "samples": samples.size(), "finite_difference_epsilon_m": EPS, "normal_error": _stats(errors), "worst_case": worst}


func _measure_performance(native: Object, samples: Array[Dictionary], wave_time: float) -> Dictionary:
	var result := {"hardware": "i7-5820K / GTX 970", "classification": "PROVISIONAL ONLY", "coastal_queries": []}
	for count in [1, 4, 16, 64]:
		var positions := PackedVector3Array()
		for i in count:
			var q: Vector2 = samples[i]["q"]
			positions.append(Vector3(q.x, 0.0, q.y))
		var start := Time.get_ticks_usec()
		for qv in positions:
			native.call("sample_material_q", qv.x, qv.z, wave_time)
		var scalar := Time.get_ticks_usec() - start
		start = Time.get_ticks_usec()
		native.call("sample_material_q_batch", wave_time, positions)
		var batch := Time.get_ticks_usec() - start
		result["coastal_queries"].append({"queries": count, "scalar_total_us": scalar,
			"scalar_us_per_query": float(scalar) / float(count), "batch_total_us": batch,
			"batch_us_per_query": float(batch) / float(count)})
	return result


func _check_clock(native: Object, initial_time: float) -> Dictionary:
	_ocean.set("wave_speed_multiplier", 1.0)
	await process_frame
	await process_frame
	var t0 := float(_ocean.call("get_wave_time"))
	var native0 := float(native.call("sample_material_q", 0.0, 0.0, t0)[0])
	await process_frame
	await process_frame
	var t1 := float(_ocean.call("get_wave_time"))
	var native1 := float(native.call("sample_material_q", 0.0, 0.0, t1)[0])
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	var frozen0 := float(_ocean.call("get_wave_time"))
	var _native_frozen0: PackedFloat64Array = native.call("sample_material_q", 0.0, 0.0, frozen0)
	await _settle_clock()
	var frozen1 := float(_ocean.call("get_wave_time"))
	_ocean.set("wave_speed_multiplier", 1.0)
	await process_frame
	var resume0 := float(_ocean.call("get_wave_time"))
	await process_frame
	var resume1 := float(_ocean.call("get_wave_time"))
	_ocean.set("wave_speed_multiplier", 0.0)
	await _settle_clock()
	return {"initial": initial_time, "t0": t0, "t1": t1, "native_times": [t0, t1],
		"one_x_advances": t1 > t0, "frozen": [frozen0, frozen1], "zero_x_freezes": is_equal_approx(frozen0, frozen1),
		"resume": [resume0, resume1], "resume_advances": resume1 > resume0,
		"native_clock_authority": "only caller-provided Ocean.get_wave_time()"}


func _settle_clock() -> void:
	for _frame in 4:
		await RenderingServer.frame_post_draw


func _read_vec4(bytes: PackedByteArray, offset: int) -> Vector4:
	return Vector4(bytes.decode_float(offset), bytes.decode_float(offset + 4), bytes.decode_float(offset + 8), bytes.decode_float(offset + 12))


func _channel_stats(values: Array) -> Dictionary:
	var names := ["R", "G", "B", "A"]
	var result := {}
	for i in mini(values.size(), names.size()):
		result[names[i]] = _stats(values[i])
	return result


func _channel_stats_percentiles(values: Array) -> Dictionary:
	var names := ["X", "Y", "Z"]
	var result := {}
	for i in mini(values.size(), names.size()):
		result[names[i]] = _stats_percentiles(values[i])
	return result


func _stats(values: Array) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var sorted: Array = values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in values: total += float(value)
	return {"mean": total / float(values.size()), "p95": sorted[clampi(ceili(values.size() * 0.95) - 1, 0, values.size() - 1)], "max": sorted.back()}


func _source_contract(state: Dictionary) -> Dictionary:
	var coast: Dictionary = state.get("coastal_runtime", {})
	return {"Production_shader": "ocean_surface.gdshader vertex(): Coastal affects LONG only; MID/SHORT are added after it",
		"formula": "mix(LONG(q), LONG(warp.xy), field.a*smoothstep(0,detj_safe,warp.z)*warp.w); then Y *= mix(1,field.g,confidence)",
		"textures": {"field": "RGBA32F: phase_offset, shoaling_scale, local_k, valid_mask", "warp": "RGBA32F: deep_x, deep_z, detJ, valid_mask"},
		"geometry_channels": "field.g/field.a and warp.rgba; metrics/phase/separate jacobian texture do not enter vertex displacement",
		"filters": {"field": "repeat_disable + filter_linear, RGBA32F", "warp": "repeat_disable + filter_linear, RGBA32F",
			"metrics": "RGBA32F, not consumed by vertex geometry", "phase": "RGBA32F, not consumed by vertex geometry",
			"jacobian": "RGBA32F, not consumed by vertex geometry"},
		"field_origin": _bake_snapshot["field_origin"], "field_extent": _bake_snapshot["field_extent"],
		"field_resolution": _bake_snapshot["field_resolution"], "warp_origin": _bake_snapshot["warp_origin"],
		"warp_extent": _bake_snapshot["warp_extent"], "warp_resolution": _bake_snapshot["warp_resolution"],
		"detj_safe": _bake_snapshot["detj_safe"], "runtime_generation": _bake_snapshot["generation"],
		"active": bool(_bake_snapshot.get("active", false)), "GPU_readback": "none; CPU bake arrays copied into native once"}


func _classify() -> String:
	const MANUAL_BILINEAR_ROUNDOFF_ENVELOPE_M := 6.103515625e-5
	var packet: Dictionary = _report.get("interior_64", {})
	var scan: Dictionary = _report.get("hardware_filter_geometry_scan_8192", {})
	var errors_ok := bool(packet.get("valid", false)) and bool(scan.get("valid", false))
	var fallback: Dictionary = _report.get("open_ocean_fallback", {})
	var inversion: Dictionary = _report.get("world_xz", {})
	var batch: Dictionary = _report.get("batch", {})
	var moving: Dictionary = _report.get("moving_packet", {})
	var continuous_packet: Dictionary = packet
	var matched_ok := float(continuous_packet.get("production_gpu_coastal_long_vs_native_lattice_interpolation_vector", {}).get("max", 1.0)) < 0.002 \
		and float(continuous_packet.get("production_gpu_combined_vs_native_lattice_interpolation_vector", {}).get("max", 1.0)) < 0.002
	var border: Dictionary = _report.get("boundaries_16", {})
	var moving_packet: Dictionary = moving.get("packet", {})
	matched_ok = matched_ok and float(border.get("production_gpu_combined_vs_native_lattice_interpolation_vector", {}).get("max", 1.0)) < 0.002 \
		and float(moving_packet.get("production_gpu_combined_vs_native_lattice_interpolation_vector", {}).get("max", 1.0)) < 0.002
	var deterministic_scan: Dictionary = scan.get("manual_field_warp_and_fft_vs_native_vector_error", {})
	var confidence: Dictionary = scan.get("confidence_buckets", {})
	var high_confidence: Dictionary = confidence.get("over_0_5", {})
	var very_high_confidence: Dictionary = confidence.get("over_0_9", {})
	matched_ok = matched_ok and int(high_confidence.get("samples", 0)) > 0 \
		and int(very_high_confidence.get("samples", 0)) > 0 \
		and float(deterministic_scan.get("max", 1.0)) <= MANUAL_BILINEAR_ROUNDOFF_ENVELOPE_M \
		and float(high_confidence.get("manual_coastal_and_fft_final_mean_p95_max", {}).get("max", 1.0)) <= MANUAL_BILINEAR_ROUNDOFF_ENVELOPE_M \
		and float(very_high_confidence.get("manual_coastal_and_fft_final_mean_p95_max", {}).get("max", 1.0)) <= MANUAL_BILINEAR_ROUNDOFF_ENVELOPE_M
	var fallback_ok := float(fallback.get("native_coastal_enabled_vs_PHYS2_open", {}).get("max", 1.0)) == 0.0
	var batch_ok := float(batch.get("material_scalar_vs_batch_m", {}).get("max", 1.0)) < 1.0e-8 \
		and float(batch.get("world_scalar_vs_batch_m", {}).get("max", 1.0)) < 1.0e-8
	var normal_ok := float(_report.get("normals", {}).get("normal_error", {}).get("max", 1.0)) < 0.01
	var clock: Dictionary = _report.get("clock", {})
	var clock_ok := bool(clock.get("one_x_advances", false)) and bool(clock.get("zero_x_freezes", false)) \
		and bool(clock.get("resume_advances", false))
	if errors_ok and matched_ok and fallback_ok and batch_ok and normal_ok and clock_ok \
			and bool(moving.get("time_association_valid", false)):
		if int(inversion.get("failures", 99)) > 0:
			return "PHYS-3-B-INVERSION"
		return "PHYS-3-A"
	return "PHYS-3-B"


func _fail(message: String) -> void:
	_report["fatal"] = message
	_report["result"] = "PHYS-3-B-HARNESS"
	print("PHYS3_COASTAL_REPORT ", JSON.stringify(_report, "\t"))
	printerr("PHYS3_COASTAL_FAILURE: ", message)
	quit(1)
