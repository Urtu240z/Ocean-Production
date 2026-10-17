extends RefCounted
## World-anchored, visual-only interaction foam for small local watercraft wakes.

const COMPUTE_SHADER := "res://addons/ocean/shaders/interaction_foam_update.glsl"
const RESOLUTION := 512
const COVERAGE_M := 128.0
const MAX_STAMPS := 24
const UPDATE_HZ := 24.0

var ready := false
var last_error := ""
var texture_rid := RID()
var region_origin := Vector2.ZERO
var completed_updates := 0
var last_pass_submit_ms := 0.0

var _rd: RenderingDevice
var _texture := [RID(), RID()]
var _shader := RID()
var _pipeline := RID()
var _uniform_buffer := RID()
var _stamp_buffer := RID()
var _uniform_sets := [RID(), RID()]
var _read_index := 0
var _desired_center := Vector2.ZERO
var _has_center := false
var _previous_origin := Vector2.ZERO
var _accumulator := 0.0
var _energy_decay_s := 2.4
var _foam_rise_rate := 1.0
var _foam_decay_rate := 0.65
var _target_coverage := 0.34
var _energy_injection := 0.035
var _intensity := 1.1
var _width := 1.2
var _enabled := true
var _stamps: Array[Dictionary] = []
var _recent_stamps: Array[Dictionary] = []
var _total_submitted_stamps := 0
var _dropped_stamps := 0
var _outside_window_stamps := 0
var _last_stamp_count := 0
var _mutex := Mutex.new()


func initialize() -> void:
	shutdown()
	last_error = ""
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice is unavailable."
		return
	var file := load(COMPUTE_SHADER) as RDShaderFile
	if file == null:
		last_error = "Could not load %s" % COMPUTE_SHADER
		return
	_shader = _rd.shader_create_from_spirv(file.get_spirv(), "Ocean.InteractionFoam")
	if not _shader.is_valid():
		last_error = "Could not compile interaction foam shader."
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		last_error = "Could not create interaction foam pipeline."
		return
	var zeroes := PackedFloat32Array()
	zeroes.resize(RESOLUTION * RESOLUTION * 2)
	var info := RDTextureFormat.new()
	info.format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
	info.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	info.width = RESOLUTION
	info.height = RESOLUTION
	info.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var initial: Array[PackedByteArray] = [zeroes.to_byte_array()]
	for i in 2:
		_texture[i] = _rd.texture_create(info, RDTextureView.new(), initial)
		_rd.set_resource_name(_texture[i], "Ocean.InteractionFoam.History%d" % i)
	_uniform_buffer = _rd.uniform_buffer_create(64)
	_stamp_buffer = _rd.storage_buffer_create(MAX_STAMPS * 48)
	for i in 2:
		_uniform_sets[i] = _make_uniform_set(i)
	ready = _resources_valid()
	if not ready:
		last_error = "Could not create interaction foam GPU resources."
		shutdown()
		return
	_read_index = 0
	texture_rid = _texture[_read_index]
	_previous_origin = Vector2.ZERO
	region_origin = Vector2.ZERO


func set_controls(enabled: bool, energy_decay_s: float, foam_rise_rate: float, foam_decay_rate: float, target_coverage: float, energy_injection: float, intensity: float, width_m: float) -> void:
	_mutex.lock()
	_enabled = enabled
	_energy_decay_s = maxf(energy_decay_s, 0.25)
	_foam_rise_rate = maxf(foam_rise_rate, 0.05)
	_foam_decay_rate = maxf(foam_decay_rate, 0.05)
	_target_coverage = clampf(target_coverage, 0.0, 1.0)
	_energy_injection = clampf(energy_injection, 0.005, 0.2)
	_intensity = clampf(intensity, 0.0, 2.0)
	_width = clampf(width_m, 0.25, 5.0)
	_mutex.unlock()


func submit_stamp(world_position: Vector3, velocity: Vector3, strength := 1.0, landing := false) -> void:
	var velocity_xz := Vector2(velocity.x, velocity.z)
	_mutex.lock()
	_desired_center = Vector2(world_position.x, world_position.z)
	_has_center = true
	if _enabled:
		if _stamps.size() >= MAX_STAMPS:
			_stamps.pop_front()
			_dropped_stamps += 1
		var stamp := {
			"position": Vector2(world_position.x, world_position.z),
			"direction": velocity_xz.normalized() if velocity_xz.length_squared() > 0.01 else Vector2.UP,
			"strength": clampf(strength, 0.0, 2.0),
			"landing": landing,
		}
		_stamps.append(stamp)
		_recent_stamps.append(stamp.duplicate())
		if _recent_stamps.size() > 16: _recent_stamps.pop_front()
		_total_submitted_stamps += 1
	_mutex.unlock()


func advance(delta: float) -> void:
	if not ready or not _resources_valid(): return
	_accumulator += clampf(delta, 0.0, 0.1)
	if _accumulator < 1.0 / UPDATE_HZ: return
	var dt := minf(_accumulator, 0.1)
	_accumulator = 0.0
	_mutex.lock()
	var stamps := _stamps.duplicate()
	_stamps.clear()
	var desired := _desired_center
	var has_center := _has_center
	var energy_decay_s := _energy_decay_s
	var foam_rise_rate := _foam_rise_rate
	var foam_decay_rate := _foam_decay_rate
	var target_coverage := _target_coverage
	var energy_injection := _energy_injection
	var intensity := _intensity
	var width := _width
	var is_enabled := _enabled
	_mutex.unlock()
	if not is_enabled and stamps.is_empty():
		_accumulator = 0.0
		return
	var cell_size := COVERAGE_M / float(RESOLUTION)
	var target_origin := region_origin
	if has_center:
		var snapped_center := Vector2(
			floorf(desired.x / cell_size + 0.5) * cell_size,
			floorf(desired.y / cell_size + 0.5) * cell_size)
		target_origin = snapped_center - Vector2.ONE * (COVERAGE_M * 0.5)
	var params := PackedFloat32Array([
		target_origin.x, target_origin.y, region_origin.x, region_origin.y,
		dt, energy_decay_s, float(stamps.size()), cell_size,
		intensity, width, COVERAGE_M, 1.0 if is_enabled else 0.0,
		foam_rise_rate, foam_decay_rate, energy_injection, target_coverage,
	])
	_last_stamp_count = stamps.size()
	for stamp in stamps:
		var offset: Vector2 = stamp.position - target_origin
		if offset.x < 0.0 or offset.y < 0.0 or offset.x >= COVERAGE_M or offset.y >= COVERAGE_M:
			_outside_window_stamps += 1
	_rd.buffer_update(_uniform_buffer, 0, 64, params.to_byte_array())
	var stamp_data := PackedFloat32Array()
	stamp_data.resize(MAX_STAMPS * 12)
	for i in stamps.size():
		var stamp: Dictionary = stamps[i]
		var position: Vector2 = stamp["position"]
		var direction: Vector2 = stamp["direction"]
		var base := i * 12
		stamp_data[base] = position.x
		stamp_data[base + 1] = position.y
		stamp_data[base + 2] = float(stamp["strength"])
		stamp_data[base + 3] = 1.0 if bool(stamp["landing"]) else 0.0
		stamp_data[base + 4] = direction.x
		stamp_data[base + 5] = direction.y
		stamp_data[base + 6] = width
		stamp_data[base + 7] = 1.0
	_rd.buffer_update(_stamp_buffer, 0, MAX_STAMPS * 48, stamp_data.to_byte_array())
	var write_index := 1 - _read_index
	if not _rd.uniform_set_is_valid(_uniform_sets[_read_index]): return
	var submit_started_usec := Time.get_ticks_usec()
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _uniform_sets[_read_index], 0)
	_rd.compute_list_dispatch(list, ceili(float(RESOLUTION) / 8.0), ceili(float(RESOLUTION) / 8.0), 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	last_pass_submit_ms = float(Time.get_ticks_usec() - submit_started_usec) / 1000.0
	_read_index = write_index
	_previous_origin = region_origin
	region_origin = target_origin
	texture_rid = _texture[_read_index]
	completed_updates += 1


func diagnostic_state() -> Dictionary:
	_mutex.lock()
	var submitted_stamps := _total_submitted_stamps
	var enabled := _enabled
	_mutex.unlock()
	return {
		"ready": ready,
		"error": last_error,
		"resolution": RESOLUTION,
		"coverage_m": COVERAGE_M,
		"region_origin_xz": region_origin,
		"completed_updates": completed_updates,
		"energy_decay_s": _energy_decay_s,
		"foam_rise_rate": _foam_rise_rate,
		"foam_decay_rate": _foam_decay_rate,
		"target_coverage": _target_coverage,
		"energy_injection": _energy_injection,
		"recent_stamps": _recent_stamps.duplicate(true),
		"submitted_stamps": submitted_stamps,
		"dropped_stamps": _dropped_stamps,
		"outside_window_stamps": _outside_window_stamps,
		"last_stamp_count": _last_stamp_count,
		"max_stamps": MAX_STAMPS,
		"history_bytes": RESOLUTION * RESOLUTION * 2 * 4 * 2,
		"window_policy": "last_emitter_centered_128m",
		"enabled": enabled,
		"field_layout": "R=energy,G=visible_foam",
		"pass_submit_ms": last_pass_submit_ms,
	}


func shutdown() -> void:
	ready = false
	if _rd != null:
		for set_rid in _uniform_sets:
			if set_rid.is_valid() and _rd.uniform_set_is_valid(set_rid): _rd.free_rid(set_rid)
		for rid in _texture:
			if rid.is_valid(): _rd.free_rid(rid)
		for rid in [_uniform_buffer, _stamp_buffer, _pipeline, _shader]:
			if rid.is_valid(): _rd.free_rid(rid)
	_texture = [RID(), RID()]
	_uniform_sets = [RID(), RID()]
	_uniform_buffer = RID()
	_stamp_buffer = RID()
	_pipeline = RID()
	_shader = RID()
	texture_rid = RID()
	_rd = null
	_stamps.clear()
	completed_updates = 0
	last_pass_submit_ms = 0.0
	_total_submitted_stamps = 0
	_dropped_stamps = 0
	_outside_window_stamps = 0
	_last_stamp_count = 0


func _make_uniform_set(read_index: int) -> RID:
	var previous := RDUniform.new()
	previous.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	previous.binding = 0
	previous.add_id(_texture[read_index])
	var destination := RDUniform.new()
	destination.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	destination.binding = 1
	destination.add_id(_texture[1 - read_index])
	var parameters := RDUniform.new()
	parameters.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	parameters.binding = 2
	parameters.add_id(_uniform_buffer)
	var stamps := RDUniform.new()
	stamps.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	stamps.binding = 3
	stamps.add_id(_stamp_buffer)
	return _rd.uniform_set_create([previous, destination, parameters, stamps], _shader, 0)


func _resources_valid() -> bool:
	if _rd == null or not _pipeline.is_valid() or not _uniform_buffer.is_valid() or not _stamp_buffer.is_valid(): return false
	for rid in _texture:
		if not rid.is_valid(): return false
	for rid in _uniform_sets:
		if not rid.is_valid() or not _rd.uniform_set_is_valid(rid): return false
	return true
