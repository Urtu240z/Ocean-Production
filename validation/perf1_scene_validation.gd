extends SceneTree
## Loads the actual jet ski scene unchanged and validates the capture hook.
var scene: Node
var frames := 0

func _initialize() -> void:
	scene = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene

func _process(_delta: float) -> bool:
	frames += 1
	if frames < 240: return false
	var providers := root.find_children("*", "WaterSurfaceProvider3D", true, false)
	var capture_count := 0
	for provider in providers:
		var capture := provider.get_node_or_null("Perf1Capture")
		if capture != null: capture_count += 1
	var result := {"scene_loaded": scene.scene_file_path, "frames": frames, "capture_nodes": capture_count,
		"physics_frames": Engine.get_physics_frames(), "user_data_dir": OS.get_user_data_dir()}
	var file := FileAccess.open("res://temp/perf1_scene_validation.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t")); file.close()
	print("PERF1_SCENE_VALIDATION ", result)
	quit(0 if capture_count > 0 else 1)
	return false
