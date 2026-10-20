@tool
extends RefCounted
## Compile current shared sources, never an RDShaderFile imported before an
## included wave formula changed. ShaderInclude resources also survive export.
const CAMERA_BODY = preload("res://addons/ocean/underwater/shaders/ocean_waterline_camera_state_body.gdshaderinc")
const RASTER_BODY = preload("res://addons/ocean/underwater/shaders/ocean_waterline_raster_body.gdshaderinc")
const RASTER_FRAGMENT = preload("res://addons/ocean/underwater/shaders/ocean_waterline_fragment.gdshaderinc")
const CAMERA_UNIFORMS = preload("res://addons/ocean/underwater/shaders/ocean_waterline_camera_state_uniforms.gdshaderinc")
const RASTER_UNIFORMS = preload("res://addons/ocean/underwater/shaders/ocean_waterline_raster_uniforms.gdshaderinc")
const INCLUDES := {
	"res://addons/ocean/areas/wave_area_math.gdshaderinc":preload("res://addons/ocean/areas/wave_area_math.gdshaderinc"),
	"res://addons/ocean/events/tsunami_math.gdshaderinc":preload("res://addons/ocean/events/tsunami_math.gdshaderinc"),
	"res://addons/ocean/areas/wave_area_buffer.gdshaderinc":preload("res://addons/ocean/areas/wave_area_buffer.gdshaderinc"),
	"res://addons/ocean/shaders/coastal_coverage.gdshaderinc":preload("res://addons/ocean/shaders/coastal_coverage.gdshaderinc"),
	"res://addons/ocean/surface/foam2d/hull_wave_sampling.gdshaderinc":preload("res://addons/ocean/surface/foam2d/hull_wave_sampling.gdshaderinc"),
	"res://addons/ocean/underwater/shaders/ocean_hull_wave_waterline.gdshaderinc":preload("res://addons/ocean/underwater/shaders/ocean_hull_wave_waterline.gdshaderinc")}
static var _spirv_cache: Dictionary = {}

static func _stage_code(camera: bool) -> String:
	# Godot's RDShaderFile importer expands a single include level. Keep the
	# compatibility entry points flat too, in the identical declaration order.
	var code: String="#define WAVE_AREA_BINDING %d\n#define LOCAL_FFT_BINDING %d\n"%[15 if camera else 14,16 if camera else 15]
	for path in ["res://addons/ocean/areas/wave_area_math.gdshaderinc","res://addons/ocean/events/tsunami_math.gdshaderinc","res://addons/ocean/areas/wave_area_buffer.gdshaderinc","res://addons/ocean/shaders/coastal_coverage.gdshaderinc"]:
		code+=INCLUDES[path].code+"\n"
	code+=(CAMERA_UNIFORMS.code if camera else RASTER_UNIFORMS.code)+"\n"
	for path in ["res://addons/ocean/surface/foam2d/hull_wave_sampling.gdshaderinc","res://addons/ocean/underwater/shaders/ocean_hull_wave_waterline.gdshaderinc"]:
		code+=INCLUDES[path].code+"\n"
	code+=(CAMERA_BODY.code if camera else RASTER_BODY.code)+"\n"
	if code.contains("#include"):
		push_error("Ocean waterline: shared stages must use flat include dependencies.")
		return ""
	return code

static func compile(rd: RenderingDevice,camera: bool) -> RDShaderSPIRV:
	var body:=_stage_code(camera)
	if body.is_empty(): return null
	var fragment: String="" if camera else RASTER_FRAGMENT.code
	var cache_key:=body+"\n// fragment\n"+fragment
	if _spirv_cache.has(cache_key): return _spirv_cache[cache_key]
	var source:=RDShaderSource.new()
	source.language=RenderingDevice.SHADER_LANGUAGE_GLSL
	if camera: source.source_compute="#version 450\n"+body
	else:
		source.source_vertex="#version 450\n"+body
		source.source_fragment="#version 450\n"+fragment
	var spirv:=rd.shader_compile_spirv_from_source(source)
	if spirv==null: return null
	for stage in ([RenderingDevice.SHADER_STAGE_COMPUTE] if camera else [RenderingDevice.SHADER_STAGE_VERTEX,RenderingDevice.SHADER_STAGE_FRAGMENT]):
		var error:=spirv.get_stage_compile_error(stage)
		if not error.is_empty():
			push_error("Ocean waterline: "+error)
			return null
	_spirv_cache[cache_key]=spirv
	return spirv
