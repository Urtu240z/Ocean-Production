extends "res://addons/jet_ski/common/systems/jet_ski_water_physics_system.gd"
## Isolated candidate. Same force loop; reads existing per-vehicle packed output.
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
	if not hull_buoyancy.is_native_ready(): return state
	if _hull_native_samples.size() != HullBuoyancyV1.SAMPLE_COUNT:
		_hull_native_samples.clear()
		for _i in HullBuoyancyV1.SAMPLE_COUNT: _hull_native_samples.append(WaterSample3D.new())
	# Keep the experimental native path's exact query and force order.
	for i in HullBuoyancyV1.SAMPLE_COUNT:
		var point: Vector3 = body_state.transform*hull_buoyancy.local_points[i]
		_hull_native_samples[i] = water_provider.sample_water(point,_hull_native_samples[i])
		if water_provider.has_method("sample_comparison_water"):
			water_provider.call("sample_comparison_water",point,_comparison_water_scratch)
	if not hull_buoyancy.integrate_native_batch(body_state.transform,_hull_native_samples,buoyancy_draft_offset_m):
		return state
	var compact_cells: PackedFloat64Array = hull_buoyancy._native_values
	for index in hull_buoyancy.local_points.size():
		var query_point: Vector3 = body_state.transform * hull_buoyancy.local_points[index]
		# begin_gameplay_contacts has already prefetched these twelve in one batch.
		var sample: WaterSample3D = _hull_native_samples[index]
		if not sample.valid or not sample.normal.is_finite() or not sample.velocity.is_finite() \
				or not sample.surface_position.is_finite() or sample.normal.length_squared() < 0.000001:
			continue
		var normal: Vector3 = hull_buoyancy._native_normals[index]
		if normal.y < 0.0:
			normal = -normal
		sample.normal = normal
		var cell: Dictionary = hull_buoyancy.cells[index]
		var native_offset := index*10
		var contact: int = cell.contact
		var position := Vector3(compact_cells[native_offset+2],compact_cells[native_offset+3],compact_cells[native_offset+4])
		var world_offset := position - body_state.transform.origin
		var physical_velocity := body_state.get_velocity_at_local_position(world_offset)
		var relative_velocity := physical_velocity - sample.velocity
		var relative_normal_speed := relative_velocity.dot(normal)
		var raw_depth: float = compact_cells[native_offset+5]
		var volume: float = maxf(compact_cells[native_offset+1], 0.0)
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

