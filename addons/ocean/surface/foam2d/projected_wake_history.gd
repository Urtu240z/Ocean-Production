extends RefCounted
## Visual 2D pigment history. No wave displacement, forces, or physics queries.
const RESOLUTION := 512
const COVERAGE_M := 128.0
const MAX_STAMPS := 256
var ready := false
var texture_rid := RID()
var region_origin := Vector2.ZERO
var completed_updates := 0
var last_pass_submit_ms := 0.0
var last_error := ""
var gpu_ms: Array[float] = []
var submitted_stamps := 0
var dropped_stamps := 0
var clipped_stamps := 0
var localized_pixels := 0
var max_sweep_m := 0.0
var _rd: RenderingDevice
var _textures := [RID(), RID()]
var _shaders := [RID(), RID()]
var _pipelines := [RID(), RID()]
var _decay_sets := [RID(), RID()]
var _stamp_sets := [RID(), RID()]
var _sampler := RID()
var _read := 0
var _elapsed := 0.0
var _update_hz := 30
var _center := Vector2.ZERO
var _stamps: Array[Dictionary] = []
var _enabled := true
var _mutex := Mutex.new()
var _last_gpu_frame := -1
var _stamp_serial := 0
var _appearance := Vector4(1.7,0.95,0.28,0.9)
var _motion := Vector3(0.35,0.0,0.60)
var _edges := Vector2(0.32,0.45)
var _outward := Vector2(0.75,1.50)
var _shape := Vector2(0.56,24.0)
var _flow_time := 0.0

func initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		last_error = "RenderingDevice unavailable"
		return
	for i in 2:
		var path := "res://addons/ocean/surface/foam2d/history_%s.glsl" % ("decay" if i == 0 else "stamp")
		var file := load(path) as RDShaderFile
		var spirv := file.get_spirv()
		last_error = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not last_error.is_empty():
			push_error(last_error)
			return
		_shaders[i] = _rd.shader_create_from_spirv(spirv)
		_pipelines[i] = _rd.compute_pipeline_create(_shaders[i])
	var format := RDTextureFormat.new()
	format.width = RESOLUTION
	format.height = RESOLUTION
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var zero := PackedByteArray()
	zero.resize(RESOLUTION * RESOLUTION * 8)
	for i in 2: _textures[i] = _rd.texture_create(format, RDTextureView.new(), [zero])
	var sampling := RDSamplerState.new()
	sampling.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampling.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampling.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampling.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampling)
	for i in 2:
		_decay_sets[i] = _rd.uniform_set_create([_sample(0, _textures[i]), _image(1, _textures[1-i])], _shaders[0], 0)
		_stamp_sets[i] = _rd.uniform_set_create([_image(0, _textures[i])], _shaders[1], 0)
	texture_rid = _textures[0]
	ready = true

func _image(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.binding = binding
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.add_id(rid)
	return u

func _sample(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.binding = binding
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.add_id(_sampler)
	u.add_id(rid)
	return u

func set_controls(enabled: bool, _lifetime: float, _rise: float, _decay: float, _coverage: float, _injection: float, _intensity: float, _width: float) -> void:
	_mutex.lock()
	_enabled = enabled
	_mutex.unlock()

func set_view_center(center: Vector2) -> void:
	_mutex.lock()
	_center = center
	_mutex.unlock()

func set_appearance(parameters: Vector4) -> void:
	_mutex.lock()
	_appearance=parameters
	_mutex.unlock()

func set_motion(parameters: Vector3) -> void:
	_mutex.lock()
	_motion=parameters
	_mutex.unlock()

func set_edges(parameters: Vector2) -> void:
	_mutex.lock()
	_edges=parameters.clamp(Vector2(0.0,0.2),Vector2(0.6,0.8))
	_mutex.unlock()

func set_outward(parameters: Vector2) -> void:
	_mutex.lock()
	_outward=parameters.clamp(Vector2.ZERO,Vector2(2.0,4.0))
	_mutex.unlock()

func set_shape(parameters: Vector2) -> void:
	_mutex.lock()
	_shape = parameters.clamp(Vector2(0.2,1.0),Vector2(4.0,60.0))
	_mutex.unlock()

func submit_stamp(position: Vector3, velocity: Vector3, strength := 1.0, landing := false) -> void:
	# The unchanged Ocean API may still receive legacy deposits. Projected foam
	# is emitted by submit_hull from existing V1 contacts, never a prebuilt wake.
	pass

func submit_hull(position: Vector2, previous: Vector2, forward: Vector2, speed: float,
		wet: Vector4, birth: Vector4, interval: float, pressure := -1.0) -> void:
	_mutex.lock()
	if _enabled:
		submitted_stamps += 1
		_stamp_serial += 1
		if _stamps.size() >= MAX_STAMPS:
			_stamps.pop_front()
			dropped_stamps += 1
		_stamps.append({"position": position, "previous": previous, "forward": forward,
			"speed": speed, "wet": wet, "birth": birth, "interval": interval,
			"pressure":clampf(pressure if pressure>=0.0 else maxf(maxf(birth.x,birth.y),maxf(birth.z,birth.w)),0.0,1.0),
			"seed": float(_stamp_serial % 8192)})
	_mutex.unlock()

func set_update_hz(value: int) -> void:
	_mutex.lock()
	_update_hz = value if value in [20,30,60] else 30
	_mutex.unlock()

func advance(delta: float) -> void:
	if not ready: return
	_elapsed += delta
	_mutex.lock()
	var step := 1.0 / _update_hz
	if _elapsed + 0.000001 < step:
		_mutex.unlock()
		return
	# Consume only elapsed whole steps. The remainder belongs to the next pass;
	# counting it twice made transport/fade depend on the rendering frame rate.
	var consumed := floorf((_elapsed + 0.000001) / step) * step
	var dt := minf(consumed, 0.1)
	_elapsed = maxf(_elapsed - consumed, 0.0)
	var enabled := _enabled
	var stamps := _stamps.duplicate()
	_stamps.clear()
	var center := _center
	var appearance := _appearance
	var motion := _motion
	var edges := _edges
	var outward := _outward
	var shape := _shape
	_mutex.unlock()
	if not enabled: return
	_flow_time += dt
	var cell := COVERAGE_M / RESOLUTION
	var origin := (center / cell).round() * cell - Vector2.ONE * COVERAGE_M * 0.5
	var target := 1 - _read
	var start := Time.get_ticks_usec()
	_rd.capture_timestamp("Foam2D.begin")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[0])
	_rd.compute_list_bind_uniform_set(list, _decay_sets[_read], 0)
	var decay := PackedFloat32Array([origin.x, origin.y, region_origin.x, region_origin.y,
		dt, appearance.z, cell, 24.0/shape.y, motion.x, motion.y, motion.z, _flow_time]).to_byte_array()
	_rd.compute_list_set_push_constant(list, decay, decay.size())
	_rd.compute_list_dispatch(list, RESOLUTION / 8, RESOLUTION / 8, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[1])
	_rd.compute_list_bind_uniform_set(list, _stamp_sets[target], 0)
	for stamp in stamps:
		var position: Vector2 = stamp.position
		var previous: Vector2 = stamp.previous
		max_sweep_m = maxf(max_sweep_m, previous.distance_to(position))
		var direction: Vector2 = stamp.forward
		# Only the hull and the distance actually travelled since the last deposit.
		# A reversal never changes the footprint into a six-metre triangle.
		# Bound the entire perturbed ellipse and its soft tail at every heading.
		var radius := Vector2.ONE * (maxf(1.52,shape.x*0.5) + 0.08 + edges.x + edges.y + cell)
		var lo := ((position.min(previous) - radius - origin) / cell).floor().clamp(Vector2.ZERO, Vector2.ONE * RESOLUTION)
		var hi := ((position.max(previous) + radius - origin) / cell).ceil().clamp(Vector2.ZERO, Vector2.ONE * RESOLUTION)
		var extent := hi - lo
		if extent.x <= 0 or extent.y <= 0:
			clipped_stamps += 1
			continue
		localized_pixels += int(extent.x * extent.y)
		var radial_speed: float = outward.x*(0.80+outward.y*stamp.pressure)
		var pulse_interval: float = stamp.interval*(0.45+0.55*stamp.pressure)
		var params := PackedFloat32Array([origin.x, origin.y, cell, radial_speed, lo.x, lo.y, extent.x, extent.y,
			position.x, position.y, pulse_interval, stamp.seed, direction.x, direction.y, stamp.speed, motion.x,
			previous.x, previous.y, edges.x, edges.y,
			stamp.wet.x, stamp.wet.y, stamp.wet.z, stamp.wet.w,
			stamp.birth.x, stamp.birth.y, stamp.birth.z, stamp.birth.w,
			appearance.x,appearance.y,shape.x,appearance.w]).to_byte_array()
		_rd.compute_list_set_push_constant(list, params, params.size())
		_rd.compute_list_dispatch(list, ceili(extent.x / 8), ceili(extent.y / 8), 1)
		_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	_rd.capture_timestamp("Foam2D.end")
	last_pass_submit_ms = float(Time.get_ticks_usec() - start) / 1000.0
	_read = target
	region_origin = origin
	texture_rid = _textures[_read]
	completed_updates += 1

func _read_gpu_timing() -> void:
	var frame := _rd.get_captured_timestamps_frame()
	if frame == _last_gpu_frame: return
	_last_gpu_frame = frame
	var start := -1
	for i in _rd.get_captured_timestamps_count():
		var name := _rd.get_captured_timestamp_name(i)
		if name == "Foam2D.begin": start = _rd.get_captured_timestamp_gpu_time(i)
		if name == "Foam2D.end" and start >= 0:
			gpu_ms.append(float(_rd.get_captured_timestamp_gpu_time(i) - start) / 1000000.0)

func diagnostic_state() -> Dictionary:
	return {"ready": ready, "error": last_error, "region_origin_xz": region_origin, "coverage_m": COVERAGE_M,
		"update_hz":_update_hz,"flow_time_s":_flow_time,
		"wake_spread":_motion.x,"motion_strength":_motion.y,"motion_speed":_motion.z,
		"edge_irregularity_m":_edges.x,"edge_fade_m":_edges.y,
		"outward_speed_mps":_outward.x,"impact_outward_boost":_outward.y,
		"resolution": RESOLUTION, "history_bytes": RESOLUTION * RESOLUTION * 8 * 2,
		"max_swept_distance_m": max_sweep_m,
		"completed_updates": completed_updates, "submitted_stamps": submitted_stamps, "dropped_stamps": dropped_stamps,
		"clipped_stamps": clipped_stamps, "localized_pixels": localized_pixels,
		"pass_submit_ms": last_pass_submit_ms, "field_layout": "R=shared foam,GB=coverage times outward velocity,A=coverage times agitation",
		"emission": "swept inner hull; pigment transports outwards; no prebuilt triangle"}

func shutdown() -> void:
	ready = false
	if _rd == null: return
	for rid in _decay_sets + _stamp_sets + _textures + _pipelines + _shaders + [_sampler]:
		if rid.is_valid(): _rd.free_rid(rid)
	_rd = null
	texture_rid = RID()
