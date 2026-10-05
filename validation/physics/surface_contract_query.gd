extends "res://addons/ocean/physics/gpu/ocean_surface_query.gd"
## Validation-only replacement token. Production modes and source are frozen.
## Extra output preserves FP64 roots and measures the actual fine Jacobian.
const SOURCE := preload("res://addons/ocean/physics/gpu/ocean_envelope_shader_source.gd")
const DIAGNOSTIC_MODE := 252
func _physical_mode() -> int: return DIAGNOSTIC_MODE
func _physical_rich_stride() -> int: return 160
func _physical_compact_stride() -> int: return 160
func _create_query_shader(_file:RDShaderFile) -> RID:
	var result:=SOURCE.compile(_rd,{RenderingDevice.SHADER_STAGE_COMPUTE:"res://validation/physics/surface_contract_query.comp"})
	if result.has("error"): _error(result.error); return RID()
	return result.shader

static func pack(trials:Array) -> Dictionary:
	var packet:=PackedByteArray(); var controls:=PackedByteArray()
	packet.resize(trials.size()*32); controls.resize(trials.size()*32)
	for i in trials.size():
		var t:Dictionary=trials[i]; var o:int=i*32
		packet.encode_float(o,t.target[0]); packet.encode_float(o+4,t.target[1])
		packet.encode_u32(o+16,DIAGNOSTIC_MODE); packet.encode_u32(o+28,i)
		controls.encode_u32(o,i); controls.encode_u32(o+4,1); controls.encode_u32(o+8,1)
		if t.get("precise_seed",false):
			packet.encode_float(o+8,t.get("orientation",0.0)); packet.encode_float(o+12,t.get("trust",0.0)); packet.encode_float(o+20,t.get("radius",0.0))
			controls.encode_u32(o+12,2 if t.get("material",false) else 4 if t.get("continuation",false) else 3)
			controls.encode_double(o+16,t.seed[0]); controls.encode_double(o+24,t.seed[1])
		else:
			packet.encode_float(o+8,t.seed[0]); packet.encode_float(o+12,t.seed[1])
			controls.encode_u32(o+12,1 if t.get("material",false) else 0)
			controls.encode_float(o+16,t.get("radius",0.0)); controls.encode_float(o+20,t.get("trust",0.0)); controls.encode_float(o+24,t.get("orientation",0.0))
	return {"packet":packet,"controls":controls}

static func decode(result:Dictionary,index:int) -> Dictionary:
	var b:PackedByteArray=result.bytes; var o:int=index*160
	return {"q":[b.decode_double(o+96),b.decode_double(o+104)],"valid":b.decode_float(o+28)>0.5,"height":b.decode_float(o+36),"residual":b.decode_float(o+8),"iterations":int(b.decode_float(o+12)),"world":[b.decode_float(o+32),b.decode_float(o+36),b.decode_float(o+40)],"det":b.decode_float(o+44),"j":[b.decode_float(o+112),b.decode_float(o+116),b.decode_float(o+120),b.decode_float(o+124)],"height_gradient_q":[b.decode_float(o+128),b.decode_float(o+132)],"smax":b.decode_float(o+136),"smin":b.decode_float(o+140),"condition":b.decode_float(o+144),"reason":int(b.decode_float(o+148)),"fine_residual":b.decode_float(o+152)}
