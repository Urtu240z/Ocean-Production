extends SceneTree

const SCENE_PATH := "res://validation/p0_open_ocean.tscn"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var scene: Node = load(SCENE_PATH).instantiate()
	root.add_child(scene)
	await process_frame
	var ocean := scene.get_node("Ocean")
	ocean.set("wave_speed_multiplier", 0.0)
	for _frame in 18:
		await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var path := OS.get_environment("PHYS33_CAPTURE_PATH")
	if path.is_empty() or image.save_png(path) != OK:
		printerr("PHYS33_VISUAL_CAPTURE_FAIL")
		quit(1)
		return
	print("PHYS33_VISUAL_CAPTURE path=%s size=%s wave_time=%s" % [
		path, image.get_size(), ocean.call("get_wave_time")])
	quit(0)
