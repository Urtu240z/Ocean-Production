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

static func shadow_source(surface_code: String) -> String:
	# Reuse the visible surface's complete vertex deformation and shared buffers.
	# No screen/depth/Optics fragment is needed for a shadow-only draw.
	var fragment := surface_code.find("void fragment() {")
	assert(fragment >= 0 and surface_code.contains(VERTEX))
	var code := surface_code.substr(0,fragment)
	code = code.replace("void vertex() {","uniform bool ocean_shadow_crest_only = true;\nvarying float tsunami_shadow_height;\nvoid vertex() {")
	var expression := "ocean_tsunami_wave(tsunami_p,tsunami_center_radius,tsunami_shape,tsunami_motion).x"
	var shadow_vertex := VERTEX.replace("surface_displacement.y+="+expression,
		"tsunami_shadow_height="+expression+";\n\tsurface_displacement.y+=tsunami_shadow_height")
	code = code.replace(VERTEX,shadow_vertex)
	# Clip the flat ocean and trough; only the raised crest occludes sunlight.
	return code + "void fragment() { if (ocean_shadow_crest_only && tsunami_shadow_height <= 0.01) { discard; } }\n"


static func shadow_receiver_source(surface_code: String) -> String:
	# A transparent next pass reads Godot's real directional shadow attenuation.
	# Keep the exact visible vertex deformation, including projected hull waves.
	var fragment := surface_code.find("void fragment() {")
	assert(fragment >= 0 and surface_code.contains("depth_draw_always"))
	var visibility_end := surface_code.find("\tfloat distance_m = distance(world_xz, camera_world_xz);", fragment)
	assert(visibility_end > fragment)
	var visibility := surface_code.substr(fragment + "void fragment() {".length(), visibility_end - fragment - "void fragment() {".length())
	var code := surface_code.substr(0, fragment)
	code = code.replace("depth_draw_always", "depth_draw_never, fog_disabled")
	var receiver := '''
uniform float ocean_shadow_strength = 0.0;
void fragment() {
	// WATER_SHADOW_VISIBILITY
	vec3 geometric_normal = normalize(cross(dFdx(VERTEX), dFdy(VERTEX)));
	vec3 world_up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	NORMAL = dot(geometric_normal, world_up_view) >= 0.0 ? geometric_normal : -geometric_normal;
	ALBEDO = vec3(0.0);
	SPECULAR = 0.0;
	ROUGHNESS = 1.0;
	RADIANCE = vec4(0.0, 0.0, 0.0, 1.0);
	IRRADIANCE = vec4(0.0, 0.0, 0.0, 1.0);
	ALPHA = 0.0;
}
void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		ALPHA = max(ALPHA, ocean_shadow_strength * clamp(surface_air_blend, 0.0, 1.0) * (1.0 - ATTENUATION));
	}
	DIFFUSE_LIGHT = vec3(0.0);
	SPECULAR_LIGHT = vec3(0.0);
}
'''
	# Preserve the visible surface's fragment cutout for a replacement breaker.
	return code + receiver.replace("\t// WATER_SHADOW_VISIBILITY", visibility)
