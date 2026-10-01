extends SceneTree
## PHYS-OPT-2A synchronous CPU FFT mirror lattice smoke test. This runner uses
## retained Production H0 snapshots and compares the new field to the direct
## spectral oracle. It does not read back GPU textures.

const OCEAN_SCENE: PackedScene = preload("res://addons/ocean/ocean.tscn")
const ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const COASTAL_BAKE: Resource = preload("res://validation/p4_paradise/coastal_bake.tres")
const DESCRIPTOR := "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"
const BAND_NAMES := ["LONG", "MID", "SHORT"]
const BAND_MASKS := [1, 2, 4]
const GPU_PROBE_SCRIPT = preload("res://validation/physics/phys1_gpu_probe.gd")
const GPU_PROBE_SHADER := "res://validation/physics/phys1_gpu_probe.glsl"
const GPU_LINEAR_PROBE_SCRIPT = preload("res://validation/physics/phys1_gpu_linear_probe.gd")
const GPU_LINEAR_PROBE_SHADER := "res://validation/physics/phys1_gpu_linear_probe.glsl"

signal _probe_initialized(success: bool, error: String)
signal _probe_completed(request: Dictionary, bytes: PackedByteArray, error: String)
signal _linear_probe_initialized(success: bool, error: String)
signal _linear_probe_completed(request: Dictionary, bytes: PackedByteArray, error: String)

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if load(DESCRIPTOR) == null or not ClassDB.class_exists("OceanQueryNative"):
		_fail("native extension unavailable")
		return
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("long_enabled", true)
	ocean.set("mid_enabled", true)
	ocean.set("short_enabled", true)
	ocean.set("coastal_bake", COASTAL_BAKE)
	ocean.set("coastal", true)
	ocean.set("breakers", false)
	ocean.set("crest_foam", false)
	ocean.set("surface_foam", false)
	root.add_child(ocean)
	for _frame in range(5):
		await RenderingServer.frame_post_draw
	ocean.set("wave_speed_multiplier", 0.0)
	for _frame in range(4):
		await RenderingServer.frame_post_draw
	var fft: Node = ocean.get_node_or_null("OpenOceanFFT")
	if fft == null:
		_fail("OpenOceanFFT missing")
		return
	var snapshots: Array[Dictionary] = fft.call("get_phys2_band_spectrum_snapshots")
	var coastal_snapshot: Dictionary = fft.call("get_phys3_coastal_snapshot")
	if snapshots.size() != 3:
		_fail("Production did not publish all three spectra")
		return
	if coastal_snapshot.is_empty() or not bool(coastal_snapshot.get("active", false)):
		_fail("Production Coastal bake is not active")
		return
	var wave_time := float(ocean.call("get_wave_time"))
	var gpu_shader := load(GPU_PROBE_SHADER) as RDShaderFile
	var gpu_linear_shader := load(GPU_LINEAR_PROBE_SHADER) as RDShaderFile
	if gpu_shader == null or gpu_linear_shader == null:
		_fail("Production lattice probe shader is unavailable")
		return
	var results: Array[Dictionary] = []
	var tables: Array[Dictionary] = []
	var band_natives: Array[Object] = []
	for band in 3:
		var native: Object = ClassDB.instantiate("OceanQueryNative")
		var configured: Dictionary = ADAPTER.configure_bands(native, snapshots, float(ocean.get("sea_level")), BAND_MASKS[band])
		if not bool(configured.get("ok", false)):
			_fail("setup failed for %s: %s" % [BAND_NAMES[band], configured])
			return
		band_natives.append(native)
		var start := Time.get_ticks_usec()
		if not bool(native.call("build_dynamic_physics_fields", wave_time)):
			_fail("CPU FFT build failed for %s" % BAND_NAMES[band])
			return
		var build_us := Time.get_ticks_usec() - start
		var n := int(snapshots[band]["resolution"])
		var l := float(snapshots[band]["domain_size_m"])
		var errors: Array[Array] = []
		var lattice_texels := PackedVector2Array()
		var x_errors: Array[float] = []
		var y_errors: Array[float] = []
		var z_errors: Array[float] = []
		var vy_errors: Array[float] = []
		var vx_errors: Array[float] = []
		var vz_errors: Array[float] = []
		var max_normal_angle := 0.0
		var max_jacobian_error := 0.0
		# Sixty-four deterministic lattice nodes spread over the periodic domain.
		for sample_index in 64:
			var ix := posmod(sample_index * 47 + 3, n)
			var iy := posmod(sample_index * 83 + 11, n)
			lattice_texels.append(Vector2(ix, iy))
			var q := Vector2((float(ix) + 0.5) / n * l - 0.5 * l,
				(float(iy) + 0.5) / n * l - 0.5 * l)
			var direct: PackedFloat64Array = native.call("sample_material_q", q.x, q.y, wave_time)
			var mirror: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band, q.x, q.y)
			if direct.size() < 15 or mirror.size() != 12:
				_fail("invalid sample result for %s" % BAND_NAMES[band])
				return
			var comparable := [
				[mirror[0], direct[3]], [mirror[1], direct[2]], [mirror[2], direct[4]],
				[mirror[9], direct[9]], [mirror[10], direct[8]], [mirror[11], direct[10]],
			]
			var row: Array[float] = []
			for pair: Array in comparable:
				row.append(abs(float(pair[0]) - float(pair[1])))
			errors.append(row)
			y_errors.append(row[0]); x_errors.append(row[1]); z_errors.append(row[2])
			vy_errors.append(row[3]); vx_errors.append(row[4]); vz_errors.append(row[5])
			var nx := mirror[4] * mirror[7] - (1.0 + mirror[8]) * mirror[3]
			var ny := (1.0 + mirror[8]) * (1.0 + mirror[5]) - mirror[6] * mirror[7]
			var nz := mirror[6] * mirror[3] - mirror[4] * (1.0 + mirror[5])
			var normal_length := sqrt(nx * nx + ny * ny + nz * nz)
			if normal_length > 1.0e-12:
				var dot_value := clampf((nx * direct[5] + ny * direct[6] + nz * direct[7]) / normal_length, -1.0, 1.0)
				max_normal_angle = maxf(max_normal_angle, acos(dot_value))
			var jacobian := (1.0 + mirror[5]) * (1.0 + mirror[8]) - mirror[6] * mirror[7]
			max_jacobian_error = maxf(max_jacobian_error, abs(jacobian - direct[11]))
		var max_height := 0.0
		var max_dx := 0.0
		var max_dz := 0.0
		var max_vy := 0.0
		var max_vx := 0.0
		var max_vz := 0.0
		for row in errors:
			max_height = maxf(max_height, row[0])
			max_dx = maxf(max_dx, row[1])
			max_dz = maxf(max_dz, row[2])
			max_vy = maxf(max_vy, row[3])
			max_vx = maxf(max_vx, row[4])
			max_vz = maxf(max_vz, row[5])
		var dynamic_info: PackedInt64Array = native.call("get_dynamic_field_info")
		var probe: RefCounted = GPU_PROBE_SCRIPT.new()
		RenderingServer.call_on_render_thread(probe.initialize.bind(self, snapshots[band]["displacement_rid"], gpu_shader))
		var init_result: Array = await _probe_initialized
		if not bool(init_result[0]):
			_fail("GPU probe init failed for %s: %s" % [BAND_NAMES[band], init_result[1]])
			return
		var request := {"band": BAND_NAMES[band], "id": band, "wave_time": wave_time}
		RenderingServer.call_on_render_thread(probe.dispatch_request.bind(request, lattice_texels))
		var packet: Array = await _probe_completed
		probe.call("shutdown")
		if not String(packet[2]).is_empty():
			_fail("GPU lattice packet failed: " + String(packet[2]))
			return
		var gpu_bytes: PackedByteArray = packet[1]
		var gpu_max_error := 0.0
		for sample_index in lattice_texels.size():
			var qx := (lattice_texels[sample_index].x + 0.5) / n * l - 0.5 * l
			var qz := (lattice_texels[sample_index].y + 0.5) / n * l - 0.5 * l
			var mirror: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band, qx, qz)
			for channel in 3:
				var gpu_value := gpu_bytes.decode_float(sample_index * 16 + channel * 4)
				var mirror_value := mirror[1] if channel == 0 else (mirror[0] if channel == 1 else mirror[2])
				gpu_max_error = maxf(gpu_max_error, absf(gpu_value - mirror_value))
		var linear_probe: RefCounted = GPU_LINEAR_PROBE_SCRIPT.new()
		RenderingServer.call_on_render_thread(linear_probe.initialize.bind(self, snapshots[band]["displacement_rid"], gpu_linear_shader))
		var linear_init_result: Array = await _linear_probe_initialized
		if not bool(linear_init_result[0]):
			_fail("GPU filtered probe init failed for %s: %s" % [BAND_NAMES[band], linear_init_result[1]])
			return
		var off_grid_uvs := PackedVector2Array()
		var off_grid_qs: Array[Vector2] = []
		for sample_index in 64:
			var uv := Vector2(fposmod(float(sample_index * 37) / n + 0.173, 1.0),
				fposmod(float(sample_index * 61) / n + 0.391, 1.0))
			off_grid_uvs.append(uv)
			off_grid_qs.append((uv - Vector2(0.5, 0.5)) * l)
		RenderingServer.call_on_render_thread(linear_probe.dispatch_request.bind(request, off_grid_uvs))
		var linear_packet: Array = await _linear_probe_completed
		linear_probe.call("shutdown")
		if not String(linear_packet[2]).is_empty():
			_fail("GPU filtered packet failed: " + String(linear_packet[2]))
			return
		var linear_bytes: PackedByteArray = linear_packet[1]
		var rendered_errors: Array[float] = []
		for sample_index in off_grid_qs.size():
			var mirror: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band,
				off_grid_qs[sample_index].x, off_grid_qs[sample_index].y)
			var gx := linear_bytes.decode_float(sample_index * 16)
			var gy := linear_bytes.decode_float(sample_index * 16 + 4)
			var gz := linear_bytes.decode_float(sample_index * 16 + 8)
			rendered_errors.append(Vector3(mirror[1] - gx, mirror[0] - gy, mirror[2] - gz).length())
		results.append({"band": BAND_NAMES[band], "N": n, "L": l,
			"samples": errors.size(), "build_ms": float(build_us) / 1000.0,
			"max_height_error_m": max_height, "max_dx_error_m": max_dx,
			"max_dz_error_m": max_dz, "max_vertical_velocity_error_mps": max_vy,
			"max_velocity_x_error_mps": max_vx, "max_velocity_z_error_mps": max_vz,
			"grid_component_stats": {"X": _statistics(x_errors), "Y": _statistics(y_errors), "Z": _statistics(z_errors),
				"Vx": _statistics(vx_errors), "Vy": _statistics(vy_errors), "Vz": _statistics(vz_errors)},
			"max_normal_angle_rad": max_normal_angle, "max_jacobian_error": max_jacobian_error,
			"gpu_lattice_displacement_max_error_m": gpu_max_error,
			"off_grid_vs_hardware_filtered_stats_m": _statistics(rendered_errors),
			"field_memory_bytes": int(dynamic_info[3])})
		# Verify off-grid sampling is a stable periodic field lookup.
		var q0 := Vector2(-0.173 * l, 0.291 * l)
		var qwrap := q0 + Vector2(l * 3.0, -l * 2.0)
		var a: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band, q0.x, q0.y)
		var b: PackedFloat64Array = native.call("sample_dynamic_band_material_q", band, qwrap.x, qwrap.y)
		tables.append({"band": BAND_NAMES[band], "periodic_wrap_max_error": _max_delta(a, b)})
	var combined: Object = ClassDB.instantiate("OceanQueryNative")
	var combined_setup: Dictionary = ADAPTER.configure_bands(combined, snapshots, float(ocean.get("sea_level")), 7)
	if not bool(combined_setup.get("ok", false)):
		_fail("combined setup failed")
		return
	var coastal_setup: Dictionary = ADAPTER.configure_coastal(combined, coastal_snapshot)
	if not bool(coastal_setup.get("ok", false)):
		_fail("combined Coastal snapshot setup failed")
		return
	var combined_start := Time.get_ticks_usec()
	if not bool(combined.call("build_dynamic_physics_fields", wave_time)):
		_fail("combined CPU FFT build failed")
		return
	var combined_build_us := Time.get_ticks_usec() - combined_start
	var phase_recurrence_flat: PackedFloat64Array = combined.call("get_dynamic_phase_recurrence_errors", 0.0, 1.0 / 60.0)
	var phase_recurrence_errors: Array[Dictionary] = []
	for band in 3:
		phase_recurrence_errors.append({"band": BAND_NAMES[band], "H_mode_abs_error_m": [
			phase_recurrence_flat[band * 4], phase_recurrence_flat[band * 4 + 1],
			phase_recurrence_flat[band * 4 + 2], phase_recurrence_flat[band * 4 + 3]]})
	var worker_scaling: Array[Dictionary] = []
	var benchmark_wave_time := wave_time
	for worker_count in range(1, 7):
		var configured_workers := int(combined.call("set_dynamic_worker_count", worker_count))
		for _warmup in range(2):
			benchmark_wave_time += 1.0 / 60.0
			if not bool(combined.call("build_dynamic_physics_fields", benchmark_wave_time)):
				_fail("worker-count warmup build failed")
				return
		var snapshot_times_ms: Array[float] = []
		for _sample in range(12):
			benchmark_wave_time += 1.0 / 60.0
			var snapshot_start := Time.get_ticks_usec()
			if not bool(combined.call("build_dynamic_physics_fields", benchmark_wave_time)):
				_fail("worker-count timed build failed")
				return
			snapshot_times_ms.append(float(Time.get_ticks_usec() - snapshot_start) / 1000.0)
		worker_scaling.append({"workers": configured_workers,
			"snapshots": snapshot_times_ms.size(), "wall_ms": _statistics(snapshot_times_ms)})
	combined.call("set_dynamic_worker_count", 6)
	if not bool(combined.call("build_dynamic_physics_fields", wave_time)):
		_fail("restore-time dynamic build failed")
		return
	var stage_profile: PackedInt64Array = combined.call("get_dynamic_stage_profile_us")
	var combined_build_profile: PackedFloat64Array = combined.call("get_dynamic_build_profile_us")
	var query_benchmarks: Array[Dictionary] = []
	for query_count in [4, 16, 64, 256]:
		var points := PackedVector3Array()
		for query_index in query_count:
			points.append(Vector3((float(query_index) * 13.71) - 200.0, 0.0, (float(query_index) * -9.31) + 80.0))
		var query_start := Time.get_ticks_usec()
		var batch: PackedFloat64Array = combined.call("sample_dynamic_material_q_batch", points)
		var elapsed := Time.get_ticks_usec() - query_start
		var scalar_match := true
		for check_index in mini(query_count, 4):
			var scalar: PackedFloat64Array = combined.call("sample_dynamic_material_q", points[check_index].x, points[check_index].z)
			for field in 15:
				if absf(batch[check_index * 15 + field] - scalar[field]) > 1.0e-12:
					scalar_match = false
		query_benchmarks.append({"queries": query_count, "batch_total_ms": float(elapsed) / 1000.0,
			"ms_per_query": float(elapsed) / 1000.0 / query_count, "scalar_batch_match": scalar_match})
	var world_targets := PackedVector3Array()
	var world_material_q := PackedVector3Array()
	for query_index in 64:
		var material_q: Vector2
		if query_index < 32:
			var origin: Vector2 = coastal_snapshot["field_origin"]
			var extent: Vector2 = coastal_snapshot["field_extent"]
			material_q = origin + Vector2(extent.x * (0.12 + float(query_index % 8) * 0.10),
				extent.y * (0.10 + float(query_index / 8) * 0.18))
		else:
			material_q = Vector2(float(query_index * 19) - 900.0, float(query_index * -11) + 700.0)
		var surface: PackedFloat64Array = combined.call("sample_dynamic_material_q", material_q.x, material_q.y)
		world_targets.append(Vector3(material_q.x + surface[2], 0.0, material_q.y + surface[4]))
		world_material_q.append(Vector3(material_q.x, 0.0, material_q.y))
	var world_start := Time.get_ticks_usec()
	var world_batch: PackedFloat64Array = combined.call("sample_dynamic_world_batch", world_targets, PackedVector3Array(), false)
	var world_elapsed_us := Time.get_ticks_usec() - world_start
	var world_failures := 0
	var world_residuals: Array[float] = []
	var world_q_errors: Array[float] = []
	var world_q_outliers: Array[Dictionary] = []
	var world_scalar_batch_match := true
	for query_index in 64:
		var offset := query_index * 17
		world_residuals.append(world_batch[offset + 13])
		world_q_errors.append(Vector2(world_batch[offset + 15] - world_material_q[query_index].x,
			world_batch[offset + 16] - world_material_q[query_index].z).length())
		if world_q_errors[-1] > 0.05:
			var target_outlier := world_targets[query_index]
			var oracle_world: PackedFloat64Array = combined.call("sample_world_with_material_q",
				target_outlier.x, target_outlier.z, wave_time)
			world_q_outliers.append({"index": query_index, "source_q": world_material_q[query_index],
				"target_xz": Vector2(target_outlier.x, target_outlier.z),
				"mirror_q": Vector2(world_batch[offset + 15], world_batch[offset + 16]),
				"mirror_q_error_m": world_q_errors[-1], "mirror_residual_m": world_batch[offset + 13],
				"mirror_iterations": world_batch[offset + 14],
				"direct_oracle_q": Vector2(oracle_world[15], oracle_world[16]),
				"direct_oracle_residual_m": oracle_world[13],
				"direct_q_error_from_source_m": Vector2(oracle_world[15] - world_material_q[query_index].x,
					oracle_world[16] - world_material_q[query_index].z).length()})
		if world_batch[offset] < 0.5:
			world_failures += 1
		if query_index < 4:
			var target := world_targets[query_index]
			var scalar_world: PackedFloat64Array = combined.call("sample_dynamic_world", target.x, target.z, 0.0, 0.0, false)
			for field in 17:
				if absf(world_batch[offset + field] - scalar_world[field]) > 1.0e-12:
					world_scalar_batch_match = false
	var direct_errors: Array[float] = []
	var direct_velocity_errors: Array[float] = []
	for sample_index in 16:
		var q := Vector2((float(sample_index) * 31.773) - 230.0, (float(sample_index) * -15.319) + 90.0)
		var direct: PackedFloat64Array = combined.call("sample_material_q", q.x, q.y, wave_time)
		var mirror: PackedFloat64Array = combined.call("sample_dynamic_material_q", q.x, q.y)
		direct_errors.append(Vector3(mirror[2] - direct[2], mirror[3] - direct[3], mirror[4] - direct[4]).length())
		direct_velocity_errors.append(Vector3(mirror[8] - direct[8], mirror[9] - direct[9], mirror[10] - direct[10]).length())
	var dynamic_info: PackedInt64Array = combined.call("get_dynamic_field_info")
	var clock_t0 := float(ocean.call("get_wave_time"))
	ocean.set("wave_speed_multiplier", 1.0)
	for _frame in range(4): await RenderingServer.frame_post_draw
	var clock_t1 := float(ocean.call("get_wave_time"))
	var moving_native: Object = band_natives[0]
	var moving_build_ok := bool(moving_native.call("build_dynamic_physics_fields", clock_t1))
	var moving_query: PackedFloat64Array = moving_native.call("sample_dynamic_band_material_q", 0, 21.0, -37.0)
	var moving_oracle: PackedFloat64Array = moving_native.call("sample_material_q", 21.0, -37.0, clock_t1)
	var moving_lattice_error := Vector3(moving_query[1] - moving_oracle[2],
		moving_query[0] - moving_oracle[3], moving_query[2] - moving_oracle[4]).length()
	ocean.set("wave_speed_multiplier", 0.0)
	for _frame in range(4): await RenderingServer.frame_post_draw
	var clock_frozen_0 := float(ocean.call("get_wave_time"))
	for _frame in range(3): await RenderingServer.frame_post_draw
	var clock_frozen_1 := float(ocean.call("get_wave_time"))
	var frozen_build_ok := bool(moving_native.call("build_dynamic_physics_fields", clock_frozen_1))
	ocean.set("wave_speed_multiplier", 1.0)
	for _frame in range(4): await RenderingServer.frame_post_draw
	var clock_resume := float(ocean.call("get_wave_time"))
	var resume_build_ok := bool(moving_native.call("build_dynamic_physics_fields", clock_resume))
	print("PHYS_OPT_2A_FFT_MIRROR=" + JSON.stringify({"wave_time": wave_time,
		"bands": results, "periodic": tables, "ifft_transforms_per_band": 6,
		"combined_sync_build_ms": float(combined_build_us) / 1000.0,
		"combined_per_band_build_us": combined_build_profile,
		"stage_profile_us_long_mid_short_evolution_fft_total": stage_profile,
		"worker_scaling_repeated_warm_snapshots": worker_scaling,
		"worker_count_after_benchmark": int(combined.call("get_dynamic_worker_count")),
		"phase_recurrence_H_mode_abs_error_m_frames_1_60_600_3600": phase_recurrence_errors,
		"combined_query_benchmarks": query_benchmarks,
		"world_inversion": {"samples": 64, "failures": world_failures,
			"batch_ms": float(world_elapsed_us) / 1000.0, "scalar_batch_match": world_scalar_batch_match,
			"residual_max_m": _max_value(world_residuals), "q_recovery_max_m": _max_value(world_q_errors),
			"iterations_max": _max_world_iterations(world_batch), "q_outliers": world_q_outliers},
		"production_clock": {"t0": clock_t0, "moving_t1": clock_t1,
			"frozen_t0": clock_frozen_0, "frozen_t1": clock_frozen_1, "resumed": clock_resume,
			"moving_build_ok": moving_build_ok, "frozen_build_ok": frozen_build_ok,
			"resume_build_ok": resume_build_ok, "moving_material_q_error_m": moving_lattice_error,
			"native_time_us": int(moving_native.call("get_dynamic_field_info")[5])},
		"combined_memory_bytes": int(dynamic_info[3]),
		"off_grid_continuous_oracle_displacement_max_m": _max_value(direct_errors),
		"off_grid_continuous_oracle_velocity_max_mps": _max_value(direct_velocity_errors),
		"source": "same final Production H0 retained in OceanQueryNative direct Cascade",
		"coastal_setup": coastal_setup,
		"gpu_readback": false, "coastal_included": true}))
	quit(0)

func _max_delta(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var maximum := 0.0
	for i in mini(a.size(), b.size()):
		maximum = maxf(maximum, abs(a[i] - b[i]))
	return maximum

func _max_value(values: Array[float]) -> float:
	var maximum := 0.0
	for value in values:
		maximum = maxf(maximum, value)
	return maximum

func _max_world_iterations(values: PackedFloat64Array) -> int:
	var maximum := 0
	for index in 64:
		maximum = maxi(maximum, int(values[index * 17 + 14]))
	return maximum

func _statistics(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var sorted: Array = values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted: total += value
	var middle := int(sorted.size() / 2)
	var median: float = sorted[middle] if sorted.size() % 2 == 1 else (sorted[middle - 1] + sorted[middle]) * 0.5
	return {"mean": total / sorted.size(), "median": median,
		"p95": sorted[mini(sorted.size() - 1, ceili(sorted.size() * 0.95))], "max": sorted[-1]}

func _on_gpu_probe_initialized(success: bool, error: String) -> void:
	_probe_initialized.emit(success, error)

func _on_gpu_probe_readback(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	_probe_completed.emit(request, bytes, error)

func _on_linear_probe_initialized(success: bool, error: String) -> void:
	_linear_probe_initialized.emit(success, error)

func _on_linear_probe_readback(request: Dictionary, bytes: PackedByteArray, error: String) -> void:
	_linear_probe_completed.emit(request, bytes, error)

func _fail(message: String) -> void:
	printerr("PHYS_OPT_2A_FFT_MIRROR_FAIL=" + message)
	quit(1)
