class_name JetSkiNavigationSystem
extends Node

signal water_entered(intensity: float, position: Vector3)
signal water_exited()
signal hard_landing(intensity: float, position: Vector3)
signal deeply_submerged()

const NavigationState = JetSkiTypes.NavigationState
const LandingEntryType = JetSkiTypes.LandingEntryType

const BUOYANCY_POINT_COUNT: int = 4
const ALL_CONTACT_MASK: int = 15
const FRONT_CONTACT_MASK: int = 3
const REAR_CONTACT_MASK: int = 12
const LEFT_CONTACT_MASK: int = 5
const RIGHT_CONTACT_MASK: int = 10
const SUPPORT_MINIMUM_UP_DOT: float = 0.20

var state: JetSkiNavigationState = JetSkiNavigationState.new()

var airborne_confirmation_time: float = 0.1
var airborne_minimum_clearance: float = 0.05
var landing_state_duration: float = 0.2
var minimum_landing_speed: float = 1.0
var maximum_landing_speed: float = 12.0
var hard_landing_speed: float = 6.0
var deep_submersion_average_depth: float = 0.7
var deep_submersion_release_depth: float = 0.4
var deep_submersion_required_points: int = 4


func begin_physics_tick() -> void:
	state.true_takeoff_this_tick = false


func prepare_support_state(
	body_state: PhysicsDirectBodyState3D,
	water_state: JetSkiWaterState
) -> void:
	var solid_support_count: int = 0
	var physical_contact_count := body_state.get_contact_count()
	var physical_delta_velocity: float = 0.0
	var physical_position := body_state.transform.origin
	var body_basis := body_state.transform.basis.orthonormalized()
	for contact_index in physical_contact_count:
		var contact_impulse := body_state.get_contact_impulse(contact_index)
		if contact_impulse.is_finite():
			var contact_delta_velocity := (
				contact_impulse.length() * body_state.inverse_mass
			)
			if contact_delta_velocity > physical_delta_velocity:
				physical_delta_velocity = contact_delta_velocity
				physical_position = body_state.get_contact_local_position(
					contact_index
				)
		var collider_object: Object = (
			body_state.get_contact_collider_object(contact_index)
		)
		if not is_instance_valid(collider_object):
			continue
		var local_normal := body_state.get_contact_local_normal(contact_index)
		if (
			not local_normal.is_finite()
			or local_normal.length_squared() <= 0.000001
		):
			continue
		var support_normal := (body_basis * local_normal).normalized()
		if (
			support_normal.is_finite()
			and support_normal.dot(Vector3.UP) >= SUPPORT_MINIMUM_UP_DOT
		):
			solid_support_count += 1
	_update_support_state(
		water_state.raw_contact_mask,
		physical_contact_count,
		solid_support_count,
		physical_delta_velocity,
		physical_position
	)


func step(
	body_state: PhysicsDirectBodyState3D,
	water_system: JetSkiWaterPhysicsSystem,
	physics_delta: float
) -> void:
	_step_navigation_state(
		body_state.transform.origin,
		body_state.linear_velocity,
		water_system,
		physics_delta
	)


func reset_runtime_state() -> void:
	state.reset_runtime_state()


func clear_navigation_statistics() -> void:
	state.clear_statistics()


func count_contact_bits(contact_mask: int) -> int:
	var contact_count: int = 0
	for index in BUOYANCY_POINT_COUNT:
		if (contact_mask & (1 << index)) != 0:
			contact_count += 1
	return contact_count


func classify_landing_entry(
	contact_mask: int
) -> JetSkiTypes.LandingEntryType:
	var masked_contact := contact_mask & ALL_CONTACT_MASK
	var contact_count := count_contact_bits(masked_contact)
	if contact_count == 1:
		return LandingEntryType.SINGLE_POINT
	if masked_contact == ALL_CONTACT_MASK:
		return LandingEntryType.FLAT
	if masked_contact == FRONT_CONTACT_MASK:
		return LandingEntryType.FRONT
	if masked_contact == REAR_CONTACT_MASK:
		return LandingEntryType.REAR
	if masked_contact == LEFT_CONTACT_MASK:
		return LandingEntryType.LEFT
	if masked_contact == RIGHT_CONTACT_MASK:
		return LandingEntryType.RIGHT
	if masked_contact == 6 or masked_contact == 9:
		return LandingEntryType.DIAGONAL
	return LandingEntryType.UNKNOWN


func get_navigation_state_name(
	value: JetSkiTypes.NavigationState
) -> StringName:
	match value:
		NavigationState.IN_WATER:
			return &"IN_WATER"
		NavigationState.PARTIALLY_SUBMERGED:
			return &"PARTIALLY_SUBMERGED"
		NavigationState.AIRBORNE:
			return &"AIRBORNE"
		NavigationState.LANDING:
			return &"LANDING"
		NavigationState.DEEP_SUBMERGED:
			return &"DEEP_SUBMERGED"
	return &"PARTIALLY_SUBMERGED"


func get_landing_entry_type_name(
	value: JetSkiTypes.LandingEntryType
) -> StringName:
	match value:
		LandingEntryType.FRONT:
			return &"FRONT"
		LandingEntryType.REAR:
			return &"REAR"
		LandingEntryType.LEFT:
			return &"LEFT"
		LandingEntryType.RIGHT:
			return &"RIGHT"
		LandingEntryType.FLAT:
			return &"FLAT"
		LandingEntryType.DIAGONAL:
			return &"DIAGONAL"
		LandingEntryType.SINGLE_POINT:
			return &"SINGLE_POINT"
		LandingEntryType.UNKNOWN:
			return &"UNKNOWN"
	return &"UNKNOWN"


func _update_support_state(
	raw_water_contact_mask: int,
	physical_contact_count: int,
	solid_support_contact_count: int,
	physical_contact_delta_velocity: float,
	physical_contact_position: Vector3
) -> void:
	var was_supported := state.has_any_support
	state.has_water_support = (
		raw_water_contact_mask & ALL_CONTACT_MASK
	) != 0
	state.physical_contact_count = physical_contact_count
	state.solid_support_contact_count = solid_support_contact_count
	state.physical_contact_delta_velocity = physical_contact_delta_velocity
	state.physical_contact_position = physical_contact_position
	state.has_solid_support = state.solid_support_contact_count > 0
	state.has_any_support = state.has_water_support or state.has_solid_support
	if not state.support_state_initialized:
		state.support_state_initialized = true
		state.previous_has_any_support = state.has_any_support
		state.true_takeoff_this_tick = false
		return
	state.previous_has_any_support = was_supported
	state.true_takeoff_this_tick = (
		state.previous_has_any_support and not state.has_any_support
	)


func _step_navigation_state(
	body_position: Vector3,
	body_linear_velocity: Vector3,
	water_system: JetSkiWaterPhysicsSystem,
	physics_delta: float
) -> void:
	var water_state := water_system.state
	if not state.navigation_initialized:
		state.navigation_initialized = true
		state.current_contact_mask = (
			water_state.raw_contact_mask & ALL_CONTACT_MASK
		)
		state.previous_contact_mask = state.current_contact_mask
		state.new_contact_mask = 0
		state.lost_contact_mask = 0
	else:
		state.previous_contact_mask = state.current_contact_mask
		state.current_contact_mask = (
			water_state.raw_contact_mask & ALL_CONTACT_MASK
		)
		state.new_contact_mask = (
			state.current_contact_mask
			& (~state.previous_contact_mask)
			& ALL_CONTACT_MASK
		)
		state.lost_contact_mask = (
			state.previous_contact_mask
			& (~state.current_contact_mask)
			& ALL_CONTACT_MASK
		)
	var has_confirmed_clearance := (
		state.current_contact_mask == 0
		and water_state.maximum_signed_point_depth
		<= -airborne_minimum_clearance
	)
	if has_confirmed_clearance:
		state.dry_contact_time += physics_delta
	else:
		state.dry_contact_time = 0.0
	_update_deep_submersion_detection(water_state)
	if state.navigation_state == NavigationState.LANDING:
		state.landing_state_time_remaining = maxf(
			state.landing_state_time_remaining - physics_delta,
			0.0
		)
		if state.current_contact_mask != 0:
			state.has_ever_contacted_water = true
		if state.landing_state_time_remaining > 0.0:
			return
		if state.dry_contact_time >= airborne_confirmation_time:
			_confirm_airborne(body_position, body_linear_velocity)
		else:
			state.navigation_state = _derive_contact_navigation_state()
		return
	if state.has_confirmed_airborne:
		if (
			state.current_contact_mask != 0
			and state.new_contact_mask != 0
		):
			_record_landing(body_position, water_system)
			state.has_ever_contacted_water = true
		else:
			state.navigation_state = NavigationState.AIRBORNE
			state.current_airtime += physics_delta
		return
	if (
		state.current_contact_mask == 0
		and state.dry_contact_time >= airborne_confirmation_time
	):
		_confirm_airborne(body_position, body_linear_velocity)
		return
	if state.current_contact_mask != 0:
		state.has_ever_contacted_water = true
	state.navigation_state = _derive_contact_navigation_state()


func _update_deep_submersion_detection(
	water_state: JetSkiWaterState
) -> void:
	var required_points := clampi(
		deep_submersion_required_points,
		1,
		BUOYANCY_POINT_COUNT
	)
	var deeply_submerged_now := (
		water_state.submerged_point_count >= required_points
		and water_state.average_depth >= deep_submersion_average_depth
	)
	if not state.deep_submersion_latched and deeply_submerged_now:
		state.deep_submersion_latched = true
		state.deep_submersion_count += 1
		deeply_submerged.emit()
	elif state.deep_submersion_latched and (
		water_state.submerged_point_count < required_points
		or water_state.average_depth <= deep_submersion_release_depth
	):
		state.deep_submersion_latched = false


func _confirm_airborne(
	body_position: Vector3,
	body_linear_velocity: Vector3
) -> void:
	if state.has_confirmed_airborne:
		return
	state.has_confirmed_airborne = true
	state.navigation_state = NavigationState.AIRBORNE
	state.current_airtime = 0.0
	state.takeoff_position = body_position
	state.takeoff_linear_velocity = body_linear_velocity
	if state.has_ever_contacted_water:
		state.water_exit_count += 1
		water_exited.emit()


func _record_landing(
	body_position: Vector3,
	water_system: JetSkiWaterPhysicsSystem
) -> void:
	var first_contact_mask := state.new_contact_mask & ALL_CONTACT_MASK
	var landing_position_sum := Vector3.ZERO
	var landing_position_count: int = 0
	var landing_normal_speed: float = 0.0
	for index in BUOYANCY_POINT_COUNT:
		var point_bit := 1 << index
		if (first_contact_mask & point_bit) == 0:
			continue
		landing_position_sum += water_system.get_point_world_position(index)
		landing_position_count += 1
		if water_system.is_point_sample_valid(index):
			var point_entry_speed := maxf(
				-water_system.get_point_relative_normal_speed(index),
				0.0
			)
			landing_normal_speed = maxf(
				landing_normal_speed,
				point_entry_speed
			)
	if landing_position_count > 0:
		state.last_landing_position = (
			landing_position_sum / float(landing_position_count)
		)
	else:
		state.last_landing_position = _average_position_for_contact_mask(
			state.current_contact_mask,
			body_position,
			water_system
		)
	state.last_landing_normal_speed = landing_normal_speed
	state.last_landing_intensity = _inverse_lerp_clamped(
		minimum_landing_speed,
		maximum_landing_speed,
		landing_normal_speed
	)
	state.last_landing_contact_mask = first_contact_mask
	state.last_landing_contact_count = count_contact_bits(first_contact_mask)
	state.last_landing_entry_type = classify_landing_entry(first_contact_mask)
	state.last_airtime = state.current_airtime
	state.maximum_recorded_airtime = maxf(
		state.maximum_recorded_airtime,
		state.last_airtime
	)
	state.current_airtime = 0.0
	state.has_confirmed_airborne = false
	state.landing_state_time_remaining = landing_state_duration
	state.navigation_state = NavigationState.LANDING
	state.water_entry_count += 1
	water_entered.emit(
		state.last_landing_intensity,
		state.last_landing_position
	)
	if state.last_landing_normal_speed >= hard_landing_speed:
		state.hard_landing_count += 1
		hard_landing.emit(
			state.last_landing_intensity,
			state.last_landing_position
		)


func _derive_contact_navigation_state() -> JetSkiTypes.NavigationState:
	if state.deep_submersion_latched:
		return NavigationState.DEEP_SUBMERGED
	if state.current_contact_mask == ALL_CONTACT_MASK:
		return NavigationState.IN_WATER
	return NavigationState.PARTIALLY_SUBMERGED


func _average_position_for_contact_mask(
	contact_mask: int,
	fallback_position: Vector3,
	water_system: JetSkiWaterPhysicsSystem
) -> Vector3:
	var position_sum := Vector3.ZERO
	var point_count: int = 0
	for index in BUOYANCY_POINT_COUNT:
		if (contact_mask & (1 << index)) == 0:
			continue
		position_sum += water_system.get_point_world_position(index)
		point_count += 1
	if point_count <= 0:
		return fallback_position
	return position_sum / float(point_count)


func _inverse_lerp_clamped(from: float, to: float, value: float) -> float:
	if to <= from:
		return 1.0 if value >= to else 0.0
	return clampf(inverse_lerp(from, to, value), 0.0, 1.0)
