extends SceneTree
## Real GPU sensor, flat water and a stationary camera. Runtime-only settings.
const SCENE = preload("res://gameplay/jet_ski_ocean.tscn")


func _initialize() -> void:
	_run.call_deferred()


func _frames(count: int) -> void:
	for frame in count:
		await process_frame
	await RenderingServer.frame_post_draw


func _run() -> void:
	var scene := SCENE.instantiate()
	var ocean := scene.get_node("Production/Ocean") as Ocean
	ocean.wind_speed_mps = 0.0
	ocean.wave_height_scale = 0.0
	root.add_child(scene)
	for frame in 240:
		await process_frame
		if scene.get("ready_to_drive"):
			break
	if not scene.get("ready_to_drive"):
		push_error("WATER_STATE_STALL: scene failed to initialize")
		quit(1)
		return
	scene.follow_camera = false
	scene.ski.freeze = true
	scene.camera.global_position = Vector3(40, 2.2, 0)
	scene.camera.look_at(Vector3(40, 2.2, -1))
	var medium := ocean.get_node("OceanUnderwaterMedium") as OceanUnderwaterMedium
	await _frames(60)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--natural-run-seconds="):
			var duration := float(argument.trim_prefix("--natural-run-seconds="))
			scene.ski.freeze = false
			Input.action_press("throttle")
			var started := Time.get_ticks_usec()
			var previous := started
			var frame_times: Array[float] = []
			var stalls := 0
			while Time.get_ticks_usec() - started < duration * 1000000.0:
				await process_frame
				var now := Time.get_ticks_usec()
				var frame_ms := (now - previous) * 0.001
				previous = now
				frame_times.append(frame_ms)
				if frame_ms > 100.0:
					stalls += 1
					var state := medium.get_waterline_state()
					print("WATER_STATE_NATURAL_STALL ", JSON.stringify({"frame_ms": frame_ms,
						"readback_valid": state.get("valid", false), "runtime_state": medium.get("_runtime_water_state")}))
			Input.action_release("throttle")
			scene.ski.freeze = true
			frame_times.sort()
			print("WATER_STATE_NATURAL_RESULT ", JSON.stringify({"seconds": duration, "samples": frame_times.size(),
				"max_frame_ms": frame_times[-1], "p95_frame_ms": frame_times[int(frame_times.size() * 0.95)], "stalls_over_100ms": stalls}))
	var false_transitions := 0
	for trial in 3:
		var before := medium.get_waterline_state()
		var rendered_before := Engine.get_frames_drawn()
		OS.delay_msec(350)
		var after := medium.get_waterline_state()
		medium._update_runtime_water_state()
		var state: StringName = medium.get("_runtime_water_state")
		if state != &"AIR_SAFE":
			false_transitions += 1
		print("WATER_STATE_STALL_SAMPLE ", JSON.stringify({
			"trial": trial, "valid": after.get("valid", false),
			"distance": after.get("signed_distance_to_surface", NAN),
			"age_ms": (Time.get_ticks_usec() * 0.000001 - float(after.get("request_time_s", 0.0))) * 1000.0,
			"rendered_frames_during_pause": Engine.get_frames_drawn() - rendered_before,
			"sensor_frame_before": before.get("frame", 0), "sensor_frame_after": after.get("frame", 0),
			"runtime_state": state,
		}))
		await _frames(20)
	print("WATER_STATE_STALL_RESULT false_transitions=", false_transitions)
	scene.queue_free()
	await _frames(3)
	quit(0 if false_transitions == 0 else 1)
