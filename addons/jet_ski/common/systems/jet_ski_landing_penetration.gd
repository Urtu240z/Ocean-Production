extends RefCounted
## A dry-to-wet landing latch, not a general reduction of buoyancy or drag.
var dry_seconds := 0.0
var armed := false
var active := false
var entry_speed := 0.0


func begin_tick(allowed: bool) -> void:
	if not allowed:
		active = false
		armed = false


func damping_multiplier(allowed: bool, relative_down_speed: float,
		threshold: float, minimum_multiplier: float) -> float:
	var start := maxf(threshold, 0.5)
	if armed:
		armed = false
		entry_speed = relative_down_speed
		active = allowed and relative_down_speed > start
	if not allowed or not active: return 1.0
	# Full normal damping returns continuously as descent slows. Existing
	# immersed-volume damping and rho*g*V also grow as the craft sinks.
	return lerpf(1.0, clampf(minimum_multiplier, 0.0, 1.0),
		smoothstep(start, 1.5 * start, relative_down_speed))


func end_tick(wet: bool, mean_down_speed: float, threshold: float, dt: float) -> void:
	if not wet:
		dry_seconds += dt
		armed = dry_seconds >= 0.08
		active = false
		return
	dry_seconds = 0.0
	armed = false
	if mean_down_speed <= maxf(threshold, 0.5): active = false
