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
	var async_results := await _run_async_publication_suite(ocean, combined, snapshots)
	if not bool(async_results.get("passed", false)):
		_fail("PHYS-OPT-2C asynchronous suite failed: %s" % JSON.stringify(async_results))
		return
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
		"async_publication": async_results,
		"combined_memory_bytes": int(dynamic_info[3]),
		"off_grid_continuous_oracle_displacement_max_m": _max_value(direct_errors),
		"off_grid_continuous_oracle_velocity_max_mps": _max_value(direct_velocity_errors),
		"source": "same final Production H0 retained in OceanQueryNative direct Cascade",
		"coastal_setup": coastal_setup,
		"gpu_readback": false, "coastal_included": true}))
	quit(0)

func _run_async_publication_suite(ocean: Node, native: Object, snapshots: Array[Dictionary]) -> Dictionary:
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 6: await physics_frame
	var initial_time := float(ocean.call("get_wave_time"))
	if not bool(native.call("start_dynamic_async_fields", initial_time, 0)):
		return {"passed": false, "error": "async publisher initialization failed"}
	var build_id := String(native.call("get_dynamic_async_build_id"))
	if build_id != "PHYS-OPT-2E-packed-avx-twiddle-v2":
		return {"passed": false, "error": "stale native DLL", "build_id": build_id}
	var initial_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	if initial_info.size() != 5 or initial_info[0] != 1:
		return {"passed": false, "error": "initial immutable snapshot is invalid"}

	var matrix: Array[Dictionary] = []
	var chosen_candidates: Array[Dictionary] = []
	var tick_id := 0
	var forced_query_failures := 0
	for worker_count in [2, 3, 4, 5, 6]:
		var drained_tick := await _drain_and_set_workers(ocean, native, worker_count, tick_id)
		if drained_tick < 0:
			return {"passed": false, "error": "worker pool did not become idle", "workers": worker_count}
		tick_id = drained_tick
		ocean.set("wave_speed_multiplier", 1.0)
		var run := await _run_async_window(ocean, native, worker_count, 0, 3600, tick_id)
		tick_id = int(run.get("tick_end", tick_id))
		if not bool(run.get("queries_ok", false)):
			forced_query_failures += 1
		if not bool(run.get("band_times_consistent", false)):
			return {"passed": false, "error": "published snapshot contains mixed band times", "run": run}
		run["worker_count"] = worker_count
		matrix.append(run)
		chosen_candidates.append(run)
		print("PHYS_OPT_2D_WORKER_3600=" + JSON.stringify(run))
		ocean.set("wave_speed_multiplier", 0.0)
		for _i in 3: await physics_frame

	chosen_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var am := int(a.get("missed_deadlines", 0))
		var bm := int(b.get("missed_deadlines", 0))
		if am != bm: return am < bm
		var ap := float(a.get("field_age_ticks", {}).get("p99", 1.0e9))
		var bp := float(b.get("field_age_ticks", {}).get("p99", 1.0e9))
		if ap != bp: return ap < bp
		var ax := float(a.get("field_age_ticks", {}).get("max", 1.0e9))
		var bx := float(b.get("field_age_ticks", {}).get("max", 1.0e9))
		if ax != bx: return ax < bx
		return int(a.get("worker_count", 0)) < int(b.get("worker_count", 0)))
	var selected_workers := int(chosen_candidates[0].get("worker_count", 4)) if not chosen_candidates.is_empty() else 4
	var sustained: Dictionary = chosen_candidates[0] if not chosen_candidates.is_empty() else {}
	var load_runs: Array[Dictionary] = []
	for contention_ms in [2, 4]:
		var load_drain := await _drain_and_set_workers(ocean, native, selected_workers, tick_id)
		if load_drain < 0: return {"passed": false, "error": "worker pool did not drain before load test"}
		tick_id = load_drain
		ocean.set("wave_speed_multiplier", 1.0)
		var loaded := await _run_async_window(ocean, native, selected_workers, contention_ms, 3600, tick_id)
		tick_id = int(loaded.get("tick_end", tick_id))
		loaded["worker_count"] = selected_workers
		load_runs.append(loaded)
		print("PHYS_OPT_2D_LOAD_3600=" + JSON.stringify(loaded))
		ocean.set("wave_speed_multiplier", 0.0)
		for _i in 3: await physics_frame
	var long_drain := await _drain_and_set_workers(ocean, native, selected_workers, tick_id)
	if long_drain < 0: return {"passed": false, "error": "worker pool did not drain before long run"}
	tick_id = long_drain
	ocean.set("wave_speed_multiplier", 1.0)
	var long_run := await _run_async_window(ocean, native, selected_workers, 0, 10000, tick_id)
	tick_id = int(long_run.get("tick_end", tick_id))
	print("PHYS_OPT_2D_SUSTAINED_10000=" + JSON.stringify(long_run))

	var scale_runs: Array[Dictionary] = []
	for rate in [0.5, 1.0, 2.0, 3.0]:
		ocean.set("wave_speed_multiplier", rate)
		var scale_run := await _run_async_window(ocean, native, selected_workers, 0, 60, tick_id)
		tick_id = int(scale_run.get("tick_end", tick_id))
		scale_run["rate"] = rate
		scale_runs.append(scale_run)
	# Freeze for 30 physics ticks and prove neither Production nor the native
	# published simulation time advances; resume from the same Production clock.
	ocean.set("wave_speed_multiplier", 0.0)
	var freeze_ocean_before := float(ocean.call("get_wave_time"))
	var freeze_snapshot_before: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	for _i in 30:
		await physics_frame
		tick_id += 1
		var frozen_now := float(ocean.call("get_wave_time"))
		native.call("advance_dynamic_async", tick_id, frozen_now, frozen_now, 1.0 / 60.0)
	var freeze_ocean_after := float(ocean.call("get_wave_time"))
	var freeze_snapshot_after: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	var frozen_ok := absf(freeze_ocean_after - freeze_ocean_before) <= 1.0e-8 and \
		freeze_snapshot_before[1] == freeze_snapshot_after[1]
	ocean.set("wave_speed_multiplier", 1.0)
	var resume_run := await _run_async_window(ocean, native, selected_workers, 0, 120, tick_id)
	tick_id = int(resume_run.get("tick_end", tick_id))
	var config_changes := await _run_async_config_change_probe(ocean, native, snapshots, tick_id)
	var final_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	var final_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
	var final_band_times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
	var wait_p95_ok := true
	for run in matrix:
		wait_p95_ok = wait_p95_ok and float(run["main_wait_us"]["p95"]) < 100.0
	wait_p95_ok = wait_p95_ok and float(sustained.get("main_wait_us", {}).get("p95", 1.0e9)) < 100.0
	for run in load_runs:
		wait_p95_ok = wait_p95_ok and float(run["main_wait_us"]["p95"]) < 100.0
	var freshness_ok := true
	var freshness_runs: Array[Dictionary] = matrix.duplicate()
	freshness_runs.append_array(load_runs)
	freshness_runs.append(long_run)
	for run in freshness_runs:
		var ages: Dictionary = run.get("field_age_ticks", {})
		freshness_ok = freshness_ok and float(ages.get("p95", 1.0e9)) <= 1.0 and \
			float(ages.get("p99", 1.0e9)) <= 1.0 and float(ages.get("max", 1.0e9)) <= 2.0
	var summary_passed := forced_query_failures == 0 and frozen_ok and final_band_times.size() == 3 and \
		final_band_times[0] == final_band_times[1] and final_band_times[1] == final_band_times[2] and freshness_ok and \
		int(final_stats[10]) <= 2 and int(final_info[0]) == 1 and wait_p95_ok and \
		bool(config_changes.get("passed", false)) and \
		float(final_stats[13]) / maxf(float(final_stats[0]), 1.0) < 50.0
	return {"passed": summary_passed, "build_id": build_id, "worker_sustained_3600_ticks": matrix,
		"selected_worker_count": selected_workers, "selected_worker_sustained_3600_ticks": sustained,
		"selected_worker_main_load_3600_ticks": load_runs, "selected_worker_sustained_10000_ticks": long_run,
		"simulation_rate_windows_60_ticks": scale_runs, "configuration_change_probe": config_changes, "freeze": {
			"ocean_time_before": freeze_ocean_before, "ocean_time_after": freeze_ocean_after,
			"native_time_ns_before": freeze_snapshot_before[1], "native_time_ns_after": freeze_snapshot_after[1],
			"passed": frozen_ok}, "resume_120_ticks": resume_run,
		"final_stats": {"ticks": final_stats[0], "requests": final_stats[1], "builds_finished": final_stats[3],
			"publications": final_stats[4], "ready_early": final_stats[5], "ready_on_time": final_stats[6],
			"missed_deadlines": final_stats[7], "max_missed_streak": final_stats[8],
			"stale_ticks": final_stats[9], "max_age_ticks": final_stats[10],
			"discarded_obsolete": final_stats[11], "swaps": final_stats[12],
			"main_wait_total_us": final_stats[13], "main_wait_max_us": final_stats[14],
			"worker_build_total_us": final_stats[15], "worker_build_max_us": final_stats[16],
			"worker_state": final_stats[22], "coalesced_requests": final_stats[24],
			"obsolete_builds": final_stats[25], "buffer_wait_us": final_stats[26],
			"configuration_phase_resets": final_stats[33]}, "final_snapshot": final_info,
		"final_band_times_ns": final_band_times, "query_failures": forced_query_failures,
		"main_wait_mean_us": float(final_stats[13]) / maxf(float(final_stats[0]), 1.0),
		"main_wait_p95_budget_pass": wait_p95_ok, "freshness_budget_pass": freshness_ok,
		"same_production_clock": true, "gpu_readback": false}

func _drain_and_set_workers(ocean: Node, native: Object, worker_count: int, tick_id: int) -> int:
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 1200:
		await physics_frame
		tick_id += 1
		var now := float(ocean.call("get_wave_time"))
		native.call("advance_dynamic_async", tick_id, now, now, 1.0 / 60.0)
		var stats: PackedInt64Array = native.call("get_dynamic_async_stats")
		if int(stats[22]) == 0:
			if int(native.call("set_dynamic_worker_count", worker_count)) == worker_count:
				return tick_id
			return -1
	var timeout_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	push_warning("PHYS-OPT-2D drain timeout: state=%d published=%s config=%d requested=%d coalesced=%d obsolete=%d" % [
		int(timeout_stats[22]), str(native.call("get_dynamic_snapshot_info")), int(timeout_stats[21]),
		int(timeout_stats[1]), int(timeout_stats[24]), int(timeout_stats[25])])
	return -1

func _run_async_window(ocean: Node, native: Object, worker_count: int, contention_ms: int,
		tick_count: int, tick_start: int) -> Dictionary:
	var waits: Array[float] = []
	var ages: Array[float] = []
	var query_ms: Array[float] = []
	var build_ms: Array[float] = []
	var long_stage_us: Array[float] = []
	var mid_stage_us: Array[float] = []
	var short_stage_us: Array[float] = []
	var previous_build_count := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[3])
	var current_ready := 0
	var scheduled := 0
	var published := 0
	var mixed_band_times := 0
	var stats_start: PackedInt64Array = native.call("get_dynamic_async_stats")
	var missed_start: int = int(stats_start[7])
	var previous_time := float(ocean.call("get_wave_time"))
	var success := true
	for sample_index in tick_count:
		await physics_frame
		var now := float(ocean.call("get_wave_time"))
		var observed_dt := maxf(now - previous_time, 0.0)
		var tick_id := tick_start + sample_index + 1
		var result: PackedInt64Array = native.call("advance_dynamic_async", tick_id, now,
			now + observed_dt, 1.0 / 60.0)
		if result.size() < 8:
			success = false
			break
		current_ready += int(result[2])
		scheduled += int(result[1])
		published += int(result[0])
		waits.append(float(result[6]))
		ages.append(float(result[7]) / 1000000.0)
		var live_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
		if int(live_stats[3]) > previous_build_count:
			var completed_count := int(live_stats[3]) - previous_build_count
			for _build in completed_count:
				build_ms.append(float(live_stats[34]) / 1000.0)
				long_stage_us.append(float(live_stats[27] + live_stats[30]))
				mid_stage_us.append(float(live_stats[28] + live_stats[31]))
				short_stage_us.append(float(live_stats[29] + live_stats[32]))
			previous_build_count = int(live_stats[3])
		var band_times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
		if band_times.size() != 3 or band_times[0] != band_times[1] or band_times[1] != band_times[2]:
			mixed_band_times += 1
		var query_start := Time.get_ticks_usec()
		var query: PackedFloat64Array = native.call("sample_dynamic_material_q", 123.456, -78.9)
		query_ms.append(float(Time.get_ticks_usec() - query_start) / 1000.0)
		if query.size() < 15:
			success = false
		if contention_ms > 0:
			native.call("run_dynamic_contention_us", contention_ms * 1000)
		previous_time = now
	var stats_end: PackedInt64Array = native.call("get_dynamic_async_stats")
	var missed_end := int(stats_end[7])
	var build_count := int(stats_end[3] - stats_start[3])
	var build_total_delta_us := int(stats_end[15] - stats_start[15])
	var age_stale_1 := 0
	var age_stale_2 := 0
	var age_stale_3 := 0
	for age in ages:
		if age >= 1.0: age_stale_1 += 1
		if age >= 2.0: age_stale_2 += 1
		if age >= 3.0: age_stale_3 += 1
	return {"ticks": tick_count, "tick_start": tick_start + 1, "tick_end": tick_start + tick_count,
		"queries_ok": success, "band_times_consistent": mixed_band_times == 0,
		"mixed_band_time_ticks": mixed_band_times, "current_time_ready_ticks": current_ready,
		"scheduled": scheduled, "published": published, "missed_deadlines": missed_end - missed_start,
		"stale_ticks": int(stats_end[9] - stats_start[9]), "field_age_ticks": _statistics(ages),
		"stale_age_counts": {"ge_1_tick": age_stale_1, "ge_2_ticks": age_stale_2, "ge_3_ticks": age_stale_3},
		"main_wait_us": _statistics(waits),
		"worker_build_average_ms": float(build_total_delta_us) / 1000.0 / maxf(float(build_count), 1.0),
		"worker_build_count": build_count, "worker_build_ms": _statistics(build_ms),
		"stage_build_ms": {"LONG": _statistics(long_stage_us), "MID": _statistics(mid_stage_us), "SHORT": _statistics(short_stage_us)},
		"request_count": int(stats_end[1] - stats_start[1]),
		"coalesced_request_count": int(stats_end[24] - stats_start[24]),
		"obsolete_build_count": int(stats_end[25] - stats_start[25]),
		"buffer_wait_us": int(stats_end[26] - stats_start[26]),
		"query_ms": _statistics(query_ms), "worker_count": worker_count, "contention_ms": contention_ms}

func _run_async_config_change_probe(ocean: Node, native: Object, _initial_snapshots: Array[Dictionary],
		tick_id: int) -> Dictionary:
	ocean.set("wave_speed_multiplier", 0.0)
	for _i in 4: await physics_frame
	var fft: Node = ocean.get_node_or_null("OpenOceanFFT")
	if fft == null: return {"passed": false, "error": "OpenOceanFFT missing during config test"}
	var original_hs := float(ocean.get("significant_wave_height_m"))
	var original_wind := float(ocean.get("wind_speed_mps"))
	var original_direction := float(ocean.get("wind_direction_degrees"))
	var original_profile: Resource = ocean.get("wave_profile")
	var profile: Resource = original_profile.duplicate(true)
	ocean.set("wave_profile", profile)
	var initial_version := int((native.call("get_dynamic_snapshot_info") as PackedInt64Array)[3])
	var initial_time := float(ocean.call("get_wave_time"))
	var versions: Array[int] = []
	var transition_times: Array[float] = []
	var discontinuities: Array[float] = []
	var reset_counts: Array[int] = []
	var rapid_versions: Array[int] = []
	var worker_was_building := false
	var all_coherent := true
	var final_tick := tick_id
	var targets := [
		{"label": "storm_B", "hs": 3.0, "wind": 18.0, "direction": 75.0, "chop": 2.0},
		{"label": "calm_C", "hs": 0.8, "wind": 4.0, "direction": 20.0, "chop": 0.8},
	]
	for target in targets:
		var before: PackedFloat64Array = native.call("sample_material_q", 41.25, -72.5, float(ocean.call("get_wave_time")))
		ocean.set("significant_wave_height_m", float(target["hs"]))
		ocean.set("wind_speed_mps", float(target["wind"]))
		ocean.set("wind_direction_degrees", float(target["direction"]))
		var target_profile: Resource = ocean.get("wave_profile")
		var long_band: Resource = target_profile.get("long_band")
		long_band.set("choppiness", float(target["chop"]))
		var initialized := bool(ocean.call("initialize"))
		if not initialized: return {"passed": false, "error": "Production Ocean rebuild failed", "target": target}
		await RenderingServer.frame_post_draw
		fft = ocean.get_node_or_null("OpenOceanFFT")
		if fft == null: return {"passed": false, "error": "OpenOceanFFT missing after Production rebuild"}
		var live_snapshots: Array[Dictionary] = fft.call("get_phys2_band_spectrum_snapshots")
		if live_snapshots.size() != 3: return {"passed": false, "error": "Production did not expose all bands after rebuild"}
		for band in 3:
			var configured: Dictionary = ADAPTER._configure_band(native, live_snapshots[band], band)
			if not bool(configured.get("ok", false)):
				return {"passed": false, "error": "native spectrum update failed", "band": band, "details": configured}
		native.call("finalize_spectrum")
		var wanted_version := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
		versions.append(wanted_version)
		var now := float(ocean.call("get_wave_time"))
		transition_times.append(now)
		var after: PackedFloat64Array = native.call("sample_material_q", 41.25, -72.5, now)
		var delta := 0.0
		if before.size() > 3 and after.size() > 3:
			delta = Vector3(after[1] - before[1], after[0] - before[0], after[2] - before[2]).length()
		discontinuities.append(delta)
		# Request current frozen time; config updates must rebuild the complete
		# LONG/MID/SHORT snapshot before any query can observe the new version.
		for _wait in 1200:
			await physics_frame
			final_tick += 1
			now = float(ocean.call("get_wave_time"))
			native.call("advance_dynamic_async", final_tick, now, now, 1.0 / 60.0)
			var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
			if info.size() >= 5 and info[0] == 1 and int(info[3]) == wanted_version:
				var band_times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
				all_coherent = all_coherent and band_times.size() == 3 and band_times[0] == band_times[1] and band_times[1] == band_times[2]
				break
		var final_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
		if final_info.size() < 5 or int(final_info[3]) != wanted_version:
			return {"passed": false, "error": "new config snapshot was not published", "wanted_version": wanted_version, "snapshot": final_info}
		var stats: PackedInt64Array = native.call("get_dynamic_async_stats")
		reset_counts.append(int(stats[33]))
		if String(target["label"]) == "storm_B":
			# Force an A->B->C version race while a snapshot build is in flight.
			# The second finalize uses the same immutable Production B spectrum;
			# only its version changes, so this isolates scheduler/config ownership.
			native.call("finalize_spectrum")
			var version_b2 := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
			var current_time := float(ocean.call("get_wave_time"))
			native.call("advance_dynamic_async", final_tick + 1, current_time, current_time, 1.0 / 60.0)
			for _spin in 1000:
				var worker_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
				if int(worker_stats[22]) == 2:
					worker_was_building = true
					break
				OS.delay_usec(100)
			native.call("finalize_spectrum")
			var version_b3 := int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
			rapid_versions = [version_b2, version_b3]
			versions.append(version_b3)
			for _wait in 1200:
				await physics_frame
				final_tick += 1
				current_time = float(ocean.call("get_wave_time"))
				native.call("advance_dynamic_async", final_tick, current_time, current_time, 1.0 / 60.0)
				var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
				if info.size() >= 5 and int(info[3]) == version_b3: break
			var rapid_info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
			if rapid_info.size() < 5 or int(rapid_info[3]) != version_b3:
				return {"passed": false, "error": "latest config version did not publish after rapid updates", "versions": rapid_versions, "snapshot": rapid_info}
			stats = native.call("get_dynamic_async_stats")
			reset_counts.append(int(stats[33]))
	ocean.set("significant_wave_height_m", original_hs)
	ocean.set("wind_speed_mps", original_wind)
	ocean.set("wind_direction_degrees", original_direction)
	ocean.set("wave_profile", original_profile)
	var restored := bool(ocean.call("initialize"))
	var restored_version := -1
	if restored:
		await RenderingServer.frame_post_draw
		fft = ocean.get_node_or_null("OpenOceanFFT")
		var restored_snapshots: Array[Dictionary] = fft.call("get_phys2_band_spectrum_snapshots")
		for band in 3:
			var restored_band: Dictionary = ADAPTER._configure_band(native, restored_snapshots[band], band)
			restored = restored and bool(restored_band.get("ok", false))
		native.call("finalize_spectrum")
		restored_version = int((native.call("get_dynamic_async_stats") as PackedInt64Array)[21])
		for _wait in 1200:
			await physics_frame
			final_tick += 1
			var now := float(ocean.call("get_wave_time"))
			native.call("advance_dynamic_async", final_tick, now, now, 1.0 / 60.0)
			if int((native.call("get_dynamic_snapshot_info") as PackedInt64Array)[3]) == restored_version: break
	var final_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	var resets_ok := reset_counts.size() == 3 and reset_counts[0] >= 1 and reset_counts[1] >= reset_counts[0] and reset_counts[2] > reset_counts[1]
	return {"passed": restored and all_coherent and resets_ok and versions.size() == 3 and \
		initial_version < versions[0] and versions[0] < versions[1] and versions[1] < versions[2],
		"transition": "A->B->C Production spectrum updates while Ocean remains running",
		"version_A": initial_version, "versions_B_Bprime_C": versions, "rapid_versions_while_building": rapid_versions,
		"worker_was_building_during_rapid_update": worker_was_building,
		"phase_reset_counts": reset_counts,
		"simulation_times": transition_times, "query_displacement_change_m": discontinuities,
		"coherent_bands": all_coherent, "restored_original_sea_state": restored,
		"restored_version": restored_version,
		"coalesced_requests_total": final_stats[24], "obsolete_builds_total": final_stats[25],
		"final_tick": final_tick}

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
	if values.is_empty(): return {"mean": 0.0, "p50": 0.0, "median": 0.0, "p90": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted: Array = values.duplicate()
	sorted.sort()
	var total := 0.0
	for value in sorted: total += value
	var middle := int(sorted.size() / 2)
	var median: float = sorted[middle] if sorted.size() % 2 == 1 else (sorted[middle - 1] + sorted[middle]) * 0.5
	return {"mean": total / sorted.size(), "p50": sorted[mini(sorted.size() - 1, ceili(sorted.size() * 0.50))], "median": median,
		"p90": sorted[mini(sorted.size() - 1, ceili(sorted.size() * 0.90))],
		"p95": sorted[mini(sorted.size() - 1, ceili(sorted.size() * 0.95))],
		"p99": sorted[mini(sorted.size() - 1, ceili(sorted.size() * 0.99))], "max": sorted[-1]}

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
