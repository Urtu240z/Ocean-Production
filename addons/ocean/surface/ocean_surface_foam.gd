class_name OceanSurfaceFoam
extends RefCounted
## P3 owns the independent V3 J-only source, Direct-J topology and histories.
## This object is created only while Ocean > Systems > Surface Foam is enabled.

const EVOLVE := "res://addons/ocean/shaders/surface_foam/evolve_j.glsl"
const FFT := "res://addons/ocean/shaders/surface_foam/stockham_ifft.glsl"
const ASSEMBLE := "res://addons/ocean/shaders/surface_foam/assemble_jacobian.glsl"
const FIELD := "res://addons/ocean/shaders/surface_foam/update_field.glsl"
const TOPOLOGY := "res://addons/ocean/shaders/surface_foam/build_topology.glsl"
const DOWNSAMPLE := "res://addons/ocean/shaders/surface_foam/downsample_topology.glsl"
const MID_HISTORY := "res://addons/ocean/shaders/surface_foam/update_mid_history.glsl"

const SOURCE_RESOLUTION := 512
const SOURCE_DOMAIN_M := 14.5
const FIELD_RESOLUTION := 1024
const FIELD_DOMAIN_M := 88.0
const TOPOLOGY_RESOLUTION := 512
const UPDATE_HZ := 30.0
const PASS_BUDGET := 24

var ready := false
var last_error := ""
var field_rid := RID()
var topology_rid := RID()
var mid_history_rid := RID()

var _rd: RenderingDevice
var _h0 := RID()
var _ping := [RID(), RID()]
var _jacobian := [RID(), RID()]
var _field := [RID(), RID()]
var _topology := [RID(), RID()]
var _topology_views := [[], []]
var _mid_history := [RID(), RID()]
var _sampler := RID()
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _sets: Array[RID] = []
var _evolve_set := RID()
var _fft_sets := [RID(), RID()]
var _assemble_sets := [RID(), RID()]
var _field_sets: Array[RID] = []
var _topology_sets: Array[RID] = []
var _downsample_sets := [[], []]
var _mid_sets: Array[RID] = []
var _evolve_buffer := RID()
var _fft_buffer := RID()
var _assemble_buffer := RID()
var _field_buffer := RID()
var _topology_buffer := RID()
var _read_jacobian := 0
var _read_field := 0
var _read_mid := 0
var _accumulator := 0.0
var _spectral_time := 0.0
var _job_active := false
var _job_pass := 0
var _job_delta := 0.0
var _job_write_jacobian := 0
var _job_write_field := 0
var _job_write_mid := 0
var _pass_credit := 0.0


func initialize(seed: int, mid_displacement: RID, mid_resolution: int) -> void:
	shutdown()
	_rd = RenderingServer.get_rendering_device()
	if _rd == null or not mid_displacement.is_valid():
		last_error = "Surface Foam requiere RenderingDevice y el desplazamiento MID."
		return
	for path in [EVOLVE, FFT, ASSEMBLE, FIELD, TOPOLOGY, DOWNSAMPLE, MID_HISTORY]:
		if not _create_pipeline(path):
			shutdown()
			return
	_sampler = _create_sampler()
	_h0 = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, SOURCE_RESOLUTION, "Ocean.SurfaceFoam.H0", _build_h0(seed), true)
	for i in 2:
		_ping[i] = _create_texture(RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, SOURCE_RESOLUTION, "Ocean.SurfaceFoam.Packed%d" % i)
		_jacobian[i] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, SOURCE_RESOLUTION, "Ocean.SurfaceFoam.Jacobian%d" % i)
		_field[i] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, FIELD_RESOLUTION, "Ocean.SurfaceFoam.Field%d" % i)
		_topology[i] = _create_texture(RenderingDevice.DATA_FORMAT_R16G16_SFLOAT, TOPOLOGY_RESOLUTION, "Ocean.SurfaceFoam.Topology%d" % i, PackedByteArray(), false, true)
		_mid_history[i] = _create_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT, mid_resolution, "Ocean.SurfaceFoam.MidHistory%d" % i)
	_evolve_buffer = _rd.uniform_buffer_create(16)
	_fft_buffer = _rd.uniform_buffer_create(16)
	_assemble_buffer = _rd.uniform_buffer_create(16, PackedFloat32Array([1.0, 0.0, 0.0, 0.0]).to_byte_array())
	_field_buffer = _rd.uniform_buffer_create(48)
	_topology_buffer = _rd.uniform_buffer_create(16, PackedFloat32Array([0.58, 0.4, SOURCE_DOMAIN_M, float(TOPOLOGY_RESOLUTION)]).to_byte_array())
	_evolve_set = _image_set(0, [_h0, _ping[0]], _evolve_buffer)
	_fft_sets[0] = _image_set(1, [_ping[0], _ping[1]], _fft_buffer)
	_fft_sets[1] = _image_set(1, [_ping[1], _ping[0]], _fft_buffer)
	for i in 2:
		_assemble_sets[i] = _image_set(2, [_ping[0], _jacobian[i]], _assemble_buffer)
	for j in 2:
		for f in 2: _field_sets.append(_field_set(_jacobian[j], _field[f], _field[1 - f]))
		_topology_views[j] = _create_mip_views(_topology[j])
		_topology_sets.append(_topology_set(_jacobian[j], _topology_views[j][0]))
		for mip in range(1, _topology_views[j].size()): _downsample_sets[j].append(_downsample_set(_topology_views[j][mip - 1], _topology_views[j][mip]))
	for h in 2: _mid_sets.append(_mid_set(mid_displacement, _mid_history[h], _mid_history[1 - h]))
	ready = _resources_are_current()
	if not ready:
		last_error = "No se pudieron crear los recursos Surface Foam P3."
		return
	field_rid = _field[0]; topology_rid = _topology[0]; mid_history_rid = _mid_history[0]


func advance(delta_s: float) -> void:
	if not ready: return
	var safe_delta := maxf(delta_s, 0.0)
	_accumulator += safe_delta
	_pass_credit = minf(_pass_credit + total_job_passes() * UPDATE_HZ * safe_delta, float(total_job_passes() * 2))
	if not _job_active and _accumulator >= 1.0 / UPDATE_HZ:
		_job_active = true
		_job_pass = 0
		_job_delta = _accumulator
		_accumulator = 0.0
		_spectral_time += _job_delta * 0.59
		_job_write_jacobian = 1 - _read_jacobian
		_job_write_field = 1 - _read_field
		_job_write_mid = 1 - _read_mid
	var pass_budget := mini(int(floor(_pass_credit)), PASS_BUDGET)
	if pass_budget <= 0 or not _job_active: return
	_pass_credit -= float(pass_budget)
	for _unused in pass_budget:
		if not _job_active: break
		if not _dispatch_job_pass():
			_abort_job("P3 canceló un job con recursos inválidos.")
			break


func total_job_passes() -> int:
	# Evolve + 18 IFFT butterflies + assemble + field + topology + its mips + MID.
	return 22 + _downsample_sets[0].size() + 1


func _dispatch_job_pass() -> bool:
	if not _resources_are_current(): return false
	var source_groups := ceili(float(SOURCE_RESOLUTION) / 8.0)
	var fft_first := 1
	var fft_last := fft_first + 18 - 1
	var assemble_pass := fft_last + 1
	var field_pass := assemble_pass + 1
	var topology_pass := field_pass + 1
	var first_mip_pass: int = topology_pass + 1
	var mid_pass: int = first_mip_pass + _downsample_sets[_job_write_jacobian].size()
	if _job_pass == 0:
		_rd.buffer_update(_evolve_buffer, 0, 16, PackedFloat32Array([_spectral_time, 9.81, 20.0, SOURCE_DOMAIN_M]).to_byte_array())
		if not _dispatch(0, _evolve_set, source_groups, source_groups): return false
	elif _job_pass >= fft_first and _job_pass <= fft_last:
		var fft_index := _job_pass - fft_first
		var axis := fft_index / 9
		var stage := fft_index % 9
		_rd.buffer_update(_fft_buffer, 0, 16, PackedInt32Array([2 << stage, axis, SOURCE_RESOLUTION, 1]).to_byte_array())
		if not _dispatch(1, _fft_sets[fft_index % 2], source_groups, source_groups): return false
	elif _job_pass == assemble_pass:
		if not _dispatch(2, _assemble_sets[_job_write_jacobian], source_groups, source_groups): return false
	elif _job_pass == field_pass:
		var foam_bytes := PackedFloat32Array([0.58, 2.05, 0.28, 1.0, _job_delta, 0.16, 1.10, 0.12, FIELD_DOMAIN_M, SOURCE_DOMAIN_M, 2.25, 0.0]).to_byte_array()
		_rd.buffer_update(_field_buffer, 0, 48, foam_bytes)
		if not _dispatch(3, _field_sets[_job_write_jacobian * 2 + _read_field], ceili(float(FIELD_RESOLUTION) / 8.0), ceili(float(FIELD_RESOLUTION) / 8.0)): return false
	elif _job_pass == topology_pass:
		if not _dispatch(4, _topology_sets[_job_write_jacobian], ceili(float(TOPOLOGY_RESOLUTION) / 8.0), ceili(float(TOPOLOGY_RESOLUTION) / 8.0)): return false
	elif _job_pass >= first_mip_pass and _job_pass < mid_pass:
		var mip := _job_pass - first_mip_pass
		var mip_resolution := maxi(TOPOLOGY_RESOLUTION >> (mip + 1), 1)
		if not _dispatch(5, _downsample_sets[_job_write_jacobian][mip], ceili(float(mip_resolution) / 8.0), ceili(float(mip_resolution) / 8.0)): return false
	else:
		if not _dispatch_mid(_job_delta, ceili(float(_texture_resolution(_mid_history[0])) / 8.0)): return false
	_job_pass += 1
	if _job_pass < total_job_passes(): return true
	# Publish only after every write, including the topology mip chain and MID
	# eligibility, is complete. Render samples the last fully published state.
	_read_jacobian = _job_write_jacobian
	_read_field = _job_write_field
	_read_mid = _job_write_mid
	field_rid = _field[_read_field]
	topology_rid = _topology[_read_jacobian]
	mid_history_rid = _mid_history[_read_mid]
	_job_active = false
	return true


func diagnostic_state() -> Dictionary:
	return {"source_resolution": SOURCE_RESOLUTION, "source_domain_m": SOURCE_DOMAIN_M, "auxiliary_iffts": 1, "ifft_butterfly_dispatches": 18, "field_resolution": FIELD_RESOLUTION, "field_domain_m": FIELD_DOMAIN_M, "topology_resolution": TOPOLOGY_RESOLUTION, "topology_format": "RG16F", "topology_mips": 10, "update_hz": UPDATE_HZ}


func shutdown() -> void:
	ready = false
	if _rd == null:
		field_rid = RID(); topology_rid = RID(); mid_history_rid = RID()
		return
	for set_rid in _sets:
		if _rd.uniform_set_is_valid(set_rid): _rd.free_rid(set_rid)
	for views in _topology_views:
		for view in views:
			if view.is_valid(): _rd.free_rid(view)
	for texture in [_h0, _ping[0], _ping[1], _jacobian[0], _jacobian[1], _field[0], _field[1], _topology[0], _topology[1], _mid_history[0], _mid_history[1]]:
		if texture.is_valid(): _rd.free_rid(texture)
	for buffer in [_evolve_buffer, _fft_buffer, _assemble_buffer, _field_buffer, _topology_buffer, _sampler]:
		if buffer.is_valid(): _rd.free_rid(buffer)
	for pipeline in _pipelines:
		if pipeline.is_valid(): _rd.free_rid(pipeline)
	for shader in _shaders:
		if shader.is_valid(): _rd.free_rid(shader)
	_h0=RID(); _ping=[RID(),RID()]; _jacobian=[RID(),RID()]; _field=[RID(),RID()]; _topology=[RID(),RID()]; _mid_history=[RID(),RID()]; _topology_views=[[],[]]; _sets.clear(); _shaders.clear(); _pipelines.clear(); _field_sets.clear(); _topology_sets.clear(); _downsample_sets=[[],[]]; _mid_sets.clear(); _job_active=false; _job_pass=0; _job_delta=0.0; _pass_credit=0.0; _accumulator=0.0; _rd=null; field_rid=RID(); topology_rid=RID(); mid_history_rid=RID()


func _dispatch(pipeline_index: int, set_rid: RID, groups_x: int, groups_y: int) -> bool:
	if _rd == null or pipeline_index < 0 or pipeline_index >= _pipelines.size() or not _pipelines[pipeline_index].is_valid() or not _rd.uniform_set_is_valid(set_rid): return false
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[pipeline_index])
	_rd.compute_list_bind_uniform_set(list, set_rid, 0)
	_rd.compute_list_dispatch(list, groups_x, groups_y, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	return true


func _dispatch_mid(step: float, groups: int) -> bool:
	if _rd == null or _pipelines.size() <= 6 or _mid_sets.size() != 2 or not _pipelines[6].is_valid() or not _rd.uniform_set_is_valid(_mid_sets[_read_mid]): return false
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[6])
	_rd.compute_list_bind_uniform_set(list, _mid_sets[_read_mid], 0)
	_rd.compute_list_set_push_constant(list, PackedFloat32Array([step, 0.16, 1.10, 0.0, 0.0, 1.0, 0.0, 0.0]).to_byte_array(), 32)
	_rd.compute_list_dispatch(list, groups, groups, 1)
	_rd.compute_list_add_barrier(list)
	_rd.compute_list_end()
	return true


func _resources_are_current() -> bool:
	if _rd == null or not _rd.uniform_set_is_valid(_evolve_set) or not _rd.uniform_set_is_valid(_fft_sets[0]) or not _rd.uniform_set_is_valid(_fft_sets[1]): return false
	if _assemble_sets.size() != 2 or _field_sets.size() != 4 or _topology_sets.size() != 2 or _mid_sets.size() != 2 or _pipelines.size() != 7: return false
	for set_rid in _assemble_sets + _field_sets + _topology_sets + _mid_sets:
		if not _rd.uniform_set_is_valid(set_rid): return false
	return true


func _abort_job(reason: String) -> void:
	last_error = reason
	_job_active = false
	_job_pass = 0
	_pass_credit = 0.0


func _create_pipeline(path: String) -> bool:
	var file := load(path) as RDShaderFile
	if file == null: last_error = "No se pudo cargar %s" % path; return false
	var shader := _rd.shader_create_from_spirv(file.get_spirv(), "Ocean.SurfaceFoam")
	if not shader.is_valid(): last_error = "No se pudo compilar %s" % path; return false
	var pipeline := _rd.compute_pipeline_create(shader)
	if not pipeline.is_valid(): _rd.free_rid(shader); last_error = "No se pudo crear pipeline %s" % path; return false
	_shaders.append(shader); _pipelines.append(pipeline); return true


func _create_texture(format: int, resolution: int, name: String, data := PackedByteArray(), can_update := false, mipmaps := false) -> RID:
	var info := RDTextureFormat.new(); info.format = format as RenderingDevice.DataFormat; info.texture_type = RenderingDevice.TEXTURE_TYPE_2D; info.width = resolution; info.height = resolution; info.mipmaps = 10 if mipmaps else 1; info.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	if can_update: info.usage_bits |= RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial: Array[PackedByteArray] = []; if not data.is_empty(): initial.append(data)
	var texture := _rd.texture_create(info, RDTextureView.new(), initial); _rd.set_resource_name(texture, name); return texture


func _create_sampler() -> RID:
	var state := RDSamplerState.new(); state.mag_filter=RenderingDevice.SAMPLER_FILTER_LINEAR; state.min_filter=RenderingDevice.SAMPLER_FILTER_LINEAR; state.mip_filter=RenderingDevice.SAMPLER_FILTER_LINEAR; state.repeat_u=RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; state.repeat_v=RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT; return _rd.sampler_create(state)


func _image_set(pipeline_index: int, images: Array, buffer: RID) -> RID:
	var uniforms: Array[RDUniform] = []
	for binding in images.size():
		var item := RDUniform.new(); item.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE; item.binding=binding; item.add_id(images[binding]); uniforms.append(item)
	var parameter := RDUniform.new(); parameter.uniform_type=RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; parameter.binding=2; parameter.add_id(buffer); uniforms.append(parameter)
	return _track_set(uniforms, pipeline_index)


func _field_set(jacobian: RID, previous: RID, next: RID) -> RID:
	var uniforms: Array[RDUniform] = [_sampled(0,jacobian), _sampled(1,previous)]
	var output:=RDUniform.new(); output.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding=2; output.add_id(next); uniforms.append(output)
	var params:=RDUniform.new(); params.uniform_type=RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; params.binding=3; params.add_id(_field_buffer); uniforms.append(params)
	return _track_set(uniforms,3)


func _topology_set(jacobian: RID, topology: RID) -> RID:
	var output:=RDUniform.new(); output.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding=1; output.add_id(topology)
	var params:=RDUniform.new(); params.uniform_type=RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER; params.binding=2; params.add_id(_topology_buffer)
	return _track_set([_sampled(0,jacobian),output,params],4)


func _downsample_set(source: RID, destination: RID) -> RID:
	var output:=RDUniform.new(); output.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding=1; output.add_id(destination)
	return _track_set([_sampled(0,source),output],5)


func _mid_set(displacement: RID, previous: RID, next: RID) -> RID:
	var output:=RDUniform.new(); output.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE; output.binding=2; output.add_id(next)
	return _track_set([_sampled(0,displacement),_sampled(1,previous),output],6)


func _sampled(binding: int, texture: RID) -> RDUniform:
	var item:=RDUniform.new(); item.uniform_type=RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE; item.binding=binding; item.add_id(_sampler); item.add_id(texture); return item


func _track_set(uniforms: Array, pipeline_index: int) -> RID:
	var set_rid:=_rd.uniform_set_create(uniforms,_shaders[pipeline_index],0)
	if not _rd.uniform_set_is_valid(set_rid):
		last_error = "No se pudo crear un uniform set Surface Foam P3 válido."
		return RID()
	_sets.append(set_rid)
	return set_rid


func _create_mip_views(texture: RID) -> Array:
	var result: Array[RID]=[]
	for mip in 10: result.append(_rd.texture_create_shared_from_slice(RDTextureView.new(),texture,0,mip,1))
	return result


func _texture_resolution(texture: RID) -> int:
	return int(_rd.texture_get_format(texture).width)


func _build_h0(seed: int) -> PackedByteArray:
	var packed:=PackedFloat32Array(); packed.resize(SOURCE_RESOLUTION*SOURCE_RESOLUTION*4)
	var dk:=TAU/SOURCE_DOMAIN_M; var alpha:=0.076*pow(10.0*10.0/(6000.0*9.81),0.22); var wp:=22.0*pow(9.81*9.81/(10.0*6000.0),1.0/3.0); var wind:=deg_to_rad(110.0)
	var values:=PackedVector2Array(); values.resize(SOURCE_RESOLUTION*SOURCE_RESOLUTION)
	for y in SOURCE_RESOLUTION:
		for x in SOURCE_RESOLUTION:
			var index:=y*SOURCE_RESOLUTION+x; var kvec:=Vector2(float(x)-256.0,float(y)-256.0)*dk; var k:=kvec.length()+0.000001; var omega:=sqrt(9.81*k*tanh(k*20.0)); var derivative:=0.5*9.81*(tanh(k*20.0)+k*20.0*(1.0-pow(tanh(k*20.0),2.0)))/maxf(omega,.000001); var sigma:=.07 if omega<=wp else .09; var r:=exp(-pow(omega-wp,2.0)/(2.0*sigma*sigma*wp*wp)); var jonswap:=alpha*9.81*9.81/pow(omega,5.0)*exp(-1.25*pow(wp/omega,4.0))*pow(3.3,r); var oh:=minf(omega*sqrt(20.0/9.81),2.0); var tma:=jonswap*(.5*oh*oh if oh<=1.0 else 1.0-.5*pow(2.0-oh,2.0)); var p:=omega/wp; var spread:=6.97*pow(absf(p),4.06) if omega<=wp else 9.77*pow(absf(p),-2.33-1.45*(10.0*wp/9.81-1.17)); spread+=16.0*tanh(wp/omega)*.779*.779; var norm:float=(.5*sqrt(spread)+.0625/sqrt(spread))/sqrt(PI) if spread>=.4 else .5/PI+spread*(.220636+spread*(-.109+spread*.090)); var directional:=lerpf(.5/PI,norm*pow(absf(cos((atan2(kvec.x,kvec.y)-wind)*.5)),2.0*spread),.89); var amplitude:=sqrt(maxf(2.0*tma*directional*derivative/k*dk*dk,0.0)); values[index]=_gaussian(seed,index)*amplitude
	for y in SOURCE_RESOLUTION:
		for x in SOURCE_RESOLUTION:
			var index:=y*SOURCE_RESOLUTION+x; var opposite:=values[((SOURCE_RESOLUTION-y)%SOURCE_RESOLUTION)*SOURCE_RESOLUTION+((SOURCE_RESOLUTION-x)%SOURCE_RESOLUTION)]; var base:=index*4; packed[base]=values[index].x; packed[base+1]=values[index].y; packed[base+2]=opposite.x; packed[base+3]=-opposite.y
	return packed.to_byte_array()


func _gaussian(seed: int, index: int) -> Vector2:
	var u1:=maxf((float(_hash((seed&0xffffffff)^((index*0x9e3779b9)&0xffffffff)^0x68bc21eb))+.5)/4294967296.0,.0000001); var u2:=(float(_hash((seed&0xffffffff)^((index*0x9e3779b9)&0xffffffff)^0x02e5be93))+.5)/4294967296.0; var radius:=sqrt(-2.0*log(u1)); return Vector2(radius*cos(TAU*u2),radius*sin(TAU*u2))


func _hash(value: int) -> int:
	var x:=value&0xffffffff; x=((x^(x>>16))*0x7feb352d)&0xffffffff; x=((x^(x>>15))*0x846ca68b)&0xffffffff; return (x^(x>>16))&0xffffffff
