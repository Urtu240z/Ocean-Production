@tool
extends RefCounted
const INCLUDE := '#include "res://addons/ocean/events/tsunami_math.gdshaderinc"'
const UNIFORMS := '''
uniform vec4 tsunami_center_radius=vec4(0.0);
uniform vec4 tsunami_shape=vec4(30.0,90.0,35.0,65.0);
uniform vec4 tsunami_motion=vec4(0.0,0.0,0.25,0.0);
'''
const VERTEX := '''
	vec2 tsunami_p=(MODEL_MATRIX*vec4(VERTEX+vec3(surface_displacement.x,0.0,surface_displacement.z),1.0)).xz;
	surface_displacement.y+=ocean_tsunami_wave(tsunami_p,tsunami_center_radius,tsunami_shape,tsunami_motion).x/max(length(MODEL_MATRIX[1].xyz),0.001);
'''
const NORMAL := '''
	vec4 tsunami_wave=ocean_tsunami_wave(ocean_world_position.xz,tsunami_center_radius,tsunami_shape,tsunami_motion);
	shading_normal_world=normalize(shading_normal_world-vec3(tsunami_wave.y,0.0,tsunami_wave.z)*shading_normal_world.y);
'''
const FOAM := '''
	if(tsunami_center_radius.w>0.0) {
		vec4 tsunami_foam_wave=ocean_tsunami_wave(ocean_world_position.xz,tsunami_center_radius,tsunami_shape,tsunami_motion);
		float tsunami_white=smoothstep(0.65,0.95,tsunami_foam_wave.x/max(tsunami_center_radius.w,0.001))*0.85;
		ALBEDO=mix(ALBEDO,vec3(0.92,0.97,1.0),tsunami_white);
		ROUGHNESS=mix(ROUGHNESS,0.85,tsunami_white);
	}
'''

static func inject(code: String) -> String:
	if code.contains(INCLUDE): return code
	code=code.replace("void vertex() {",INCLUDE+"\n"+UNIFORMS+"\nvoid vertex() {")
	code=code.replace("\tVERTEX += surface_displacement;",VERTEX+"\tVERTEX += surface_displacement;")
	var anchor:="\tvec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);"
	code=code.replace(anchor,NORMAL+anchor)
	var end:=code.rfind("}")
	return code.substr(0,end)+FOAM+code.substr(end)
