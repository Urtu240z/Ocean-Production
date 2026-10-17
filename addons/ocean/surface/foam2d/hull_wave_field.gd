extends RefCounted
## Bakes a bounded set of finite analytic wave packets into one signed atlas.
## Local GPU dispatches; no per-pixel packet loop, no water simulation or mesh.
const RESOLUTION := 512
const COVERAGE_M := 128.0
const MAX_PACKETS := 128
var ready := false
var texture_rid := RID()
var previous_texture_rid := RID()
var _wake_accumulation := RID()
var _wake_weight_gradient := RID()
var region_origin := Vector2.ZERO
var completed_updates := 0
var localized_pixels := 0
var last_packet_count := 0
var last_error := ""
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _set := RID()

func initialize() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null: return
	var source := RDShaderSource.new()
	source.source_compute = FileAccess.get_file_as_string("res://addons/ocean/surface/foam2d/hull_wave_stamp.glsl.source")
	var spirv := _rd.shader_compile_spirv_from_source(source)
	last_error = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not last_error.is_empty():
		push_error(last_error)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var format := RDTextureFormat.new()
	format.width = RESOLUTION
	format.height = RESOLUTION
	format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	var zero := PackedByteArray()
	zero.resize(RESOLUTION*RESOLUTION*8)
	texture_rid = _rd.texture_create(format,RDTextureView.new(),[zero])
	previous_texture_rid = _rd.texture_create(format,RDTextureView.new(),[zero])
	_wake_accumulation = _rd.texture_create(format,RDTextureView.new(),[zero])
	format.format = RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
	zero.resize(RESOLUTION*RESOLUTION*4)
	_wake_weight_gradient = _rd.texture_create(format,RDTextureView.new(),[zero])
	var uniform := RDUniform.new()
	uniform.binding = 0
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.add_id(texture_rid)
	var accumulation := RDUniform.new()
	accumulation.binding = 1
	accumulation.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	accumulation.add_id(_wake_accumulation)
	var gradient := RDUniform.new()
	gradient.binding = 2
	gradient.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	gradient.add_id(_wake_weight_gradient)
	_set = _rd.uniform_set_create([uniform,accumulation,gradient],_shader,0)
	ready = true

func draw(packets: Array[Dictionary], origin: Vector2, clock: float) -> void:
	if not ready: return
	_rd.capture_timestamp("HullWaves.begin")
	# Retain the last field for smooth display between localized bakes.
	_rd.texture_copy(texture_rid,previous_texture_rid,Vector3.ZERO,Vector3.ZERO,Vector3(RESOLUTION,RESOLUTION,1),0,0,0,0)
	_rd.texture_clear(texture_rid,Color(0,0,0,0),0,1,0,1)
	var cell := COVERAGE_M/RESOLUTION
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list,_pipeline)
	_rd.compute_list_bind_uniform_set(list,_set,0)
	var owners := {}
	var impacts: Array[Dictionary] = []
	for packet in packets:
		if packet.impact:
			impacts.append(packet)
		else:
			var owner: int = packet.get("owner",0)
			if not owners.has(owner): owners[owner] = []
			owners[owner].append(packet)
	# Normalize overlaps within each boat, then add boats and impacts together.
	# Scratch storage is shared, cleared locally by each normalization dispatch.
	for group: Array in owners.values():
		var bounds := Rect2i()
		for packet: Dictionary in group:
			var rect := _packet_rect(packet,origin,clock,cell)
			if not rect.has_area(): continue
			_dispatch_packet(list,packet,rect,origin,clock,cell)
			bounds = bounds.merge(rect) if bounds.has_area() else rect
		if bounds.has_area():
			var normalize_parameters := PackedFloat32Array()
			normalize_parameters.resize(28)
			normalize_parameters[4] = bounds.position.x
			normalize_parameters[5] = bounds.position.y
			normalize_parameters[6] = bounds.size.x
			normalize_parameters[7] = bounds.size.y
			normalize_parameters[18] = 2.0
			_dispatch(list,normalize_parameters,bounds.size)
	for packet in impacts:
		var rect := _packet_rect(packet,origin,clock,cell)
		if rect.has_area(): _dispatch_packet(list,packet,rect,origin,clock,cell)
	_rd.compute_list_end()
	_rd.capture_timestamp("HullWaves.end")
	region_origin = origin
	last_packet_count = packets.size()
	completed_updates += 1

func _packet_rect(packet: Dictionary, origin: Vector2, clock: float, cell: float) -> Rect2i:
	var age: float = clock-packet.born
	var time_span: float = packet.get("time_span",packet.half_length*packet.get("inverse_speed",0.0))
	if age+time_span <= 0.0 or age-time_span >= packet.life: return Rect2i()
	var radius: float = packet.speed*clampf(age+time_span,0.0,packet.life)+packet.width*3.5+packet.get("start_radius",0.28)
	var extent := Vector2.ONE*radius
	if not packet.impact:
		var forward: Vector2 = packet.forward
		extent = forward.abs()*packet.half_length+Vector2(-forward.y,forward.x).abs()*radius
	var lo: Vector2 = ((packet.position-extent-origin)/cell).floor().clamp(Vector2.ZERO,Vector2.ONE*RESOLUTION)
	var hi: Vector2 = ((packet.position+extent-origin)/cell).ceil().clamp(Vector2.ZERO,Vector2.ONE*RESOLUTION)
	return Rect2i(Vector2i(lo),Vector2i(hi-lo))

func _dispatch_packet(list: int, packet: Dictionary, rect: Rect2i, origin: Vector2, clock: float, cell: float) -> void:
	var parameters := PackedFloat32Array([origin.x,origin.y,cell,clock-packet.born,rect.position.x,rect.position.y,rect.size.x,rect.size.y,
		packet.position.x,packet.position.y,packet.forward.x,packet.forward.y,
		packet.amplitude,packet.speed,packet.width,packet.wavelength,
		packet.life,packet.half_length,1.0 if packet.impact else 0.0,packet.get("start_radius",0.28),
		packet.get("rise",0.75),packet.get("fade",packet.life*0.45),packet.get("inverse_speed",0.0),0.0,
		clock-packet.get("source_start",clock-100000.0),packet.get("birth_distance",0.65),0.0,0.0])
	_dispatch(list,parameters,rect.size)

func _dispatch(list: int, parameters: PackedFloat32Array, extent: Vector2i) -> void:
	var bytes := parameters.to_byte_array()
	_rd.compute_list_set_push_constant(list,bytes,bytes.size())
	_rd.compute_list_dispatch(list,ceili(extent.x/8.0),ceili(extent.y/8.0),1)
	_rd.compute_list_add_barrier(list)
	localized_pixels += extent.x*extent.y

func diagnostic_state() -> Dictionary:
	return {"ready":ready,"updates":completed_updates,"packets":last_packet_count,"max_packets":MAX_PACKETS,
		"texture_bytes":RESOLUTION*RESOLUTION*28,"localized_pixels":localized_pixels,"error":last_error,
		"layout":"signed height and analytic XZ slopes; per-boat normalized continuous phase","simulation":"finite analytic packets; no FFT or PDE"}

func shutdown() -> void:
	ready = false
	if _rd == null: return
	for rid in [_set,texture_rid,previous_texture_rid,_wake_accumulation,_wake_weight_gradient,_pipeline,_shader]:
		if rid.is_valid(): _rd.free_rid(rid)
	_rd = null
	texture_rid = RID()
	previous_texture_rid = RID()
	_wake_accumulation = RID()
	_wake_weight_gradient = RID()
