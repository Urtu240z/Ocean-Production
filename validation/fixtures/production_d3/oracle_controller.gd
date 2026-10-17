extends JetSkiController
const BuoyancyHud = preload("res://addons/jet_ski/debug/jet_ski_buoyancy_hud.gd")

func _ready() -> void:
	_auto_center_of_mass_local = center_of_mass
	inertia = Vector3.ZERO
	input_system.rider_weight_shift_changed.connect(
		_on_input_system_rider_weight_shift_changed
	)
	_respawn_transform = global_transform
	_has_respawn_transform = true
	_resolve_water_reference()
	_configure_water_physics_system()
	var buoyancy_hud := BuoyancyHud.new()
	add_child(buoyancy_hud)
	_configure_navigation_system()
	_connect_navigation_signals()
	_configure_drive_system()
	_configure_rider_dynamics_system()
	_configure_submarine_system()
	_configure_trick_system()
	_connect_submarine_signals()
	_connect_trick_signals()
	navigation_system.reset_runtime_state()
	drive_system.reset_runtime_state()
	rider_dynamics_system.reset_runtime_state()
	input_system.reset_rider_shift()
	submarine_system.reset_runtime_state(false)
	trick_system.reset_runtime_state()
	arcade_handling_system.reset_turn_continuity_state()
	reset_physics_interpolation()

func _perf2_integrate_forces_body(state: PhysicsDirectBodyState3D) -> void:
	powered_trim_torque = Vector3.ZERO
	submarine_level_torque = Vector3.ZERO
	nose_recovery_torque = Vector3.ZERO
	nose_recovery_authority = 0.0
	nose_up_limit_torque = Vector3.ZERO
	nose_up_limit_active = false
	nose_up_contact_authority = 0.0
	nose_up_current_pitch_degrees = rad_to_deg(NoseUpLimit.world_pitch(state.transform.basis))
	rider_dynamics_system.external_nose_up_limit_active = false
	_capture_auto_inertia(state)
	_sync_heavy_hull_configuration()
	water_physics_system.hull_arcade_enabled = is_normal_hull_arcade_active()
	water_physics_system.hull_bow_braking_mps2 = hull_v1_bow_braking_mps2
	water_physics_system.hull_bow_yaw_damping_rate = hull_v1_bow_yaw_damping_rate
	water_physics_system.hull_rebound_damping_rate = hull_v1_rebound_damping_rate
	water_physics_system.hull_rebound_min_depth_m = hull_v1_rebound_min_depth_m
	water_physics_system.hull_submarine_target_depth_m = hull_v1_submarine_target_depth_m
	water_physics_system.hull_submarine_sink_speed_mps = hull_v1_submarine_sink_speed_mps
	submarine_system.level_hold_enabled = is_normal_hull_arcade_active()
	submarine_system.level_start_depth_m = hull_v1_submarine_level_start_depth_m
	submarine_system.level_transition_seconds = hull_v1_submarine_level_transition_seconds
	submarine_system.level_target_depth_m = hull_v1_submarine_target_depth_m
	submarine_system.level_current_root_depth_m = water_physics_system.hull_root_depth_m
	submarine_system.level_exit_speed_mps = hull_v1_submarine_exit_speed_mps
	water_physics_system.landing_penetration_enabled = landing_penetration_enabled
	water_physics_system.landing_entry_speed_threshold = landing_entry_speed_threshold
	water_physics_system.landing_upward_damping_multiplier = landing_upward_damping_multiplier
	_apply_requested_inertia_mode()
	navigation_system.begin_physics_tick()
	drive_system.begin_physics_tick()
	rider_dynamics_system.begin_physics_tick()
	trick_system.begin_physics_tick()
	input_system.rider_weight_shift_enabled = rider_weight_shift_enabled
	input_system.rider_shift_input_half_life = rider_shift_input_half_life
	input_system.rider_shift_release_half_life = rider_shift_release_half_life
	var controls_locked := (
		wipeout_system != null
		and bool(wipeout_system.call("is_vehicle_control_locked"))
	)
	input_system.rider_input_allowed = (
		not freeze
		and process_mode != Node.PROCESS_MODE_DISABLED
		and not get_tree().paused
		and not controls_locked
	)
	input_system.sample_input(state.step)
	water_physics_system.takeoff_rider_shift = input_system.state.rider_shift_raw
	water_physics_system.hull_steering_input = input_system.state.steering
	if not is_instance_valid(_water_provider):
		water_physics_system.reset_runtime_state()
		_warn_about_missing_water_once()
		return
	if not water_physics_system.has_valid_buoyancy_points():
		water_physics_system.reset_runtime_state()
		return
	if not controls_locked:
		var current_attitude := (
			rider_dynamics_system.calculate_world_attitude(state.transform)
		)
		if is_normal_hull_arcade_active():
			submarine_system.try_supported_dive(state, input_system.state,
				current_attitude, water_physics_system)
		submarine_system.update_before_forces(
			state,
			input_system.state,
			current_attitude,
			state.step
		)
	var extra_local_points := PackedVector3Array()
	if use_arcade_turn_continuity:
		extra_local_points.append(Vector3.ZERO)
	if drive_system.has_valid_propulsion_point():
		extra_local_points.append(drive_system.get_propulsion_local_point())
	if _water_consumer_context != null:
		_water_provider.select_consumer(_water_consumer_context)
	_water_provider.prepare_water_queries(state.transform,
		water_physics_system.get_water_query_local_points(), extra_local_points, state.step)
	var water_buoyancy_factor := 1.0 if controls_locked else submarine_system.state.buoyancy_factor_current
	water_physics_system.hull_submarine_authority = smoothstep(0.0, 0.12, submarine_system.state.duration) \
		if not controls_locked and is_normal_hull_arcade_active() and submarine_system.is_dive_active() else 0.0
	if not controls_locked and is_normal_hull_arcade_active() and submarine_system.get_control_blend() > 0.0:
		var full_displaced_mass := 1000.0 * water_physics_system.hull_buoyancy.total_volume_m3
		var dive_factor := mass * hull_v1_submarine_support_ratio / maxf(full_displaced_mass, 1.0)
		var dive_weight := smoothstep(0.0, 0.12, submarine_system.state.duration) \
			if submarine_system.is_dive_active() else 1.0 - smoothstep(0.0, 1.0, submarine_system.state.exit_blend)
		water_buoyancy_factor = minf(water_buoyancy_factor, lerpf(1.0, dive_factor, dive_weight))
	var water_state := water_physics_system.step(
		state,
		_water_provider,
		water_buoyancy_factor
	)
	navigation_system.prepare_support_state(state, water_state)
	if not controls_locked and water_state.raw_contact_mask == 0:
		var pre_contact_attitude := (
			rider_dynamics_system.calculate_world_attitude(state.transform)
		)
		submarine_system.capture_pre_contact_state(
			state,
			pre_contact_attitude
		)
	navigation_system.step(
		state,
		water_physics_system,
		state.step
	)
	if navigation_system.state.has_any_support or not is_normal_hull_arcade_active():
		_hull_v1_release_elapsed = -1.0
	elif navigation_system.state.true_takeoff_this_tick:
		_hull_v1_release_elapsed = 0.0
	elif _hull_v1_release_elapsed >= 0.0:
		_hull_v1_release_elapsed += state.step
	if navigation_system.state.true_takeoff_this_tick and (
		water_physics_system.buoyancy_mode == JetSkiWaterPhysicsSystem.BuoyancyMode.LEGACY_4POINT
		or is_normal_hull_arcade_active()):
		water_physics_system.handle_takeoff_transition(state, is_normal_hull_arcade_active())
	if (
		navigation_system.state.navigation_state
		== NavigationState.AIRBORNE
	):
		_airborne_state_confirmed_for_landing = true
	if controls_locked:
		return
	submarine_system.update_after_contacts(
		input_system.state,
		water_state,
		navigation_system.state,
		water_physics_system
	)
	trick_system.update_state(
		state,
		input_system.state,
		water_state,
		navigation_system.state,
		rider_weight_shift_enabled,
		trick_preload_enabled,
		submarine_system.is_dive_active(),
		state.step
	)
	if use_arcade_turn_continuity:
		arcade_handling_system.step_turn_continuity(
			state,
			input_system.state,
			water_state,
			_water_provider,
			state.step
		)
	var airborne_contact_factor := (
		0.0 if water_state.raw_contact_mask == 0 or water_physics_system.contact_is_airborne else 1.0
	)
	if water_physics_system.anti_hop_enabled and water_state.raw_contact_mask == 0:
		airborne_contact_factor = water_physics_system.get_propulsion_contact_grace_factor()
	# An immersed bow should coast into a submarine rather than keep full jet
	# thrust while its drag is softened. The normal surface engine is unchanged.
	var propulsion_factor := submarine_system.state.propulsion_factor_current \
		* lerpf(1.0, hull_v1_buried_thrust_factor, water_physics_system.bow_plow_authority)
	if is_normal_hull_arcade_active() and submarine_system.is_dive_active():
		# The underwater trick coasts on its entry momentum. Full throttle must
		# not indefinitely cancel water friction and prevent the low-speed exit.
		propulsion_factor *= 1.0 - submarine_system.state.horizontal_blend
	if use_arcade_turn_continuity:
		drive_system.step(
			state,
			_water_provider,
			arcade_handling_system.get_drive_input(input_system.state),
			propulsion_factor,
			airborne_contact_factor
		)
	else:
		drive_system.step(
			state,
			_water_provider,
			input_system.state,
			propulsion_factor,
			airborne_contact_factor
		)
	nose_up_contact_authority = _powered_nose_up_contact_authority(state)
	rider_dynamics_system.external_nose_up_limit_active = nose_up_contact_authority > 0.0
	_apply_rider_dynamics(state)
	_apply_powered_nose_up_limit(state)
	_apply_auto_nose_recovery(state)
	_apply_powered_running_trim(state)
	_apply_submarine_level_hold(state)
