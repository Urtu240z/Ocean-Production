extends RefCounted
## PHYS-GPU-1: one bounded, multi-contact dispatch on the GLOBAL device.
## Main-thread submit/consume use the mutex. GPU lifetime belongs to render thread.
## A callback holds this RefCounted token alive, never an Ocean Node.

const SHADER := "res://addons/ocean/physics/gpu/ocean_surface_query.glsl"
const INPUT_STRIDE := 32
const RICH_STRIDE := 96
const COMPACT_STRIDE := 64
const RING_SIZE := 3
const MAX_CONTACTS := 1024
const METRIC_LIMIT := 16384
var _mutex := Mutex.new()
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _slots: Array[Dictionary] = []
var _pending: Dictionary = {}
var _completed: Dictionary = {}
var _serial := 0
var _retired := false
var _ready := false
var _last_consumed := 0
var _timestamp_frame := -1
var _timestamp_requests: Dictionary = {}
var _ocean_timestamp := ""
var _validation_metrics := false
var _validation_trace: Dictionary = {}
var _stats := {"submitted": 0, "dispatched": 0, "completed": 0, "coalesced": 0,
	"superseded_results": 0, "errors": 0, "mismatches": 0, "max_in_flight": 0, "in_flight": 0,
	"consumed": 0, "target_time_rejected": 0, "latency_ms": [], "latency_ticks": [],
	"submit_us": [], "consume_us": [], "dispatch_cpu_us": [], "gpu_samples": [], "ocean_gpu_us": [], "last_error": ""}


func initialize(shader_file: RDShaderFile) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or not _rd.has_method("buffer_get_data_async"):
		_error("Global RenderingDevice async readback unavailable"); return
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "Ocean.SurfaceQuery")
	if not _shader.is_valid(): _error("query shader unavailable"); return
	_pipeline = _rd.compute_pipeline_create(_shader)
	var state := RDSamplerState.new()
	_sampler = _rd.sampler_create(state) # texelFetch; filtering/repeat are explicit in shader.
	for _index in RING_SIZE:
		var slot := {"input": _rd.storage_buffer_create(MAX_CONTACTS * INPUT_STRIDE),
			"output": _rd.storage_buffer_create(MAX_CONTACTS * RICH_STRIDE),
			"set": RID(), "busy": false, "request": {}, "textures": []}
		_slots.append(slot)
		if not slot.input.is_valid() or not slot.output.is_valid(): _error("ring allocation failed"); return
	_mutex.lock()
	_ready = _pipeline.is_valid() and _sampler.is_valid() and not _retired
	_mutex.unlock()


## Rich telemetry is validation-only; ordinary runtime retains bounded packets
## and counters. The trace holds headers, never query/result buffers.
func set_validation_metrics_enabled(enabled: bool) -> void:
	_mutex.lock(); _validation_metrics = enabled; _mutex.unlock()


func get_validation_trace() -> Array:
	_mutex.lock(); var result := _validation_trace.values().duplicate(true); _mutex.unlock()
	return result


## Packet: repeated vec4(target_x,target_z,previous_qx,previous_qz),
## uvec4(mode: 0 material/1 world, warm_valid, vehicle_index, contact_index).
## target_time=NAN means sample next authoritative field; explicit future times
## fail rather than silently returning current water under a future-time tag.
func submit(packet: PackedByteArray, tick: int, target_time := NAN, compact := false) -> int:
	var start := Time.get_ticks_usec()
	if packet.is_empty() or packet.size() % INPUT_STRIDE != 0 or packet.size() > MAX_CONTACTS * INPUT_STRIDE:
		return -1
	_mutex.lock()
	if _retired or not _ready:
		_mutex.unlock(); return -1
	_serial += 1
	if not _pending.is_empty():
		_stats.coalesced += 1
		if _validation_trace.has(_pending.generation): _validation_trace[_pending.generation]["state"] = "coalesced"
	_pending = {"generation": _serial, "packet": packet.duplicate(), "count": packet.size() / INPUT_STRIDE,
		"submit_tick": tick, "submit_usec": start, "target_time": target_time, "compact": compact}
	_stats.submitted += 1
	if _validation_metrics and _validation_trace.size() < METRIC_LIMIT:
		var trace := _pending.duplicate(); trace.erase("packet"); trace["state"] = "submitted"
		_validation_trace[_serial] = trace
	_record("submit_us", Time.get_ticks_usec() - start)
	var serial := _serial
	_mutex.unlock()
	return serial


func consume(tick: int, expected_epoch := -1, expected_config := -1) -> Dictionary:
	var start := Time.get_ticks_usec()
	_mutex.lock()
	var result := _completed
	_completed = {}
	if not result.is_empty():
		if int(result.generation) <= _last_consumed or (expected_epoch >= 0 and int(result.ocean_epoch) != expected_epoch) \
				or (expected_config >= 0 and int(result.config_version) != expected_config):
			_stats.superseded_results += 1
			result = {}
		else:
			_last_consumed = int(result.generation)
			result["consume_tick"] = tick
			result["consume_usec"] = Time.get_ticks_usec()
			if _validation_trace.has(result.generation):
				_validation_trace[result.generation]["consume_tick"] = tick
				_validation_trace[result.generation]["consume_usec"] = result.consume_usec
			_record("latency_ticks", tick - int(result.submit_tick))
			_stats.consumed += 1
	_record("consume_us", Time.get_ticks_usec() - start)
	_mutex.unlock()
	return result


func get_stats() -> Dictionary:
	_mutex.lock()
	var result := _stats.duplicate(true)
	result["ready"] = _ready
	result["retired"] = _retired
	result["pending"] = 0 if _pending.is_empty() else 1
	result["completed_pending"] = 0 if _completed.is_empty() else 1
	result["owned_buffers"] = _slots.size() * 2
	_mutex.unlock()
	return result


## Called in FIFO render-thread order AFTER the three authoritative dispatches.
func dispatch_after_ocean(token: RefCounted, solvers: Array, sources: Dictionary, sample_time: float) -> void:
	if not token.is_active() or solvers.size() != 3 or sources.is_empty(): return
	_collect_timestamps()
	_mutex.lock()
	if not _ready or _retired or _pending.is_empty(): _mutex.unlock(); return
	var slot_index := -1
	for index in _slots.size():
		if not _slots[index].busy: slot_index = index; break
	if slot_index < 0: _mutex.unlock(); return # one pending latest packet, no queue growth
	var request := _pending
	_pending = {}
	_mutex.unlock()
	if is_finite(float(request.target_time)) and absf(float(request.target_time) - sample_time) > 1e-6:
		_mutex.lock(); _stats.target_time_rejected += 1
		if _validation_trace.has(request.generation): _validation_trace[request.generation]["state"] = "target_time_rejected"
		_mutex.unlock(); return
	var start := Time.get_ticks_usec()
	var runtime: Array = token.get_runtime_spectrum()
	request["sample_time"] = sample_time
	request["sample_time_gpu"] = float(PackedFloat32Array([sample_time])[0])
	request["requested_time"] = request.target_time if is_finite(float(request.target_time)) else sample_time
	request["ocean_epoch"] = token.generation
	request["config_version"] = int(runtime[0].configuration_version) if runtime.size() == 3 else 0
	request["weather_alpha"] = float(runtime[0].weather_alpha) if runtime.size() == 3 else 0.0
	request["spectrum_time"] = float(runtime[0].wave_time) if runtime.size() == 3 else sample_time
	request["dispatch_usec"] = start
	request["dispatch_tick"] = Engine.get_physics_frames()
	request["stride"] = COMPACT_STRIDE if request.compact else RICH_STRIDE
	request["payload_bytes"] = int(request.count) * int(request.stride)
	request["sea_level"] = sources.sea_level
	request["first_mode"] = (request.packet as PackedByteArray).decode_u32(16)
	request["surface_config"] = {"domains": sources.domains, "horizontal_scale": sources.clipmap_geometry_scale,
		"vertical_scale": sources.ocean_scale, "sea_level": sources.sea_level, "coastal_enabled": sources.coastal_enabled,
		"field_origin": sources.coastal_origin, "field_extent": sources.coastal_extent,
		"warp_origin": sources.coastal_warp_origin, "warp_extent": sources.coastal_warp_extent, "detj_safe": sources.coastal_warp_detj_safe}
	var textures: Array[RID] = [sources.long, sources.mid, sources.short, sources.coastal_field, sources.coastal_warp]
	var states: Array = []
	for solver in solvers:
		var state: Dictionary = solver.get_publication_snapshot()
		if not bool(state.get("ready", false)) or int(state.generation) != int(token.generation) or not state.velocity_rid.is_valid():
			_error("incoherent/unavailable ocean query fields"); return
		states.append(state)
		textures.append(state.velocity_rid)
	for state: Dictionary in states: textures.append(state.spatial_b); textures.append(state.spatial_c)
	if runtime.size() == 3:
		for band in 3:
			if runtime[band].configuration_version != request.config_version or runtime[band].weather_alpha != request.weather_alpha:
				_error("mixed weather bands"); return
	var slot: Dictionary = _slots[slot_index]
	if slot.textures != textures or not slot.set.is_valid():
		if slot.set.is_valid() and _rd.uniform_set_is_valid(slot.set): _rd.free_rid(slot.set)
		var uniforms: Array[RDUniform] = []
		for binding in textures.size():
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			uniform.binding = binding; uniform.add_id(_sampler); uniform.add_id(textures[binding]); uniforms.append(uniform)
		for item in [[14, slot.input], [15, slot.output]]:
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			uniform.binding = item[0]; uniform.add_id(item[1]); uniforms.append(uniform)
		slot.set = _rd.uniform_set_create(uniforms, _shader, 0)
		slot.textures = textures
	if not slot.set.is_valid(): _error("query uniform set unavailable"); return
	if _rd.buffer_update(slot.input, 0, request.packet.size(), request.packet) != OK: _error("input upload failed"); return
	var domains: Vector3 = sources.domains
	var origin: Vector2 = sources.coastal_origin; var extent: Vector2 = sources.coastal_extent
	var warp_origin: Vector2 = sources.coastal_warp_origin; var warp_extent: Vector2 = sources.coastal_warp_extent
	var push := PackedFloat32Array([domains.x, domains.y, domains.z, sources.sea_level,
		origin.x, origin.y, extent.x, extent.y, warp_origin.x, warp_origin.y, warp_extent.x, warp_extent.y,
		sources.coastal_warp_detj_safe, 1.0 if sources.coastal_enabled else 0.0, 0.01, 0.001,
		sources.clipmap_geometry_scale, sources.ocean_scale, sample_time, 1.0 if request.compact else 0.0]).to_byte_array()
	push.append_array(PackedInt32Array([request.count, request.generation, request.config_version, request.ocean_epoch]).to_byte_array())
	var name := "GPU1.Query.%d" % int(request.generation)
	if _validation_metrics:
		_rd.capture_timestamp(name + ".begin")
		_timestamp_requests[name] = {"generation": request.generation, "count": request.count, "compact": request.compact, "first_mode": request.first_mode}
	# Bound timestamp bookkeeping even if the renderer omits a timestamp frame.
	if _timestamp_requests.size() > 32: _timestamp_requests.erase(_timestamp_requests.keys()[0])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, slot.set, 0)
	_rd.compute_list_set_push_constant(list, push, push.size())
	_rd.compute_list_dispatch(list, ceili(float(request.count) / 64.0), 1, 1)
	_rd.compute_list_end()
	if _validation_metrics: _rd.capture_timestamp(name + ".end")
	request.erase("packet")
	_mutex.lock()
	slot.busy = true; slot.request = request
	_stats.dispatched += 1; _stats.in_flight += 1
	_stats.max_in_flight = maxi(_stats.max_in_flight, _stats.in_flight)
	if _validation_trace.has(request.generation):
		_validation_trace[request.generation].merge(request,true)
		_validation_trace[request.generation]["state"] = "dispatched"
	_record("dispatch_cpu_us", Time.get_ticks_usec() - start)
	_mutex.unlock()
	var error := _rd.buffer_get_data_async(slot.output, _on_readback.bind(slot_index, request), 0, request.payload_bytes)
	if error != OK:
		_error("buffer_get_data_async error %d" % error)
		_finish_readback(PackedByteArray(), slot_index, request, Time.get_ticks_usec())


func _on_readback(bytes: PackedByteArray, slot_index: int, request: Dictionary) -> void:
	var callback_usec := Time.get_ticks_usec()
	RenderingServer.call_on_render_thread(_finish_readback.bind(bytes, slot_index, request, callback_usec))


func _collect_timestamps() -> void:
	if _rd == null or not _validation_metrics: return
	var frame := _rd.get_captured_timestamps_frame()
	if frame == _timestamp_frame: return
	_timestamp_frame = frame
	var starts: Dictionary = {}
	for index in _rd.get_captured_timestamps_count():
		var name := _rd.get_captured_timestamp_name(index)
		if not name.begins_with("GPU1.Query.") and not name.begins_with("GPU1.Ocean."): continue
		var key := name.trim_suffix(".begin").trim_suffix(".end")
		if name.ends_with(".begin"): starts[key] = _rd.get_captured_timestamp_gpu_time(index)
		elif starts.has(key) and name.begins_with("GPU1.Ocean."):
			_mutex.lock()
			_record("ocean_gpu_us", float(_rd.get_captured_timestamp_gpu_time(index) - int(starts[key])) / 1000.0)
			_mutex.unlock()
		elif starts.has(key) and _timestamp_requests.has(key):
			var row: Dictionary = _timestamp_requests[key]
			row["gpu_us"] = float(_rd.get_captured_timestamp_gpu_time(index) - int(starts[key])) / 1000.0
			_mutex.lock()
			if _validation_metrics and _stats.gpu_samples.size() < METRIC_LIMIT: _stats.gpu_samples.append(row)
			if _validation_trace.has(row.generation): _validation_trace[row.generation]["gpu_us"] = row.gpu_us
			_mutex.unlock()
			_timestamp_requests.erase(key)


func mark_ocean_begin(frame: int) -> void:
	if _rd == null or _retired or not _validation_metrics: return
	_ocean_timestamp = "GPU1.Ocean.%d" % frame
	_rd.capture_timestamp(_ocean_timestamp + ".begin")


func mark_ocean_end() -> void:
	if _rd != null and not _retired and _validation_metrics and not _ocean_timestamp.is_empty(): _rd.capture_timestamp(_ocean_timestamp + ".end")


func _finish_readback(bytes: PackedByteArray, slot_index: int, request: Dictionary, callback_usec: int) -> void:
	_mutex.lock()
	var slot: Dictionary = _slots[slot_index]
	if not slot.busy or slot.request.generation != request.generation:
		_stats.mismatches += 1; _mutex.unlock(); return
	_stats.in_flight -= 1
	slot.busy = false; slot.request = {}
	if bytes.size() == int(request.payload_bytes):
		var coherent := true
		if not request.compact:
			for index in int(request.count):
				var offset := index * RICH_STRIDE + 80
				if bytes.decode_u32(offset) != int(request.generation) or bytes.decode_u32(offset + 4) != int(request.config_version) \
						or bytes.decode_float(index * RICH_STRIDE + 60) != float(request.sample_time_gpu): coherent = false
		if coherent:
			_stats.completed += 1
			if _validation_trace.has(request.generation):
				_validation_trace[request.generation]["callback_usec"] = callback_usec
				_validation_trace[request.generation]["callback_tick"] = Engine.get_physics_frames()
				_validation_trace[request.generation]["state"] = "completed"
			_record("latency_ms", float(callback_usec - int(request.submit_usec)) / 1000.0)
			if not _retired and int(request.generation) > _last_consumed and (_completed.is_empty() or int(request.generation) > int(_completed.generation)):
				if not _completed.is_empty(): _stats.superseded_results += 1
				request["callback_usec"] = callback_usec
				request["callback_tick"] = Engine.get_physics_frames()
				request["bytes"] = bytes
				_completed = request
			else: _stats.superseded_results += 1
		else: _stats.mismatches += 1
	var retired := _retired
	_mutex.unlock()
	if retired: _release_resources_if_drained()


func shutdown() -> void:
	_mutex.lock()
	_retired = true; _ready = false
	_pending = {}; _completed = {}
	_mutex.unlock()
	_release_resources_if_drained()


func _release_resources_if_drained() -> void:
	_mutex.lock()
	if int(_stats.in_flight) > 0: _mutex.unlock(); return
	_mutex.unlock()
	if _rd == null: return
	for slot in _slots:
		if slot.set.is_valid() and _rd.uniform_set_is_valid(slot.set): _rd.free_rid(slot.set)
		for rid in [slot.input, slot.output]:
			if rid.is_valid(): _rd.free_rid(rid)
	_mutex.lock(); _slots.clear(); _mutex.unlock()
	for rid in [_pipeline, _shader, _sampler]:
		if rid.is_valid(): _rd.free_rid(rid)
	_pipeline = RID(); _shader = RID(); _sampler = RID(); _rd = null


func _record(key: String, value: float) -> void:
	if _validation_metrics and _stats[key].size() < METRIC_LIMIT: _stats[key].append(value)


func _error(message: String) -> void:
	_mutex.lock(); _stats.errors += 1; _stats.last_error = message; _mutex.unlock()
	push_error("PHYS-GPU-1: " + message)


static func pack_queries(points: PackedVector2Array, world := false, previous := PackedVector2Array(), contacts_per_vehicle := 8) -> PackedByteArray:
	var packet := PackedByteArray(); packet.resize(points.size() * INPUT_STRIDE)
	for index in points.size():
		var q := previous[index] if previous.size() == points.size() else points[index]
		var offset := index * INPUT_STRIDE
		packet.encode_float(offset, points[index].x); packet.encode_float(offset + 4, points[index].y)
		packet.encode_float(offset + 8, q.x); packet.encode_float(offset + 12, q.y)
		packet.encode_u32(offset + 16, 1 if world else 0)
		packet.encode_u32(offset + 20, 1 if previous.size() == points.size() else 0)
		packet.encode_u32(offset + 24, index / maxi(contacts_per_vehicle, 1))
		packet.encode_u32(offset + 28, index % maxi(contacts_per_vehicle, 1))
	return packet
