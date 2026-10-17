extends SceneTree
const Director := preload("res://addons/ocean/surface/foam2d/foam2d_review_director.gd")
const Previous := preload("res://validation/foam2d_previous_factory.gd")
var args := {}
var world: Node3D
var vehicles: Array[JetSkiController] = []
var director: Node
var rows: Array[Dictionary] = []
var shots: Array[Dictionary] = []
var checksums: Array[Dictionary] = []
var max_builds := 0
var max_queries := 0
var camera: Camera3D
var frozen_target := Vector3.ZERO
var style_test := {}
var contact_events: Array[Dictionary] = []
var spray_motion: Array[Dictionary] = []

func _initialize() -> void:
	# The follow rig stays unchanged. Ignore wheel/key camera adjustments only
	# in this measuring process so desktop input cannot alter the comparison.
	node_added.connect(func(node: Node):
		var attached: Script=node.get_script() as Script
		if attached!=null and attached.resource_path.ends_with("jet_ski_camera_controls.gd"):
			node.set("controls_enabled",false))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=")+1)
	var requested: String = args.get("mode", "combined")
	var spray_mode: String=args.get("spray","off")
	ProjectSettings.set_setting("jet_ski/hull_spray_enabled",spray_mode!="off")
	ProjectSettings.set_setting("jet_ski/hull_spray_mode",spray_mode)
	ProjectSettings.set_setting("foam2d/review_mode", "combined" if requested in ["previous_revision","revision3","before_motion","before_filaments","before_edges","before_center_out"] else requested)
	# Keep previous visual references equivalent; current modes omit the retired
	# ring and placeholder contact/wake/splash particles.
	ProjectSettings.set_setting("foam2d/reference_contact_visuals", requested in ["original","f1f2","previous2d","previous_revision","revision3"])
	run.call_deferred()

func run() -> void:
	var output: String = args.get("out", "res://temp/foam2d/smoke")
	DirAccess.make_dir_recursive_absolute(output)
	seed(24017)
	world = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	world.development_window_size = Vector2i(1280,720)
	world.validation_sea_state = int(args.get("sea", "1"))
	if world.validation_sea_state == 0:
		world._apply_validation_sea_state(world.get_node("Production/Ocean"),0.65,5.0,35.0,1.0,1.0)
	if args.get("flat","no") == "yes":
		world.validation_sea_state = 0
		world.get_node("Production/Ocean").wave_height_scale = 0.0
		world.get_node("Production/Ocean").wind_speed_mps = 0.0
	if args.has("wind-speed"):
		world.validation_sea_state = 0
		world.get_node("Production/Ocean").wind_speed_mps = float(args["wind-speed"])
	root.add_child(world)
	if args.get("hide-course","no") == "yes":
		var obstacle: Node3D = world.get_node_or_null("MeshInstance3D")
		if obstacle != null: obstacle.hide()
	for i in 600:
		await process_frame
		if world.ready_to_drive: break
	assert(world.ready_to_drive)
	var ocean: Ocean = world.get_node("Production/Ocean")
	var fft: Node = ocean.get_node("OpenOceanFFT")
	vehicles.append(world.ski)
	world.ski.collision_layer = 0
	world.ski.collision_mask = 0
	for i in range(1,int(args.get("vehicles","1"))):
		var ski := load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate() as JetSkiController
		ski.position = Vector3((i % 4) * 7.0,1.0,(i / 4) * 7.0)
		ski.configure_ocean(ocean)
		ski.collision_layer = 0
		ski.collision_mask = 0
		world.add_child(ski)
		ski.get_node("CameraRig").process_mode = Node.PROCESS_MODE_DISABLED
		vehicles.append(ski)
	world.camera.make_current()
	# Diagnostic isolation only: never changes water/vehicle algorithms.
	var diagnostics: String=args.get("diagnostics","on")
	if diagnostics!="on":
		var recorder: Node=world.water.get("_perf1_capture")
		if is_instance_valid(recorder):
			recorder.queue_free()
			await process_frame
		if diagnostics=="off":
			world.water.set("perf2_stage_measurements_enabled",false)
			world.water.get("native").call("perf1_set_enabled",false)
	if args.get("spray-events","no")=="yes":
		for ski in vehicles:
			var spray: Node=ski.get_node("BowSprayRoot/HullSprays")
			spray.gate.capture_events=true
	for canvas in world.find_children("*","CanvasLayer",true,false): canvas.hide()
	var view: String = args.get("view","game")
	if view != "game":
		camera = Camera3D.new()
		camera.fov = 53.0
		world.add_child(camera)
		camera.make_current()
	var requested_mode: String = args.get("mode", "combined")
	director = Previous.create("pre_center_out") if requested_mode == "before_center_out" else (Previous.create("pre_edges") if requested_mode == "before_edges" else (Previous.create("pre_filaments") if requested_mode == "before_filaments" else (Previous.create("pre_motion") if requested_mode == "before_motion" else (Previous.create("revision3_sources") if requested_mode == "revision3" else (Previous.create("saved_revision2") if requested_mode == "previous_revision" else (Previous.create() if requested_mode == "previous2d" else Director.new()))))))
	if args.get("wave-source","") == "before_live_front":
		director.free()
		director = load("res://temp/foam2d/live_front/before/foam2d_review_director.gd").new()
	world.add_child(director)
	director.configure(fft,vehicles,"combined" if requested_mode in ["previous2d","previous_revision","revision3","before_motion","before_filaments","before_edges","before_center_out"] else requested_mode)
	if args.has("running-foam"): director.style.running_enabled = args["running-foam"] == "on"
	if args.has("hull-waves"): director.style.deformation_enabled = args["hull-waves"] == "on"
	if args.has("foam-hz"): director.style.wake_update_hz = int(args["foam-hz"])
	if args.has("foam-forward"): director.style.wake_emission_forward_m = float(args["foam-forward"])
	# Isolated visual fixtures; never save these overrides to the user's preset.
	var wave_options := {"wave-speed":"wake_wave_speed_mps","wave-duration":"wake_wave_duration_s","wave-height":"wake_wave_height_m","wave-rise":"wake_wave_rise_s","wave-birth-distance":"wake_wave_birth_distance_m"}
	for option in wave_options:
		if args.has(option):
			var property: String = wave_options[option]
			director.style.set(property,float(args[option]))
	if args.has("wake-spread"): director.style.wake_spread = float(args["wake-spread"])
	if args.has("motion-strength"): director.style.motion_strength = float(args["motion-strength"])
	if str(args.get("style-test","no")) == "yes":
		_test_style()
		if not style_test.get("passed",false):
			quit(1)
			return
	if args.has("debug"):
		director.surface._set_surface_shader_parameter("foam2d_debug",int(args.debug))
	var viewport := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport,true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var frame_count := int(args.get("frames","600"))
	var warmup := int(args.get("warmup","180"))
	var previous := Time.get_ticks_usec()
	var previous_physics_frame := Engine.get_physics_frames()
	var captures := {210:"rest_a",230:"rest_b",320:"slow",470:"fast",580:"wake",840:"aged_wake"}
	var clip_start := int(args.get("clip-start","180"))
	var clip_end := int(args.get("clip-end","360"))
	var spray_landing := str(args.get("scenario","forward")) == "spray_landing"
	var landing_test := str(args.get("scenario","forward")) in ["landing","spray_landing"]
	var previously_airborne := false
	var landed_frame := -1
	var left_water_frame := -1
	if args.get("hide-hull","no") == "yes":
		for ski in vehicles:
			for mesh in ski.find_children("*","MeshInstance3D",true,false): mesh.hide()
	var reverse_test := str(args.get("scenario", "forward")) == "reverse"
	if reverse_test: captures.merge({241:"reverse_start",245:"reverse_first",270:"reverse_early"})
	for frame in frame_count:
		if landing_test and frame==240:
			vehicles[0].global_position += Vector3.UP*6.0
			vehicles[0].linear_velocity = Vector3(0,-8,0)
		Input.action_press("throttle",0.20 if frame<340 else 1.0) if args.get("still","no") != "yes" and not reverse_test and not landing_test and frame>=240 and frame<500 else Input.action_release("throttle")
		if spray_landing and frame>=180 and frame<620: Input.action_press("throttle",1.0)
		Input.action_press("brake",1.0) if reverse_test and frame>=240 and frame<500 else Input.action_release("brake")
		Input.action_press("steer_left",0.35) if not reverse_test and frame>=390 and frame<450 else Input.action_release("steer_left")
		if frame==500: frozen_target=vehicles[0].global_position
		if camera != null:
			var target := vehicles[0].global_position
			if view == "trail":
				var direction := vehicles[0].linear_velocity
				direction.y = 0.0
				if direction.length_squared() < 1.0: direction = -vehicles[0].global_basis.z
				direction.y = 0.0
				direction = direction.normalized()
				target -= direction * 5.0
				camera.global_position = target - direction * 6.0 + Vector3.UP * 13.0
				camera.look_at(target)
			elif view == "near_top":
				camera.global_position=target+Vector3(0,4.5,0.5)
				camera.look_at(target)
			elif view == "spray_close":
				var back := vehicles[0].global_basis.z
				back.y=0.0
				back=back.normalized()
				camera.global_position=target+Vector3.UP.cross(back)*2.2+back*3.4+Vector3.UP*6.0
				camera.look_at(target+back*0.9)
			elif view == "spray_side":
				var back := vehicles[0].global_basis.z
				back.y=0.0
				back=back.normalized()
				camera.global_position=target+Vector3.UP.cross(back)*3.8+back*2.8+Vector3.UP*1.5
				camera.look_at(target+back*0.7)
			elif view == "top":
				var back := -vehicles[0].linear_velocity
				back.y=0.0
				back=back.normalized()
				target += back*12.0
				if frame>500: target=frozen_target
				camera.global_position=target+Vector3.UP*22.0+back*3.0
				camera.look_at(target)
			else:
				camera.global_position=target+Vector3(3.4,-1.70 if view=="underside" else 0.46,1.9)
				camera.look_at(target+Vector3(0,-0.10,0))
		await process_frame
		var now := Time.get_ticks_usec()
		var elapsed := float(now-previous)/1000.0
		previous=now
		var water: Node = world.water
		var physics_steps := Engine.get_physics_frames()-previous_physics_frame
		previous_physics_frame=Engine.get_physics_frames()
		if diagnostics=="stages":
			water.get("native").call("perf2_frame_boundary",Engine.get_process_frames(),Engine.get_frames_drawn(),1000000)
		if spray_landing:
			var hull_water: Node=vehicles[0].water_physics_system
			var in_air: bool=hull_water.contact_is_airborne
			var bow: Node=vehicles[0].get_node("BowSprayRoot")
			var spray: Node=bow.get_node("HullSprays")
			if in_air and not previously_airborne and frame>=240 and left_water_frame<0:
				left_water_frame=frame
				captures[frame+4]="air_residual"
				captures[frame+45]="air_empty"
			if previously_airborne and not in_air and hull_water.contact_is_wet and frame>240 and landed_frame<0:
				landed_frame=frame
				captures[frame]="landing_first"
				captures[frame+12]="landing_growth"
				captures[frame+45]="landing_recovered"
			previously_airborne=in_air
			spray_motion.append({"frame":frame,"airborne":in_air,"wet":hull_water.contact_is_wet,
				"bow_visible":bow._sheets[0].visible,"bow_growth":bow._contact_growth,
				"tail_visible":spray._tail.visible,"residual":spray._tail_material.get_shader_parameter("tail_residual"),
				"tail_intensity":spray._tail_intensity})
		if landing_test:
			contact_events.append({"frame":frame,"airborne":vehicles[0].water_physics_system.contact_is_airborne,
				"submitted_stamps":director.history.submitted_stamps,"hull_y":vehicles[0].global_position.y})
		max_builds=maxi(max_builds,int(water.get("field_builds_this_physics_tick")))
		max_queries=maxi(max_queries,int(water.get("native_query_positions_this_physics_tick")))
		if frame==warmup:
			director.metrics_active=true
			FileAccess.open(output.path_join("measure_started.json"),FileAccess.WRITE).store_string(JSON.stringify({"pid":OS.get_process_id(),"frames":frame_count-warmup}))
		if frame>=warmup:
			rows.append({"frame":frame,"wall_ms":elapsed,
				"process_frame":Engine.get_process_frames(),"physics_steps":physics_steps,
				"engine_physics_time_ms":Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0,
				"engine_process_time_ms":Performance.get_monitor(Performance.TIME_PROCESS)*1000.0,
				"object_count":Performance.get_monitor(Performance.OBJECT_COUNT),
				"render_cpu_ms":RenderingServer.viewport_get_measured_render_time_cpu(viewport),
				"render_gpu_ms":RenderingServer.viewport_get_measured_render_time_gpu(viewport),
				"static_bytes":Performance.get_monitor(Performance.MEMORY_STATIC),
				"video_bytes":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
				"contact_cpu_us":director.contact_update_us,"wet":str(director.wet[0]),"birth":str(director.birth[0])})
		if frame % 60 == 0:
			checksums.append({"frame":frame,"position":vehicles[0].global_position,"basis":vehicles[0].global_basis,
				"velocity":vehicles[0].linear_velocity,"wave_time":ocean.get_wave_time(),"camera":root.get_camera_3d().global_transform})
		var take_shot := captures.has(frame) and str(args.get("shots","no"))=="yes"
		var take_clip := str(args.get("clip","no"))=="yes" and frame>=clip_start and frame<=clip_end and (frame-clip_start)%6==0
		if take_shot or take_clip:
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			if take_shot:
				var shot: String = captures[frame]
				image.save_png(output.path_join(shot+".png"))
				shots.append({"name":shot,"frame":frame,"position":vehicles[0].global_position,"camera":root.get_camera_3d().global_transform,
					"wave_time":ocean.get_wave_time(),"contact":director.diagnostic_state()})
			if take_clip: image.save_png(output.path_join("motion_%03d.png"%((frame-clip_start)/6)))
	director.metrics_active=false
	FileAccess.open(output.path_join("measure_ended.json"),FileAccess.WRITE).store_string("{}")
	if str(args.get("readback","no"))=="yes":
		for node in world.find_children("*","Node",true,false): node.process_mode=Node.PROCESS_MODE_DISABLED
		for ski in vehicles: ski.freeze=true
		RenderingServer.call_on_render_thread(director.read_field)
		for i in 8: await process_frame
		var material: ShaderMaterial=director.surface.get("_material")
		var bound: Texture2DRD=material.get_shader_parameter("interaction_foam_texture")
		print("FOAM2D_READBACK ",director.field_readback," bound=",bound," history_rid=",director.history.texture_rid," bound_rid=",bound.texture_rd_rid if bound!=null else RID())
		print("FOAM2D_PARAMS origin=",material.get_shader_parameter("interaction_foam_origin_xz")," domain=",material.get_shader_parameter("interaction_foam_domain_m")," debug=",material.get_shader_parameter("foam2d_debug")," count=",material.get_shader_parameter("foam2d_vehicle_count"))
	FileAccess.open(output.path_join("contact_events.json"),FileAccess.WRITE).store_string(JSON.stringify(contact_events))
	var providers := {}
	var natives := {}
	var contexts := {}
	var mesh_counts := {"ArrayMesh":0,"TorusMesh":0}
	for ski in vehicles:
		providers[ski.get_water_provider().get_instance_id()]=true
		var native: RefCounted=ski.get_water_provider().get("native")
		natives[native.get_instance_id()]=true
		var context: RefCounted=ski.get("_water_consumer_context")
		contexts[context.get_instance_id()]=true
		var contact := ski.get_node_or_null("WaterContactFx/HullContactFoam") as MeshInstance3D
		if contact != null:
			if contact.mesh is ArrayMesh: mesh_counts.ArrayMesh+=1
			if contact.mesh is TorusMesh: mesh_counts.TorusMesh+=1
	var shader_variants := []
	var surface: Node=fft.get("_surface")
	for key in surface.get("_variant_shaders"):
		var shader: Shader=surface.get("_variant_shaders")[key]
		shader_variants.append({"key":key,"projected":shader.code.contains("foam2d_contact(vec3"),"front_gate":shader.code.contains("projected_upper_face && surface_air_blend")})
	var history: RefCounted=fft.get("_interaction_foam")
	var spray_reports := []
	for ski in vehicles:
		var spray: Node=ski.get_node_or_null("BowSprayRoot/HullSprays")
		if spray!=null:
			spray_reports.append({"state":spray.diagnostic_state(),"events":spray.gate.events})
	var report := {"args":args,"rows":rows,"shots":shots,"checksums":checksums,"warmup":warmup,"frames":frame_count,"style_test":style_test,
		"spray":spray_reports,
		"spray_motion":spray_motion,
		"diagnostics_mode":diagnostics,"native_stages":world.water.get("native").call("get_perf2_capture") if diagnostics=="stages" else {},
		"providers":providers.size(),"native_objects":natives.size(),"contexts":contexts.size(),"max_builds":max_builds,"max_queries":max_queries,
		"field_updates":world.water.get("field_update_count"),"contact_meshes":mesh_counts,"variants":shader_variants,
		"effect_gpu_ms":director.effect_gpu_ms.duplicate(),"wave_gpu_ms":director.wave_gpu_ms.duplicate(),"timestamp_names":director.timestamp_names,
		"wave_settings":{"speed_mps":director.style.wake_wave_speed_mps,"duration_s":director.style.wake_wave_duration_s,"height_m":director.style.wake_wave_height_m,"rise_s":director.style.wake_wave_rise_s,"birth_distance_m":director.style.wake_wave_birth_distance_m},
		"foam_settings":{"update_hz":director.style.wake_update_hz,"forward_m":director.style.wake_emission_forward_m},
		"history":history.diagnostic_state() if history!=null else {},"contact":director.diagnostic_state(),"readback":director.field_readback,
		"device":RenderingServer.get_video_adapter_name(),"gpu_scope":"Viewport raster plus separately timestamped history; not assumed full-frame GPU"}
	FileAccess.open(output.path_join("report.json"),FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	for action in ["throttle","steer_left","brake"]: Input.action_release(action)
	if str(args.get("monitor","no"))=="yes":
		for node in world.find_children("*","Node",true,false): node.process_mode=Node.PROCESS_MODE_DISABLED
		for ski in vehicles: ski.freeze=true
		for i in 180:
			if FileAccess.file_exists(output.path_join("cpu_collected.marker")): break
			await process_frame
	print("FOAM2D_COMPLETE ",output)
	await world._close_gracefully()

func _test_style() -> void:
	var style: Resource=director.style
	var before: Dictionary=style.shader_parameters()
	style.roughness=0.82
	style.specular=0.66
	style.opacity=0.4
	style.calm_foam_strength=1.35
	style.whitening_threshold=0.72
	style.water_tint=Color(0.03,0.4,0.58,1.0)
	style.white_color=Color(0.95,0.85,0.70,1.0)
	style.patch_size=2.35
	style.agitation_decay=0.61
	var expected: Dictionary=style.shader_parameters()
	var checks := 0
	for material: ShaderMaterial in director.surface.get("_variant_materials").values():
		for parameter in expected:
			var actual = material.get_shader_parameter(parameter)
			var target = expected[parameter]
			assert(actual != null, "Missing style uniform: "+parameter)
			if target is Color:
				var actual_color: Color = actual if actual is Color else Color(actual.x,actual.y,actual.z,actual.w)
				assert(actual_color.is_equal_approx(target), "Style color failed: "+parameter)
			elif target is Vector3:
				assert((actual as Vector3).is_equal_approx(target), "Style vector failed: "+parameter)
			else:
				assert(is_equal_approx(float(actual),float(target)), "Style uniform failed: "+parameter)
			checks+=1
	assert(director.history.get("_appearance").is_equal_approx(style.history_parameters()))
	style_test={"passed":true,"uniform_checks":checks,"history_parameters":str(style.history_parameters())}
	# Restore the defaults before rendering this validation run.
	style.roughness=before.foam2d_roughness
	style.specular=before.foam2d_specular
	style.opacity=before.foam2d_opacity
	style.calm_foam_strength=before.foam2d_calm_strength
	style.whitening_threshold=before.foam2d_white_threshold
	style.water_tint=before.foam2d_water_tint
	style.white_color=before.foam2d_white_color
	style.patch_size=before.foam2d_patch_size
	style.agitation_decay=0.28
