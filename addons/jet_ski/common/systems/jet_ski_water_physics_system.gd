class_name JetSkiWaterPhysicsSystem
extends Node

const HullBuoyancyV1 = preload("res://addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd")
const HeavyHullResponse = preload("res://addons/jet_ski/common/systems/jet_ski_heavy_hull_response.gd")
const LandingPenetration = preload("res://addons/jet_ski/common/systems/jet_ski_landing_penetration.gd")
const HullArcade = preload("res://addons/jet_ski/common/systems/jet_ski_hull_arcade_response.gd")

var hull_arcade_enabled := false
var wave_face_support_enabled := true
var wave_face_support_force := Vector3.ZERO
var hull_bow_braking_mps2 := 3.0
var hull_bow_yaw_damping_rate := 5.0
var hull_rebound_damping_rate := 5.0
var hull_rebound_min_depth_m := 0.55
var hull_submarine_authority := 0.0
var hull_submarine_target_depth_m := 1.4
var hull_submarine_sink_speed_mps := 2.2
var hull_steering_input := 0.0
var bow_plow_authority := 0.0
var hull_arcade_force := Vector3.ZERO
var hull_arcade_yaw_torque := Vector3.ZERO
var hull_rebound_force := Vector3.ZERO
var hull_submarine_force := Vector3.ZERO
var hull_root_depth_m := 0.0
var _hull_deep_recovery := false

var landing_penetration_enabled := true
var landing_entry_speed_threshold := 3.0
var landing_upward_damping_multiplier := 0.4
var landing_response := LandingPenetration.new()
var landing_removed_upward_damping_n := 0.0
var landing_preserved_torque := Vector3.ZERO
var landing_current_damping_multiplier := 1.0
enum BuoyancyMode { LEGACY_4POINT, HULL_BUOYANCY_V1 }
var buoyancy_mode: int = BuoyancyMode.LEGACY_4POINT
var hull_buoyancy := HullBuoyancyV1.new()
var heavy_hull_enabled := false
var heavy_heave_added_mass_coefficient := 0.35
var heavy_heave_resistance_rate := 1.5
var heavy_heave_added_mass_kg := 0.0
var heavy_heave_drag_force_n := 0.0
var heavy_heave_inertia_force_n := 0.0
var heavy_heave_force := Vector3.ZERO
var heavy_upright_enabled := true
var heavy_wave_tilt_influence := 0.12
var heavy_normal_lateral_influence := 0.10
var heavy_upright_response_rate := 4.0
var heavy_wave_torque_correction := Vector3.ZERO
var heavy_upright_torque := Vector3.ZERO

const BUOYANCY_POINT_COUNT: int = 4
const FRONT_POINT_COUNT: int = 2
const DIAGNOSTIC_WINDOW_SIZE: int = 4096
const TOP_TORQUE_EVENT_COUNT: int = 10
const FORCE_RISE_EVENT_THRESHOLD_N: float = 2000.0
const MEANINGFUL_WET_DEPTH_M := 0.025
const SUPPORTED_CONTACT_FORCE_N := 100.0
const AIRBORNE_GRACE_SECONDS := 0.08
const LANDING_DOWNWARD_SPEED_MPS := 1.0
const POINT_NAMES: Array[StringName] = [
	&"FrontLeft",
	&"FrontRight",
	&"RearLeft",
	&"RearRight",
]

@export_range(0.05, 0.5, 0.01) var equilibrium_depth := 0.15
@export_range(0.8, 1.0, 0.01) var damping_ratio := 0.9

var state: JetSkiWaterState = JetSkiWaterState.new()

var buoyancy_strength_per_point: float = 5500.0
var buoyancy_damping_per_point: float = 2500.0
var buoyancy_damping_full_depth_m: float = 0.25
var max_submersion_depth: float = 0.8
var deep_buoyancy_start_depth: float = 1.0
var deep_buoyancy_strength_per_point: float = 3500.0
var deep_buoyancy_force_limit_per_meter: float = 5000.0
var max_buoyancy_force_per_point: float = 5500.0
var force_debug_enabled: bool = false
var diagnostics_enabled: bool = false
var stabilized_angular_mode: bool = false
var buoyancy_torque_scale: float = 1.0
@export_range(0.0, 1.0, 0.05) var buoyancy_normal_influence: float = 0.5
var use_raw_buoyancy_direction: bool = false
var wet_pitch_damping: float = 35.0
var wet_roll_damping: float = 260.0
var wet_yaw_damping: float = 30.0
var max_buoyancy_force_rise_N_per_s: float = 0.0
var reentry_torque_ramp_seconds: float = 0.08
var diagnostic_scenario_name: String = "unassigned"

var forward_drag_linear_per_point: float = 15.0
var forward_drag_quadratic_per_point: float = 1.5
var lateral_drag_linear_per_point: float = 80.0
var lateral_drag_quadratic_per_point: float = 7.0
var drag_depth_exponent: float = 1.0
var hydrodynamic_drag_full_depth_m: float = 0.8
var maximum_forward_drag_force_per_point: float = 3500.0
var maximum_lateral_drag_force_per_point: float = 7000.0

## Runtime A/B switch. Current Production remains the default path.
var water_race_mode: bool = false
var wet_contact_count := 0
var supported_contact_count := 0
var contact_is_wet := false
var contact_is_supported := false
var contact_is_airborne := false
var contact_is_landing := false
var contact_landing_event_serial := 0
var contact_landing_downward_speed_mps := 0.0
var _airborne_dry_time_s := 0.0
var _landing_fx_time_remaining_s := 0.0
var anti_hop_enabled := false
var anti_hop_max_net_upward_acceleration_mps2 := 18.0
var anti_hop_intervention_count := 0
var anti_hop_last_acceleration_reduction_mps2 := 0.0
var propulsion_grace_intervention_count := 0
var propulsion_grace_current_multiplier := 0.0
var propulsion_grace_duration_seconds := 0.10
var propulsion_grace_clearance_limit_m := 0.30
var short_hop_count := 0
var _short_hop_dry_elapsed_s := 0.0
var _short_hop_max_clearance_m := 0.0
var _previous_short_hop_contact_mask := 0

## One-shot release spin cleaner. Water forces and torques remain unscaled.
var takeoff_assist_enabled := true
@export_range(0.1, 2.0, 0.05) var takeoff_pitch_soft_rate_rad_s := 0.8
@export_range(0.2, 3.0, 0.05) var takeoff_pitch_strong_rate_rad_s := 1.5
@export_range(0.1, 2.0, 0.05) var takeoff_roll_soft_rate_rad_s := 0.6
@export_range(0.2, 3.0, 0.05) var takeoff_roll_strong_rate_rad_s := 1.2
@export_range(0.0, 1.0, 0.05) var takeoff_rider_intent_expansion := 0.65
var takeoff_extreme := false
var takeoff_event_serial := 0
var takeoff_last_diagnostic: Dictionary = {}
var takeoff_rider_shift := Vector2.ZERO
var _takeoff_contact_impulse_history := PackedFloat32Array()
var _takeoff_side_impulse_history := PackedFloat32Array()
var _takeoff_contact_history: Array[Dictionary] = []
var _takeoff_rate_history := PackedVector3Array()
var _takeoff_force_history := PackedFloat32Array()
var _takeoff_pitch_history := PackedFloat32Array()
var _takeoff_roll_history := PackedFloat32Array()
var _takeoff_air_elapsed_s := -1.0
var _takeoff_air_max_pitch_deg := 0.0
var _takeoff_air_max_roll_deg := 0.0

var point_depths: PackedFloat32Array:
	get:
		return _point_depths
var point_normal_forces: PackedFloat32Array:
	get:
		return _point_normal_forces
var point_buoyancy_force_vectors: PackedVector3Array:
	get:
		return _point_buoyancy_force_vectors
var point_water_normals: PackedVector3Array:
	get:
		return _point_water_normals
var point_world_positions: PackedVector3Array:
	get:
		return _point_world_positions
var point_water_surface_positions: PackedVector3Array:
	get:
		return _point_water_surface_positions
var point_water_velocities: PackedVector3Array:
	get:
		return _point_water_velocities
var point_physical_velocities: PackedVector3Array:
	get:
		return _point_physical_velocities
var point_relative_velocities: PackedVector3Array:
	get:
		return _point_relative_velocities
var point_relative_normal_speeds: PackedFloat32Array:
	get:
		return _point_relative_normal_speeds
var point_sample_valid: Array[bool]:
	get:
		return _point_sample_valid
var point_forward_drag_forces: PackedVector3Array:
	get:
		return _point_forward_drag_forces
var point_lateral_drag_forces: PackedVector3Array:
	get:
		return _point_lateral_drag_forces

var _buoyancy_local_points: PackedVector3Array = PackedVector3Array()
var _point_depths: PackedFloat32Array = PackedFloat32Array()
var _point_effective_depths: PackedFloat32Array = PackedFloat32Array()
@export_range(0.0, 0.15, 0.05, "suffix:m") var buoyancy_draft_offset_m: float = 0.0
var effective_point_depths: PackedFloat32Array:
	get:
		return _point_effective_depths
var _point_normal_forces: PackedFloat32Array = PackedFloat32Array()
var _point_buoyancy_force_vectors: PackedVector3Array = PackedVector3Array()
var _point_water_normals: PackedVector3Array = PackedVector3Array()
var _point_world_positions: PackedVector3Array = PackedVector3Array()
var _point_water_surface_positions: PackedVector3Array = PackedVector3Array()
var _point_water_velocities: PackedVector3Array = PackedVector3Array()
var _point_physical_velocities: PackedVector3Array = PackedVector3Array()
var _point_relative_velocities: PackedVector3Array = PackedVector3Array()
var _point_relative_normal_speeds: PackedFloat32Array = PackedFloat32Array()
var _point_sample_valid: Array[bool] = []
var _point_forward_drag_forces: PackedVector3Array = PackedVector3Array()
var _point_lateral_drag_forces: PackedVector3Array = PackedVector3Array()
var point_spring_forces: PackedFloat32Array = PackedFloat32Array()
var point_damping_forces: PackedFloat32Array = PackedFloat32Array()
var point_force_clamp_reached: Array[bool] = []
var point_baseline_force_clamp_reached: Array[bool] = []
var _point_diagnostic_depth: PackedFloat32Array = PackedFloat32Array()
var _point_diagnostic_normal_speed: PackedFloat32Array = PackedFloat32Array()
var baseline_contact_count: int = 0
var baseline_force_clamp_count: int = 0
var baseline_damping_caused_clamp_count: int = 0
var point_lever_arms := PackedVector3Array()
var point_buoyancy_torques := PackedVector3Array()
var point_force_directions := PackedVector3Array()
var total_buoyancy_force_vector := Vector3.ZERO
var total_buoyancy_torque := Vector3.ZERO
var audit_last_total_gravity := Vector3.ZERO
var _last_applied_buoyancy_torque := Vector3.ZERO
var total_buoyancy_torque_samples := PackedFloat32Array()
var buoyancy_pitch_torque_samples := PackedFloat32Array()
var buoyancy_roll_torque_samples := PackedFloat32Array()
var buoyancy_yaw_torque_samples := PackedFloat32Array()
var applied_buoyancy_pitch_torque_samples := PackedFloat32Array()
var applied_buoyancy_roll_torque_samples := PackedFloat32Array()
var applied_buoyancy_yaw_torque_samples := PackedFloat32Array()
var contact_torque_samples := PackedFloat32Array()
var angular_pitch_samples := PackedFloat32Array()
var angular_roll_samples := PackedFloat32Array()
var angular_yaw_samples := PackedFloat32Array()
var angular_pitch_acceleration_samples := PackedFloat32Array()
var angular_roll_acceleration_samples := PackedFloat32Array()
var wet_angular_damping_torque_samples := PackedFloat32Array()
var force_rise_samples_n_per_s := PackedFloat32Array()
var force_rise_limiter_activation_count: int = 0
var force_rise_event_count: int = 0
var top_contact_torque_events: Array[Dictionary] = []
var top_pitch_torque_events: Array[Dictionary] = []
var top_roll_torque_events: Array[Dictionary] = []
var top_angular_acceleration_events: Array[Dictionary] = []
var effective_inertia_diagnostic: Dictionary = {}
var _diagnostic_ring_cursors := {"total_torque": 0, "contact_torque": 0, "pitch": 0, "roll": 0, "yaw": 0,
	"pitch_torque": 0, "roll_torque": 0, "yaw_torque": 0, "pitch_accel": 0, "roll_accel": 0,
	"damping_torque": 0, "force_rise": 0}
var _diagnostic_tick_count := 0
var _diagnostic_cache: Dictionary = {}
var _previous_contact_forces := PackedFloat32Array()
var _previous_world_angular_velocity := Vector3.ZERO
var _has_previous_angular_velocity := false
var _was_airborne_previous_frame := false
var _landing_reentry_this_frame := false
var _reentry_elapsed := 0.0
var _reentry_ramp_active := false
var _last_wet_angular_damping_torque := Vector3.ZERO
var _water_sample_scratch: WaterSample3D = WaterSample3D.new()
var _comparison_water_scratch: WaterSample3D = WaterSample3D.new()

var _point_warning_emitted: bool = false
var _invalid_sample_warning_emitted: bool = false
var _invalid_drag_warning_emitted: bool = false
var _degenerate_axis_warning_emitted: bool = false
var _runtime_array_resize_count: int = 0


func configure(buoyancy_points_root: Node3D) -> void:
	_resize_runtime_arrays()
	_buoyancy_local_points.clear()
	if buoyancy_points_root == null:
		_warn_about_missing_points_once()
		reset_runtime_state()
		return
	for point_name in POINT_NAMES:
		var marker := buoyancy_points_root.get_node_or_null(
			NodePath(point_name)
		) as Marker3D
		if marker == null:
			_buoyancy_local_points.clear()
			_warn_about_missing_points_once()
			reset_runtime_state()
			return
		_buoyancy_local_points.append(
			(buoyancy_points_root.transform * marker.transform).origin
		)
	reset_runtime_state()


func has_valid_buoyancy_points() -> bool:
	return _buoyancy_local_points.size() == BUOYANCY_POINT_COUNT


func step(body_state: PhysicsDirectBodyState3D, water_provider: WaterSurfaceProvider3D,
		submarine_buoyancy_factor: float) -> JetSkiWaterState:
	var perf2_sink: Object = (water_provider.call("get_perf2_sink")
		if is_instance_valid(water_provider) and water_provider.has_method("get_perf2_sink") else null)
	hull_buoyancy.perf2_sink = perf2_sink
	var started := Time.get_ticks_usec() if perf2_sink != null else 0
	var result := _perf2_step_body(body_state, water_provider, submarine_buoyancy_factor)
	if perf2_sink != null:
		perf2_sink.call("perf2_record_span", 2, Engine.get_process_frames(), Engine.get_physics_frames(),
			started, Time.get_ticks_usec(), 1)
	return result

func _perf2_step_body(
	body_state: PhysicsDirectBodyState3D,
	water_provider: WaterSurfaceProvider3D,
	submarine_buoyancy_factor: float
) -> JetSkiWaterState:
	if buoyancy_mode == BuoyancyMode.HULL_BUOYANCY_V1:
		return _step_hull_buoyancy(body_state, water_provider, submarine_buoyancy_factor)
	reset_runtime_state()
	audit_last_total_gravity = body_state.total_gravity
	if water_provider == null or not is_instance_valid(water_provider):
		return state
	if not has_valid_buoyancy_points():
		_warn_about_missing_points_once()
		return state
	if water_provider.has_method("has_usable_contacts") and not water_provider.has_usable_contacts(): return state
	var depth_sum: float = 0.0
	var maximum_signed_depth: float = -INF
	var active_water_normal_sum := Vector3.ZERO
	var active_water_velocity_sum := Vector3.ZERO
	var body_forward := -body_state.transform.basis.z.normalized()
	state.sampled_body_forward = body_forward
	state.sampled_body_linear_velocity = body_state.linear_velocity
	for index in BUOYANCY_POINT_COUNT:
		var local_point := _buoyancy_local_points[index]
		var world_point := body_state.transform * local_point
		var world_offset := world_point - body_state.transform.origin
		_point_world_positions[index] = world_point
		var water_sample := water_provider.sample_water(
			world_point,
			_water_sample_scratch
		)
		if not water_sample.valid:
			_previous_contact_forces[index] = 0.0
			_warn_about_invalid_sample_once()
			continue
		var comparison_sample: WaterSample3D = _comparison_water_scratch.reset()
		if water_provider.has_method("sample_comparison_water"):
			comparison_sample = water_provider.call("sample_comparison_water", world_point,
				_comparison_water_scratch) as WaterSample3D
		_point_water_surface_positions[index] = water_sample.surface_position
		_point_sample_valid[index] = true
		_point_water_normals[index] = water_sample.normal
		_point_water_velocities[index] = water_sample.velocity
		var raw_depth := water_sample.signed_depth
		var support_depth := maxf(raw_depth - buoyancy_draft_offset_m, 0.0)
		_point_depths[index] = raw_depth
		_point_effective_depths[index] = support_depth
		maximum_signed_depth = maxf(maximum_signed_depth, raw_depth)
		var point_velocity := body_state.get_velocity_at_local_position(world_offset)
		if diagnostics_enabled and water_provider.has_method("record_contact_trace") and bool(water_provider.get("capture_contact_trace")):
			water_provider.call("record_contact_trace", index, world_point, point_velocity,
				body_state.transform, body_state.linear_velocity, body_state.angular_velocity, water_sample)
		if raw_depth <= 0.0:
			_previous_contact_forces[index] = 0.0
			if comparison_sample != null and comparison_sample.valid and water_provider.has_method("record_contact_comparison"):
				var alternate_force := _support_force_for_sample(body_state, comparison_sample, point_velocity)
				water_provider.call("record_contact_comparison", index, world_point, water_sample,
					comparison_sample, 0.0, alternate_force)
			continue
		state.raw_contact_mask |= 1 << index
		var water_normal := water_sample.normal
		var water_velocity := water_sample.velocity
		if not water_normal.is_finite() or not water_velocity.is_finite():
			_warn_about_invalid_sample_once()
			continue
		if water_normal.length_squared() <= 0.000001:
			_warn_about_invalid_sample_once()
			continue
		water_normal = water_normal.normalized()
		if water_normal.y < 0.0:
			water_normal = -water_normal
		var relative_velocity := point_velocity - water_velocity
		var normal_speed := (relative_velocity.dot(water_normal)
			if water_race_mode else relative_velocity.y)
		_point_water_velocities[index] = water_velocity
		_point_physical_velocities[index] = point_velocity
		_point_relative_velocities[index] = relative_velocity
		_point_relative_normal_speeds[index] = normal_speed
		_point_sample_valid[index] = true
		var depth_ratio := clampf(raw_depth / maxf(hydrodynamic_drag_full_depth_m, 0.001), 0.0, 1.0)
		var support_depth_ratio := clampf(support_depth / maxf(buoyancy_damping_full_depth_m, 0.001), 0.0, 1.0)
		var effective_mass := 1.0 / body_state.inverse_mass / 4.0
		var gravity := body_state.total_gravity.length()
		var spring := effective_mass * gravity / equilibrium_depth
		var damping := damping_ratio * 2.0 * sqrt(spring * effective_mass)
		# Fade damping at the surface so entry starts continuously at zero force.
		var normal_force: float
		if water_race_mode:
			var spring_component := _water_race_buoyancy_force(support_depth)
			var damping_component := -buoyancy_damping_per_point * normal_speed * support_depth_ratio
			var uncapped_total := spring_component + damping_component
			normal_force = clampf(uncapped_total, 0.0, max_buoyancy_force_per_point)
			if force_debug_enabled:
				_store_force_diagnostics(index, support_depth, normal_speed, spring_component,
					damping_component, uncapped_total)
		else:
			normal_force = maxf(0.0, spring * support_depth - damping * relative_velocity.y *
				support_depth_ratio)
		normal_force *= clampf(submarine_buoyancy_factor, 0.0, 1.0)
		if not is_finite(normal_force):
			push_error("Non-finite heightfield support"); continue
		if comparison_sample != null and comparison_sample.valid and water_provider.has_method("record_contact_comparison"):
			var alternate_force := _support_force_for_sample(body_state, comparison_sample, point_velocity)
			water_provider.call("record_contact_comparison", index, world_point, water_sample,
				comparison_sample, normal_force, alternate_force)
		_point_normal_forces[index] = normal_force
		_point_water_normals[index] = water_normal
		var support_up := -body_state.total_gravity.normalized()
		var buoyancy_direction := support_up
		if water_race_mode:
			var normal_influence := 1.0 if use_raw_buoyancy_direction else clampf(buoyancy_normal_influence, 0.0, 1.0)
			var blended_direction := Vector3.UP * (1.0 - normal_influence) + water_normal * normal_influence
			buoyancy_direction = blended_direction.normalized() if blended_direction.length_squared() > 0.000001 else Vector3.UP
		var buoyancy_force := buoyancy_direction * normal_force
		var previous_force := _previous_contact_forces[index]
		var force_rise := maxf(normal_force - previous_force, 0.0)
		var force_rise_rate := force_rise / maxf(body_state.step, 0.000001)
		if diagnostics_enabled:
			_append_diagnostic_sample(force_rise_samples_n_per_s, force_rise_rate, "force_rise")
			if force_rise >= FORCE_RISE_EVENT_THRESHOLD_N:
				force_rise_event_count += 1
		if stabilized_angular_mode and max_buoyancy_force_rise_N_per_s > 0.0:
			var limited_force := minf(normal_force, previous_force + max_buoyancy_force_rise_N_per_s * body_state.step)
			if limited_force < normal_force:
				force_rise_limiter_activation_count += 1
				normal_force = limited_force
				buoyancy_force = buoyancy_direction * normal_force
		_previous_contact_forces[index] = normal_force
		_point_normal_forces[index] = normal_force
		_point_buoyancy_force_vectors[index] = buoyancy_force
		point_force_directions[index] = buoyancy_force.normalized() if normal_force > 0.0 else Vector3.ZERO
		state.total_buoyancy_force += buoyancy_force.length()
		total_buoyancy_force_vector += buoyancy_force
		state.maximum_point_buoyancy_force = maxf(
			state.maximum_point_buoyancy_force,
			buoyancy_force.length()
		)
		var body := get_parent() as RigidBody3D
		var center_of_mass_world := body_state.transform * body.center_of_mass if body != null else body_state.transform.origin
		var lever_arm := world_point - center_of_mass_world
		var point_torque := lever_arm.cross(buoyancy_force)
		point_lever_arms[index] = lever_arm
		point_buoyancy_torques[index] = point_torque
		total_buoyancy_torque += point_torque
		if diagnostics_enabled:
			_record_contact_torque_event(index, support_depth, buoyancy_force, lever_arm, point_torque)
		if not stabilized_angular_mode:
			body_state.apply_force(buoyancy_force, world_offset)
		_apply_point_hydrodynamic_drag(
			body_state,
			index,
			world_offset,
			body_forward,
			water_normal,
			relative_velocity,
			depth_ratio
		)
		active_water_normal_sum += water_normal
		active_water_velocity_sum += water_velocity
		state.submerged_point_count += 1
		depth_sum += raw_depth
		state.effective_support_depth_sum += support_depth
		state.maximum_depth = maxf(state.maximum_depth, raw_depth)
		state.maximum_effective_support_depth = maxf(state.maximum_effective_support_depth, support_depth)
		if index < FRONT_POINT_COUNT:
			state.front_submerged_count += 1
		else:
			state.rear_submerged_count += 1
	_landing_reentry_this_frame = _was_airborne_previous_frame and state.submerged_point_count > 0
	var stabilized_torque_scale := clampf(buoyancy_torque_scale, 0.0, 1.0)
	if stabilized_angular_mode and state.submerged_point_count > 0:
		if _landing_reentry_this_frame:
			_reentry_elapsed = 0.0
			_reentry_ramp_active = true
		if _reentry_ramp_active:
			_reentry_elapsed += body_state.step
			var reentry_blend := clampf(_reentry_elapsed / maxf(reentry_torque_ramp_seconds, 0.001), 0.0, 1.0)
			stabilized_torque_scale *= lerpf(0.2, 1.0, reentry_blend)
			if reentry_blend >= 1.0: _reentry_ramp_active = false
		var body := get_parent() as RigidBody3D
		var center_of_mass_offset := body_state.transform.basis * body.center_of_mass if body != null else Vector3.ZERO
		body_state.apply_force(total_buoyancy_force_vector, center_of_mass_offset)
		_last_applied_buoyancy_torque = total_buoyancy_torque * stabilized_torque_scale
		body_state.apply_torque(_last_applied_buoyancy_torque)
		_last_wet_angular_damping_torque = _apply_wet_angular_damping(body_state)
	else:
		_last_applied_buoyancy_torque = total_buoyancy_torque if not stabilized_angular_mode else Vector3.ZERO
		_last_wet_angular_damping_torque = Vector3.ZERO
	if state.submerged_point_count == 0:
		_reentry_ramp_active = false
		_reentry_elapsed = 0.0
	if state.submerged_point_count > 0:
		state.average_depth = depth_sum / float(state.submerged_point_count)
		state.average_effective_support_depth = (
			state.effective_support_depth_sum / float(state.submerged_point_count)
		)
	if anti_hop_enabled and water_race_mode:
		_apply_small_wave_anti_hop(body_state)
	_update_hydrodynamic_speed_metrics(
		body_state,
		body_forward,
		active_water_normal_sum,
		active_water_velocity_sum
	)
	_update_water_contact_state(body_state.step)
	_record_takeoff_contact_sample(body_state)
	state.maximum_signed_point_depth = maximum_signed_depth
	if diagnostics_enabled:
		_record_tick_diagnostics(body_state)
	_was_airborne_previous_frame = state.submerged_point_count == 0
	_update_ratios()
	if state.total_buoyancy_force > 0.0 and water_provider.has_method("record_force_application"):
		water_provider.record_force_application(Engine.get_physics_frames())
	return state


func configure_hull_buoyancy(collision: CollisionShape3D) -> void:
	if not hull_buoyancy.configure(collision):
		push_error("HULL_BUOYANCY_V1 requires a valid convex collision hull")


func set_buoyancy_mode(mode: int) -> void:
	if mode != BuoyancyMode.LEGACY_4POINT and mode != BuoyancyMode.HULL_BUOYANCY_V1:
		return
	if mode == BuoyancyMode.HULL_BUOYANCY_V1 and hull_buoyancy.local_points.size() != HullBuoyancyV1.SAMPLE_COUNT:
		return
	if mode == buoyancy_mode:
		return
	buoyancy_mode = mode
	reset_hull_arcade_history()
	landing_response = LandingPenetration.new()
	# No velocity, transform, impulse or provider configuration changes on A/B.
	reset_runtime_state()
	reset_diagnostics()
	reset_takeoff_validation_history()
	takeoff_last_diagnostic.clear()
	_previous_contact_forces.fill(0.0)
	_reentry_ramp_active = false
	hull_buoyancy.submerged_volume_m3 = 0.0
	hull_buoyancy.wet_sample_count = 0


func get_buoyancy_mode_name() -> String:
	return "HULL_BUOYANCY_V1" if buoyancy_mode == BuoyancyMode.HULL_BUOYANCY_V1 else "LEGACY_4POINT"


func get_water_query_local_points() -> PackedVector3Array:
	# The public marker/landing getters keep their original four-contact contract.
	return hull_buoyancy.local_points if buoyancy_mode == BuoyancyMode.HULL_BUOYANCY_V1 else get_buoyancy_local_points()


func _step_hull_buoyancy(body_state: PhysicsDirectBodyState3D,
		water_provider: WaterSurfaceProvider3D, submarine_buoyancy_factor: float) -> JetSkiWaterState:
	reset_runtime_state()
	if not hull_arcade_enabled or heavy_hull_enabled: _hull_deep_recovery = false
	audit_last_total_gravity = body_state.total_gravity
	hull_buoyancy.submerged_volume_m3 = 0.0
	hull_buoyancy.wet_sample_count = 0
	if not is_instance_valid(water_provider) or not has_valid_buoyancy_points():
		return state
	if water_provider.has_method("has_usable_contacts") and not water_provider.has_usable_contacts():
		return state
	var gravity := body_state.total_gravity.length()
	var support_up := -body_state.total_gravity.normalized()
	var mass_kg := 1.0 / body_state.inverse_mass
	var center_of_mass_world := body_state.transform * body_state.center_of_mass_local
	var body_forward := -body_state.transform.basis.z.normalized()
	state.sampled_body_forward = body_forward
	state.sampled_body_linear_velocity = body_state.linear_velocity
	_point_depths.fill(-INF)
	var immersed_water_velocity_sum := Vector3.ZERO
	var immersed_water_surface_sum := Vector3.ZERO
	var landing_allowed := landing_penetration_enabled and not heavy_hull_enabled \
		and submarine_buoyancy_factor >= 0.999 and takeoff_rider_shift.y >= -0.0005
	landing_response.begin_tick(landing_allowed)
	for index in hull_buoyancy.local_points.size():
		var query_point: Vector3 = body_state.transform * hull_buoyancy.local_points[index]
		# begin_gameplay_contacts has already prefetched these twelve in one batch.
		var sample := water_provider.sample_water(query_point, _water_sample_scratch)
		if water_provider.has_method("sample_comparison_water"):
			water_provider.call("sample_comparison_water", query_point, _comparison_water_scratch)
		if not sample.valid or not sample.normal.is_finite() or not sample.velocity.is_finite() \
				or not sample.surface_position.is_finite() or sample.normal.length_squared() < 0.000001:
			continue
		var normal := sample.normal.normalized()
		if normal.y < 0.0:
			normal = -normal
		sample.normal = normal
		var cell: Dictionary = hull_buoyancy.cells[index]
		var immersed: Dictionary = hull_buoyancy.integrate_cell(index, body_state.transform,
			sample, buoyancy_draft_offset_m)
		var contact: int = cell.contact
		var position: Vector3 = immersed.center
		var world_offset := position - body_state.transform.origin
		var physical_velocity := body_state.get_velocity_at_local_position(world_offset)
		var relative_velocity := physical_velocity - sample.velocity
		var relative_normal_speed := relative_velocity.dot(normal)
		var raw_depth: float = immersed.depth
		var volume: float = maxf(immersed.volume, 0.0)
		var fraction := clampf(volume / float(cell.volume), 0.0, 1.0)
		var hydrostatic_force := HullBuoyancyV1.WATER_DENSITY_KG_M3 * gravity * volume \
			* clampf(submarine_buoyancy_factor, 0.0, 1.0)
		# Distributed critical damping, fading with immersed volume.
		var cell_mass := mass_kg * float(cell.volume) / hull_buoyancy.total_volume_m3
		var stiffness := HullBuoyancyV1.WATER_DENSITY_KG_M3 * gravity * float(cell.waterplane_area)
		var damping_coefficient := 2.0 * damping_ratio * sqrt(stiffness * cell_mass)
		var wave_face_normal_force := 0.0
		if wave_face_support_enabled and hull_arcade_enabled and not heavy_hull_enabled \
				and submarine_buoyancy_factor >= 0.999 and hull_submarine_authority <= 0.0 \
				and takeoff_rider_shift.y >= -0.0005 and relative_normal_speed < 0.0 \
				and body_state.transform.basis.y.dot(support_up) > 0.5:
			var horizontal_velocity := relative_velocity.slide(support_up)
			var into_face_speed := -horizontal_velocity.dot(normal)
			var face_authority := smoothstep(0.3, 2.0, into_face_speed) \
				* smoothstep(2.0, 6.0, horizontal_velocity.length())
			# Dynamic pressure on the wetted hull redirects forward motion up
			# the face before a large volume is buried. It only resists incoming
			# relative motion, so it cannot add energy or attach a departing hull.
			var pressure_acceleration := 2.0 * horizontal_velocity.length() * (-relative_normal_speed) / 3.0
			wave_face_normal_force = cell_mass * minf(pressure_acceleration, gravity * 4.0) \
				* sqrt(fraction) * face_authority
		var damping_normal_force := -damping_coefficient * fraction * relative_normal_speed \
			+ wave_face_normal_force
		var wave_face_force := normal * wave_face_normal_force
		if not heavy_hull_enabled and submarine_buoyancy_factor >= 0.999 \
				and hull_submarine_authority <= 0.0:
			# A separating surface contact may unload before the cell is dry.
			# Do not let damping exceed its hydrostatic normal support and pull
			# the craft down the back of a crest. Keep rho*g*V, entry damping,
			# tangential drag and the dedicated deep-recovery response intact.
			damping_normal_force = maxf(damping_normal_force,
				-hydrostatic_force * maxf(support_up.dot(normal), 0.0))
		var damping_force := normal * damping_normal_force
		if heavy_hull_enabled and heavy_upright_enabled:
			damping_force = HeavyHullResponse.soften_normal_lateral(damping_force,
				support_up, heavy_normal_lateral_influence)
		var removed_damping := Vector3.ZERO
		if volume > HullBuoyancyV1.VOLUME_EPSILON and landing_allowed:
			var down_speed := -(body_state.linear_velocity - sample.velocity).dot(support_up)
			var multiplier := landing_response.damping_multiplier(landing_allowed, down_speed,
				landing_entry_speed_threshold, landing_upward_damping_multiplier)
			landing_current_damping_multiplier = minf(landing_current_damping_multiplier, multiplier)
			# Reduce only an existing positive vertical damping component. Retain
			# hydrostatics, lateral damping, and all angular moments independently.
			removed_damping = support_up * maxf(damping_force.dot(support_up), 0.0) * (1.0 - multiplier)
			damping_force -= removed_damping
			wave_face_force -= support_up * maxf(wave_face_force.dot(support_up), 0.0) * (1.0 - multiplier)
			landing_removed_upward_damping_n += removed_damping.dot(support_up)
		wave_face_support_force += wave_face_force
		var force := support_up * hydrostatic_force + damping_force
		if not force.is_finite():
			continue
		if raw_depth > _point_depths[contact]:
			_point_depths[contact] = raw_depth
			_point_effective_depths[contact] = maxf(raw_depth - buoyancy_draft_offset_m, 0.0)
			_point_world_positions[contact] = position
			_point_water_surface_positions[contact] = sample.surface_position
			_point_water_normals[contact] = normal
			_point_water_velocities[contact] = sample.velocity
			_point_physical_velocities[contact] = physical_velocity
			_point_relative_velocities[contact] = relative_velocity
			_point_relative_normal_speeds[contact] = relative_normal_speed
		_point_sample_valid[contact] = true
		if raw_depth > 0.0:
			state.raw_contact_mask |= 1 << contact
		if volume <= HullBuoyancyV1.VOLUME_EPSILON:
			continue
		hull_buoyancy.submerged_volume_m3 += volume
		immersed_water_velocity_sum += sample.velocity * volume
		immersed_water_surface_sum += sample.surface_position * volume
		hull_buoyancy.wet_sample_count += 1
		body_state.apply_force(force, world_offset)
		var lever_arm := position - center_of_mass_world
		var torque := lever_arm.cross(force)
		var preserved_moment := lever_arm.cross(removed_damping)
		landing_preserved_torque += preserved_moment
		torque += preserved_moment
		total_buoyancy_force_vector += force
		total_buoyancy_torque += torque
		_point_buoyancy_force_vectors[contact] += force
		point_buoyancy_torques[contact] += torque
		_point_normal_forces[contact] += maxf(force.dot(support_up), 0.0)
		point_spring_forces[contact] += hydrostatic_force
		point_damping_forces[contact] += damping_force.dot(support_up)
	# The reduced force enters at its existing point; restore only its removed
	# moment so this tuning changes heave, never the existing pitch/roll/yaw law.
	if not landing_preserved_torque.is_zero_approx(): body_state.apply_torque(landing_preserved_torque)
	var landing_wet := hull_buoyancy.submerged_volume_m3 > HullBuoyancyV1.VOLUME_EPSILON
	var landing_mean_down := 0.0
	if landing_wet:
		landing_mean_down = -(body_state.linear_velocity \
			- immersed_water_velocity_sum / hull_buoyancy.submerged_volume_m3).dot(support_up)
	landing_response.end_tick(landing_wet, landing_mean_down, landing_entry_speed_threshold, body_state.step)
	if heavy_hull_enabled and hull_buoyancy.submerged_volume_m3 > HullBuoyancyV1.VOLUME_EPSILON:
		var displaced_mass := HullBuoyancyV1.WATER_DENSITY_KG_M3 * hull_buoyancy.submerged_volume_m3
		var average_water_velocity := immersed_water_velocity_sum / hull_buoyancy.submerged_volume_m3
		var relative_heave_speed := (body_state.linear_velocity - average_water_velocity).dot(support_up)
		var net_water_heave_force := total_buoyancy_force_vector.dot(support_up) - mass_kg * gravity
		var response := HeavyHullResponse.heave_response(mass_kg, displaced_mass,
			net_water_heave_force, relative_heave_speed, heavy_heave_added_mass_coefficient,
			heavy_heave_resistance_rate, body_state.step)
		heavy_heave_added_mass_kg = response.added_mass_kg
		heavy_heave_drag_force_n = response.drag_force_n
		heavy_heave_inertia_force_n = response.inertia_force_n
		heavy_heave_force = support_up * float(response.force_n)
		# Pure heave at the COM: no yaw torque, no propulsion/direction scaling.
		body_state.apply_central_force(heavy_heave_force)
		total_buoyancy_force_vector += heavy_heave_force
	var depth_sum := 0.0
	var normal_sum := Vector3.ZERO
	var velocity_sum := Vector3.ZERO
	state.maximum_signed_point_depth = -INF
	for contact in BUOYANCY_POINT_COUNT:
		if not _point_sample_valid[contact]:
			_point_depths[contact] = 0.0
			continue
		state.maximum_signed_point_depth = maxf(state.maximum_signed_point_depth, _point_depths[contact])
		if (state.raw_contact_mask & (1 << contact)) == 0:
			continue
		state.submerged_point_count += 1
		if contact < FRONT_POINT_COUNT:
			state.front_submerged_count += 1
		else:
			state.rear_submerged_count += 1
		depth_sum += _point_depths[contact]
		state.effective_support_depth_sum += _point_effective_depths[contact]
		state.maximum_depth = maxf(state.maximum_depth, _point_depths[contact])
		state.maximum_effective_support_depth = maxf(state.maximum_effective_support_depth, _point_effective_depths[contact])
		state.total_buoyancy_force += _point_buoyancy_force_vectors[contact].length()
		state.maximum_point_buoyancy_force = maxf(state.maximum_point_buoyancy_force,
			_point_buoyancy_force_vectors[contact].length())
		point_lever_arms[contact] = _point_world_positions[contact] - center_of_mass_world
		point_force_directions[contact] = _point_buoyancy_force_vectors[contact].normalized()
		# Preserve the existing total tangential drag and its four-contact API.
		_apply_point_hydrodynamic_drag(body_state, contact,
			_point_world_positions[contact] - body_state.transform.origin, body_forward,
			_point_water_normals[contact], _point_relative_velocities[contact],
			clampf(_point_depths[contact] / maxf(hydrodynamic_drag_full_depth_m, 0.001), 0.0, 1.0))
		normal_sum += _point_water_normals[contact]
		velocity_sum += _point_water_velocities[contact]
	if state.submerged_point_count > 0:
		state.average_depth = depth_sum / float(state.submerged_point_count)
		state.average_effective_support_depth = state.effective_support_depth_sum / float(state.submerged_point_count)
	if heavy_hull_enabled:
		state.total_buoyancy_force = total_buoyancy_force_vector.length()
	_last_applied_buoyancy_torque = total_buoyancy_torque
	_last_wet_angular_damping_torque = Vector3.ZERO
	if heavy_hull_enabled and heavy_upright_enabled and hull_buoyancy.submerged_volume_m3 > HullBuoyancyV1.VOLUME_EPSILON:
		var basis := body_state.transform.basis.orthonormalized()
		var inverse_local := basis.transposed() * body_state.inverse_inertia_tensor * basis
		if inverse_local.is_finite() and absf(inverse_local.determinant()) > 0.000000000001:
			var tensor := inverse_local.inverse()
			var inertia_local := Vector3(tensor.x.x, tensor.y.y, tensor.z.z)
			var wet_support := HullBuoyancyV1.WATER_DENSITY_KG_M3 * hull_buoyancy.submerged_volume_m3 / mass_kg
			var response := HeavyHullResponse.upright_response(basis, body_state.angular_velocity,
				inertia_local, support_up, wet_support, total_buoyancy_torque,
				heavy_wave_tilt_influence, heavy_upright_response_rate, takeoff_rider_shift, body_state.step)
			heavy_wave_torque_correction = response.wave_correction
			heavy_upright_torque = response.upright_torque
			body_state.apply_torque(heavy_wave_torque_correction + heavy_upright_torque)
			_last_applied_buoyancy_torque += heavy_wave_torque_correction + heavy_upright_torque
	_update_hydrodynamic_speed_metrics(body_state, body_forward, normal_sum, velocity_sum)
	if hull_arcade_enabled and not heavy_hull_enabled:
		_apply_hull_arcade_response(body_state, support_up, mass_kg,
			immersed_water_velocity_sum, immersed_water_surface_sum)
	_update_water_contact_state(body_state.step)
	_update_ratios()
	_record_takeoff_contact_sample(body_state)
	if diagnostics_enabled:
		_record_tick_diagnostics(body_state)
	_was_airborne_previous_frame = state.submerged_point_count == 0
	return state


func reset_hull_arcade_history() -> void:
	_hull_deep_recovery = false


func _apply_hull_arcade_response(body_state: PhysicsDirectBodyState3D, up: Vector3,
		mass_kg: float, water_velocity_volume_sum: Vector3, surface_volume_sum: Vector3) -> void:
	var volume := hull_buoyancy.submerged_volume_m3
	if volume <= HullBuoyancyV1.VOLUME_EPSILON:
		_hull_deep_recovery = false
		return
	var relative := body_state.linear_velocity - water_velocity_volume_sum / volume
	hull_root_depth_m = (surface_volume_sum / volume - body_state.transform.origin).dot(up)
	var bow_depth := maxf(_point_depths[0], _point_depths[1])
	bow_plow_authority = HullArcade.plow_authority(body_state.transform.basis,
		bow_depth, relative.slide(up).length(), hull_root_depth_m)
	var water_force := total_buoyancy_force_vector
	var water_torque := total_buoyancy_torque
	var center := body_state.transform * body_state.center_of_mass_local
	for index in BUOYANCY_POINT_COUNT:
		var drag := _point_forward_drag_forces[index] + _point_lateral_drag_forces[index]
		water_force += drag
		water_torque += (_point_world_positions[index] - center).cross(drag)
	hull_arcade_force = HullArcade.plow_force_correction(water_force, relative, up,
		mass_kg, hull_bow_braking_mps2, bow_plow_authority, body_state.step)
	hull_arcade_yaw_torque = HullArcade.plow_yaw_torque(water_torque,
		body_state.angular_velocity, body_state.inverse_inertia_tensor, up,
		bow_plow_authority, hull_steering_input, hull_bow_yaw_damping_rate, body_state.step)
	# A surface wave is not a recovery. Arm only after actual deep, near-full
	# immersion; dissipate its stored ascent energy until the body resurfaces.
	if hull_root_depth_m >= hull_rebound_min_depth_m \
			and volume >= hull_buoyancy.total_volume_m3 * 0.9:
		_hull_deep_recovery = true
	if hull_root_depth_m <= 0.0: _hull_deep_recovery = false
	var recovery := smoothstep(0.0, 0.25, hull_root_depth_m) if _hull_deep_recovery else 0.0
	if hull_submarine_authority <= 0.0:
		hull_rebound_force = HullArcade.rebound_force(relative, up, mass_kg,
			volume * HullBuoyancyV1.WATER_DENSITY_KG_M3, hull_rebound_damping_rate, body_state.step) * recovery
	hull_submarine_force = HullArcade.submarine_force(water_force, relative, up, mass_kg,
		body_state.total_gravity.length(), hull_root_depth_m, hull_submarine_target_depth_m,
		hull_submarine_sink_speed_mps, hull_submarine_authority)
	body_state.apply_central_force(hull_arcade_force + hull_rebound_force + hull_submarine_force)
	body_state.apply_torque(hull_arcade_yaw_torque)
	_last_applied_buoyancy_torque += hull_arcade_yaw_torque


func set_takeoff_assist_enabled(enabled: bool) -> void:
	takeoff_assist_enabled = enabled


func set_anti_hop_enabled(enabled: bool) -> void:
	anti_hop_enabled = enabled
	anti_hop_intervention_count = 0
	anti_hop_last_acceleration_reduction_mps2 = 0.0
	propulsion_grace_intervention_count = 0
	propulsion_grace_current_multiplier = 0.0


func get_propulsion_contact_grace_factor() -> float:
	propulsion_grace_current_multiplier = 0.0
	if not anti_hop_enabled or _airborne_dry_time_s <= 0.0:
		return 0.0
	if _airborne_dry_time_s > propulsion_grace_duration_seconds:
		return 0.0
	var clearance := 0.0
	for index in BUOYANCY_POINT_COUNT:
		if _point_sample_valid[index]:
			clearance = maxf(clearance, -_point_depths[index])
	if clearance > propulsion_grace_clearance_limit_m:
		return 0.0
	var remaining := clampf(1.0 - _airborne_dry_time_s / propulsion_grace_duration_seconds, 0.0, 1.0)
	propulsion_grace_current_multiplier = 0.35 * remaining
	if propulsion_grace_current_multiplier > 0.0:
		propulsion_grace_intervention_count += 1
	return propulsion_grace_current_multiplier


func _apply_small_wave_anti_hop(body_state: PhysicsDirectBodyState3D) -> void:
	anti_hop_last_acceleration_reduction_mps2 = 0.0
	if state.submerged_point_count < 2:
		return
	var peak_upward_water_speed := 0.0
	for index in BUOYANCY_POINT_COUNT:
		if _point_sample_valid[index] and _point_depths[index] > 0.0:
			peak_upward_water_speed = maxf(peak_upward_water_speed, _point_water_velocities[index].y)
	# Leave vertically fast crests free to launch the craft. Ordinary supported
	# wave crossings retain up to 18 m/s^2 net upward acceleration.
	if peak_upward_water_speed >= 1.25:
		return
	var mass := 1.0 / maxf(body_state.inverse_mass, 0.000001)
	var net_upward_acceleration := total_buoyancy_force_vector.y / mass + body_state.total_gravity.y
	var allowed_acceleration := anti_hop_max_net_upward_acceleration_mps2
	if net_upward_acceleration <= allowed_acceleration:
		return
	anti_hop_last_acceleration_reduction_mps2 = net_upward_acceleration - allowed_acceleration
	body_state.apply_central_force(Vector3.DOWN * anti_hop_last_acceleration_reduction_mps2 * mass)
	anti_hop_intervention_count += 1


func reset_takeoff_validation_history() -> void:
	_takeoff_contact_history.clear()
	_takeoff_rate_history.clear()
	_takeoff_force_history.clear()
	_takeoff_pitch_history.clear()
	_takeoff_roll_history.clear()
	_takeoff_contact_impulse_history.clear()
	_takeoff_side_impulse_history.clear()
	takeoff_last_diagnostic.clear()
	takeoff_extreme = false


func _record_takeoff_contact_sample(body_state: PhysicsDirectBodyState3D) -> void:
	var basis := body_state.transform.basis.orthonormalized()
	var local_rates := basis.inverse() * body_state.angular_velocity
	var pitch_angle := _body_pitch_angle(body_state.transform)
	var roll_angle := _body_roll_angle(body_state.transform)
	_takeoff_rate_history.append(local_rates)
	_takeoff_force_history.append(state.maximum_point_buoyancy_force)
	_takeoff_pitch_history.append(absf(pitch_angle))
	_takeoff_roll_history.append(absf(roll_angle))
	var peak_contact_impulse := 0.0
	var peak_side_impulse := 0.0
	for contact_index in body_state.get_contact_count():
		var contact_impulse_local := basis.inverse() * body_state.get_contact_impulse(contact_index)
		peak_contact_impulse = maxf(peak_contact_impulse, contact_impulse_local.length())
		peak_side_impulse = maxf(peak_side_impulse, absf(contact_impulse_local.x))
	_takeoff_contact_impulse_history.append(peak_contact_impulse)
	_takeoff_side_impulse_history.append(peak_side_impulse)
	var history_limit := maxi(4, int(ceil(Engine.physics_ticks_per_second * 0.2)))
	while _takeoff_rate_history.size() > history_limit:
		_takeoff_rate_history.remove_at(0)
		_takeoff_force_history.remove_at(0)
		_takeoff_pitch_history.remove_at(0)
		_takeoff_roll_history.remove_at(0)
		_takeoff_contact_impulse_history.remove_at(0)
		_takeoff_side_impulse_history.remove_at(0)
	if not diagnostics_enabled:
		return
	var normal_sum := Vector3.ZERO
	var forces := PackedFloat32Array()
	for index in BUOYANCY_POINT_COUNT:
		forces.append(_point_normal_forces[index])
		if _point_sample_valid[index] and _point_depths[index] >= MEANINGFUL_WET_DEPTH_M:
			normal_sum += _point_water_normals[index]
	var mean_normal := normal_sum.normalized() if normal_sum.length_squared() > 0.0001 else Vector3.UP
	var forward := -basis.z
	var right := basis.x
	var local_torque := basis.inverse() * total_buoyancy_torque
	_takeoff_contact_history.append({
		"time_s": Time.get_ticks_msec() * 0.001,
		"wet_contacts": wet_contact_count,
		"supported_contacts": supported_contact_count,
		"point_forces_n": forces,
		"peak_contact_impulse_n_s": peak_contact_impulse,
		"peak_side_impulse_n_s": peak_side_impulse,
		"total_force_n": state.total_buoyancy_force,
		"peak_point_force_n": state.maximum_point_buoyancy_force,
		"buoyancy_torque_nm": total_buoyancy_torque,
		"pitch_torque_nm": local_torque.x,
		"roll_torque_nm": local_torque.z,
		"water_normal": mean_normal,
		"forward_water_slope": atan2(-mean_normal.dot(forward), maxf(mean_normal.y, 0.0001)),
		"lateral_water_slope": atan2(-mean_normal.dot(right), maxf(mean_normal.y, 0.0001)),
		"linear_velocity": body_state.linear_velocity,
		"angular_velocity_local": local_rates,
		"pitch_deg": rad_to_deg(pitch_angle),
		"roll_deg": rad_to_deg(roll_angle),
		"rider_shift": takeoff_rider_shift
	})
	while _takeoff_contact_history.size() > history_limit:
		_takeoff_contact_history.pop_front()
	if _takeoff_air_elapsed_s >= 0.0:
		_takeoff_air_elapsed_s += body_state.step
		_takeoff_air_max_pitch_deg = maxf(_takeoff_air_max_pitch_deg, absf(rad_to_deg(pitch_angle)))
		_takeoff_air_max_roll_deg = maxf(_takeoff_air_max_roll_deg, absf(rad_to_deg(roll_angle)))
		if _takeoff_air_elapsed_s > 0.5:
			takeoff_last_diagnostic["max_pitch_first_500ms_deg"] = _takeoff_air_max_pitch_deg
			takeoff_last_diagnostic["max_roll_first_500ms_deg"] = _takeoff_air_max_roll_deg
			_takeoff_air_elapsed_s = -1.0


func handle_takeoff_transition(body_state: PhysicsDirectBodyState3D, respect_manual_axes: bool = false) -> void:
	var basis := body_state.transform.basis.orthonormalized()
	var rates_before := basis.inverse() * body_state.angular_velocity
	var extreme := _takeoff_is_extreme(rates_before, body_state.transform)
	var pitch_intent := clampf(takeoff_rider_shift.y, -1.0, 1.0)
	var roll_intent := clampf(takeoff_rider_shift.x, -1.0, 1.0)
	var pitch_intent_alignment := absf(pitch_intent) if rates_before.x * pitch_intent > 0.0 else 0.0
	# Rider roll rate is measured about body-forward (-local Z).
	var roll_intent_alignment := absf(roll_intent) if rates_before.z * -roll_intent > 0.0 else 0.0
	var rates_after := rates_before
	var pitch_soft_limit := takeoff_pitch_soft_rate_rad_s * (1.0 + takeoff_rider_intent_expansion * pitch_intent_alignment)
	var pitch_strong_limit := takeoff_pitch_strong_rate_rad_s * (1.0 + takeoff_rider_intent_expansion * pitch_intent_alignment)
	var roll_soft_limit := takeoff_roll_soft_rate_rad_s * (1.0 + takeoff_rider_intent_expansion * roll_intent_alignment)
	var roll_strong_limit := takeoff_roll_strong_rate_rad_s * (1.0 + takeoff_rider_intent_expansion * roll_intent_alignment)
	var correction_impulse_world := Vector3.ZERO
	if takeoff_assist_enabled and not extreme:
		rates_after.x = _compress_takeoff_rate(rates_before.x, pitch_soft_limit, pitch_strong_limit)
		rates_after.z = _compress_takeoff_rate(rates_before.z, roll_soft_limit, roll_strong_limit)
		if respect_manual_axes:
			if absf(pitch_intent) > 0.02: rates_after.x = rates_before.x
			if absf(roll_intent) > 0.02: rates_after.z = rates_before.z
		var delta_omega_world := basis * (rates_after - rates_before)
		var inverse_inertia_world := body_state.inverse_inertia_tensor
		if inverse_inertia_world.is_finite() and absf(inverse_inertia_world.determinant()) > 0.000000000001:
			correction_impulse_world = inverse_inertia_world.inverse() * delta_omega_world
			if correction_impulse_world.is_finite() and not correction_impulse_world.is_zero_approx():
				body_state.apply_torque_impulse(correction_impulse_world)
			else:
				correction_impulse_world = Vector3.ZERO
	takeoff_event_serial += 1
	takeoff_extreme = extreme
	takeoff_last_diagnostic = {
		"serial": takeoff_event_serial,
		"mode": "ON" if takeoff_assist_enabled else "OFF",
		"classification": "EXTREME" if extreme else "NORMAL",
		"pitch_deg": rad_to_deg(_body_pitch_angle(body_state.transform)),
		"roll_deg": rad_to_deg(_body_roll_angle(body_state.transform)),
		"pitch_rate_before_rad_s": rates_before.x,
		"roll_rate_before_rad_s": rates_before.z,
		"pitch_rate_after_rad_s": rates_after.x,
		"roll_rate_after_rad_s": rates_after.z,
		"yaw_rate_before_rad_s": rates_before.y,
		"yaw_rate_after_rad_s": rates_after.y,
		"pitch_soft_limit_rad_s": pitch_soft_limit,
		"pitch_strong_limit_rad_s": pitch_strong_limit,
		"roll_soft_limit_rad_s": roll_soft_limit,
		"roll_strong_limit_rad_s": roll_strong_limit,
		"correction_angular_impulse_world_nms": correction_impulse_world,
		"rider_intent": takeoff_rider_shift,
		"vertical_velocity_m_s": body_state.linear_velocity.y,
		"forward_speed_m_s": absf(body_state.linear_velocity.dot(-basis.z)),
		"samples_last_200ms": _takeoff_contact_history.duplicate(true),
		"max_pitch_first_500ms_deg": absf(rad_to_deg(_body_pitch_angle(body_state.transform))),
		"max_roll_first_500ms_deg": absf(rad_to_deg(_body_roll_angle(body_state.transform)))
	}
	_takeoff_air_elapsed_s = 0.0
	_takeoff_air_max_pitch_deg = absf(rad_to_deg(_body_pitch_angle(body_state.transform)))
	_takeoff_air_max_roll_deg = absf(rad_to_deg(_body_roll_angle(body_state.transform)))
	if diagnostics_enabled:
		print("TAKEOFF %s | %s | pitch %.2f→%.2f rad/s | roll %.2f→%.2f rad/s | impulse %s N·m·s | rider %s" % [
			takeoff_last_diagnostic.classification, takeoff_last_diagnostic.mode,
			takeoff_last_diagnostic.pitch_rate_before_rad_s, takeoff_last_diagnostic.pitch_rate_after_rad_s,
			takeoff_last_diagnostic.roll_rate_before_rad_s, takeoff_last_diagnostic.roll_rate_after_rad_s,
			correction_impulse_world, takeoff_rider_shift])


func _takeoff_is_extreme(rates: Vector3, body_transform: Transform3D) -> bool:
	if absf(rad_to_deg(_body_pitch_angle(body_transform))) >= 60.0:
		return true
	if absf(rad_to_deg(_body_roll_angle(body_transform))) >= 50.0:
		return true
	if absf(rates.x) >= 4.5 or absf(rates.z) >= 5.5:
		return true
	for index in _takeoff_force_history.size():
		if _takeoff_force_history[index] >= 20000.0:
			return true
		if index < _takeoff_contact_impulse_history.size() and _takeoff_contact_impulse_history[index] >= 1200.0:
			return true
		if index < _takeoff_side_impulse_history.size() and _takeoff_side_impulse_history[index] >= 600.0:
			return true
	for sample in _takeoff_contact_history:
		if Vector3(sample.get("buoyancy_torque_nm", Vector3.ZERO)).length() >= 25000.0:
			return true
	return false


func _compress_takeoff_rate(rate: float, soft_limit: float, strong_limit: float) -> float:
	var magnitude := absf(rate)
	if soft_limit <= 0.001 or strong_limit <= soft_limit or magnitude <= soft_limit:
		return rate
	var envelope_span := strong_limit - soft_limit
	var compressed: float
	if magnitude <= strong_limit:
		var normalized_excess := (magnitude - soft_limit) / envelope_span
		compressed = soft_limit + envelope_span * (normalized_excess - 0.25 * normalized_excess * normalized_excess)
	else:
		var compressed_at_strong_limit := soft_limit + envelope_span * 0.75
		compressed = compressed_at_strong_limit + envelope_span * 0.5 * (1.0 - exp(-(magnitude - strong_limit) / envelope_span))
	return signf(rate) * compressed


func _body_pitch_angle(body_transform: Transform3D) -> float:
	var forward := -body_transform.basis.z.normalized()
	return atan2(forward.y, maxf(Vector2(forward.x, forward.z).length(), 0.0001))


func _body_roll_angle(body_transform: Transform3D) -> float:
	var right := body_transform.basis.x.normalized()
	return atan2(right.y, maxf(Vector2(right.x, right.z).length(), 0.0001))


func _update_water_contact_state(step_seconds: float) -> void:
	wet_contact_count = 0
	supported_contact_count = 0
	contact_landing_downward_speed_mps = 0.0
	for index in BUOYANCY_POINT_COUNT:
		if not _point_sample_valid[index] or _point_depths[index] < MEANINGFUL_WET_DEPTH_M:
			continue
		wet_contact_count += 1
		if _point_normal_forces[index] >= SUPPORTED_CONTACT_FORCE_N:
			supported_contact_count += 1
			contact_landing_downward_speed_mps = maxf(
				contact_landing_downward_speed_mps,
				maxf(-_point_relative_normal_speeds[index], 0.0)
			)
	contact_is_wet = wet_contact_count > 0
	contact_is_supported = supported_contact_count > 0
	if diagnostics_enabled:
		if state.raw_contact_mask == 0:
			_short_hop_dry_elapsed_s = minf(_short_hop_dry_elapsed_s + step_seconds, 1.0)
			for index in BUOYANCY_POINT_COUNT:
				if _point_sample_valid[index]:
					_short_hop_max_clearance_m = maxf(_short_hop_max_clearance_m, -_point_depths[index])
		elif _previous_short_hop_contact_mask == 0:
			if _short_hop_dry_elapsed_s <= 0.08 and _short_hop_max_clearance_m <= 0.30:
				short_hop_count += 1
			_short_hop_dry_elapsed_s = 0.0
			_short_hop_max_clearance_m = 0.0
		_previous_short_hop_contact_mask = state.raw_contact_mask
	_landing_fx_time_remaining_s = maxf(_landing_fx_time_remaining_s - step_seconds, 0.0)
	if contact_is_wet:
		_airborne_dry_time_s = 0.0
		if contact_is_airborne and contact_landing_downward_speed_mps >= LANDING_DOWNWARD_SPEED_MPS:
			contact_landing_event_serial += 1
			_landing_fx_time_remaining_s = 0.24
		contact_is_airborne = false
	else:
		_airborne_dry_time_s += step_seconds
		if _airborne_dry_time_s >= AIRBORNE_GRACE_SECONDS:
			contact_is_airborne = true
	contact_is_landing = _landing_fx_time_remaining_s > 0.0


func _support_force_for_sample(body_state: PhysicsDirectBodyState3D, sample: WaterSample3D,
		point_velocity: Vector3) -> float:
	if sample == null or not sample.valid:
		return 0.0
	var support_depth := maxf(sample.signed_depth - buoyancy_draft_offset_m, 0.0)
	if support_depth <= 0.0:
		return 0.0
	var effective_mass := 1.0 / body_state.inverse_mass / float(BUOYANCY_POINT_COUNT)
	var spring := effective_mass * body_state.total_gravity.length() / equilibrium_depth
	var damping := damping_ratio * 2.0 * sqrt(spring * effective_mass)
	var relative_velocity := point_velocity - sample.velocity
	var damping_immersion := clampf(support_depth / maxf(buoyancy_damping_full_depth_m, 0.001), 0.0, 1.0)
	if water_race_mode:
		var sample_normal_speed := relative_velocity.dot(sample.normal.normalized())
		return clampf(_water_race_buoyancy_force(support_depth)
			- buoyancy_damping_per_point * sample_normal_speed * damping_immersion, 0.0,
			max_buoyancy_force_per_point)
	var relative_vertical_speed := relative_velocity.y
	return maxf(0.0, spring * support_depth - damping * relative_vertical_speed * damping_immersion)


func _water_race_buoyancy_force(depth: float) -> float:
	if depth <= 0.0: return 0.0
	var shallow_depth := minf(depth, maxf(max_submersion_depth, 0.0))
	var deep_depth := maxf(depth - deep_buoyancy_start_depth, 0.0)
	var deep_force := minf(deep_buoyancy_strength_per_point * deep_depth,
		deep_buoyancy_force_limit_per_meter * deep_depth)
	return buoyancy_strength_per_point * shallow_depth + deep_force


func _store_force_diagnostics(index: int, depth: float, normal_speed: float,
		spring_force: float, damping_force: float, uncapped_total: float) -> void:
	point_spring_forces[index] = spring_force
	point_damping_forces[index] = damping_force
	_point_diagnostic_depth[index] = depth
	_point_diagnostic_normal_speed[index] = normal_speed
	point_force_clamp_reached[index] = uncapped_total >= max_buoyancy_force_per_point
	# Track the previous Water Race force law alongside the live diagnostic so
	# clamp frequency is based on measured contact velocities, not an estimate.
	var old_depth := minf(depth, 0.8)
	var old_deep_depth := maxf(depth - 1.0, 0.0)
	var old_spring := 5500.0 * old_depth + 3500.0 * old_deep_depth
	var old_raw_force := old_spring - 2500.0 * normal_speed
	point_baseline_force_clamp_reached[index] = old_raw_force >= 5500.0
	baseline_contact_count += 1
	if old_raw_force >= 5500.0: baseline_force_clamp_count += 1
	if old_raw_force >= 5500.0 and old_spring < 5500.0 and normal_speed < 0.0:
		baseline_damping_caused_clamp_count += 1


func reset_runtime_state() -> void:
	wave_face_support_force = Vector3.ZERO
	bow_plow_authority = 0.0
	hull_arcade_force = Vector3.ZERO
	hull_arcade_yaw_torque = Vector3.ZERO
	hull_rebound_force = Vector3.ZERO
	hull_submarine_force = Vector3.ZERO
	hull_root_depth_m = 0.0
	state.reset()
	landing_removed_upward_damping_n = 0.0
	landing_preserved_torque = Vector3.ZERO
	landing_current_damping_multiplier = 1.0
	heavy_heave_added_mass_kg = 0.0
	heavy_heave_drag_force_n = 0.0
	heavy_heave_inertia_force_n = 0.0
	heavy_heave_force = Vector3.ZERO
	heavy_wave_torque_correction = Vector3.ZERO
	heavy_upright_torque = Vector3.ZERO
	total_buoyancy_force_vector = Vector3.ZERO
	total_buoyancy_torque = Vector3.ZERO
	_last_applied_buoyancy_torque = Vector3.ZERO
	for index in _point_depths.size():
		_point_depths[index] = 0.0
		_point_effective_depths[index] = 0.0
		_point_normal_forces[index] = 0.0
		_point_buoyancy_force_vectors[index] = Vector3.ZERO
		_point_water_normals[index] = Vector3.UP
		_point_world_positions[index] = Vector3.ZERO
		_point_water_surface_positions[index] = Vector3.ZERO
		_point_water_velocities[index] = Vector3.ZERO
		_point_physical_velocities[index] = Vector3.ZERO
		_point_relative_velocities[index] = Vector3.ZERO
		_point_relative_normal_speeds[index] = 0.0
		_point_sample_valid[index] = false
		_point_forward_drag_forces[index] = Vector3.ZERO
		_point_lateral_drag_forces[index] = Vector3.ZERO
		point_spring_forces[index] = 0.0
		point_damping_forces[index] = 0.0
		_point_diagnostic_depth[index] = 0.0
		_point_diagnostic_normal_speed[index] = 0.0
		point_force_clamp_reached[index] = false
		point_baseline_force_clamp_reached[index] = false
		point_lever_arms[index] = Vector3.ZERO
		point_buoyancy_torques[index] = Vector3.ZERO
		point_force_directions[index] = Vector3.ZERO


func reset_diagnostics() -> void:
	total_buoyancy_torque_samples.clear()
	buoyancy_pitch_torque_samples.clear()
	buoyancy_roll_torque_samples.clear()
	buoyancy_yaw_torque_samples.clear()
	applied_buoyancy_pitch_torque_samples.clear()
	applied_buoyancy_roll_torque_samples.clear()
	applied_buoyancy_yaw_torque_samples.clear()
	contact_torque_samples.clear()
	angular_pitch_samples.clear()
	angular_roll_samples.clear()
	angular_yaw_samples.clear()
	angular_pitch_acceleration_samples.clear()
	angular_roll_acceleration_samples.clear()
	wet_angular_damping_torque_samples.clear()
	force_rise_samples_n_per_s.clear()
	for key in _diagnostic_ring_cursors: _diagnostic_ring_cursors[key] = 0
	_diagnostic_tick_count = 0
	_diagnostic_cache.clear()
	top_contact_torque_events.clear()
	top_pitch_torque_events.clear()
	top_roll_torque_events.clear()
	top_angular_acceleration_events.clear()
	force_rise_limiter_activation_count = 0
	force_rise_event_count = 0
	short_hop_count = 0
	_short_hop_dry_elapsed_s = 0.0
	_short_hop_max_clearance_m = 0.0
	_previous_short_hop_contact_mask = 0
	_previous_world_angular_velocity = Vector3.ZERO
	_has_previous_angular_velocity = false
	_previous_contact_forces.fill(0.0)
	_was_airborne_previous_frame = false
	_landing_reentry_this_frame = false
	_reentry_elapsed = 0.0
	_reentry_ramp_active = false


func get_gameplay_force_diagnostics() -> Dictionary:
	return _diagnostic_cache


func _record_contact_torque_event(index: int, depth: float, force: Vector3,
		lever_arm: Vector3, torque: Vector3) -> void:
	_append_diagnostic_sample(contact_torque_samples, torque.length(), "contact_torque")
	var magnitude := torque.length()
	if magnitude <= 0.0001: return
	var event := {"tick": Engine.get_physics_frames(), "contact": String(POINT_NAMES[index]),
		"depth_m": depth, "force_n": force.length(), "force_direction": force.normalized(),
		"lever_arm_m": lever_arm, "torque_nm": torque, "torque_magnitude_nm": magnitude}
	_insert_top_event(top_contact_torque_events, event, "torque_magnitude_nm")


func _record_tick_diagnostics(body_state: PhysicsDirectBodyState3D) -> void:
	_append_diagnostic_sample(total_buoyancy_torque_samples, total_buoyancy_torque.length(), "total_torque")
	var basis := body_state.transform.basis.orthonormalized()
	var angular := body_state.angular_velocity
	var local_angular := basis.transposed() * angular
	_append_diagnostic_sample(angular_pitch_samples, absf(local_angular.x), "pitch")
	_append_diagnostic_sample(angular_roll_samples, absf(local_angular.z), "roll")
	_append_diagnostic_sample(angular_yaw_samples, absf(local_angular.y), "yaw")
	var local_torque := basis.transposed() * total_buoyancy_torque
	var local_applied_torque := basis.transposed() * _last_applied_buoyancy_torque
	_append_diagnostic_sample(buoyancy_pitch_torque_samples, absf(local_torque.x), "pitch_torque")
	_append_diagnostic_sample(buoyancy_roll_torque_samples, absf(local_torque.z), "roll_torque")
	_append_diagnostic_sample(buoyancy_yaw_torque_samples, absf(local_torque.y), "yaw_torque")
	_append_diagnostic_sample(applied_buoyancy_pitch_torque_samples, absf(local_applied_torque.x), "pitch_torque")
	_append_diagnostic_sample(applied_buoyancy_roll_torque_samples, absf(local_applied_torque.z), "roll_torque")
	_append_diagnostic_sample(applied_buoyancy_yaw_torque_samples, absf(local_applied_torque.y), "yaw_torque")
	_append_diagnostic_sample(wet_angular_damping_torque_samples, _last_wet_angular_damping_torque.length(), "damping_torque")
	var angular_acceleration_world := Vector3.ZERO
	if _has_previous_angular_velocity and body_state.step > 0.0:
		angular_acceleration_world = (angular - _previous_world_angular_velocity) / body_state.step
	var local_angular_acceleration := basis.transposed() * angular_acceleration_world
	_append_diagnostic_sample(angular_pitch_acceleration_samples, absf(local_angular_acceleration.x), "pitch_accel")
	_append_diagnostic_sample(angular_roll_acceleration_samples, absf(local_angular_acceleration.z), "roll_accel")
	_previous_world_angular_velocity = angular
	_has_previous_angular_velocity = true
	effective_inertia_diagnostic = _effective_inertia(body_state.inverse_inertia_tensor, basis)
	var pitch_torque := absf(local_applied_torque.x)
	var roll_torque := absf(local_applied_torque.z)
	var acceleration_magnitude := local_angular_acceleration.length()
	var capture_pitch := _would_enter_top(top_pitch_torque_events, pitch_torque, "pitch_torque_nm")
	var capture_roll := _would_enter_top(top_roll_torque_events, roll_torque, "roll_torque_nm")
	var capture_acceleration := _would_enter_top(top_angular_acceleration_events,
		acceleration_magnitude, "angular_acceleration_magnitude_rad_s2")
	if capture_pitch or capture_roll or capture_acceleration:
		var event := _build_angular_event(local_torque, local_applied_torque,
			local_angular, local_angular_acceleration)
		if capture_pitch: _insert_top_event(top_pitch_torque_events, event, "pitch_torque_nm")
		if capture_roll: _insert_top_event(top_roll_torque_events, event, "roll_torque_nm")
		if capture_acceleration: _insert_top_event(top_angular_acceleration_events, event, "angular_acceleration_magnitude_rad_s2")
	_diagnostic_tick_count += 1
	if _diagnostic_tick_count % 30 == 0:
		top_contact_torque_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return float(a.torque_magnitude_nm) > float(b.torque_magnitude_nm))
		_diagnostic_cache = {"total_buoyancy_force_n": total_buoyancy_force_vector,
			"total_buoyancy_force_magnitude_n": total_buoyancy_force_vector.length(),
			"total_buoyancy_torque_nm": total_buoyancy_torque,
			"total_buoyancy_torque_stats_nm": _sample_stats(total_buoyancy_torque_samples),
			"buoyancy_pitch_torque_nm": _sample_stats(buoyancy_pitch_torque_samples),
			"buoyancy_roll_torque_nm": _sample_stats(buoyancy_roll_torque_samples),
			"buoyancy_yaw_torque_nm": _sample_stats(buoyancy_yaw_torque_samples),
			"applied_buoyancy_pitch_torque_nm": _sample_stats(applied_buoyancy_pitch_torque_samples),
			"applied_buoyancy_roll_torque_nm": _sample_stats(applied_buoyancy_roll_torque_samples),
			"applied_buoyancy_yaw_torque_nm": _sample_stats(applied_buoyancy_yaw_torque_samples),
			"individual_contact_torque_stats_nm": _sample_stats(contact_torque_samples),
			"angular_velocity_pitch_rad_s": _sample_stats(angular_pitch_samples),
			"angular_velocity_roll_rad_s": _sample_stats(angular_roll_samples),
			"angular_velocity_yaw_rad_s": _sample_stats(angular_yaw_samples),
			"angular_acceleration_pitch_rad_s2": _sample_stats(angular_pitch_acceleration_samples),
			"angular_acceleration_roll_rad_s2": _sample_stats(angular_roll_acceleration_samples),
			"wet_angular_damping_torque_nm": _sample_stats(wet_angular_damping_torque_samples),
			"force_rise_n_per_s": _sample_stats(force_rise_samples_n_per_s),
			"force_rise_event_threshold_n": FORCE_RISE_EVENT_THRESHOLD_N,
			"force_rise_event_count": force_rise_event_count,
			"force_rise_limiter_activation_count": force_rise_limiter_activation_count,
			"top_pitch_torque_events": top_pitch_torque_events.duplicate(true),
			"top_roll_torque_events": top_roll_torque_events.duplicate(true),
			"top_angular_acceleration_events": top_angular_acceleration_events.duplicate(true),
			"points": _current_point_diagnostics(),
			"top_contact_torque_events": top_contact_torque_events.duplicate(true),
			"angular_mode": "STABILIZED" if stabilized_angular_mode else "RAW",
			"effective_inertia": effective_inertia_diagnostic.duplicate(true)}


func _effective_inertia(inverse_tensor_world: Basis, body_basis: Basis) -> Dictionary:
	var inverse_tensor_local := body_basis.transposed() * inverse_tensor_world * body_basis
	var tensor_local := inverse_tensor_local.inverse()
	return {"available": inverse_tensor_world.is_finite() and tensor_local.is_finite(),
		"axes": {"pitch": "local +X", "yaw": "local +Y", "roll": "local +Z"},
		"inverse_inertia_tensor_local_columns": [[inverse_tensor_local.x.x, inverse_tensor_local.x.y, inverse_tensor_local.x.z],
			[inverse_tensor_local.y.x, inverse_tensor_local.y.y, inverse_tensor_local.y.z],
			[inverse_tensor_local.z.x, inverse_tensor_local.z.y, inverse_tensor_local.z.z]],
		"inertia_tensor_local_columns": [[tensor_local.x.x, tensor_local.x.y, tensor_local.x.z],
			[tensor_local.y.x, tensor_local.y.y, tensor_local.y.z], [tensor_local.z.x, tensor_local.z.y, tensor_local.z.z]],
		"Ixx_pitch": tensor_local.x.x, "Iyy_yaw": tensor_local.y.y, "Izz_roll": tensor_local.z.z}


func _build_angular_event(local_torque: Vector3, local_applied_torque: Vector3,
		local_angular: Vector3, local_angular_acceleration: Vector3) -> Dictionary:
	var contacts: Array[Dictionary] = []
	for index in BUOYANCY_POINT_COUNT:
		contacts.append({"contact": String(POINT_NAMES[index]), "depth_m": point_depths[index],
			"force_n": point_buoyancy_force_vectors[index].length(),
			"force_direction": point_force_directions[index], "lever_arm_m": point_lever_arms[index],
			"torque_nm": point_buoyancy_torques[index]})
	var rider_torque := Vector3.ZERO
	var controller := get_parent() as JetSkiController
	if controller != null and controller.rider_dynamics_system != null:
		rider_torque = controller.rider_dynamics_system.state.total_applied_torque_vector
	return {"tick": Engine.get_physics_frames(), "scenario": diagnostic_scenario_name,
		"speed_mps": state.sampled_body_linear_velocity.length(),
		"wet_contact_count": state.submerged_point_count, "contacts": contacts,
		"total_buoyancy_force_vector_n": total_buoyancy_force_vector,
		"total_buoyancy_force_magnitude_n": total_buoyancy_force_vector.length(),
		"total_buoyancy_torque_nm": total_buoyancy_torque,
		"applied_buoyancy_torque_nm": _last_applied_buoyancy_torque,
		"wet_angular_damping_torque_nm": _last_wet_angular_damping_torque,
		"rider_control_torque_nm": rider_torque,
		"pitch_torque_nm": absf(local_applied_torque.x), "roll_torque_nm": absf(local_applied_torque.z),
		"potential_pitch_torque_nm": absf(local_torque.x), "potential_roll_torque_nm": absf(local_torque.z),
		"angular_velocity_pitch_rad_s": local_angular.x,
		"angular_velocity_roll_rad_s": local_angular.z,
		"angular_acceleration_pitch_rad_s2": local_angular_acceleration.x,
		"angular_acceleration_roll_rad_s2": local_angular_acceleration.z,
		"angular_acceleration_magnitude_rad_s2": local_angular_acceleration.length(),
		"airborne_previous_frame": _was_airborne_previous_frame,
		"landing_reentry": _landing_reentry_this_frame}


func _insert_top_event(events: Array[Dictionary], event: Dictionary, metric: String) -> void:
	if float(event.get(metric, 0.0)) <= 0.0001: return
	if events.size() < TOP_TORQUE_EVENT_COUNT:
		events.append(event.duplicate(true))
		return
	var smallest_index := 0
	for index in range(1, events.size()):
		if float(events[index].get(metric, 0.0)) < float(events[smallest_index].get(metric, 0.0)):
			smallest_index = index
	if float(event[metric]) > float(events[smallest_index].get(metric, 0.0)):
		events[smallest_index] = event.duplicate(true)


func _would_enter_top(events: Array[Dictionary], value: float, metric: String) -> bool:
	if value <= 0.0001: return false
	if events.size() < TOP_TORQUE_EVENT_COUNT: return true
	for event in events:
		if value > float(event.get(metric, 0.0)): return true
	return false


func _apply_wet_angular_damping(body_state: PhysicsDirectBodyState3D) -> Vector3:
	var wet_fraction := float(state.submerged_point_count) / float(BUOYANCY_POINT_COUNT)
	if wet_fraction <= 0.0: return Vector3.ZERO
	var basis := body_state.transform.basis.orthonormalized()
	var local_angular := basis.transposed() * body_state.angular_velocity
	var local_torque := Vector3(-wet_pitch_damping * local_angular.x,
		-wet_yaw_damping * local_angular.y, -wet_roll_damping * local_angular.z) * wet_fraction
	var world_torque := basis * local_torque
	body_state.apply_torque(world_torque)
	return world_torque


func _current_point_diagnostics() -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for index in BUOYANCY_POINT_COUNT:
		rows.append({"contact": String(POINT_NAMES[index]), "depth_m": point_depths[index],
			"force_n": point_buoyancy_force_vectors[index].length(),
			"force_direction": point_force_directions[index], "lever_arm_m": point_lever_arms[index],
			"torque_nm": point_buoyancy_torques[index],
			"torque_magnitude_nm": point_buoyancy_torques[index].length()})
	return rows


func _append_diagnostic_sample(samples: PackedFloat32Array, value: float, metric: String) -> void:
	if not is_finite(value): return
	if samples.size() < DIAGNOSTIC_WINDOW_SIZE:
		samples.append(value)
	else:
		var cursor := int(_diagnostic_ring_cursors[metric])
		samples[cursor] = value
		_diagnostic_ring_cursors[metric] = (cursor + 1) % DIAGNOSTIC_WINDOW_SIZE


func _sample_stats(samples: PackedFloat32Array) -> Dictionary:
	if samples.is_empty(): return {"mean": 0.0, "p95": 0.0, "max": 0.0}
	var ordered := samples.duplicate()
	ordered.sort()
	var total := 0.0
	for value in samples: total += value
	return {"mean": total / float(samples.size()),
		"p95": ordered[mini(ordered.size() - 1, int(ceil((ordered.size() - 1) * 0.95)))],
		"max": ordered[ordered.size() - 1]}


func get_buoyancy_local_points() -> PackedVector3Array:
	return _buoyancy_local_points.duplicate()


func get_buoyancy_point_depths() -> PackedFloat32Array:
	return _point_depths.duplicate()


func get_buoyancy_point_normal_forces() -> PackedFloat32Array:
	return _point_normal_forces.duplicate()


func get_buoyancy_point_normal_force_vectors() -> PackedVector3Array:
	return _point_buoyancy_force_vectors.duplicate()


func get_buoyancy_point_water_normals() -> PackedVector3Array:
	return _point_water_normals.duplicate()


func get_point_forward_drag_forces() -> PackedVector3Array:
	return _point_forward_drag_forces.duplicate()


func get_point_lateral_drag_forces() -> PackedVector3Array:
	return _point_lateral_drag_forces.duplicate()


func get_point_physical_velocities() -> PackedVector3Array:
	return _point_physical_velocities.duplicate()


func get_point_relative_velocities() -> PackedVector3Array:
	return _point_relative_velocities.duplicate()


func get_point_relative_normal_speeds() -> PackedFloat32Array:
	return _point_relative_normal_speeds.duplicate()


func get_point_sample_valid() -> Array[bool]:
	return _point_sample_valid.duplicate()


func get_signed_point_depth(index: int) -> float:
	if index < 0 or index >= _point_depths.size():
		return 0.0
	return _point_depths[index]


func get_point_world_position(index: int) -> Vector3:
	if index < 0 or index >= _point_world_positions.size():
		return Vector3.ZERO
	return _point_world_positions[index]


func get_point_relative_normal_speed(index: int) -> float:
	if index < 0 or index >= _point_relative_normal_speeds.size():
		return 0.0
	return _point_relative_normal_speeds[index]


func is_point_sample_valid(index: int) -> bool:
	if index < 0 or index >= _point_sample_valid.size():
		return false
	return _point_sample_valid[index]


func get_degenerate_drag_axis_count() -> int:
	return state.degenerate_drag_axis_count


func get_runtime_array_resize_count() -> int:
	return _runtime_array_resize_count


func _resize_runtime_arrays() -> void:
	_runtime_array_resize_count += 1
	_point_depths.resize(BUOYANCY_POINT_COUNT)
	_point_effective_depths.resize(BUOYANCY_POINT_COUNT)
	_point_normal_forces.resize(BUOYANCY_POINT_COUNT)
	_point_buoyancy_force_vectors.resize(BUOYANCY_POINT_COUNT)
	_point_water_normals.resize(BUOYANCY_POINT_COUNT)
	_point_world_positions.resize(BUOYANCY_POINT_COUNT)
	_point_water_surface_positions.resize(BUOYANCY_POINT_COUNT)
	_point_water_velocities.resize(BUOYANCY_POINT_COUNT)
	_point_physical_velocities.resize(BUOYANCY_POINT_COUNT)
	_point_relative_velocities.resize(BUOYANCY_POINT_COUNT)
	_point_relative_normal_speeds.resize(BUOYANCY_POINT_COUNT)
	_point_sample_valid.resize(BUOYANCY_POINT_COUNT)
	_point_forward_drag_forces.resize(BUOYANCY_POINT_COUNT)
	_point_lateral_drag_forces.resize(BUOYANCY_POINT_COUNT)
	point_spring_forces.resize(BUOYANCY_POINT_COUNT)
	point_damping_forces.resize(BUOYANCY_POINT_COUNT)
	point_lever_arms.resize(BUOYANCY_POINT_COUNT)
	point_buoyancy_torques.resize(BUOYANCY_POINT_COUNT)
	point_force_directions.resize(BUOYANCY_POINT_COUNT)
	_previous_contact_forces.resize(BUOYANCY_POINT_COUNT)
	_point_diagnostic_depth.resize(BUOYANCY_POINT_COUNT)
	_point_diagnostic_normal_speed.resize(BUOYANCY_POINT_COUNT)
	point_force_clamp_reached.resize(BUOYANCY_POINT_COUNT)
	point_baseline_force_clamp_reached.resize(BUOYANCY_POINT_COUNT)


func _update_ratios() -> void:
	state.submerged_ratio = (
		float(state.submerged_point_count)
		/ float(BUOYANCY_POINT_COUNT)
	)
	state.front_submerged_ratio = (
		float(state.front_submerged_count)
		/ float(FRONT_POINT_COUNT)
	)
	state.rear_submerged_ratio = (
		float(state.rear_submerged_count)
		/ float(FRONT_POINT_COUNT)
	)


func _apply_point_hydrodynamic_drag(
	body_state: PhysicsDirectBodyState3D,
	point_index: int,
	world_offset: Vector3,
	body_forward: Vector3,
	water_normal: Vector3,
	relative_velocity: Vector3,
	depth_ratio: float
) -> void:
	var normal_component := (
		water_normal * relative_velocity.dot(water_normal)
	)
	var tangential_velocity := relative_velocity - normal_component
	var forward_tangent := (
		body_forward - water_normal * body_forward.dot(water_normal)
	)
	if forward_tangent.length_squared() <= 0.000001:
		state.degenerate_drag_axis_count += 1
		_warn_about_degenerate_axis_once()
		return
	forward_tangent = forward_tangent.normalized()
	var right_tangent := forward_tangent.cross(water_normal)
	if right_tangent.length_squared() <= 0.000001:
		state.degenerate_drag_axis_count += 1
		_warn_about_degenerate_axis_once()
		return
	right_tangent = right_tangent.normalized()
	var forward_speed := tangential_velocity.dot(forward_tangent)
	var lateral_speed := tangential_velocity.dot(right_tangent)
	var immersion_factor := pow(depth_ratio, drag_depth_exponent)
	var forward_drag_scalar := clampf(
		_drag_scalar(
			forward_speed,
			forward_drag_linear_per_point,
			forward_drag_quadratic_per_point
		) * immersion_factor,
		-maximum_forward_drag_force_per_point,
		maximum_forward_drag_force_per_point
	)
	var lateral_drag_scalar := clampf(
		_drag_scalar(
			lateral_speed,
			lateral_drag_linear_per_point,
			lateral_drag_quadratic_per_point
		) * immersion_factor,
		-maximum_lateral_drag_force_per_point,
		maximum_lateral_drag_force_per_point
	)
	var forward_drag := -forward_tangent * forward_drag_scalar
	var lateral_drag := -right_tangent * lateral_drag_scalar
	var drag_force := forward_drag + lateral_drag
	if not drag_force.is_finite():
		_warn_about_invalid_drag_once()
		return
	_point_forward_drag_forces[point_index] = forward_drag
	_point_lateral_drag_forces[point_index] = lateral_drag
	state.total_forward_drag_force += absf(forward_drag_scalar)
	state.total_lateral_drag_force += absf(lateral_drag_scalar)
	state.maximum_point_forward_drag = maxf(
		state.maximum_point_forward_drag,
		absf(forward_drag_scalar)
	)
	state.maximum_point_lateral_drag = maxf(
		state.maximum_point_lateral_drag,
		absf(lateral_drag_scalar)
	)
	state.hydrodynamic_active_point_count += 1
	body_state.apply_force(drag_force, world_offset)


func _update_hydrodynamic_speed_metrics(
	body_state: PhysicsDirectBodyState3D,
	body_forward: Vector3,
	water_normal_sum: Vector3,
	water_velocity_sum: Vector3
) -> void:
	if state.hydrodynamic_active_point_count <= 0:
		return
	var average_water_normal := water_normal_sum.normalized()
	var average_water_velocity := (
		water_velocity_sum
		/ float(state.hydrodynamic_active_point_count)
	)
	state.support_normal = average_water_normal
	state.average_water_velocity = average_water_velocity
	var forward_tangent := (
		body_forward
		- average_water_normal * body_forward.dot(average_water_normal)
	)
	if forward_tangent.length_squared() <= 0.000001:
		return
	forward_tangent = forward_tangent.normalized()
	var right_tangent := (
		forward_tangent.cross(average_water_normal).normalized()
	)
	var relative_center_velocity := (
		body_state.linear_velocity - average_water_velocity
	)
	var tangential_center_velocity := (
		relative_center_velocity
		- average_water_normal
		* relative_center_velocity.dot(average_water_normal)
	)
	state.water_relative_forward_speed = (
		tangential_center_velocity.dot(forward_tangent)
	)
	state.water_relative_lateral_speed = (
		tangential_center_velocity.dot(right_tangent)
	)


func _drag_scalar(
	speed: float,
	linear_coefficient: float,
	quadratic_coefficient: float
) -> float:
	return (
		linear_coefficient * speed
		+ quadratic_coefficient * speed * absf(speed)
	)


func _warn_about_missing_points_once() -> void:
	if _point_warning_emitted:
		return
	_point_warning_emitted = true
	push_warning(
		"JetSki buoyancy is disabled because exactly four "
		+ "buoyancy markers are required."
	)


func _warn_about_invalid_sample_once() -> void:
	if _invalid_sample_warning_emitted:
		return
	_invalid_sample_warning_emitted = true
	push_warning("JetSki water sampling returned a non-finite or invalid value.")


func _warn_about_invalid_drag_once() -> void:
	if _invalid_drag_warning_emitted:
		return
	_invalid_drag_warning_emitted = true
	push_warning("JetSki hydrodynamic drag produced a non-finite force.")


func _warn_about_degenerate_axis_once() -> void:
	if _degenerate_axis_warning_emitted:
		return
	_degenerate_axis_warning_emitted = true
	push_warning("JetSki hydrodynamic drag skipped a degenerate tangent axis.")
