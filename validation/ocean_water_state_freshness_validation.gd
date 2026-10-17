extends SceneTree
const Medium = preload("res://addons/ocean/underwater/ocean_underwater_medium.gd")
var failures: Array[String] = []

class FakeMedium extends OceanUnderwaterMedium:
	var sensor: Dictionary = {}
	func get_waterline_state() -> Dictionary:
		return sensor


func _initialize() -> void:
	_run.call_deferred()


func check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("WATER_STATE_FRESHNESS: " + message)


func _sample(medium: FakeMedium, frame: int, distance: float) -> void:
	medium.sensor = {"valid": true, "frame": frame, "request_time_s": Time.get_ticks_usec() * 0.000001,
		"signed_distance_to_surface": distance, "source_render_frame_id": 10}
	medium._update_runtime_water_state()


func _run() -> void:
	var medium := FakeMedium.new()
	var sample := {"request_time_s": 10.0, "source_render_frame_id": 100}
	check(not medium._sensor_is_stale(sample, 10.02, 102), "normal async readback remains fresh")
	check(not medium._sensor_is_stale(sample, 10.35, 102), "CPU pause with no rendered progress does not expire data")
	check(not medium._sensor_is_stale(sample, 10.35, 104), "async pipeline gets four rendered frames to recover")
	check(medium._sensor_is_stale(sample, 10.35, 105), "actual stalled readback expires after rendered progress")
	check(medium._sensor_is_stale({"request_time_s": -1.0}, 10.0, 100), "missing sensor does not become AIR_SAFE")
	check(medium._sensor_is_stale({"request_time_s": 10.0, "source_render_frame_id": 0}, 10.35, 100), "unknown old frame is treated conservatively")
	_sample(medium, 1, 2.2)
	_sample(medium, 2, 2.2)
	check(medium.get("_runtime_water_state") == &"AIR_SAFE", "stationary air camera enters AIR_SAFE")
	_sample(medium, 3, -0.12)
	check(medium.get("_runtime_water_state") == &"TRANSITION", "first fresh water crossing wakes the effect immediately")
	_sample(medium, 4, -1.0)
	_sample(medium, 5, -1.0)
	check(medium.get("_runtime_water_state") == &"UNDERWATER_SAFE", "submersion still enters UNDERWATER_SAFE")
	medium.sensor = {"valid": false, "request_time_s": Time.get_ticks_usec() * 0.000001}
	medium._update_runtime_water_state()
	check(medium.get("_runtime_water_state") == &"TRANSITION", "genuine invalid data still uses the conservative fallback")
	medium.free()
	print("WATER_STATE_FRESHNESS_VALIDATION ", "PASS" if failures.is_empty() else "FAIL", " | ", failures)
	quit(0 if failures.is_empty() else 1)
