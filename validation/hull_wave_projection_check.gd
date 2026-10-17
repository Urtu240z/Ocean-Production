extends SceneTree
const Emitter := preload("res://addons/ocean/surface/foam2d/hull_wave_emitter.gd")
var field_stats := {}

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var output := "res://temp/foam2d/ocean_controls/wave_contract"
	DirAccess.make_dir_recursive_absolute(output)
	var scene: Node = load("res://validation/foam2d_playground.tscn").instantiate()
	var fixture_ocean: Ocean = scene.get_node("JetSkiOcean/Production/Ocean")
	# This test starts disabled even when the user has enabled the prototype in
	# their saved preset. Isolate the fixture; never reset their authoring values.
	fixture_ocean.hull_foam_settings = fixture_ocean.get_hull_foam_settings().duplicate(true)
	fixture_ocean.set("foam_deformation_enabled",false)
	root.add_child(scene)
	for frame in 900:
		await process_frame
		if scene.find_child("AjustesSalpicaduras",true,false) != null: break
	var world: Node = scene.get_node("JetSkiOcean")
	var ocean: Ocean = world.get_node("Production/Ocean")
	var director: Node = scene.get_foam_runtime()
	assert(director.get_parent() == ocean and not scene.has_node("Foam2D"))
	assert(director.wave_field == null,"Disabled prototype allocated a height atlas")
	var recorder: Node = world.water.get("_perf1_capture")
	if is_instance_valid(recorder): recorder.queue_free()
	await process_frame
	world.water.perf2_stage_measurements_enabled = false
	world.water.native.perf1_set_enabled(false)
	for frame in 240: await process_frame
	var ski: JetSkiController = director.vehicles[0]
	ski.freeze = true
	world.process_mode = Node.PROCESS_MODE_DISABLED
	for node in world.find_children("*","Node",true,false): node.process_mode = Node.PROCESS_MODE_DISABLED
	director.set_process(false)
	director.fft.set("_interaction_foam",null)
	for canvas in scene.find_children("*","CanvasLayer",true,false): canvas.hide()
	ski.get_node("BowSprayRoot").hide()
	var water: Node = ski.water_physics_system
	water._point_sample_valid.fill(true)
	water._point_depths.fill(0.15)
	water._point_relative_normal_speeds.fill(0.0)
	water.contact_is_airborne = false
	var style: Resource = director.style
	var idle := Emitter.new()
	ski.linear_velocity = Vector3.ZERO
	for i in 20: idle.update(0.1,float(i)*0.1,director.vehicles,style)
	assert(idle.packets.is_empty(),"Stationary hull generated a moving wake")
	var emitter := Emitter.new()
	var pose := ski.global_transform
	ski.linear_velocity = Vector3(0,0,-15)
	for i in 8:
		ski.global_position = pose.origin+Vector3(0,0,-float(i)*3.0)
		ski.reset_physics_interpolation()
		await process_frame
		ski.linear_velocity = Vector3(0,0,-15)
		emitter.update(0.2,float(i)*0.2,director.vehicles,style)
	assert(emitter.submitted_wakes >= 5,"Fixture movement did not advance: %s" % emitter.diagnostic_state())
	var first_position: Vector2 = emitter.packets[0].position
	water.contact_is_airborne = true
	ski.linear_velocity = Vector3(0,-5,0)
	emitter.update(0.1,1.7,director.vehicles,style)
	var wake_count: int = emitter.submitted_wakes
	emitter.update(0.1,1.8,director.vehicles,style)
	assert(emitter.submitted_wakes == wake_count)
	water.contact_is_airborne = false
	water._point_relative_normal_speeds.fill(-5.0)
	emitter.update(0.1,1.9,director.vehicles,style)
	assert(emitter.submitted_impacts == 1)
	emitter.update(0.1,2.0,director.vehicles,style)
	assert(emitter.submitted_impacts == 1,"A continuous wet hull retriggered landing waves")
	assert(emitter.packets[0].position == first_position,"Old wave packets followed the moving boat")
	var expiry_clock := 3.0+maxf(style.wake_wave_duration_s,style.impact_wave_duration_s)
	emitter.update(expiry_clock-2.0,expiry_clock,director.vehicles,style)
	assert(emitter.packets.is_empty(),"Wave packets did not expire")
	ski.global_transform = pose
	ski.reset_physics_interpolation()
	ski.linear_velocity = Vector3.ZERO
	water._point_relative_normal_speeds.fill(0.0)
	# The leading segment must follow every frame, even before a history commit.
	var saved_front := {"wake_wave_rise_s":style.wake_wave_rise_s,"wake_wave_duration_s":style.wake_wave_duration_s}
	style.wake_wave_rise_s = 0.1
	style.wake_wave_duration_s = 20.0
	var head_emitter := Emitter.new()
	var old_head: RefCounted
	if FileAccess.file_exists("res://temp/foam2d/live_front/before/hull_wave_emitter.gd"):
		old_head = load("res://temp/foam2d/live_front/before/hull_wave_emitter.gd").new()
	var head_lag := 0.0
	var previous_head_lag := 0.0
	for i in 60:
		ski.global_position = pose.origin+Vector3(0,0,-float(i)/6.0)
		ski.reset_physics_interpolation()
		await process_frame
		ski.linear_velocity = Vector3(0,0,-10)
		head_emitter.update(1.0/60.0,float(i)/60.0,director.vehicles,style)
		if old_head != null: old_head.update(1.0/60.0,float(i)/60.0,director.vehicles,style)
		if i == 0: continue
		assert(not head_emitter.packets.is_empty(),"Bow waited for an archive interval")
		var latest: Dictionary = head_emitter.packets.back()
		var local_points: PackedVector3Array = water.get_buoyancy_local_points()
		var bow: Vector3 = ski.get_global_transform_interpolated()*((local_points[0]+local_points[1])*0.5)
		var tip: Vector2 = latest.position+latest.forward*latest.half_length
		head_lag = maxf(head_lag,tip.distance_to(Vector2(bow.x,bow.z)))
		assert(head_emitter.diagnostic_state().live_heads <= 1)
		if old_head != null and not old_head.packets.is_empty():
			var old_latest: Dictionary = old_head.packets.back()
			var old_tip: Vector2 = old_latest.position+old_latest.forward*old_latest.half_length
			previous_head_lag = maxf(previous_head_lag,old_tip.distance_to(Vector2(bow.x,bow.z)))
	assert(head_lag < 0.001,"Leading segment fell behind the bow")
	if old_head != null: assert(previous_head_lag > 0.5,"Fixture did not expose the previous interval gap")
	for key in saved_front: style.set(key,saved_front[key])
	ski.global_transform = pose
	ski.reset_physics_interpolation()
	ski.linear_velocity = Vector3.ZERO
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.fov = 53.0
	camera.global_position = pose.origin+Vector3(4,6,7)
	camera.look_at(pose.origin)
	camera.make_current()
	for frame in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("off.png"))
	ocean.set("foam_deformation_enabled",true)
	director.clock = 30.0
	director._update_waves(0.05)
	for frame in 8: await process_frame
	assert(director.wave_field.ready,director.wave_field.last_error)
	var center := Vector2(pose.origin.x,pose.origin.z)
	var forward := Vector2(-pose.basis.z.x,-pose.basis.z.z).normalized()
	for i in 5:
		director.wave_emitter._add({"position":center-forward*float(i)*1.3,"forward":forward,"born":30.0-float(i)*0.4-0.2,"life":4.0,
			"amplitude":style.wake_wave_height_m,"speed":1.4,"width":style.wake_wave_width_m,"wavelength":style.wake_wave_wavelength_m,"half_length":1.6,"impact":false})
	director.wave_emitter._add({"position":center,"forward":forward,"born":29.3,"life":3.0,
		"amplitude":style.impact_wave_height_m,"speed":2.5,"width":style.impact_wave_width_m,"wavelength":style.impact_wave_wavelength_m,"half_length":1.0,"impact":true})
	director._update_waves(0.05)
	for frame in 8: await process_frame
	director._update_waves(0.049)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("on.png"))
	RenderingServer.call_on_render_thread(read_field.bind(director.wave_field))
	for frame in 8: await process_frame
	assert(field_stats.minimum < -0.005 and field_stats.maximum > 0.005,"No signed height in GPU atlas")
	assert(field_stats.max_gradient > 0.01,"Missing slope correction")
	var live_stats := field_stats.duplicate()
	assert(is_equal_approx(director.surface.get_clipmap_culling_bounds_state().interaction_vertical_bound_world_m,style.deformation_max_height_m))
	# Isolate a broad 2 m packet: verify a gradual GPU birth and previous-field
	# preservation instead of trusting slider metadata or a CPU approximation.
	var test_packet := {"position":center,"forward":forward,"born":0.0,"life":6.0,
		"amplitude":2.0,"speed":0.0,"width":3.0,"wavelength":10.0,"half_length":1.0,"impact":true,"rise":1.0,"fade":2.0}
	var envelope_samples: Array[Dictionary] = []
	var test_packets: Array[Dictionary] = [test_packet]
	for age in [0.0,0.1,0.25,0.5,1.0]:
		RenderingServer.call_on_render_thread(director.wave_field.draw.bind(test_packets,director._wave_origin,age))
		for frame in 3: await process_frame
		RenderingServer.call_on_render_thread(read_field.bind(director.wave_field))
		for frame in 3: await process_frame
		envelope_samples.append(field_stats.duplicate())
	assert(is_zero_approx(envelope_samples[0].maximum))
	for i in range(1,envelope_samples.size()): assert(envelope_samples[i].maximum > envelope_samples[i-1].maximum,"GPU rise was not progressive")
	assert(envelope_samples[1].maximum < 0.1 and envelope_samples[4].maximum > 1.5,"Large waves were clipped or born at full size")
	RenderingServer.call_on_render_thread(read_field.bind(director.wave_field,true))
	for frame in 3: await process_frame
	assert(is_equal_approx(field_stats.maximum,envelope_samples[3].maximum),"Previous atlas was not retained for interpolation")
	assert(director.wave_field.diagnostic_state().texture_bytes == 7340032)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("large_2m.png"))
	style.deformation_debug_view = 1
	for frame in 8: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output.path_join("height.png"))
	style.deformation_debug_view = 0
	director.clock = 50.0
	director._update_waves(0.05)
	for frame in 8: await process_frame
	RenderingServer.call_on_render_thread(read_field.bind(director.wave_field))
	for frame in 8: await process_frame
	assert(is_zero_approx(field_stats.maximum) and is_zero_approx(field_stats.minimum),"Expired packets left displaced geometry")
	var retired: RefCounted = director.wave_field
	ocean.set("foam_deformation_enabled",false)
	for frame in 8: await process_frame
	assert(director.wave_field == null and not retired.ready and not retired.texture_rid.is_valid() and not retired.previous_texture_rid.is_valid())
	assert(not retired.get("_wake_accumulation").is_valid() and not retired.get("_wake_weight_gradient").is_valid())
	assert(is_zero_approx(director.surface.get_clipmap_culling_bounds_state().interaction_vertical_bound_world_m))
	for material: ShaderMaterial in director.surface.get("_variant_materials").values():
		assert(not material.get_shader_parameter("hull_waves_enabled"))
	FileAccess.open(output.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify({"passed":true,
		"ocean_owned":true,"idle_air_quiet":true,"landing_once":true,"world_fixed_history":true,"expires":true,"off_releases_gpu":true,
		"live_field":live_stats,"rise_samples_2m":envelope_samples,"head_lag_m":head_lag,"previous_head_lag_m":previous_head_lag,"cpu_emitter":emitter.diagnostic_state(),"extra_water_queries":0,"extra_meshes":0},"\t"))
	print("HULL_WAVE_PROJECTION_PASS ",JSON.stringify(live_stats))
	await world._close_gracefully()

func read_field(field: RefCounted, previous := false) -> void:
	var bytes: PackedByteArray = field.get("_rd").texture_get_data(field.previous_texture_rid if previous else field.texture_rid,0)
	var image := Image.create_from_data(512,512,false,Image.FORMAT_RGBAH,bytes)
	image.convert(Image.FORMAT_RGBAF)
	var values := image.get_data().to_float32_array()
	var minimum := 0.0
	var maximum := 0.0
	var max_gradient := 0.0
	for i in range(0,values.size(),4):
		minimum = minf(minimum,values[i])
		maximum = maxf(maximum,values[i])
		max_gradient = maxf(max_gradient,Vector2(values[i+1],values[i+2]).length())
	field_stats = {"minimum":minimum,"maximum":maximum,"max_gradient":max_gradient}
