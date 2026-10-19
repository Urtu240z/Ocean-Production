extends Node
## Experimental CPU-only scheduling. The original wave clocks remain authoritative.
var provider: CpuFftWaterProvider
var _mode := 0
var _runtime: RefCounted
var _states: Array = [null,null]
var _unused_states: Array = [null,null]

func configure(owner_provider: CpuFftWaterProvider) -> void:
	provider = owner_provider
	process_physics_priority = -900000

func _set_mode(mode: int) -> bool:
	if not is_instance_valid(provider.native): return false
	# Retire all state leases before changing the single shared worker limit.
	if _runtime != null:
		for state in _states:
			if state != null and state.native != null:
				state.native.call("set_dynamic_lite_execution_mode", 0)
	if not provider.native.call("set_dynamic_lite_execution_mode", mode): return false
	_mode = mode
	if mode == 0:
		for state in _unused_states:
			if state != null: state.shutdown()
		_unused_states = [null,null]
	return true

func _physics_process(delta: float) -> void:
	if not is_instance_valid(provider) or not is_instance_valid(provider.native): return
	var wanted := clampi(provider.fft_execution_mode, 0, 2)
	var mode_changed := wanted != _mode
	if mode_changed and not _set_mode(wanted): return
	if _mode == 0:
		if mode_changed and provider.field_ready:
			provider.field_ready = provider.native.call("build_dynamic_physics_lite",provider.current_field_time,provider.lite_resolutions)
		return
	if not provider._refresh_runtime_spectrum_if_needed(): return
	if provider.backend != CpuFftWaterProvider.Backend.CPU_LITE_B or provider.compare_other_cpu_backend:
		push_error("Async FFT requires CPU Lite without backend comparison")
		provider.fft_execution_mode = 0
		_set_mode(0)
		return
	var tick := Engine.get_physics_frames()
	provider.fft.call("advance_physics_wave_time", tick, delta)
	var time := float(provider.fft.call("get_wave_time"))
	provider.native.call("set_gameplay_min_wavelength_m", provider.physics_min_wavelength_m)
	_runtime = provider.ocean_root.call("get_wave_area_runtime") if provider.ocean_root.has_method("get_wave_area_runtime") else null
	if _runtime != null:
		for slot in 2:
			_states[slot] = _runtime.states[slot]
			if _states[slot] != null:
				if _unused_states[slot] != null: _unused_states[slot].shutdown(); _unused_states[slot] = null
				continue
			var settings: Resource = provider.ocean_root.get("local_sea_state_1" if slot == 0 else "local_sea_state_2")
			if settings == null: continue
			if _unused_states[slot] == null: _unused_states[slot] = preload("res://addons/ocean/areas/ocean_local_fft_state.gd").new()
			_unused_states[slot].configure_physics_only(settings,provider.ocean_root)
			_states[slot] = _unused_states[slot]
	# Queue every active state before waiting for any of them: nine band jobs
	# compete on the same persistent pool even when there are no area contacts.
	provider.native.call("request_dynamic_lite", tick, time, provider.lite_resolutions)
	if _runtime != null:
		for state in _states:
			if state != null: state.prepare_physics_tick(tick, _runtime.time_s, _mode)
	if tick != provider.last_build_tick: provider._build_fields(time)
	elif mode_changed:
		provider.field_ready = provider.native.call("consume_dynamic_lite",tick,time,provider.lite_resolutions)
	if _runtime != null:
		for state in _states:
			if state != null: state.consume_physics_tick(tick, _runtime.time_s)
	# Exact clocks are checked again at consumption. Freeze, speed changes or
	# a rewind invalidate this speculation and restore its phase checkpoint.
	var clock_state: Dictionary = provider.fft.call("get_physics_wave_time_state")
	var next_time := time + float(clock_state.get("physics_wave_time_step", 0.0))
	provider.native.call("request_dynamic_lite", tick + 1, next_time, provider.lite_resolutions)
	if _runtime != null:
		var next_clock: float = _runtime.time_s + 1.0 / Engine.physics_ticks_per_second
		for state in _states:
			if state != null: state.prepare_physics_tick(tick + 1, next_clock, _mode)

func _exit_tree() -> void:
	if is_instance_valid(provider) and is_instance_valid(provider.native): _set_mode(0)
