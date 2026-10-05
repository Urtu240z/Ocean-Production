class_name JetSkiInputSystem
extends Node

signal rider_weight_shift_changed(shift: Vector2)

const HALF_LIFE_LOG_TWO: float = 0.6931471805599453
const RIDER_SHIFT_CHANGE_THRESHOLD: float = 0.01

var state: JetSkiInputState = JetSkiInputState.new()
var rider_weight_shift_enabled: bool = true
var rider_input_allowed: bool = true
var rider_shift_input_half_life: float = 0.10
var rider_shift_release_half_life: float = 0.20

var _rider_shift_last_emitted: Vector2 = Vector2.ZERO
var _invalid_rider_shift_warning_emitted: bool = false


func sample_input(physics_delta: float) -> void:
	state.throttle = clampf(
		Input.get_action_strength("throttle"),
		0.0,
		1.0
	)
	state.brake = clampf(Input.get_action_strength("brake"), 0.0, 1.0)
	state.steering = clampf(
		Input.get_action_strength("steer_right")
		- Input.get_action_strength("steer_left"),
		-1.0,
		1.0
	)
	_sample_rider_shift(physics_delta)


func reset() -> void:
	state.throttle = 0.0
	state.brake = 0.0
	state.steering = 0.0
	reset_rider_shift()


func reset_rider_shift() -> void:
	var should_emit_zero := not _rider_shift_last_emitted.is_zero_approx()
	state.rider_shift_raw = Vector2.ZERO
	state.rider_shift_smoothed = Vector2.ZERO
	_rider_shift_last_emitted = Vector2.ZERO
	if should_emit_zero:
		rider_weight_shift_changed.emit(Vector2.ZERO)


func _sample_rider_shift(physics_delta: float) -> void:
	var raw_input := Vector2.ZERO
	if rider_weight_shift_enabled and rider_input_allowed:
		raw_input = Vector2(
			Input.get_action_strength("rider_shift_right")
				- Input.get_action_strength("rider_shift_left"),
			Input.get_action_strength("rider_shift_back")
				- Input.get_action_strength("rider_shift_forward")
		)
	if not raw_input.is_finite():
		_warn_about_invalid_rider_shift_once(
			"Rider weight-shift input is not finite."
		)
		raw_input = Vector2.ZERO
	if raw_input.length_squared() > 1.0:
		raw_input = raw_input.normalized()
	state.rider_shift_raw = raw_input
	var half_life := (
		rider_shift_release_half_life
		if raw_input.is_zero_approx()
		else rider_shift_input_half_life
	)
	var blend_weight := 1.0 - exp(
		-HALF_LIFE_LOG_TWO
		* maxf(physics_delta, 0.0)
		/ maxf(half_life, 0.0001)
	)
	state.rider_shift_smoothed = state.rider_shift_smoothed.lerp(
		raw_input,
		clampf(blend_weight, 0.0, 1.0)
	)
	if not state.rider_shift_smoothed.is_finite():
		_warn_about_invalid_rider_shift_once(
			"Smoothed rider weight-shift input is not finite."
		)
		state.rider_shift_smoothed = Vector2.ZERO
	if (
		state.rider_shift_smoothed.distance_to(_rider_shift_last_emitted)
		>= RIDER_SHIFT_CHANGE_THRESHOLD
		or (
			state.rider_shift_smoothed.is_zero_approx()
			and not _rider_shift_last_emitted.is_zero_approx()
		)
	):
		_rider_shift_last_emitted = state.rider_shift_smoothed
		rider_weight_shift_changed.emit(state.rider_shift_smoothed)


func _warn_about_invalid_rider_shift_once(message: String) -> void:
	if _invalid_rider_shift_warning_emitted:
		return
	_invalid_rider_shift_warning_emitted = true
	push_warning(message)
