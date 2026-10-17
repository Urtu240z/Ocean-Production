extends SceneTree
## End-to-end regression in the jet-ski scene. Runtime-only test settings:
## freeze wave time, place the camera across the surface, read the debug medium.
const SCENE = preload("res://gameplay/jet_ski_ocean.tscn")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _frames(count: int) -> void:
	for frame in count:
		await process_frame
	await RenderingServer.frame_post_draw


func _run() -> void:
	var scene = SCENE.instantiate()
	root.add_child(scene)
	for frame in 240:
		await process_frame
		if scene.get("ready_to_drive"):
			break
	_check(bool(scene.get("ready_to_drive")), "Jet ski scene initialized")
	scene.follow_camera = false
	scene.ski.freeze = true
	scene.label.visible = false
	var ocean := scene.get_node("Production/Ocean") as Ocean
	var fft := ocean.get_node("OpenOceanFFT")
	fft.set("_breaker_detector_capture_freeze_override", true)
	var camera: Camera3D = scene.camera
	camera.global_position = Vector3(40.0, 0.0, 0.0)
	camera.look_at(camera.global_position + Vector3(0.0, 0.02, -1.0))
	# Duplicate the profile; no edits to the saved resource or user's settings.
	ocean.underwater_medium_profile = ocean.underwater_medium_profile.duplicate()
	ocean.underwater_medium_profile.waterline_mask_debug = true
	await _frames(40)
	var medium := ocean.get_node("OceanUnderwaterMedium") as OceanUnderwaterMedium
	for profile in [Vector3(0, 0, 1), Vector3.ONE, Vector3(0.5, 0.3, 0.7)]:
		scene._set_visual_water_multipliers(profile)
		await _frames(20)
		var published: Vector3 = medium.get("_effect").get("_sources").get("visual_horizontal_displacement_scale")
		_check(published.is_equal_approx(profile), "Runtime profile change reaches waterline without replacing FFT textures")
		var state := medium.get_waterline_state()
		_check(bool(state.get("valid", false)), "Real FFT camera sensor is valid")
		var surface_y := float(state.get("water_surface_y", 0.0))
		for offset in [0.12, -0.12]:
			camera.global_position.y = surface_y + float(offset)
			await _frames(20)
			state = medium.get_waterline_state()
			var signed_distance := float(state.get("signed_distance_to_surface", NAN))
			_check(absf(signed_distance - float(offset)) < 0.015, "Camera crossing is measured in centimetres, not metres")
			var image := root.get_texture().get_image()
			var color := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
			# Production tone mapping turns debug-white into gray (~0.69); black stays 0.
			_check(color.r > 0.5 if offset > 0.0 else color.r < 0.05, "Rendered medium switches at the near waterline")
			print("UNDERWATER_CROSSING profile=", profile, " offset=", offset, " signed=", signed_distance, " pixel=", color.r)
	# Also cover runtime Ocean Space scale edits with the same texture RIDs.
	ocean.ocean_scale = 0.75
	ocean.clipmap_geometry_scale = 0.8
	await _frames(20)
	var published_sources: Dictionary = medium.get("_effect").get("_sources")
	_check(is_equal_approx(published_sources.get("ocean_scale"), 0.75)
		and is_equal_approx(published_sources.get("clipmap_geometry_scale"), 0.8), "Live height/geometry edits update underwater sampling")
	print("OCEAN_UNDERWATER_VISUAL_PROFILE_RUNTIME: ", "PASS" if failures.is_empty() else "FAIL", " ", failures)
	scene.queue_free()
	await _frames(3)
	quit(0 if failures.is_empty() else 1)
