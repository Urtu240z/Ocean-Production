extends RefCounted
## One authority: extract the frozen PHYS-GPU-1.3 texture evaluation/refinement
## definitions verbatim. The new stage templates contain no ocean transform.
const AUTHORITY := "res://addons/ocean/physics/gpu/ocean_surface_query.glsl"

static func compile(rd: RenderingDevice, stages: Dictionary) -> Dictionary:
	var authority := FileAccess.get_file_as_string(AUTHORITY)
	var start := authority.find("ivec2 wrap(")
	var end := authority.find("// Local evidence triggers")
	if start < 0 or end <= start: return {"error":"authoritative shader source delimiters changed"}
	var functions := authority.substr(start,end-start)
	var header := authority.substr(authority.find("layout(set=0,binding=0)"),authority.find("// 32 bytes:")-authority.find("layout(set=0,binding=0)"))
	var params_start := authority.find("layout(push_constant,std430)")
	var params := authority.substr(params_start,start-params_start)
	var source := RDShaderSource.new()
	for stage in stages:
		var text := FileAccess.get_file_as_string(stages[stage])
		text = text.replace("// @OCEAN_AUTHORITY@",header+params+functions)
		text = text.replace("// @ENVELOPE_SHARED@",FileAccess.get_file_as_string("res://addons/ocean/physics/gpu/ocean_envelope_shared.inc"))
		source.set_stage_source(stage,text)
	var spirv := rd.shader_compile_spirv_from_source(source)
	for stage in stages:
		var error := spirv.get_stage_compile_error(stage)
		if not error.is_empty(): return {"error":error}
	return {"shader":rd.shader_create_from_spirv(spirv,"Ocean.Envelope"),"authority_sha256":FileAccess.get_sha256(AUTHORITY)}
