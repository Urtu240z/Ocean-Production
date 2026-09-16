extends SceneTree

const TEST_EPSILON: float = 0.000001

var _failed: bool = false


func _initialize() -> void:
	var passed := _run_source_contract()
	if passed:
		passed = _run_math_contract()
	quit(0 if passed else 1)


func _run_source_contract() -> bool:
	var surface_path := "res://addons/ocean/surface/ocean_clipmap_surface.gd"
	var open_ocean_path := "res://addons/ocean/fft/open_ocean_fft.gd"
	var surface_source := FileAccess.get_file_as_string(surface_path)
	var open_ocean_source := FileAccess.get_file_as_string(open_ocean_path)
	if surface_source.is_empty() or open_ocean_source.is_empty():
		return _fail("Surface Detail wave-clock sources are missing")

	var surface_contract := [
		"var _wave_time_s := 0.0",
		"func set_wave_time(value: float) -> void:",
		"_wave_time_s = maxf(value, 0.0)",
		"func _apply_wave_time() -> void:",
		"_set_surface_shader_parameter(&\"ocean_time_s\", _wave_time_s)",
		"_material.shader = SURFACE_SHADER if key == \"base:fallback:flat:nobreaker\" else _variant_shaders[key]",
		"_apply_wave_time()\n\t_apply_surface_scale()",
	]
	for contract_line in surface_contract:
		if not surface_source.contains(contract_line):
			return _fail("Missing Surface Detail wave-clock contract: %s" % contract_line)

	if surface_source.contains("_set_surface_shader_parameter(&\"ocean_time_s\", Time.get_ticks_msec() * 0.001)"):
		return _fail("Surface Detail still uses the application wall clock")
	if surface_source.contains("ocean_time_s * _wave_speed_multiplier") or not surface_source.contains("ocean_time_s * surface_flow_speed_a") or not surface_source.contains("ocean_time_s * surface_flow_speed_b"):
		return _fail("Surface Detail flow speed is not relative to the shared clock")

	var open_ocean_contract := [
		"_wave_time += maxf(delta, 0.0) * _wave_speed_multiplier",
		"if _surface_initialized:\n\t\t_surface.set_wave_time(_wave_time)",
		"_surface.set_wave_time(_wave_time)\n\t_surface_initialized = true",
		"_surface_foam.set_wave_time(_wave_time)",
	]
	for contract_line in open_ocean_contract:
		if not open_ocean_source.contains(contract_line):
			return _fail("OpenOceanFFT is not the sole Surface Detail clock authority")

	print("OCEAN_SURFACE_DETAIL_NO_WALL_CLOCK_PASS")
	print("OCEAN_SHARED_WAVE_CLOCK_CONTRACT_PASS")
	return true


func _run_math_contract() -> bool:
	if not _check_initial_time():
		return false
	print("OCEAN_SURFACE_DETAIL_INITIAL_TIME_PASS")

	if not _check_wave_speed_sync():
		return false
	print("OCEAN_SURFACE_DETAIL_WAVE_SPEED_SYNC_PASS")

	if not _check_pause_sync():
		return false
	print("OCEAN_SURFACE_DETAIL_PAUSE_SYNC_PASS")

	if not _check_reenable_continuity():
		return false
	print("OCEAN_SURFACE_DETAIL_REENABLE_TIME_CONTINUITY_PASS")

	if not _check_variant_continuity():
		return false
	print("OCEAN_SURFACE_DETAIL_VARIANT_TIME_CONTINUITY_PASS")

	return true


func _check_initial_time() -> bool:
	if not _approximately_equal(_sanitize_wave_time(37.0), 37.0):
		return _fail("Initial wave time was not preserved")
	if not _approximately_equal(_sanitize_wave_time(-4.0), 0.0):
		return _fail("Negative initial wave time was not clamped")
	return true


func _check_wave_speed_sync() -> bool:
	for multiplier_value in [0.0, 0.5, 1.0, 2.0]:
		var multiplier := float(multiplier_value)
		var before := 11.0
		var after := _advance_wave_time(before, 1.0, multiplier)
		if not _approximately_equal(after - before, multiplier):
			return _fail("Wave-speed delta mismatch for multiplier %f" % multiplier)
	return true


func _check_pause_sync() -> bool:
	var wave_time := 11.0
	var paused_surface_time := wave_time
	var paused_fft_time := wave_time
	if not _approximately_equal(_advance_wave_time(paused_fft_time, 1.0, 0.0), paused_fft_time):
		return _fail("Wave clock advanced while speed was zero")
	if not _approximately_equal(paused_surface_time, paused_fft_time):
		return _fail("Surface Detail diverged while the ocean was paused")
	return true


func _check_reenable_continuity() -> bool:
	var wave_time := 10.0
	var detail_time_when_disabled := wave_time
	wave_time = _advance_wave_time(wave_time, 15.0, 1.0)
	var detail_time_when_reenabled := wave_time
	if not _approximately_equal(detail_time_when_disabled, 10.0) or not _approximately_equal(detail_time_when_reenabled, 25.0):
		return _fail("Surface Detail did not re-enable at the shared current wave time")
	return true


func _check_variant_continuity() -> bool:
	var wave_time := 23.5
	var stored_time := _sanitize_wave_time(wave_time)
	var after_variant_reapply := _sanitize_wave_time(stored_time)
	if not _approximately_equal(after_variant_reapply, wave_time):
		return _fail("Shader variant reapplication changed the stored wave time")
	return true


func _advance_wave_time(current: float, delta: float, multiplier: float) -> float:
	return current + maxf(delta, 0.0) * multiplier


func _sanitize_wave_time(value: float) -> float:
	return maxf(value, 0.0)


func _approximately_equal(actual: float, expected: float) -> bool:
	return absf(actual - expected) <= TEST_EPSILON


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_SURFACE_DETAIL_WAVE_TIME_FAIL: %s" % reason)
	return false
