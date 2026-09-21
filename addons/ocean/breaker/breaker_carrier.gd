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

var _mesh_instance: MeshInstance3D
var _mesh: ArrayMesh
var _carrier_material: ShaderMaterial
var _ocean: Node
var _attached := false
var _camera_update_accumulator := 0.0


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
		var phase := phase_image.get_pixelv(pixel)
		var metrics := metrics_image.get_pixelv(pixel)
		var forward := -Vector2(phase.g, phase.b).normalized()
		if field_image != null and warp_image != null:
			var warp_uv := (carrier_search_xz - coastal_warp_origin) / coastal_warp_extent
			var warp_pixel := Vector2i(
				clampi(int(warp_uv.x * float(warp_image.get_width() - 1)), 0, warp_image.get_width() - 1),
				clampi(int(warp_uv.y * float(warp_image.get_height() - 1)), 0, warp_image.get_height() - 1))
			var warp := warp_image.get_pixelv(warp_pixel)
			var field := field_image.get_pixelv(pixel)
			var confidence := clampf(field.a * smoothstep(0.0, float(parameters.get("coastal_warp_detj_safe", 0.5)), warp.b), 0.0, 1.0)
			var candidate := carrier_search_xz.lerp(Vector2(warp.r, warp.g), confidence)
			var wavelength := maxf(metrics.g, 0.001)
			var wrapped_phase := fposmod(phase.r + PI, TAU) - PI
			var s_profile := -wrapped_phase / (TAU / wavelength)
			var crest_anchor := candidate - forward * s_profile
			var tangent := Vector2(-forward.y, forward.x)
			gate_camera.position = Vector3(crest_anchor.x + tangent.x * 24.0, 8.0, crest_anchor.y + tangent.y * 24.0)
			gate_camera.look_at(Vector3(crest_anchor.x, 1.0, crest_anchor.y), Vector3.UP)
		else:
			var tangent := Vector2(-forward.y, forward.x)
			gate_camera.position = Vector3(carrier_search_xz.x + tangent.x * 24.0, 8.0, carrier_search_xz.y + tangent.y * 24.0)
			gate_camera.look_at(Vector3(carrier_search_xz.x, 1.0, carrier_search_xz.y), Vector3.UP)
	_carrier_material.set_shader_parameter(&"carrier_search_xz", carrier_search_xz)
	_carrier_material.set_shader_parameter(&"carrier_reference_wavelength_m", WAVELENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_crest_length_m", CREST_LENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_vertical_scale", 1.0)
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
    ALBEDO = vec3(0.015, 0.18, 0.25);
    ROUGHNESS = 0.22;
}
"""


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
	}
