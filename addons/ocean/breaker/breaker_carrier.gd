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
@export var carrier_validation_wireframe := false
@export var carrier_validation_phase_debug := false
@export var carrier_validation_event_acquisition := true

var _mesh_instance: MeshInstance3D
var _mesh: ArrayMesh
var _carrier_material: ShaderMaterial
var _ocean: Node
var _attached := false
var _camera_update_accumulator := 0.0
var _validation_report: Dictionary = {}
var _event_acquired := false
var _event_sequence := -1
var _event_acquired_time_s := -1.0
var _pending_event_sequence := -1
var _event_seed_uv := Vector2.ZERO
var _event_seed_sample_xz := Vector2.ZERO
var _event_seed_world_xz := Vector2.ZERO
var _event_seed_sim_time := -1.0
var _event_acquisition_sim_time := -1.0
var _event_acquisition_age_s := INF
var _event_forward_warp_check_xz := Vector2.ZERO
var _event_inverse_error_m := INF
var _event_inverse_valid := false
var _carrier_world_crest_xz := Vector2.ZERO
var _carrier_sample_crest_xz := Vector2.ZERO
var _carrier_frame_sequence := -1
var _center_lifecycle_sample_xz := Vector2.ZERO
var _center_sample_error_m := INF
var _frame_world_search_xz := Vector2.ZERO
var _frame_wavelength_search_m := 0.0
var _frame_search_s_profile_m := 0.0
var _frame_world_crest_guess_xz := Vector2.ZERO
var _frame_wavelength_final_m := 0.0
var _frame_residual_s_m := 0.0
var _frame_distance_search_to_crest_m := 0.0
var _frame_snap_invariants_valid := false


func _ready() -> void:
	_build_static_mesh()
	var camera := get_node_or_null(^"Camera3D") as Camera3D
	if camera == null:
		camera = get_parent().get_node_or_null(^"GateBCamera") as Camera3D
	if camera == null:
		camera = get_parent().get_node_or_null(^"GateCCamera") as Camera3D
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
	_mesh_instance.visible = not attach_to_ocean
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
	var open_ocean := surface.get_parent()
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource
	var event_duration := float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8
	if carrier_validation_event_acquisition and open_ocean != null and open_ocean.has_method(&"get_breaker_event_probe_state"):
		if open_ocean.has_method(&"request_breaker_event_probe_readback"):
			open_ocean.request_breaker_event_probe_readback()
		var probe: Dictionary = open_ocean.get_breaker_event_probe_state()
		var probe_sequence := int(probe.get("sequence", -1))
		var probe_sample_xz: Vector2 = probe.get("sample_xz", Vector2.ZERO)
		var probe_age_s := float(probe.get("acquisition_age_s", INF))
		if not _event_acquired and bool(probe.get("valid", false)) and probe_age_s < event_duration and probe_sequence > _event_sequence and probe_sequence > _pending_event_sequence:
			_pending_event_sequence = probe_sequence
			_event_seed_uv = probe.get("uv", Vector2.ZERO)
			_event_seed_sample_xz = probe_sample_xz
			_event_seed_sim_time = float(probe.get("seed_sim_time", -1.0))
			_event_acquisition_sim_time = float(probe.get("acquisition_sim_time", -1.0))
			_event_acquisition_age_s = probe_age_s
		elif _event_acquired:
			var current_sim_time := float(open_ocean.get_breaker_lifecycle_sim_time()) if open_ocean.has_method(&"get_breaker_lifecycle_sim_time") else -1.0
			var event_age_s := current_sim_time - _event_seed_sim_time if current_sim_time >= 0.0 and _event_seed_sim_time >= 0.0 else Time.get_ticks_usec() * 0.000001 - _event_acquired_time_s
			if event_age_s >= event_duration:
				_event_acquired = false
				_pending_event_sequence = -1
				_carrier_frame_sequence = -1
				_validation_report.clear()
				_carrier_world_crest_xz = Vector2.ZERO
				_carrier_sample_crest_xz = Vector2.ZERO
	var state: Dictionary = surface.get_runtime_feature_state()
	var parameters: Dictionary = state.get("surface_parameter_state", {})
	if parameters.is_empty():
		return
	var required := ["displacement_long", "displacement_mid", "displacement_short", "coastal_phase", "coastal_metrics", "coastal_field", "coastal_warp", "breaker_lifecycle", "breaker_multiphase_vdm"]
	for key in required:
		if parameters.get(key) == null:
			return
	for key in ["displacement_long", "displacement_mid", "displacement_short", "coastal_phase", "coastal_metrics", "coastal_field", "coastal_warp", "breaker_lifecycle", "breaker_multiphase_vdm"]:
		_carrier_material.set_shader_parameter(key, parameters[key])
	for key in ["domain_long_m", "domain_mid_m", "domain_short_m", "coastal_origin", "coastal_extent", "coastal_warp_origin", "coastal_warp_extent", "coastal_warp_detj_safe"]:
		if parameters.has(key):
			_carrier_material.set_shader_parameter(key, parameters[key])
	var gate_camera := get_parent().get_node_or_null(^"GateBCamera") as Camera3D
	if gate_camera == null:
		gate_camera = get_parent().get_node_or_null(^"GateCCamera") as Camera3D
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
	var event_acquired_this_frame := false
	if not _event_acquired and _pending_event_sequence >= 0 and warp_image != null and not warp_image.is_empty():
		event_acquired_this_frame = _resolve_pending_event(parameters, warp_image)
	if event_acquired_this_frame:
		update_camera = true
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
		var crest_anchor: Vector2 = frame.get("world_crest_xz", carrier_search_xz)
		_carrier_world_crest_xz = crest_anchor
		_carrier_sample_crest_xz = frame.get("sample_crest_xz", Vector2.ZERO)
		var forward: Vector2 = frame.get("forward", Vector2(0.0, 1.0))
		var tangent: Vector2 = frame.get("tangent", Vector2(-forward.y, forward.x))
		var camera_direction := (tangent * 0.65 - forward * 0.75).normalized()
		gate_camera.position = Vector3(crest_anchor.x + camera_direction.x * 18.0, 1.25, crest_anchor.y + camera_direction.y * 18.0)
		gate_camera.look_at(Vector3(crest_anchor.x, 1.0, crest_anchor.y), Vector3.UP)
		_carrier_frame_sequence = _event_sequence if _event_acquired else -1
		_center_lifecycle_sample_xz = _event_seed_sample_xz
		_center_sample_error_m = _center_lifecycle_sample_xz.distance_to(_event_seed_sample_xz)
		_frame_world_search_xz = frame.get("world_search_xz", carrier_search_xz)
		_frame_wavelength_search_m = float(frame.get("wavelength_search_m", 0.0))
		_frame_search_s_profile_m = float(frame.get("search_s_profile_m", 0.0))
		_frame_world_crest_guess_xz = frame.get("world_crest_guess_xz", crest_anchor)
		_frame_wavelength_final_m = float(frame.get("wavelength_final_m", 0.0))
		_frame_residual_s_m = float(frame.get("residual_s_m", 0.0))
		_frame_distance_search_to_crest_m = _frame_world_search_xz.distance_to(crest_anchor)
		_frame_snap_invariants_valid = absf(_frame_search_s_profile_m) <= _frame_wavelength_search_m * 0.5 + 0.001 and absf(_frame_residual_s_m) <= _frame_wavelength_final_m * 0.5 + 0.001
		if _event_acquired:
			_validation_report = _validate_centerline(frame)
			_validation_report["event_sequence"] = _event_sequence
			_validation_report["frame_sequence"] = _carrier_frame_sequence
			_validation_report["crest_snap_invariants_valid"] = _frame_snap_invariants_valid
			if not _frame_snap_invariants_valid:
				_event_acquired = false
				_carrier_frame_sequence = -1
	_carrier_material.set_shader_parameter(&"carrier_search_xz", carrier_search_xz)
	_carrier_material.set_shader_parameter(&"carrier_event_seed_sample_xz", _event_seed_sample_xz)
	_carrier_material.set_shader_parameter(&"carrier_reference_wavelength_m", WAVELENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_crest_length_m", CREST_LENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_vertical_scale", 1.0)
	_carrier_material.set_shader_parameter(&"carrier_validation_cutaway", carrier_validation_cutaway)
	_carrier_material.set_shader_parameter(&"carrier_validation_wireframe", carrier_validation_wireframe)
	_carrier_material.set_shader_parameter(&"carrier_validation_phase_debug", carrier_validation_phase_debug)
	if surface.has_method(&"set_breaker_carrier_suppression"):
		surface.set_breaker_carrier_suppression(true, carrier_search_xz, CREST_LENGTH_M, _event_seed_sample_xz)
	_mesh_instance.visible = true
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
	var code := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, unshaded;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D coastal_phase : repeat_disable, filter_linear;
uniform sampler2D coastal_metrics : repeat_disable, filter_linear;
uniform sampler2D coastal_field : repeat_disable, filter_linear;
uniform sampler2D coastal_warp : repeat_disable, filter_linear;
uniform sampler2D breaker_lifecycle : repeat_enable, filter_linear;
uniform sampler2D breaker_multiphase_vdm : repeat_disable, filter_linear;
uniform float domain_long_m = 512.0;
uniform float domain_mid_m = 137.0;
uniform float domain_short_m = 37.0;
uniform vec2 coastal_origin = vec2(0.0);
uniform vec2 coastal_extent = vec2(1.0);
uniform vec2 coastal_warp_origin = vec2(0.0);
uniform vec2 coastal_warp_extent = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;
uniform vec2 carrier_search_xz = vec2(0.0);
uniform vec2 carrier_event_seed_sample_xz = vec2(0.0);
uniform float carrier_reference_wavelength_m = 32.0;
uniform float carrier_crest_length_m = 32.0;
uniform float carrier_vertical_scale = 1.0;
uniform bool carrier_validation_cutaway = false;
uniform bool carrier_validation_wireframe = false;
uniform bool carrier_validation_phase_debug = false;

varying float carrier_visibility;
varying float carrier_phase_b;
varying vec3 carrier_world_position;

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
    vec2 world_search_xz = carrier_search_xz;
    vec2 search_uv = clamp(coastal_uv(world_search_xz, coastal_origin, coastal_extent), vec2(0.0), vec2(1.0));
    vec4 phase_search = texture(coastal_phase, search_uv);
    vec4 metrics_search = texture(coastal_metrics, search_uv);
    vec2 forward_search = -normalize(phase_search.yz);
    if (length(phase_search.yz) < 0.0001) forward_search = vec2(0.0, 1.0);
    float wavelength_search = max(metrics_search.g, 0.001);
    float wrapped_phase = mod(phase_search.r + 3.14159265359, 6.28318530718) - 3.14159265359;
    float search_s_profile = -wrapped_phase / max(6.28318530718 / wavelength_search, 0.001);
    vec2 world_crest_guess_xz = world_search_xz - forward_search * search_s_profile;
    vec2 crest_guess_uv = clamp(coastal_uv(world_crest_guess_xz, coastal_origin, coastal_extent), vec2(0.0), vec2(1.0));
    vec4 phase_info = texture(coastal_phase, crest_guess_uv);
    vec4 metrics_info = texture(coastal_metrics, crest_guess_uv);
    vec2 forward = -normalize(phase_info.yz);
    if (length(phase_info.yz) < 0.0001) forward = forward_search;
    float wavelength_m = max(metrics_info.g, wavelength_search);
    float residual_phase = mod(phase_info.r + 3.14159265359, 6.28318530718) - 3.14159265359;
    float residual_s = -residual_phase / max(6.28318530718 / wavelength_m, 0.001);
    vec2 world_crest_xz = world_crest_guess_xz - forward * residual_s;
    vec2 tangent = vec2(-forward.y, forward.x);
    float profile_u = clamp(UV.x, 0.5 / 256.0, 255.5 / 256.0);
    float base_s = (profile_u - 0.5) * wavelength_m;
    float crest_s = (UV.y - 0.5) * carrier_crest_length_m;
    vec2 lateral_world_xz = world_crest_xz + tangent * crest_s;
    vec2 warp_center_xz = texture(coastal_warp, clamp(coastal_uv(world_crest_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0))).xy;
    vec2 warp_lateral_xz = texture(coastal_warp, clamp(coastal_uv(lateral_world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0))).xy;
    vec2 lifecycle_sample_xz = carrier_event_seed_sample_xz + (warp_lateral_xz - warp_center_xz);
    vec4 lifecycle_state = texture(breaker_lifecycle, world_uv(lifecycle_sample_xz, domain_long_m));
    float event_active = smoothstep(0.05, 0.35, lifecycle_state.r);
    float event_energy = clamp(lifecycle_state.a, 0.0, 1.0);
    float phase_position = clamp(lifecycle_state.b, 0.0, 1.0) * 7.0;
    float phase_index = floor(phase_position);
    float phase_fraction = smoothstep(0.0, 1.0, fract(phase_position));
    float safe_v = clamp(UV.y, 0.5 / 256.0, 255.5 / 256.0);
    vec4 vdm_phase_0 = texture(breaker_multiphase_vdm, vec2(profile_u, (phase_index + safe_v) / 8.0));
    vec4 vdm_phase_1 = texture(breaker_multiphase_vdm, vec2(profile_u, (min(phase_index + 1.0, 7.0) + safe_v) / 8.0));
    vec4 vdm_sample = mix(vdm_phase_0, vdm_phase_1, phase_fraction);
    float delta_s = vdm_sample.r * (wavelength_m / 12.0);
    float target_s = base_s + delta_s;
    float lateral_offset = vdm_sample.g * (wavelength_m / 12.0);
    float target_y = vdm_sample.b * (2.0 / 3.72184);
    vec2 base_xz = world_crest_xz + forward * base_s + tangent * crest_s;
    vec3 ocean_base = sample_ocean_base(base_xz);
    vec3 base_world = vec3(base_xz.x + ocean_base.x, ocean_base.y, base_xz.y + ocean_base.z);
    vec2 crest_param_xz = world_crest_xz + tangent * crest_s;
    vec3 crest_disp = sample_ocean_base(crest_param_xz);
    vec2 crest_world_xz = crest_param_xz + crest_disp.xz;
    vec2 breaker_world_xz = crest_world_xz + forward * target_s + tangent * lateral_offset;
    vec3 breaker_world = vec3(breaker_world_xz.x, crest_disp.y + target_y * carrier_vertical_scale, breaker_world_xz.y);
    float rear_attachment = smoothstep(0.0, 0.08, profile_u);
    float front_attachment = 1.0 - smoothstep(0.92, 1.0, profile_u);
    float lateral_attachment = smoothstep(0.0, 0.12, UV.y) * (1.0 - smoothstep(0.88, 1.0, UV.y));
    float shape_authority = event_active * event_energy * clamp(vdm_sample.a, 0.0, 1.0) * rear_attachment * front_attachment * lateral_attachment;
    carrier_visibility = event_active * event_energy;
    carrier_phase_b = lifecycle_state.b;
    VERTEX = mix(base_world, breaker_world, shape_authority);
    carrier_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    if (carrier_visibility < 0.001) discard;
    if (carrier_validation_wireframe && (UV.y < 0.47 || UV.y > 0.53)) discard;
    if (carrier_validation_cutaway && UV.y > 0.52) discard;
    vec3 geometric_normal = normalize(cross(dFdx(carrier_world_position), dFdy(carrier_world_position)));
    float normal_readability = clamp(0.5 + 0.5 * geometric_normal.y, 0.0, 1.0);
    float debug_phase = clamp(carrier_phase_b, 0.0, 1.0);
    ALBEDO = carrier_validation_phase_debug ? vec3(debug_phase, 1.0 - debug_phase, 0.15 + 0.7 * clamp(carrier_visibility, 0.0, 1.0)) : mix(vec3(0.010, 0.085, 0.13), vec3(0.025, 0.28, 0.42), normal_readability);
    ROUGHNESS = 0.22;
}
	"""
	if carrier_validation_wireframe:
		code = code.replace("render_mode blend_mix, cull_disabled, depth_draw_opaque, unshaded;", "render_mode blend_mix, cull_disabled, depth_draw_opaque, unshaded, wireframe;")
	return code


func _resolve_pending_event(parameters: Dictionary, warp_image: Image) -> bool:
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource
	var event_duration := float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8
	if _event_acquisition_age_s >= event_duration:
		_pending_event_sequence = -1
		return false
	var inverse := _inverse_coastal_warp(parameters, warp_image, _event_seed_sample_xz)
	_event_sequence = _pending_event_sequence
	_pending_event_sequence = -1
	_event_inverse_valid = bool(inverse.get("valid", false))
	_event_inverse_error_m = float(inverse.get("inverse_error_m", INF))
	_event_forward_warp_check_xz = inverse.get("forward_warp_check_xz", Vector2.ZERO)
	if not _event_inverse_valid:
		return false
	var resolved_world_xz: Vector2 = inverse.get("world_xz", Vector2.ZERO)
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ZERO)
	var inside := coastal_extent.x > 0.0 and coastal_extent.y > 0.0 and resolved_world_xz.x >= coastal_origin.x and resolved_world_xz.y >= coastal_origin.y and resolved_world_xz.x <= coastal_origin.x + coastal_extent.x and resolved_world_xz.y <= coastal_origin.y + coastal_extent.y
	if not inside:
		_event_inverse_valid = false
		return false
	_carrier_frame_sequence = -1
	_validation_report.clear()
	_carrier_world_crest_xz = Vector2.ZERO
	_carrier_sample_crest_xz = Vector2.ZERO
	_event_seed_world_xz = resolved_world_xz
	carrier_search_xz = _event_seed_world_xz
	_event_acquired = true
	_event_acquired_time_s = Time.get_ticks_usec() * 0.000001
	return true


func _inverse_coastal_warp(parameters: Dictionary, warp_image: Image, target_sample_xz: Vector2) -> Dictionary:
	var width := warp_image.get_width()
	var height := warp_image.get_height()
	if width < 2 or height < 2:
		return {"valid": false, "inverse_error_m": INF}
	var warp_origin: Vector2 = parameters.get("coastal_warp_origin", parameters.get("coastal_origin", Vector2.ZERO))
	var warp_extent: Vector2 = parameters.get("coastal_warp_extent", parameters.get("coastal_extent", Vector2.ONE))
	var detj_safe := maxf(float(parameters.get("coastal_warp_detj_safe", 0.5)), 0.001)
	var stride := maxi(1, maxi(width, height) / 64)
	var best_pixel := Vector2i(-1, -1)
	var best_error_sq := INF
	for y in range(0, height, stride):
		for x in range(0, width, stride):
			var value := warp_image.get_pixel(x, y)
			var confidence := value.a * _smoothstep(0.0, detj_safe, value.b)
			if confidence <= 0.05:
				continue
			var error_sq := Vector2(value.r, value.g).distance_squared_to(target_sample_xz)
			if error_sq < best_error_sq:
				best_error_sq = error_sq
				best_pixel = Vector2i(x, y)
	if best_pixel.x < 0:
		return {"valid": false, "inverse_error_m": INF}
	var radius := maxi(stride * 2, 1)
	var x0 := maxi(best_pixel.x - radius, 0)
	var x1 := mini(best_pixel.x + radius, width - 1)
	var y0 := maxi(best_pixel.y - radius, 0)
	var y1 := mini(best_pixel.y + radius, height - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var value := warp_image.get_pixel(x, y)
			var confidence := value.a * _smoothstep(0.0, detj_safe, value.b)
			if confidence <= 0.05:
				continue
			var error_sq := Vector2(value.r, value.g).distance_squared_to(target_sample_xz)
			if error_sq < best_error_sq:
				best_error_sq = error_sq
				best_pixel = Vector2i(x, y)
	var world_xz := warp_origin + Vector2(float(best_pixel.x) / float(width - 1) * warp_extent.x, float(best_pixel.y) / float(height - 1) * warp_extent.y)
	var texel_m := maxf(absf(warp_extent.x) / float(width - 1), absf(warp_extent.y) / float(height - 1))
	var epsilon := maxf(texel_m * 0.5, 0.01)
	for _iteration in 3:
		var center := _sample_image_uv(warp_image, (world_xz - warp_origin) / warp_extent)
		var sample_x := _sample_image_uv(warp_image, (world_xz + Vector2(epsilon, 0.0) - warp_origin) / warp_extent)
		var sample_z := _sample_image_uv(warp_image, (world_xz + Vector2(0.0, epsilon) - warp_origin) / warp_extent)
		var jacobian_00 := (sample_x.r - center.r) / epsilon
		var jacobian_01 := (sample_z.r - center.r) / epsilon
		var jacobian_10 := (sample_x.g - center.g) / epsilon
		var jacobian_11 := (sample_z.g - center.g) / epsilon
		var determinant := jacobian_00 * jacobian_11 - jacobian_01 * jacobian_10
		if absf(determinant) < 0.0001:
			break
		var residual := Vector2(center.r, center.g) - target_sample_xz
		var correction := Vector2((jacobian_11 * residual.x - jacobian_01 * residual.y) / determinant, (-jacobian_10 * residual.x + jacobian_00 * residual.y) / determinant)
		world_xz -= correction
		world_xz.x = clampf(world_xz.x, warp_origin.x, warp_origin.x + warp_extent.x)
		world_xz.y = clampf(world_xz.y, warp_origin.y, warp_origin.y + warp_extent.y)
	var forward_value := _sample_image_uv(warp_image, (world_xz - warp_origin) / warp_extent)
	var forward_warp_check_xz := Vector2(forward_value.r, forward_value.g)
	var inverse_error_m := forward_warp_check_xz.distance_to(target_sample_xz)
	return {
		"valid": inverse_error_m <= texel_m,
		"world_xz": world_xz,
		"forward_warp_check_xz": forward_warp_check_xz,
		"inverse_error_m": inverse_error_m,
		"texel_m": texel_m,
	}


func _compute_carrier_frame(parameters: Dictionary, phase_image: Image, metrics_image: Image, field_image: Image, warp_image: Image) -> Dictionary:
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
	var warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
	var warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
	var world_search_xz := carrier_search_xz
	var search_uv := (world_search_xz - coastal_origin) / coastal_extent
	var phase_search := _sample_image_uv(phase_image, search_uv)
	var metrics_search := _sample_image_uv(metrics_image, search_uv)
	var warp_search := _sample_image_uv(warp_image, (world_search_xz - warp_origin) / warp_extent)
	var forward_search := -Vector2(phase_search.g, phase_search.b).normalized()
	if forward_search.length_squared() < 0.0001: forward_search = Vector2(0.0, 1.0)
	var detj_safe := maxf(float(parameters.get("coastal_warp_detj_safe", 0.5)), 0.001)
	var wavelength_search := maxf(metrics_search.g, 0.001)
	var wrapped_search_phase := fposmod(phase_search.r + PI, TAU) - PI
	var search_s_profile := -wrapped_search_phase / (TAU / wavelength_search)
	var world_crest_guess_xz := world_search_xz - forward_search * search_s_profile
	var crest_guess_uv := (world_crest_guess_xz - coastal_origin) / coastal_extent
	var phase_info := _sample_image_uv(phase_image, crest_guess_uv)
	var metrics_info := _sample_image_uv(metrics_image, crest_guess_uv)
	var forward := -Vector2(phase_info.g, phase_info.b).normalized()
	if forward.length_squared() < 0.0001: forward = forward_search
	var wavelength_m := maxf(metrics_info.g, wavelength_search)
	var wrapped_residual_phase := fposmod(phase_info.r + PI, TAU) - PI
	var residual_s := -wrapped_residual_phase / (TAU / wavelength_m)
	var world_crest_xz := world_crest_guess_xz - forward * residual_s
	var tangent := Vector2(-forward.y, forward.x)
	var warp_at_crest := _sample_image_uv(warp_image, (world_crest_xz - warp_origin) / warp_extent)
	var field_at_crest := _sample_image_uv(field_image, (world_crest_xz - coastal_origin) / coastal_extent)
	var crest_confidence := clampf(field_at_crest.a * _smoothstep(0.0, detj_safe, warp_at_crest.b), 0.0, 1.0)
	var sample_crest_candidate_xz := world_crest_xz.lerp(Vector2(warp_at_crest.r, warp_at_crest.g), crest_confidence)
	var sample_crest_xz := sample_crest_candidate_xz - forward * residual_s
	return {
		"world_crest_xz": world_crest_xz,
		"sample_crest_xz": sample_crest_xz,
		"world_search_xz": world_search_xz,
		"wavelength_search_m": wavelength_search,
		"search_s_profile_m": search_s_profile,
		"world_crest_guess_xz": world_crest_guess_xz,
		"wavelength_final_m": wavelength_m,
		"residual_s_m": residual_s,
		"forward": forward,
		"tangent": tangent,
		"wavelength_m": wavelength_m,
		"sample_search_xz": Vector2(warp_search.r, warp_search.g),
		"confidence": crest_confidence,
		"phase_search": phase_search,
		"metrics_search": metrics_search,
		"phase_final": phase_info,
		"metrics_final": metrics_info,
	}


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



func _validate_centerline(frame: Dictionary) -> Dictionary:
	var wavelength: float = float(frame.get("wavelength_m", WAVELENGTH_M))
	var forward: Vector2 = frame.get("forward", Vector2(0.0, 1.0))
	var tangent: Vector2 = frame.get("tangent", Vector2(-forward.y, forward.x))
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
		var rear := _smoothstep(0.0, 0.08, u)
		var front := 1.0 - _smoothstep(0.92, 1.0, u)
		var authority := rear * front
		var base_s := (u - 0.5) * wavelength
		final_s.append(lerpf(base_s, target_s, authority))
		final_y.append(target_y * authority)
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
	return {"sample_count": 1024, "cpu_world_parity": false, "authority_min_p5": authority_values[470], "authority_max_p5": authority_values[750], "negative_derivative_u0": float(negative_first) / 1023.0 if negative_first >= 0 else -1.0, "negative_derivative_u1": float(negative_last + 1) / 1023.0 if negative_last >= 0 else -1.0, "negative_derivative_sample_count": negative_count, "minimum_d_final_s_du": min_derivative, "minimum_derivative_u": float(min_derivative_index) / 1023.0, "final_s_min": final_s_min, "final_s_max": final_s_max, "final_y_min": final_y_min, "final_y_max": final_y_max, "world_crest_xz": frame.get("world_crest_xz", carrier_search_xz), "sample_crest_xz": frame.get("sample_crest_xz", Vector2.ZERO), "world_search_xz": frame.get("world_search_xz", carrier_search_xz), "forward": forward, "tangent": tangent, "wavelength_m": wavelength, "confidence": frame.get("confidence", 0.0)}


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
		"event_acquired": _event_acquired,
		"event_sequence": _event_sequence,
		"frame_sequence": _carrier_frame_sequence,
		"event_seed_uv": _event_seed_uv,
		"event_seed_sample_xz": _event_seed_sample_xz,
		"event_seed_world_xz": _event_seed_world_xz,
		"event_seed_sim_time": _event_seed_sim_time,
		"event_acquisition_sim_time": _event_acquisition_sim_time,
		"event_acquisition_age_s": _event_acquisition_age_s,
		"event_forward_warp_check_xz": _event_forward_warp_check_xz,
		"event_inverse_error_m": _event_inverse_error_m,
		"event_inverse_valid": _event_inverse_valid,
		"carrier_world_crest_xz": _carrier_world_crest_xz,
		"carrier_sample_crest_xz": _carrier_sample_crest_xz,
		"center_lifecycle_sample_xz": _center_lifecycle_sample_xz,
		"center_sample_error_m": _center_sample_error_m,
		"world_search_xz": _frame_world_search_xz,
		"wavelength_search_m": _frame_wavelength_search_m,
		"search_s_profile_m": _frame_search_s_profile_m,
		"world_crest_guess_xz": _frame_world_crest_guess_xz,
		"wavelength_final_m": _frame_wavelength_final_m,
		"residual_s_m": _frame_residual_s_m,
		"distance_search_to_crest_m": _frame_distance_search_to_crest_m,
		"crest_snap_invariants_valid": _frame_snap_invariants_valid,
	}
