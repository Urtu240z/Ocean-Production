extends RefCounted
## Keep a valid horizontal heading while the hull pitches through vertical.
var backward := Vector3.BACK
var _projection_allowed := true


func reset(body_basis: Basis) -> void:
	var projected := Vector3(body_basis.z.x, 0.0, body_basis.z.z)
	if projected.length_squared() > 0.0625:
		backward = projected.normalized()
	_projection_allowed = body_basis.y.y > 0.35


func update(body_basis: Basis, delta: float, response_rate: float) -> Vector3:
	var projected := Vector3(body_basis.z.x, 0.0, body_basis.z.z)
	# Hysteresis prevents repeatedly switching modes on the crest of a wave.
	if body_basis.y.y < 0.20 or projected.length_squared() < 0.0625:
		_projection_allowed = false
	elif body_basis.y.y > 0.35 and projected.length_squared() > 0.1225:
		_projection_allowed = true
	if _projection_allowed:
		var target := projected.normalized()
		var angle := backward.signed_angle_to(target, Vector3.UP)
		var blend := 1.0 - exp(-maxf(response_rate, 0.0) * maxf(delta, 0.0))
		var step_angle := clampf(angle * blend, -4.0 * delta, 4.0 * delta)
		backward = backward.rotated(Vector3.UP, step_angle).normalized()
	return backward
