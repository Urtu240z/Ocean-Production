class_name BreakerCarrier
extends Node3D

## H5.2 Gate A: a single static, high-resolution P5 carrier.
## This scene intentionally has no ocean, lifecycle, foam, or event inputs.

const VDM_GENERATOR := preload("res://lab/p7_breaker_shape_lab/breaker_shape_vdm_generator.gd")
const U_SAMPLES := 256
const V_SAMPLES := 64
const WAVELENGTH_M := 32.0
const AUTHORED_PROFILE_SPAN_M := 12.0
const CREST_LENGTH_M := 32.0
const REFERENCE_HEIGHT_M := 2.0
const AUTHORED_VERTICAL_REFERENCE_M := 3.72184
const P5_PHASE := 5

@export var attach_to_ocean := false
@export var ocean_node_path: NodePath = ^"../P0/Ocean"
## Fixed search point used to recover the moving LONG crest on the GPU.
## The actual carrier anchor is derived from Coastal phase every frame.
@export var carrier_search_xz := Vector2.ZERO
## Validation-only cutaway. It removes the camera-side half in the carrier
## fragment shader without changing vertices, authority, or topology.
@export var carrier_validation_cutaway := false

var _mesh_instance: MeshInstance3D
var _mesh: ArrayMesh
var _carrier_material: ShaderMaterial
var _ocean: Node
var _attached := false
var _camera_update_accumulator := 0.0
var _validation_report: Dictionary = {}


func _ready() -> void:
	_build_static_mesh()
	var camera := get_node_or_null(^"Camera3D") as Camera3D
	if camera == null:
		camera = get_parent().get_node_or_null(^"GateBCamera") as Camera3D
	if camera != null:
		camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	if attach_to_ocean:
		set_process(true)


func _build_static_mesh() -> void:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var normals := PackedVector3Array()
	vertices.resize(U_SAMPLES * V_SAMPLES)
	normals.resize(U_SAMPLES * V_SAMPLES)

	for v in V_SAMPLES:
		var v01 := float(v) / float(V_SAMPLES - 1)
		var crest_s := (v01 - 0.5) * CREST_LENGTH_M
		for u in U_SAMPLES:
			var u01 := float(u) / float(U_SAMPLES - 1)
			var authored_base_s := (u01 - 0.5) * AUTHORED_PROFILE_SPAN_M
			var authored := VDM_GENERATOR._sample_profile(VDM_GENERATOR.PROFILE_P5, u01)
			var authored_delta_s := authored.x - authored_base_s
			var scale_s := WAVELENGTH_M / AUTHORED_PROFILE_SPAN_M
			var base_s := (u01 - 0.5) * WAVELENGTH_M
			var delta_s := authored_delta_s * scale_s
			var target_s := base_s + delta_s
			var target_y := maxf(authored.y * REFERENCE_HEIGHT_M / AUTHORED_VERTICAL_REFERENCE_M, 0.0)
			vertices[v * U_SAMPLES + u] = Vector3(target_s, target_y, crest_s)

			# UV carries the authored profile coordinates into the attachment shader.

	for v in V_SAMPLES - 1:
		for u in U_SAMPLES - 1:
			var a := v * U_SAMPLES + u
			var b := a + 1
			var c := a + U_SAMPLES
			var d := c + 1
			indices.append_array(PackedInt32Array([a, c, b, b, c, d]))

	for triangle in range(0, indices.size(), 3):
		var p0: Vector3 = vertices[indices[triangle]]
		var p1: Vector3 = vertices[indices[triangle + 1]]
		var p2: Vector3 = vertices[indices[triangle + 2]]
		var n := (p1 - p0).cross(p2 - p0).normalized()
		normals[indices[triangle]] += n
		normals[indices[triangle + 1]] += n
		normals[indices[triangle + 2]] += n
	for i in normals.size():
		normals[i] = normals[i].normalized()

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	_mesh = ArrayMesh.new()
	var uvs := PackedVector2Array()
	uvs.resize(U_SAMPLES * V_SAMPLES)
	for v in V_SAMPLES:
		for u in U_SAMPLES:
			uvs[v * U_SAMPLES + u] = Vector2(float(u) / float(U_SAMPLES - 1), float(v) / float(V_SAMPLES - 1))
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = &"StaticP5Carrier"
	_mesh_instance.mesh = _mesh
	_carrier_material = _make_attachment_material() if attach_to_ocean else _make_static_material()
	_mesh_instance.material_override = _carrier_material
	add_child(_mesh_instance)


func _process(delta: float) -> void:
	if not attach_to_ocean:
		return
	_ocean = get_node_or_null(ocean_node_path)
	if _ocean == null:
		return
	var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface")
	if surface == null or not surface.has_method(&"get_runtime_feature_state"):
		return
	var state: Dictionary = surface.get_runtime_feature_state()
	var parameters: Dictionary = state.get("surface_parameter_state", {})
	if parameters.is_empty():
		return
	var required := ["displacement_long", "displacement_mid", "displacement_short", "coastal_phase", "coastal_metrics", "coastal_field", "coastal_warp"]
	for key in required:
		if parameters.get(key) == null:
			return
	for key in ["displacement_long", "displacement_mid", "displacement_short", "coastal_phase", "coastal_metrics", "coastal_field", "coastal_warp"]:
		_carrier_material.set_shader_parameter(key, parameters[key])
	for key in ["domain_long_m", "domain_mid_m", "domain_short_m", "coastal_origin", "coastal_extent", "coastal_warp_origin", "coastal_warp_extent", "coastal_warp_detj_safe"]:
		if parameters.has(key):
			_carrier_material.set_shader_parameter(key, parameters[key])
	var gate_camera := get_parent().get_node_or_null(^"GateBCamera") as Camera3D
	_camera_update_accumulator += delta
	var update_camera := not _attached or _camera_update_accumulator >= 0.25
	if update_camera:
		_camera_update_accumulator = 0.0
	var phase_texture := parameters.get("coastal_phase") as Texture2D
	var metrics_texture := parameters.get("coastal_metrics") as Texture2D
	var warp_texture := parameters.get("coastal_warp") as Texture2D
	var field_texture := parameters.get("coastal_field") as Texture2D
	var phase_image := phase_texture.get_image() if phase_texture != null else null
	var metrics_image := metrics_texture.get_image() if metrics_texture != null else null
	var warp_image := warp_texture.get_image() if warp_texture != null else null
	var field_image := field_texture.get_image() if field_texture != null else null
	if update_camera and phase_image != null and metrics_image != null and gate_camera != null:
		var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
		var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
		var coastal_warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
		var coastal_warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
		var phase_uv := (carrier_search_xz - coastal_origin) / coastal_extent
		var pixel := Vector2i(
			clampi(int(phase_uv.x * float(phase_image.get_width() - 1)), 0, phase_image.get_width() - 1),
			clampi(int(phase_uv.y * float(phase_image.get_height() - 1)), 0, phase_image.get_height() - 1))
		var frame := _compute_carrier_frame(parameters, phase_image, metrics_image, field_image, warp_image)
		var crest_anchor: Vector2 = frame.get("crest_xz", carrier_search_xz)
		var forward: Vector2 = frame.get("forward", Vector2(0.0, 1.0))
		var tangent: Vector2 = frame.get("tangent", Vector2(-forward.y, forward.x))
		var camera_direction := (tangent * 0.95 - forward * 0.25).normalized()
		gate_camera.position = Vector3(crest_anchor.x + camera_direction.x * 24.0, 8.0, crest_anchor.y + camera_direction.y * 24.0)
		gate_camera.look_at(Vector3(crest_anchor.x, 1.0, crest_anchor.y), Vector3.UP)
		if _validation_report.is_empty():
			_validation_report = _validate_centerline(parameters, frame)
	_carrier_material.set_shader_parameter(&"carrier_search_xz", carrier_search_xz)
	_carrier_material.set_shader_parameter(&"carrier_reference_wavelength_m", WAVELENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_crest_length_m", CREST_LENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_vertical_scale", 1.0)
	_carrier_material.set_shader_parameter(&"carrier_validation_cutaway", carrier_validation_cutaway)
	if surface.has_method(&"set_breaker_carrier_suppression"):
		surface.set_breaker_carrier_suppression(true, carrier_search_xz, CREST_LENGTH_M)
	_attached = true


func _make_static_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode cull_disabled, unshaded; void fragment() { ALBEDO = vec3(0.035, 0.24, 0.42); }"
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _make_attachment_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = _carrier_shader_code()
	var material := ShaderMaterial.new()
	material.shader = shader
	material.render_priority = 10
	return material


func _carrier_shader_code() -> String:
	return """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, unshaded;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D coastal_phase : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics : repeat_disable, filter_linear;
uniform sampler2D coastal_field : repeat_disable, filter_linear;
uniform sampler2D coastal_warp : repeat_disable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 coastal_origin = vec2(0.0);
uniform vec2 coastal_extent = vec2(1.0);
uniform vec2 coastal_warp_origin = vec2(0.0);
uniform vec2 coastal_warp_extent = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;
uniform vec2 carrier_search_xz = vec2(0.0);
uniform float carrier_reference_wavelength_m = 32.0;
uniform float carrier_crest_length_m = 32.0;
uniform float carrier_vertical_scale = 1.0;
uniform bool carrier_validation_cutaway = false;

vec2 world_uv(vec2 world_xz, float domain_m) {
    return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

vec2 coastal_uv(vec2 world_xz, vec2 origin, vec2 extent) {
    return (world_xz - origin) / max(extent, vec2(0.001));
}

float coastal_confidence(vec4 warp) {
    return smoothstep(0.0, coastal_warp_detj_safe, warp.z) * warp.w;
}

vec3 sample_ocean_base(vec2 base_xz) {
    vec3 long_displacement = texture(displacement_long, world_uv(base_xz, domain_long_m)).xyz;
    vec2 coast_uv = coastal_uv(base_xz, coastal_origin, coastal_extent);
    if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
        vec4 field = texture(coastal_field, coast_uv);
        vec4 warp = texture(coastal_warp, clamp(coastal_uv(base_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
        float confidence = field.a * coastal_confidence(warp);
        long_displacement = mix(long_displacement, texture(displacement_long, world_uv(warp.xy, domain_long_m)).xyz, confidence);
        long_displacement.y *= mix(1.0, field.g, confidence);
    }
    return long_displacement + texture(displacement_mid, world_uv(base_xz, domain_mid_m)).xyz + texture(displacement_short, world_uv(base_xz, domain_short_m)).xyz;
}

void vertex() {
    vec2 search_uv = clamp(coastal_uv(carrier_search_xz, coastal_origin, coastal_extent), vec2(0.0), vec2(1.0));
    vec4 phase_search = texture(coastal_phase, search_uv);
    vec4 metrics_search = texture(coastal_metrics, search_uv);
    vec4 field_search = texture(coastal_field, search_uv);
    vec4 warp_search = texture(coastal_warp, clamp(coastal_uv(carrier_search_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
    float confidence_search = clamp(field_search.a * coastal_confidence(warp_search), 0.0, 1.0);
    vec2 candidate_wave_xz = mix(carrier_search_xz, warp_search.xy, confidence_search);
    vec2 forward_search = -normalize(phase_search.yz);
    if (length(phase_search.yz) < 0.0001) forward_search = vec2(0.0, 1.0);
    float wavelength_search = max(metrics_search.g, 0.001);
    float wrapped_phase = mod(phase_search.r + 3.14159265359, 6.28318530718) - 3.14159265359;
    float s_profile = -wrapped_phase / max(6.28318530718 / wavelength_search, 0.001);
    vec2 carrier_crest_xz = candidate_wave_xz - forward_search * s_profile;
    vec2 crest_uv = clamp(coastal_uv(carrier_crest_xz, coastal_origin, coastal_extent), vec2(0.0), vec2(1.0));
    vec4 phase_info = texture(coastal_phase, crest_uv);
    vec4 metrics_info = texture(coastal_metrics, crest_uv);
    vec2 forward = -normalize(phase_info.yz);
    if (length(phase_info.yz) < 0.0001) forward = forward_search;
    vec2 tangent = vec2(-forward.y, forward.x);
    float wavelength_m = max(metrics_info.g, wavelength_search);
    float wavelength_scale = wavelength_m / max(carrier_reference_wavelength_m, 0.001);
    float profile_u = UV.x;
    float base_s = (profile_u - 0.5) * wavelength_m;
    float target_s = VERTEX.x * wavelength_scale;
    float crest_s = (UV.y - 0.5) * carrier_crest_length_m;
    vec2 base_xz = carrier_crest_xz + forward * base_s + tangent * crest_s;
    vec3 ocean_base = sample_ocean_base(base_xz);
    vec3 base_world = vec3(base_xz.x + ocean_base.x, ocean_base.y, base_xz.y + ocean_base.z);
    vec2 crest_param_xz = carrier_crest_xz + tangent * crest_s;
    vec3 crest_disp = sample_ocean_base(crest_param_xz);
    vec2 crest_world_xz = crest_param_xz + crest_disp.xz;
    vec2 breaker_xz = crest_world_xz + forward * target_s;
    vec3 breaker_world = vec3(breaker_xz.x, crest_disp.y + VERTEX.y * carrier_vertical_scale, breaker_xz.y);
    float rear_attachment = smoothstep(0.0, 0.08, profile_u);
    float front_attachment = 1.0 - smoothstep(0.92, 1.0, profile_u);
    float lateral_attachment = smoothstep(0.0, 0.12, UV.y) * (1.0 - smoothstep(0.88, 1.0, UV.y));
    float authority = rear_attachment * front_attachment * lateral_attachment;
    VERTEX = mix(base_world, breaker_world, authority);
}

void fragment() {
    if (carrier_validation_cutaway && UV.y > 0.52) discard;
    float normal_readability = clamp(0.5 + 0.5 * normalize(NORMAL).y, 0.0, 1.0);
    ALBEDO = mix(vec3(0.010, 0.085, 0.13), vec3(0.025, 0.28, 0.42), normal_readability);
    ROUGHNESS = 0.22;
}
"""


func _compute_carrier_frame(parameters: Dictionary, phase_image: Image, metrics_image: Image, field_image: Image, warp_image: Image) -> Dictionary:
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
	var warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
	var warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
	var phase := _sample_image_uv(phase_image, (carrier_search_xz - coastal_origin) / coastal_extent)
	var metrics := _sample_image_uv(metrics_image, (carrier_search_xz - coastal_origin) / coastal_extent)
	var field := _sample_image_uv(field_image, (carrier_search_xz - coastal_origin) / coastal_extent)
	var warp := _sample_image_uv(warp_image, (carrier_search_xz - warp_origin) / warp_extent)
	var forward_search := -Vector2(phase.g, phase.b).normalized()
	if forward_search.length_squared() < 0.0001: forward_search = Vector2(0.0, 1.0)
	var detj_safe := maxf(float(parameters.get("coastal_warp_detj_safe", 0.5)), 0.001)
	var confidence := clampf(field.a * _smoothstep(0.0, detj_safe, warp.b), 0.0, 1.0)
	var candidate := carrier_search_xz.lerp(Vector2(warp.r, warp.g), confidence)
	var wavelength_search := maxf(metrics.g, 0.001)
	var wrapped_phase := fposmod(phase.r + PI, TAU) - PI
	var s_profile := -wrapped_phase / (TAU / wavelength_search)
	var crest := candidate - forward_search * s_profile
	var phase_info := _sample_image_uv(phase_image, (crest - coastal_origin) / coastal_extent)
	var metrics_info := _sample_image_uv(metrics_image, (crest - coastal_origin) / coastal_extent)
	var forward := -Vector2(phase_info.g, phase_info.b).normalized()
	if forward.length_squared() < 0.0001: forward = forward_search
	var tangent := Vector2(-forward.y, forward.x)
	return {"crest_xz": crest, "forward": forward, "tangent": tangent, "wavelength_m": maxf(metrics_info.g, wavelength_search), "candidate_xz": candidate, "confidence": confidence, "phase_search": phase, "metrics_search": metrics, "phase_final": phase_info, "metrics_final": metrics_info}


func _sample_image_uv(image: Image, uv: Vector2) -> Color:
	if image == null or image.is_empty(): return Color(0.0, 0.0, 0.0, 0.0)
	var p := Vector2(clampf(uv.x, 0.0, 1.0) * float(image.get_width() - 1), clampf(uv.y, 0.0, 1.0) * float(image.get_height() - 1))
	var p0 := Vector2i(floori(p.x), floori(p.y))
	var p1 := Vector2i(mini(p0.x + 1, image.get_width() - 1), mini(p0.y + 1, image.get_height() - 1))
	var f := p - Vector2(p0)
	return image.get_pixelv(p0).lerp(image.get_pixelv(Vector2i(p1.x, p0.y)), f.x).lerp(image.get_pixelv(Vector2i(p0.x, p1.y)).lerp(image.get_pixelv(p1), f.x), f.y)


func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	var t := clampf((value - edge0) / maxf(edge1 - edge0, 0.000001), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _validate_centerline(parameters: Dictionary, frame: Dictionary) -> Dictionary:
	var wavelength: float = float(frame.get("wavelength_m", WAVELENGTH_M))
	var crest: Vector2 = frame.get("crest_xz", carrier_search_xz)
	var forward: Vector2 = frame.get("forward", Vector2(0.0, 1.0))
	var tangent: Vector2 = frame.get("tangent", Vector2(-forward.y, forward.x))
	var displacement_long := (parameters.get("displacement_long") as Texture2D).get_image() if parameters.get("displacement_long") is Texture2D else null
	var displacement_mid := (parameters.get("displacement_mid") as Texture2D).get_image() if parameters.get("displacement_mid") is Texture2D else null
	var displacement_short := (parameters.get("displacement_short") as Texture2D).get_image() if parameters.get("displacement_short") is Texture2D else null
	var coastal_field := (parameters.get("coastal_field") as Texture2D).get_image() if parameters.get("coastal_field") is Texture2D else null
	var coastal_warp := (parameters.get("coastal_warp") as Texture2D).get_image() if parameters.get("coastal_warp") is Texture2D else null
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
	var warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
	var warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
	var domain_long := float(parameters.get("domain_long_m", 512.0))
	var domain_mid := float(parameters.get("domain_mid_m", 137.0))
	var domain_short := float(parameters.get("domain_short_m", 37.0))
	var crest_disp := _sample_ocean_base_cpu(crest, displacement_long, displacement_mid, displacement_short, coastal_field, coastal_warp, coastal_origin, coastal_extent, warp_origin, warp_extent, domain_long, domain_mid, domain_short, float(parameters.get("coastal_warp_detj_safe", 0.5)))
	var crest_world := crest + Vector2(crest_disp.x, crest_disp.z)
	var final_s: PackedFloat32Array = []
	var final_y: PackedFloat32Array = []
	var authority_values: PackedFloat32Array = []
	for i in 1024:
		var u := float(i) / 1023.0
		var authored_base_s := (u - 0.5) * AUTHORED_PROFILE_SPAN_M
		var authored := VDM_GENERATOR._sample_profile(VDM_GENERATOR.PROFILE_P5, u)
		var target_s_static := (u - 0.5) * WAVELENGTH_M + (authored.x - authored_base_s) * WAVELENGTH_M / AUTHORED_PROFILE_SPAN_M
		var target_s := target_s_static * wavelength / WAVELENGTH_M
		var target_y := maxf(authored.y * REFERENCE_HEIGHT_M / AUTHORED_VERTICAL_REFERENCE_M, 0.0)
		var base_s := (u - 0.5) * wavelength
		var base_xz := crest + forward * base_s
		var base_disp := _sample_ocean_base_cpu(base_xz, displacement_long, displacement_mid, displacement_short, coastal_field, coastal_warp, coastal_origin, coastal_extent, warp_origin, warp_extent, domain_long, domain_mid, domain_short, float(parameters.get("coastal_warp_detj_safe", 0.5)))
		var base_world := Vector3(base_xz.x + base_disp.x, base_disp.y, base_xz.y + base_disp.z)
		var breaker_xz := crest_world + forward * target_s
		var breaker_world := Vector3(breaker_xz.x, crest_disp.y + target_y, breaker_xz.y)
		var rear := _smoothstep(0.0, 0.08, u)
		var front := 1.0 - _smoothstep(0.92, 1.0, u)
		var authority := rear * front
		var final_world := base_world.lerp(breaker_world, authority)
		final_s.append((Vector2(final_world.x, final_world.z) - crest_world).dot(forward))
		final_y.append(final_world.y - crest_world.y)
		authority_values.append(authority)
	var min_derivative := INF
	var min_derivative_index := 0
	var final_s_min := INF
	var final_s_max := -INF
	var final_y_min := INF
	var final_y_max := -INF
	var negative_first := -1
	var negative_last := -1
	var negative_count := 0
	for value in final_s:
		final_s_min = minf(final_s_min, value)
		final_s_max = maxf(final_s_max, value)
	for value in final_y:
		final_y_min = minf(final_y_min, value)
		final_y_max = maxf(final_y_max, value)
	for i in 1023:
		var derivative := (final_s[i + 1] - final_s[i]) * 1023.0
		if derivative < 0.0:
			if negative_first < 0: negative_first = i
			negative_last = i
			negative_count += 1
		if derivative < min_derivative:
			min_derivative = derivative
			min_derivative_index = i
	return {"sample_count": 1024, "authority_min_p5": authority_values[470], "authority_max_p5": authority_values[750], "negative_derivative_u0": float(negative_first) / 1023.0 if negative_first >= 0 else -1.0, "negative_derivative_u1": float(negative_last + 1) / 1023.0 if negative_last >= 0 else -1.0, "negative_derivative_sample_count": negative_count, "minimum_d_final_s_du": min_derivative, "minimum_derivative_u": float(min_derivative_index) / 1023.0, "final_s_min": final_s_min, "final_s_max": final_s_max, "final_y_min": final_y_min, "final_y_max": final_y_max, "crest_world_xz": crest_world, "candidate_xz": frame.get("candidate_xz", carrier_search_xz), "forward": forward, "tangent": tangent, "wavelength_m": wavelength, "confidence": frame.get("confidence", 0.0)}


func _sample_ocean_base_cpu(base_xz: Vector2, long_image: Image, mid_image: Image, short_image: Image, field_image: Image, warp_image: Image, coastal_origin: Vector2, coastal_extent: Vector2, warp_origin: Vector2, warp_extent: Vector2, domain_long: float, domain_mid: float, domain_short: float, detj_safe: float) -> Vector3:
	var long_disp := _sample_image_uv(long_image, base_xz / maxf(domain_long, 0.001) + Vector2(0.5, 0.5))
	var coast_uv := (base_xz - coastal_origin) / coastal_extent
	if coast_uv.x >= 0.0 and coast_uv.x <= 1.0 and coast_uv.y >= 0.0 and coast_uv.y <= 1.0 and field_image != null and warp_image != null:
		var field := _sample_image_uv(field_image, coast_uv)
		var warp := _sample_image_uv(warp_image, (base_xz - warp_origin) / warp_extent)
		var confidence := field.a * _smoothstep(0.0, detj_safe, warp.b)
		long_disp = long_disp.lerp(_sample_image_uv(long_image, Vector2(warp.r, warp.g) / maxf(domain_long, 0.001) + Vector2(0.5, 0.5)), confidence)
		long_disp.g *= lerpf(1.0, field.g, confidence)
	var mid := _sample_image_uv(mid_image, base_xz / maxf(domain_mid, 0.001) + Vector2(0.5, 0.5))
	var short := _sample_image_uv(short_image, base_xz / maxf(domain_short, 0.001) + Vector2(0.5, 0.5))
	return Vector3(long_disp.r + mid.r + short.r, long_disp.g + mid.g + short.g, long_disp.b + mid.b + short.b)


func get_static_carrier_info() -> Dictionary:
	return {
		"phase": P5_PHASE,
		"u_samples": U_SAMPLES,
		"v_samples": V_SAMPLES,
		"wavelength_m": WAVELENGTH_M,
		"authored_profile_span_m": AUTHORED_PROFILE_SPAN_M,
		"profile_scale_s": WAVELENGTH_M / AUTHORED_PROFILE_SPAN_M,
		"crest_length_m": CREST_LENGTH_M,
		"reference_height_m": REFERENCE_HEIGHT_M,
		"mesh_built_once": _mesh != null,
		"vertex_count": U_SAMPLES * V_SAMPLES,
		"triangle_count": (U_SAMPLES - 1) * (V_SAMPLES - 1) * 2,
		"validation_report": _validation_report.duplicate(),
	}
