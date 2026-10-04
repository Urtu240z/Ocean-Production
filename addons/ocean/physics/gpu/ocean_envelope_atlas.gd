extends "res://addons/ocean/physics/gpu/ocean_surface_query.gd"
## Dedicated physical topology; no camera, clipmap or visual mesh dependency.
## Phase B capacity is one tile. Capacity is fixed for each resource lifetime.
const SOURCE := preload("res://addons/ocean/physics/gpu/ocean_envelope_shader_source.gd")
const DIRECTORY := "res://addons/ocean/physics/gpu/"
const MODE_PHYSICAL_ENVELOPE_ATLAS := 5
var tile_resolution := 128
var grid_resolution := 128
var tile_capacity := 1
var tile_axis := 1
var _envelope_owned: Array[RID] = []
var _color := RID()
var _depth := RID()
var _framebuffer := RID()
var _raster_shader := RID()
var _raster_pipeline := RID()
var _bounds_shader := RID()
var _bounds_pipeline := RID()
var _holes_shader := RID()
var _holes_pipeline := RID()
var _vertices := RID()
var _indices := RID()
var _tiles := RID()
var _extrema := RID()
var _query_set := RID()
var _raster_set := RID()
var _raster_tiles := RID()
var _bounds_set := RID()
var _holes_set := RID()
var _source_textures: Array[RID] = []
var _index_count := 0
var _bounds_groups := 0
var _atlas_timestamp_frame := -1

func configure(settings: Dictionary) -> void:
	# Main thread, before initialize; no live resizing or per-tick allocation.
	tile_resolution=int(settings.get("tile_resolution",128))
	grid_resolution=int(settings.get("grid_resolution",128))
	tile_capacity=int(settings.get("tile_capacity",1))
	tile_axis=1 # Phase C is gated on a successful single-tile proof.

func _physical_mode() -> int: return MODE_PHYSICAL_ENVELOPE_ATLAS
func _physical_rich_stride() -> int: return 208
func _physical_compact_stride() -> int: return 176

func _compile(stages: Dictionary) -> RID:
	var result := SOURCE.compile(_rd,stages)
	if result.has("error"): _error(result.error); return RID()
	return result.shader

func _create_query_shader(_file: RDShaderFile) -> RID:
	return _compile({RenderingDevice.SHADER_STAGE_COMPUTE:DIRECTORY+"ocean_envelope_query.comp"})

func _own(rid: RID) -> RID:
	if rid.is_valid(): _envelope_owned.append(rid)
	return rid

func _initialize_query_extension() -> bool:
	if tile_resolution not in [64,128,256,512,1024,2048] or grid_resolution not in [64,128,256,512,1024,2048] or tile_capacity!=1:
		_error("unsupported fixed atlas capacity/resolution"); return false
	var color_usage := RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	if not _rd.texture_is_format_supported_for_usage(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,color_usage) or not _rd.texture_is_format_supported_for_usage(RenderingDevice.DATA_FORMAT_D32_SFLOAT,RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT):
		_error("envelope attachment formats unavailable"); return false
	_color=_own(_target(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT,color_usage))
	_depth=_own(_target(RenderingDevice.DATA_FORMAT_D32_SFLOAT,RenderingDevice.TEXTURE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT))
	_framebuffer=_own(_rd.framebuffer_create([_color,_depth]))
	_raster_shader=_own(_compile({RenderingDevice.SHADER_STAGE_VERTEX:DIRECTORY+"ocean_envelope_raster.vert",RenderingDevice.SHADER_STAGE_FRAGMENT:DIRECTORY+"ocean_envelope_raster.frag"}))
	_bounds_shader=_own(_compile({RenderingDevice.SHADER_STAGE_COMPUTE:DIRECTORY+"ocean_envelope_bounds.comp"}))
	_holes_shader=_own(_compile({RenderingDevice.SHADER_STAGE_COMPUTE:DIRECTORY+"ocean_envelope_holes.comp"}))
	if not _framebuffer.is_valid() or not _raster_shader.is_valid() or not _bounds_shader.is_valid() or not _holes_shader.is_valid(): return false
	_bounds_pipeline=_own(_rd.compute_pipeline_create(_bounds_shader))
	_holes_pipeline=_own(_rd.compute_pipeline_create(_holes_shader))
	_tiles=_own(_rd.storage_buffer_create(tile_capacity*64))
	_extrema=_own(_rd.storage_buffer_create(64))
	var vertices := PackedVector2Array(); var indices := PackedInt32Array()
	for z in grid_resolution+1:
		for x in grid_resolution+1: vertices.append(Vector2(float(x)/grid_resolution-0.5,float(z)/grid_resolution-0.5))
	for z in grid_resolution:
		for x in grid_resolution:
			var a := z*(grid_resolution+1)+x; var b := a+1; var c := a+grid_resolution+1; var d := c+1
			indices.append_array(PackedInt32Array([a,c,b,b,c,d]))
	_index_count=indices.size()
	var vertex_buffer := _own(_rd.vertex_buffer_create(vertices.size()*8,vertices.to_byte_array()))
	var index_buffer := _own(_rd.index_buffer_create(indices.size(),RenderingDevice.INDEX_BUFFER_FORMAT_UINT32,indices.to_byte_array()))
	var attribute := RDVertexAttribute.new(); attribute.location=0; attribute.format=RenderingDevice.DATA_FORMAT_R32G32_SFLOAT; attribute.stride=8
	var format := _rd.vertex_format_create([attribute])
	_vertices=_own(_rd.vertex_array_create(vertices.size(),format,[vertex_buffer]))
	_indices=_own(_rd.index_array_create(index_buffer,0,indices.size()))
	var depth_state := RDPipelineDepthStencilState.new()
	depth_state.enable_depth_test=true; depth_state.enable_depth_write=true; depth_state.depth_compare_operator=RenderingDevice.COMPARE_OP_GREATER_OR_EQUAL
	var blend := RDPipelineColorBlendState.new(); blend.attachments=[RDPipelineColorBlendStateAttachment.new()]
	_raster_pipeline=_own(_rd.render_pipeline_create(_raster_shader,_rd.framebuffer_get_format(_framebuffer),format,RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,RDPipelineRasterizationState.new(),RDPipelineMultisampleState.new(),depth_state,blend))
	_query_set=_own(_rd.uniform_set_create([_texture_uniform(0,_color),_buffer_uniform(1,_tiles),_buffer_uniform(2,_extrema)],_shader,1))
	_raster_tiles=_own(_rd.uniform_set_create([_buffer_uniform(1,_tiles),_buffer_uniform(2,_extrema)],_raster_shader,1))
	_holes_set=_own(_rd.uniform_set_create([_texture_uniform(0,_color),_buffer_uniform(1,_extrema)],_holes_shader,0))
	for rid in [_raster_pipeline,_bounds_pipeline,_holes_pipeline,_vertices,_indices,_query_set,_raster_tiles,_holes_set]:
		if not rid.is_valid(): _error("envelope initialization RID unavailable"); return false
	_stats["envelope_gpu_samples"]=[]; _stats["bounds_gpu_samples"]=[]
	_stats["atlas_query_mismatches"]=0
	return true

func _target(format: int, usage: int) -> RID:
	var f := RDTextureFormat.new(); f.width=tile_resolution*tile_axis; f.height=f.width; f.format=format; f.usage_bits=usage
	return _rd.texture_create(f,RDTextureView.new())

func _texture_uniform(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type=RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; u.binding=binding; u.add_id(_sampler); u.add_id(texture); return u
func _buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new(); u.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER; u.binding=binding; u.add_id(buffer); return u

static func pack_envelope_contacts(points: PackedVector3Array, descriptors: Array, tiles: Array) -> Dictionary:
	var batch := pack_physical_contacts(points,descriptors)
	if batch.is_empty(): return {}
	for i in points.size():
		var tile_slot:=int(descriptors[i].get("tile_slot",0))
		if tile_slot<0 or tile_slot>=tiles.size(): return {}
		batch.packet.encode_u32(i*32+16,MODE_PHYSICAL_ENVELOPE_ATLAS)
		batch.packet.encode_u32(i*32+20,tile_slot)
		batch.controls.encode_u32(i*32+24,int(tiles[tile_slot].get("generation",1)))
	batch["tiles"]=tiles.duplicate(true)
	return batch

func submit_envelope_contacts(batch: Dictionary, tick: int, target_time := NAN, compact := false) -> int:
	if batch.is_empty() or not batch.has("tiles") or batch.tiles.is_empty() or batch.tiles.size()>tile_capacity: return -1
	for i in batch.packet.size()/32:
		if batch.packet.decode_u32(i*32+16)!=MODE_PHYSICAL_ENVELOPE_ATLAS or batch.packet.decode_u32(i*32+20)>=batch.tiles.size(): return -1
	for tile in batch.tiles:
		if not tile.has("center") or not tile.has("size"): return -1
		var center: Vector2=tile.center; var size: Vector2=tile.size
		if not is_finite(center.x) or not is_finite(center.y) or size.x<=0 or size.y<=0 or not is_finite(size.x) or not is_finite(size.y): return -1
	return submit(batch.packet,tick,target_time,compact,batch.controls,{"tiles":batch.tiles})

func submit(packet: PackedByteArray,tick:int,target_time:=NAN,compact:=false,controls:=PackedByteArray(),extension:={}) -> int:
	if packet.is_empty() or packet.size()%32!=0 or controls.size()!=packet.size() or not extension.has("tiles") or extension.tiles.size()>tile_capacity: return -1
	for i in packet.size()/32:
		if packet.decode_u32(i*32+16)!=MODE_PHYSICAL_ENVELOPE_ATLAS or packet.decode_u32(i*32+20)>=extension.tiles.size(): return -1
	return super.submit(packet,tick,target_time,compact,controls,extension)

func _prepare_query_extension(request: Dictionary, textures: Array[RID], push: PackedByteArray) -> bool:
	if not request.extension.has("tiles"): _error("envelope tile descriptor missing"); return false
	var tile_bytes := PackedByteArray(); tile_bytes.resize(tile_capacity*64)
	for i in tile_capacity:
		var offset := i*64
		tile_bytes.encode_float(offset+48,tile_resolution); tile_bytes.encode_float(offset+52,tile_axis)
		tile_bytes.encode_u32(offset+16,request.generation); tile_bytes.encode_u32(offset+20,request.config_version); tile_bytes.encode_u32(offset+24,request.ocean_epoch); tile_bytes.encode_float(offset+28,request.sample_time_gpu)
		if i>=request.extension.tiles.size(): continue
		var tile: Dictionary=request.extension.tiles[i]; var center: Vector2=tile.center; var size: Vector2=tile.size
		tile_bytes.encode_float(offset,center.x); tile_bytes.encode_float(offset+4,center.y); tile_bytes.encode_float(offset+8,size.x); tile_bytes.encode_float(offset+12,size.y)
		tile_bytes.encode_u32(offset+32,1 if tile.get("active",true) else 0); tile_bytes.encode_u32(offset+36,int(tile.get("generation",1)))
		tile_bytes.encode_u32(offset+40,int(tile.get("vehicle_id",0))); tile_bytes.encode_u32(offset+44,i)
	if _rd.buffer_update(_tiles,0,tile_bytes.size(),tile_bytes)!=OK: _error("tile upload failed"); return false
	if _source_textures!=textures:
		for rid in [_raster_set,_bounds_set]:
			if rid.is_valid() and _rd.uniform_set_is_valid(rid): _rd.free_rid(rid)
		var raster_uniforms: Array[RDUniform]=[]; var bounds_uniforms: Array[RDUniform]=[]
		for binding in textures.size(): raster_uniforms.append(_texture_uniform(binding,textures[binding]))
		_bounds_groups=0
		for binding in 5:
			bounds_uniforms.append(_texture_uniform(binding,textures[binding]))
			var format := _rd.texture_get_format(textures[binding])
			_bounds_groups=maxi(_bounds_groups,ceili(float(format.width*format.height)/256.0))
		bounds_uniforms.append(_buffer_uniform(5,_extrema))
		_raster_set=_rd.uniform_set_create(raster_uniforms,_raster_shader,0)
		_bounds_set=_rd.uniform_set_create(bounds_uniforms,_bounds_shader,0)
		_source_textures=textures.duplicate()
	if not _raster_set.is_valid() or not _bounds_set.is_valid(): _error("envelope source set unavailable"); return false
	_rd.buffer_clear(_extrema,0,64)
	var prefix := "Envelope.%d" % int(request.generation)
	if _validation_metrics: _rd.capture_timestamp(prefix+".bounds.begin")
	var list := _rd.compute_list_begin(); _rd.compute_list_bind_compute_pipeline(list,_bounds_pipeline); _rd.compute_list_bind_uniform_set(list,_bounds_set,0); _rd.compute_list_dispatch(list,_bounds_groups,5,1); _rd.compute_list_end()
	if _validation_metrics: _rd.capture_timestamp(prefix+".bounds.end"); _rd.capture_timestamp(prefix+".raster.begin")
	var draw := _rd.draw_list_begin(_framebuffer,RenderingDevice.DRAW_CLEAR_COLOR_ALL | RenderingDevice.DRAW_CLEAR_DEPTH,PackedColorArray([Color(0,0,0,0)]),0.0)
	_rd.draw_list_bind_render_pipeline(draw,_raster_pipeline); _rd.draw_list_bind_uniform_set(draw,_raster_set,0); _rd.draw_list_bind_uniform_set(draw,_raster_tiles,1)
	_rd.draw_list_bind_vertex_array(draw,_vertices); _rd.draw_list_bind_index_array(draw,_indices); _rd.draw_list_set_push_constant(draw,push,push.size())
	_rd.draw_list_draw(draw,true,tile_capacity); _rd.draw_list_end()
	if _validation_metrics:
		_rd.capture_timestamp(prefix+".raster.end")
		list=_rd.compute_list_begin(); _rd.compute_list_bind_compute_pipeline(list,_holes_pipeline); _rd.compute_list_bind_uniform_set(list,_holes_set,0); _rd.compute_list_dispatch(list,ceili(float(tile_resolution*tile_axis*tile_resolution*tile_axis)/256.0),1,1); _rd.compute_list_end()
	request["envelope"]={"tile_resolution":tile_resolution,"grid_resolution":grid_resolution,"tile_capacity":tile_capacity,"tile_generation":request.generation,"ocean_time":request.sample_time_gpu}
	return true

func _bind_query_extension(list: int) -> void:
	_rd.compute_list_bind_uniform_set(list,_query_set,1)

func _collect_timestamps() -> void:
	if _rd!=null and _validation_metrics and _atlas_timestamp_frame!=_rd.get_captured_timestamps_frame():
		_atlas_timestamp_frame=_rd.get_captured_timestamps_frame()
		var starts: Dictionary={}
		for i in _rd.get_captured_timestamps_count():
			var name := _rd.get_captured_timestamp_name(i)
			if not name.begins_with("Envelope."): continue
			var key := name.trim_suffix(".begin").trim_suffix(".end")
			if name.ends_with(".begin"): starts[key]=_rd.get_captured_timestamp_gpu_time(i)
			elif starts.has(key):
				var metric := "bounds_gpu_samples" if key.ends_with(".bounds") else "envelope_gpu_samples"
				_mutex.lock()
				if _stats[metric].size()<METRIC_LIMIT: _stats[metric].append({"generation":int(name.split(".")[1]),"gpu_us":float(_rd.get_captured_timestamp_gpu_time(i)-int(starts[key]))/1000.0})
				_mutex.unlock()
	super._collect_timestamps()

func _release_query_extension() -> void:
	for rid in [_raster_set,_bounds_set]:
		if rid.is_valid() and _rd.uniform_set_is_valid(rid): _rd.free_rid(rid)
	for i in range(_envelope_owned.size()-1,-1,-1):
		var rid := _envelope_owned[i]
		if rid.is_valid(): _rd.free_rid(rid)
	_envelope_owned.clear(); _source_textures.clear(); _raster_set=RID(); _bounds_set=RID()

func get_stats() -> Dictionary:
	var result := super.get_stats()
	result["envelope_owned_resources"]=_envelope_owned.size()+(1 if _raster_set.is_valid() else 0)+(1 if _bounds_set.is_valid() else 0)
	result["atlas_color_bytes"]=tile_capacity*tile_resolution*tile_resolution*16
	result["atlas_depth_bytes"]=tile_capacity*tile_resolution*tile_resolution*4
	result["mesh_bytes"]=(grid_resolution+1)*(grid_resolution+1)*8+grid_resolution*grid_resolution*6*4
	result["tile_state_bytes"]=tile_capacity*64+64
	return result

static func decode_envelope_contact(result: Dictionary, index: int) -> Dictionary:
	var row := decode_physical_contact(result,index)
	if row.is_empty(): return row
	var b: PackedByteArray=result.bytes; var offset := index*int(result.stride)+(128 if result.compact else 160)
	row["atlas_seed_q"]=Vector2(b.decode_float(offset),b.decode_float(offset+4)); row["atlas_y"]=b.decode_float(offset+8); row["atlas_valid"]=b.decode_float(offset+12)>0.5
	row["coverage_bound"]=Vector3(b.decode_float(offset+16),b.decode_float(offset+20),b.decode_float(offset+24)); row["atlas_holes"]=b.decode_u32(offset+28)
	row["tile_generation"]=int(b.decode_float(offset+32)); row["valid_neighbors"]=int(b.decode_float(offset+36)); row["tile_occupant_generation"]=int(b.decode_float(offset+40))
	return row
