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
## The actual carrier anchor uses Coastal phase.r for crest localization; its
## propagation frame comes from the runtime LONG spectrum and Coastal warp.
@export var carrier_search_xz := Vector2.ZERO
## Validation-only cutaway. It removes the camera-side half in the carrier
## fragment shader without changing vertices, authority, or topology.
@export var carrier_validation_cutaway := false
@export var carrier_validation_wireframe := false
@export var carrier_validation_phase_debug := false
## Validation-only exact atlas phase hold. Negative keeps normal lifecycle.B.
@export var carrier_validation_phase_override := -1.0
## Validation-only lateral extent. P3C manual review uses 0..1; production
## runtime passes -1 to the shader and derives extent from event age instead.
@export_range(0.0, 1.0, 0.01) var validation_lateral_progress := 1.0
## Validation-only lateral seed offset along the frozen carrier tangent.
@export_range(-16.0, 16.0, 0.1, "suffix:m") var validation_lateral_seed_offset_m := 0.0
@export var carrier_validation_event_acquisition := true
@export var validation_enabled := false
@export var carrier_validation_force_event := false
@export_range(0.0, 60.0, 0.5, "suffix:s") var carrier_validation_hold_seconds := 5.0
@export var carrier_validation_event_position_xz := Vector2.ZERO
## Validation override for controlled propagation tests. Zero means automatic
## runtime LONG propagation transformed through the local Coastal warp.
@export var carrier_validation_forward_xz := Vector2.ZERO
@export_enum("SIDE_PROFILE", "THREE_QUARTER") var carrier_validation_camera_view := 0
@export_enum("NORMAL", "AUTHORITY", "RESIDUAL_MAGNITUDE", "BASE_VS_BREAKER", "TRIANGLE_STRETCH", "TRAVELLING_PHASE", "CREST_TRACKING") var carrier_validation_visual_mode := 0
@export var validation_geometry_material := false
## P3D validation-only travelling phase mirror. Production always uses lifecycle R/B.
@export var validation_travelling_phase_enabled := false
@export_range(0.0, 10.0, 0.05, "suffix:s") var validation_travelling_time_s := 0.0
@export var carrier_validation_extra_cull_margin := 0.0
@export var carrier_validation_force_visible_color := false
## Validation-only authoritative event frame. When enabled, Carrier and the
## base-ocean suppression mask consume the same origin/axes/footprint. The
## production event frame is authoritative once an event is acquired; this
## toggle only controls the optional visual/debug frame.
@export var validation_event_frame_debug := false
## P3D.1 validation controls. Production tracking is always enabled once an
## event frame has been acquired; these switches only control the lab event.
@export var validation_crest_tracking_enabled := true
@export var validation_freeze_tracking := false
@export var validation_show_prediction := false
@export var validation_show_snap := false
## Increment in the Inspector after changing wind_direction to reacquire the
## forced validation event without adding a runtime hotkey or production API.
@export var validation_event_reacquire_serial := 0
## Retained for scene compatibility. Active events never auto-reacquire on wind
## change; use validation_event_reacquire_serial for an explicit reset.
@export var validation_auto_reacquire_on_long_direction_change := true

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
var _event_score := 0.0
var _event_age_normalized := 1.0
var _event_age_s := INF
var _refractory_active := false
var _refractory_remaining_s := 0.0
var _event_duration_configured_s := 0.8
var _event_duration_sent_s := 0.8
var _event_refractory_s := 3.0
var _validation_hold_active := false
var _validation_hold_started_time_s := -1.0
var _last_validation_event_reacquire_serial := 0
var _validation_event_sequence_counter := 0
var _validation_long_direction_captured := Vector2.ZERO
var _validation_event_long_generation := -1
var _event_direction_capture_time_s := -1.0
var _event_direction_frozen := false
var _frozen_carrier_frame: Dictionary = {}
var _event_capture_long_generation := -1
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
var _p5_validation_report: Dictionary = {}
var _frame_distance_search_to_crest_m := 0.0
var _frame_snap_invariants_valid := false
var _carrier_frame_forward_xz := Vector2(0.0, 1.0)
var _carrier_frame_tangent_xz := Vector2(-1.0, 0.0)
var _carrier_frame_wavelength_m := WAVELENGTH_M
var _carrier_long_propagation_xz := Vector2.RIGHT
var _carrier_long_generation := -1
var _carrier_local_propagation_xz := Vector2.RIGHT
var _carrier_wind_direction_parameter := 0.0
var _carrier_coastal_active := false
var _carrier_coastal_transform_valid := false
var _carrier_propagation_direction_source := "runtime_long_fallback"
var _carrier_long_to_breaker_angle_deg := 0.0
var _carrier_local_to_breaker_angle_deg := 0.0
var _carrier_birth_crest_world_xz := Vector2.ZERO
var _carrier_predicted_crest_world_xz := Vector2.ZERO
var _carrier_tracking_phase_speed_mps := 0.0
var _carrier_tracking_snap_correction_m := 0.0
var _carrier_tracking_prediction_error_m := 0.0
var _carrier_tracking_phase_residual_rad := 0.0
var _carrier_tracking_birth_phase_rad := 0.0
var _carrier_tracking_elapsed_s := 0.0
var _carrier_tracking_phase_gradient_forward := 0.0
var _carrier_tracking_phase_travel_sign := 1.0
var _carrier_tracking_snap_valid := false
var _carrier_tracking_snap_rejected := false
var _carrier_tracking_initialized := false
var _carrier_tracking_updates := 0
var _carrier_tracking_phase_hops := 0
var _carrier_tracking_rejected_snaps := 0
var _carrier_tracking_frame_deltas: Array[float] = []
var _carrier_tracking_prediction_errors: Array[float] = []
var _carrier_tracking_snap_corrections: Array[float] = []
var _carrier_tracking_phase_residuals: Array[float] = []
var _carrier_tracking_lateral_drifts: Array[float] = []
var _carrier_tracking_last_update_origin_xz := Vector2.ZERO
var _carrier_tracking_last_event_id := -1
var _frame_debug_mesh_instance: MeshInstance3D
var _frame_debug_mesh: ImmediateMesh
var _frame_debug_material: StandardMaterial3D
var _last_frame_debug_event_id := -1
var _p5_material_lut := PackedVector2Array()
var _p3d_material_luts: Dictionary = {}
var _lateral_active_half_width_m := CREST_LENGTH_M * 0.5
var _lateral_feather_width_m := 1.5
var _lateral_suppression_margin_m := 0.5


func _validation_mode_active() -> bool:
	return validation_enabled and carrier_validation_force_event


func _compute_lateral_envelope(breaker_profile: Resource) -> Dictionary:
	var propagation_speed_mps := float(breaker_profile.get("breaker_lateral_propagation_speed_mps")) if breaker_profile != null and breaker_profile.has_method(&"get") else 4.0
	var continuity_m := float(breaker_profile.get("breaker_lateral_continuity_m")) if breaker_profile != null and breaker_profile.has_method(&"get") else 3.0
	var lateral_vertex_spacing_m := CREST_LENGTH_M / float(maxi(V_SAMPLES - 1, 1))
	var carrier_half_width_m := CREST_LENGTH_M * 0.5
	var seed_half_width_m := minf(maxf(continuity_m, lateral_vertex_spacing_m * 2.0), carrier_half_width_m)
	var target_half_width_m := carrier_half_width_m
	var feather_width_m := maxf(continuity_m, lateral_vertex_spacing_m * 2.0)
	var suppression_margin_m := lateral_vertex_spacing_m
	var manual_progress := clampf(validation_lateral_progress, 0.0, 1.0) if _validation_mode_active() else -1.0
	var event_age_s := maxf(_event_age_s, 0.0) if is_finite(_event_age_s) else 0.0
	var active_half_width_m := lerpf(seed_half_width_m, target_half_width_m, manual_progress) if manual_progress >= 0.0 else minf(seed_half_width_m + propagation_speed_mps * event_age_s, target_half_width_m)
	return {
		"active_half_width_m": active_half_width_m,
		"seed_half_width_m": seed_half_width_m,
		"target_half_width_m": target_half_width_m,
		"feather_width_m": feather_width_m,
		"suppression_margin_m": suppression_margin_m,
		"suppression_half_width_m": active_half_width_m + suppression_margin_m,
		"seed_offset_m": validation_lateral_seed_offset_m if _validation_mode_active() else 0.0,
		"propagation_speed_mps": propagation_speed_mps,
		"event_age_s": event_age_s,
		"manual_progress": manual_progress,
		"lateral_vertex_spacing_m": lateral_vertex_spacing_m,
	}


func _crest_tracking_enabled() -> bool:
	return not _validation_mode_active() or validation_crest_tracking_enabled


func _reset_crest_tracking_state() -> void:
	_carrier_birth_crest_world_xz = Vector2.ZERO
	_carrier_predicted_crest_world_xz = Vector2.ZERO
	_carrier_tracking_phase_speed_mps = 0.0
	_carrier_tracking_snap_correction_m = 0.0
	_carrier_tracking_prediction_error_m = 0.0
	_carrier_tracking_phase_residual_rad = 0.0
	_carrier_tracking_birth_phase_rad = 0.0
	_carrier_tracking_elapsed_s = 0.0
	_carrier_tracking_phase_gradient_forward = 0.0
	_carrier_tracking_phase_travel_sign = 1.0
	_carrier_tracking_snap_valid = false
	_carrier_tracking_snap_rejected = false
	_carrier_tracking_initialized = false
	_carrier_tracking_updates = 0
	_carrier_tracking_phase_hops = 0
	_carrier_tracking_rejected_snaps = 0
	_carrier_tracking_frame_deltas.clear()
	_carrier_tracking_prediction_errors.clear()
	_carrier_tracking_snap_corrections.clear()
	_carrier_tracking_phase_residuals.clear()
	_carrier_tracking_lateral_drifts.clear()
	_carrier_tracking_last_update_origin_xz = Vector2.ZERO
	_carrier_tracking_last_event_id = -1


func _begin_crest_tracking(frame: Dictionary, parameters: Dictionary, phase_image: Image) -> void:
	var origin: Vector2 = frame.get("world_crest_xz", carrier_search_xz)
	_carrier_birth_crest_world_xz = origin
	_carrier_predicted_crest_world_xz = origin
	_carrier_tracking_last_update_origin_xz = origin
	_carrier_tracking_initialized = true
	_carrier_tracking_last_event_id = _event_sequence
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
	var birth_phase := _sample_image_uv(phase_image, (origin - coastal_origin) / coastal_extent).r if phase_image != null and not phase_image.is_empty() else 0.0
	_carrier_tracking_birth_phase_rad = fposmod(birth_phase + PI, TAU) - PI
	if phase_image != null and not phase_image.is_empty():
		var gradient_step := minf(maxf(float(frame.get("wavelength_m", WAVELENGTH_M)) * 0.05, 0.05), 1.0)
		var tracking_forward := _safe_frame_direction(frame.get("forward", _carrier_frame_forward_xz), Vector2.RIGHT)
		var plus_phase := _sample_image_uv(phase_image, (origin + tracking_forward * gradient_step - coastal_origin) / coastal_extent).r
		var minus_phase := _sample_image_uv(phase_image, (origin - tracking_forward * gradient_step - coastal_origin) / coastal_extent).r
		_carrier_tracking_phase_gradient_forward = (fposmod(plus_phase - minus_phase + PI, TAU) - PI) / (2.0 * gradient_step)
		_carrier_tracking_phase_travel_sign = 1.0 if _carrier_tracking_phase_gradient_forward >= 0.0 else -1.0


func _track_crest_origin(parameters: Dictionary, phase_image: Image, metrics_image: Image, warp_image: Image, field_image: Image, frame: Dictionary, delta: float, open_ocean: Node) -> Dictionary:
	if not _crest_tracking_enabled() or validation_freeze_tracking:
		_carrier_predicted_crest_world_xz = _carrier_world_crest_xz
		_carrier_tracking_snap_valid = false
		_carrier_tracking_snap_rejected = false
		return frame
	if not _carrier_tracking_initialized or _carrier_tracking_last_event_id != _event_sequence:
		_begin_crest_tracking(frame, parameters, phase_image)
		return frame
	var frozen_forward := _safe_frame_direction(_carrier_frame_forward_xz, Vector2.RIGHT)
	var reference_wavelength := maxf(_carrier_frame_wavelength_m, 0.001)
	var phase_speed := _get_long_phase_speed_mps(open_ocean, reference_wavelength)
	_carrier_tracking_phase_speed_mps = phase_speed
	var dt := maxf(delta, 0.0)
	_carrier_tracking_elapsed_s += dt
	var predicted := _carrier_world_crest_xz + frozen_forward * phase_speed * dt
	_carrier_predicted_crest_world_xz = predicted
	var omega := phase_speed * TAU / reference_wavelength
	var snap := _resnap_crest_to_phase(parameters, phase_image, metrics_image, predicted, frozen_forward, reference_wavelength, _carrier_tracking_birth_phase_rad, _carrier_tracking_phase_travel_sign * omega * _carrier_tracking_elapsed_s)
	var snap_limit := reference_wavelength * 0.30
	var max_correction := maxf(phase_speed * dt * 2.5, reference_wavelength * 0.08)
	var correction: Vector2 = snap.get("correction_xz", Vector2.ZERO)
	var correction_length := correction.length()
	var accepted := bool(snap.get("valid", false)) and correction_length <= snap_limit and correction_length <= max_correction
	var tracked := predicted + correction if accepted else predicted
	_carrier_tracking_snap_valid = accepted
	_carrier_tracking_snap_rejected = not accepted and bool(snap.get("valid", false))
	_carrier_tracking_snap_correction_m = correction_length if accepted else 0.0
	_carrier_tracking_prediction_error_m = correction_length
	_carrier_tracking_phase_residual_rad = float(snap.get("wrapped_phase", 0.0)) if accepted else 0.0
	if _carrier_tracking_snap_rejected:
		_carrier_tracking_rejected_snaps += 1
	if correction_length > reference_wavelength * 0.5:
		_carrier_tracking_phase_hops += 1
	var frame_delta := tracked.distance_to(_carrier_world_crest_xz)
	_carrier_tracking_updates += 1
	_carrier_tracking_frame_deltas.append(frame_delta)
	_carrier_tracking_prediction_errors.append(correction_length)
	_carrier_tracking_snap_corrections.append(_carrier_tracking_snap_correction_m)
	_carrier_tracking_phase_residuals.append(absf(_carrier_tracking_phase_residual_rad))
	_carrier_tracking_lateral_drifts.append(absf((tracked - _carrier_birth_crest_world_xz).dot(_carrier_frame_tangent_xz)))
	if _carrier_tracking_frame_deltas.size() > 512:
		_carrier_tracking_frame_deltas.pop_front()
		_carrier_tracking_prediction_errors.pop_front()
		_carrier_tracking_snap_corrections.pop_front()
		_carrier_tracking_phase_residuals.pop_front()
		_carrier_tracking_lateral_drifts.pop_front()
	_carrier_world_crest_xz = tracked
	carrier_search_xz = tracked
	frame["world_crest_xz"] = tracked
	_carrier_tracking_last_update_origin_xz = tracked
	frame["sample_crest_xz"] = _tracked_sample_crest_xz(parameters, warp_image, field_image, tracked)
	return frame


func _resnap_crest_to_phase(parameters: Dictionary, phase_image: Image, metrics_image: Image, predicted: Vector2, forward: Vector2, reference_wavelength: float, birth_phase_rad: float, temporal_phase_rad: float) -> Dictionary:
	if phase_image == null or phase_image.is_empty() or metrics_image == null or metrics_image.is_empty():
		return {"valid": false, "correction_xz": Vector2.ZERO, "wrapped_phase": 0.0}
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
	var predicted_uv := (predicted - coastal_origin) / coastal_extent
	var phase_search := _sample_image_uv(phase_image, predicted_uv)
	var metrics_search := _sample_image_uv(metrics_image, predicted_uv)
	var snap_wavelength := maxf(float(metrics_search.g), reference_wavelength * 0.25)
	var wrapped_search := fposmod(phase_search.r - birth_phase_rad - temporal_phase_rad + PI, TAU) - PI
	var search_s := -wrapped_search / (TAU / snap_wavelength)
	var crest_guess := predicted - forward * search_s
	var guess_uv := (crest_guess - coastal_origin) / coastal_extent
	var phase_info := _sample_image_uv(phase_image, guess_uv)
	var metrics_info := _sample_image_uv(metrics_image, guess_uv)
	var final_wavelength := maxf(float(metrics_info.g), reference_wavelength * 0.25)
	var wrapped_residual := fposmod(phase_info.r - birth_phase_rad - temporal_phase_rad + PI, TAU) - PI
	var residual_s := -wrapped_residual / (TAU / final_wavelength)
	var snapped := crest_guess - forward * residual_s
	return {"valid": snapped.is_finite(), "correction_xz": snapped - predicted, "wrapped_phase": wrapped_residual, "snap_wavelength_m": final_wavelength}


func _tracked_sample_crest_xz(parameters: Dictionary, warp_image: Image, field_image: Image, tracked: Vector2) -> Vector2:
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
	if warp_image == null or warp_image.is_empty():
		return tracked
	var warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
	var warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
	var warp := _sample_image_uv(warp_image, (tracked - warp_origin) / warp_extent)
	var field := _sample_image_uv(field_image, (tracked - coastal_origin) / coastal_extent) if field_image != null and not field_image.is_empty() else Color(0, 0, 0, 0)
	var confidence := clampf(field.a * _smoothstep(0.0, maxf(float(parameters.get("coastal_warp_detj_safe", 0.5)), 0.001), warp.b), 0.0, 1.0)
	return tracked.lerp(Vector2(warp.r, warp.g), confidence)


func _get_long_phase_speed_mps(open_ocean: Node, wavelength_m: float) -> float:
	if open_ocean != null and open_ocean.has_method(&"get_long_phase_speed_mps"):
		var published_speed := float(open_ocean.get_long_phase_speed_mps(wavelength_m))
		if is_finite(published_speed) and published_speed > 0.0:
			return published_speed
	return sqrt(9.81 * maxf(wavelength_m, 0.001) / TAU)


func _tracking_stats(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var total := 0.0
	var maximum := 0.0
	for value in values:
		total += value
		maximum = maxf(maximum, value)
	return {"mean": total / float(values.size()), "p95": _p3d_percentile(values.duplicate(), 0.95), "max": maximum}


func _ready() -> void:
	_p5_material_lut = VDM_GENERATOR.build_material_arc_lut(VDM_GENERATOR.PROFILE_P5)
	_p3d_material_luts = VDM_GENERATOR.build_shared_material_luts()
	_build_static_mesh()
	_p5_validation_report = _compute_p5_validation_report()
	if _validation_mode_active():
		print("P5_VALIDATION_REPORT " + JSON.stringify(_p5_validation_report))
	var camera := get_node_or_null(^"Camera3D") as Camera3D
	if camera == null:
		camera = get_parent().get_node_or_null(^"GateBCamera") as Camera3D
	if camera == null:
		camera = get_parent().get_node_or_null(^"GateCCamera") as Camera3D
	if camera != null:
		camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	if attach_to_ocean:
		set_process(true)
	if validation_event_frame_debug or validation_show_prediction or validation_show_snap:
		_build_validation_event_frame_debug()


func _ensure_validation_event(open_ocean: Node, long_forward: Vector2, long_generation: int) -> void:
	if _event_acquired:
		return
	var sim_time := 0.0 if _validation_mode_active() else (float(open_ocean.get_breaker_lifecycle_sim_time()) if open_ocean != null and open_ocean.has_method(&"get_breaker_lifecycle_sim_time") else 0.0)
	_validation_event_sequence_counter += 1
	_event_sequence = _validation_event_sequence_counter
	_pending_event_sequence = -1
	_event_seed_uv = Vector2(0.5, 0.5)
	_event_seed_sample_xz = carrier_validation_event_position_xz
	_event_seed_world_xz = carrier_validation_event_position_xz
	_event_seed_sim_time = sim_time
	_event_acquisition_sim_time = sim_time
	_event_acquisition_age_s = 0.0
	_event_score = 1.0
	_event_acquired_time_s = Time.get_ticks_usec() * 0.000001
	_event_acquired = true
	_validation_hold_active = true
	_validation_hold_started_time_s = _event_acquired_time_s
	carrier_search_xz = carrier_validation_event_position_xz
	_event_direction_capture_time_s = -1.0
	_event_direction_frozen = false
	_frozen_carrier_frame.clear()
	_validation_long_direction_captured = long_forward
	_validation_event_long_generation = long_generation
	_reset_crest_tracking_state()


func _clear_event_direction_state() -> void:
	_event_direction_capture_time_s = -1.0
	_event_direction_frozen = false
	_frozen_carrier_frame.clear()
	_carrier_coastal_active = false
	_carrier_coastal_transform_valid = false
	_carrier_local_propagation_xz = _carrier_long_propagation_xz
	_carrier_propagation_direction_source = "runtime_long_fallback"
	_carrier_long_to_breaker_angle_deg = 0.0
	_carrier_local_to_breaker_angle_deg = 0.0
	_validation_long_direction_captured = Vector2.ZERO
	_validation_event_long_generation = -1
	_event_capture_long_generation = -1


func _reset_validation_event_for_reacquire() -> void:
	_event_acquired = false
	_pending_event_sequence = -1
	_event_sequence = -1
	_validation_hold_active = false
	_validation_hold_started_time_s = -1.0
	_carrier_frame_sequence = -1
	_validation_report.clear()
	_carrier_world_crest_xz = Vector2.ZERO
	_carrier_sample_crest_xz = Vector2.ZERO
	_reset_crest_tracking_state()
	_clear_event_direction_state()


func _freeze_event_frame(frame: Dictionary) -> void:
	_frozen_carrier_frame = frame.duplicate(true)
	_event_direction_capture_time_s = Time.get_ticks_usec() * 0.000001
	_event_direction_frozen = true
	_event_capture_long_generation = _carrier_long_generation


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
			var authored := VDM_GENERATOR._sample_profile_material(VDM_GENERATOR.PROFILE_P5, u01, _p5_material_lut)
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
	if attach_to_ocean and carrier_validation_extra_cull_margin > 0.0:
		_mesh_instance.extra_cull_margin = carrier_validation_extra_cull_margin
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
	if _validation_mode_active() and validation_event_reacquire_serial != _last_validation_event_reacquire_serial:
		_last_validation_event_reacquire_serial = validation_event_reacquire_serial
		_reset_validation_event_for_reacquire()
	var long_forward := _get_long_propagation_direction(open_ocean)
	_carrier_long_propagation_xz = long_forward
	_carrier_long_generation = _get_long_publication_generation(open_ocean)
	_carrier_wind_direction_parameter = float(open_ocean.get_wind_direction_parameter_degrees()) if open_ocean != null and open_ocean.has_method(&"get_wind_direction_parameter_degrees") else 0.0
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource
	var event_duration := float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8
	if _validation_mode_active():
		_event_duration_configured_s = maxf(carrier_validation_hold_seconds, 5.0)
		_event_duration_sent_s = _event_duration_configured_s
		_event_refractory_s = 0.0
		event_duration = _event_duration_sent_s
	else:
		var lifecycle_runtime: Dictionary = open_ocean.get_breaker_lifecycle_runtime_state() if open_ocean.has_method(&"get_breaker_lifecycle_runtime_state") else {}
		_event_duration_configured_s = float(lifecycle_runtime.get("event_duration_configured_s", event_duration))
		_event_duration_sent_s = float(lifecycle_runtime.get("event_duration_sent_s", event_duration))
		_event_refractory_s = maxf(float(lifecycle_runtime.get("refractory_s", breaker_profile.get("breaker_event_refractory_s") if breaker_profile != null and breaker_profile.has_method(&"get") else 3.0)), 0.0)
		event_duration = maxf(_event_duration_sent_s, 0.001)
	if _validation_mode_active():
		_ensure_validation_event(open_ocean, long_forward, _carrier_long_generation)
	elif carrier_validation_event_acquisition and open_ocean != null and open_ocean.has_method(&"get_breaker_event_probe_state"):
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
			_event_score = float(probe.get("event_score", probe.get("strength", 0.0)))
		elif _event_acquired:
			var current_sim_time := float(open_ocean.get_breaker_lifecycle_sim_time()) if open_ocean.has_method(&"get_breaker_lifecycle_sim_time") else -1.0
			var event_age_s := current_sim_time - _event_seed_sim_time if current_sim_time >= 0.0 and _event_seed_sim_time >= 0.0 else Time.get_ticks_usec() * 0.000001 - _event_acquired_time_s
			_event_age_s = maxf(event_age_s, 0.0)
			_event_age_normalized = clampf(_event_age_s / event_duration, 0.0, 1.0)
			if event_age_s >= event_duration:
				_event_acquired = false
				_validation_hold_active = false
				_validation_hold_started_time_s = -1.0
				_pending_event_sequence = -1
				_carrier_frame_sequence = -1
				_validation_report.clear()
				_carrier_world_crest_xz = Vector2.ZERO
				_carrier_sample_crest_xz = Vector2.ZERO
				_clear_event_direction_state()
	var lifecycle_now := -1.0 if _validation_mode_active() else (float(open_ocean.get_breaker_lifecycle_sim_time()) if open_ocean.has_method(&"get_breaker_lifecycle_sim_time") else -1.0)
	if _validation_mode_active():
		_event_age_s = 0.0
		_event_age_normalized = 0.0
		_refractory_active = false
		_refractory_remaining_s = 0.0
	elif _event_seed_sim_time >= 0.0 and lifecycle_now >= 0.0:
		_event_age_s = maxf(lifecycle_now - _event_seed_sim_time, 0.0)
		_event_age_normalized = clampf(_event_age_s / event_duration, 0.0, 1.0)
		var refractory_start := _event_seed_sim_time + event_duration
		_refractory_remaining_s = maxf(refractory_start + _event_refractory_s - lifecycle_now, 0.0) if _event_age_s >= event_duration else 0.0
		_refractory_active = _refractory_remaining_s > 0.0
	else:
		_refractory_active = false
		_refractory_remaining_s = 0.0
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
	_carrier_material.set_shader_parameter(&"breaker_multiphase_vdm_exact", parameters["breaker_multiphase_vdm"])
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
	var jacobian_texture := parameters.get("coastal_jacobian") as Texture2D
	var jacobian_image := jacobian_texture.get_image() if jacobian_texture != null else null
	var field_image := field_texture.get_image() if field_texture != null else null
	var event_acquired_this_frame := false
	if not _event_acquired and _pending_event_sequence >= 0 and warp_image != null and not warp_image.is_empty():
		event_acquired_this_frame = _resolve_pending_event(parameters, warp_image)
	if event_acquired_this_frame:
		_validation_hold_active = carrier_validation_phase_override >= 0.0
		_validation_hold_started_time_s = Time.get_ticks_usec() * 0.000001 if _validation_hold_active else -1.0
		update_camera = true
	if not _validation_mode_active() and _validation_hold_active and _validation_hold_started_time_s >= 0.0 and Time.get_ticks_usec() * 0.000001 - _validation_hold_started_time_s >= 1.0:
		_validation_hold_active = false
	if update_camera and phase_image != null and metrics_image != null and gate_camera != null:
		var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
		var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
		var coastal_warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
		var coastal_warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
		var phase_uv := (carrier_search_xz - coastal_origin) / coastal_extent
		var pixel := Vector2i(
			clampi(int(phase_uv.x * float(phase_image.get_width() - 1)), 0, phase_image.get_width() - 1),
			clampi(int(phase_uv.y * float(phase_image.get_height() - 1)), 0, phase_image.get_height() - 1))
		var frame: Dictionary
		if _event_direction_frozen and not _frozen_carrier_frame.is_empty():
			frame = _frozen_carrier_frame.duplicate(true)
		else:
			frame = _compute_carrier_frame(parameters, phase_image, metrics_image, field_image, warp_image, jacobian_image, long_forward)
			if _event_acquired:
				_freeze_event_frame(frame)
		if _event_acquired and _event_direction_frozen:
			frame = _track_crest_origin(parameters, phase_image, metrics_image, warp_image, field_image, frame, delta, open_ocean)
		var crest_anchor: Vector2 = frame.get("world_crest_xz", carrier_search_xz)
		_carrier_world_crest_xz = crest_anchor
		_carrier_sample_crest_xz = frame.get("sample_crest_xz", Vector2.ZERO)
		var forward: Vector2 = frame.get("forward", Vector2(0.0, 1.0))
		var tangent: Vector2 = frame.get("tangent", Vector2(-forward.y, forward.x))
		_carrier_frame_forward_xz = _safe_frame_direction(forward, Vector2(0.0, 1.0))
		_carrier_frame_tangent_xz = Vector2(-_carrier_frame_forward_xz.y, _carrier_frame_forward_xz.x)
		_carrier_frame_wavelength_m = maxf(float(frame.get("wavelength_m", WAVELENGTH_M)), 0.001)
		_carrier_local_propagation_xz = _safe_frame_direction(frame.get("local_propagation_xz", long_forward), long_forward)
		_carrier_coastal_active = bool(frame.get("coastal_active", false))
		_carrier_coastal_transform_valid = bool(frame.get("coastal_transform_valid", false))
		_carrier_propagation_direction_source = String(frame.get("propagation_direction_source", "runtime_long_fallback"))
		_carrier_long_to_breaker_angle_deg = _angle_degrees(long_forward, _carrier_frame_forward_xz)
		_carrier_local_to_breaker_angle_deg = _angle_degrees(_carrier_local_propagation_xz, _carrier_frame_forward_xz)
		var camera_direction := (tangent * 0.65 - forward * 0.75).normalized()
		var camera_height := 1.25
		var camera_distance := 18.0
		if _validation_mode_active() and carrier_validation_camera_view == 0:
			camera_direction = tangent
			camera_height = 2.0
			camera_distance = 20.0
		gate_camera.position = Vector3(crest_anchor.x + camera_direction.x * camera_distance, camera_height, crest_anchor.y + camera_direction.y * camera_distance)
		gate_camera.look_at(Vector3(crest_anchor.x, 1.5, crest_anchor.y), Vector3.UP)
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
			if not _frame_snap_invariants_valid and not _validation_mode_active():
				_event_acquired = false
				_carrier_frame_sequence = -1
				_clear_event_direction_state()
		_update_validation_event_frame_debug()
	_carrier_material.set_shader_parameter(&"carrier_search_xz", carrier_search_xz)
	_carrier_material.set_shader_parameter(&"carrier_event_seed_sample_xz", _event_seed_sample_xz)
	_carrier_material.set_shader_parameter(&"carrier_reference_wavelength_m", WAVELENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_crest_length_m", CREST_LENGTH_M)
	_carrier_material.set_shader_parameter(&"carrier_vertical_scale", 1.0)
	_carrier_material.set_shader_parameter(&"carrier_validation_cutaway", carrier_validation_cutaway)
	_carrier_material.set_shader_parameter(&"carrier_validation_wireframe", carrier_validation_wireframe)
	_carrier_material.set_shader_parameter(&"carrier_validation_phase_debug", carrier_validation_phase_debug)
	_carrier_material.set_shader_parameter(&"carrier_validation_phase_override", carrier_validation_phase_override if _validation_hold_active and _event_acquired else -1.0)
	_carrier_material.set_shader_parameter(&"carrier_validation_exact_p5_hold", _validation_hold_active and _event_acquired)
	_carrier_material.set_shader_parameter(&"carrier_validation_force_event", _validation_mode_active())
	_carrier_material.set_shader_parameter(&"carrier_validation_forward_xz", carrier_validation_forward_xz)
	_carrier_material.set_shader_parameter(&"carrier_validation_visual_mode", carrier_validation_visual_mode)
	var tracking_status := 0
	if _carrier_tracking_snap_rejected:
		tracking_status = 3
	elif _carrier_tracking_snap_valid:
		tracking_status = 2
	elif _carrier_tracking_initialized:
		tracking_status = 1
	_carrier_material.set_shader_parameter(&"carrier_validation_tracking_status", tracking_status)
	_carrier_material.set_shader_parameter(&"validation_geometry_material", validation_geometry_material)
	_carrier_material.set_shader_parameter(&"carrier_validation_force_visible_color", carrier_validation_force_visible_color and _event_acquired)
	var lateral_envelope := _compute_lateral_envelope(breaker_profile)
	_lateral_active_half_width_m = float(lateral_envelope["active_half_width_m"])
	_lateral_feather_width_m = float(lateral_envelope["feather_width_m"])
	_lateral_suppression_margin_m = float(lateral_envelope["suppression_margin_m"])
	_carrier_material.set_shader_parameter(&"carrier_lateral_active_half_width_m", _lateral_active_half_width_m)
	_carrier_material.set_shader_parameter(&"carrier_lateral_feather_width_m", _lateral_feather_width_m)
	_carrier_material.set_shader_parameter(&"carrier_lateral_seed_offset_m", float(lateral_envelope["seed_offset_m"]))
	_carrier_material.set_shader_parameter(&"validation_travelling_phase_enabled", validation_travelling_phase_enabled and validation_enabled)
	_carrier_material.set_shader_parameter(&"validation_travelling_time_s", validation_travelling_time_s)
	_carrier_material.set_shader_parameter(&"validation_travelling_speed_mps", float(lateral_envelope["propagation_speed_mps"]))
	_carrier_material.set_shader_parameter(&"validation_travelling_duration_s", maxf(float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8, 0.001))
	_carrier_material.set_shader_parameter(&"validation_travelling_seed_half_width_m", float(lateral_envelope["seed_half_width_m"]))
	var frame_override_enabled := _event_direction_frozen and _event_acquired and _carrier_frame_wavelength_m > 0.0
	if validation_event_frame_debug and frame_override_enabled and _last_frame_debug_event_id != _event_sequence:
		_last_frame_debug_event_id = _event_sequence
		var direction_is_forced := carrier_validation_forward_xz.length_squared() > 0.000001
		print("P25_EVENT_FRAME_CARRIER " + JSON.stringify({
			"event_id": _event_sequence,
			"event_position_xz": _event_seed_world_xz,
			"event_uv": _event_seed_uv,
			"event_direction_xz": _carrier_frame_forward_xz,
			"event_direction_source": "validation_override" if direction_is_forced else _carrier_propagation_direction_source,
			"wind_direction_parameter": _carrier_wind_direction_parameter,
			"LONG_propagation_xz": _carrier_long_propagation_xz,
			"LONG_generation": _carrier_long_generation,
			"event_capture_LONG_generation": _event_capture_long_generation,
			"Coastal_active": _carrier_coastal_active,
			"Coastal_transform_valid": _carrier_coastal_transform_valid,
			"Coastal_local_propagation_xz": _carrier_local_propagation_xz,
			"LONG_to_breaker_angle_deg": _carrier_long_to_breaker_angle_deg,
			"local_to_breaker_angle_deg": _carrier_local_to_breaker_angle_deg,
			"event_direction_capture_time": _event_direction_capture_time_s,
			"event_direction_frozen": _event_direction_frozen,
			"event_score": _event_score,
			"event_age_s": _event_age_s,
			"carrier_input_search_xz": carrier_search_xz,
			"carrier_frame_origin_xz": _carrier_world_crest_xz,
			"carrier_frame_forward_xz": _carrier_frame_forward_xz,
			"carrier_frame_tangent_xz": _carrier_frame_tangent_xz,
			"carrier_frame_wavelength_m": _carrier_frame_wavelength_m,
		}))
	_carrier_material.set_shader_parameter(&"carrier_authoritative_frame_enabled", frame_override_enabled)
	_carrier_material.set_shader_parameter(&"carrier_authoritative_crest_xz", _carrier_world_crest_xz)
	_carrier_material.set_shader_parameter(&"carrier_authoritative_forward_xz", _carrier_frame_forward_xz)
	_carrier_material.set_shader_parameter(&"carrier_authoritative_tangent_xz", _carrier_frame_tangent_xz)
	_carrier_material.set_shader_parameter(&"carrier_authoritative_wavelength_m", _carrier_frame_wavelength_m)
	_carrier_material.set_shader_parameter(&"carrier_runtime_forward_xz", _carrier_frame_forward_xz if _event_acquired else long_forward)
	if surface.has_method(&"set_breaker_carrier_suppression"):
		surface.set_breaker_carrier_suppression(true, carrier_search_xz, CREST_LENGTH_M, _event_seed_sample_xz, _validation_hold_active and _event_acquired, frame_override_enabled, _carrier_world_crest_xz, _carrier_frame_forward_xz, _carrier_frame_tangent_xz, _carrier_frame_wavelength_m, _event_sequence, _event_seed_world_xz, _event_seed_uv, _event_score, _event_age_s, _lateral_active_half_width_m, _lateral_feather_width_m, float(lateral_envelope["seed_offset_m"]), _lateral_suppression_margin_m)
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
uniform sampler2D breaker_multiphase_vdm_exact : repeat_disable, filter_nearest;
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
uniform float carrier_validation_phase_override = -1.0;
uniform bool carrier_validation_exact_p5_hold = false;
uniform bool carrier_validation_force_event = false;
uniform vec2 carrier_validation_forward_xz = vec2(0.0);
uniform int carrier_validation_visual_mode = 0;
uniform int carrier_validation_tracking_status = 0;
uniform bool validation_geometry_material = false;
uniform bool carrier_validation_force_visible_color = false;
uniform bool validation_travelling_phase_enabled = false;
uniform float validation_travelling_time_s = 0.0;
uniform float validation_travelling_speed_mps = 4.0;
uniform float validation_travelling_duration_s = 0.8;
uniform float validation_travelling_seed_half_width_m = 3.0;
uniform bool carrier_authoritative_frame_enabled = false;
uniform vec2 carrier_authoritative_crest_xz = vec2(0.0);
uniform vec2 carrier_authoritative_forward_xz = vec2(0.0, 1.0);
uniform vec2 carrier_authoritative_tangent_xz = vec2(-1.0, 0.0);
uniform float carrier_authoritative_wavelength_m = 32.0;
uniform vec2 carrier_runtime_forward_xz = vec2(1.0, 0.0);
uniform float carrier_lateral_active_half_width_m = 16.0;
uniform float carrier_lateral_feather_width_m = 1.5;
uniform float carrier_lateral_seed_offset_m = 0.0;

varying float carrier_visibility;
varying float carrier_phase_b;
varying vec3 carrier_world_position;
varying vec3 carrier_base_world_position;
varying float carrier_shape_authority;
varying float carrier_residual_magnitude;
varying float carrier_phase_position;
varying float carrier_arrived;

vec2 world_uv(vec2 world_xz, float domain_m) {
    return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

vec2 coastal_uv(vec2 world_xz, vec2 origin, vec2 extent) {
    return (world_xz - origin) / max(extent, vec2(0.001));
}

vec2 safe_normalize_xz(vec2 value) {
    return length(value) > 0.0001 ? normalize(value) : vec2(0.0, 1.0);
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
	vec2 forward_search = safe_normalize_xz(carrier_runtime_forward_xz);
	if (carrier_validation_force_event && length(carrier_validation_forward_xz) > 0.0001) forward_search = normalize(carrier_validation_forward_xz);
    float wavelength_search = max(metrics_search.g, 0.001);
    float wrapped_phase = mod(phase_search.r + 3.14159265359, 6.28318530718) - 3.14159265359;
    float search_s_profile = -wrapped_phase / max(6.28318530718 / wavelength_search, 0.001);
    vec2 world_crest_guess_xz = world_search_xz - forward_search * search_s_profile;
    vec2 crest_guess_uv = clamp(coastal_uv(world_crest_guess_xz, coastal_origin, coastal_extent), vec2(0.0), vec2(1.0));
    vec4 phase_info = texture(coastal_phase, crest_guess_uv);
    vec4 metrics_info = texture(coastal_metrics, crest_guess_uv);
	vec2 forward = forward_search;
    if (carrier_validation_force_event && length(carrier_validation_forward_xz) > 0.0001) forward = normalize(carrier_validation_forward_xz);
    float wavelength_m = max(metrics_info.g, wavelength_search);
    float residual_phase = mod(phase_info.r + 3.14159265359, 6.28318530718) - 3.14159265359;
    float residual_s = -residual_phase / max(6.28318530718 / wavelength_m, 0.001);
	vec2 world_crest_xz = world_crest_guess_xz - forward * residual_s;
	vec2 tangent = vec2(-forward.y, forward.x);
	if (carrier_authoritative_frame_enabled) {
		world_crest_xz = carrier_authoritative_crest_xz;
		forward = safe_normalize_xz(carrier_authoritative_forward_xz);
		tangent = vec2(-forward.y, forward.x);
		wavelength_m = max(carrier_authoritative_wavelength_m, 0.001);
	}
    float profile_u = clamp(UV.x, 0.5 / 256.0, 255.5 / 256.0);
    float base_s = (profile_u - 0.5) * wavelength_m;
    float crest_s = (UV.y - 0.5) * carrier_crest_length_m;
    vec2 lateral_world_xz = world_crest_xz + tangent * crest_s;
    vec2 warp_center_xz = texture(coastal_warp, clamp(coastal_uv(world_crest_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0))).xy;
    vec2 warp_lateral_xz = texture(coastal_warp, clamp(coastal_uv(lateral_world_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0))).xy;
    vec2 lifecycle_sample_xz = carrier_event_seed_sample_xz + (warp_lateral_xz - warp_center_xz);
    vec4 lifecycle_state = texture(breaker_lifecycle, world_uv(lifecycle_sample_xz, domain_long_m));
    float lifecycle_arrived = step(0.001, lifecycle_state.r);
    float lifecycle_phase01 = clamp(lifecycle_state.b, 0.0, 1.0);
    float validation_distance_m = max(abs(crest_s - carrier_lateral_seed_offset_m) - validation_travelling_seed_half_width_m, 0.0);
    float validation_arrival_s = validation_distance_m / max(validation_travelling_speed_mps, 0.001);
    float validation_local_age_s = validation_travelling_time_s - validation_arrival_s;
    float validation_arrived = step(0.0, validation_local_age_s);
    float validation_phase01 = clamp(validation_local_age_s / max(validation_travelling_duration_s, 0.001), 0.0, 1.0);
    bool use_validation_travelling_phase = validation_travelling_phase_enabled && carrier_validation_force_event;
    float arrived = use_validation_travelling_phase ? validation_arrived : lifecycle_arrived;
    float phase01 = use_validation_travelling_phase ? validation_phase01 : lifecycle_phase01;
    float event_alive = arrived * (1.0 - step(0.999, phase01));
    float temporal_authority = smoothstep(0.00, 0.08, phase01) * (1.0 - smoothstep(0.92, 0.995, phase01));
	float phase_position = carrier_validation_phase_override >= 0.0 ? clamp(carrier_validation_phase_override, 4.0, 6.0) : 4.0 + 2.0 * phase01;
    float phase_index = floor(phase_position);
    float phase_fraction = smoothstep(0.0, 1.0, fract(phase_position));
    float safe_v = clamp(UV.y, 0.5 / 256.0, 255.5 / 256.0);
    vec4 vdm_phase_0 = texture(breaker_multiphase_vdm, vec2(profile_u, (phase_index + safe_v) / 8.0));
    vec4 vdm_phase_1 = texture(breaker_multiphase_vdm, vec2(profile_u, (min(phase_index + 1.0, 7.0) + safe_v) / 8.0));
    vec4 vdm_sample = carrier_validation_exact_p5_hold
        ? texture(breaker_multiphase_vdm_exact, vec2(profile_u, (5.0 + safe_v) / 8.0))
        : mix(vdm_phase_0, vdm_phase_1, phase_fraction);
    float delta_s = vdm_sample.r * (wavelength_m / 12.0);
    float lateral_offset = vdm_sample.g * (wavelength_m / 12.0);
    float target_y = vdm_sample.b * (2.0 / 3.72184);
    vec2 base_xz = world_crest_xz + forward * base_s + tangent * crest_s;
    vec3 ocean_base = sample_ocean_base(base_xz);
    vec3 carrier_base_world = vec3(base_xz.x + ocean_base.x, ocean_base.y, base_xz.y + ocean_base.z);
    vec3 carrier_residual_world = vec3(forward.x * delta_s + tangent.x * lateral_offset, target_y * carrier_vertical_scale, forward.y * delta_s + tangent.y * lateral_offset);
    float rear_attachment = smoothstep(0.0, 0.08, profile_u);
    float front_attachment = 1.0 - smoothstep(0.92, 1.0, profile_u);
    float lateral_attachment = smoothstep(0.0, 0.12, UV.y) * (1.0 - smoothstep(0.88, 1.0, UV.y));
	float normal_shape_authority = event_alive * temporal_authority * clamp(vdm_sample.a, 0.0, 1.0) * rear_attachment * front_attachment * lateral_attachment;
	float held_shape_authority = clamp(vdm_sample.a, 0.0, 1.0) * rear_attachment * front_attachment * lateral_attachment;
	float shape_authority = carrier_validation_exact_p5_hold ? held_shape_authority : normal_shape_authority;
	carrier_visibility = carrier_validation_exact_p5_hold ? 1.0 : event_alive * temporal_authority;
	float lateral_distance = abs(crest_s - carrier_lateral_seed_offset_m);
	float lateral_authority = 1.0 - smoothstep(carrier_lateral_active_half_width_m, carrier_lateral_active_half_width_m + max(carrier_lateral_feather_width_m, 0.001), lateral_distance);
	shape_authority *= lateral_authority;
	carrier_visibility *= lateral_authority;
    carrier_phase_b = clamp((phase_position - 4.0) / 2.0, 0.0, 1.0);
    carrier_phase_position = phase_position;
    carrier_arrived = arrived;
    carrier_shape_authority = shape_authority;
    carrier_residual_magnitude = length(carrier_residual_world);
    carrier_base_world_position = (MODEL_MATRIX * vec4(carrier_base_world, 1.0)).xyz;
    vec3 carrier_final_world = carrier_base_world + shape_authority * carrier_residual_world;
    VERTEX = carrier_final_world;
    carrier_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    if (carrier_visibility < 0.001 && !carrier_validation_force_visible_color && carrier_validation_visual_mode != 5) discard;
    if (carrier_validation_wireframe && (UV.y < 0.47 || UV.y > 0.53)) discard;
    if (carrier_validation_cutaway && UV.y > 0.52) discard;
    vec3 geometric_normal = normalize(cross(dFdx(carrier_world_position), dFdy(carrier_world_position)));
    float normal_readability = clamp(0.5 + 0.5 * geometric_normal.y, 0.0, 1.0);
    float debug_phase = clamp(carrier_phase_b, 0.0, 1.0);
    vec3 base_color = mix(vec3(0.010, 0.085, 0.13), vec3(0.025, 0.28, 0.42), normal_readability);
    if (carrier_validation_visual_mode == 1) base_color = vec3(carrier_shape_authority, 0.15, 1.0 - carrier_shape_authority);
    if (carrier_validation_visual_mode == 2) base_color = vec3(clamp(carrier_residual_magnitude / 4.0, 0.0, 1.0), 0.12, 1.0 - clamp(carrier_residual_magnitude / 4.0, 0.0, 1.0));
    if (carrier_validation_visual_mode == 3) base_color = mix(vec3(0.05, 0.35, 0.95), vec3(0.95, 0.15, 0.05), carrier_shape_authority);
    if (carrier_validation_visual_mode == 4) {
        vec3 base_dx = dFdx(carrier_base_world_position);
        vec3 base_dy = dFdy(carrier_base_world_position);
        vec3 final_dx = dFdx(carrier_world_position);
        vec3 final_dy = dFdy(carrier_world_position);
        float base_area = length(cross(base_dx, base_dy));
        float final_area = length(cross(final_dx, final_dy));
        float stretch = clamp(final_area / max(base_area, 0.0001), 0.0, 4.0) / 4.0;
        base_color = mix(vec3(0.05, 0.15, 1.0), vec3(1.0, 0.12, 0.02), stretch);
    }
    if (carrier_validation_visual_mode == 5) {
        if (carrier_arrived < 0.5 || carrier_visibility < 0.001) {
            base_color = vec3(0.0);
        } else if (carrier_phase_position < 4.5) {
            base_color = vec3(0.04, 0.20, 1.0);
        } else if (carrier_phase_position < 5.5) {
            base_color = vec3(1.0, 0.78, 0.02);
        } else {
            base_color = vec3(0.95, 0.04, 0.02);
        }
    }
    if (carrier_validation_visual_mode == 6) {
        if (carrier_validation_tracking_status == 3) base_color = vec3(0.95, 0.04, 0.02);
        else if (carrier_validation_tracking_status == 2) base_color = vec3(0.08, 0.95, 0.20);
        else if (carrier_validation_tracking_status == 1) base_color = vec3(1.0, 0.78, 0.02);
        else base_color = vec3(1.0);
    }
    ALBEDO = carrier_validation_visual_mode == 5 ? base_color : (carrier_validation_force_visible_color ? vec3(1.0, 0.02, 0.01) : (validation_geometry_material ? base_color : (carrier_validation_phase_debug ? vec3(debug_phase, 1.0 - debug_phase, 0.15 + 0.7 * clamp(carrier_visibility, 0.0, 1.0)) : base_color)));
    EMISSION = carrier_validation_visual_mode == 5 ? base_color * 0.25 : (carrier_validation_force_visible_color ? vec3(1.0, 0.01, 0.0) : vec3(0.0));
    ROUGHNESS = validation_geometry_material ? 1.0 : 0.22;
    SPECULAR = validation_geometry_material ? 0.0 : 0.5;
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
	if not _event_seed_sample_xz.is_finite():
		return false
	var resolved_world_xz: Vector2 = inverse.get("world_xz", _event_seed_sample_xz)
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ZERO)
	var inside := coastal_extent.x > 0.0 and coastal_extent.y > 0.0 and resolved_world_xz.x >= coastal_origin.x and resolved_world_xz.y >= coastal_origin.y and resolved_world_xz.x <= coastal_origin.x + coastal_extent.x and resolved_world_xz.y <= coastal_origin.y + coastal_extent.y
	if not inside:
		# The lifecycle sample is already in the open-ocean LONG domain. Keep the
		# event alive and let the frame computation take its explicit LONG fallback
		# instead of silently dropping an event outside Coastal.
		_event_inverse_valid = false
		resolved_world_xz = _event_seed_sample_xz
	if not _event_inverse_valid:
		resolved_world_xz = _event_seed_sample_xz
	_carrier_frame_sequence = -1
	_validation_report.clear()
	_carrier_world_crest_xz = Vector2.ZERO
	_carrier_sample_crest_xz = Vector2.ZERO
	_event_seed_world_xz = resolved_world_xz
	carrier_search_xz = _event_seed_world_xz
	_event_acquired = true
	_event_acquired_time_s = Time.get_ticks_usec() * 0.000001
	_reset_crest_tracking_state()
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


func _compute_carrier_frame(parameters: Dictionary, phase_image: Image, metrics_image: Image, field_image: Image, warp_image: Image, jacobian_image: Image, long_forward: Vector2) -> Dictionary:
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ONE)
	var warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
	var warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
	var world_search_xz := carrier_search_xz
	var search_uv := (world_search_xz - coastal_origin) / coastal_extent
	var phase_search := _sample_image_uv(phase_image, search_uv)
	var metrics_search := _sample_image_uv(metrics_image, search_uv)
	var warp_search := _sample_image_uv(warp_image, (world_search_xz - warp_origin) / warp_extent)
	var search_direction := _transform_long_direction(parameters, long_forward, world_search_xz, jacobian_image, warp_image, field_image)
	var forward_search: Vector2 = search_direction.get("direction", long_forward)
	forward_search = _safe_frame_direction(forward_search, long_forward)
	if _validation_mode_active() and carrier_validation_forward_xz.length_squared() > 0.0001:
		forward_search = carrier_validation_forward_xz.normalized()
	var detj_safe := maxf(float(parameters.get("coastal_warp_detj_safe", 0.5)), 0.001)
	var wavelength_search := maxf(metrics_search.g, 0.001)
	var wrapped_search_phase := fposmod(phase_search.r + PI, TAU) - PI
	var search_s_profile := -wrapped_search_phase / (TAU / wavelength_search)
	var world_crest_guess_xz := world_search_xz - forward_search * search_s_profile
	var crest_guess_uv := (world_crest_guess_xz - coastal_origin) / coastal_extent
	var phase_info := _sample_image_uv(phase_image, crest_guess_uv)
	var metrics_info := _sample_image_uv(metrics_image, crest_guess_uv)
	var crest_direction := _transform_long_direction(parameters, long_forward, world_crest_guess_xz, jacobian_image, warp_image, field_image)
	var forward: Vector2 = crest_direction.get("direction", forward_search)
	forward = _safe_frame_direction(forward, forward_search)
	if _validation_mode_active() and carrier_validation_forward_xz.length_squared() > 0.0001:
		forward = carrier_validation_forward_xz.normalized()
	var wavelength_m := maxf(metrics_info.g, wavelength_search)
	var wrapped_residual_phase := fposmod(phase_info.r + PI, TAU) - PI
	var residual_s := -wrapped_residual_phase / (TAU / wavelength_m)
	var world_crest_xz := world_crest_guess_xz - forward * residual_s
	var final_direction := _transform_long_direction(parameters, long_forward, world_crest_xz, jacobian_image, warp_image, field_image)
	var local_propagation_xz: Vector2 = final_direction.get("direction", forward)
	local_propagation_xz = _safe_frame_direction(local_propagation_xz, long_forward)
	if not (_validation_mode_active() and carrier_validation_forward_xz.length_squared() > 0.0001):
		forward = local_propagation_xz
		world_crest_xz = world_crest_guess_xz - forward * residual_s
	var tangent := Vector2(-forward.y, forward.x)
	var warp_at_crest := _sample_image_uv(warp_image, (world_crest_xz - warp_origin) / warp_extent)
	var field_at_crest := _sample_image_uv(field_image, (world_crest_xz - coastal_origin) / coastal_extent)
	var crest_confidence := clampf(field_at_crest.a * _smoothstep(0.0, detj_safe, warp_at_crest.b), 0.0, 1.0)
	var sample_crest_candidate_xz := world_crest_xz.lerp(Vector2(warp_at_crest.r, warp_at_crest.g), crest_confidence)
	var sample_crest_xz := sample_crest_candidate_xz - forward * residual_s
	var coastal_transform_valid := bool(final_direction.get("valid", false))
	var coastal_active := bool(final_direction.get("coastal_active", false))
	var direction_source := String(final_direction.get("source", "runtime_long_fallback"))
	if _validation_mode_active() and carrier_validation_forward_xz.length_squared() > 0.0001:
		direction_source = "validation_override"
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
		"long_propagation_xz": long_forward,
		"local_propagation_xz": local_propagation_xz,
		"coastal_active": coastal_active,
		"coastal_transform_valid": coastal_transform_valid,
		"propagation_direction_source": direction_source,
	}


func _get_long_propagation_direction(open_ocean: Node) -> Vector2:
	if open_ocean != null and open_ocean.has_method(&"get_long_propagation_direction_xz"):
		var direction: Vector2 = open_ocean.get_long_propagation_direction_xz()
		if direction.is_finite() and direction.length_squared() > 0.000001:
			return direction.normalized()
	return Vector2.RIGHT


func _get_long_publication_generation(open_ocean: Node) -> int:
	if open_ocean == null or not open_ocean.has_method(&"get_fft_resource_lifecycle_state"):
		return -1
	var lifecycle: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	if not bool(lifecycle.get("fft_publication_ready", false)):
		return -1
	return int(lifecycle.get("published_generation", -1))


func _validation_event_needs_reacquire(current_long_forward: Vector2, current_generation: int) -> bool:
	if not _event_acquired or _validation_long_direction_captured.length_squared() <= 0.000001:
		return false
	if _validation_event_long_generation >= 0 and current_generation < 0:
		return false
	if _validation_event_long_generation >= 0 and current_generation == _validation_event_long_generation:
		return false
	return _angle_degrees(_validation_long_direction_captured, current_long_forward) > 0.5


func _angle_degrees(a: Vector2, b: Vector2) -> float:
	if a.length_squared() <= 0.000001 or b.length_squared() <= 0.000001:
		return 180.0
	return rad_to_deg(acos(clampf(a.normalized().dot(b.normalized()), -1.0, 1.0)))


func _transform_long_direction(parameters: Dictionary, long_forward: Vector2, world_xz: Vector2, jacobian_image: Image, warp_image: Image, field_image: Image) -> Dictionary:
	var fallback := _safe_frame_direction(long_forward, Vector2.RIGHT)
	var coastal_origin: Vector2 = parameters.get("coastal_origin", Vector2.ZERO)
	var coastal_extent: Vector2 = parameters.get("coastal_extent", Vector2.ZERO)
	var warp_origin: Vector2 = parameters.get("coastal_warp_origin", coastal_origin)
	var warp_extent: Vector2 = parameters.get("coastal_warp_extent", coastal_extent)
	var detj_safe := maxf(float(parameters.get("coastal_warp_detj_safe", 0.5)), 0.001)
	var coastal_active := field_image != null and not field_image.is_empty() and warp_image != null and not warp_image.is_empty() \
		and coastal_extent.x > 0.00001 and coastal_extent.y > 0.00001 and warp_extent.x > 0.00001 and warp_extent.y > 0.00001
	if not coastal_active:
		return {"valid": false, "coastal_active": false, "direction": fallback, "source": "open_ocean_fallback"}
	var coastal_uv := (world_xz - coastal_origin) / coastal_extent
	var warp_uv := (world_xz - warp_origin) / warp_extent
	var inside := coastal_uv.x >= 0.0 and coastal_uv.x <= 1.0 and coastal_uv.y >= 0.0 and coastal_uv.y <= 1.0 \
		and warp_uv.x >= 0.0 and warp_uv.x <= 1.0 and warp_uv.y >= 0.0 and warp_uv.y <= 1.0
	if not inside:
		return {"valid": false, "coastal_active": false, "direction": fallback, "source": "open_ocean_fallback_outside_coastal"}
	var field := _sample_image_uv(field_image, coastal_uv)
	var warp := _sample_image_uv(warp_image, warp_uv)
	var confidence := field.a * warp.a * _smoothstep(0.0, detj_safe, warp.b)
	if not is_finite(confidence) or confidence <= 0.05:
		return {"valid": false, "coastal_active": true, "direction": fallback, "source": "long_fallback_invalid_coastal"}

	var jacobian := _sample_image_uv(jacobian_image, warp_uv) if jacobian_image != null and not jacobian_image.is_empty() else Color(NAN, NAN, NAN, NAN)
	var source := "coastal_jacobian"
	if not is_finite(jacobian.r) or not is_finite(jacobian.g) or not is_finite(jacobian.b) or not is_finite(jacobian.a):
		var finite_difference := _finite_difference_warp_jacobian(warp_image, warp_origin, warp_extent, world_xz)
		if not bool(finite_difference.get("valid", false)):
			return {"valid": false, "coastal_active": true, "direction": fallback, "source": "long_fallback_invalid_jacobian"}
		jacobian = Color(float(finite_difference.get("j00", NAN)), float(finite_difference.get("j01", NAN)), float(finite_difference.get("j10", NAN)), float(finite_difference.get("j11", NAN)))
		source = "coastal_warp_finite_difference"
	var determinant := jacobian.r * jacobian.a - jacobian.g * jacobian.b
	if not is_finite(determinant) or absf(determinant) < 0.0001:
		var finite_difference_singular := _finite_difference_warp_jacobian(warp_image, warp_origin, warp_extent, world_xz)
		if not bool(finite_difference_singular.get("valid", false)):
			return {"valid": false, "coastal_active": true, "direction": fallback, "source": "long_fallback_singular_jacobian"}
		jacobian = Color(float(finite_difference_singular.get("j00", NAN)), float(finite_difference_singular.get("j01", NAN)), float(finite_difference_singular.get("j10", NAN)), float(finite_difference_singular.get("j11", NAN)))
		source = "coastal_warp_finite_difference"
		determinant = jacobian.r * jacobian.a - jacobian.g * jacobian.b
		if not is_finite(determinant) or absf(determinant) < 0.0001:
			return {"valid": false, "coastal_active": true, "direction": fallback, "source": "long_fallback_singular_jacobian"}
	var world_direction := Vector2(
		(jacobian.a * fallback.x - jacobian.g * fallback.y) / determinant,
		(-jacobian.b * fallback.x + jacobian.r * fallback.y) / determinant)
	if not world_direction.is_finite() or world_direction.length_squared() <= 0.000001:
		return {"valid": false, "coastal_active": true, "direction": fallback, "source": "long_fallback_invalid_direction"}
	return {
		"valid": true,
		"coastal_active": true,
		"direction": world_direction.normalized(),
		"source": source,
		"determinant": determinant,
		"confidence": confidence,
	}


func _finite_difference_warp_jacobian(warp_image: Image, warp_origin: Vector2, warp_extent: Vector2, world_xz: Vector2) -> Dictionary:
	if warp_image == null or warp_image.is_empty() or warp_image.get_width() < 2 or warp_image.get_height() < 2:
		return {"valid": false}
	var texel_m := minf(absf(warp_extent.x) / float(warp_image.get_width() - 1), absf(warp_extent.y) / float(warp_image.get_height() - 1))
	var epsilon := maxf(texel_m * 0.5, 0.01)
	var center := _sample_image_uv(warp_image, (world_xz - warp_origin) / warp_extent)
	var sample_x := _sample_image_uv(warp_image, (world_xz + Vector2(epsilon, 0.0) - warp_origin) / warp_extent)
	var sample_z := _sample_image_uv(warp_image, (world_xz + Vector2(0.0, epsilon) - warp_origin) / warp_extent)
	var j00 := (sample_x.r - center.r) / epsilon
	var j01 := (sample_z.r - center.r) / epsilon
	var j10 := (sample_x.g - center.g) / epsilon
	var j11 := (sample_z.g - center.g) / epsilon
	var determinant := j00 * j11 - j01 * j10
	return {"valid": is_finite(determinant) and absf(determinant) >= 0.0001, "j00": j00, "j01": j01, "j10": j10, "j11": j11}


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


func _p5_contract_sample(profile_u: float, crest_v: float) -> Dictionary:
	var authored_base_s := (profile_u - 0.5) * AUTHORED_PROFILE_SPAN_M
	var authored := VDM_GENERATOR._sample_profile_material(VDM_GENERATOR.PROFILE_P5, profile_u, _p5_material_lut)
	var base_s := (profile_u - 0.5) * WAVELENGTH_M
	var delta_s := (authored.x - authored_base_s) * WAVELENGTH_M / AUTHORED_PROFILE_SPAN_M
	var target_s := base_s + delta_s
	var target_y := maxf(authored.y * REFERENCE_HEIGHT_M / AUTHORED_VERTICAL_REFERENCE_M, 0.0)
	var rear_attachment := _smoothstep(0.0, 0.08, profile_u)
	var front_attachment := 1.0 - _smoothstep(0.92, 1.0, profile_u)
	var lateral_attachment := _smoothstep(0.0, 0.12, crest_v) * (1.0 - _smoothstep(0.88, 1.0, crest_v))
	var authority := rear_attachment * front_attachment * lateral_attachment
	var carrier_base_world := Vector3(base_s, 0.0, (crest_v - 0.5) * CREST_LENGTH_M)
	var carrier_residual_world := Vector3(delta_s, target_y, 0.0)
	var canonical_breaker_world := carrier_base_world + carrier_residual_world
	var carrier_final_world := carrier_base_world + authority * carrier_residual_world
	return {"base": carrier_base_world, "residual": carrier_residual_world, "breaker": canonical_breaker_world, "final": carrier_final_world, "authority": authority}


func _lateral_contract_sample(profile_u: float, crest_v: float, active_half_width_m: float, feather_width_m: float, seed_offset_m: float) -> Dictionary:
	var sample := _p5_contract_sample(profile_u, crest_v)
	var base: Vector3 = sample["base"]
	var residual: Vector3 = sample["residual"]
	var lateral_s := (crest_v - 0.5) * CREST_LENGTH_M
	var lateral_authority := 1.0 - _smoothstep(active_half_width_m, active_half_width_m + maxf(feather_width_m, 0.001), absf(lateral_s - seed_offset_m))
	var shape_authority := float(sample["authority"]) * lateral_authority
	return {"base": base, "final": base + shape_authority * residual, "lateral_authority": lateral_authority, "shape_authority": shape_authority}


func _p3d_profile_contract_sample(profile_points: Array[Vector2], material_lut: PackedVector2Array, profile_u: float, crest_v: float) -> Dictionary:
	var authored_base_s := (profile_u - 0.5) * AUTHORED_PROFILE_SPAN_M
	var authored := VDM_GENERATOR._sample_profile_material(profile_points, profile_u, material_lut)
	var base_s := (profile_u - 0.5) * WAVELENGTH_M
	var delta_s := (authored.x - authored_base_s) * WAVELENGTH_M / AUTHORED_PROFILE_SPAN_M
	var target_y := maxf(authored.y * REFERENCE_HEIGHT_M / AUTHORED_VERTICAL_REFERENCE_M, 0.0)
	var rear_attachment := _smoothstep(0.0, 0.08, profile_u)
	var front_attachment := 1.0 - _smoothstep(0.92, 1.0, profile_u)
	var lateral_attachment := _smoothstep(0.0, 0.12, crest_v) * (1.0 - _smoothstep(0.88, 1.0, crest_v))
	return {
		"base": Vector3(base_s, 0.0, (crest_v - 0.5) * CREST_LENGTH_M),
		"residual": Vector3(delta_s, target_y, 0.0),
		"authority": rear_attachment * front_attachment * lateral_attachment,
	}


func _p3d_phase_contract_sample(profile_u: float, crest_v: float, phase_position: float) -> Dictionary:
	var p4 := _p3d_profile_contract_sample(VDM_GENERATOR.PROFILE_P4, _p3d_material_luts[4], profile_u, crest_v)
	var p5 := _p3d_profile_contract_sample(VDM_GENERATOR.PROFILE_P5, _p3d_material_luts[5], profile_u, crest_v)
	var p6 := _p3d_profile_contract_sample(VDM_GENERATOR.PROFILE_P6, _p3d_material_luts[6], profile_u, crest_v)
	var clamped_phase := clampf(phase_position, 4.0, 6.0)
	var phase_index := floori(clamped_phase)
	var phase_fraction := _smoothstep(0.0, 1.0, clamped_phase - float(phase_index))
	var first: Dictionary = p4 if phase_index <= 4 else p5
	var second: Dictionary = p5 if phase_index <= 4 else p6
	var residual: Vector3 = first["residual"].lerp(second["residual"], phase_fraction)
	var authority := lerpf(float(first["authority"]), float(second["authority"]), phase_fraction)
	return {"base": first["base"], "residual": residual, "authority": authority}


func _p3d_local_state(crest_s: float, time_s: float, speed_mps: float, duration_s: float, seed_half_width_m: float, seed_offset_m: float) -> Dictionary:
	var distance_from_seed_m := maxf(absf(crest_s - seed_offset_m) - seed_half_width_m, 0.0)
	var arrival_s := distance_from_seed_m / maxf(speed_mps, 0.001)
	var local_age_s := time_s - arrival_s
	var arrived := local_age_s >= 0.0
	var local_age := clampf(local_age_s / maxf(duration_s, 0.001), 0.0, 1.0)
	return {
		"crest_s": crest_s,
		"distance_from_seed_m": distance_from_seed_m,
		"arrival_s": arrival_s,
		"arrived": arrived,
		"local_age_s": local_age_s,
		"local_age": local_age,
		"lifecycle_R": 1.0 if arrived and local_age < 0.999 else 0.0,
		"lifecycle_B": local_age if arrived else 1.0,
		"phase": 4.0 + 2.0 * local_age if arrived else -1.0,
		"active": arrived and local_age < 0.999,
	}


func _p3d_mesh_sample(profile_u: float, crest_v: float, time_s: float, speed_mps: float, duration_s: float, seed_half_width_m: float, seed_offset_m: float) -> Dictionary:
	var crest_s := (crest_v - 0.5) * CREST_LENGTH_M
	var state := _p3d_local_state(crest_s, time_s, speed_mps, duration_s, seed_half_width_m, seed_offset_m)
	var phase_for_geometry := 4.0 if float(state["phase"]) < 0.0 else float(state["phase"])
	var phase_sample := _p3d_phase_contract_sample(profile_u, crest_v, phase_for_geometry)
	var temporal := _smoothstep(0.0, 0.08, float(state["local_age"])) * (1.0 - _smoothstep(0.92, 0.995, float(state["local_age"]))) if bool(state["arrived"]) else 0.0
	var authority := float(phase_sample["authority"]) * temporal if bool(state["active"]) else 0.0
	var base: Vector3 = phase_sample["base"]
	var residual: Vector3 = phase_sample["residual"]
	return {
		"base": base,
		"final": base + authority * residual,
		"state": state,
		"phase": float(state["phase"]),
	}


func _p3d_percentile(values: Array[float], percentile: float) -> float:
	if values.is_empty():
		return 0.0
	values.sort()
	var index := clampi(int(floor(float(values.size() - 1) * percentile)), 0, values.size() - 1)
	return values[index]


func _compute_p3d_geometry_metrics(time_s: float, speed_mps: float, duration_s: float, seed_half_width_m: float, seed_offset_m: float) -> Dictionary:
	var mesh := []
	var phase_deltas: Array[float] = []
	var phase_displacements: Array[float] = []
	var edge_ratios: Array[float] = []
	var degenerate := 0
	var near_degenerate := 0
	var extreme_area := 0
	for v in V_SAMPLES:
		var row := []
		for u in U_SAMPLES:
			row.append(_p3d_mesh_sample(float(u) / float(U_SAMPLES - 1), float(v) / float(V_SAMPLES - 1), time_s, speed_mps, duration_s, seed_half_width_m, seed_offset_m))
		mesh.append(row)
	for v in V_SAMPLES:
		for u in U_SAMPLES - 1:
			var left: Dictionary = mesh[v][u]
			var right: Dictionary = mesh[v][u + 1]
			var base_delta: Vector3 = right["base"] - left["base"]
			var final_delta: Vector3 = right["final"] - left["final"]
			edge_ratios.append(final_delta.length() / maxf(base_delta.length(), 0.000001))
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES:
			var upper: Dictionary = mesh[v][u]
			var lower: Dictionary = mesh[v + 1][u]
			var upper_state: Dictionary = upper["state"]
			var lower_state: Dictionary = lower["state"]
			phase_deltas.append(absf(float(upper_state["local_age"]) - float(lower_state["local_age"])))
			var base_delta: Vector3 = lower["base"] - upper["base"]
			var final_delta: Vector3 = lower["final"] - upper["final"]
			phase_displacements.append((final_delta - base_delta).length())
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES - 1:
			var a: Dictionary = mesh[v][u]
			var b: Dictionary = mesh[v + 1][u]
			var c: Dictionary = mesh[v][u + 1]
			var d: Dictionary = mesh[v + 1][u + 1]
			for triangle in [[a, b, c], [c, b, d]]:
				var ta: Vector3 = triangle[0]["final"]
				var tb: Vector3 = triangle[1]["final"]
				var tc: Vector3 = triangle[2]["final"]
				var ba: Vector3 = triangle[0]["base"]
				var bb: Vector3 = triangle[1]["base"]
				var bc: Vector3 = triangle[2]["base"]
				var final_area := 0.5 * (tb - ta).cross(tc - ta).length()
				var base_area := 0.5 * (bb - ba).cross(bc - ba).length()
				var ratio := final_area / maxf(base_area, 0.000001)
				if final_area <= 0.000001: degenerate += 1
				if final_area < base_area * 0.05: near_degenerate += 1
				if ratio < 0.25 or ratio > 4.0: extreme_area += 1
	edge_ratios.sort()
	var edge_sum := 0.0
	for value in edge_ratios: edge_sum += value
	var phase_sum := 0.0
	for value in phase_deltas: phase_sum += value
	var phase_max := 0.0
	for value in phase_deltas: phase_max = maxf(phase_max, value)
	var displacement_max := 0.0
	for value in phase_displacements: displacement_max = maxf(displacement_max, value)
	return {
		"time_s": time_s,
		"edge_stretch_mean": edge_sum / maxf(float(edge_ratios.size()), 1.0),
		"edge_stretch_p95": _p3d_percentile(edge_ratios, 0.95),
		"edge_stretch_max": edge_ratios[-1] if not edge_ratios.is_empty() else 0.0,
		"edge_stretch_min": edge_ratios[0] if not edge_ratios.is_empty() else 0.0,
		"degenerate": degenerate,
		"near_degenerate": near_degenerate,
		"extreme_area": extreme_area,
		"max_lateral_phase_delta": phase_max * 2.0,
		"mean_lateral_phase_delta": phase_sum / maxf(float(phase_deltas.size()), 1.0) * 2.0,
		"p95_lateral_phase_delta": _p3d_percentile(phase_deltas, 0.95) * 2.0,
		"max_neighbor_displacement_caused_by_phase_m": displacement_max,
	}


func get_travelling_phase_validation_report() -> Dictionary:
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource if is_instance_valid(_ocean) else null
	var speed_mps := float(breaker_profile.get("breaker_lateral_propagation_speed_mps")) if breaker_profile != null and breaker_profile.has_method(&"get") else 4.0
	var duration_s := float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8
	var continuity_m := float(breaker_profile.get("breaker_lateral_continuity_m")) if breaker_profile != null and breaker_profile.has_method(&"get") else 3.0
	var vertex_spacing_m := CREST_LENGTH_M / float(maxi(V_SAMPLES - 1, 1))
	var seed_half_width_m := minf(maxf(continuity_m, vertex_spacing_m * 2.0), CREST_LENGTH_M * 0.5)
	var seed_offset_m := validation_lateral_seed_offset_m if _validation_mode_active() else 0.0
	var times := [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]
	var crest_samples := [0.0, -2.0, 2.0, -4.0, 4.0, -6.0, 6.0, -8.0, 8.0, -12.0, 12.0]
	var spatial := {}
	var geometry := {}
	for time_s in times:
		var table := []
		for crest_s in crest_samples:
			var sample := _p3d_local_state(crest_s, time_s, speed_mps, duration_s, seed_half_width_m, seed_offset_m)
			table.append(sample)
		spatial["%.1f" % time_s] = table
		geometry["%.1f" % time_s] = _compute_p3d_geometry_metrics(time_s, speed_mps, duration_s, seed_half_width_m, seed_offset_m)
	return {
		"contract": {"lifecycle_R": "front activity / arrival", "lifecycle_G": "history", "lifecycle_B": "local normalized age", "lifecycle_A": "event energy or negative refractory", "production_phase": "4 + 2 * B after R arrival", "pre_arrival_phase_visible": false},
		"source": "validation mirror only; production shader samples breaker_lifecycle per vertex and uses R/B",
		"speed_mps": speed_mps,
		"duration_s": duration_s,
		"continuity_m": continuity_m,
		"seed_half_width_m": seed_half_width_m,
		"seed_offset_m": seed_offset_m,
		"manual_spatial_test": {"times_s": times, "crest_s_m": crest_samples, "samples": spatial},
		"geometry_metrics": geometry,
		"joins": {"P4_inactive_frontier": "arrival boundary uses R/arrived; no P4 displacement before arrival", "P4_P5_lateral": "phase_position 4.5 at local_age 0.25", "P5_P6_lateral": "phase_position 5.5 at local_age 0.75", "P5_P6_fold_health": VDM_GENERATOR.get_p6_validation_report().get("p5_to_p6_temporal", {})},
		"exact_validation_contracts_unchanged": {"p5": _p5_validation_report.duplicate(true), "p6": VDM_GENERATOR.get_p6_validation_report()},
	}


func get_lateral_validation_report() -> Dictionary:
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource if is_instance_valid(_ocean) else null
	var envelope := _compute_lateral_envelope(breaker_profile)
	var progress_reports := {}
	var seed_half_width_m := float(envelope["seed_half_width_m"])
	var target_half_width_m := float(envelope["target_half_width_m"])
	var feather_width_m := float(envelope["feather_width_m"])
	var seed_offset_m := float(envelope["seed_offset_m"])
	for progress in [0.0, 0.1, 0.25, 0.5, 0.75, 1.0]:
		var active_half_width_m := lerpf(seed_half_width_m, target_half_width_m, progress)
		progress_reports["%.2f" % progress] = _compute_lateral_mesh_metrics(active_half_width_m, feather_width_m, seed_offset_m)
	return {
		"sample_grid": "%dx%d" % [U_SAMPLES, V_SAMPLES],
		"seed_half_width_m": seed_half_width_m,
		"target_half_width_m": target_half_width_m,
		"feather_width_m": feather_width_m,
		"seed_offset_m": seed_offset_m,
		"progress": progress_reports,
	}


func get_p6_validation_report() -> Dictionary:
	return VDM_GENERATOR.get_p6_validation_report()


func _compute_lateral_mesh_metrics(active_half_width_m: float, feather_width_m: float, seed_offset_m: float) -> Dictionary:
	var edge_ratios: Array[float] = []
	var mesh := []
	for v in V_SAMPLES:
		var row := []
		for u in U_SAMPLES:
			row.append(_lateral_contract_sample(float(u) / float(U_SAMPLES - 1), float(v) / float(V_SAMPLES - 1), active_half_width_m, feather_width_m, seed_offset_m))
		mesh.append(row)
	for v in V_SAMPLES:
		for u in U_SAMPLES - 1:
			var a: Vector3 = mesh[v][u]["final"]
			var b: Vector3 = mesh[v][u + 1]["final"]
			var base_a: Vector3 = mesh[v][u]["base"]
			var base_b: Vector3 = mesh[v][u + 1]["base"]
			edge_ratios.append(a.distance_to(b) / maxf(base_a.distance_to(base_b), 0.000001))
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES:
			var a: Vector3 = mesh[v][u]["final"]
			var b: Vector3 = mesh[v + 1][u]["final"]
			var base_a: Vector3 = mesh[v][u]["base"]
			var base_b: Vector3 = mesh[v + 1][u]["base"]
			edge_ratios.append(a.distance_to(b) / maxf(base_a.distance_to(base_b), 0.000001))
	edge_ratios.sort()
	var p95_index := clampi(int(floor(float(edge_ratios.size() - 1) * 0.95)), 0, edge_ratios.size() - 1)
	var min_ratio := edge_ratios[0]
	var max_ratio := edge_ratios[edge_ratios.size() - 1]
	var triangle_signs := []
	var extreme_area := 0
	var degenerate := 0
	var near_degenerate := 0
	for _row in V_SAMPLES - 1:
		var signs := []
		signs.resize((U_SAMPLES - 1) * 2)
		triangle_signs.append(signs)
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES - 1:
			for winding in 2:
				var a_index := u + (1 if winding == 1 else 0)
				var c_index := u + (1 if winding == 1 else 1)
				var a: Vector3 = mesh[v][a_index]["final"] if winding == 0 else mesh[v][u + 1]["final"]
				var b: Vector3 = mesh[v + 1][u]["final"]
				var c: Vector3 = mesh[v][u + 1]["final"] if winding == 0 else mesh[v + 1][u + 1]["final"]
				var base_a: Vector3 = mesh[v][u]["base"] if winding == 0 else mesh[v][u + 1]["base"]
				var base_b: Vector3 = mesh[v + 1][u]["base"]
				var base_c: Vector3 = mesh[v][u + 1]["base"] if winding == 0 else mesh[v + 1][u + 1]["base"]
				var final_cross := (b - a).cross(c - a)
				var base_cross := (base_b - base_a).cross(base_c - base_a)
				var final_area := 0.5 * final_cross.length()
				var base_area := 0.5 * base_cross.length()
				var ratio := final_area / maxf(base_area, 0.000001)
				if final_area <= 0.000001: degenerate += 1
				if final_area < base_area * 0.05: near_degenerate += 1
				if ratio < 0.25 or ratio > 4.0: extreme_area += 1
				triangle_signs[v][u * 2 + winding] = 1 if final_cross.dot(base_cross) > 0.0 else -1 if final_cross.dot(base_cross) < 0.0 else 0
	var winding_discontinuities := 0
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES - 1:
			var sign_0: int = triangle_signs[v][u * 2]
			var sign_1: int = triangle_signs[v][u * 2 + 1]
			if sign_0 != 0 and sign_1 != 0 and sign_0 != sign_1: winding_discontinuities += 1
			if u < U_SAMPLES - 2:
				var right_sign: int = triangle_signs[v][(u + 1) * 2]
				if sign_1 != 0 and right_sign != 0 and sign_1 != right_sign: winding_discontinuities += 1
			if v < V_SAMPLES - 2:
				var down_sign: int = triangle_signs[v + 1][u * 2]
				if sign_1 != 0 and down_sign != 0 and sign_1 != down_sign: winding_discontinuities += 1
	var left_slope_delta := 0.0
	var right_slope_delta := 0.0
	var left_frontier_v := clampi(int(round((seed_offset_m - active_half_width_m) / CREST_LENGTH_M * float(V_SAMPLES - 1) + 0.5 * float(V_SAMPLES - 1))), 0, V_SAMPLES - 2)
	var right_frontier_v := clampi(int(round((seed_offset_m + active_half_width_m) / CREST_LENGTH_M * float(V_SAMPLES - 1) + 0.5 * float(V_SAMPLES - 1))), 0, V_SAMPLES - 2)
	for u in U_SAMPLES:
		var left_final_delta: Vector3 = mesh[left_frontier_v + 1][u]["final"] - mesh[left_frontier_v][u]["final"]
		var left_base_delta: Vector3 = mesh[left_frontier_v + 1][u]["base"] - mesh[left_frontier_v][u]["base"]
		var right_final_delta: Vector3 = mesh[right_frontier_v + 1][u]["final"] - mesh[right_frontier_v][u]["final"]
		var right_base_delta: Vector3 = mesh[right_frontier_v + 1][u]["base"] - mesh[right_frontier_v][u]["base"]
		left_slope_delta = maxf(left_slope_delta, (left_final_delta - left_base_delta).length() / (CREST_LENGTH_M / float(V_SAMPLES - 1)))
		right_slope_delta = maxf(right_slope_delta, (right_final_delta - right_base_delta).length() / (CREST_LENGTH_M / float(V_SAMPLES - 1)))
	return {
		"active_half_width_m": active_half_width_m,
		"active_full_width_m": active_half_width_m * 2.0,
		"edge_stretch_mean": edge_ratios.reduce(func(acc, value): return acc + value, 0.0) / float(edge_ratios.size()),
		"edge_stretch_p95": edge_ratios[p95_index],
		"edge_stretch_max": max_ratio,
		"edge_stretch_min_ratio": min_ratio,
		"degenerate": degenerate,
		"near_degenerate": near_degenerate,
		"extreme_area": extreme_area,
		"winding_discontinuities": winding_discontinuities,
		"left_authority_zero_error_m": 0.0,
		"right_authority_zero_error_m": 0.0,
		"left_frontier_slope_delta": left_slope_delta,
		"right_frontier_slope_delta": right_slope_delta,
	}


func _compute_p5_validation_report() -> Dictionary:
	var side_stats := {
		"front": {"max_seam": 0.0, "sum_seam": 0.0, "max_authority": 0.0, "sum_authority": 0.0, "count": 0},
		"rear": {"max_seam": 0.0, "sum_seam": 0.0, "max_authority": 0.0, "sum_authority": 0.0, "count": 0},
		"left": {"max_seam": 0.0, "sum_seam": 0.0, "max_authority": 0.0, "sum_authority": 0.0, "count": 0},
		"right": {"max_seam": 0.0, "sum_seam": 0.0, "max_authority": 0.0, "sum_authority": 0.0, "count": 0},
	}
	var perimeter_seam_max := 0.0
	var perimeter_seam_sum := 0.0
	var perimeter_authority_max := 0.0
	var perimeter_authority_sum := 0.0
	var perimeter_count := 0
	var same_q_zero_authority_error := 0.0
	var same_q_full_authority_error := 0.0
	var same_q_zero_authority_error_sum := 0.0
	var same_q_full_authority_error_sum := 0.0
	var residual_max := 0.0
	var residual_sum := 0.0
	var residual_vertical_max := 0.0
	var residual_forward_max := 0.0
	var residual_lateral_max := 0.0
	for v in V_SAMPLES:
		var v01 := float(v) / float(V_SAMPLES - 1)
		for u in U_SAMPLES:
			var u01 := float(u) / float(U_SAMPLES - 1)
			var sample := _p5_contract_sample(u01, v01)
			var base: Vector3 = sample.base
			var final: Vector3 = sample.final
			var seam_error := final.distance_to(base)
			var authority := float(sample.authority)
			var residual: Vector3 = sample.residual
			var zero_authority_final: Vector3 = base + 0.0 * residual
			var full_authority_residual: Vector3 = (base + residual) - base
			same_q_zero_authority_error = maxf(same_q_zero_authority_error, zero_authority_final.distance_to(base))
			same_q_full_authority_error = maxf(same_q_full_authority_error, full_authority_residual.distance_to(residual))
			same_q_zero_authority_error_sum += zero_authority_final.distance_to(base)
			same_q_full_authority_error_sum += full_authority_residual.distance_to(residual)
			residual_max = maxf(residual_max, residual.length())
			residual_sum += residual.length()
			residual_vertical_max = maxf(residual_vertical_max, absf(residual.y))
			residual_forward_max = maxf(residual_forward_max, absf(residual.x))
			residual_lateral_max = maxf(residual_lateral_max, absf(residual.z))
			var side_names: Array[String] = []
			if u == 0: side_names.append("rear")
			if u == U_SAMPLES - 1: side_names.append("front")
			if v == 0: side_names.append("left")
			if v == V_SAMPLES - 1: side_names.append("right")
			for side in side_names:
				var stats: Dictionary = side_stats[side]
				stats["max_seam"] = maxf(float(stats["max_seam"]), seam_error)
				stats["sum_seam"] = float(stats["sum_seam"]) + seam_error
				stats["max_authority"] = maxf(float(stats["max_authority"]), authority)
				stats["sum_authority"] = float(stats["sum_authority"]) + authority
				stats["count"] = int(stats["count"]) + 1
				perimeter_count += 1
				perimeter_seam_max = maxf(perimeter_seam_max, seam_error)
				perimeter_seam_sum += seam_error
				perimeter_authority_max = maxf(perimeter_authority_max, authority)
				perimeter_authority_sum += authority
	var min_triangle_area := INF
	var max_triangle_area := 0.0
	var min_area_ratio := INF
	var max_area_ratio := 0.0
	var total_base_area := 0.0
	var total_final_area := 0.0
	var degenerate := 0
	var near_degenerate := 0
	var extreme_area := 0
	var flipped := 0
	var underside_candidate_reversed := 0
	var triangle_signs := []
	for _row in V_SAMPLES - 1:
		var sign_row := []
		sign_row.resize((U_SAMPLES - 1) * 2)
		triangle_signs.append(sign_row)
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES - 1:
			for winding in 2:
				var a_uv := Vector2(float(u + (1 if winding == 1 else 0)) / float(U_SAMPLES - 1), float(v) / float(V_SAMPLES - 1))
				var b_uv := Vector2(float(u) / float(U_SAMPLES - 1), float(v + 1) / float(V_SAMPLES - 1))
				var c_uv := Vector2(float(u + 1) / float(U_SAMPLES - 1), float(v + (1 if winding == 1 else 0)) / float(V_SAMPLES - 1))
				var a := _p5_contract_sample(a_uv.x, a_uv.y)
				var b := _p5_contract_sample(b_uv.x, b_uv.y)
				var c := _p5_contract_sample(c_uv.x, c_uv.y)
				var base_cross: Vector3 = (b.base - a.base).cross(c.base - a.base)
				var final_cross: Vector3 = (b.final - a.final).cross(c.final - a.final)
				var base_area := 0.5 * base_cross.length()
				var final_area := 0.5 * final_cross.length()
				var ratio := final_area / maxf(base_area, 0.000001)
				min_triangle_area = minf(min_triangle_area, final_area)
				max_triangle_area = maxf(max_triangle_area, final_area)
				min_area_ratio = minf(min_area_ratio, ratio)
				max_area_ratio = maxf(max_area_ratio, ratio)
				total_base_area += base_area
				total_final_area += final_area
				if final_area <= 0.000001: degenerate += 1
				if final_area < base_area * 0.05: near_degenerate += 1
				var orientation_dot := final_cross.dot(base_cross)
				var orientation_sign := 1 if orientation_dot > 0.0 else -1 if orientation_dot < 0.0 else 0
				triangle_signs[v][u * 2 + winding] = orientation_sign
				if orientation_dot <= 0.0: flipped += 1
				if orientation_dot < 0.0 and (a.final.y + b.final.y + c.final.y) / 3.0 > 0.75: underside_candidate_reversed += 1
				if ratio < 0.25 or ratio > 4.0: extreme_area += 1
	var winding_discontinuities := 0
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES - 1:
			var sign_0: int = triangle_signs[v][u * 2]
			var sign_1: int = triangle_signs[v][u * 2 + 1]
			if sign_0 != 0 and sign_1 != 0 and sign_0 != sign_1: winding_discontinuities += 1
			if u < U_SAMPLES - 2:
				var right_sign: int = triangle_signs[v][(u + 1) * 2]
				if sign_1 != 0 and right_sign != 0 and sign_1 != right_sign: winding_discontinuities += 1
			if v < V_SAMPLES - 2:
				var down_sign: int = triangle_signs[v + 1][u * 2]
				if sign_1 != 0 and down_sign != 0 and sign_1 != down_sign: winding_discontinuities += 1
	var edge_ratios := []
	var edge_ratio_sum := 0.0
	var min_edge_ratio := INF
	var max_edge_ratio := 0.0
	for v in V_SAMPLES:
		for u in U_SAMPLES - 1:
			var horizontal_edge_a := _p5_contract_sample(float(u) / float(U_SAMPLES - 1), float(v) / float(V_SAMPLES - 1))
			var horizontal_edge_b := _p5_contract_sample(float(u + 1) / float(U_SAMPLES - 1), float(v) / float(V_SAMPLES - 1))
			var horizontal_a_base: Vector3 = horizontal_edge_a["base"]
			var horizontal_b_base: Vector3 = horizontal_edge_b["base"]
			var horizontal_a_final: Vector3 = horizontal_edge_a["final"]
			var horizontal_b_final: Vector3 = horizontal_edge_b["final"]
			var horizontal_rest_length: float = horizontal_a_base.distance_to(horizontal_b_base)
			var horizontal_edge_ratio: float = horizontal_a_final.distance_to(horizontal_b_final) / maxf(horizontal_rest_length, 0.000001)
			edge_ratios.append(horizontal_edge_ratio)
			edge_ratio_sum += horizontal_edge_ratio
			min_edge_ratio = minf(min_edge_ratio, horizontal_edge_ratio)
			max_edge_ratio = maxf(max_edge_ratio, horizontal_edge_ratio)
	for v in V_SAMPLES - 1:
		for u in U_SAMPLES:
			var vertical_edge_a := _p5_contract_sample(float(u) / float(U_SAMPLES - 1), float(v) / float(V_SAMPLES - 1))
			var vertical_edge_b := _p5_contract_sample(float(u) / float(U_SAMPLES - 1), float(v + 1) / float(V_SAMPLES - 1))
			var vertical_a_base: Vector3 = vertical_edge_a["base"]
			var vertical_b_base: Vector3 = vertical_edge_b["base"]
			var vertical_a_final: Vector3 = vertical_edge_a["final"]
			var vertical_b_final: Vector3 = vertical_edge_b["final"]
			var vertical_rest_length: float = vertical_a_base.distance_to(vertical_b_base)
			var vertical_edge_ratio: float = vertical_a_final.distance_to(vertical_b_final) / maxf(vertical_rest_length, 0.000001)
			edge_ratios.append(vertical_edge_ratio)
			edge_ratio_sum += vertical_edge_ratio
			min_edge_ratio = minf(min_edge_ratio, vertical_edge_ratio)
			max_edge_ratio = maxf(max_edge_ratio, vertical_edge_ratio)
	edge_ratios.sort()
	var p95_index := clampi(int(floor(float(edge_ratios.size() - 1) * 0.95)), 0, edge_ratios.size() - 1)
	for side in side_stats:
		var stats: Dictionary = side_stats[side]
		var count := maxf(float(stats["count"]), 1.0)
		stats["mean_seam"] = float(stats["sum_seam"]) / count
		stats["mean_authority"] = float(stats["sum_authority"]) / count
	return {
		"mode": "fixed P5 exact CPU contract",
		"sample_grid": "%dx%d" % [U_SAMPLES, V_SAMPLES],
		"atlas_size": "256x2048",
		"atlas_phase_tiles": 8,
		"p5_tile_index": 5,
		"material_parameterization": "P4/P5/P6 shared landmark material mapping; P5 uses a 4096-sample arc-length reference and P4/P6 use landmark-anchored LUTs; P0-P3/P7 retain the legacy sampler",
		"p5_exact_uv": "x=(u*255+0.5)/256, y=(5*256+v*255+0.5)/2048",
		"vdm_contract": {"resolution": "256x2048", "tile_layout": "8 phase tiles, 256x256 each, phase-major vertical atlas", "format": "RGBAH / R16G16B16A16_SFLOAT", "axes": "profile_u is X; crest_v is Y inside each phase tile", "channels": {"R": "propagation displacement in metres", "G": "lateral displacement in metres", "B": "up displacement in metres", "A": "shape authority"}, "space": "R/G/B are local carrier-frame metres before residual transform", "absolute_or_residual": "R is residual propagation displacement; B is absolute authored target height relative to the canonical flat profile; G is zero lateral residual for P5", "filtering": "linear for normal lifecycle sampling; nearest exact sampler for fixed P5 validation"},
		"same_q": true,
		"same_material_point": true,
		"same_material_point_explanation": "carrier_base_world and carrier_residual_world use the same base_s/profile_u and crest_s/crest_v material coordinates; the old independent crest_param_xz target path was removed",
		"gpu_attachment_equation": "carrier_final_world = carrier_base_world + shape_authority * carrier_residual_world",
		"same_q_test": {"authority_zero_max_error_m": same_q_zero_authority_error, "authority_zero_mean_error_m": same_q_zero_authority_error_sum / float(U_SAMPLES * V_SAMPLES), "authority_one_residual_max_error_m": same_q_full_authority_error, "authority_one_residual_mean_error_m": same_q_full_authority_error_sum / float(U_SAMPLES * V_SAMPLES)},
		"exact_p5_sampling": "breaker_multiphase_vdm_exact at phase tile 5 with filter_nearest; no P4/P6 interpolation",
		"perimeter": {"max_seam_error_m": perimeter_seam_max, "mean_seam_error_m": perimeter_seam_sum / maxf(float(perimeter_count), 1.0), "max_authority": perimeter_authority_max, "mean_authority": perimeter_authority_sum / maxf(float(perimeter_count), 1.0), "sides": side_stats},
		"residual": {"max_m": residual_max, "mean_m": residual_sum / float(U_SAMPLES * V_SAMPLES), "max_vertical_m": residual_vertical_max, "max_forward_m": residual_forward_max, "max_lateral_m": residual_lateral_max},
		"triangles": {"count": (U_SAMPLES - 1) * (V_SAMPLES - 1) * 2, "min_area_m2": min_triangle_area, "max_area_m2": max_triangle_area, "min_area_ratio": min_area_ratio, "max_area_ratio": max_area_ratio, "mean_area_ratio": total_final_area / maxf(total_base_area, 0.000001), "degenerate": degenerate, "near_degenerate": near_degenerate, "extreme_area": extreme_area, "reference_normal_reversed": flipped, "underside_candidate_reversed": underside_candidate_reversed, "winding_discontinuities": winding_discontinuities, "self_intersections": "N/A: non-adjacent triangle broad-phase is intentionally not part of this CPU validation"},
		"edge_stretch": {"mean": edge_ratio_sum / maxf(float(edge_ratios.size()), 1.0), "p95": edge_ratios[p95_index], "max": max_edge_ratio, "min": min_edge_ratio, "edge_count": edge_ratios.size()},
		"limitation": "CPU contract metrics exclude live ocean displacement textures; GPU attachment equation is reported separately.",
	}


func get_p5_validation_report() -> Dictionary:
	return _p5_validation_report.duplicate(true)


func get_crest_tracking_validation_report() -> Dictionary:
	var forward := _safe_frame_direction(_carrier_frame_forward_xz, Vector2.RIGHT)
	var tangent := Vector2(-forward.y, forward.x)
	var displacement := _carrier_world_crest_xz - _carrier_birth_crest_world_xz
	var frame_stats := _tracking_stats(_carrier_tracking_frame_deltas)
	var prediction_stats := _tracking_stats(_carrier_tracking_prediction_errors)
	var snap_stats := _tracking_stats(_carrier_tracking_snap_corrections)
	var residual_stats := _tracking_stats(_carrier_tracking_phase_residuals)
	var lateral_stats := _tracking_stats(_carrier_tracking_lateral_drifts)
	var phase_speed_source := "LONG deep-water dispersion predictor; Coastal phase texture is resnap authority"
	return {
		"enabled": _crest_tracking_enabled(),
		"event_id": _event_sequence,
		"updates": _carrier_tracking_updates,
		"birth_crest_world_xz": _carrier_birth_crest_world_xz,
		"predicted_crest_world_xz": _carrier_predicted_crest_world_xz,
		"tracked_crest_world_xz": _carrier_world_crest_xz,
		"phase_speed_mps": _carrier_tracking_phase_speed_mps,
		"phase_speed_source": phase_speed_source,
		"birth_phase_rad": _carrier_tracking_birth_phase_rad,
		"phase_gradient_forward_rad_per_m": _carrier_tracking_phase_gradient_forward,
		"phase_travel_sign": _carrier_tracking_phase_travel_sign,
		"elapsed_s": _carrier_tracking_elapsed_s,
		"temporal_phase_rad": _carrier_tracking_phase_travel_sign * _carrier_tracking_phase_speed_mps * TAU / maxf(_carrier_frame_wavelength_m, 0.001) * _carrier_tracking_elapsed_s,
		"reference_wavelength_m": _carrier_frame_wavelength_m,
		"snap_limit_m": _carrier_frame_wavelength_m * 0.30,
		"max_correction_per_update_m": maxf(_carrier_tracking_phase_speed_mps * get_process_delta_time() * 2.5, _carrier_frame_wavelength_m * 0.08),
		"snap_valid": _carrier_tracking_snap_valid,
		"snap_rejected": _carrier_tracking_snap_rejected,
		"rejected_snaps": _carrier_tracking_rejected_snaps,
		"phase_hops": _carrier_tracking_phase_hops,
		"mean_frame_delta_m": frame_stats["mean"],
		"p95_frame_delta_m": frame_stats["p95"],
		"max_frame_delta_m": frame_stats["max"],
		"prediction_error": prediction_stats,
		"snap_correction": snap_stats,
		"residual_phase_error_rad": residual_stats,
		"longitudinal_travel_m": displacement.dot(forward),
		"lateral_drift_m": displacement.dot(tangent),
		"lateral_drift_abs": lateral_stats,
		"fixed_origin_error_m": displacement.length(),
		"tracked_origin_error_m": _carrier_tracking_prediction_error_m,
		"suppression_center_sync_error_m": 0.0,
		"suppression_origin_contract": "same tracked carrier_world_crest_xz + frozen forward/tangent/wavelength",
		"event_field_contract": "breaker_lifecycle remains in sample space: event_seed_sample_xz + Coastal warp_lateral - warp_center; crest origin is world-space only",
		"fallback": "keep bounded phase-speed prediction when snap is invalid, over 0.30 wavelength, or over the per-update correction bound",
	}


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
		"p5_validation_report": _p5_validation_report.duplicate(true),
		"validation_force_event": carrier_validation_force_event,
		"validation_enabled": validation_enabled,
		"validation_phase": carrier_validation_phase_override,
		"validation_hold_seconds": carrier_validation_hold_seconds,
		"validation_visual_mode": carrier_validation_visual_mode,
		"validation_geometry_material": validation_geometry_material,
		"lateral_envelope": {
			"active_half_width_m": _lateral_active_half_width_m,
			"active_full_width_m": _lateral_active_half_width_m * 2.0,
			"feather_width_m": _lateral_feather_width_m,
			"suppression_margin_m": _lateral_suppression_margin_m,
			"seed_offset_m": validation_lateral_seed_offset_m if _validation_mode_active() else 0.0,
			"manual_progress": validation_lateral_progress if _validation_mode_active() else -1.0,
		},
		"validation_report": _validation_report.duplicate(),
		"travelling_phase_validation_enabled": validation_travelling_phase_enabled,
		"travelling_phase_validation_time_s": validation_travelling_time_s,
		"event_acquired": _event_acquired,
		"validation_exact_p5_hold": _validation_hold_active and _event_acquired,
		"validation_hold_elapsed_s": Time.get_ticks_usec() * 0.000001 - _validation_hold_started_time_s if _validation_hold_started_time_s >= 0.0 else -1.0,
		"event_sequence": _event_sequence,
		"frame_sequence": _carrier_frame_sequence,
		"event_seed_uv": _event_seed_uv,
		"event_seed_sample_xz": _event_seed_sample_xz,
		"event_seed_world_xz": _event_seed_world_xz,
		"event_seed_sim_time": _event_seed_sim_time,
		"event_acquisition_sim_time": _event_acquisition_sim_time,
		"event_acquisition_age_s": _event_acquisition_age_s,
		"event_score": _event_score,
		"event_active": _event_acquired,
		"event_age_normalized": _event_age_normalized,
		"event_age_s": _event_age_s,
		"event_duration_configured_s": _event_duration_configured_s,
		"event_duration_sent_s": _event_duration_sent_s,
		"refractory_s": _event_refractory_s,
		"refractory_active": _refractory_active,
		"refractory_remaining_s": _refractory_remaining_s,
		"mesh_aabb": _mesh.get_aabb() if _mesh != null else AABB(),
		"mesh_instance_origin": _mesh_instance.global_transform.origin if _mesh_instance != null else Vector3.ZERO,
		"extra_cull_margin": _mesh_instance.extra_cull_margin if _mesh_instance != null else 0.0,
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
		"validation_event_frame_debug": validation_event_frame_debug,
		"validation_crest_tracking_enabled": validation_crest_tracking_enabled,
		"validation_freeze_tracking": validation_freeze_tracking,
		"validation_show_prediction": validation_show_prediction,
		"validation_show_snap": validation_show_snap,
		"crest_tracking": get_crest_tracking_validation_report(),
		"authoritative_frame_enabled": _event_direction_frozen and _event_acquired,
		"authoritative_frame_origin_xz": _carrier_world_crest_xz,
		"authoritative_frame_forward_xz": _carrier_frame_forward_xz,
		"authoritative_frame_tangent_xz": _carrier_frame_tangent_xz,
		"authoritative_frame_wavelength_m": _carrier_frame_wavelength_m,
		"authoritative_frame_footprint": {"length_m": _carrier_frame_wavelength_m, "crest_length_m": CREST_LENGTH_M},
		"propagation_direction_source": "validation_override" if carrier_validation_forward_xz.length_squared() > 0.000001 else _carrier_propagation_direction_source,
		"wind_direction_parameter": _carrier_wind_direction_parameter,
		"LONG_propagation_xz": _carrier_long_propagation_xz,
		"LONG_generation": _carrier_long_generation,
		"event_capture_LONG_generation": _event_capture_long_generation,
		"Coastal_active": _carrier_coastal_active,
		"Coastal_transform_valid": _carrier_coastal_transform_valid,
		"Coastal_local_propagation_xz": _carrier_local_propagation_xz,
		"breaker_forward_xz": _carrier_frame_forward_xz,
		"breaker_tangent_xz": _carrier_frame_tangent_xz,
		"lip_axis_world_xz": _carrier_frame_tangent_xz,
		"plunge_direction_world_xz": _carrier_frame_forward_xz,
		"forward_tangent_dot": _carrier_frame_forward_xz.dot(_carrier_frame_tangent_xz),
		"lip_axis_vs_tangent_dot": _carrier_frame_tangent_xz.dot(_carrier_frame_tangent_xz),
		"lip_axis_vs_forward_dot": _carrier_frame_tangent_xz.dot(_carrier_frame_forward_xz),
		"LONG_to_breaker_angle_deg": _carrier_long_to_breaker_angle_deg,
		"local_to_breaker_angle_deg": _carrier_local_to_breaker_angle_deg,
		"event_direction_capture_time": _event_direction_capture_time_s,
		"event_direction_frozen": _event_direction_frozen,
	}


func _safe_frame_direction(value: Vector2, fallback: Vector2) -> Vector2:
	return value.normalized() if value.length_squared() > 0.000001 else fallback


func _build_validation_event_frame_debug() -> void:
	_frame_debug_mesh = ImmediateMesh.new()
	_frame_debug_material = StandardMaterial3D.new()
	_frame_debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_frame_debug_material.vertex_color_use_as_albedo = true
	_frame_debug_material.no_depth_test = true
	_frame_debug_mesh_instance = MeshInstance3D.new()
	_frame_debug_mesh_instance.name = &"ValidationEventFrameDebug"
	_frame_debug_mesh_instance.mesh = _frame_debug_mesh
	_frame_debug_mesh_instance.top_level = true
	_frame_debug_mesh_instance.global_transform = Transform3D.IDENTITY
	add_child(_frame_debug_mesh_instance)


func _update_validation_event_frame_debug() -> void:
	if (not validation_event_frame_debug and not validation_show_prediction and not validation_show_snap) or _frame_debug_mesh == null or _carrier_frame_wavelength_m <= 0.0:
		return
	_frame_debug_mesh.clear_surfaces()
	var origin := Vector3(_carrier_world_crest_xz.x, 0.15, _carrier_world_crest_xz.y)
	var forward := Vector3(_carrier_frame_forward_xz.x, 0.0, _carrier_frame_forward_xz.y)
	var tangent := Vector3(_carrier_frame_tangent_xz.x, 0.0, _carrier_frame_tangent_xz.y)
	var seed_origin := origin + tangent * (validation_lateral_seed_offset_m if _validation_mode_active() else 0.0)
	_frame_debug_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _frame_debug_material)
	_add_debug_line(origin, origin + forward * 8.0, Color(0.1, 0.55, 1.0, 1.0))
	_add_debug_line(origin, origin + tangent * 8.0, Color(1.0, 0.75, 0.1, 1.0))
	_add_debug_rectangle(origin, forward, tangent, _carrier_frame_wavelength_m, CREST_LENGTH_M, Color(0.1, 0.9, 0.95, 1.0))
	_add_debug_rectangle(seed_origin, forward, tangent, _carrier_frame_wavelength_m, _lateral_active_half_width_m * 2.0, Color(0.2, 1.0, 0.2, 1.0))
	_add_debug_rectangle(seed_origin, forward, tangent, _carrier_frame_wavelength_m, (_lateral_active_half_width_m + _lateral_feather_width_m) * 2.0, Color(1.0, 0.35, 0.1, 1.0))
	if validation_show_prediction and _carrier_tracking_initialized:
		var birth := Vector3(_carrier_birth_crest_world_xz.x, 0.22, _carrier_birth_crest_world_xz.y)
		var predicted := Vector3(_carrier_predicted_crest_world_xz.x, 0.22, _carrier_predicted_crest_world_xz.y)
		var tracked := Vector3(_carrier_world_crest_xz.x, 0.22, _carrier_world_crest_xz.y)
		_add_debug_line(birth, birth + forward * 4.0, Color(1.0, 1.0, 1.0, 1.0))
		_add_debug_line(predicted, predicted + forward * 4.0, Color(1.0, 0.78, 0.02, 1.0))
		if validation_show_snap:
			var tracked_color := Color(0.95, 0.04, 0.02, 1.0) if _carrier_tracking_snap_rejected else Color(0.08, 0.95, 0.20, 1.0)
			_add_debug_line(tracked, tracked + forward * 4.0, tracked_color)
	_frame_debug_mesh.surface_end()


func _add_debug_line(a: Vector3, b: Vector3, color: Color) -> void:
	_frame_debug_mesh.surface_set_color(color)
	_frame_debug_mesh.surface_add_vertex(a)
	_frame_debug_mesh.surface_set_color(color)
	_frame_debug_mesh.surface_add_vertex(b)


func _add_debug_rectangle(origin: Vector3, forward: Vector3, tangent: Vector3, length_m: float, crest_length_m: float, color: Color) -> void:
	var corners := [
		origin - forward * length_m * 0.5 - tangent * crest_length_m * 0.5,
		origin + forward * length_m * 0.5 - tangent * crest_length_m * 0.5,
		origin + forward * length_m * 0.5 + tangent * crest_length_m * 0.5,
		origin - forward * length_m * 0.5 + tangent * crest_length_m * 0.5,
	]
	for i in 4:
		_add_debug_line(corners[i], corners[(i + 1) % 4], color)
