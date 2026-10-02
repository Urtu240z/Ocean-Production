class_name OceanGPUStockhamFFT
extends RefCounted
## Una banda FFT y, cuando Crest está activo, su acumulador V3 RG16F.
## Crest añade 2xR16F de historia fresh privada por solver; solo se usa en el
## update Crest de 30 Hz y nunca se publica al material ni a Spindrift.

const EVOLVE_SHADER := "res://addons/ocean/shaders/fft/evolve_spectrum.glsl"
const STOCKHAM_SHADER := "res://addons/ocean/shaders/fft/stockham_ifft.glsl"
const ASSEMBLE_SHADER := "res://addons/ocean/shaders/fft/assemble_maps.glsl"
const UPDATE_CREST_SHADER := "res://addons/ocean/shaders/fft/update_crest_foam.glsl"
const STORE_PREVIOUS_SHADER := "res://addons/ocean/shaders/fft/store_crest_previous_displacement.glsl"
const BREAKER_LIFECYCLE_SHADER := "res://addons/ocean/shaders/fft/update_breaker_lifecycle.glsl"
const BREAKER_EVENT_SCORE_BITS := 14
const BREAKER_EVENT_INDEX_BITS := 18
const BREAKER_EVENT_INDEX_MASK := (1 << BREAKER_EVENT_INDEX_BITS) - 1
const BREAKER_EVENT_SCORE_MAX := float((1 << BREAKER_EVENT_SCORE_BITS) - 1)
const BREAKER_DETECTOR_PROBE_BYTES := 128
const BREAKER_DETECTOR_PROBE_WINDOW_S := 1.0
const BREAKER_DETECTOR_PROBE_RING_SIZE := 8

var ready := false
var generation := -1
var last_error := ""
var displacement_rid := RID()
var normal_rid := RID()
var crest_foam_rid := RID()
var breaker_lifecycle_rid := RID()
var breaker_lifecycle_ready := false
var crest_ready := false
var _publication_mutex := Mutex.new()
var _publication_revision := 0
var _publication_snapshot: Dictionary = {}
var _time_audit_mutex := Mutex.new()
var _time_audit_enabled := false
var _time_audit: Dictionary = {}

var _rd: RenderingDevice
var _config: Resource
var _h0 := RID()
var _ping_a: Array[RID] = [RID(), RID()]
var _ping_b: Array[RID] = [RID(), RID()]
var _ping_c: Array[RID] = [RID(), RID()]
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _uniform_sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets: Array[RID] = [RID(), RID()]
var _assemble_set := RID()

var _crest_enabled := false
var _crest_shaders: Array[RID] = [RID(), RID()]
var _crest_pipelines: Array[RID] = [RID(), RID()]
var _crest_whitecap := 0.62
var _crest_amount := 1.60
var _crest_decay := 4.50
var _crest_weight := 1.0
var _crest_resolution := 1024
var _crest_accumulator := 0.0
var _crest_ping: Array[RID] = [RID(), RID()]
var _crest_legacy_fresh: Array[RID] = [RID(), RID()]
var _previous_displacement: Array[RID] = [RID(), RID()]
var _crest_read_index := 0
var _previous_read_index := 0
var _crest_sampler := RID()
var _crest_sets: Array[RID] = []
var _store_sets: Array[RID] = []
var _breaker_lifecycle_enabled := false
var _breaker_lifecycle_retire_pending := false
var _breaker_lifecycle_shader := RID()
var _breaker_lifecycle_pipeline := RID()
var _breaker_lifecycle_ping: Array[RID] = [RID(), RID()]
var _breaker_lifecycle_sets: Array[RID] = []
var _breaker_detector_probe_shader := RID()
var _breaker_detector_probe_pipeline := RID()
var _breaker_detector_probe_sets: Array[RID] = []
const BREAKER_EVENT_PROBE_BYTES := 32
var _breaker_event_probe := RID()
var _breaker_event_probe_readback_pending := false
var _breaker_event_probe_latest: Dictionary = {}
var _breaker_event_probe_sequence := 0
var _breaker_detector_probe_buffers: Array[RID] = []
var _breaker_detector_probe_enabled := false
var _breaker_detector_probe_requested_xz := Vector2.ZERO
var _breaker_detector_probe_cell := Vector2i.ZERO
var _breaker_detector_probe_reset_serial := 0
var _breaker_detector_probe_step_sequence := 0
var _breaker_detector_probe_readback_pending: Array[bool] = []
var _breaker_detector_probe_slot_reserved: Array[bool] = []
var _breaker_detector_probe_captures_queued: Array[int] = []
var _breaker_detector_probe_capture_id_by_slot: Array[int] = []
var _breaker_detector_probe_sequence_by_slot: Array[int] = []
var _breaker_detector_probe_next_slot := 0
var _breaker_detector_probe_config_revision := 0
var _breaker_detector_probe_latest: Dictionary = {}
var _breaker_detector_probe_history: Array[Dictionary] = []
var _breaker_detector_capture_mutex := Mutex.new()
var _breaker_detector_capture_callback: Callable
var _breaker_detector_capture_state: Dictionary = {"capture_armed": false, "capture_frozen": false, "capture_complete_gpu": false}
var _breaker_detector_capture_arm_serial := 0
var _breaker_detector_capture_release_serial := 0
var _breaker_detector_capture_id := 0
var _breaker_detector_capture_armed := false
var _breaker_detector_capture_frozen := false
var _breaker_detector_capture_freeze_pending := false
var _breaker_detector_capture_pending_state: Dictionary = {}
var _breaker_lifecycle_runtime: Dictionary = {}
var _breaker_lifecycle_index := 0
var _breaker_lifecycle_accumulator := 0.0
var _breaker_lifecycle_time := 0.0
var _breaker_lifecycle_resolution := 512
var _breaker_lifecycle_values := PackedFloat32Array([4.0, 1.2, 2.0, 3.0, 0.45, 0.22, 0.35, 0.3, 3.0, 0.62, 0.02])
var _crest_disable_requested := false


func get_publication_snapshot() -> Dictionary:
	_publication_mutex.lock()
	var result: Dictionary = _publication_snapshot.duplicate()
	_publication_mutex.unlock()
	return result


## Validation-only counters for checking fixed-step time conservation.
func set_time_audit_enabled(enabled: bool) -> void:
	_time_audit_mutex.lock()
	_time_audit_enabled = enabled
	_time_audit_mutex.unlock()


func reset_time_audit() -> void:
	_time_audit_mutex.lock()
	_time_audit = {
		"initial_crest_remainder": _crest_accumulator,
		"total_simulation_dt_input": 0.0,
		"total_crest_input": 0.0,
		"total_crest_time_consumed": 0.0,
		"final_crest_remainder": _crest_accumulator,
		"crest_updates": 0,
		"crest_last": {},
		"total_lifecycle_elapsed_received": 0.0,
		"lifecycle_fixed_steps_executed": 0,
		"total_lifecycle_time": 0.0,
		"lifecycle_last": {},
	}
	_time_audit_mutex.unlock()


func get_time_audit_snapshot() -> Dictionary:
	_time_audit_mutex.lock()
	var result := _time_audit.duplicate(true)
	_time_audit_mutex.unlock()
	return result


func _time_audit_add_input(delta_s: float) -> void:
	_time_audit_mutex.lock()
	_time_audit["total_simulation_dt_input"] = float(_time_audit.get("total_simulation_dt_input", 0.0)) + maxf(delta_s, 0.0)
	_time_audit_mutex.unlock()


func _time_audit_record_crest(input_dt: float, accumulator_before: float, after_add: float, consumed: float, remainder_after: float) -> void:
	_time_audit_mutex.lock()
	_time_audit["total_crest_input"] = float(_time_audit.get("total_crest_input", 0.0)) + input_dt
	_time_audit["total_crest_time_consumed"] = float(_time_audit.get("total_crest_time_consumed", 0.0)) + consumed
	_time_audit["final_crest_remainder"] = remainder_after
	_time_audit["crest_updates"] = int(_time_audit.get("crest_updates", 0)) + 1
	_time_audit["crest_last"] = {
		"accumulator_before": accumulator_before,
		"input_dt": input_dt,
		"accumulator_after_add": after_add,
		"consumed_delta_returned": consumed,
		"remainder_after": remainder_after,
	}
	_time_audit_mutex.unlock()


func _time_audit_record_lifecycle(elapsed_received: float, steps: int, time_before: float, time_after: float, accumulator_after: float) -> void:
	_time_audit_mutex.lock()
	_time_audit["total_lifecycle_elapsed_received"] = float(_time_audit.get("total_lifecycle_elapsed_received", 0.0)) + elapsed_received
	_time_audit["lifecycle_fixed_steps_executed"] = int(_time_audit.get("lifecycle_fixed_steps_executed", 0)) + steps
	_time_audit["total_lifecycle_time"] = float(_time_audit.get("total_lifecycle_time", 0.0)) + (time_after - time_before)
	_time_audit["lifecycle_last"] = {
		"elapsed_received": elapsed_received,
		"fixed_steps_executed": steps,
		"lifecycle_time_before": time_before,
		"lifecycle_time_after": time_after,
		"lifecycle_accumulator_after": accumulator_after,
	}
	_time_audit_mutex.unlock()


func _publish_snapshot() -> void:
	_publication_mutex.lock()
	_publication_revision += 1
	var resources_valid: bool = ready and _resources_are_ready() and displacement_rid.is_valid() and normal_rid.is_valid()
	var crest_valid: bool = resources_valid and crest_ready and crest_foam_rid.is_valid()
	var fft_resources: bool = _h0.is_valid()
	for texture in _ping_a + _ping_b + _ping_c:
		fft_resources = fft_resources and texture.is_valid()
	_publication_snapshot = {
		"generation": generation,
		"ready": resources_valid,
		"error": last_error,
		"displacement_rid": displacement_rid if resources_valid else RID(),
		"normal_rid": normal_rid if resources_valid else RID(),
		"crest_ready": crest_valid,
		"crest_foam_rid": crest_foam_rid if crest_valid else RID(),
		"breaker_lifecycle_ready": resources_valid and breaker_lifecycle_ready and breaker_lifecycle_rid.is_valid(),
		"breaker_lifecycle_rid": breaker_lifecycle_rid if resources_valid and breaker_lifecycle_ready else RID(),
		"breaker_lifecycle_dispatch_enabled": _breaker_lifecycle_enabled,
		"breaker_lifecycle_retire_pending": _breaker_lifecycle_retire_pending,
		"breaker_lifecycle_published_rid_valid": breaker_lifecycle_rid.is_valid(),
		"breaker_event_probe_ready": _breaker_event_probe.is_valid(),
		"breaker_event_probe_readback_pending": _breaker_event_probe_readback_pending,
		"breaker_detector_probe_enabled": _breaker_detector_probe_enabled,
		"breaker_detector_probe_ready": _breaker_detector_probe_pipeline.is_valid() and _breaker_detector_probe_sets.size() == 4 * BREAKER_DETECTOR_PROBE_RING_SIZE,
		"breaker_detector_probe_readback_pending": _breaker_detector_probe_readback_pending.has(true),
		"breaker_detector_probe_state": _breaker_detector_probe_latest.duplicate(true),
		"breaker_lifecycle_runtime": _breaker_lifecycle_runtime.duplicate(true),
		"resources_valid": resources_valid,
		"h0": _h0.is_valid(),
		"fft_resources": fft_resources,
		"dispatch": resources_valid,
		"crest_legacy_fresh_history": _crest_legacy_fresh[0].is_valid() and _crest_legacy_fresh[1].is_valid(),
		"publication_revision": _publication_revision,
	}
	_publication_mutex.unlock()


func initialize(config: Resource, h0_data: PackedByteArray, resource_prefix: String) -> void:
	shutdown()
	last_error = ""
	_config = config
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice global no disponible."
		_publish_snapshot()
		return
	for item in [[EVOLVE_SHADER, ".Evolve"], [STOCKHAM_SHADER, ".Stockham"], [ASSEMBLE_SHADER, ".Assemble"]]:
		if not _create_pipeline(item[0], resource_prefix + item[1]).is_valid():
			shutdown()
			return
	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".H0", h0_data, true)
	for index in 2:
		_ping_a[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingA%d" % index)
		_ping_b[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingB%d" % index)
		_ping_c[index] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".PingC%d" % index)
	displacement_rid = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, resource_prefix + ".Displacement")
	var normal_data := PackedByteArray()
	normal_data.resize(_config.resolution * _config.resolution * 8)
	normal_rid = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, resource_prefix + ".Normal", normal_data)
	_evolve_set = _create_image_set(_shaders[0], [_h0, _h0, _ping_a[0], _ping_b[0], _ping_c[0]])
	_fft_sets[0] = _create_image_set(_shaders[1], [_ping_a[0], _ping_b[0], _ping_c[0], _ping_a[1], _ping_b[1], _ping_c[1]])
	_fft_sets[1] = _create_image_set(_shaders[1], [_ping_a[1], _ping_b[1], _ping_c[1], _ping_a[0], _ping_b[0], _ping_c[0]])
	_assemble_set = _create_image_set(_shaders[2], [_ping_a[0], _ping_b[0], _ping_c[0], displacement_rid, normal_rid])
	ready = _resources_are_ready()
	if not ready: last_error = "No se pudieron crear los uniform sets de %s." % resource_prefix
	_publish_snapshot()


func set_crest_foam_settings(whitecap: float, amount: float, decay: float, weight: float, resolution: int) -> void:
	_crest_whitecap = whitecap
	_crest_amount = amount
	_crest_decay = decay
	_crest_weight = weight
	_crest_resolution = resolution


func set_crest_foam_enabled(enabled: bool) -> void:
	if _rd == null or not ready: return
	if not enabled:
		_crest_disable_requested = true
		# Breakers retain the long crest inputs until lifecycle retirement completes.
		if _breaker_lifecycle_enabled or _breaker_lifecycle_retire_pending:
			_publish_snapshot()
			return
		_crest_enabled = false
		_free_crest_resources()
		_publish_snapshot()
		return
	_crest_disable_requested = false
	if _crest_enabled and crest_ready and crest_foam_rid.is_valid(): return
	_create_crest_resources()
	_crest_enabled = crest_ready
	_publish_snapshot()


func set_breaker_lifecycle_enabled(enabled: bool, values: PackedFloat32Array) -> void:
	if _rd == null or not ready: return
	if values.size() == 11:
		_breaker_lifecycle_values = values.duplicate()
	if not enabled:
		_breaker_lifecycle_enabled = false
		breaker_lifecycle_ready = false
		_breaker_lifecycle_retire_pending = _breaker_lifecycle_resources_valid()
		_publish_snapshot()
		return
	if _breaker_lifecycle_retire_pending:
		_breaker_lifecycle_retire_pending = false
		breaker_lifecycle_ready = _breaker_lifecycle_resources_valid()
		if breaker_lifecycle_ready:
			_breaker_lifecycle_enabled = true
			_publish_snapshot()
			return
		_free_breaker_lifecycle_resources()
	if _breaker_lifecycle_enabled and breaker_lifecycle_ready: return
	_create_breaker_lifecycle_resources()
	_breaker_lifecycle_enabled = breaker_lifecycle_ready
	_publish_snapshot()


func retire_breaker_lifecycle_resources() -> void:
	if _breaker_lifecycle_enabled or not _breaker_lifecycle_retire_pending:
		return
	_free_breaker_lifecycle_resources()
	if _crest_disable_requested:
		_crest_disable_requested = false
		_crest_enabled = false
		_free_crest_resources()
	_publish_snapshot()


func update_runtime_spectrum(config: Resource, h0_data: PackedByteArray) -> bool:
	# Render thread only. Reuses existing H0 texture and FFT plans/resources.
	if not _resources_are_ready() or config.resolution != _config.resolution \
			or config.domain_size_m != _config.domain_size_m \
			or h0_data.size() != config.resolution * config.resolution * 16:
		return false
	if _rd.texture_update(_h0, 0, h0_data) != OK: return false
	_config = config
	return true


func dispatch(render_time: float, delta_s: float) -> void:
	if not ready or _breaker_detector_capture_frozen: return
	if _time_audit_enabled:
		_time_audit_add_input(delta_s)
	_breaker_detector_capture_freeze_pending = false
	var previous_crest_rid: RID = crest_foam_rid
	var previous_breaker_rid: RID = breaker_lifecycle_rid
	var groups := ceili(float(_config.resolution) / 8.0)
	var crest_delta := _prepare_crest_update(delta_s)
	if _breaker_detector_probe_enabled:
		_breaker_detector_probe_captures_queued.clear()
		if _breaker_detector_probe_slot_reserved.size() == BREAKER_DETECTOR_PROBE_RING_SIZE:
			_breaker_detector_probe_slot_reserved.fill(false)
	if _breaker_detector_probe_enabled and _breaker_detector_probe_buffers.size() == BREAKER_DETECTOR_PROBE_RING_SIZE:
		for slot in BREAKER_DETECTOR_PROBE_RING_SIZE:
			if not _breaker_detector_probe_readback_pending[slot]:
				_rd.buffer_update(_breaker_detector_probe_buffers[slot], 0, BREAKER_DETECTOR_PROBE_BYTES, _zeroed_probe_bytes())
	if _breaker_lifecycle_enabled and _breaker_event_probe.is_valid() and not _breaker_event_probe_readback_pending:
		_rd.buffer_update(_breaker_event_probe, 0, BREAKER_EVENT_PROBE_BYTES, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[0])
	_rd.compute_list_bind_uniform_set(list, _evolve_set, 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([render_time, _config.gravity_mps2, _config.choppiness, _config.domain_size_m, 0.0]).to_byte_array(), 20)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[1])
	var pass_index := 0
	for axis in 2:
		var stage_size := 2
		for _stage in _config.fft_stage_count():
			_rd.compute_list_bind_uniform_set(list, _fft_sets[pass_index % 2], 0)
			_rd.compute_list_set_push_constant(list, PackedInt32Array([stage_size, axis, _config.resolution, 1]).to_byte_array(), 16)
			_rd.compute_list_dispatch(list, groups, groups, 1)
			_rd.compute_list_add_barrier(list)
			stage_size *= 2
			pass_index += 1
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[2])
	_rd.compute_list_bind_uniform_set(list, _assemble_set, 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([_config.domain_size_m, 1.0 / float(_config.resolution * _config.resolution), _config.domain_size_m / float(_config.resolution), 0.0]).to_byte_array(), 16)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_add_barrier(list)
	_dispatch_crest(list, groups, crest_delta)
	if _breaker_lifecycle_enabled and crest_delta > 0.0:
		_rd.compute_list_add_barrier(list)
		_dispatch_breaker_lifecycle(list, crest_delta, render_time)
	_rd.compute_list_end()
	if _breaker_detector_capture_freeze_pending:
		_breaker_detector_capture_frozen = true
		_breaker_detector_capture_pending_state["capture_frozen"] = true
		_set_breaker_detector_capture_state(_breaker_detector_capture_pending_state)
		if _breaker_detector_capture_callback.is_valid():
			_breaker_detector_capture_callback.call_deferred(_breaker_detector_capture_pending_state.duplicate(true))
		_breaker_detector_capture_freeze_pending = false
	if _breaker_detector_probe_enabled:
		for slot in _breaker_detector_probe_captures_queued:
			_queue_breaker_detector_probe_readback(slot)
		_breaker_detector_probe_captures_queued.clear()
	if previous_crest_rid != crest_foam_rid or previous_breaker_rid != breaker_lifecycle_rid:
		_publish_snapshot()


func _queue_breaker_event_probe_readback() -> void:
	if not _breaker_event_probe.is_valid() or _breaker_event_probe_readback_pending:
		return
	_breaker_event_probe_readback_pending = true
	_rd.buffer_get_data_async(_breaker_event_probe, _on_breaker_event_probe_readback)


func request_breaker_event_probe_readback() -> void:
	_queue_breaker_event_probe_readback()


func _on_breaker_event_probe_readback(bytes: PackedByteArray) -> void:
	if not is_instance_valid(self):
		return
	if not _breaker_event_probe.is_valid():
		_breaker_event_probe_readback_pending = false
		return
	var found := bytes.decode_u32(0) if bytes.size() >= 4 else 0
	if found != 0 and bytes.size() >= 8:
		_breaker_event_probe_sequence += 1
		var domain_m := maxf(_config.domain_size_m, 0.001)
		var linear_index := found & BREAKER_EVENT_INDEX_MASK
		var cell_x := linear_index % _breaker_lifecycle_resolution
		var cell_y := linear_index / _breaker_lifecycle_resolution
		var uv_x := (float(cell_x) + 0.5) / float(_breaker_lifecycle_resolution)
		var uv_y := (float(cell_y) + 0.5) / float(_breaker_lifecycle_resolution)
		var score_q := found >> BREAKER_EVENT_INDEX_BITS
		var event_score := float(score_q) / BREAKER_EVENT_SCORE_MAX
		var seed_sim_time := bytes.decode_float(4)
		var acquisition_sim_time := _breaker_lifecycle_time
		_breaker_event_probe_latest = {
			"valid": true,
			"sequence": _breaker_event_probe_sequence,
			"uv": Vector2(uv_x, uv_y),
			"sample_xz": (Vector2(uv_x, uv_y) - Vector2(0.5, 0.5)) * domain_m,
			"strength": clampf(event_score, 0.0, 1.0),
			"event_score": clampf(event_score, 0.0, 1.0),
			"winner_key": found,
			"seed_sim_time": seed_sim_time,
			"acquisition_sim_time": acquisition_sim_time,
			"acquisition_age_s": maxf(acquisition_sim_time - seed_sim_time, 0.0) if seed_sim_time >= 0.0 else INF,
			"domain_m": domain_m,
		}
	_breaker_event_probe_readback_pending = false


func get_breaker_event_probe_state() -> Dictionary:
	return _breaker_event_probe_latest.duplicate(true)


func set_breaker_detector_capture_callback(callback: Callable) -> void:
	_breaker_detector_capture_callback = callback


func set_breaker_detector_capture_control(arm_serial: int, release_serial: int) -> void:
	if arm_serial != _breaker_detector_capture_arm_serial:
		_breaker_detector_capture_arm_serial = arm_serial
		_breaker_detector_capture_id = maxi(arm_serial, 1)
		_breaker_detector_capture_armed = true
		_breaker_detector_capture_frozen = false
		_breaker_detector_probe_config_revision += 1
		_breaker_detector_probe_latest.clear()
		_breaker_detector_probe_history.clear()
		_set_breaker_detector_capture_state({
			"capture_armed": true,
			"capture_frozen": false,
			"capture_complete_gpu": false,
			"capture_id": _breaker_detector_capture_id,
			"capture_invalid": false,
		})
	if release_serial != _breaker_detector_capture_release_serial:
		_breaker_detector_capture_release_serial = release_serial
		_breaker_detector_capture_armed = false
		_breaker_detector_capture_frozen = false
		_breaker_lifecycle_accumulator = 0.0
		var released_state := get_breaker_detector_capture_state()
		released_state["capture_armed"] = false
		released_state["capture_frozen"] = false
		released_state["capture_released"] = true
		_set_breaker_detector_capture_state(released_state)


func get_breaker_detector_capture_state() -> Dictionary:
	_breaker_detector_capture_mutex.lock()
	var state: Dictionary = _breaker_detector_capture_state.duplicate(true)
	_breaker_detector_capture_mutex.unlock()
	return state


func _set_breaker_detector_capture_state(state: Dictionary) -> void:
	_breaker_detector_capture_mutex.lock()
	_breaker_detector_capture_state = state.duplicate(true)
	_breaker_detector_capture_mutex.unlock()


func set_breaker_detector_probe(enabled: bool, requested_xz: Vector2, reset_serial: int) -> void:
	var moved := not requested_xz.is_equal_approx(_breaker_detector_probe_requested_xz)
	_breaker_detector_probe_enabled = enabled
	_breaker_detector_probe_requested_xz = requested_xz if requested_xz.is_finite() else Vector2.ZERO
	if moved or reset_serial != _breaker_detector_probe_reset_serial:
		_breaker_detector_probe_reset_serial = reset_serial
		_breaker_detector_probe_config_revision += 1
		_breaker_detector_probe_latest.clear()
		_breaker_detector_probe_history.clear()
	var domain_m := maxf(_config.domain_size_m, 0.001)
	var uv := Vector2(
		fposmod(_breaker_detector_probe_requested_xz.x / domain_m + 0.5, 1.0),
		fposmod(_breaker_detector_probe_requested_xz.y / domain_m + 0.5, 1.0))
	_breaker_detector_probe_cell = Vector2i(
		clampi(floori(uv.x * float(_breaker_lifecycle_resolution)), 0, _breaker_lifecycle_resolution - 1),
		clampi(floori(uv.y * float(_breaker_lifecycle_resolution)), 0, _breaker_lifecycle_resolution - 1))
	if not enabled:
		_breaker_detector_probe_captures_queued.clear()
		_breaker_detector_probe_latest.clear()
		_breaker_detector_probe_history.clear()
	elif breaker_lifecycle_ready:
		_ensure_breaker_detector_probe_resources()


func get_breaker_detector_probe_state() -> Dictionary:
	return _breaker_detector_probe_latest.duplicate(true)


func _queue_breaker_detector_probe_readback(slot: int) -> void:
	if not _breaker_detector_probe_enabled or slot < 0 or slot >= _breaker_detector_probe_buffers.size() or _breaker_detector_probe_readback_pending[slot]:
		return
	_breaker_detector_probe_readback_pending[slot] = true
	_rd.buffer_get_data_async(_breaker_detector_probe_buffers[slot], _on_breaker_detector_probe_readback.bind(
		slot, _breaker_detector_probe_config_revision, _breaker_detector_probe_requested_xz,
		_breaker_detector_probe_capture_id_by_slot[slot], _breaker_detector_probe_sequence_by_slot[slot]))


func _on_breaker_detector_probe_readback(bytes: PackedByteArray, slot: int, config_revision: int, requested_xz: Vector2, expected_capture_id: int, expected_sequence: int) -> void:
	if slot >= 0 and slot < _breaker_detector_probe_readback_pending.size():
		_breaker_detector_probe_readback_pending[slot] = false
	if not is_instance_valid(self) or not _breaker_detector_probe_enabled or config_revision != _breaker_detector_probe_config_revision or bytes.size() < BREAKER_DETECTOR_PROBE_BYTES:
		return
	var buffer_capture_id := int(bytes.decode_u32(0))
	var buffer_sequence := int(bytes.decode_u32(4))
	if expected_capture_id > 0 and (expected_capture_id != _breaker_detector_capture_id or buffer_capture_id != expected_capture_id or buffer_sequence != expected_sequence):
		if expected_capture_id == _breaker_detector_capture_id:
			var invalid_state := get_breaker_detector_capture_state()
			invalid_state["capture_armed"] = false
			invalid_state["capture_frozen"] = true
			invalid_state["capture_complete_gpu"] = false
			invalid_state["capture_invalid"] = true
			invalid_state["capture_invalid_reason"] = "READBACK_ID_OR_SEQUENCE_MISMATCH"
			_set_breaker_detector_capture_state(invalid_state)
		return
	if buffer_capture_id == 0:
		return
	if expected_capture_id == 0 and (_breaker_detector_capture_armed or _breaker_detector_capture_frozen):
		return
	var above_threshold := bytes.decode_u32(56) != 0
	var threshold_edge := bytes.decode_u32(60) != 0
	var previous_active := bytes.decode_u32(80) != 0
	var duplicate_event := bytes.decode_u32(88) != 0
	var refractory_active := bytes.decode_u32(96) != 0
	var seed := bytes.decode_float(104)
	var fresh_foam := bytes.decode_float(40)
	var threshold := bytes.decode_float(48)
	var classification: Array[String] = []
	if not above_threshold:
		classification.append("BELOW_THRESHOLD")
	if above_threshold and not threshold_edge:
		classification.append("ABOVE_THRESHOLD_NO_EDGE")
	if duplicate_event:
		classification.append("DUPLICATE_EVENT")
	if refractory_active:
		classification.append("REFRACTORY")
	if previous_active:
		classification.append("PREVIOUS_ACTIVE")
	if seed > 0.0:
		classification.append("VALID_SEED")
	var first_blocker := "VALID_SEED" if seed > 0.0 else ""
	if seed <= 0.0:
		if duplicate_event: first_blocker = "DUPLICATE_EVENT"
		elif previous_active: first_blocker = "PREVIOUS_ACTIVE"
		elif refractory_active: first_blocker = "REFRACTORY"
		elif not threshold_edge: first_blocker = "BELOW_THRESHOLD" if not above_threshold else "ABOVE_THRESHOLD_NO_EDGE"
	var state := {
		"valid": true,
		"capture_id": expected_capture_id if expected_capture_id > 0 else 0,
		"capture_complete_gpu": expected_capture_id > 0 and buffer_capture_id == expected_capture_id and buffer_sequence == expected_sequence,
		"readback_capture_id": buffer_capture_id,
		"readback_sequence": buffer_sequence,
		"capture_stale_readback_accepted": false,
		"requested_xz": requested_xz,
		"requested_probe_xz": requested_xz,
		"resolved_xz": Vector2(bytes.decode_float(32), bytes.decode_float(36)),
		"resolved_cell_world_xz": Vector2(bytes.decode_float(32), bytes.decode_float(36)),
		"uv": Vector2(bytes.decode_float(24), bytes.decode_float(28)),
		"cell": Vector2i(bytes.decode_u32(16), bytes.decode_u32(20)),
		"lifecycle_sequence": bytes.decode_u32(4),
		"lifecycle_time": bytes.decode_float(8),
		"wave_time": bytes.decode_float(12),
		"fresh_foam": fresh_foam,
		"foam_history": bytes.decode_float(44),
		"threshold": threshold,
		"foam_previous_along_tangent": bytes.decode_float(52),
		"above_threshold": above_threshold,
		"threshold_edge": threshold_edge,
		"previous_lifecycle": Vector4(bytes.decode_float(64), bytes.decode_float(68), bytes.decode_float(72), bytes.decode_float(76)),
		"previous_active": previous_active,
		"nearby_event_support": bytes.decode_float(84),
		"duplicate_event": duplicate_event,
		"refractory_remaining": bytes.decode_float(92),
		"refractory_active": refractory_active,
		"foam_support": bytes.decode_float(100),
		"seed": seed,
		"event_score": bytes.decode_float(108),
		"front_activity": bytes.decode_float(112),
		"lifecycle_age": bytes.decode_float(116),
		"lifecycle_energy": bytes.decode_float(120),
		"long_surface_slope": bytes.decode_float(124),
		"classification": classification,
		"first_blocker": first_blocker,
	}
	var wrapped_delta := (state["resolved_xz"] as Vector2) - requested_xz
	var domain_m := maxf(_config.domain_size_m, 0.001)
	wrapped_delta.x -= roundf(wrapped_delta.x / domain_m) * domain_m
	wrapped_delta.y -= roundf(wrapped_delta.y / domain_m) * domain_m
	state["distance_requested_to_cell_m"] = wrapped_delta.length()
	if expected_capture_id > 0:
		var capture_state := get_breaker_detector_capture_state()
		capture_state["capture_armed"] = false
		capture_state["capture_frozen"] = _breaker_detector_capture_frozen
		capture_state["capture_complete_gpu"] = true
		capture_state["capture_invalid"] = false
		capture_state["capture_id"] = expected_capture_id
		capture_state["readback_capture_id"] = buffer_capture_id
		capture_state["readback_sequence"] = buffer_sequence
		capture_state["capture_stale_readback_accepted"] = false
		capture_state["captured_wave_time"] = float(state["wave_time"])
		capture_state["captured_lifecycle_time"] = float(state["lifecycle_time"])
		capture_state["lifecycle_step_sequence"] = int(state["lifecycle_sequence"])
		capture_state["resolved_cell_xy"] = state["cell"]
		_set_breaker_detector_capture_state(capture_state)
	_breaker_detector_probe_history.append(state.duplicate(true))
	var cutoff_s: float = float(state["lifecycle_time"]) - BREAKER_DETECTOR_PROBE_WINDOW_S
	while not _breaker_detector_probe_history.is_empty() and float(_breaker_detector_probe_history[0]["lifecycle_time"]) < cutoff_s:
		_breaker_detector_probe_history.pop_front()
	var peak_fresh := -1.0
	var peak_time := -1.0
	var peak_slope := 0.0
	var crossed_threshold := false
	var had_edge := false
	var had_seed := false
	var step_gaps := 0
	var previous_sequence := -1
	for sample in _breaker_detector_probe_history:
		peak_slope = maxf(peak_slope, float(sample["long_surface_slope"]))
		if float(sample["fresh_foam"]) > peak_fresh:
			peak_fresh = float(sample["fresh_foam"])
			peak_time = float(sample["lifecycle_time"])
		crossed_threshold = crossed_threshold or bool(sample["above_threshold"])
		had_edge = had_edge or bool(sample["threshold_edge"])
		had_seed = had_seed or float(sample["seed"]) > 0.0
		var sequence := int(sample["lifecycle_sequence"])
		if previous_sequence >= 0 and sequence > previous_sequence + 1:
			step_gaps += sequence - previous_sequence - 1
		previous_sequence = sequence
	state["peak_fresh_foam_1s"] = maxf(peak_fresh, 0.0)
	state["time_of_peak_fresh_foam_1s"] = peak_time
	state["peak_long_surface_slope_1s"] = peak_slope
	state["crossed_threshold_1s"] = crossed_threshold
	state["ever_above_threshold_1s"] = crossed_threshold
	state["had_threshold_edge_1s"] = had_edge
	state["had_seed_1s"] = had_seed
	state["sample_count_1s"] = _breaker_detector_probe_history.size()
	state["missed_lifecycle_samples_1s"] = step_gaps
	_breaker_detector_probe_latest = state


func _zeroed_probe_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(BREAKER_DETECTOR_PROBE_BYTES)
	return bytes


func _reserve_breaker_detector_probe_slot() -> int:
	if not _breaker_detector_probe_enabled or not _breaker_detector_probe_pipeline.is_valid() or _breaker_detector_probe_sets.size() != 4 * BREAKER_DETECTOR_PROBE_RING_SIZE or _breaker_detector_probe_readback_pending.size() != BREAKER_DETECTOR_PROBE_RING_SIZE or _breaker_detector_probe_slot_reserved.size() != BREAKER_DETECTOR_PROBE_RING_SIZE or _breaker_detector_probe_capture_id_by_slot.size() != BREAKER_DETECTOR_PROBE_RING_SIZE or _breaker_detector_probe_sequence_by_slot.size() != BREAKER_DETECTOR_PROBE_RING_SIZE:
		return -1
	for offset in BREAKER_DETECTOR_PROBE_RING_SIZE:
		var slot := (_breaker_detector_probe_next_slot + offset) % BREAKER_DETECTOR_PROBE_RING_SIZE
		if _breaker_detector_probe_readback_pending[slot] or _breaker_detector_probe_slot_reserved[slot]:
			continue
		_breaker_detector_probe_slot_reserved[slot] = true
		_breaker_detector_probe_capture_id_by_slot[slot] = 0
		_breaker_detector_probe_sequence_by_slot[slot] = 0
		_breaker_detector_probe_next_slot = (slot + 1) % BREAKER_DETECTOR_PROBE_RING_SIZE
		_breaker_detector_probe_captures_queued.append(slot)
		return slot
	return -1


func get_breaker_lifecycle_runtime_state() -> Dictionary:
	return _breaker_lifecycle_runtime.duplicate(true)


func get_breaker_lifecycle_sim_time() -> float:
	return _breaker_lifecycle_time


func get_runtime_resource_state() -> Dictionary:
	return get_publication_snapshot()


func shutdown() -> void:
	ready = false
	crest_ready = false
	_crest_enabled = false
	_breaker_lifecycle_enabled = false
	_breaker_lifecycle_retire_pending = false
	_crest_disable_requested = false
	if _rd == null:
		displacement_rid = RID(); normal_rid = RID(); crest_foam_rid = RID(); _crest_legacy_fresh = [RID(), RID()]; breaker_lifecycle_rid = RID(); breaker_lifecycle_ready = false
		_publish_snapshot()
		return
	_publish_snapshot()
	_free_breaker_lifecycle_resources()
	_free_crest_resources()
	for uniform_set in _uniform_sets:
		if uniform_set.is_valid(): _rd.free_rid(uniform_set)
	_uniform_sets.clear()
	for texture in [_h0, _ping_a[0], _ping_a[1], _ping_b[0], _ping_b[1], _ping_c[0], _ping_c[1], displacement_rid, normal_rid]:
		if texture.is_valid(): _rd.free_rid(texture)
	for pipeline in _pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_shaders.clear(); _pipelines.clear(); _h0 = RID(); _ping_a = [RID(), RID()]; _ping_b = [RID(), RID()]; _ping_c = [RID(), RID()]
	displacement_rid = RID(); normal_rid = RID(); crest_foam_rid = RID(); _evolve_set = RID(); _fft_sets = [RID(), RID()]; _assemble_set = RID(); _rd = null
	_publish_snapshot()


func _prepare_crest_update(delta_s: float) -> float:
	if not _crest_enabled or _crest_sets.is_empty(): return 0.0
	var input_dt := maxf(delta_s, 0.0)
	var accumulator_before := _crest_accumulator
	_crest_accumulator += input_dt
	var accumulator_after_add := _crest_accumulator
	if _crest_accumulator < 1.0 / 30.0:
		if _time_audit_enabled:
			_time_audit_record_crest(input_dt, accumulator_before, accumulator_after_add, 0.0, _crest_accumulator)
		return 0.0
	const CREST_STEP_S := 1.0 / 30.0
	var complete_steps := floori(_crest_accumulator / CREST_STEP_S)
	var crest_delta := float(complete_steps) * CREST_STEP_S
	_crest_accumulator = maxf(_crest_accumulator - crest_delta, 0.0)
	if _time_audit_enabled:
		_time_audit_record_crest(input_dt, accumulator_before, accumulator_after_add, crest_delta, _crest_accumulator)
	return crest_delta


func _dispatch_crest(list: int, groups: int, crest_delta: float) -> void:
	if crest_delta <= 0.0: return
	_rd.compute_list_bind_compute_pipeline(list, _crest_pipelines[0])
	_rd.compute_list_bind_uniform_set(list, _crest_sets[_previous_read_index * 2 + _crest_read_index], 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([
		_crest_whitecap, _crest_amount * 7.5, _crest_weight, 0.72,
		_crest_decay * 1.15 * 0.2, crest_delta, 1.0, 1.0,
		_config.domain_size_m, 0.0, 0.0, 0.0,
	]).to_byte_array(), 48)
	var foam_groups := ceili(float(_crest_resolution) / 8.0)
	_rd.compute_list_dispatch(list, foam_groups, foam_groups, 1)
	_crest_read_index = 1 - _crest_read_index
	crest_foam_rid = _crest_ping[_crest_read_index]
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _crest_pipelines[1])
	_rd.compute_list_bind_uniform_set(list, _store_sets[_previous_read_index], 0)
	_rd.compute_list_set_push_constant(list, PackedByteArray(), 0)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_previous_read_index = 1 - _previous_read_index
	_rd.compute_list_add_barrier(list)


func _dispatch_breaker_lifecycle(list: int, elapsed_s: float, wave_time_s: float) -> void:
	const STEP_S := 1.0 / 30.0
	var elapsed_received := maxf(elapsed_s, 0.0)
	var lifecycle_time_before := _breaker_lifecycle_time
	var steps_executed := 0
	_breaker_lifecycle_accumulator = minf(_breaker_lifecycle_accumulator + elapsed_received, STEP_S * 4.0)
	var values := _breaker_lifecycle_values
	var groups := ceili(float(_breaker_lifecycle_resolution) / 8.0)
	while _breaker_lifecycle_accumulator >= STEP_S:
		_breaker_lifecycle_accumulator -= STEP_S
		_breaker_lifecycle_time += STEP_S
		steps_executed += 1
		if _breaker_detector_probe_enabled:
			_breaker_detector_probe_step_sequence += 1
		var next_index := 1 - _breaker_lifecycle_index
		var set_index := _crest_read_index * 2 + _breaker_lifecycle_index
		var detector_probe_slot := -1
		var use_probe_pipeline := false
		if _breaker_detector_probe_enabled:
			detector_probe_slot = _reserve_breaker_detector_probe_slot()
			use_probe_pipeline = detector_probe_slot >= 0 and _breaker_detector_probe_pipeline.is_valid() and _breaker_detector_probe_sets.size() == 4 * BREAKER_DETECTOR_PROBE_RING_SIZE
		var capture_this_step := _breaker_detector_capture_armed and use_probe_pipeline
		var capture_id_this_step := _breaker_detector_capture_id if capture_this_step else 0
		var capture_sequence_this_step := _breaker_detector_probe_step_sequence if capture_this_step else 0
		if capture_this_step:
			_breaker_detector_probe_capture_id_by_slot[detector_probe_slot] = capture_id_this_step
			_breaker_detector_probe_sequence_by_slot[detector_probe_slot] = capture_sequence_this_step
		_rd.compute_list_bind_compute_pipeline(list, _breaker_detector_probe_pipeline if use_probe_pipeline else _breaker_lifecycle_pipeline)
		_rd.compute_list_bind_uniform_set(list, _breaker_detector_probe_sets[detector_probe_slot * 4 + set_index] if use_probe_pipeline else _breaker_lifecycle_sets[set_index], 0)
		var event_duration_s := maxf(values[1], 0.001)
		var spacing_cells := maxf(roundf(values[8] * float(_breaker_lifecycle_resolution) / maxf(_config.domain_size_m, 0.001)), 1.0)
		var wind: Vector2 = _config.wind_direction.normalized()
		var params := PackedFloat32Array([
			_config.domain_size_m, STEP_S, _breaker_lifecycle_time, spacing_cells,
			values[0], event_duration_s, values[2], values[3],
			values[4], values[5], float(capture_id_this_step) if capture_this_step else values[6], values[7],
			wind.x, wind.y,
			1.0 if use_probe_pipeline else 0.0,
			float(_breaker_detector_probe_cell.y * _breaker_lifecycle_resolution + _breaker_detector_probe_cell.x) if use_probe_pipeline else 0.0,
			values[9], values[10], wave_time_s if use_probe_pipeline else 0.0, float(_breaker_detector_probe_step_sequence) if use_probe_pipeline else 0.0,
		])
		_breaker_lifecycle_runtime = {
			"lifecycle_update_hz": 1.0 / STEP_S,
			"event_lateral_speed_mps": values[0],
			"event_duration_configured_s": values[1],
			"event_duration_sent_s": event_duration_s,
			"history_decay_s": values[2],
			"refractory_s": values[3],
			"last_update_sim_time_s": _breaker_lifecycle_time,
		}
		_rd.compute_list_set_push_constant(list, params.to_byte_array(), 80)
		_rd.compute_list_dispatch(list, groups, groups, 1)
		_rd.compute_list_add_barrier(list)
		_breaker_lifecycle_index = next_index
		breaker_lifecycle_rid = _breaker_lifecycle_ping[_breaker_lifecycle_index]
		if capture_this_step:
			_breaker_detector_capture_armed = false
			_breaker_detector_capture_freeze_pending = true
			_breaker_lifecycle_accumulator = 0.0
			var capture_wave_time := float(PackedFloat32Array([wave_time_s])[0])
			var capture_lifecycle_time := float(PackedFloat32Array([_breaker_lifecycle_time])[0])
			_breaker_detector_capture_pending_state = {
				"capture_armed": false,
				"capture_frozen": false,
				"capture_complete_gpu": false,
				"capture_invalid": false,
				"capture_id": capture_id_this_step,
				"captured_wave_time": capture_wave_time,
				"captured_lifecycle_time": capture_lifecycle_time,
				"lifecycle_step_sequence": capture_sequence_this_step,
				"resolved_cell_xy": _breaker_detector_probe_cell,
			}
			break
	if _time_audit_enabled:
		_time_audit_record_lifecycle(elapsed_received, steps_executed, lifecycle_time_before, _breaker_lifecycle_time, _breaker_lifecycle_accumulator)


func _create_breaker_lifecycle_resources() -> void:
	breaker_lifecycle_ready = false
	if not ready or not crest_ready or _breaker_lifecycle_ping[0].is_valid(): return
	_breaker_lifecycle_shader = _compile_breaker_lifecycle_shader(false)
	if not _breaker_lifecycle_shader.is_valid():
		last_error = "No se pudo compilar %s" % BREAKER_LIFECYCLE_SHADER
		return
	_breaker_lifecycle_pipeline = _rd.compute_pipeline_create(_breaker_lifecycle_shader)
	var initial := PackedByteArray()
	initial.resize(_breaker_lifecycle_resolution * _breaker_lifecycle_resolution * 8)
	for cell in _breaker_lifecycle_resolution * _breaker_lifecycle_resolution:
		initial[cell * 8 + 5] = 60 # B = float16(1), initially eligible to seed.
	for index in 2:
		_breaker_lifecycle_ping[index] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, "Ocean.BreakerLifecycle%d" % index, initial, false, _breaker_lifecycle_resolution, true)
	_breaker_event_probe = _rd.storage_buffer_create(BREAKER_EVENT_PROBE_BYTES, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	for crest_index in 2:
		for old_index in 2:
			var output := RDUniform.new()
			output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
			output.binding = 3
			output.add_id(_breaker_lifecycle_ping[1 - old_index])
			var probe := RDUniform.new()
			probe.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			probe.binding = 4
			probe.add_id(_breaker_event_probe)
			var uniforms := [_sampler_uniform(0, _crest_ping[crest_index]), _sampler_uniform(1, displacement_rid), _sampler_uniform(2, _breaker_lifecycle_ping[old_index]), output, probe]
			_breaker_lifecycle_sets.append(_rd.uniform_set_create(uniforms, _breaker_lifecycle_shader, 0))
	_breaker_lifecycle_index = 0
	_breaker_lifecycle_accumulator = 0.0
	_breaker_lifecycle_time = 0.0
	breaker_lifecycle_rid = _breaker_lifecycle_ping[0]
	breaker_lifecycle_ready = _breaker_lifecycle_pipeline.is_valid() and breaker_lifecycle_rid.is_valid() and _breaker_lifecycle_sets.size() == 4
	for rid in _breaker_lifecycle_ping + _breaker_lifecycle_sets:
		breaker_lifecycle_ready = breaker_lifecycle_ready and rid.is_valid()
	breaker_lifecycle_ready = breaker_lifecycle_ready and _breaker_event_probe.is_valid()
	if not breaker_lifecycle_ready:
		_free_breaker_lifecycle_resources()
	elif _breaker_detector_probe_enabled:
		_ensure_breaker_detector_probe_resources()


func _ensure_breaker_detector_probe_resources() -> bool:
	if _breaker_detector_probe_pipeline.is_valid() and _breaker_detector_probe_sets.size() == 4 * BREAKER_DETECTOR_PROBE_RING_SIZE:
		return true
	if _rd == null or not breaker_lifecycle_ready or not _breaker_lifecycle_pipeline.is_valid():
		return false
	_breaker_detector_probe_shader = _compile_breaker_lifecycle_shader(true)
	if not _breaker_detector_probe_shader.is_valid(): return false
	_breaker_detector_probe_pipeline = _rd.compute_pipeline_create(_breaker_detector_probe_shader)
	if not _breaker_detector_probe_pipeline.is_valid():
		last_error = "No se pudo crear el pipeline de sonda de breakers."
		_free_breaker_detector_probe_resources()
		return false
	_breaker_detector_probe_buffers.clear()
	_breaker_detector_probe_readback_pending.clear()
	_breaker_detector_probe_slot_reserved.clear()
	_breaker_detector_probe_capture_id_by_slot.clear()
	_breaker_detector_probe_sequence_by_slot.clear()
	for slot in BREAKER_DETECTOR_PROBE_RING_SIZE:
		_breaker_detector_probe_buffers.append(_rd.storage_buffer_create(BREAKER_DETECTOR_PROBE_BYTES, _zeroed_probe_bytes()))
		_breaker_detector_probe_readback_pending.append(false)
		_breaker_detector_probe_slot_reserved.append(false)
		_breaker_detector_probe_capture_id_by_slot.append(0)
		_breaker_detector_probe_sequence_by_slot.append(0)
	for slot in BREAKER_DETECTOR_PROBE_RING_SIZE:
		for crest_index in 2:
			for old_index in 2:
				var output := RDUniform.new()
				output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
				output.binding = 3
				output.add_id(_breaker_lifecycle_ping[1 - old_index])
				var event_probe := RDUniform.new()
				event_probe.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				event_probe.binding = 4
				event_probe.add_id(_breaker_event_probe)
				var detector_probe := RDUniform.new()
				detector_probe.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
				detector_probe.binding = 5
				detector_probe.add_id(_breaker_detector_probe_buffers[slot])
				var uniforms := [_sampler_uniform(0, _crest_ping[crest_index]), _sampler_uniform(1, displacement_rid), _sampler_uniform(2, _breaker_lifecycle_ping[old_index]), output, event_probe, detector_probe]
				_breaker_detector_probe_sets.append(_rd.uniform_set_create(uniforms, _breaker_detector_probe_shader, 0))
	for rid in _breaker_detector_probe_buffers + _breaker_detector_probe_sets:
		if not rid.is_valid():
			last_error = "No se pudieron crear los recursos de sonda de breakers."
			_free_breaker_detector_probe_resources()
			return false
	return _breaker_detector_probe_sets.size() == 4 * BREAKER_DETECTOR_PROBE_RING_SIZE


func _compile_breaker_lifecycle_shader(probe_variant: bool) -> RID:
	if _rd == null: return RID()
	var source := FileAccess.get_file_as_string(BREAKER_LIFECYCLE_SHADER).replace("#[compute]", "").strip_edges()
	var version_end := source.find("\n")
	if version_end < 0 or not source.begins_with("#version"):
		last_error = "No se pudo preparar el shader de ciclo de breakers."
		return RID()
	if probe_variant:
		source = source.substr(0, version_end + 1) + "#define VALIDATION_ONLY_PROBE\n" + source.substr(version_end + 1)
	var shader_source := RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source
	var spirv := _rd.shader_compile_spirv_from_source(shader_source)
	if spirv == null:
		last_error = "No se pudo compilar el shader de ciclo de breakers%s." % (" con sonda" if probe_variant else "")
		return RID()
	return _rd.shader_create_from_spirv(spirv, "Ocean.BreakerLifecycle.ValidationProbe" if probe_variant else "Ocean.BreakerLifecycle")


func _free_breaker_detector_probe_resources() -> void:
	if _rd != null:
		for rid in _breaker_detector_probe_sets + _breaker_detector_probe_buffers + [_breaker_detector_probe_pipeline, _breaker_detector_probe_shader]:
			if rid.is_valid(): _rd.free_rid(rid)
	_breaker_detector_probe_sets.clear()
	_breaker_detector_probe_buffers.clear()
	_breaker_detector_probe_pipeline = RID()
	_breaker_detector_probe_shader = RID()
	_breaker_detector_probe_readback_pending.clear()
	_breaker_detector_probe_slot_reserved.clear()
	_breaker_detector_probe_capture_id_by_slot.clear()
	_breaker_detector_probe_sequence_by_slot.clear()


func _free_breaker_lifecycle_resources() -> void:
	_free_breaker_detector_probe_resources()
	if _rd != null:
		for rid in _breaker_lifecycle_sets + _breaker_lifecycle_ping + [_breaker_lifecycle_pipeline, _breaker_lifecycle_shader, _breaker_event_probe]:
			if rid.is_valid(): _rd.free_rid(rid)
	_breaker_lifecycle_sets.clear()
	_breaker_event_probe = RID()
	_breaker_event_probe_readback_pending = false
	_breaker_detector_probe_captures_queued.clear()
	_breaker_detector_probe_next_slot = 0
	_breaker_event_probe_latest.clear()
	_breaker_detector_probe_latest.clear()
	_breaker_detector_probe_history.clear()
	_breaker_detector_probe_step_sequence = 0
	_breaker_lifecycle_ping = [RID(), RID()]
	_breaker_lifecycle_pipeline = RID()
	_breaker_lifecycle_shader = RID()
	breaker_lifecycle_rid = RID()
	breaker_lifecycle_ready = false
	_breaker_lifecycle_retire_pending = false
	_breaker_lifecycle_accumulator = 0.0


func _breaker_lifecycle_resources_valid() -> bool:
	if not breaker_lifecycle_rid.is_valid() or not _breaker_lifecycle_pipeline.is_valid() or not _breaker_event_probe.is_valid() or _breaker_lifecycle_sets.size() != 4:
		return false
	for rid in _breaker_lifecycle_ping + _breaker_lifecycle_sets:
		if not rid.is_valid():
			return false
	return true


func _create_crest_resources() -> void:
	crest_ready = false
	if not ready or _crest_ping[0].is_valid(): return
	if not _create_crest_pipeline(UPDATE_CREST_SHADER, "Ocean.UpdateCrest", 0) or not _create_crest_pipeline(STORE_PREVIOUS_SHADER, "Ocean.StoreCrestPrevious", 1):
		_free_crest_resources()
		return
	var initial := PackedByteArray(); initial.resize(_crest_resolution * _crest_resolution * 4)
	_crest_ping[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestFoamA", initial, false, _crest_resolution)
	_crest_ping[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestFoamB", initial, false, _crest_resolution)
	var legacy_initial := PackedByteArray(); legacy_initial.resize(_crest_resolution * _crest_resolution * 2)
	_crest_legacy_fresh[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, "Ocean.CrestLegacyFreshA", legacy_initial, false, _crest_resolution)
	_crest_legacy_fresh[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, "Ocean.CrestLegacyFreshB", legacy_initial, false, _crest_resolution)
	var snapshots := PackedByteArray(); snapshots.resize(_config.resolution * _config.resolution * 4)
	_previous_displacement[0] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestPreviousA", snapshots)
	_previous_displacement[1] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, "Ocean.CrestPreviousB", snapshots)
	var state := RDSamplerState.new(); state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR; state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST; state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_crest_sampler = _rd.sampler_create(state)
	for snapshot_index in 2:
		for foam_index in 2:
			_crest_sets.append(_create_crest_set(_crest_shaders[0], _previous_displacement[snapshot_index], _crest_ping[foam_index], _crest_ping[1 - foam_index], _crest_legacy_fresh[foam_index], _crest_legacy_fresh[1 - foam_index]))
		_store_sets.append(_create_store_set(_crest_shaders[1], _previous_displacement[(snapshot_index + 1) % 2]))
	_crest_read_index = 0; _previous_read_index = 0; _crest_accumulator = 0.0; crest_foam_rid = _crest_ping[0]
	crest_ready = crest_foam_rid.is_valid() and _crest_sampler.is_valid() and _crest_sets.size() == 4 and _store_sets.size() == 2
	for texture in _crest_ping + _crest_legacy_fresh + _previous_displacement:
		crest_ready = crest_ready and texture.is_valid()
	for set_rid in _crest_sets + _store_sets:
		crest_ready = crest_ready and set_rid.is_valid()
	crest_ready = crest_ready and _crest_pipelines[0].is_valid() and _crest_pipelines[1].is_valid()
	if not crest_ready:
		_free_crest_resources()


func _free_crest_resources() -> void:
	if _rd == null: return
	for uniform_set in _crest_sets + _store_sets:
		if uniform_set.is_valid(): _rd.free_rid(uniform_set)
		_uniform_sets.erase(uniform_set)
	for texture in _crest_ping + _crest_legacy_fresh + _previous_displacement:
		if texture.is_valid(): _rd.free_rid(texture)
	if _crest_sampler.is_valid(): _rd.free_rid(_crest_sampler)
	for pipeline in _crest_pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _crest_shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_crest_sets.clear(); _store_sets.clear(); _crest_ping = [RID(), RID()]; _crest_legacy_fresh = [RID(), RID()]; _previous_displacement = [RID(), RID()]; _crest_sampler = RID(); _crest_shaders = [RID(), RID()]; _crest_pipelines = [RID(), RID()]; crest_foam_rid = RID(); crest_ready = false; _crest_accumulator = 0.0


func _resources_are_ready() -> bool:
	if _rd == null or not _h0.is_valid() or not displacement_rid.is_valid() or not normal_rid.is_valid():
		return false
	for texture in _ping_a + _ping_b + _ping_c:
		if not texture.is_valid():
			return false
	for set_rid in [_evolve_set, _fft_sets[0], _fft_sets[1], _assemble_set]:
		if not set_rid.is_valid():
			return false
	return true


func _create_crest_set(shader: RID, previous_displacement: RID, previous_foam: RID, next_foam: RID, previous_legacy_fresh: RID, next_legacy_fresh: RID) -> RID:
	var output := RDUniform.new(); output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding = 3; output.add_id(next_foam)
	var legacy_output := RDUniform.new(); legacy_output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; legacy_output.binding = 5; legacy_output.add_id(next_legacy_fresh)
	var set := _rd.uniform_set_create([_sampler_uniform(0, displacement_rid), _sampler_uniform(1, previous_displacement), _sampler_uniform(2, previous_foam), output, _sampler_uniform(4, previous_legacy_fresh), legacy_output], shader, 0)
	_uniform_sets.append(set)
	return set


func _create_store_set(shader: RID, destination: RID) -> RID:
	var source := RDUniform.new(); source.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; source.binding = 0; source.add_id(displacement_rid)
	var output := RDUniform.new(); output.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding = 1; output.add_id(destination)
	var set := _rd.uniform_set_create([source, output], shader, 0)
	_uniform_sets.append(set)
	return set


func _sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var uniform := RDUniform.new(); uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; uniform.binding = binding; uniform.add_id(_crest_sampler); uniform.add_id(texture)
	return uniform


func _create_pipeline(path: String, resource_name: String) -> RID:
	var file := load(path) as RDShaderFile
	if file == null: last_error = "No se pudo cargar %s" % path; return RID()
	var shader := _rd.shader_create_from_spirv(file.get_spirv(), resource_name)
	if not shader.is_valid(): last_error = "No se pudo compilar %s" % path; return RID()
	var pipeline := _rd.compute_pipeline_create(shader); _shaders.append(shader); _pipelines.append(pipeline)
	return pipeline


func _create_crest_pipeline(path: String, resource_name: String, index: int) -> bool:
	var shader_file := load(path) as RDShaderFile
	if shader_file == null:
		last_error = "No se pudo cargar %s" % path
		return false
	var shader := _rd.shader_create_from_spirv(shader_file.get_spirv(), resource_name)
	if not shader.is_valid():
		last_error = "No se pudo compilar %s" % path
		return false
	var pipeline := _rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		_rd.free_rid(shader)
		last_error = "No se pudo crear pipeline %s" % path
		return false
	_crest_shaders[index] = shader
	_crest_pipelines[index] = pipeline
	return true


func _create_texture(format: int, resource_name: String, data := PackedByteArray(), allow_update := false, resolution_override := 0, allow_readback := false) -> RID:
	var format_info := RDTextureFormat.new(); format_info.format = format as RenderingDevice.DataFormat; format_info.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	var resolution: int = resolution_override if resolution_override > 0 else int(_config.resolution)
	format_info.width = resolution; format_info.height = resolution; format_info.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if allow_update: format_info.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	if allow_readback: format_info.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var initial: Array[PackedByteArray] = []; if not data.is_empty(): initial.append(data)
	var texture := _rd.texture_create(format_info, RDTextureView.new(), initial); _rd.set_resource_name(texture, resource_name)
	return texture


func _create_image_set(shader: RID, textures: Array[RID]) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in textures.size():
		var uniform := RDUniform.new(); uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE; uniform.binding = binding; uniform.add_id(textures[binding]); uniforms.append(uniform)
	var set := _rd.uniform_set_create(uniforms, shader, 0); _uniform_sets.append(set)
	return set
