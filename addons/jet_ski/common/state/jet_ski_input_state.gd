class_name JetSkiInputState
extends RefCounted

var throttle: float = 0.0
var brake: float = 0.0
var steering: float = 0.0
var rider_shift_raw: Vector2 = Vector2.ZERO
var rider_shift_smoothed: Vector2 = Vector2.ZERO


func reset() -> void:
	throttle = 0.0
	brake = 0.0
	steering = 0.0
	rider_shift_raw = Vector2.ZERO
	rider_shift_smoothed = Vector2.ZERO
