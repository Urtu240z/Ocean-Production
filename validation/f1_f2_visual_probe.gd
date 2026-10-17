extends SceneTree
## Reproducible visual review only. No production physics or camera settings saved.
var args := {}
var world: Node3D
var ocean: Ocean
var fft: Node
var vehicles: Array[JetSkiController] = []
var rows: Array[Dictionary] = []
var shots: Array[Dictionary] = []
var output := ""
var test_camera: Camera3D
var max_builds := 0
var max_batch_points := 0
var max_speed := 0.0
var airborne_frames := 0
var landings := 0
var previous_serial := 0
var last_build_count := 0
var last_tick := -1
var duplicate_build_ticks := 0
var frozen_wake_target := Vector3.ZERO
var wall_previous_usec := 0
var field_summary := {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			args[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	run.call_deferred()

func run() -> void:
	output = str(args.get("out", "res://temp/f1_f2/baseline"))
	DirAccess.make_dir_recursive_absolute(output)
	seed(24017)
	world = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
	world.development_window_size = Vector2i(1280, 720)
	world.validation_sea_state = int(args.get("sea", "0"))
	if world.validation_sea_state == 0:
		# Mild sea, confined to the review instance and identical in A/B.
		world._apply_validation_sea_state(world.get_node("Production/Ocean"), 0.65, 5.0, 35.0, 1.0, 1.0)
	root.add_child(world)
	for i in 600:
		await process_frame
		if world.ready_to_drive: break
	if not world.ready_to_drive:
		push_error("F1F2: production not ready")
		quit(1)
		return
	ocean = world.get_node("Production/Ocean")
	fft = ocean.get_node("OpenOceanFFT")
	vehicles.append(world.ski)
	world.ski.collision_layer = 0
	world.ski.collision_mask = 0
	for i in range(1, int(args.get("vehicles", "1"))):
		var ski := load("res://addons/jet_ski/jet_ski_01/jet_ski_01.tscn").instantiate() as JetSkiController
		ski.name = "ReviewSki%d" % i
		ski.position = Vector3((i % 4) * float(args.get("spacing", "7")), 1, (i / 4) * 7.0)
		ski.configure_ocean(ocean)
		ski.collision_layer = 0
		ski.collision_mask = 0
		world.add_child(ski)
		ski.get_node("CameraRig").process_mode = Node.PROCESS_MODE_DISABLED
		vehicles.append(ski)
	world.camera.make_current()
	for canvas in world.find_children("*", "CanvasLayer", true, false): canvas.hide()
	var viewport_rid := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if str(args.get("view", "game")) == "side":
		test_camera = Camera3D.new()
		test_camera.fov = 55.0
		world.add_child(test_camera)
		test_camera.make_current()
	var captures := {210: "rest", 345: "slow", 490: "turn", 550: "jump", 655: "landing", 875: "aged_wake"}
	var frame_count := int(args.get("frames", "900"))
	wall_previous_usec = Time.get_ticks_usec()
	for frame in frame_count:
		Input.action_press("throttle", 0.20 if frame < 360 else 1.0) if frame >= 240 and frame < 660 else Input.action_release("throttle")
		Input.action_press("steer_left", 0.55) if frame >= 410 and frame < 510 else Input.action_release("steer_left")
		if frame == 530:
			# Controlled jump stimulus in this test only; production forces untouched.
			for ski in vehicles: ski.apply_central_impulse(Vector3.UP * ski.mass * 4.5)
		if frame == 660:
			frozen_wake_target = vehicles[0].global_position
		if test_camera != null:
			var target := vehicles[0].global_position
			if frame >= 660: target = frozen_wake_target
			test_camera.global_position = target + Vector3(4.8, 0.55, 2.6)
			test_camera.look_at(target + Vector3(0, 0.03, 0))
		await process_frame
		var wall_now := Time.get_ticks_usec()
		var wall_ms := float(wall_now - wall_previous_usec) / 1000.0
		wall_previous_usec = wall_now
		var water: Node = world.water
		var tick := Engine.get_physics_frames()
		var builds: int = water.get("field_update_count")
		if tick == last_tick and builds > last_build_count: duplicate_build_ticks += 1
		last_tick = tick
		last_build_count = builds
		max_builds = maxi(max_builds, int(water.get("field_builds_this_physics_tick")))
		max_batch_points = maxi(max_batch_points, int(water.get("native_query_positions_this_physics_tick")))
		var ski := vehicles[0]
		max_speed = maxf(max_speed, ski.linear_velocity.length())
		if ski.water_physics_system.contact_is_airborne: airborne_frames += 1
		var serial := ski.water_physics_system.contact_landing_event_serial
		if serial != previous_serial:
			landings += 1
			previous_serial = serial
		if frame >= 120:
			rows.append({"frame": frame, "wall_frame_ms": wall_ms, "process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
				"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				"viewport_cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid),
				"viewport_gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid),
				"static_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
				"video_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
				"speed": ski.linear_velocity.length()})
		if captures.has(frame) and str(args.get("shots", "yes")) == "yes":
			await RenderingServer.frame_post_draw
			var name: String = captures[frame]
			root.get_texture().get_image().save_png(output.path_join(name + ".png"))
			shots.append({"name": name, "frame": frame, "wave_time": ocean.get_wave_time(),
				"position": ski.global_position, "basis": ski.global_basis,
				"wet": ski.water_physics_system.wet_contact_count, "airborne": ski.water_physics_system.contact_is_airborne,
				"camera": root.get_camera_3d().global_transform,
				"speed": ski.linear_velocity.length()})
	var surface: Node = fft.get("_surface")
	var variants := []
	var shader_map: Dictionary = surface.get("_variant_shaders")
	for key in shader_map:
		var shader: Shader = shader_map[key]
		var uniforms := []
		for u in shader.get_shader_uniform_list():
			if str(u.name).begins_with("interaction_foam"): uniforms.append(str(u.name))
		variants.append({"key": key, "uniforms": uniforms, "reads_R": shader.code.contains("texture(interaction_foam_texture, interaction_uv).r")})
	var wake: RefCounted = fft.get("_interaction_foam")
	var contact_lines := []
	var provider_ids := {}
	var native_ids := {}
	var context_ids := {}
	for ski in vehicles:
		var line := ski.get_node("WaterContactFx/HullContactFoam")
		contact_lines.append({"segments": line.get("visible_segments"), "extra_queries": 0})
		var provider := ski.get_water_provider()
		provider_ids[provider.get_instance_id()] = true
		var native: RefCounted = provider.get("native")
		native_ids[native.get_instance_id()] = true
		var context: RefCounted = ski.get("_water_consumer_context")
		context_ids[context.get_instance_id()] = true
	if str(args.get("diagnostics", "no")) == "yes":
		# A single overhead diagnostic camera exposes the wake behind the chase
		# camera. This is review capture only, never an effect/depth camera.
		var diagnostic_camera := Camera3D.new()
		world.add_child(diagnostic_camera)
		var back := -vehicles[0].linear_velocity
		back.y = 0.0
		back = back.normalized()
		var target := vehicles[0].global_position + back * 10.0
		diagnostic_camera.global_position = target + Vector3.UP * 18.0 + back * 6.0
		diagnostic_camera.look_at(target)
		diagnostic_camera.make_current()
		world.process_mode = Node.PROCESS_MODE_DISABLED
		for node in world.find_children("*", "Node", true, false):
			node.process_mode = Node.PROCESS_MODE_DISABLED
		for ski in vehicles: ski.freeze = true
		for i in 3: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output.path_join("wake_overview.png"))
		for mode in [1, 2, 3]:
			fft.interaction_foam_debug_view = mode
			surface._set_surface_shader_parameter("interaction_foam_debug_view", mode)
			var material: ShaderMaterial = surface.get("_material")
			print("F1F2_DIAG ", mode, " enabled=", material.get_shader_parameter("interaction_foam_enabled"), " mode=", material.get_shader_parameter("interaction_foam_debug_view"), " path=", material.shader.resource_path)
			for i in 3: await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(output.path_join("diagnostic_%d.png" % mode))
		surface._set_surface_shader_parameter("interaction_foam_debug_view", 0)
		RenderingServer.call_on_render_thread(_read_wake_fields.bind(wake))
		for i in 8: await process_frame
	var report := {"args": args, "frames": frame_count, "fixed_fps": 60, "rows": rows, "shots": shots,
		"max_builds_per_tick": max_builds, "duplicate_build_ticks_observed": duplicate_build_ticks,
		"max_batch_points": max_batch_points, "field_updates": last_build_count,
		"shared_provider": provider_ids.size() == 1, "native_objects": native_ids.size(), "consumer_contexts": context_ids.size(),
		"max_speed": max_speed, "airborne_frames": airborne_frames, "landings": landings,
		"wake": wake.diagnostic_state(), "field_summary": field_summary, "variants": variants, "contact_lines": contact_lines,
		"gpu_scope": "Viewport GPU timestamps measure raster work, exclude global Ocean compute; submit_ms is CPU only.",
		"device": RenderingServer.get_video_adapter_name()}
	FileAccess.open(output.path_join("report.json"), FileAccess.WRITE).store_string(JSON.stringify(report, "\t"))
	for action in ["throttle", "steer_left"]: Input.action_release(action)
	print("F1F2_COMPLETE " + output)
	await world._close_gracefully()

func _read_wake_fields(wake: RefCounted) -> void:
	# Validation-only readback, after timing collection and while the scene is frozen.
	var rd := RenderingServer.get_rendering_device()
	var source := RDShaderSource.new()
	source.source_compute = """#version 450
layout(local_size_x=8, local_size_y=8) in;
layout(rg32f,set=0,binding=0) readonly uniform image2D fields;
layout(std430,set=0,binding=1) writeonly buffer Result { vec2 values[]; } result;
void main() { ivec2 p=ivec2(gl_GlobalInvocationID.xy); result.values[p.y*512+p.x]=imageLoad(fields,p).rg; }
"""
	var shader := rd.shader_create_from_spirv(rd.shader_compile_spirv_from_source(source))
	var pipeline := rd.compute_pipeline_create(shader)
	var buffer := rd.storage_buffer_create(512 * 512 * 8)
	var input := RDUniform.new()
	input.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	input.binding = 0
	input.add_id(wake.texture_rid)
	var destination := RDUniform.new()
	destination.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	destination.binding = 1
	destination.add_id(buffer)
	var uniforms := rd.uniform_set_create([input, destination], shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniforms, 0)
	rd.compute_list_dispatch(list, 64, 64, 1)
	rd.compute_list_end()
	var bytes := rd.buffer_get_data(buffer)
	FileAccess.open(output.path_join("fields_rg32.bin"), FileAccess.WRITE).store_buffer(bytes)
	var values := bytes.to_float32_array()
	var max_r := 0.0
	var max_g := 0.0
	var visible_cells := 0
	for i in range(0, values.size(), 2):
		max_r = maxf(max_r, values[i])
		max_g = maxf(max_g, values[i + 1])
		if values[i + 1] > 0.04: visible_cells += 1
	field_summary = {"max_r": max_r, "max_g": max_g, "cells_above_004": visible_cells}
	for rid in [uniforms, buffer, pipeline, shader]: rd.free_rid(rid)
