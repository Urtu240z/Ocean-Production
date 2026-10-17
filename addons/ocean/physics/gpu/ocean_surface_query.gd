extends RefCounted
## PHYS-GPU-1: one bounded, multi-contact dispatch on the GLOBAL device.
## Main-thread submit/consume use the mutex. GPU lifetime belongs to render thread.
## A callback holds this RefCounted token alive, never an Ocean Node.

const SHADER := "res://addons/ocean/physics/gpu/ocean_surface_query.glsl"
const PHYSICAL_HEIGHTFIELD := 5
const INPUT_STRIDE := 32
const RICH_STRIDE := 96
const COMPACT_STRIDE := 64
const CONTACT_RICH_STRIDE := 128
const CONTACT_COMPACT_STRIDE := 96
const PHYSICAL_RICH_STRIDE := 160
const PHYSICAL_COMPACT_STRIDE := 128
const CONTROL_STRIDE := 32
const STATE_STRIDE := 96
enum ContactStatus { CONTINUED = 1, REACQUIRED_LOCAL = 2, COLD_ACQUIRED = 3, FAILED = 4, SHEET_HANDOFF = 5 }
enum ContactAction { ACTIVE = 1, RESET = 2, HINT = 4, OWNED_SEED = 8 }
const DEFAULT_RING_SIZE := 3
const VALID_RING_SIZES := [3, 4, 6, 8]
const MAX_CONTACTS := 1024
const METRIC_LIMIT := 16384
var _mutex := Mutex.new()
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _contact_states := RID()
var _slots: Array[Dictionary] = []
var _ring_size := DEFAULT_RING_SIZE
var _pending: Dictionary = {}
## Only submitted identity/action metadata, never q or readback history.
## A coalesced inactive/reset/occupant-change packet must still clear ownership
## in the next executed packet. Both maps are bounded by MAX_CONTACTS.
var _submitted_owners: Dictionary = {}
var _lifetime_invalidations: Dictionary = {}
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
var _validation_completed: Array[Dictionary] = []
var _stats := {"submitted": 0, "dispatched": 0, "completed": 0, "coalesced": 0,
	"heightfield_batches": 0, "heightfield_contacts": 0, "heightfield_invalid_contacts": 0,
	"superseded_results": 0, "errors": 0, "mismatches": 0, "max_in_flight": 0, "in_flight": 0,
	"completed_superseded_before_consumption": 0, "completed_arrived_after_consumption": 0,
	"consumed": 0, "target_time_rejected": 0, "latency_ms": [], "latency_ticks": [],
	"submit_us": [], "consume_us": [], "dispatch_cpu_us": [], "gpu_samples": [], "ocean_gpu_us": [], "last_error": "", "validation_capture_dropped": 0,
	"dispatch_attempts": 0, "slot_busy_count": 0, "no_free_slot": 0, "generations_skipped_before_dispatch": 0,
	"oldest_in_flight_ticks": [], "field_age_at_dispatch_ticks": [], "contact_to_submit_us": [], "submit_to_dispatch_ticks": [],
	"slot_in_flight_us": [], "callback_us": [], "callback_to_publish_us": [], "publish_to_consume_ticks": [],
	"contact_age_ticks": [], "field_age_at_consume_ticks": [], "force_application_ticks": []}


func initialize(shader_file: RDShaderFile, requested_ring_size := DEFAULT_RING_SIZE) -> void:
	_ring_size = requested_ring_size if VALID_RING_SIZES.has(requested_ring_size) else DEFAULT_RING_SIZE
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or not _rd.has_method("buffer_get_data_async"):
		_error("Global RenderingDevice async readback unavailable"); return
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "Ocean.SurfaceQuery")
	if not _shader.is_valid(): _error("query shader unavailable"); return
	_pipeline = _rd.compute_pipeline_create(_shader)
	var state := RDSamplerState.new()
	_sampler = _rd.sampler_create(state) # texelFetch; filtering/repeat are explicit in shader.
	var empty_states := PackedByteArray(); empty_states.resize(MAX_CONTACTS * STATE_STRIDE)
	_contact_states = _rd.storage_buffer_create(MAX_CONTACTS * STATE_STRIDE, empty_states)
	if not _contact_states.is_valid(): _error("contact state allocation failed"); return
	for _index in _ring_size:
		var slot := {"input": _rd.storage_buffer_create(MAX_CONTACTS * INPUT_STRIDE),
			"output": _rd.storage_buffer_create(MAX_CONTACTS * PHYSICAL_RICH_STRIDE),
			"control": _rd.storage_buffer_create(MAX_CONTACTS * CONTROL_STRIDE),
			"set": RID(), "busy": false, "request": {}, "textures": []}
		_slots.append(slot)
		if not slot.input.is_valid() or not slot.output.is_valid() or not slot.control.is_valid(): _error("ring allocation failed"); return
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


## Bounded validation capture of every persistent completion, including those
## superseded by latest-result consumption. No queue exists in ordinary runtime.
func drain_validation_completed() -> Array[Dictionary]:
	_mutex.lock(); var result := _validation_completed; _validation_completed = []; _mutex.unlock()
	return result


## Packet: repeated vec4(target_x,target_z,previous_qx,previous_qz),
## uvec4(mode: 0 material/1 world, warm_valid, vehicle_index, contact_index).
## target_time=NAN means sample next authoritative field; explicit future times
## fail rather than silently returning current water under a future-time tag.
func submit(packet: PackedByteArray, tick: int, target_time := NAN, compact := false, controls := PackedByteArray(), contact_capture_usec := -1) -> int:
	var start := Time.get_ticks_usec()
	if packet.is_empty() or packet.size() % INPUT_STRIDE != 0 or packet.size() > MAX_CONTACTS * INPUT_STRIDE:
		return -1
	var persistent := not controls.is_empty()
	var physical := persistent and packet.decode_u32(16) == 3
	if not persistent:
		for i in packet.size()/INPUT_STRIDE:
			var mode:=packet.decode_u32(i*INPUT_STRIDE+16)
			if mode>1 and mode!=4 and mode!=PHYSICAL_HEIGHTFIELD: return -1
			if mode==PHYSICAL_HEIGHTFIELD and compact: return -1
	if persistent:
		if controls.size() != packet.size(): return -1
		var occupied: Dictionary = {}
		for i in packet.size()/INPUT_STRIDE:
			var offset: int = i*CONTROL_STRIDE
			var slot_id := controls.decode_u32(offset)
			if slot_id >= MAX_CONTACTS or occupied.has(slot_id) or packet.decode_u32(i*INPUT_STRIDE+16) != (3 if physical else 2): return -1
			occupied[slot_id] = true # no two invocations may race on one state slot
	_mutex.lock()
	if _retired or not _ready:
		_mutex.unlock(); return -1
	if not persistent and not _validation_metrics:
		for i in packet.size()/INPUT_STRIDE:
			if packet.decode_u32(i*INPUT_STRIDE+16)==4: _mutex.unlock(); return -1
	if persistent and not _validation_metrics:
		for i in controls.size()/CONTROL_STRIDE:
			if controls.decode_u32(i*CONTROL_STRIDE+12)!=0: _mutex.unlock(); return -1
			if physical and (controls.decode_u32(i*CONTROL_STRIDE+8) & ContactAction.OWNED_SEED)!=0: _mutex.unlock(); return -1
	_serial += 1
	var upload_controls:=controls.duplicate()
	var carried_invalidations:Dictionary={}
	if persistent:
		for i in packet.size()/INPUT_STRIDE:
			var offset:int=i*CONTROL_STRIDE
			var slot_id:=controls.decode_u32(offset)
			var flags:=controls.decode_u32(offset+8)
			var identity:=Vector4i(packet.decode_u32(i*INPUT_STRIDE+24),packet.decode_u32(i*INPUT_STRIDE+28),controls.decode_u32(offset+4),packet.decode_u32(i*INPUT_STRIDE+16))
			var changed:bool=_submitted_owners.has(slot_id) and _submitted_owners[slot_id]!=identity
			if (flags & ContactAction.ACTIVE)==0 or (flags & ContactAction.RESET)!=0 or changed: _lifetime_invalidations[slot_id]=_serial
			_submitted_owners[slot_id]=identity
			if _lifetime_invalidations.has(slot_id):
				upload_controls.encode_u32(offset+8,flags | ContactAction.RESET)
				carried_invalidations[slot_id]=_lifetime_invalidations[slot_id]
	if not _pending.is_empty():
		_stats.coalesced += 1
		_stats.generations_skipped_before_dispatch += 1
		if _validation_trace.has(_pending.generation): _validation_trace[_pending.generation]["state"] = "coalesced"
	_pending = {"generation": _serial, "packet": packet.duplicate(), "count": packet.size() / INPUT_STRIDE,
		"contact_capture_tick": tick, "contact_capture_usec": contact_capture_usec if contact_capture_usec >= 0 else start,
		"submit_tick": tick, "submit_usec": start, "target_time": target_time, "compact": compact,
		"persistent": persistent, "physical": physical, "controls": upload_controls,"lifetime_invalidations":carried_invalidations}
	_stats.submitted += 1
	if _validation_metrics and _validation_trace.size() < METRIC_LIMIT:
		var trace := _pending.duplicate(); trace.erase("packet"); trace.erase("controls"); trace.erase("lifetime_invalidations"); trace["state"] = "submitted"
		_validation_trace[_serial] = trace
	_record("submit_us", Time.get_ticks_usec() - start)
	if contact_capture_usec >= 0: _record("contact_to_submit_us", float(start - contact_capture_usec))
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
			_record("publish_to_consume_ticks", tick - int(result.get("publish_tick", result.submit_tick)))
			_record("contact_age_ticks", tick - int(result.get("contact_capture_tick", result.submit_tick)))
			_record("field_age_at_consume_ticks", tick - int(result.field_tick))
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
	result["owned_buffers"] = _slots.size() * 3 + (1 if _contact_states.is_valid() else 0)
	result["contact_state_buffers"] = 1 if _contact_states.is_valid() else 0
	result["contact_capacity"] = MAX_CONTACTS
	result["ring_size"] = _ring_size
	result["lifetime_identity_slots"] = _submitted_owners.size()
	result["lifetime_invalidations_pending"] = _lifetime_invalidations.size()
	_mutex.unlock()
	return result


## Called in FIFO render-thread order AFTER the three authoritative dispatches.
func dispatch_after_ocean(token: RefCounted, solvers: Array, sources: Dictionary, sample_time: float, field_tick := -1, query_enqueue_usec := -1) -> void:
	if not token.is_active() or solvers.size() != 3 or sources.is_empty(): return
	_collect_timestamps()
	_mutex.lock()
	if not _ready or _retired or _pending.is_empty(): _mutex.unlock(); return
	var slot_index := -1
	var busy_count := 0
	for index in _slots.size():
		if not _slots[index].busy and slot_index < 0: slot_index = index
		elif _slots[index].busy: busy_count += 1
	_stats.dispatch_attempts += 1
	_stats.slot_busy_count += busy_count
	var oldest_ticks := 0
	for busy_slot in _slots:
		if busy_slot.busy: oldest_ticks = maxi(oldest_ticks, Engine.get_physics_frames() - int(busy_slot.request.get("dispatch_tick", Engine.get_physics_frames())))
	_record("oldest_in_flight_ticks", oldest_ticks)
	if slot_index < 0:
		_stats.no_free_slot += 1
		_mutex.unlock(); return # one pending latest packet, no queue growth
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
	request["field_tick"] = Engine.get_physics_frames() if field_tick < 0 else field_tick
	request["sample_time_gpu"] = float(PackedFloat32Array([sample_time])[0])
	request["requested_time"] = request.target_time if is_finite(float(request.target_time)) else sample_time
	request["ocean_epoch"] = token.generation
	request["config_version"] = int(runtime[0].configuration_version) if runtime.size() == 3 else 0
	request["weather_alpha"] = float(runtime[0].weather_alpha) if runtime.size() == 3 else 0.0
	request["spectrum_time"] = float(runtime[0].wave_time) if runtime.size() == 3 else sample_time
	request["dispatch_usec"] = start
	request["dispatch_tick"] = Engine.get_physics_frames()
	request["render_dispatch_tick"] = request.dispatch_tick
	request["query_enqueue_usec"] = query_enqueue_usec if query_enqueue_usec >= 0 else start
	request["slot_index"] = slot_index
	_record("field_age_at_dispatch_ticks", request.dispatch_tick - int(request.field_tick))
	_record("submit_to_dispatch_ticks", request.dispatch_tick - int(request.submit_tick))
	request["stride"] = COMPACT_STRIDE if request.compact else RICH_STRIDE
	if request.persistent: request.stride = CONTACT_COMPACT_STRIDE if request.compact else CONTACT_RICH_STRIDE
	if request.physical: request.stride = PHYSICAL_COMPACT_STRIDE if request.compact else PHYSICAL_RICH_STRIDE
	request["payload_bytes"] = int(request.count) * int(request.stride)
	request["sea_level"] = sources.sea_level
	request["first_mode"] = (request.packet as PackedByteArray).decode_u32(16)
	request["wave_time_rate"] = float(sources.get("wave_time_rate", 1.0))
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
		for item in [[14, slot.input], [15, slot.output], [16, _contact_states], [17, slot.control]]:
			var uniform := RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			uniform.binding = item[0]; uniform.add_id(item[1]); uniforms.append(uniform)
		slot.set = _rd.uniform_set_create(uniforms, _shader, 0)
		slot.textures = textures
	if not slot.set.is_valid(): _error("query uniform set unavailable"); return
	if _rd.buffer_update(slot.input, 0, request.packet.size(), request.packet) != OK: _error("input upload failed"); return
	if request.persistent and _rd.buffer_update(slot.control, 0, request.controls.size(), request.controls) != OK:
		_error("contact lifetime upload failed"); return
	var domains: Vector3 = sources.domains
	var origin: Vector2 = sources.coastal_origin; var extent: Vector2 = sources.coastal_extent
	var warp_origin: Vector2 = sources.coastal_warp_origin; var warp_extent: Vector2 = sources.coastal_warp_extent
	var push := PackedFloat32Array([domains.x, domains.y, domains.z, sources.sea_level,
		origin.x, origin.y, extent.x, extent.y, warp_origin.x, warp_origin.y, warp_extent.x, warp_extent.y,
		sources.coastal_warp_detj_safe, 1.0 if sources.coastal_enabled else 0.0, 0.01, 0.001,
		sources.clipmap_geometry_scale, sources.ocean_scale, sample_time,
		request.wave_time_rate if request.first_mode == PHYSICAL_HEIGHTFIELD else (1.0 if request.compact else 0.0)]).to_byte_array()
	push.append_array(PackedInt32Array([request.count, request.generation, request.config_version, request.ocean_epoch]).to_byte_array())
	var name := "GPU1.Query.%d" % int(request.generation)
	if _validation_metrics:
		_rd.capture_timestamp(name + ".begin")
		_timestamp_requests[name] = {"generation": request.generation, "count": request.count, "compact": request.compact, "first_mode": request.first_mode, "slot_index": slot_index}
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
	request.erase("controls")
	_mutex.lock()
	# Erase only the revision actually queued on the GPU. A newer submission
	# may have invalidated this slot while this render dispatch was prepared.
	for slot_id in request.lifetime_invalidations:
		if _lifetime_invalidations.get(slot_id,-1)==request.lifetime_invalidations[slot_id]: _lifetime_invalidations.erase(slot_id)
	request.erase("lifetime_invalidations")
	slot.busy = true; slot.request = request
	_stats.dispatched += 1; _stats.in_flight += 1
	_stats.max_in_flight = maxi(_stats.max_in_flight, _stats.in_flight)
	if _validation_trace.has(request.generation):
		_validation_trace[request.generation].merge(request,true)
		_validation_trace[request.generation]["state"] = "dispatched"
	_record("dispatch_cpu_us", Time.get_ticks_usec() - start)
	_mutex.unlock()
	request["readback_request_usec"] = Time.get_ticks_usec()
	_mutex.lock()
	if _validation_trace.has(request.generation): _validation_trace[request.generation]["readback_request_usec"] = request.readback_request_usec
	_mutex.unlock()
	var error := _rd.buffer_get_data_async(slot.output, _on_readback.bind(slot_index, request), 0, request.payload_bytes)
	if error != OK:
		_error("buffer_get_data_async error %d" % error)
		_finish_readback(PackedByteArray(), slot_index, request, Time.get_ticks_usec())


func _on_readback(bytes: PackedByteArray, slot_index: int, request: Dictionary) -> void:
	var callback_usec := Time.get_ticks_usec()
	# Publish CPU bytes under the mutex immediately. Scheduling this CPU-only
	# work back onto the render thread costs another frame of contact age.
	# RID destruction is still exclusively scheduled on the render thread.
	_finish_readback(bytes, slot_index, request, callback_usec)


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
			row["gpu_begin_ns"] = int(starts[key])
			row["gpu_end_ns"] = int(_rd.get_captured_timestamp_gpu_time(index))
			row["gpu_us"] = float(_rd.get_captured_timestamp_gpu_time(index) - int(starts[key])) / 1000.0
			_mutex.lock()
			if _validation_metrics and _stats.gpu_samples.size() < METRIC_LIMIT: _stats.gpu_samples.append(row)
			if _validation_trace.has(row.generation):
				_validation_trace[row.generation]["gpu_begin_ns"] = row.gpu_begin_ns
				_validation_trace[row.generation]["gpu_end_ns"] = row.gpu_end_ns
				_validation_trace[row.generation]["gpu_us"] = row.gpu_us
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
				var offset := index * int(request.stride) + 80
				if bytes.decode_u32(offset) != int(request.generation) or bytes.decode_u32(offset + 4) != int(request.config_version) \
						or bytes.decode_float(index * int(request.stride) + 60) != float(request.sample_time_gpu): coherent = false
		if coherent:
			if request.first_mode == PHYSICAL_HEIGHTFIELD:
				_stats.heightfield_batches += 1
				_stats.heightfield_contacts += int(request.count)
				for index in int(request.count):
					if bytes.decode_float(index * RICH_STRIDE + 28) < 0.5: _stats.heightfield_invalid_contacts += 1
			_stats.completed += 1
			if _validation_metrics and (request.persistent or request.first_mode==4) and not _retired:
				if _validation_completed.size()<32:
					var captured := request.duplicate(); captured["bytes"] = bytes
					captured["callback_usec"] = callback_usec; captured["callback_tick"] = Engine.get_physics_frames()
					_validation_completed.append(captured)
				else: _stats.validation_capture_dropped += 1
			if _validation_trace.has(request.generation):
				_validation_trace[request.generation]["callback_usec"] = callback_usec
				_validation_trace[request.generation]["callback_tick"] = Engine.get_physics_frames()
				_validation_trace[request.generation]["state"] = "completed"
			_record("callback_us", float(callback_usec - int(request.get("readback_request_usec", request.dispatch_usec))))
			if _validation_metrics and _stats.slot_in_flight_us.size() < METRIC_LIMIT:
				_stats.slot_in_flight_us.append({"slot_index": slot_index, "generation": request.generation, "duration_us": callback_usec - int(request.dispatch_usec)})
			_record("latency_ms", float(callback_usec - int(request.submit_usec)) / 1000.0)
			if not _retired and int(request.generation) > _last_consumed and (_completed.is_empty() or int(request.generation) > int(_completed.generation)):
				if not _completed.is_empty():
					_stats.superseded_results += 1
					_stats.completed_superseded_before_consumption += 1
				request["callback_usec"] = callback_usec
				request["callback_tick"] = Engine.get_physics_frames()
				request["publish_usec"] = Time.get_ticks_usec()
				request["publish_tick"] = Engine.get_physics_frames()
				_record("callback_to_publish_us", float(request.publish_usec - callback_usec))
				request["bytes"] = bytes
				_completed = request
				if _validation_trace.has(request.generation):
					_validation_trace[request.generation]["publish_usec"] = request.publish_usec
					_validation_trace[request.generation]["publish_tick"] = request.publish_tick
			else:
				_stats.superseded_results += 1
				if int(request.generation) <= _last_consumed: _stats.completed_arrived_after_consumption += 1
				else: _stats.completed_superseded_before_consumption += 1
		else: _stats.mismatches += 1
	var retired := _retired
	_mutex.unlock()
	if retired: RenderingServer.call_on_render_thread(_release_resources_if_drained)


func shutdown() -> void:
	_mutex.lock()
	_retired = true; _ready = false
	_pending = {}; _completed = {}
	_submitted_owners.clear(); _lifetime_invalidations.clear()
	_validation_completed.clear()
	_mutex.unlock()
	_release_resources_if_drained()


func _release_resources_if_drained() -> void:
	_mutex.lock()
	if int(_stats.in_flight) > 0: _mutex.unlock(); return
	_mutex.unlock()
	if _rd == null: return
	for slot in _slots:
		if slot.set.is_valid() and _rd.uniform_set_is_valid(slot.set): _rd.free_rid(slot.set)
		for rid in [slot.input, slot.output, slot.control]:
			if rid.is_valid(): _rd.free_rid(rid)
	_mutex.lock(); _slots.clear(); _mutex.unlock()
	for rid in [_pipeline, _shader, _sampler, _contact_states]:
		if rid.is_valid(): _rd.free_rid(rid)
	_pipeline = RID(); _shader = RID(); _sampler = RID(); _contact_states = RID(); _rd = null


func _record(key: String, value: float) -> void:
	if _validation_metrics and _stats[key].size() < METRIC_LIMIT: _stats[key].append(value)


func record_force_application(generation: int, tick: int) -> void:
	if generation <= 0: return
	_mutex.lock()
	if _validation_metrics and _validation_trace.has(generation):
		_validation_trace[generation]["force_application_tick"] = tick
		_validation_trace[generation]["force_application_usec"] = Time.get_ticks_usec()
		if _stats.force_application_ticks.size() < METRIC_LIMIT: _stats.force_application_ticks.append(tick)
	_mutex.unlock()


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


## Production single-valued geometry. XYZ input; q is exactly world XZ.
## No persistent ownership, inverse mapping, seeds or root selection.
static func pack_heightfield(points: PackedVector3Array) -> PackedByteArray:
	var packet := PackedByteArray(); packet.resize(points.size() * INPUT_STRIDE)
	for i in points.size():
		var offset := i * INPUT_STRIDE
		packet.encode_float(offset, points[i].x)
		packet.encode_float(offset + 4, points[i].y)
		packet.encode_float(offset + 8, points[i].z)
		packet.encode_u32(offset + 16, PHYSICAL_HEIGHTFIELD)
		packet.encode_u32(offset + 28, i)
	return packet


static func decode_heightfield(bytes: PackedByteArray, index: int) -> Dictionary:
	var o := index * RICH_STRIDE
	if bytes.size() < o + RICH_STRIDE: return {"valid": false}
	return {"valid": bytes.decode_float(o + 28) > 0.5,
		"surface_world_y": bytes.decode_float(o + 36), "signed_depth": bytes.decode_float(o + 8),
		"displacement_y": bytes.decode_float(o + 20),
		"normal": Vector3(bytes.decode_float(o + 64), bytes.decode_float(o + 68), bytes.decode_float(o + 72)),
		"surface_vertical_velocity": bytes.decode_float(o + 52), "ocean_time": bytes.decode_float(o + 60),
		"query_generation": bytes.decode_u32(o + 80), "config_generation": bytes.decode_u32(o + 84)}


## Persistent descriptor: slot, occupant generation, vehicle_id, contact_id,
## active, reset, optional hint_q (non-owned), optional owned_seed (explicit
## branch initialization). Occupant generation MUST change on reuse/removal.
## Deactivation is an explicit packet, never inferred from readback or absence.
static func pack_contacts(points: PackedVector2Array, descriptors: Array) -> Dictionary:
	if points.size() != descriptors.size(): return {}
	var packet := pack_queries(points, true)
	var controls := PackedByteArray(); controls.resize(points.size()*CONTROL_STRIDE)
	for i in points.size():
		var desc: Dictionary = descriptors[i]
		var flags: int = ContactAction.ACTIVE if desc.get("active",true) else 0
		if desc.get("reset",false): flags |= ContactAction.RESET
		if desc.has("hint_q") or desc.get("retain_hint",false): flags |= ContactAction.HINT
		if desc.get("owned_seed",false): flags |= ContactAction.OWNED_SEED
		var hint: Vector2 = desc.get("hint_q",points[i])
		if not is_finite(hint.x) or not is_finite(hint.y):
			# Malformed coordinates fail THIS contact in the shader, preserving
			# independent results for other contacts in a structurally valid batch.
			hint = Vector2.ZERO; packet.encode_float(i*INPUT_STRIDE,NAN)
		packet.encode_u32(i*INPUT_STRIDE+16,2)
		packet.encode_u32(i*INPUT_STRIDE+24,int(desc.get("vehicle_id",0)))
		packet.encode_u32(i*INPUT_STRIDE+28,int(desc.get("contact_id",i)))
		controls.encode_u32(i*CONTROL_STRIDE,int(desc.get("slot",i)))
		controls.encode_u32(i*CONTROL_STRIDE+4,int(desc.get("generation",1)))
		controls.encode_u32(i*CONTROL_STRIDE+8,flags)
		controls.encode_float(i*CONTROL_STRIDE+16,hint.x); controls.encode_float(i*CONTROL_STRIDE+20,hint.y)
	return {"packet":packet,"controls":controls}


func submit_contacts(batch: Dictionary, tick: int, target_time := NAN, compact := false) -> int:
	if batch.is_empty(): return -1
	return submit(batch.packet,tick,target_time,compact,batch.controls)


## Physical upper-envelope contact. Y determines signed immersion, never sheet
## proximity. The old pack_contacts XZ API remains numerical validation mode 2.
static func pack_physical_contacts(points: PackedVector3Array, descriptors: Array) -> Dictionary:
	var xz := PackedVector2Array()
	for point in points: xz.append(Vector2(point.x,point.z))
	var batch := pack_contacts(xz,descriptors)
	if batch.is_empty(): return {}
	for i in points.size():
		var offset := i*INPUT_STRIDE
		batch.packet.encode_float(offset+4,points[i].y)
		batch.packet.encode_float(offset+8,points[i].z)
		batch.packet.encode_float(offset+12,0.0)
		batch.packet.encode_u32(offset+16,3)
	return batch


## Validation-only fine root discovery. submit rejects this mode when validation
## telemetry is off; it cannot become an ordinary physical fallback.
static func pack_envelope_validation_queries(points: PackedVector2Array, seeds: PackedVector2Array) -> PackedByteArray:
	if points.size()!=seeds.size(): return PackedByteArray()
	var packet:=pack_queries(points,true,seeds)
	for i in points.size(): packet.encode_u32(i*INPUT_STRIDE+16,4)
	return packet


static func decode_physical_contact(result: Dictionary, index: int) -> Dictionary:
	if not result.get("physical",false) or index<0 or index>=int(result.count): return {}
	var bytes: PackedByteArray=result.bytes
	var base := index*int(result.stride)
	var ordinary := COMPACT_STRIDE if result.compact else RICH_STRIDE
	var q := Vector2(bytes.decode_float(base),bytes.decode_float(base+4))
	var displacement := Vector3(bytes.decode_float(base+16),bytes.decode_float(base+20),bytes.decode_float(base+24))
	var velocity_offset := base+(32 if result.compact else 48)
	var normal_offset := base+(48 if result.compact else 64)
	var extra := base+ordinary
	var physical_extra := extra+32
	var selected_world := Vector3(q.x+displacement.x,float(result.sea_level)+displacement.y,q.y+displacement.z)
	if not result.compact:
		selected_world=Vector3(bytes.decode_float(base+32),bytes.decode_float(base+36),bytes.decode_float(base+40))
	return {"q":q,"world":selected_world,"displacement":displacement,"surface_y":bytes.decode_float(physical_extra),
		"contact_y":bytes.decode_float(physical_extra+4),"signed_depth":bytes.decode_float(physical_extra+8),
		"previous_y":bytes.decode_float(physical_extra+12),"previous_candidate_y":bytes.decode_float(physical_extra+16),
		"maximum_candidate_y":bytes.decode_float(physical_extra+20),"height_delta":bytes.decode_float(physical_extra+24),
		"ambiguous":bytes.decode_float(physical_extra+28)>0.5,
		"residual":bytes.decode_float(base+8),"iterations":int(bytes.decode_float(base+12)),
		"valid":bytes.decode_float(base+28)>0.5,"status":bytes.decode_u32(extra),
		"solves":bytes.decode_u32(extra+4),"reason":bytes.decode_u32(extra+8),"owned":bytes.decode_u32(extra+12)!=0,
		"previous_q":Vector2(bytes.decode_float(extra+16),bytes.decode_float(extra+20)),
		"delta":bytes.decode_float(extra+24),"radius":bytes.decode_float(extra+28),
		"velocity":Vector3(bytes.decode_float(velocity_offset),bytes.decode_float(velocity_offset+4),bytes.decode_float(velocity_offset+8)),
		"normal":Vector3(bytes.decode_float(normal_offset),bytes.decode_float(normal_offset+4),bytes.decode_float(normal_offset+8)),
		"det":bytes.decode_float(base+44),
		"generation":result.generation,"config":result.config_version}
