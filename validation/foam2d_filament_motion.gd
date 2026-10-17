extends SceneTree
var scene: Node
var world: Node
var director: Node
var material: ShaderMaterial
var history_updates := 0
var history_hash := 0
var result := {}

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	seed(24017)
	scene = load("res://validation/foam2d_playground.tscn").instantiate()
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.get_foam_runtime() != null and scene.get_foam_runtime().history != null: break
	director = scene.get_foam_runtime()
	world = scene.get_child(0)
	var ocean: Node = world.get_node("Production/Ocean")
	ocean.wave_height_scale = 0.0
	ocean.wind_speed_mps = 0.0
	var camera := Camera3D.new()
	camera.fov = 53.0
	world.add_child(camera)
	camera.make_current()
	for frame in 300:
		var ski: Node3D = director.vehicles[0]
		camera.global_position = ski.global_position + Vector3(0,4.5,0.5)
		camera.look_at(ski.global_position)
		await process_frame
	# All three possible explanations of apparent movement are frozen:
	# geometry/camera, body motion, and the underlying history texture.
	world.ski.freeze = true
	world.process_mode = Node.PROCESS_MODE_DISABLED
	for node in world.find_children("*","Node",true,false): node.process_mode = Node.PROCESS_MODE_DISABLED
	director.set_process(false)
	director.fft.set("_interaction_foam",null)
	for layer in scene.find_children("*","CanvasLayer",true,false): layer.hide()
	for frame in 8: await process_frame
	material = director.surface.get("_material")
	# Isolate local bending from the separate transport of the strands.
	material.set_shader_parameter("foam2d_transport_detail",false)
	await read_history()
	history_hash = director.field_readback.field_hash
	history_updates = director.history.completed_updates
	var transport_only := "--transport-only" in OS.get_cmdline_user_args()
	if transport_only:
		# Expose the transported strands beneath the hull as well as outside it.
		for mesh in world.ski.find_children("*","MeshInstance3D",true,false): mesh.hide()
	var output := "res://temp/foam2d/transport_motion" if transport_only else "res://temp/foam2d/filament_motion"
	DirAccess.make_dir_recursive_absolute(output)
	var configured: float = 0.0 if transport_only else director.style.filament_deformation
	var pose: Transform3D = camera.global_transform
	var hull_pose: Transform3D = world.ski.global_transform
	result.control = await sequence(output,"control",0.0,4)
	result.isolated = await sequence(output,"isolated",configured,4,transport_only)
	material.set_shader_parameter("foam2d_filament_deformation",0.0)
	material.set_shader_parameter("foam2d_transport_detail",false)
	material.set_shader_parameter("foam2d_debug",0)
	material.set_shader_parameter("foam2d_time",0.0)
	for frame in 8: await process_frame
	root.get_texture().get_image().save_png(output.path_join("static.png"))
	result.beauty = await sequence(output,"beauty",configured,0,transport_only)
	await read_history()
	result.history_fixed = director.field_readback.field_hash == history_hash and director.history.completed_updates == history_updates
	result.camera_fixed = camera.global_transform.is_equal_approx(pose)
	result.hull_fixed = world.ski.global_transform.is_equal_approx(hull_pose)
	result.parameters = {"transport_only":transport_only,"deformation":configured,"speed":director.style.filament_speed,"whole_field_drift":director.style.motion_strength}
	result.passed = result.history_fixed and result.camera_fixed and result.hull_fixed \
		and result.control.difference < 0.001 and result.isolated.difference > 0.001 \
		and result.isolated.changed_pixels > result.control.changed_pixels*3+100
	FileAccess.open(output.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print("FILAMENT_MOTION passed=",result.passed," history_fixed=",result.history_fixed,
		" control_diff=",result.control.difference," filament_diff=",result.isolated.difference)
	if not result.passed:
		quit(1)
		return
	await world._close_gracefully()

func sequence(output: String, prefix: String, amount: float, debug: int, transport := false) -> Dictionary:
	material.set_shader_parameter("foam2d_filament_deformation",amount)
	material.set_shader_parameter("foam2d_transport_detail",transport)
	material.set_shader_parameter("foam2d_debug",debug)
	material.set_shader_parameter("foam2d_time",0.0)
	for frame in 8: await process_frame
	var first := PackedByteArray()
	var last := PackedByteArray()
	for frame in 31:
		material.set_shader_parameter("foam2d_time",frame*0.1)
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.convert(Image.FORMAT_RGBA8)
		image.save_png(output.path_join("%s_%03d.png" % [prefix,frame]))
		if frame == 0: first = image.get_data()
		if frame == 30: last = image.get_data()
	var difference := 0.0
	var changed := 0
	for pixel in range(0,mini(first.size(),last.size()),4):
		var delta := absf(float(first[pixel])-float(last[pixel]))
		difference += delta/255.0
		if delta > 16: changed += 1
	return {"difference":difference/maxf(first.size()/4.0,1.0),"changed_pixels":changed,"frames":31}

func read_history() -> void:
	RenderingServer.call_on_render_thread(director.read_field)
	for frame in 4: await process_frame
