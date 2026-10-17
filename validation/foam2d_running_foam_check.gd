extends SceneTree
## Disposable V1 fixture: hold waves/pose/history constant, vary only speed.
var rows: Array[Dictionary] = []

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	DirAccess.make_dir_recursive_absolute("res://temp/foam2d/running")
	var scene: Node = load("res://validation/foam2d_playground.tscn").instantiate()
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.find_child("AjustesSalpicaduras",true,false) != null: break
	# Let the hull settle; this is a rendering fixture, not a landing test.
	for frame in 300: await process_frame
	var director: Node = scene.get_foam_runtime()
	var world: Node = scene.get_child(0)
	var recorder: Node = world.water.get("_perf1_capture")
	if is_instance_valid(recorder): recorder.queue_free()
	await process_frame
	world.water.perf2_stage_measurements_enabled = false
	world.water.native.perf1_set_enabled(false)
	var ski: JetSkiController = director.vehicles[0]
	ski.freeze = true
	world.process_mode = Node.PROCESS_MODE_DISABLED
	for node in world.find_children("*","Node",true,false): node.process_mode = Node.PROCESS_MODE_DISABLED
	ski.get_node("BowSprayRoot").hide()
	director.fft.set("_interaction_foam",null)
	director.set_process(false)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.hide()
	var water: Node = ski.water_physics_system
	water._point_sample_valid.fill(true)
	water._point_depths.fill(0.15)
	water.contact_is_airborne = false
	var style: Resource = director.style
	var original: Resource = style.duplicate()
	style.running_enabled = true
	style.running_start_kmh = 0.5
	style.running_full_kmh = 50.0
	style.running_speed_curve = 0.65
	var camera := Camera3D.new()
	camera.fov = 53.0
	root.add_child(camera)
	camera.global_position = ski.global_position + Vector3(0,5.0,1.0)
	camera.look_at(ski.global_position)
	camera.make_current()
	var viewport := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport,true)
	var last_weight := -1.0
	for kmh in [0.0,2.0,20.0,30.0,50.0]:
		ski.linear_velocity = Vector3(-ski.global_basis.z.x,0,-ski.global_basis.z.z).normalized()*(kmh/3.6)
		for step in 80: director._update_running_foam(0.05)
		var weight: float = director._running_weights[0]
		assert(weight > last_weight and is_equal_approx(weight,style.running_speed_weight(kmh)),"Speed %s: weight %s expected %s" % [kmh,weight,style.running_speed_weight(kmh)])
		last_weight = weight
		assert(director.surface._material.get_shader_parameter("foam2d_running_count") == (0 if kmh == 0 else 1))
		# Isolate the added pigment, then capture its real material appearance.
		director.surface._set_surface_shader_parameter("foam2d_debug",5)
		for frame in 8: await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		image.save_png("res://temp/foam2d/running/mask_%02d.png" % int(kmh))
		director.surface._set_surface_shader_parameter("foam2d_debug",0)
		for frame in 8: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://temp/foam2d/running/beauty_%02d.png" % int(kmh))
		rows.append({"kmh":kmh,"weight":weight})
	# No water, invalid samples or disabled layer must never leave a ghost.
	water.contact_is_airborne = true
	director._update_running_foam(0.016)
	assert(director._running_weights[0] == 0.0)
	assert(director.surface._material.get_shader_parameter("foam2d_running_count") == 0)
	water.contact_is_airborne = false
	water._point_sample_valid.fill(false)
	director._update_running_foam(0.016)
	assert(director._running_weights[0] == 0.0)
	water._point_sample_valid.fill(true)
	director._update_running_foam(0.016)
	assert(director._running_weights[0] > 0.0 and director._running_weights[0] < 0.1,"Speed response snapped")
	for step in 80: director._update_running_foam(0.05)
	ski.linear_velocity = Vector3.ZERO
	director._update_running_foam(0.016)
	assert(director._running_weights[0] > 0.8,"Braking snapped")
	for step in 100: director._update_running_foam(0.05)
	assert(director.surface._material.get_shader_parameter("foam2d_running_count") == 0)
	ski.linear_velocity = -ski.global_basis.z*15.0
	style.running_enabled = false
	director._update_running_foam(0.016)
	assert(director.surface._material.get_shader_parameter("foam2d_running_count") == 0)
	assert(style.history_parameters() == original.history_parameters())
	FileAccess.open("res://temp/foam2d/running/contract.json",FileAccess.WRITE).store_string(JSON.stringify({"passed":true,"speeds":rows,"air_dry_disabled_hidden":true,"progressive_acceleration_braking":true,"extra_water_queries":0,"additional_meshes":0},"\t"))
	print("FOAM2D_RUNNING_PASS ",JSON.stringify(rows))
	await world._close_gracefully()
