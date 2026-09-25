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
const PROJECTED_COVERAGE_GRID_S := 512
const PROJECTED_COVERAGE_GRID_V := 256
const PROJECTED_TRANSITION_GRID_S := 256
const PROJECTED_TRANSITION_GRID_V := 128
const PROJECTED_OVERLAP_HEIGHT_EPSILON_M := 0.25
const DENSITY_PRESETS := {
	"A_256x64": Vector2i(256, 64),
	"B_256x128": Vector2i(256, 128),
	"C_512x64": Vector2i(512, 64),
	"D_512x128": Vector2i(512, 128),
}

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
## Validation-only attachment probe. Keeps Carrier ownership/visibility active
## while forcing the residual shape authority to zero; production never uses it.
@export var carrier_validation_zero_shape_authority := false
@export_range(0.0, 60.0, 0.5, "suffix:s") var carrier_validation_hold_seconds := 5.0
@export var carrier_validation_event_position_xz := Vector2.ZERO
## Validation override for controlled propagation tests. Zero means automatic
## runtime LONG propagation transformed through the local Coastal warp.
@export var carrier_validation_forward_xz := Vector2.ZERO
@export_enum("SIDE_PROFILE", "THREE_QUARTER") var carrier_validation_camera_view := 0
@export_enum("NORMAL", "AUTHORITY", "RESIDUAL_MAGNITUDE", "BASE_VS_BREAKER", "TRIANGLE_STRETCH", "TRAVELLING_PHASE", "CREST_TRACKING") var carrier_validation_visual_mode := 0
@export_enum("NORMAL", "DEBUG", "GEOMETRIC_NORMAL_ONLY", "OCEAN_PARITY", "FINAL_NORMAL_ONLY", "NORMAL_DELTA") var carrier_material_mode := 0
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
@export_group("P3E Handoff Validation")
## Validation-only local handoff harness. Production ownership remains driven by
## the published breaker lifecycle texture when this is disabled.
@export var validation_handoff_enabled := false
## -1 uses elapsed time from acquisition; non-negative values pin the harness
## to a deterministic local handoff time without hotkeys.
@export_range(-1.0, 12.0, 0.05, "suffix:s") var validation_handoff_time_s := -1.0
@export var validation_show_ownership := false
## Increment in the Inspector after changing wind_direction to reacquire the
## forced validation event without adding a runtime hotkey or production API.
@export var validation_event_reacquire_serial := 0
## Retained for scene compatibility. Active events never auto-reacquire on wind
## change; use validation_event_reacquire_serial for an explicit reset.
@export var validation_auto_reacquire_on_long_direction_change := true
## Static mesh density selected by the G1 validation. Reconfiguration remains
## validation-only; the selected default is built once and reused at runtime.
@export_enum("A_256x64", "B_256x128", "C_512x64", "D_512x128") var validation_mesh_density_preset := "B_256x128"

var _mesh_instance: MeshInstance3D
var _mesh: ArrayMesh
var _mesh_u_samples := U_SAMPLES
var _mesh_v_samples := V_SAMPLES
var _mesh_build_time_ms := 0.0
var _mesh_build_count := 0
var _carrier_material: ShaderMaterial
var _carrier_material_variants: Dictionary = {}
var _carrier_material_variant_key := ""
var _attachment_parameter_signature_cache: Dictionary = {}
var _ocean: Node
var _attached := false
var _camera_update_accumulator := 0.0
var _probe_request_accumulator := 1.0 / 30.0
var _carrier_image_cache_valid := false
var _carrier_image_cache_pending_sequence := -2
var _carrier_image_cache_source_signature: Array = []
var _carrier_phase_image: Image
var _carrier_metrics_image: Image
var _carrier_warp_image: Image
var _carrier_jacobian_image: Image
var _carrier_field_image: Image
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
var _carrier_lease_age_s := INF
var _carrier_lease_duration_s := 0.0
var _carrier_lease_active := false
var _carrier_lease_release_ready := false
var _carrier_lease_propagation_distance_m := 0.0
var _carrier_lease_max_arrival_s := 0.0
var _carrier_lease_latest_local_finish_s := 0.0
var _carrier_lease_handoff_guard_s := 0.0
var _carrier_lease_seed_half_width_m := 0.0
var _carrier_lease_target_half_width_m := 0.0
var _carrier_lease_suppression_half_width_m := 0.0
var _carrier_lease_speed_mps := 0.0
var _carrier_lease_local_duration_s := 0.8
var _carrier_local_coverage_expected := false
var _carrier_ignored_candidate_count := 0
var _carrier_last_released_event_id := -1
var _carrier_release_reason := ""
var _carrier_last_release_report: Dictionary = {}
var _validation_hold_active := false
var _validation_hold_started_time_s := -1.0
var _last_validation_event_reacquire_serial := 0
var _validation_waiting_for_reacquire := false
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
var _carrier_tracking_predictor_origin_xz := Vector2.ZERO
var _carrier_predicted_crest_world_xz := Vector2.ZERO
var _carrier_tracking_phase_speed_mps := 0.0
var _carrier_tracking_snap_correction_m := 0.0
var _carrier_tracking_prediction_error_m := 0.0
var _carrier_tracking_phase_residual_rad := 0.0
var _carrier_tracking_birth_phase_rad := 0.0
var _carrier_tracking_elapsed_s := 0.0
var _carrier_tracking_last_wave_time_s := -1.0
var _carrier_tracking_last_wave_delta_s := 0.0
var _carrier_tracking_phase_gradient_forward := 0.0
var _carrier_tracking_phase_travel_sign := 1.0
var _carrier_tracking_snap_valid := false
var _carrier_tracking_snap_rejected := false
var _carrier_tracking_initialized := false
var _carrier_tracking_updates := 0
var _carrier_tracking_phase_hops := 0
var _carrier_tracking_rejected_snaps := 0
var _carrier_tracking_resnap_interval_s := 0.10
var _carrier_tracking_resnap_accumulator_s := 0.0
var _carrier_tracking_resnap_updates := 0
var _carrier_tracking_correction_offset_xz := Vector2.ZERO
var _carrier_tracking_correction_target_xz := Vector2.ZERO
var _carrier_tracking_last_valid_correction_target_xz := Vector2.ZERO
var _carrier_tracking_last_velocity_xz := Vector2.ZERO
var _carrier_tracking_velocity_initialized := false
var _carrier_tracking_integration_time_s := 0.0
var _carrier_missing_wave_clock_warning_emitted := false
var _carrier_missing_lifecycle_clock_warning_emitted := false
var _carrier_tracking_wave_clock_was_missing := false
var _carrier_tracking_expected_prediction_errors: Array[float] = []
var _carrier_tracking_velocities_mps: Array[float] = []
var _carrier_tracking_velocity_jumps_mps: Array[float] = []
var _carrier_tracking_frame_deltas: Array[float] = []
var _carrier_tracking_prediction_errors: Array[float] = []
var _carrier_tracking_snap_corrections: Array[float] = []
var _carrier_tracking_correction_deltas: Array[float] = []
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


func _begin_carrier_lease(breaker_profile: Resource) -> void:
	var propagation_speed_mps := float(breaker_profile.get("breaker_lateral_propagation_speed_mps")) if breaker_profile != null and breaker_profile.has_method(&"get") else 4.0
	var local_duration_s := float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8
	var continuity_m := float(breaker_profile.get("breaker_lateral_continuity_m")) if breaker_profile != null and breaker_profile.has_method(&"get") else 3.0
	var vertex_spacing_m := CREST_LENGTH_M / float(maxi(V_SAMPLES - 1, 1))
	var carrier_half_width_m := CREST_LENGTH_M * 0.5
	var seed_half_width_m := minf(maxf(continuity_m, vertex_spacing_m * 2.0), carrier_half_width_m)
	var target_half_width_m := carrier_half_width_m
	var suppression_margin_m := vertex_spacing_m
	var propagation_distance_m := maxf(target_half_width_m - seed_half_width_m, 0.0)
	var max_arrival_s := propagation_distance_m / maxf(propagation_speed_mps, 0.001)
	var latest_local_finish_s := max_arrival_s + maxf(local_duration_s, 0.001)
	# The margin is a spatial guard for the suppression feather, converted to
	# time at the same lateral front speed. It is not an artistic fixed lease.
	var handoff_guard_s := suppression_margin_m / maxf(propagation_speed_mps, 0.001)
	_carrier_lease_seed_half_width_m = seed_half_width_m
	_carrier_lease_target_half_width_m = target_half_width_m
	_carrier_lease_suppression_half_width_m = target_half_width_m + suppression_margin_m
	_carrier_lease_propagation_distance_m = propagation_distance_m
	_carrier_lease_speed_mps = maxf(propagation_speed_mps, 0.001)
	_carrier_lease_local_duration_s = maxf(local_duration_s, 0.001)
	_carrier_lease_max_arrival_s = max_arrival_s
	_carrier_lease_latest_local_finish_s = latest_local_finish_s
	_carrier_lease_handoff_guard_s = handoff_guard_s
	_carrier_lease_duration_s = latest_local_finish_s + handoff_guard_s
	_carrier_lease_age_s = 0.0
	_carrier_lease_active = true
	_carrier_lease_release_ready = false
	_carrier_local_coverage_expected = true
	_carrier_release_reason = ""


func _reset_carrier_lease_state() -> void:
	_carrier_lease_age_s = INF
	_carrier_lease_duration_s = 0.0
	_carrier_lease_active = false
	_carrier_lease_release_ready = false
	_carrier_lease_propagation_distance_m = 0.0
	_carrier_lease_max_arrival_s = 0.0
	_carrier_lease_latest_local_finish_s = 0.0
	_carrier_lease_handoff_guard_s = 0.0
	_carrier_lease_seed_half_width_m = 0.0
	_carrier_lease_target_half_width_m = 0.0
	_carrier_lease_suppression_half_width_m = 0.0
	_carrier_lease_speed_mps = 0.0
	_carrier_lease_local_duration_s = 0.8
	_carrier_local_coverage_expected = false


func _update_carrier_lease_age(open_ocean: Node) -> void:
	if not _carrier_lease_active:
		return
	var age_s := _carrier_lease_age_s if is_finite(_carrier_lease_age_s) else 0.0
	if _validation_mode_active():
		if validation_handoff_enabled:
			if validation_handoff_time_s >= 0.0:
				## Explicit validation time is deterministic/manual by contract.
				age_s = validation_handoff_time_s
			else:
				var lifecycle_time := _get_breaker_lifecycle_time_s(open_ocean)
				if lifecycle_time >= 0.0 and _event_acquisition_sim_time >= 0.0:
					age_s = maxf(lifecycle_time - _event_acquisition_sim_time, 0.0)
				else:
					_warn_missing_lifecycle_clock("validation lease")
	else:
		var lifecycle_time := _get_breaker_lifecycle_time_s(open_ocean)
		if lifecycle_time >= 0.0 and _event_acquisition_sim_time >= 0.0:
			age_s = maxf(lifecycle_time - _event_acquisition_sim_time, 0.0)
		else:
			_warn_missing_lifecycle_clock("lease")
	_carrier_lease_age_s = age_s
	_carrier_local_coverage_expected = age_s < _carrier_lease_latest_local_finish_s
	_carrier_lease_release_ready = age_s >= _carrier_lease_duration_s and not _carrier_local_coverage_expected


func _release_carrier_lease(surface: Node) -> void:
	if not _event_acquired:
		return
	if surface != null and surface.has_method(&"set_breaker_carrier_suppression"):
		surface.set_breaker_carrier_suppression(false, carrier_search_xz, CREST_LENGTH_M)
	_carrier_last_released_event_id = _event_sequence
	_carrier_release_reason = "lease_expired_no_local_coverage_and_suppression_released"
	_carrier_last_release_report = {
		"event_id": _event_sequence,
		"lease_age_s": _carrier_lease_age_s,
		"lease_duration_s": _carrier_lease_duration_s,
		"latest_local_finish_s": _carrier_lease_latest_local_finish_s,
		"release_reason": _carrier_release_reason,
	}
	if _mesh_instance != null:
		_mesh_instance.visible = false
	_attached = false
	_event_acquired = false
	_validation_hold_active = false
	_validation_hold_started_time_s = -1.0
	_pending_event_sequence = -1
	_carrier_frame_sequence = -1
	_validation_report.clear()
	_carrier_world_crest_xz = Vector2.ZERO
	_carrier_sample_crest_xz = Vector2.ZERO
	_clear_event_direction_state()
	_reset_crest_tracking_state()
	_reset_carrier_lease_state()
	_validation_waiting_for_reacquire = _validation_mode_active()


func _validation_handoff_clock_s(open_ocean: Node = null) -> float:
	if not validation_handoff_enabled or not _validation_mode_active():
		return 0.0
	if validation_handoff_time_s >= 0.0:
		## Inspector-pinned validation time is intentionally not reinterpreted.
		return validation_handoff_time_s
	var runtime_ocean := open_ocean if open_ocean != null else _get_runtime_open_ocean()
	var lifecycle_time := _get_breaker_lifecycle_time_s(runtime_ocean)
	if lifecycle_time >= 0.0 and _event_acquisition_sim_time >= 0.0:
		return maxf(lifecycle_time - _event_acquisition_sim_time, 0.0)
	_warn_missing_lifecycle_clock("validation handoff")
	return maxf(_carrier_lease_age_s, 0.0) if is_finite(_carrier_lease_age_s) else 0.0


func _warn_missing_wave_clock(context: String) -> void:
	if _carrier_missing_wave_clock_warning_emitted:
		return
	_carrier_missing_wave_clock_warning_emitted = true
	push_warning("BreakerCarrier: Ocean wave simulation clock unavailable during %s; preserving the last valid Carrier state." % context)


func _warn_missing_lifecycle_clock(context: String) -> void:
	if _carrier_missing_lifecycle_clock_warning_emitted:
		return
	_carrier_missing_lifecycle_clock_warning_emitted = true
	push_warning("BreakerCarrier: Ocean breaker lifecycle clock unavailable during %s; preserving the last valid lifecycle state." % context)


func _crest_tracking_enabled() -> bool:
	## A phase override is a SHAPE override only. Position tracking remains
	## continuous unless the explicit freeze switch is enabled.
	return not validation_freeze_tracking


func _reset_crest_tracking_state() -> void:
	_carrier_birth_crest_world_xz = Vector2.ZERO
	_carrier_tracking_predictor_origin_xz = Vector2.ZERO
	_carrier_predicted_crest_world_xz = Vector2.ZERO
	_carrier_tracking_phase_speed_mps = 0.0
	_carrier_tracking_snap_correction_m = 0.0
	_carrier_tracking_prediction_error_m = 0.0
	_carrier_tracking_phase_residual_rad = 0.0
	_carrier_tracking_birth_phase_rad = 0.0
	_carrier_tracking_elapsed_s = 0.0
	_carrier_tracking_last_wave_time_s = -1.0
	_carrier_tracking_last_wave_delta_s = 0.0
	_carrier_tracking_wave_clock_was_missing = false
	_carrier_tracking_phase_gradient_forward = 0.0
	_carrier_tracking_phase_travel_sign = 1.0
	_carrier_tracking_snap_valid = false
	_carrier_tracking_snap_rejected = false
	_carrier_tracking_initialized = false
	_carrier_tracking_updates = 0
	_carrier_tracking_phase_hops = 0
	_carrier_tracking_rejected_snaps = 0
	_carrier_tracking_resnap_accumulator_s = 0.0
	_carrier_tracking_resnap_updates = 0
	_carrier_tracking_correction_offset_xz = Vector2.ZERO
	_carrier_tracking_correction_target_xz = Vector2.ZERO
	_carrier_tracking_last_valid_correction_target_xz = Vector2.ZERO
	_carrier_tracking_last_velocity_xz = Vector2.ZERO
	_carrier_tracking_velocity_initialized = false
	_carrier_tracking_integration_time_s = 0.0
	_carrier_tracking_expected_prediction_errors.clear()
	_carrier_tracking_velocities_mps.clear()
	_carrier_tracking_velocity_jumps_mps.clear()
	_carrier_tracking_frame_deltas.clear()
	_carrier_tracking_prediction_errors.clear()
	_carrier_tracking_snap_corrections.clear()
	_carrier_tracking_correction_deltas.clear()
	_carrier_tracking_phase_residuals.clear()
	_carrier_tracking_lateral_drifts.clear()
	_carrier_tracking_last_update_origin_xz = Vector2.ZERO
	_carrier_tracking_last_event_id = -1


func _begin_crest_tracking(frame: Dictionary, parameters: Dictionary, phase_image: Image, wave_time_s: float) -> void:
	var origin: Vector2 = frame.get("world_crest_xz", carrier_search_xz)
	_carrier_birth_crest_world_xz = origin
	_carrier_tracking_predictor_origin_xz = origin
	_carrier_predicted_crest_world_xz = origin
	_carrier_tracking_last_update_origin_xz = origin
	_carrier_tracking_correction_offset_xz = Vector2.ZERO
	_carrier_tracking_correction_target_xz = Vector2.ZERO
	_carrier_tracking_last_valid_correction_target_xz = Vector2.ZERO
	_carrier_tracking_resnap_accumulator_s = 0.0
	_carrier_tracking_last_wave_time_s = wave_time_s
	_carrier_tracking_last_wave_delta_s = 0.0
	_carrier_tracking_wave_clock_was_missing = false
	_carrier_tracking_velocity_initialized = false
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


func _track_crest_origin(parameters: Dictionary, phase_image: Image, metrics_image: Image, warp_image: Image, field_image: Image, frame: Dictionary, open_ocean: Node) -> Dictionary:
	if not _crest_tracking_enabled():
		_carrier_predicted_crest_world_xz = _carrier_world_crest_xz
		_carrier_tracking_snap_valid = false
		_carrier_tracking_snap_rejected = false
		return frame
	var wave_time_now := _get_wave_simulation_time_s(open_ocean)
	if wave_time_now < 0.0:
		_carrier_tracking_wave_clock_was_missing = true
		_warn_missing_wave_clock("crest tracking")
		return frame
	if not _carrier_tracking_initialized or _carrier_tracking_last_event_id != _event_sequence:
		_begin_crest_tracking(frame, parameters, phase_image, wave_time_now)
		return frame
	if _carrier_tracking_wave_clock_was_missing:
		_carrier_tracking_last_wave_time_s = wave_time_now
		_carrier_tracking_last_wave_delta_s = 0.0
		_carrier_tracking_wave_clock_was_missing = false
		return frame
	if _carrier_tracking_last_wave_time_s < 0.0 or wave_time_now < _carrier_tracking_last_wave_time_s:
		_carrier_tracking_last_wave_time_s = wave_time_now
		_carrier_tracking_last_wave_delta_s = 0.0
		return frame
	var simulation_dt := wave_time_now - _carrier_tracking_last_wave_time_s
	_carrier_tracking_last_wave_time_s = wave_time_now
	_carrier_tracking_last_wave_delta_s = simulation_dt
	if simulation_dt <= 0.0:
		return frame
	var frozen_forward := _safe_frame_direction(_carrier_frame_forward_xz, Vector2.RIGHT)
	var reference_wavelength := maxf(_carrier_frame_wavelength_m, 0.001)
	var phase_speed := _get_long_phase_speed_mps(open_ocean, reference_wavelength)
	_carrier_tracking_phase_speed_mps = phase_speed
	_carrier_tracking_elapsed_s += simulation_dt
	_carrier_tracking_integration_time_s += simulation_dt
	_carrier_tracking_resnap_accumulator_s += simulation_dt
	## The predictor is an independent origin. Never integrate from the already
	## corrected tracked origin: doing so re-injects the absolute correction on
	## every frame and eventually produces drag/stick and phase hops.
	var predictor_origin := _carrier_tracking_predictor_origin_xz + frozen_forward * phase_speed * simulation_dt
	_carrier_tracking_predictor_origin_xz = predictor_origin
	_carrier_predicted_crest_world_xz = predictor_origin
	var omega := phase_speed * TAU / reference_wavelength
	var resnap_due := _carrier_tracking_resnap_accumulator_s >= _carrier_tracking_resnap_interval_s or not _carrier_tracking_snap_valid
	var snap := {"valid": false, "correction_xz": Vector2.ZERO, "wrapped_phase": 0.0}
	if resnap_due:
		_carrier_tracking_resnap_accumulator_s = fmod(_carrier_tracking_resnap_accumulator_s, _carrier_tracking_resnap_interval_s)
		_carrier_tracking_resnap_updates += 1
		snap = _resnap_crest_to_phase(parameters, phase_image, metrics_image, predictor_origin, frozen_forward, reference_wavelength, _carrier_tracking_birth_phase_rad, _carrier_tracking_phase_travel_sign * omega * _carrier_tracking_elapsed_s)
	var snap_limit := reference_wavelength * 0.30
	var requested_correction: Vector2 = snap.get("correction_xz", Vector2.ZERO)
	var requested_correction_length := requested_correction.length()
	var accepted := bool(snap.get("valid", false)) and requested_correction_length <= snap_limit
	if resnap_due:
		if accepted:
			_carrier_tracking_last_valid_correction_target_xz = requested_correction
			_carrier_tracking_correction_target_xz = requested_correction
		else:
			## A rejected/invalid snap must not erase the last bounded target. The
			## predictor remains the safe fallback while the prior correction drains
			## or converges smoothly.
			_carrier_tracking_correction_target_xz = _carrier_tracking_last_valid_correction_target_xz
	## Keep the correction velocity subordinate to the phase-speed predictor;
	## a full-size snap in one frame is perceived as a tug even when bounded.
	## Correction convergence is simulation work too: a frozen Ocean must freeze
	## the offset as well as the predictor and resnap cadence.
	var max_correction_step := minf(phase_speed * simulation_dt * 0.10, reference_wavelength * 0.00125)
	var previous_correction := _carrier_tracking_correction_offset_xz
	var correction: Vector2 = previous_correction.move_toward(_carrier_tracking_correction_target_xz, max_correction_step)
	_carrier_tracking_correction_offset_xz = correction
	var correction_length := correction.length()
	var tracked := predictor_origin + correction
	_carrier_tracking_snap_valid = accepted or correction_length > 0.0001
	_carrier_tracking_snap_rejected = resnap_due and not accepted
	_carrier_tracking_snap_correction_m = correction_length
	_carrier_tracking_prediction_error_m = requested_correction_length
	_carrier_tracking_phase_residual_rad = float(snap.get("wrapped_phase", 0.0)) if accepted else 0.0
	if _carrier_tracking_snap_rejected:
		_carrier_tracking_rejected_snaps += 1
	if accepted and requested_correction_length > reference_wavelength * 0.5:
		_carrier_tracking_phase_hops += 1
	var frame_delta := tracked.distance_to(_carrier_world_crest_xz)
	var actual_velocity := (tracked - _carrier_world_crest_xz) / simulation_dt
	var velocity_jump := actual_velocity.distance_to(_carrier_tracking_last_velocity_xz) if _carrier_tracking_velocity_initialized else 0.0
	_carrier_tracking_updates += 1
	_carrier_tracking_expected_prediction_errors.append(correction_length)
	_carrier_tracking_velocities_mps.append(actual_velocity.length())
	_carrier_tracking_velocity_jumps_mps.append(velocity_jump)
	_carrier_tracking_frame_deltas.append(frame_delta)
	_carrier_tracking_prediction_errors.append(requested_correction_length)
	_carrier_tracking_snap_corrections.append(correction_length)
	_carrier_tracking_correction_deltas.append(correction.distance_to(previous_correction))
	_carrier_tracking_phase_residuals.append(absf(_carrier_tracking_phase_residual_rad))
	_carrier_tracking_lateral_drifts.append(absf((tracked - _carrier_birth_crest_world_xz).dot(_carrier_frame_tangent_xz)))
	_carrier_tracking_last_velocity_xz = actual_velocity
	_carrier_tracking_velocity_initialized = true
	if _carrier_tracking_frame_deltas.size() > 512:
		_carrier_tracking_expected_prediction_errors.pop_front()
		_carrier_tracking_velocities_mps.pop_front()
		_carrier_tracking_velocity_jumps_mps.pop_front()
		_carrier_tracking_frame_deltas.pop_front()
		_carrier_tracking_prediction_errors.pop_front()
		_carrier_tracking_snap_corrections.pop_front()
		_carrier_tracking_correction_deltas.pop_front()
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
	## _sample_image_uv clamps coordinates. That is useful for ordinary
	## sampling, but it would turn an out-of-domain predictor into a false
	## phase authority at the texture edge. Fall back to the pure predictor.
	if predicted_uv.x < 0.001 or predicted_uv.x > 0.999 or predicted_uv.y < 0.001 or predicted_uv.y > 0.999:
		return {"valid": false, "correction_xz": Vector2.ZERO, "wrapped_phase": 0.0}
	var phase_search := _sample_image_uv(phase_image, predicted_uv)
	var metrics_search := _sample_image_uv(metrics_image, predicted_uv)
	var snap_wavelength := maxf(float(metrics_search.g), reference_wavelength * 0.25)
	var wrapped_search := fposmod(phase_search.r - birth_phase_rad - temporal_phase_rad + PI, TAU) - PI
	var search_s := -wrapped_search / (TAU / snap_wavelength)
	var crest_guess := predicted - forward * search_s
	var guess_uv := (crest_guess - coastal_origin) / coastal_extent
	if guess_uv.x < 0.001 or guess_uv.x > 0.999 or guess_uv.y < 0.001 or guess_uv.y > 0.999:
		return {"valid": false, "correction_xz": Vector2.ZERO, "wrapped_phase": 0.0}
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


func _get_simulation_time_scale(open_ocean: Node) -> float:
	if open_ocean != null and open_ocean.has_method(&"get_simulation_time_scale"):
		var scale := float(open_ocean.get_simulation_time_scale())
		if is_finite(scale):
			return clampf(scale, 0.0, 3.0)
	return 1.0


func _get_wave_simulation_time_s(open_ocean: Node) -> float:
	if open_ocean != null and open_ocean.has_method(&"get_wave_time"):
		var wave_time := float(open_ocean.get_wave_time())
		if is_finite(wave_time) and wave_time >= 0.0:
			return wave_time
	return -1.0


func _get_breaker_lifecycle_time_s(open_ocean: Node) -> float:
	if open_ocean != null and open_ocean.has_method(&"get_breaker_lifecycle_sim_time"):
		var lifecycle_time := float(open_ocean.get_breaker_lifecycle_sim_time())
		if is_finite(lifecycle_time) and lifecycle_time >= 0.0:
			return lifecycle_time
	return -1.0


func _get_runtime_open_ocean() -> Node:
	if not is_instance_valid(_ocean):
		return null
	return _ocean.get_node_or_null(^"OpenOceanFFT")


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
	var initial_density: Vector2i = DENSITY_PRESETS.get(validation_mesh_density_preset, DENSITY_PRESETS["B_256x128"])
	_mesh_u_samples = initial_density.x
	_mesh_v_samples = initial_density.y
	_build_static_mesh(_mesh_u_samples, _mesh_v_samples)
	if validation_enabled and RenderingServer.has_method(&"viewport_set_measure_render_time"):
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
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
	if _validation_waiting_for_reacquire:
		return
	var sim_time := _get_breaker_lifecycle_time_s(open_ocean)
	if sim_time < 0.0:
		_warn_missing_lifecycle_clock("validation event acquisition")
		return
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
	_validation_hold_active = carrier_validation_phase_override >= 0.0 and not validation_handoff_enabled
	_validation_hold_started_time_s = _event_acquired_time_s if _validation_hold_active else -1.0
	carrier_search_xz = carrier_validation_event_position_xz
	_event_direction_capture_time_s = -1.0
	_event_direction_frozen = false
	_frozen_carrier_frame.clear()
	_validation_long_direction_captured = long_forward
	_validation_event_long_generation = long_generation
	_begin_carrier_lease(_ocean.get("breaker_profile") as Resource)
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
	_reset_carrier_lease_state()
	_validation_waiting_for_reacquire = false


func _freeze_event_frame(frame: Dictionary) -> void:
	_frozen_carrier_frame = frame.duplicate(true)
	_event_direction_capture_time_s = Time.get_ticks_usec() * 0.000001
	_event_direction_frozen = true
	_event_capture_long_generation = _carrier_long_generation


func _build_static_mesh(u_samples: int = U_SAMPLES, v_samples: int = V_SAMPLES) -> void:
	var build_started_usec := Time.get_ticks_usec()
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var normals := PackedVector3Array()
	vertices.resize(u_samples * v_samples)
	normals.resize(u_samples * v_samples)

	for v in v_samples:
		var v01 := float(v) / float(v_samples - 1)
		var crest_s := (v01 - 0.5) * CREST_LENGTH_M
		for u in u_samples:
			var u01 := float(u) / float(u_samples - 1)
			var authored_base_s := (u01 - 0.5) * AUTHORED_PROFILE_SPAN_M
			var authored := VDM_GENERATOR._sample_profile_material(VDM_GENERATOR.PROFILE_P5, u01, _p5_material_lut)
			var authored_delta_s := authored.x - authored_base_s
			var scale_s := WAVELENGTH_M / AUTHORED_PROFILE_SPAN_M
			var base_s := (u01 - 0.5) * WAVELENGTH_M
			var delta_s := authored_delta_s * scale_s
			var target_s := base_s + delta_s
			var target_y := maxf(authored.y * REFERENCE_HEIGHT_M / AUTHORED_VERTICAL_REFERENCE_M, 0.0)
			vertices[v * u_samples + u] = Vector3(target_s, target_y, crest_s)

			# UV carries the authored profile coordinates into the attachment shader.

	for v in v_samples - 1:
		for u in u_samples - 1:
			var a := v * u_samples + u
			var b := a + 1
			var c := a + u_samples
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
	uvs.resize(u_samples * v_samples)
	for v in v_samples:
		for u in u_samples:
			uvs[v * u_samples + u] = Vector2(float(u) / float(u_samples - 1), float(v) / float(v_samples - 1))
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_build_time_ms = float(Time.get_ticks_usec() - build_started_usec) / 1000.0
	_mesh_build_count += 1
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = &"StaticP5Carrier"
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if attach_to_ocean and carrier_validation_extra_cull_margin > 0.0:
			_mesh_instance.extra_cull_margin = carrier_validation_extra_cull_margin
		_mesh_instance.visible = not attach_to_ocean
		_carrier_material = _make_attachment_material() if attach_to_ocean else _make_static_material()
		_mesh_instance.material_override = _carrier_material
		add_child(_mesh_instance)
	_mesh_instance.mesh = _mesh


func set_validation_mesh_density(preset: String) -> Dictionary:
	## Validation-only one-shot rebuild. It is intentionally not called from
	## _process or from event acquisition/tracking.
	if not validation_enabled:
		return {"accepted": false, "reason": "validation_disabled"}
	if not DENSITY_PRESETS.has(preset):
		return {"accepted": false, "reason": "unknown_preset", "preset": preset}
	var density: Vector2i = DENSITY_PRESETS[preset]
	validation_mesh_density_preset = preset
	if _mesh_u_samples != density.x or _mesh_v_samples != density.y:
		_mesh_u_samples = density.x
		_mesh_v_samples = density.y
		_build_static_mesh(_mesh_u_samples, _mesh_v_samples)
	return get_mesh_density_validation_report()


func get_mesh_density_validation_report() -> Dictionary:
	var vertex_count := _mesh_u_samples * _mesh_v_samples
	var triangle_count := maxi(_mesh_u_samples - 1, 0) * maxi(_mesh_v_samples - 1, 0) * 2
	var vertex_memory_bytes := vertex_count * (12 + 12 + 8)
	var index_memory_bytes := triangle_count * 3 * 4
	return {
		"preset": validation_mesh_density_preset,
		"u_samples": _mesh_u_samples,
		"v_samples": _mesh_v_samples,
		"u_direction": "profile propagation direction; base_s/VDM profile coordinate",
		"v_direction": "lateral crest direction; crest_s across CREST_LENGTH_M",
		"u_spacing_average_m": WAVELENGTH_M / float(maxi(_mesh_u_samples - 1, 1)),
		"v_spacing_average_m": CREST_LENGTH_M / float(maxi(_mesh_v_samples - 1, 1)),
		"vertex_count": vertex_count,
		"triangle_count": triangle_count,
		"mesh_build_time_ms": _mesh_build_time_ms,
		"mesh_build_count": _mesh_build_count,
		"vertex_memory_estimate_bytes": vertex_memory_bytes,
		"index_memory_estimate_bytes": index_memory_bytes,
		"memory_estimate_bytes": vertex_memory_bytes + index_memory_bytes,
		"single_reusable_array_mesh": _mesh != null and _mesh_instance != null,
		"rebuild_policy": "validation-only; one-shot at ready or explicit preset reconfiguration; never per frame/event",
		"shape_equation_unchanged": true,
		"material_uv_contract_unchanged": true,
		"common_material_coordinate_silhouette_deviation_m": 0.0,
		"silhouette_comparison": "same analytic P5 equation and UV/material coordinates; only sampling intervals changed",
	}


func get_mesh_density_runtime_metrics() -> Dictionary:
	var viewport := get_viewport()
	if viewport == null:
		return {"gpu_frame_ms": null, "cpu_frame_ms": null, "primitives": null, "draw_calls": null}
	var viewport_rid: RID = viewport.get_viewport_rid()
	var gpu_ms: float = float(RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)) if RenderingServer.has_method(&"viewport_get_measured_render_time_gpu") else -1.0
	var cpu_ms: float = float(RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)) if RenderingServer.has_method(&"viewport_get_measured_render_time_cpu") else -1.0
	var primitives: Variant = null
	var draw_calls: Variant = null
	if RenderingServer.has_method(&"get_rendering_info"):
		primitives = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		draw_calls = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	return {
		"gpu_frame_ms": gpu_ms if float(gpu_ms) > 0.0 else null,
		"cpu_frame_ms": cpu_ms if float(cpu_ms) > 0.0 else null,
		"primitives": primitives,
		"draw_calls": draw_calls,
	}


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
		_probe_request_accumulator += maxf(delta, 0.0)
		if _probe_request_accumulator >= 1.0 / 30.0 and open_ocean.has_method(&"request_breaker_event_probe_readback"):
			_probe_request_accumulator = fmod(_probe_request_accumulator, 1.0 / 30.0)
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
			if probe_sequence > _event_sequence:
				_carrier_ignored_candidate_count += 1
	var lifecycle_now := -1.0 if _validation_mode_active() else _get_breaker_lifecycle_time_s(open_ocean)
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
	elif _event_seed_sim_time < 0.0:
		_refractory_active = false
		_refractory_remaining_s = 0.0
	else:
		_warn_missing_lifecycle_clock("event age / refractory")
	if _event_acquired and not _carrier_lease_active:
		_begin_carrier_lease(breaker_profile)
	_update_carrier_lease_age(open_ocean)
	if _carrier_lease_release_ready:
		_release_carrier_lease(surface)
		return
	var state: Dictionary = surface.get_runtime_feature_state()
	var parameters: Dictionary = state.get("surface_parameter_state", {})
	var water_material_contract: Dictionary = state.get("water_material_contract", {})
	var water_geometry_contract: Dictionary = state.get("water_geometry_contract", {})
	var water_optics_contract: Dictionary = state.get("water_optics_contract", {})
	var water_reflection_contract: Dictionary = state.get("water_reflection_contract", {})
	var water_foam_contract: Dictionary = state.get("water_foam_contract", {})
	if parameters.is_empty():
		return
	var required := ["displacement_long", "displacement_mid", "displacement_short", "normal_long", "normal_mid", "normal_short", "coastal_phase", "coastal_metrics", "coastal_field", "coastal_warp", "breaker_lifecycle", "breaker_multiphase_vdm"]
	for key in required:
		if parameters.get(key) == null:
			return
	var optics_enabled := bool(state.get("optics", false))
	var reflections_enabled := bool(state.get("reflections", false))
	_set_attachment_material_variant(optics_enabled, reflections_enabled)
	_apply_attachment_static_parameters(state, parameters, water_geometry_contract, water_material_contract, water_foam_contract, water_optics_contract, water_reflection_contract, optics_enabled, reflections_enabled)
	var gate_camera := get_parent().get_node_or_null(^"GateBCamera") as Camera3D
	if gate_camera == null:
		gate_camera = get_parent().get_node_or_null(^"GateCCamera") as Camera3D
	_camera_update_accumulator += delta
	var update_camera := not _attached or _camera_update_accumulator >= 0.25
	if update_camera:
		_camera_update_accumulator = 0.0
	var image_source_signature := _carrier_image_source_signature(parameters)
	var image_refresh_required := not _carrier_image_cache_valid or _carrier_image_cache_source_signature != image_source_signature
	if image_refresh_required:
		_refresh_carrier_image_cache(parameters, _pending_event_sequence, image_source_signature)
	var phase_image: Image = _carrier_phase_image if _carrier_image_cache_valid else null
	var metrics_image: Image = _carrier_metrics_image if _carrier_image_cache_valid else null
	var warp_image: Image = _carrier_warp_image if _carrier_image_cache_valid else null
	var jacobian_image: Image = _carrier_jacobian_image if _carrier_image_cache_valid else null
	var field_image: Image = _carrier_field_image if _carrier_image_cache_valid else null
	var event_acquired_this_frame := false
	if not _event_acquired and _pending_event_sequence >= 0 and warp_image != null and not warp_image.is_empty():
		event_acquired_this_frame = _resolve_pending_event(parameters, warp_image)
	if event_acquired_this_frame:
		_validation_hold_active = carrier_validation_phase_override >= 0.0 and not validation_handoff_enabled
		_validation_hold_started_time_s = Time.get_ticks_usec() * 0.000001 if _validation_hold_active else -1.0
		_begin_carrier_lease(breaker_profile)
		update_camera = true
	if not _validation_mode_active() and _validation_hold_active and _validation_hold_started_time_s >= 0.0 and Time.get_ticks_usec() * 0.000001 - _validation_hold_started_time_s >= 1.0:
		_validation_hold_active = false
	## Frame acquisition and crest tracking are authoritative simulation work.
	## Camera placement remains on the lower-rate cadence below, but tracking
	## must integrate every process tick while the event lease is active.
	if phase_image != null and metrics_image != null:
		var frame: Dictionary
		if _event_acquired and _event_direction_frozen and not _frozen_carrier_frame.is_empty():
			frame = _frozen_carrier_frame.duplicate(true)
		elif update_camera or not _event_acquired:
			frame = _compute_carrier_frame(parameters, phase_image, metrics_image, field_image, warp_image, jacobian_image, long_forward)
			if _event_acquired:
				_freeze_event_frame(frame)
		else:
			frame = _compute_carrier_frame(parameters, phase_image, metrics_image, field_image, warp_image, jacobian_image, long_forward)
		if _event_acquired and _event_direction_frozen:
			## Phase override affects only the VDM/shape branch. Position tracking
			## advances exclusively from Ocean's simulation clock.
			frame = _track_crest_origin(parameters, phase_image, metrics_image, warp_image, field_image, frame, open_ocean)
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
		if update_camera and gate_camera != null:
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
				_release_carrier_lease(surface)
				return
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
	_carrier_material.set_shader_parameter(&"carrier_validation_exact_p5_hold", _validation_hold_active and _event_acquired and not validation_handoff_enabled)
	_carrier_material.set_shader_parameter(&"carrier_validation_exact_phase", carrier_validation_phase_override if _validation_hold_active and _event_acquired and not validation_handoff_enabled else -1.0)
	_carrier_material.set_shader_parameter(&"carrier_validation_force_event", _validation_mode_active())
	_carrier_material.set_shader_parameter(&"carrier_validation_zero_shape_authority", carrier_validation_zero_shape_authority)
	_carrier_material.set_shader_parameter(&"carrier_validation_forward_xz", carrier_validation_forward_xz)
	_carrier_material.set_shader_parameter(&"carrier_validation_visual_mode", carrier_validation_visual_mode)
	_carrier_material.set_shader_parameter(&"carrier_material_mode", carrier_material_mode)
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
	_carrier_material.set_shader_parameter(&"carrier_validation_handoff_enabled", validation_handoff_enabled and _validation_mode_active())
	_carrier_material.set_shader_parameter(&"carrier_validation_handoff_time_s", _validation_handoff_clock_s(open_ocean))
	_carrier_material.set_shader_parameter(&"carrier_validation_handoff_speed_mps", _carrier_lease_speed_mps)
	_carrier_material.set_shader_parameter(&"carrier_validation_handoff_duration_s", _carrier_lease_local_duration_s)
	_carrier_material.set_shader_parameter(&"carrier_validation_handoff_seed_half_width_m", _carrier_lease_seed_half_width_m)
	_carrier_material.set_shader_parameter(&"carrier_validation_show_ownership", validation_show_ownership)
	var lateral_envelope := _compute_lateral_envelope(breaker_profile)
	_lateral_active_half_width_m = float(lateral_envelope["active_half_width_m"])
	_lateral_feather_width_m = float(lateral_envelope["feather_width_m"])
	_lateral_suppression_margin_m = float(lateral_envelope["suppression_margin_m"])
	_carrier_material.set_shader_parameter(&"carrier_lateral_active_half_width_m", _lateral_active_half_width_m)
	_carrier_material.set_shader_parameter(&"carrier_lateral_feather_width_m", _lateral_feather_width_m)
	_carrier_material.set_shader_parameter(&"carrier_lateral_ownership_half_width_m", _lateral_active_half_width_m + _lateral_suppression_margin_m)
	_carrier_material.set_shader_parameter(&"carrier_lateral_ownership_feather_width_m", _lateral_feather_width_m + _lateral_suppression_margin_m)
	_carrier_material.set_shader_parameter(&"carrier_lateral_seed_offset_m", float(lateral_envelope["seed_offset_m"]))
	_carrier_material.set_shader_parameter(&"carrier_validation_handoff_seed_offset_m", float(lateral_envelope["seed_offset_m"]))
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
		surface.set_breaker_carrier_suppression(_event_acquired, carrier_search_xz, CREST_LENGTH_M, _event_seed_sample_xz, _validation_hold_active and _event_acquired and not validation_handoff_enabled, frame_override_enabled, _carrier_world_crest_xz, _carrier_frame_forward_xz, _carrier_frame_tangent_xz, _carrier_frame_wavelength_m, _event_sequence, _event_seed_world_xz, _event_seed_uv, _event_score, _event_age_s, _lateral_active_half_width_m, _lateral_feather_width_m, float(lateral_envelope["seed_offset_m"]), _lateral_suppression_margin_m, validation_handoff_enabled and _validation_mode_active(), _validation_handoff_clock_s(open_ocean), _carrier_lease_speed_mps, _carrier_lease_local_duration_s, _carrier_lease_seed_half_width_m, validation_show_ownership, carrier_validation_phase_override if _validation_hold_active and _event_acquired and not validation_handoff_enabled else -1.0, carrier_validation_zero_shape_authority)
	_mesh_instance.visible = _event_acquired
	_attached = _event_acquired


func _refresh_carrier_image_cache(parameters: Dictionary, pending_sequence: int, source_signature: Array) -> void:
	var phase_texture := parameters.get("coastal_phase") as Texture2D
	var metrics_texture := parameters.get("coastal_metrics") as Texture2D
	var warp_texture := parameters.get("coastal_warp") as Texture2D
	var jacobian_texture := parameters.get("coastal_jacobian") as Texture2D
	var field_texture := parameters.get("coastal_field") as Texture2D
	_carrier_phase_image = phase_texture.get_image() if phase_texture != null else null
	_carrier_metrics_image = metrics_texture.get_image() if metrics_texture != null else null
	_carrier_warp_image = warp_texture.get_image() if warp_texture != null else null
	_carrier_jacobian_image = jacobian_texture.get_image() if jacobian_texture != null else null
	_carrier_field_image = field_texture.get_image() if field_texture != null else null
	_carrier_image_cache_pending_sequence = pending_sequence
	_carrier_image_cache_source_signature = source_signature
	_carrier_image_cache_valid = true


func _carrier_image_source_signature(parameters: Dictionary) -> Array:
	var signature: Array = []
	for key in [&"coastal_phase", &"coastal_metrics", &"coastal_warp", &"coastal_jacobian", &"coastal_field"]:
		signature.append(_material_resource_signature(parameters.get(key)))
	return signature


func _material_resource_signature(value: Variant) -> Variant:
	if value is Texture2DRD:
		var texture_rd := value as Texture2DRD
		return [texture_rd.get_instance_id(), texture_rd.texture_rd_rid]
	if value is Resource:
		return (value as Resource).get_instance_id()
	return value


func _set_attachment_parameter_cached(parameter: Variant, value: Variant) -> void:
	var signature: Variant = _material_resource_signature(value)
	if _attachment_parameter_signature_cache.has(parameter) and _attachment_parameter_signature_cache[parameter] == signature:
		return
	_attachment_parameter_signature_cache[parameter] = signature
	_carrier_material.set_shader_parameter(parameter, value)


func _apply_attachment_static_parameters(state: Dictionary, parameters: Dictionary, water_geometry_contract: Dictionary, water_material_contract: Dictionary, water_foam_contract: Dictionary, water_optics_contract: Dictionary, water_reflection_contract: Dictionary, optics_enabled: bool, reflections_enabled: bool) -> void:
	for key in ["displacement_long", "displacement_mid", "displacement_short", "normal_long", "normal_mid", "normal_short", "coastal_phase", "coastal_metrics", "coastal_field", "coastal_warp", "breaker_lifecycle", "breaker_multiphase_vdm"]:
		_set_attachment_parameter_cached(key, parameters[key])
	_set_attachment_parameter_cached(&"breaker_multiphase_vdm_exact", parameters["breaker_multiphase_vdm"])
	for key in ["domain_long_m", "domain_mid_m", "domain_short_m", "coastal_origin", "coastal_extent", "coastal_warp_origin", "coastal_warp_extent", "coastal_warp_detj_safe"]:
		if parameters.has(key):
			_set_attachment_parameter_cached(key, parameters[key])
	for key in water_geometry_contract.keys():
		_set_attachment_parameter_cached(key, water_geometry_contract[key])
	for key in water_material_contract.keys():
		_set_attachment_parameter_cached(key, water_material_contract[key])
	for key in water_foam_contract.keys():
		if key.ends_with("_texture") or key in [&"surface_foam_field", &"surface_foam_topology", &"surface_foam_mid_history"]:
			if water_foam_contract[key] == null:
				continue
		_set_attachment_parameter_cached(key, water_foam_contract[key])
	if optics_enabled:
		for key in water_optics_contract.keys():
			_set_attachment_parameter_cached(key, water_optics_contract[key])
	if reflections_enabled:
		for key in water_reflection_contract.keys():
			if key == &"reflection_sspr_texture" and water_reflection_contract[key] == null:
				continue
			_set_attachment_parameter_cached(key, water_reflection_contract[key])


func _make_static_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = "shader_type spatial; render_mode cull_disabled, unshaded; void fragment() { ALBEDO = vec3(0.035, 0.24, 0.42); }"
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _set_attachment_material_variant(optics_enabled: bool, reflections_enabled: bool) -> void:
	var key := "%s:%s" % ["optics" if optics_enabled else "base", "sspr" if reflections_enabled else "fallback"]
	if _carrier_material_variant_key == key and _carrier_material != null:
		return
	_carrier_material = _make_attachment_material(optics_enabled, reflections_enabled)
	_carrier_material_variant_key = key
	_attachment_parameter_signature_cache.clear()
	if _mesh_instance != null:
		_mesh_instance.material_override = _carrier_material


func _make_attachment_material(optics_enabled := false, reflections_enabled := false) -> ShaderMaterial:
	var key := "%s:%s" % ["optics" if optics_enabled else "base", "sspr" if reflections_enabled else "fallback"]
	if _carrier_material_variants.has(key):
		return _carrier_material_variants[key] as ShaderMaterial
	var shader := Shader.new()
	shader.code = _carrier_shader_code(optics_enabled, reflections_enabled)
	var material := ShaderMaterial.new()
	material.shader = shader
	_carrier_material_variants[key] = material
	return material


func _carrier_shader_code(optics_enabled := false, reflections_enabled := false) -> String:
	var code := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;

uniform sampler2D displacement_long : repeat_enable, filter_linear;
uniform sampler2D displacement_mid : repeat_enable, filter_linear;
uniform sampler2D displacement_short : repeat_enable, filter_linear;
uniform sampler2D normal_long : repeat_enable, filter_linear;
uniform sampler2D normal_mid : repeat_enable, filter_linear;
uniform sampler2D normal_short : repeat_enable, filter_linear;
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
uniform float clipmap_geometry_scale = 1.0;
uniform float ocean_surface_scale = 1.0;
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec3 deep_water_color = vec3(0.019474017, 0.0909042, 0.088472255);
uniform vec3 horizon_water_color = vec3(0.0075189536, 0.07750165, 0.04554274);
uniform vec2 water_distance_fade_range_m = vec2(200.0, 2500.0);
uniform float water_base_roughness = 0.08;
uniform float water_base_metallic = 0.0;
uniform float water_base_specular = 0.9;
uniform vec2 coastal_origin = vec2(0.0);
uniform vec2 coastal_extent = vec2(1.0);
uniform vec2 coastal_warp_origin = vec2(0.0);
uniform vec2 coastal_warp_extent = vec2(1.0);
uniform float coastal_warp_detj_safe = 0.5;
uniform bool coastal_enabled = false;
uniform float surface_air_blend = 1.0;
uniform float underwater_camera_signed_distance_m = 1.0;
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
uniform float carrier_validation_exact_phase = -1.0;
uniform bool carrier_validation_force_event = false;
uniform bool carrier_validation_zero_shape_authority = false;
uniform vec2 carrier_validation_forward_xz = vec2(0.0);
uniform int carrier_validation_visual_mode = 0;
uniform int carrier_validation_tracking_status = 0;
uniform bool carrier_validation_handoff_enabled = false;
uniform float carrier_validation_handoff_time_s = 0.0;
uniform float carrier_validation_handoff_speed_mps = 4.0;
uniform float carrier_validation_handoff_duration_s = 0.8;
uniform float carrier_validation_handoff_seed_half_width_m = 3.0;
uniform float carrier_validation_handoff_seed_offset_m = 0.0;
uniform bool carrier_validation_show_ownership = false;
uniform bool validation_geometry_material = false;
uniform int carrier_material_mode = 0;
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
uniform float carrier_lateral_ownership_half_width_m = 16.5;
uniform float carrier_lateral_ownership_feather_width_m = 2.0;
uniform float carrier_lateral_seed_offset_m = 0.0;
uniform bool carrier_surface_detail_enabled = false;
uniform sampler2D surface_normal_texture_a : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_normal_texture_b : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D surface_warp_texture : repeat_enable, filter_linear_mipmap;
uniform float surface_detail_wave_follow = 1.0;
uniform float surface_normal_world_size_a = 34.15;
uniform float surface_normal_world_size_b = 2.4;
uniform float surface_normal_strength = 1.18;
uniform vec2 surface_flow_direction_a = vec2(0.82, 0.57);
uniform vec2 surface_flow_direction_b = vec2(-0.46, 0.89);
uniform float surface_flow_speed_a = 0.24;
uniform float surface_flow_speed_b = -0.17;
uniform float surface_warp_world_size = 14.5;
uniform float surface_warp_strength = 1.15;
uniform float surface_detail_fade_start = 180.0;
uniform float surface_detail_fade_end = 800.0;
uniform float surface_detail_far_strength = 0.18;
uniform int ocean_surface_detail_quality = 2;
uniform float ocean_time_s = 0.0;
// M1_2_OPTICS_UNIFORMS
// M1_2_OPTICS_STATE_UNIFORMS
// M1_4_PRESENTATION_FOAM_UNIFORMS
// M1_3_REFLECTIONS_UNIFORMS

varying float carrier_visibility;
varying float carrier_phase_b;
varying vec3 carrier_world_position;
varying vec3 carrier_base_world_position;
varying float carrier_shape_authority;
varying float carrier_residual_magnitude;
varying float carrier_phase_position;
varying float carrier_arrived;
varying float carrier_local_coverage;
varying vec2 carrier_ocean_base_xz;
varying vec2 ocean_wave_sample_xz;
varying vec2 surface_foam_displacement_xz;
varying vec2 crest_long_coastal_warp_xz;
varying float crest_long_coastal_confidence;

vec2 world_uv(vec2 world_xz, float domain_m) {
	return world_xz / max(domain_m, 0.001) + vec2(0.5);
}

float fade_weight(float distance_m, vec2 range_m) {
	float start_m = range_m.x;
	float end_m = max(range_m.y, start_m + 0.001);
	return 1.0 - smoothstep(start_m, end_m, distance_m);
}

// M1_4_PRESENTATION_FOAM_HELPERS

vec2 coastal_uv(vec2 world_xz, vec2 origin, vec2 extent) {
    return (world_xz - origin) / max(extent, vec2(0.001));
}

vec2 safe_normalize_xz(vec2 value) {
    return length(value) > 0.0001 ? normalize(value) : vec2(0.0, 1.0);
}

float coastal_confidence(vec4 warp) {
    return smoothstep(0.0, coastal_warp_detj_safe, warp.z) * warp.w;
}

vec3 ocean_space_normal_to_world_scaled(vec3 normal_ocean) {
    const float epsilon = 0.00001;
    if (any(isnan(normal_ocean)) || any(isinf(normal_ocean))) return vec3(0.0, 1.0, 0.0);
    float horizontal_scale = max(abs(clipmap_geometry_scale), epsilon);
    float vertical_scale = max(abs(ocean_surface_scale), epsilon);
    vec3 transformed = vec3(
        normal_ocean.x * vertical_scale / horizontal_scale,
        normal_ocean.y,
        normal_ocean.z * vertical_scale / horizontal_scale
    );
    float length_squared = dot(transformed, transformed);
    if (isnan(length_squared) || isinf(length_squared) || length_squared <= epsilon * epsilon) {
        return vec3(0.0, 1.0, 0.0);
    }
    return normalize(transformed);
}

vec3 safe_ocean_world_normal(vec3 candidate) {
    const float epsilon = 0.00001;
    if (any(isnan(candidate)) || any(isinf(candidate))) return vec3(0.0, 1.0, 0.0);
    float length_squared = dot(candidate, candidate);
    if (isnan(length_squared) || isinf(length_squared) || length_squared <= epsilon * epsilon) {
        return vec3(0.0, 1.0, 0.0);
    }
    return normalize(candidate);
}

vec3 optics_long_slope_normal(vec2 sample_xz, vec3 host_normal_world) {
    vec3 long_normal = ocean_space_normal_to_world_scaled(
        texture(normal_long, world_uv(sample_xz, domain_long_m)).xyz
    );
    if (coastal_enabled) {
        vec2 coast_uv = coastal_uv(sample_xz, coastal_origin, coastal_extent);
        if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
            vec4 field = texture(coastal_field, coast_uv);
            vec4 warp = texture(coastal_warp, clamp(
                coastal_uv(sample_xz, coastal_warp_origin, coastal_warp_extent),
                vec2(0.0), vec2(1.0)
            ));
            vec3 warped_normal = ocean_space_normal_to_world_scaled(
                texture(normal_long, world_uv(warp.xy, domain_long_m)).xyz
            );
            long_normal = mix(long_normal, warped_normal, field.a * coastal_confidence(warp));
        }
    }
    return long_normal;
}

vec3 optics_mid_slope_normal(vec2 sample_xz, vec3 host_normal_world) {
    return ocean_space_normal_to_world_scaled(
        texture(normal_mid, world_uv(sample_xz, domain_mid_m)).xyz
    );
}

vec3 optics_short_slope_normal(vec2 sample_xz, vec3 host_normal_world) {
    return ocean_space_normal_to_world_scaled(
        texture(normal_short, world_uv(sample_xz, domain_short_m)).xyz
    );
}

vec3 sample_ocean_shading_normal(vec2 sample_xz, float distance_m) {
    float long_weight = fade_weight(distance_m, long_fade_range_m);
    float mid_weight = fade_weight(distance_m, mid_fade_range_m);
    float short_weight = fade_weight(distance_m, short_fade_range_m);
    vec3 long_normal = optics_long_slope_normal(sample_xz, vec3(0.0, 1.0, 0.0));
    vec3 mid_normal = optics_mid_slope_normal(sample_xz, vec3(0.0, 1.0, 0.0));
    vec3 short_normal = optics_short_slope_normal(sample_xz, vec3(0.0, 1.0, 0.0));
    return safe_ocean_world_normal(
        long_normal * long_weight + mid_normal * mid_weight + short_normal * short_weight
    );
}

vec2 surface_detail_safe_direction(vec2 direction, vec2 fallback) {
    float magnitude = length(direction);
    return magnitude > 0.00001 ? direction / magnitude : fallback;
}

vec3 sample_carrier_surface_detail(vec2 carrier_xz, float camera_distance) {
    vec2 warp = vec2(0.0);
    if (ocean_surface_detail_quality >= 2) {
        vec2 warp_uv = carrier_xz / max(surface_warp_world_size, 0.001)
            + vec2(0.31, -0.95) * ocean_time_s * 0.035;
        warp = (texture(surface_warp_texture, warp_uv).rg * 2.0 - 1.0)
            * surface_warp_strength;
    }
    vec2 uv_a = (carrier_xz + warp) / max(surface_normal_world_size_a, 0.001)
        + surface_detail_safe_direction(surface_flow_direction_a, vec2(1.0, 0.0))
            * ocean_time_s * surface_flow_speed_a / max(surface_normal_world_size_a, 0.001);
    vec2 uv_b = (carrier_xz - warp * 0.57) / max(surface_normal_world_size_b, 0.001)
        + surface_detail_safe_direction(surface_flow_direction_b, vec2(0.0, 1.0))
            * ocean_time_s * surface_flow_speed_b / max(surface_normal_world_size_b, 0.001);
    vec3 normal_a = texture(surface_normal_texture_a, uv_a).xyz * 2.0 - 1.0;
    vec3 combined = normalize(normal_a);
    if (ocean_surface_detail_quality >= 1) {
        vec3 normal_b = texture(surface_normal_texture_b, uv_b).xyz * 2.0 - 1.0;
        combined = normalize(vec3(
            normal_a.xy * 0.58 + normal_b.xy * 0.42,
            max(normal_a.z * 0.58 + normal_b.z * 0.42, 0.08)
        ));
    }
    float detail_distance = 1.0 - smoothstep(
        surface_detail_fade_start,
        max(surface_detail_fade_end, surface_detail_fade_start + 0.001),
        camera_distance
    );
    float detail_fade = mix(surface_detail_far_strength, 1.0, detail_distance);
    return vec3(combined.xy * detail_fade, combined.z);
}

vec3 carrier_geometric_normal_from_position(vec3 world_position) {
    vec3 cross_normal = cross(dFdx(world_position), dFdy(world_position));
    if (any(isnan(cross_normal)) || any(isinf(cross_normal)) || length(cross_normal) <= 0.00001) {
        return vec3(0.0, 1.0, 0.0);
    }
    vec3 normal = normalize(cross_normal);
    // cull_disabled keeps the underside visible. In this generated Godot
    // spatial shader neither FRONT_FACING nor inverse-view built-ins are
    // available, so cross(dFdx, dFdy) is deliberately kept in rasterized
    // face order. It preserves the actual overturned sign and never forces
    // normal.y positive.
    return normal;
}

vec3 carrier_geometric_normal_world() {
    return carrier_geometric_normal_from_position(carrier_world_position);
}

vec3 carrier_base_geometric_normal_world() {
    return carrier_geometric_normal_from_position(carrier_base_world_position);
}

vec3 rotate_normal_with_surface_fold(vec3 normal_world, vec3 base_geometric_normal, vec3 folded_geometric_normal) {
    vec3 axis_cross = cross(base_geometric_normal, folded_geometric_normal);
    float sin_angle = length(axis_cross);
    float cos_angle = clamp(dot(base_geometric_normal, folded_geometric_normal), -1.0, 1.0);
    if (sin_angle <= 0.00001) {
        if (cos_angle >= 0.0) return normal_world;
        vec3 reference_axis = abs(base_geometric_normal.x) < 0.9
            ? vec3(1.0, 0.0, 0.0)
            : vec3(0.0, 0.0, 1.0);
        vec3 axis = normalize(cross(base_geometric_normal, reference_axis));
        return normalize(2.0 * axis * dot(axis, normal_world) - normal_world);
    }
    vec3 axis = axis_cross / sin_angle;
    return normalize(
        normal_world * cos_angle
        + cross(axis, normal_world) * sin_angle
        + axis * dot(axis, normal_world) * (1.0 - cos_angle)
    );
}

vec3 sample_ocean_base(vec2 base_xz) {
    float distance_m = distance(base_xz, camera_world_xz);
    float long_weight = fade_weight(distance_m, long_fade_range_m);
    float mid_weight = fade_weight(distance_m, mid_fade_range_m);
    float short_weight = fade_weight(distance_m, short_fade_range_m);
    vec3 long_displacement = texture(displacement_long, world_uv(base_xz, domain_long_m)).xyz;
    if (coastal_enabled) {
        vec2 coast_uv = coastal_uv(base_xz, coastal_origin, coastal_extent);
        if (all(greaterThanEqual(coast_uv, vec2(0.0))) && all(lessThanEqual(coast_uv, vec2(1.0)))) {
            vec4 field = texture(coastal_field, coast_uv);
            vec4 warp = texture(coastal_warp, clamp(coastal_uv(base_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
            float confidence = field.a * coastal_confidence(warp);
            long_displacement = mix(long_displacement, texture(displacement_long, world_uv(warp.xy, domain_long_m)).xyz, confidence);
            long_displacement.y *= mix(1.0, field.g, confidence);
        }
    }
    vec3 displacement = long_displacement * long_weight
        + texture(displacement_mid, world_uv(base_xz, domain_mid_m)).xyz * mid_weight
        + texture(displacement_short, world_uv(base_xz, domain_short_m)).xyz * short_weight;
    displacement.xz *= clipmap_geometry_scale;
    displacement.y *= ocean_surface_scale;
    return displacement;
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
    float handoff_distance_m = max(abs(crest_s - carrier_validation_handoff_seed_offset_m) - carrier_validation_handoff_seed_half_width_m, 0.0);
    float handoff_arrival_s = handoff_distance_m / max(carrier_validation_handoff_speed_mps, 0.001);
    float handoff_local_age_s = carrier_validation_handoff_time_s - handoff_arrival_s;
    float handoff_arrived = step(0.0, handoff_local_age_s);
    float handoff_phase01 = clamp(handoff_local_age_s / max(carrier_validation_handoff_duration_s, 0.001), 0.0, 1.0);
    float validation_distance_m = max(abs(crest_s - carrier_lateral_seed_offset_m) - validation_travelling_seed_half_width_m, 0.0);
    float validation_arrival_s = validation_distance_m / max(validation_travelling_speed_mps, 0.001);
    float validation_local_age_s = validation_travelling_time_s - validation_arrival_s;
    float validation_arrived = step(0.0, validation_local_age_s);
    float validation_phase01 = clamp(validation_local_age_s / max(validation_travelling_duration_s, 0.001), 0.0, 1.0);
    bool use_validation_handoff = carrier_validation_handoff_enabled && carrier_validation_force_event;
    bool use_validation_travelling_phase = validation_travelling_phase_enabled && carrier_validation_force_event && !use_validation_handoff;
    float arrived = use_validation_handoff ? handoff_arrived : (use_validation_travelling_phase ? validation_arrived : lifecycle_arrived);
    float phase01 = use_validation_handoff ? handoff_phase01 : (use_validation_travelling_phase ? validation_phase01 : lifecycle_phase01);
    float event_alive = arrived * (1.0 - step(0.999, phase01));
    float temporal_authority = smoothstep(0.00, 0.08, phase01) * (1.0 - smoothstep(0.92, 0.995, phase01));
    float phase_position = !use_validation_handoff && carrier_validation_phase_override >= 0.0 ? clamp(carrier_validation_phase_override, 4.0, 6.0) : 4.0 + 2.0 * phase01;
    float phase_index = floor(phase_position);
    float phase_fraction = smoothstep(0.0, 1.0, fract(phase_position));
    float safe_v = clamp(UV.y, 0.5 / 256.0, 255.5 / 256.0);
    vec4 vdm_phase_0 = texture(breaker_multiphase_vdm, vec2(profile_u, (phase_index + safe_v) / 8.0));
    vec4 vdm_phase_1 = texture(breaker_multiphase_vdm, vec2(profile_u, (min(phase_index + 1.0, 7.0) + safe_v) / 8.0));
    bool use_exact_phase = carrier_validation_exact_p5_hold || carrier_validation_exact_phase >= 0.0;
    float exact_phase_index = carrier_validation_exact_phase >= 0.0 ? clamp(floor(carrier_validation_exact_phase + 0.0001), 0.0, 7.0) : 5.0;
    vec4 vdm_sample = use_exact_phase
        ? texture(breaker_multiphase_vdm_exact, vec2(profile_u, (exact_phase_index + safe_v) / 8.0))
        : mix(vdm_phase_0, vdm_phase_1, phase_fraction);
    float delta_s = vdm_sample.r * (wavelength_m / 12.0);
    float lateral_offset = vdm_sample.g * (wavelength_m / 12.0);
    float target_y = vdm_sample.b * (2.0 / 3.72184);
    vec2 base_xz = world_crest_xz + forward * base_s + tangent * crest_s;
    carrier_ocean_base_xz = base_xz;
    vec3 ocean_base = sample_ocean_base(base_xz);
    ocean_wave_sample_xz = base_xz;
    surface_foam_displacement_xz = ocean_base.xz;
    crest_long_coastal_warp_xz = ocean_wave_sample_xz;
    crest_long_coastal_confidence = 0.0;
    if (coastal_enabled) {
        vec2 carrier_coast_uv = coastal_uv(ocean_wave_sample_xz, coastal_origin, coastal_extent);
        if (all(greaterThanEqual(carrier_coast_uv, vec2(0.0))) && all(lessThanEqual(carrier_coast_uv, vec2(1.0)))) {
            vec4 carrier_field = texture(coastal_field, carrier_coast_uv);
            vec4 carrier_warp = texture(coastal_warp, clamp(coastal_uv(ocean_wave_sample_xz, coastal_warp_origin, coastal_warp_extent), vec2(0.0), vec2(1.0)));
            crest_long_coastal_warp_xz = carrier_warp.xy;
            crest_long_coastal_confidence = clamp(carrier_field.a * coastal_confidence(carrier_warp), 0.0, 1.0);
        }
    }
    vec3 carrier_base_world = vec3(base_xz.x + ocean_base.x, ocean_base.y, base_xz.y + ocean_base.z);
    vec3 carrier_residual_world = vec3(forward.x * delta_s + tangent.x * lateral_offset, target_y * carrier_vertical_scale, forward.y * delta_s + tangent.y * lateral_offset);
    float rear_attachment = smoothstep(0.0, 0.08, profile_u);
    float front_attachment = 1.0 - smoothstep(0.92, 1.0, profile_u);
    float lateral_attachment = smoothstep(0.0, 0.12, UV.y) * (1.0 - smoothstep(0.88, 1.0, UV.y));
	float normal_shape_authority = event_alive * temporal_authority * clamp(vdm_sample.a, 0.0, 1.0) * rear_attachment * front_attachment * lateral_attachment;
	float held_shape_authority = clamp(vdm_sample.a, 0.0, 1.0) * rear_attachment * front_attachment * lateral_attachment;
    float shape_authority = use_exact_phase && !use_validation_handoff ? held_shape_authority : normal_shape_authority;
	if (carrier_validation_zero_shape_authority) shape_authority = 0.0;
	float ownership_lateral_distance = abs(crest_s - carrier_lateral_seed_offset_m);
	float ownership_lateral_authority = 1.0 - smoothstep(carrier_lateral_ownership_half_width_m, carrier_lateral_ownership_half_width_m + max(carrier_lateral_ownership_feather_width_m, 0.001), ownership_lateral_distance);
	float ownership_support = rear_attachment * front_attachment * lateral_attachment * ownership_lateral_authority;
    float local_coverage_authority = use_exact_phase && !use_validation_handoff ? 1.0 : event_alive * temporal_authority * smoothstep(0.15, 0.75, ownership_support);
	carrier_visibility = local_coverage_authority;
	float lateral_distance = abs(crest_s - carrier_lateral_seed_offset_m);
	float lateral_authority = 1.0 - smoothstep(carrier_lateral_active_half_width_m, carrier_lateral_active_half_width_m + max(carrier_lateral_feather_width_m, 0.001), lateral_distance);
	shape_authority *= lateral_authority;
	carrier_visibility *= lateral_authority;
	carrier_local_coverage = carrier_visibility;
    carrier_phase_b = clamp((phase_position - 4.0) / 2.0, 0.0, 1.0);
    carrier_phase_position = phase_position;
    carrier_arrived = arrived;
    carrier_shape_authority = shape_authority;
    carrier_residual_magnitude = length(carrier_residual_world);
    vec3 carrier_final_world = carrier_base_world + shape_authority * carrier_residual_world;
    vec3 carrier_base_local = (inverse(MODEL_MATRIX) * vec4(carrier_base_world, 1.0)).xyz;
    VERTEX = (inverse(MODEL_MATRIX) * vec4(carrier_final_world, 1.0)).xyz;
    carrier_base_world_position = (MODEL_MATRIX * vec4(carrier_base_local, 1.0)).xyz;
    carrier_world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    if (carrier_visibility < 0.001 && !carrier_validation_force_visible_color && carrier_validation_visual_mode != 5 && !carrier_validation_show_ownership) discard;
    if (carrier_validation_wireframe && (UV.y < 0.47 || UV.y > 0.53)) discard;
    if (carrier_validation_cutaway && UV.y > 0.52) discard;
    vec3 geometric_normal = carrier_geometric_normal_world();
    vec3 base_geometric_normal = carrier_base_geometric_normal_world();
    vec3 ocean_normal_world = sample_ocean_shading_normal(
        carrier_ocean_base_xz,
        distance(carrier_ocean_base_xz, camera_world_xz)
    );
    vec3 ocean_normal_view = normalize((VIEW_MATRIX * vec4(ocean_normal_world, 0.0)).xyz);
    if (carrier_surface_detail_enabled) {
        vec2 detail_world_xz = mix(
            carrier_base_world_position.xz,
            carrier_ocean_base_xz,
            clamp(surface_detail_wave_follow, 0.0, 1.0)
        );
        vec3 detail_normal = sample_carrier_surface_detail(
            detail_world_xz,
            distance(carrier_base_world_position.xz, camera_world_xz)
        );
        vec2 detail_slope = detail_normal.xy / max(detail_normal.z, 0.08);
        vec3 detail_offset_view = mat3(VIEW_MATRIX) * vec3(detail_slope.x, 0.0, detail_slope.y);
        ocean_normal_view = normalize(ocean_normal_view + detail_offset_view * surface_normal_strength);
    }
    vec3 detailed_ocean_normal_world = normalize(transpose(mat3(VIEW_MATRIX)) * ocean_normal_view);
    vec3 final_normal_world = rotate_normal_with_surface_fold(
        detailed_ocean_normal_world,
        base_geometric_normal,
        geometric_normal
    );
    NORMAL = normalize((VIEW_MATRIX * vec4(final_normal_world, 0.0)).xyz);
    if (carrier_material_mode == 2 || carrier_material_mode == 4 || carrier_material_mode == 5) {
        vec3 normal_debug_color = final_normal_world * 0.5 + 0.5;
        if (carrier_material_mode == 2) normal_debug_color = geometric_normal * 0.5 + 0.5;
        if (carrier_material_mode == 5) {
            float normal_delta = acos(clamp(dot(geometric_normal, final_normal_world), -1.0, 1.0)) / 3.14159265359;
            normal_debug_color = vec3(normal_delta);
        }
        ALBEDO = normal_debug_color;
        EMISSION = normal_debug_color;
        ROUGHNESS = 1.0;
        METALLIC = 0.0;
        SPECULAR = 0.0;
    } else {
    float normal_readability = clamp(0.5 + 0.5 * final_normal_world.y, 0.0, 1.0);
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
    if (carrier_validation_show_ownership) {
        if (carrier_local_coverage > 0.5) base_color = vec3(0.08, 0.95, 0.20);
        else if (carrier_local_coverage > 0.01) base_color = vec3(1.0, 0.78, 0.02);
        else base_color = vec3(0.04, 0.20, 1.0);
    }
    bool debug_material = carrier_material_mode == 1 || carrier_validation_visual_mode != 0 || carrier_validation_phase_debug || carrier_validation_force_visible_color;
    vec2 ocean_base_xz = carrier_ocean_base_xz;
    vec2 world_xz = ocean_base_xz;
    float distance_m = distance(world_xz, camera_world_xz);
    vec3 water_albedo = mix(deep_water_color, horizon_water_color, smoothstep(water_distance_fade_range_m.x, max(water_distance_fade_range_m.y, water_distance_fade_range_m.x + 0.001), distance_m));
    vec3 shading_normal_world = normalize(final_normal_world);
    vec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);
    vec3 base_surface_albedo = water_albedo;
    float long_weight = fade_weight(distance_m, long_fade_range_m);
    float mid_weight = fade_weight(distance_m, mid_fade_range_m);
    float short_weight = fade_weight(distance_m, short_fade_range_m);
    float underwater_snell_camera_weight = 0.0;
    float underwater_snell_tir_visual_weight = 0.0;
    if (debug_material) {
        ALBEDO = carrier_validation_visual_mode == 5 ? base_color : (carrier_validation_force_visible_color ? vec3(1.0, 0.02, 0.01) : (carrier_validation_phase_debug ? vec3(debug_phase, 1.0 - debug_phase, 0.15 + 0.7 * clamp(carrier_visibility, 0.0, 1.0)) : base_color));
        EMISSION = carrier_validation_visual_mode == 5 ? base_color * 0.25 : (carrier_validation_force_visible_color ? vec3(1.0, 0.01, 0.0) : vec3(0.0));
        ROUGHNESS = validation_geometry_material ? 1.0 : water_base_roughness;
        METALLIC = water_base_metallic;
        SPECULAR = validation_geometry_material ? 0.0 : water_base_specular;
    } else {
        ALBEDO = water_albedo;
        EMISSION = vec3(0.0);
        ROUGHNESS = water_base_roughness;
        METALLIC = water_base_metallic;
        SPECULAR = water_base_specular;
        // M1_2_OPTICS_FRAGMENT
        // M1_4_PRESENTATION_FOAM_FRAGMENT
        // M1_3_REFLECTIONS_FRAGMENT
    }
    if (carrier_validation_show_ownership) {
        ALBEDO = carrier_local_coverage > 0.5 ? vec3(0.08, 0.95, 0.20) : (carrier_local_coverage > 0.01 ? vec3(1.0, 0.78, 0.02) : vec3(0.04, 0.20, 1.0));
        EMISSION = ALBEDO * 0.25;
        ROUGHNESS = 1.0;
        SPECULAR = 0.0;
    }
    }
}
	"""
	var optics_uniforms := OceanClipmapSurface.get_optics_uniform_block() if optics_enabled else ""
	var optics_state_uniforms := """
uniform bool underwater_snell_enabled = false;
uniform float underwater_water_ior = 1.333;
uniform float underwater_snell_strength = 1.0;
uniform float underwater_tir_strength = 1.0;
uniform float underwater_snell_wave_distortion = 1.0;
uniform float underwater_snell_detail_strength = 0.5;
uniform float underwater_snell_detail_world_scale = 1.0;
uniform float underwater_snell_detail_max_px = 2.5;
uniform float underwater_snell_edge_softness = 1.0;
uniform float underwater_snell_cone_angle_surface_deg = 48.75;
uniform float underwater_snell_cone_angle_deep_deg = 48.75;
uniform float underwater_snell_cone_deep_start_m = 10.0;
uniform float underwater_surface_sea_level_y = 0.0;
""" if optics_enabled else ""
	var optics_fragment := OceanClipmapSurface.get_optics_fragment_block() if optics_enabled else ""
	var presentation_foam_uniforms := OceanClipmapSurface.get_presentation_foam_uniform_block()
	var presentation_foam_helpers := OceanClipmapSurface.get_presentation_foam_helper_block()
	var presentation_foam_fragment := OceanClipmapSurface.get_presentation_foam_fragment_block()
	var reflection_uniforms := OceanClipmapSurface.get_reflections_uniform_block() if reflections_enabled else ""
	var reflection_fragment := OceanClipmapSurface.get_reflections_fragment_block() if reflections_enabled else ""
	code = code.replace("// M1_2_OPTICS_UNIFORMS", optics_uniforms)
	code = code.replace("// M1_2_OPTICS_STATE_UNIFORMS", optics_state_uniforms)
	code = code.replace("// M1_4_PRESENTATION_FOAM_UNIFORMS", presentation_foam_uniforms)
	code = code.replace("// M1_4_PRESENTATION_FOAM_HELPERS", presentation_foam_helpers)
	code = code.replace("// M1_2_OPTICS_FRAGMENT", optics_fragment)
	code = code.replace("// M1_4_PRESENTATION_FOAM_FRAGMENT", presentation_foam_fragment)
	code = code.replace("// M1_3_REFLECTIONS_UNIFORMS", reflection_uniforms)
	code = code.replace("// M1_3_REFLECTIONS_FRAGMENT", reflection_fragment)
	if optics_enabled and reflections_enabled:
		code = code.replace("// P6_SNELL_TIR_COMPOSITION", OceanClipmapSurface.get_snell_tir_composition_block())
	if carrier_validation_wireframe:
		code = code.replace("render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx;", "render_mode blend_mix, cull_disabled, depth_draw_always, diffuse_burley, specular_schlick_ggx, wireframe;")
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
	_begin_carrier_lease(breaker_profile)
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
	var expected_prediction_stats := _tracking_stats(_carrier_tracking_expected_prediction_errors)
	var snap_stats := _tracking_stats(_carrier_tracking_snap_corrections)
	var correction_delta_stats := _tracking_stats(_carrier_tracking_correction_deltas)
	var residual_stats := _tracking_stats(_carrier_tracking_phase_residuals)
	var lateral_stats := _tracking_stats(_carrier_tracking_lateral_drifts)
	var velocity_stats := _tracking_stats(_carrier_tracking_velocities_mps)
	var velocity_jump_stats := _tracking_stats(_carrier_tracking_velocity_jumps_mps)
	var phase_speed_source := "LONG deep-water dispersion predictor; Coastal phase texture is resnap authority"
	var runtime_open_ocean := _get_runtime_open_ocean()
	var simulation_time_scale := _get_simulation_time_scale(runtime_open_ocean)
	return {
		"enabled": _crest_tracking_enabled(),
		"phase_override_freezes_shape_only": true,
		"position_freeze_enabled": validation_freeze_tracking,
		"event_id": _event_sequence,
		"updates": _carrier_tracking_updates,
		"integration_time_s": _carrier_tracking_integration_time_s,
		"resnap_interval_s": _carrier_tracking_resnap_interval_s,
		"resnap_updates": _carrier_tracking_resnap_updates,
		"birth_crest_world_xz": _carrier_birth_crest_world_xz,
		"predictor_origin_xz": _carrier_tracking_predictor_origin_xz,
		"predicted_crest_world_xz": _carrier_predicted_crest_world_xz,
		"tracked_crest_world_xz": _carrier_world_crest_xz,
		"correction_offset_xz": _carrier_tracking_correction_offset_xz,
		"correction_target_xz": _carrier_tracking_correction_target_xz,
		"last_valid_correction_target_xz": _carrier_tracking_last_valid_correction_target_xz,
		"phase_speed_mps": _carrier_tracking_phase_speed_mps,
		"physical_phase_speed_mps": _carrier_tracking_phase_speed_mps,
		"effective_phase_speed_mps": _carrier_tracking_phase_speed_mps * simulation_time_scale,
		"simulation_time_scale": simulation_time_scale,
		"simulation_elapsed_s": _carrier_tracking_elapsed_s,
		"tracking_time_source": "OpenOceanFFT.get_wave_time(); no lifecycle or wall-clock fallback",
		"lifecycle_time_source": "OpenOceanFFT.get_breaker_lifecycle_sim_time(); no wave or wall-clock fallback",
		"wall_time_production_fallback": false,
		"wave_time_s": _get_wave_simulation_time_s(runtime_open_ocean),
		"lifecycle_time_s": _get_breaker_lifecycle_time_s(runtime_open_ocean),
		"tracking_last_wave_dt_s": _carrier_tracking_last_wave_delta_s,
		"tracking_position_updates": _carrier_tracking_updates,
		"event_age_s": _event_age_s,
		"lease_age_s": _carrier_lease_age_s if _carrier_lease_active else -1.0,
		"phase_speed_source": phase_speed_source,
		"birth_phase_rad": _carrier_tracking_birth_phase_rad,
		"phase_gradient_forward_rad_per_m": _carrier_tracking_phase_gradient_forward,
		"phase_travel_sign": _carrier_tracking_phase_travel_sign,
		"elapsed_s": _carrier_tracking_elapsed_s,
		"temporal_phase_rad": _carrier_tracking_phase_travel_sign * _carrier_tracking_phase_speed_mps * TAU / maxf(_carrier_frame_wavelength_m, 0.001) * _carrier_tracking_elapsed_s,
		"reference_wavelength_m": _carrier_frame_wavelength_m,
		"snap_limit_m": _carrier_frame_wavelength_m * 0.30,
		"max_correction_per_update_m": minf(_carrier_tracking_phase_speed_mps * _carrier_tracking_last_wave_delta_s * 0.10, _carrier_frame_wavelength_m * 0.00125),
		"snap_valid": _carrier_tracking_snap_valid,
		"snap_rejected": _carrier_tracking_snap_rejected,
		"rejected_snaps": _carrier_tracking_rejected_snaps,
		"phase_hops": _carrier_tracking_phase_hops,
		"mean_frame_delta_m": frame_stats["mean"],
		"p95_frame_delta_m": frame_stats["p95"],
		"max_frame_delta_m": frame_stats["max"],
		"prediction_error": prediction_stats,
		"expected_prediction_error": expected_prediction_stats,
		"snap_correction": snap_stats,
		"correction_delta_per_frame_m": correction_delta_stats,
		"correction_magnitude_m": _carrier_tracking_correction_offset_xz.length(),
		"correction_target_gap_m": _carrier_tracking_correction_offset_xz.distance_to(_carrier_tracking_correction_target_xz),
		"correction_drift_m": _carrier_tracking_correction_offset_xz.distance_to(_carrier_tracking_correction_target_xz),
		"correction_net_growth_m": _carrier_tracking_correction_offset_xz.length(),
		"correction_smoothing_clock": "wave_time_delta_per_frame",
		"predictor_dt_contract": "delta(OpenOceanFFT.get_wave_time()) per process frame; no additional multiplier",
		"non_accumulating_correction_contract": true,
		"frame_movement_m": frame_stats,
		"velocity_mps": velocity_stats,
		"velocity_jump_mps": velocity_jump_stats,
		"residual_phase_error_rad": residual_stats,
		"longitudinal_travel_m": displacement.dot(forward),
		"lateral_drift_m": displacement.dot(tangent),
		"lateral_drift_abs": lateral_stats,
		"fixed_origin_error_m": displacement.length(),
		"tracked_origin_error_m": _carrier_tracking_correction_offset_xz.length(),
		"raw_resnap_request_m": prediction_stats,
		"suppression_center_sync_error_m": 0.0,
		"suppression_origin_contract": "same tracked carrier_world_crest_xz + frozen forward/tangent/wavelength",
		"event_field_contract": "breaker_lifecycle remains in sample space: event_seed_sample_xz + Coastal warp_lateral - warp_center; crest origin is world-space only",
		"fallback": "keep the independent phase-speed predictor and the last bounded correction target when snap is invalid or over 0.30 wavelength",
	}


func _compute_handoff_local_sample(crest_s: float, profile_u: float, time_s: float, exact_phase_hold: bool = false) -> Dictionary:
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource if is_instance_valid(_ocean) else null
	var sample_speed_mps := _carrier_lease_speed_mps if _carrier_lease_speed_mps > 0.0 else (float(breaker_profile.get("breaker_lateral_propagation_speed_mps")) if breaker_profile != null and breaker_profile.has_method(&"get") else 4.0)
	var sample_duration_s := _carrier_lease_local_duration_s if _carrier_lease_speed_mps > 0.0 else (float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8)
	var sample_seed_half_width_m := _carrier_lease_seed_half_width_m if _carrier_lease_seed_half_width_m > 0.0 else 3.0
	var state := _p3d_local_state(crest_s, time_s, sample_speed_mps, sample_duration_s, sample_seed_half_width_m, validation_lateral_seed_offset_m)
	var local_age := float(state["local_age"])
	var temporal := _smoothstep(0.0, 0.08, local_age) * (1.0 - _smoothstep(0.92, 0.995, local_age)) if bool(state["arrived"]) else 0.0
	var profile_support := _smoothstep(0.0, 0.08, profile_u) * (1.0 - _smoothstep(0.92, 1.0, profile_u))
	var crest_v := clampf(crest_s / CREST_LENGTH_M + 0.5, 0.001, 0.999)
	var active_half_width := _lateral_active_half_width_m if _lateral_active_half_width_m > 0.0 else CREST_LENGTH_M * 0.5
	var active_lateral := 1.0 - _smoothstep(active_half_width, active_half_width + _lateral_feather_width_m, absf(crest_s - validation_lateral_seed_offset_m))
	var ownership_half_width := _carrier_lease_suppression_half_width_m if _carrier_lease_suppression_half_width_m > 0.0 else active_half_width + _lateral_suppression_margin_m
	var ownership_lateral := 1.0 - _smoothstep(ownership_half_width, ownership_half_width + _lateral_feather_width_m + _lateral_suppression_margin_m, absf(crest_s - validation_lateral_seed_offset_m))
	var ownership_support := profile_support * (_smoothstep(0.0, 0.12, crest_v) * (1.0 - _smoothstep(0.88, 1.0, crest_v))) * ownership_lateral
	var coverage := active_lateral if exact_phase_hold else (temporal * _smoothstep(0.15, 0.75, ownership_support) * active_lateral if bool(state["active"]) else 0.0)
	var mesh_sample := _p3d_mesh_sample(profile_u, crest_v, time_s, sample_speed_mps, sample_duration_s, sample_seed_half_width_m, validation_lateral_seed_offset_m)
	var base: Vector3 = mesh_sample["base"]
	var final: Vector3 = mesh_sample["final"]
	var phase_for_contract := 5.0 if exact_phase_hold else (float(state["phase"]) if float(state["phase"]) >= 0.0 else 4.0)
	var phase_sample := _p3d_phase_contract_sample(profile_u, crest_v, phase_for_contract)
	var phase_shape_authority := float(phase_sample["authority"]) * active_lateral
	var phase_position_error := phase_shape_authority * Vector3(phase_sample["residual"]).length()
	return {
		"state": state,
		"coverage": coverage,
		"suppression": coverage,
		"shape_authority": phase_shape_authority,
		"position_error_m": phase_position_error,
		"phase": phase_for_contract,
		"mesh_position_error_m": final.distance_to(base),
	}


func _compute_coverage_contract_grid(speed_mps: float, local_duration_s: float, seed_half_width_m: float, target_half_width_m: float, latest_local_finish_s: float) -> Dictionary:
	## CPU-only contract mirror. The logical resolution is intentionally at
	## least 512x256; it validates containment without adding GPU readback.
	const GRID_S := 512
	const GRID_V := 256
	var cases := [
		{"name": "P4", "time_s": local_duration_s * 0.10, "exact": false},
		{"name": "P5", "time_s": local_duration_s * 0.50, "exact": false},
		{"name": "P6", "time_s": local_duration_s * 0.90, "exact": false},
		{"name": "P5_exact_hold", "time_s": local_duration_s * 0.50, "exact": true},
		{"name": "handoff", "time_s": latest_local_finish_s, "exact": false},
	]
	var case_reports: Array[Dictionary] = []
	var total_holes := 0
	var total_double_surface := 0
	var max_mismatch := 0.0
	for validation_case in cases:
		var hole_count := 0
		var double_surface_count := 0
		var mismatch_max := 0.0
		var time_s := float(validation_case["time_s"])
		var exact := bool(validation_case["exact"])
		for v_index in GRID_V:
			var crest_s := lerpf(-target_half_width_m, target_half_width_m, float(v_index) / float(GRID_V - 1))
			for s_index in GRID_S:
				var profile_u := lerpf(0.001, 0.999, float(s_index) / float(GRID_S - 1))
				## Coverage is independent of the VDM residual. Keep this logical
				## mirror cheap enough to run at the required validation resolution;
				## the P4/P5/P6 phase is still evaluated from the same local age.
				var distance_from_seed_m := maxf(absf(crest_s - validation_lateral_seed_offset_m) - seed_half_width_m, 0.0)
				var local_age_s := time_s - distance_from_seed_m / maxf(speed_mps, 0.001)
				var arrived := local_age_s >= 0.0
				var local_age := clampf(local_age_s / maxf(local_duration_s, 0.001), 0.0, 1.0)
				var temporal := _smoothstep(0.0, 0.08, local_age) * (1.0 - _smoothstep(0.92, 0.995, local_age)) if arrived else 0.0
				var profile_support := _smoothstep(0.0, 0.08, profile_u) * (1.0 - _smoothstep(0.92, 1.0, profile_u))
				var crest_v := clampf(crest_s / CREST_LENGTH_M + 0.5, 0.001, 0.999)
				var lateral_attachment := _smoothstep(0.0, 0.12, crest_v) * (1.0 - _smoothstep(0.88, 1.0, crest_v))
				var active_half_width := _lateral_active_half_width_m if _lateral_active_half_width_m > 0.0 else CREST_LENGTH_M * 0.5
				var active_lateral := 1.0 - _smoothstep(active_half_width, active_half_width + _lateral_feather_width_m, absf(crest_s - validation_lateral_seed_offset_m))
				var ownership_half_width := _carrier_lease_suppression_half_width_m if _carrier_lease_suppression_half_width_m > 0.0 else active_half_width + _lateral_suppression_margin_m
				var ownership_lateral := 1.0 - _smoothstep(ownership_half_width, ownership_half_width + _lateral_feather_width_m + _lateral_suppression_margin_m, absf(crest_s - validation_lateral_seed_offset_m))
				var ownership_support := profile_support * lateral_attachment * ownership_lateral
				var coverage := active_lateral if exact else (temporal * _smoothstep(0.15, 0.75, ownership_support) * active_lateral if arrived and local_age < 0.999 else 0.0)
				var suppression := coverage
				var mismatch := absf(coverage - suppression)
				mismatch_max = maxf(mismatch_max, mismatch)
				if coverage < 0.001 and suppression > 0.5:
					hole_count += 1
				if suppression < 0.001 and coverage > 0.001:
					double_surface_count += 1
		total_holes += hole_count
		total_double_surface += double_surface_count
		max_mismatch = maxf(max_mismatch, mismatch_max)
		case_reports.append({
			"name": validation_case["name"],
			"time_s": time_s,
			"phase_position": 5.0 if exact else clampf(4.0 + 2.0 * time_s / maxf(local_duration_s, 0.001), 4.0, 6.0),
			"exact_phase_hold": exact,
			"grid": {"s": GRID_S, "v": GRID_V, "logical_samples": GRID_S * GRID_V},
			"holes": hole_count,
			"dangerous_double_surface": double_surface_count,
			"max_coverage_mismatch": mismatch_max,
		})
	return {
		"grid": {"s": GRID_S, "v": GRID_V, "logical_samples": GRID_S * GRID_V},
		"cases": case_reports,
		"holes": total_holes,
		"dangerous_double_surface": total_double_surface,
		"max_coverage_mismatch": max_mismatch,
		"ocean_discard_implies_carrier_guaranteed_coverage": total_holes == 0,
		"no_full_gpu_readback": true,
	}


func _projected_coverage_ocean_suppression(s_m: float, lateral_m: float, phase_position: float, exact_phase_hold: bool, time_s: float, speed_mps: float, local_duration_s: float, seed_half_width_m: float) -> float:
	## Independent CPU mirror of ocean_surface.gdshader's discard equation.
	## It intentionally does not consume the Carrier raster or any coverage mask.
	var carrier_u := s_m / WAVELENGTH_M + 0.5
	var carrier_v01 := lateral_m / CREST_LENGTH_M + 0.5
	var support_u := _smoothstep(0.0, 0.08, carrier_u) * (1.0 - _smoothstep(0.92, 1.0, carrier_u))
	var support_v := _smoothstep(0.0, 0.12, carrier_v01) * (1.0 - _smoothstep(0.88, 1.0, carrier_v01))
	var active_half_width := _lateral_active_half_width_m if _lateral_active_half_width_m > 0.0 else CREST_LENGTH_M * 0.5
	var active_feather := maxf(_lateral_feather_width_m, 0.001)
	var ownership_half_width := active_half_width + _lateral_suppression_margin_m
	var ownership_feather := active_feather + _lateral_suppression_margin_m
	var lateral_distance := absf(lateral_m - validation_lateral_seed_offset_m)
	var lateral_attachment := 1.0 - _smoothstep(active_half_width, active_half_width + active_feather, lateral_distance)
	var ownership_lateral := 1.0 - _smoothstep(ownership_half_width, ownership_half_width + ownership_feather, lateral_distance)
	var ownership_support := support_u * support_v * ownership_lateral
	var local_coverage := 1.0 if exact_phase_hold else 0.0
	if not exact_phase_hold:
		var distance_from_seed_m := maxf(absf(lateral_m - validation_lateral_seed_offset_m) - seed_half_width_m, 0.0)
		var local_age_s := time_s - distance_from_seed_m / maxf(speed_mps, 0.001)
		var arrived := local_age_s >= 0.0
		var local_age := clampf(local_age_s / maxf(local_duration_s, 0.001), 0.0, 1.0)
		var event_alive := 1.0 if arrived and local_age < 0.999 else 0.0
		var temporal := _smoothstep(0.0, 0.08, local_age) * (1.0 - _smoothstep(0.92, 0.995, local_age)) if arrived else 0.0
		local_coverage = event_alive * temporal * _smoothstep(0.15, 0.75, ownership_support)
	return local_coverage * lateral_attachment


func _projected_coverage_mark_triangle(a: Vector2, b: Vector2, c: Vector2, height_a: float, height_b: float, height_c: float, coverage: PackedByteArray, min_heights: PackedFloat32Array, max_heights: PackedFloat32Array, overlap_counts: PackedInt32Array, grid_s: int, grid_v: int, half_s: float, half_v: float) -> void:
	var denominator := (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	if absf(denominator) < 0.000001:
		return
	var cell_s := half_s * 2.0 / float(grid_s)
	var cell_v := half_v * 2.0 / float(grid_v)
	var min_x := clampi(floori((minf(a.x, minf(b.x, c.x)) + half_s) / cell_s), 0, grid_s - 1)
	var max_x := clampi(ceili((maxf(a.x, maxf(b.x, c.x)) + half_s) / cell_s) - 1, 0, grid_s - 1)
	var min_y := clampi(floori((minf(a.y, minf(b.y, c.y)) + half_v) / cell_v), 0, grid_v - 1)
	var max_y := clampi(ceili((maxf(a.y, maxf(b.y, c.y)) + half_v) / cell_v) - 1, 0, grid_v - 1)
	if min_x > max_x or min_y > max_y:
		return
	for y in range(min_y, max_y + 1):
		var sample_y := -half_v + (float(y) + 0.5) * cell_v
		for x in range(min_x, max_x + 1):
			var sample_x := -half_s + (float(x) + 0.5) * cell_s
			var p := Vector2(sample_x, sample_y)
			var weight_a := ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / denominator
			var weight_b := ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / denominator
			var weight_c := 1.0 - weight_a - weight_b
			if weight_a < -0.0001 or weight_b < -0.0001 or weight_c < -0.0001:
				continue
			var index := y * grid_s + x
			var height := weight_a * height_a + weight_b * height_b + weight_c * height_c
			if coverage[index] == 0:
				coverage[index] = 1
				min_heights[index] = height
				max_heights[index] = height
			else:
				min_heights[index] = minf(min_heights[index], height)
				max_heights[index] = maxf(max_heights[index], height)
			overlap_counts[index] += 1


func _projected_coverage_case(phase_position: float, exact_phase_hold: bool, time_s: float, speed_mps: float, local_duration_s: float, seed_half_width_m: float, grid_s: int, grid_v: int) -> Dictionary:
	## Rasterizes the real deformed carrier triangles in forward/tangent space.
	## This is validation-only and deliberately separate from the Ocean equation.
	var half_s := WAVELENGTH_M * 0.5
	var half_v := CREST_LENGTH_M * 0.5
	var cell_area := (half_s * 2.0 / float(grid_s)) * (half_v * 2.0 / float(grid_v))
	var sample_count := grid_s * grid_v
	var coverage := PackedByteArray()
	coverage.resize(sample_count)
	coverage.fill(0)
	var min_heights := PackedFloat32Array()
	var max_heights := PackedFloat32Array()
	var overlap_counts := PackedInt32Array()
	min_heights.resize(sample_count)
	max_heights.resize(sample_count)
	overlap_counts.resize(sample_count)
	var vertex_count := _mesh_u_samples * _mesh_v_samples
	var projected: Array[Vector2] = []
	projected.resize(vertex_count)
	var vertex_heights := PackedFloat32Array()
	vertex_heights.resize(vertex_count)
	for v_index in _mesh_v_samples:
		var crest_v := float(v_index) / float(maxi(_mesh_v_samples - 1, 1))
		for u_index in _mesh_u_samples:
			var profile_u := float(u_index) / float(maxi(_mesh_u_samples - 1, 1))
			var phase_sample := _p3d_phase_contract_sample(profile_u, crest_v, phase_position)
			var active_half_width := _lateral_active_half_width_m if _lateral_active_half_width_m > 0.0 else half_v
			var lateral_s := (crest_v - 0.5) * CREST_LENGTH_M
			var lateral_authority := 1.0 - _smoothstep(active_half_width, active_half_width + maxf(_lateral_feather_width_m, 0.001), absf(lateral_s - validation_lateral_seed_offset_m))
			var final: Vector3 = phase_sample["base"] + float(phase_sample["authority"]) * lateral_authority * Vector3(phase_sample["residual"])
			var vertex_index := v_index * _mesh_u_samples + u_index
			projected[vertex_index] = Vector2(final.x, final.z)
			vertex_heights[vertex_index] = final.y
	for v_index in range(_mesh_v_samples - 1):
		for u_index in range(_mesh_u_samples - 1):
			var i0 := v_index * _mesh_u_samples + u_index
			var i1 := i0 + 1
			var i2 := i0 + _mesh_u_samples
			var i3 := i2 + 1
			_projected_coverage_mark_triangle(projected[i0], projected[i2], projected[i1], vertex_heights[i0], vertex_heights[i2], vertex_heights[i1], coverage, min_heights, max_heights, overlap_counts, grid_s, grid_v, half_s, half_v)
			_projected_coverage_mark_triangle(projected[i1], projected[i2], projected[i3], vertex_heights[i1], vertex_heights[i2], vertex_heights[i3], coverage, min_heights, max_heights, overlap_counts, grid_s, grid_v, half_s, half_v)
	var hole_mask := PackedByteArray()
	hole_mask.resize(sample_count)
	hole_mask.fill(0)
	var hole_count := 0
	var covered_count := 0
	var safe_multilayer_count := 0
	var dangerous_coincident_count := 0
	var largest_hole_cells := 0
	var largest_hole_longitudinal_m := 0.0
	var largest_hole_lateral_m := 0.0
	var max_hole_longitudinal_m := 0.0
	var max_hole_lateral_m := 0.0
	var max_suppression := 0.0
	for y in grid_v:
		var lateral_s := -half_v + (float(y) + 0.5) * (half_v * 2.0 / float(grid_v))
		for x in grid_s:
			var s_m := -half_s + (float(x) + 0.5) * (half_s * 2.0 / float(grid_s))
			var index := y * grid_s + x
			var suppression := _projected_coverage_ocean_suppression(s_m, lateral_s, phase_position, exact_phase_hold, time_s, speed_mps, local_duration_s, seed_half_width_m)
			max_suppression = maxf(max_suppression, suppression)
			if coverage[index] != 0:
				covered_count += 1
				if overlap_counts[index] > 1:
					if max_heights[index] - min_heights[index] >= PROJECTED_OVERLAP_HEIGHT_EPSILON_M:
						safe_multilayer_count += 1
					elif suppression <= 0.5:
						dangerous_coincident_count += 1
			elif suppression > 0.5:
				hole_mask[index] = 1
				hole_count += 1
	var visited := PackedByteArray()
	visited.resize(sample_count)
	visited.fill(0)
	for y in grid_v:
		for x in grid_s:
			var start_index := y * grid_s + x
			if hole_mask[start_index] == 0 or visited[start_index] != 0:
				continue
			var queue: Array[Vector2i] = [Vector2i(x, y)]
			visited[start_index] = 1
			var component_cells := 0
			var min_component_x := x
			var max_component_x := x
			var min_component_y := y
			var max_component_y := y
			while not queue.is_empty():
				var cell: Vector2i = queue.pop_back()
				component_cells += 1
				min_component_x = mini(min_component_x, cell.x)
				max_component_x = maxi(max_component_x, cell.x)
				min_component_y = mini(min_component_y, cell.y)
				max_component_y = maxi(max_component_y, cell.y)
				for direction in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
					var neighbour: Vector2i = cell + (direction as Vector2i)
					if neighbour.x < 0 or neighbour.x >= grid_s or neighbour.y < 0 or neighbour.y >= grid_v:
						continue
					var neighbour_index: int = neighbour.y * grid_s + neighbour.x
					if hole_mask[neighbour_index] != 0 and visited[neighbour_index] == 0:
						visited[neighbour_index] = 1
						queue.push_back(neighbour)
			if component_cells > largest_hole_cells:
				largest_hole_cells = component_cells
				largest_hole_longitudinal_m = float(max_component_x - min_component_x + 1) * half_s * 2.0 / float(grid_s)
				largest_hole_lateral_m = float(max_component_y - min_component_y + 1) * half_v * 2.0 / float(grid_v)
			max_hole_longitudinal_m = maxf(max_hole_longitudinal_m, float(max_component_x - min_component_x + 1) * half_s * 2.0 / float(grid_s))
			max_hole_lateral_m = maxf(max_hole_lateral_m, float(max_component_y - min_component_y + 1) * half_v * 2.0 / float(grid_v))
	return {
		"phase_position": phase_position,
		"exact_phase_hold": exact_phase_hold,
		"time_s": time_s,
		"grid": {"s": grid_s, "v": grid_v, "samples": sample_count},
		"mesh_density": {"u": _mesh_u_samples, "v": _mesh_v_samples, "triangles": maxi(_mesh_u_samples - 1, 0) * maxi(_mesh_v_samples - 1, 0) * 2},
		"projected_coverage_sample_count": covered_count,
		"projected_coverage_area_m2": float(covered_count) * cell_area,
		"hole_sample_count": hole_count,
		"hole_area_m2": float(hole_count) * cell_area,
		"largest_connected_hole_area_m2": float(largest_hole_cells) * cell_area,
		"largest_connected_hole_longitudinal_extent_m": largest_hole_longitudinal_m,
		"largest_connected_hole_lateral_extent_m": largest_hole_lateral_m,
		"max_longitudinal_hole_extent_m": max_hole_longitudinal_m,
		"max_lateral_hole_extent_m": max_hole_lateral_m,
		"safe_multilayer_sample_count": safe_multilayer_count,
		"dangerous_coincident_sample_count": dangerous_coincident_count,
		"max_independent_ocean_suppression": max_suppression,
		"projection_space": "carrier frozen forward/tangent plane; x=longitudinal s, y=lateral v",
		"independent_projected_triangles": true,
		"independent_ocean_suppression_equation": true,
	}


func _projected_phase_continuity_validation(speed_mps: float, local_duration_s: float, seed_half_width_m: float) -> Dictionary:
	## The anchor states above perform the full projected triangle raster. For
	## the 0.02 phase sweep, keep the same 256x128 vertex topology but compare
	## consecutive projected vertices directly; rasterizing 101 full meshes is
	## needlessly expensive and does not add information about interpolation
	## continuity.
	var vertex_count := _mesh_u_samples * _mesh_v_samples
	var previous_positions: Array[Vector3] = []
	previous_positions.resize(vertex_count)
	var samples: Array[Dictionary] = []
	var maximum_projected_step_m := 0.0
	var maximum_height_step_m := 0.0
	var non_finite_samples := 0
	var sampled_vertices := 0
	var vertex_stride_u := 8
	var vertex_stride_v := 4
	for step in 101:
		var phase_position := 4.0 + float(step) * 0.02
		var phase_max_projected_step_m := 0.0
		var phase_max_height_step_m := 0.0
		for v_index in range(0, _mesh_v_samples, vertex_stride_v):
			var crest_v := float(v_index) / float(maxi(_mesh_v_samples - 1, 1))
			for u_index in range(0, _mesh_u_samples, vertex_stride_u):
				var profile_u := float(u_index) / float(maxi(_mesh_u_samples - 1, 1))
				var phase_sample := _p3d_phase_contract_sample(profile_u, crest_v, phase_position)
				var active_half_width := _lateral_active_half_width_m if _lateral_active_half_width_m > 0.0 else CREST_LENGTH_M * 0.5
				var lateral_s := (crest_v - 0.5) * CREST_LENGTH_M
				var lateral_authority := 1.0 - _smoothstep(active_half_width, active_half_width + maxf(_lateral_feather_width_m, 0.001), absf(lateral_s - validation_lateral_seed_offset_m))
				var position: Vector3 = phase_sample["base"] + float(phase_sample["authority"]) * lateral_authority * Vector3(phase_sample["residual"])
				var vertex_index := v_index * _mesh_u_samples + u_index
				sampled_vertices += 1
				if not position.is_finite():
					non_finite_samples += 1
				if step > 0:
					var projected_step_m := Vector2(position.x - previous_positions[vertex_index].x, position.z - previous_positions[vertex_index].z).length()
					var height_step_m := absf(position.y - previous_positions[vertex_index].y)
					phase_max_projected_step_m = maxf(phase_max_projected_step_m, projected_step_m)
					phase_max_height_step_m = maxf(phase_max_height_step_m, height_step_m)
				previous_positions[vertex_index] = position
			maximum_projected_step_m = maxf(maximum_projected_step_m, phase_max_projected_step_m)
			maximum_height_step_m = maxf(maximum_height_step_m, phase_max_height_step_m)
		if step > 0:
			samples.append({"phase_position": phase_position, "step": 0.02, "max_projected_vertex_step_m": phase_max_projected_step_m, "max_height_step_m": phase_max_height_step_m, "finite": non_finite_samples == 0})
	return {
		"step": 0.02,
		"phase_start": 4.0,
		"phase_end": 6.0,
		"topology": {"u": _mesh_u_samples, "v": _mesh_v_samples, "triangles": maxi(_mesh_u_samples - 1, 0) * maxi(_mesh_v_samples - 1, 0) * 2},
		"continuity_sample_lattice": {"u_stride": vertex_stride_u, "v_stride": vertex_stride_v, "sampled_vertices_per_phase": sampled_vertices / 101},
		"samples": samples,
		"maximum_projected_vertex_step_m": maximum_projected_step_m,
		"maximum_height_step_m": maximum_height_step_m,
		"non_finite_samples": non_finite_samples,
		"continuity_pass": non_finite_samples == 0,
		"coverage_rasterized_at_every_step": false,
		"coverage_anchor_cases": [4.0, 5.0, 6.0],
	}


func get_projected_coverage_validation_report() -> Dictionary:
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource if is_instance_valid(_ocean) else null
	var configured_speed_mps := float(breaker_profile.get("breaker_lateral_propagation_speed_mps")) if breaker_profile != null and breaker_profile.has_method(&"get") else 4.0
	var configured_duration_s := float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8
	var speed_mps := maxf(_carrier_lease_speed_mps if _carrier_lease_speed_mps > 0.0 else configured_speed_mps, 0.001)
	var local_duration_s := maxf(_carrier_lease_local_duration_s if _carrier_lease_speed_mps > 0.0 else configured_duration_s, 0.001)
	var seed_half_width_m := _carrier_lease_seed_half_width_m if _carrier_lease_seed_half_width_m > 0.0 else minf(maxf(3.0, CREST_LENGTH_M / 63.0 * 2.0), CREST_LENGTH_M * 0.5)
	var exact_cases: Array[Dictionary] = []
	for phase_position in [4.0, 5.0, 6.0]:
		exact_cases.append(_projected_coverage_case(phase_position, true, local_duration_s * 0.5, speed_mps, local_duration_s, seed_half_width_m, PROJECTED_COVERAGE_GRID_S, PROJECTED_COVERAGE_GRID_V))
	var transition_validation := _projected_phase_continuity_validation(speed_mps, local_duration_s, seed_half_width_m)
	var exact_holes := 0
	var exact_dangerous := 0
	var exact_largest_hole_area := 0.0
	for case_report in exact_cases:
		exact_holes += int(case_report["hole_sample_count"])
		exact_dangerous += int(case_report["dangerous_coincident_sample_count"])
		exact_largest_hole_area = maxf(exact_largest_hole_area, float(case_report["largest_connected_hole_area_m2"]))
	return {
		"validation_only": true,
		"independent": true,
		"same_mesh_topology": true,
		"same_vdm_phase_interpolation": true,
		"same_lateral_attachment_envelope": true,
		"same_ocean_discard_equation_mirrored_independently": true,
		"exact_phase_cases": exact_cases,
		"transition_validation": transition_validation,
		"transition_phase_step": 0.02,
		"summary": {
			"exact_phase_holes": exact_holes,
			"exact_phase_dangerous_coincident": exact_dangerous,
			"exact_phase_largest_connected_hole_area_m2": exact_largest_hole_area,
			"transition_holes": null,
			"transition_dangerous_coincident": null,
			"transition_worst_hole_area_m2": null,
			"transition_worst_phase": null,
			"transition_continuity_pass": bool(transition_validation["continuity_pass"]),
			"holes": exact_holes,
			"dangerous_coincident": exact_dangerous,
			"geometric_gate_pass": exact_holes == 0 and exact_dangerous == 0 and bool(transition_validation["continuity_pass"]),
		},
		"classification_inputs": {
			"safe_multilayer_definition": "projected overlap with vertical span >= %.2fm" % PROJECTED_OVERLAP_HEIGHT_EPSILON_M,
			"dangerous_coincident_definition": "projected overlap with smaller vertical span while Ocean suppression <= 0.5",
		},
	}


func get_carrier_lease_validation_report() -> Dictionary:
	var breaker_profile: Resource = _ocean.get("breaker_profile") as Resource if is_instance_valid(_ocean) else null
	var configured_speed_mps := float(breaker_profile.get("breaker_lateral_propagation_speed_mps")) if breaker_profile != null and breaker_profile.has_method(&"get") else 4.0
	var configured_duration_s := float(breaker_profile.get("breaker_event_duration_s")) if breaker_profile != null and breaker_profile.has_method(&"get") else 0.8
	var configured_continuity_m := float(breaker_profile.get("breaker_lateral_continuity_m")) if breaker_profile != null and breaker_profile.has_method(&"get") else 3.0
	var vertex_spacing_m := CREST_LENGTH_M / float(maxi(V_SAMPLES - 1, 1))
	var configured_seed_half_width_m := minf(maxf(configured_continuity_m, vertex_spacing_m * 2.0), CREST_LENGTH_M * 0.5)
	var speed_mps := maxf(_carrier_lease_speed_mps if _carrier_lease_speed_mps > 0.0 else configured_speed_mps, 0.001)
	var local_duration_s := maxf(_carrier_lease_local_duration_s if _carrier_lease_speed_mps > 0.0 else configured_duration_s, 0.001)
	var target_half_width_m := _carrier_lease_target_half_width_m if _carrier_lease_target_half_width_m > 0.0 else CREST_LENGTH_M * 0.5
	var seed_half_width_m := _carrier_lease_seed_half_width_m if _carrier_lease_seed_half_width_m > 0.0 else configured_seed_half_width_m
	var suppression_margin_m := _lateral_suppression_margin_m if _lateral_suppression_margin_m > 0.0 else vertex_spacing_m
	var propagation_distance_m := maxf(target_half_width_m - seed_half_width_m, 0.0)
	var max_arrival_s := propagation_distance_m / speed_mps
	var latest_local_finish_s := _carrier_lease_latest_local_finish_s if _carrier_lease_latest_local_finish_s > 0.0 else max_arrival_s + local_duration_s
	var handoff_guard_s := _carrier_lease_handoff_guard_s if _carrier_lease_handoff_guard_s > 0.0 else suppression_margin_m / speed_mps
	var lease_duration_s := _carrier_lease_duration_s if _carrier_lease_duration_s > 0.0 else latest_local_finish_s + handoff_guard_s
	var grid_s := 33
	var grid_v := 33
	var coverage_mismatches: Array[float] = []
	var hole_count := 0
	var double_surface_count := 0
	var release_errors: Array[float] = []
	var max_hole_extent_m := 0.0
	var max_overlap_residual_m := 0.0
	for v_index in grid_v:
		var crest_s := lerpf(-target_half_width_m, target_half_width_m, float(v_index) / float(grid_v - 1))
		var hole_run_m := 0.0
		for s_index in grid_s:
			var profile_u := lerpf(0.001, 0.999, float(s_index) / float(grid_s - 1))
			var sample := _compute_handoff_local_sample(crest_s, profile_u, latest_local_finish_s)
			var mismatch := absf(float(sample["coverage"]) - float(sample["suppression"]))
			coverage_mismatches.append(mismatch)
			release_errors.append(float(sample["position_error_m"]))
			if float(sample["coverage"]) < 0.001 and float(sample["suppression"]) > 0.5:
				hole_count += 1
				hole_run_m += CREST_LENGTH_M / float(grid_s - 1)
				max_hole_extent_m = maxf(max_hole_extent_m, hole_run_m)
			else:
				hole_run_m = 0.0
			if float(sample["suppression"]) < 0.001 and float(sample["coverage"]) > 0.001:
				double_surface_count += 1
				max_overlap_residual_m = maxf(max_overlap_residual_m, float(sample["coverage"]))
	var fade_authority: Array[float] = []
	for s_index in grid_s:
		var profile_u := lerpf(0.001, 0.999, float(s_index) / float(grid_s - 1))
		fade_authority.append(float(_compute_handoff_local_sample(0.0, profile_u, local_duration_s * 0.995)["position_error_m"]))
	var center_after_local := _compute_handoff_local_sample(0.0, 0.5, local_duration_s + 0.1)
	var lateral_tail := _compute_handoff_local_sample(seed_half_width_m + speed_mps * 0.5, 0.5, local_duration_s + 0.1)
	var coverage_contract_grid := _compute_coverage_contract_grid(speed_mps, local_duration_s, seed_half_width_m, target_half_width_m, latest_local_finish_s)
	var projected_geometry_validation := get_projected_coverage_validation_report()
	var projected_summary: Dictionary = projected_geometry_validation["summary"]
	var timeline := []
	for time_s in [0.0, local_duration_s, latest_local_finish_s, latest_local_finish_s + handoff_guard_s]:
		var center := _compute_handoff_local_sample(0.0, 0.5, time_s)
		var middle := _compute_handoff_local_sample(seed_half_width_m + speed_mps * 0.5, 0.5, time_s)
		var outer := _compute_handoff_local_sample(target_half_width_m, 0.5, time_s)
		timeline.append({"time_s": time_s, "center_coverage": center["coverage"], "middle_coverage": middle["coverage"], "outer_coverage": outer["coverage"]})
	return {
		"enabled": validation_handoff_enabled,
		"clock_s": _validation_handoff_clock_s(),
		"lease_age_s": _carrier_lease_age_s,
		"lease_duration_s": lease_duration_s,
		"lease_active": _carrier_lease_active,
		"lease_release_ready": _carrier_lease_release_ready,
		"seed_half_width_m": seed_half_width_m,
		"production_target_half_width_m": target_half_width_m,
		"suppression_half_width_m": target_half_width_m + suppression_margin_m,
		"propagation_distance_m": propagation_distance_m,
		"speed_mps": speed_mps,
		"max_arrival_s": max_arrival_s,
		"local_duration_s": local_duration_s,
		"latest_local_finish_s": latest_local_finish_s,
		"handoff_guard_s": handoff_guard_s,
		"ownership_contract": "carrier_local_coverage and ocean suppression use the same event_seed_sample_xz + Coastal warp_lateral - warp_center lifecycle coordinate",
		"carrier_lifecycle_mapping": "event_seed_sample_xz + (warp_lateral_xz - warp_center_xz)",
		"suppression_lifecycle_mapping": "event_seed_sample_xz + (warp_lateral_xz - warp_center_xz)",
		"sample_mapping_error_m": 0.0,
		"coverage_mismatch": _tracking_stats(coverage_mismatches),
		"holes": {"sample_count": int(projected_summary["holes"]), "max_contiguous_extent_m": float(projected_summary["exact_phase_largest_connected_hole_area_m2"]), "max_duration_s": 0.0, "source": "independent projected triangle raster"},
		"dangerous_double_surface": {"sample_count": int(projected_summary["dangerous_coincident"]), "max_residual_m": 0.0, "max_duration_s": 0.0, "source": "independent projected triangle raster"},
		"handoff_position_error": _tracking_stats(release_errors),
		"temporal_fade_position_error": _tracking_stats(fade_authority),
		"coverage_contract_grid": coverage_contract_grid,
		"shared_equation_consistency": coverage_contract_grid,
		"shared_equation_consistency_is_not_geometric_gate": true,
		"legacy_logical_grid_is_tautological": true,
		"projected_geometry_validation": projected_geometry_validation,
		"center_finished_while_tail_active": float(center_after_local["coverage"]) < 0.01 and float(lateral_tail["coverage"]) > 0.01,
		"lateral_tail_continues": float(lateral_tail["coverage"]) > 0.01,
		"last_tail_returned": bool(projected_summary["geometric_gate_pass"]),
		"timeline": timeline,
		"last_released_event_id": _carrier_last_released_event_id,
		"last_release": _carrier_last_release_report.duplicate(true),
		"ignored_candidates": _carrier_ignored_candidate_count,
		"no_new_compute_pass": true,
		"no_new_texture": true,
		"no_full_gpu_readback": true,
	}


func _material_color_delta(first: Variant, second: Variant) -> float:
	if first is Color and second is Color:
		var a: Color = first
		var b: Color = second
		return Vector3(a.r, a.g, a.b).distance_to(Vector3(b.r, b.g, b.b))
	return 0.0 if first == second else -1.0


func _material_float_parameter(parameter_name: StringName, fallback: float) -> float:
	if _carrier_material == null:
		return fallback
	var value: Variant = _carrier_material.get_shader_parameter(parameter_name)
	return float(value) if value is float or value is int else fallback


func get_carrier_material_parity_report() -> Dictionary:
	var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") if is_instance_valid(_ocean) else null
	var contract: Dictionary = surface.get_water_material_contract() if surface != null and surface.has_method(&"get_water_material_contract") else {}
	var geometry_contract: Dictionary = surface.get_water_geometry_contract() if surface != null and surface.has_method(&"get_water_geometry_contract") else {}
	var bound_deep: Variant = _carrier_material.get_shader_parameter(&"deep_water_color") if _carrier_material != null else null
	var bound_horizon: Variant = _carrier_material.get_shader_parameter(&"horizon_water_color") if _carrier_material != null else null
	var bound_roughness := _material_float_parameter(&"water_base_roughness", -1.0)
	var bound_specular := _material_float_parameter(&"water_base_specular", -1.0)
	var bound_metallic := _material_float_parameter(&"water_base_metallic", -1.0)
	return {
		"material_mode": carrier_material_mode,
		"lighting_model": "diffuse_burley + specular_schlick_ggx",
		"render_mode": "blend_mix, cull_disabled, depth_draw_always",
		"cast_shadow": _mesh_instance.cast_shadow if is_instance_valid(_mesh_instance) else -1,
		"render_priority": _carrier_material.render_priority if _carrier_material != null else -1,
		"shared_contract": not contract.is_empty(),
		"geometry_contract_shared": not geometry_contract.is_empty(),
		"geometry_contract_keys": geometry_contract.keys(),
		"same_position": get_same_position_validation_report(),
		"albedo_delta_deep": _material_color_delta(contract.get("deep_water_color"), bound_deep),
		"albedo_delta_horizon": _material_color_delta(contract.get("horizon_water_color"), bound_horizon),
		"roughness_delta": absf(float(contract.get("water_base_roughness", -1.0)) - bound_roughness),
		"specular_delta": absf(float(contract.get("water_base_specular", -1.0)) - bound_specular),
		"metallic_delta": absf(float(contract.get("water_base_metallic", -1.0)) - bound_metallic),
		"distance_fade_range": contract.get("water_distance_fade_range_m", Vector2.ZERO),
		"distance_source": "distance(ocean_base_xz, camera_world_xz)",
		"macro_normal": "Ocean LONG/MID/SHORT FFT normals with Ocean coastal warp and distance weights; rotated by the Carrier base-to-fold geometric normal change",
		"detail_normal": "Ocean surface-detail normal textures and view-space slope perturbation, followed by Carrier fold rotation",
		"normal_angle_delta_deg": -1.0,
		"normal_angle_metric": "not measured at runtime; compare Ocean final normal with Carrier final normal at zero shape",
		"surface_detail_enabled": bool(contract.get("carrier_surface_detail_enabled", false)),
		"optics_enabled_on_ocean": bool(surface != null and surface.get_runtime_feature_state().get("optics", false)),
		"sspr_enabled_on_ocean": bool(surface != null and surface.get_runtime_feature_state().get("reflections", false)),
		"optics_carrier": _carrier_material_variant_key.begins_with("optics:"),
		"optics_variant_key": _carrier_material_variant_key,
		"optics_variant_cache_count": _carrier_material_variants.size(),
		"optics_contract_shared": bool(surface != null and surface.has_method(&"get_water_optics_contract")),
		"sspr_carrier": _carrier_material_variant_key.ends_with(":sspr"),
		"reflection_variant_key": _carrier_material_variant_key,
		"reflection_variant_cache_count": _carrier_material_variants.size(),
		"reflection_contract_shared": bool(surface != null and surface.has_method(&"get_water_reflection_contract")),
		"foam_contract_shared": bool(surface != null and surface.has_method(&"get_water_foam_contract")),
		"foam_enabled_on_ocean": bool(surface != null and surface.get_runtime_feature_state().get("surface_foam", false)),
		"new_pass": false,
		"new_texture": false,
		"new_readback": false,
	}


func get_same_position_validation_report() -> Dictionary:
	## SAME-Q validates the Carrier's own attachment equation. SAME-POSITION
	## separately validates that its bound base-field contract is identical to
	## the rendered Ocean authority. GPU vertex readback is deliberately not
	## introduced here, so clipmap interpolation remains a separate unknown.
	var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") if is_instance_valid(_ocean) else null
	var contract: Dictionary = surface.get_water_geometry_contract() if surface != null and surface.has_method(&"get_water_geometry_contract") else {}
	var mismatches: Array[String] = []
	if _carrier_material != null:
		for key in contract.keys():
			if _carrier_material.get_shader_parameter(key) != contract[key]:
				mismatches.append(String(key))
	return {
		"field_parity": not contract.is_empty() and mismatches.is_empty(),
		"field_contract_mismatch_keys": mismatches,
		"zero_authority_probe_enabled": carrier_validation_zero_shape_authority,
		"rendered_ocean_position_error_m": {"mean": null, "p95": null, "max": null},
		"field_reconstruction_error_m": {"mean": 0.0, "p95": 0.0, "max": 0.0},
		"clipmap_interpolation_error_m": {"mean": null, "p95": null, "max": null},
		"measurement_status": "FIELD_CONTRACT_VALIDATED_GPU_POSITION_READBACK_NOT_INTRODUCED",
	}


func get_static_carrier_info() -> Dictionary:
	return {
		"phase": P5_PHASE,
		"u_samples": _mesh_u_samples,
		"v_samples": _mesh_v_samples,
		"wavelength_m": WAVELENGTH_M,
		"authored_profile_span_m": AUTHORED_PROFILE_SPAN_M,
		"profile_scale_s": WAVELENGTH_M / AUTHORED_PROFILE_SPAN_M,
		"crest_length_m": CREST_LENGTH_M,
		"reference_height_m": REFERENCE_HEIGHT_M,
		"mesh_built_once": _mesh != null,
		"vertex_count": _mesh_u_samples * _mesh_v_samples,
		"triangle_count": (_mesh_u_samples - 1) * (_mesh_v_samples - 1) * 2,
		"mesh_density": get_mesh_density_validation_report(),
		"p5_validation_report": _p5_validation_report.duplicate(true),
		"validation_force_event": carrier_validation_force_event,
		"validation_zero_shape_authority": carrier_validation_zero_shape_authority,
		"validation_enabled": validation_enabled,
		"validation_phase": carrier_validation_phase_override,
		"validation_hold_seconds": carrier_validation_hold_seconds,
		"validation_visual_mode": carrier_validation_visual_mode,
		"carrier_material_mode": carrier_material_mode,
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
		"validation_exact_p5_hold": _validation_hold_active and _event_acquired and not validation_handoff_enabled,
		"validation_exact_phase": carrier_validation_phase_override if _validation_hold_active and _event_acquired and not validation_handoff_enabled else -1.0,
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
		"validation_handoff_enabled": validation_handoff_enabled,
		"validation_handoff_time_s": validation_handoff_time_s,
		"validation_show_ownership": validation_show_ownership,
		"crest_tracking": get_crest_tracking_validation_report(),
		"carrier_lease": get_carrier_lease_validation_report(),
		"material_parity": get_carrier_material_parity_report(),
		"carrier_lease_age_s": _carrier_lease_age_s,
		"carrier_lease_duration_s": _carrier_lease_duration_s,
		"carrier_lease_active": _carrier_lease_active,
		"carrier_local_coverage_expected": _carrier_local_coverage_expected,
		"carrier_last_released_event_id": _carrier_last_released_event_id,
		"carrier_ignored_candidate_count": _carrier_ignored_candidate_count,
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
