extends SceneTree
## Real production scene, frozen after startup. Fixtures change rendering only.
class FixedBoundary extends Node3D:
	var snapshot = preload("res://addons/ocean/events/ocean_tsunami_state.gd").new()
	func advance(_tick: int, _delta: float) -> void: pass

var failures: Array[String] = []
var scene: Node
var ocean: Ocean
var surface: OceanClipmapSurface
var camera: Camera3D
var output := "res://temp/shadow_receiver/"
var metrics := {}

func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label); push_error("SHADOW_RECEIVER_FAIL " + label)
func frames(count: int) -> void:
	for i in count: await process_frame
	await RenderingServer.frame_post_draw
func capture(label: String) -> Image:
	await frames(20)
	var result := root.get_texture().get_image()
	result.save_png(output + label + ".png")
	return result
func darkened(a: Image, b: Image) -> int:
	var count := 0
	for y in a.get_height():
		for x in a.get_width():
			var p := a.get_pixel(x,y)
			var q := b.get_pixel(x,y)
			if (p.r+p.g+p.b-q.r-q.g-q.b)/3.0 > 0.01: count += 1
	return count
func aim(position: Vector3, target: Vector3) -> void:
	camera.position = position
	camera.look_at(target)
	camera.reset_physics_interpolation()
	surface.global_position = Vector3(position.x, ocean.sea_level, position.z)
	surface.reset_physics_interpolation()
	surface._set_surface_shader_parameter("camera_world_xz", Vector2(position.x,position.z))
func receiver() -> ShaderMaterial:
	return (surface.get("_material") as ShaderMaterial).next_pass as ShaderMaterial
func gpu_window(strength: float) -> Dictionary:
	ocean.shadow_strength = strength
	await frames(30)
	var gpu: Array[float] = []
	var draws: Array[float] = []
	for i in 90:
		await process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid()))
		draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	gpu.sort(); draws.sort()
	return {"gpu_p50_ms":gpu[45],"gpu_p95_ms":gpu[85],"total_draw_calls_p50":draws[45]}
func run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(960,540)
	scene = load("res://validation/hull_wave_physics_playground.tscn").instantiate()
	root.add_child(scene)
	ocean = scene.get_node("JetSkiOcean/Production/Ocean")
	for i in 1200:
		await process_frame
		if ocean.get_physics_source_state().get("status","") == "OK": break
	await frames(40)
	surface = ocean.get_node("OpenOceanFFT/OceanClipmapSurface")
	for node in scene.find_children("*","",true,false):
		node.process_mode = Node.PROCESS_MODE_DISABLED
		if node is RigidBody3D: node.freeze = true
		if node is OceanBoundaryTsunami: ocean.unregister_boundary_tsunami(node)
	scene.process_mode = Node.PROCESS_MODE_DISABLED
	camera = Camera3D.new()
	root.add_child(camera)
	camera.far = 5000
	camera.current = true
	var sun: DirectionalLight3D = scene.get_node("JetSkiOcean/Production/Sun")
	var original_light := sun.transform
	var original_bias := Vector2(sun.shadow_bias, sun.shadow_normal_bias)
	var sunward := Vector2(sun.global_basis.z.x,sun.global_basis.z.z).normalized()
	var boundary := FixedBoundary.new()
	root.add_child(boundary)
	ocean.register_boundary_tsunami(boundary)
	boundary.snapshot.center_radius = Vector4(-sunward.x*1000,-sunward.y*1000,1220,60)
	boundary.snapshot.shape = Vector4(30,90,35,65)
	boundary.snapshot.motion = Vector4(0,0,0.25,sunward.angle())
	boundary.snapshot.cast_shadows = true
	ocean.cast_shadows = true
	surface.set_wave_area_state(ocean.get_wave_area_runtime())
	aim(Vector3(-sunward.x*70,100,-sunward.y*70),Vector3(sunward.x*200,15,sunward.y*200))
	ocean.shadow_strength = 0.0
	check(receiver() == null,"zero strength detaches extra pass")
	var physical_buffer: PackedFloat32Array = boundary.snapshot.packed()
	var physical_samples := []
	for d in [200.0,220.0,240.0]: physical_samples.append(boundary.snapshot.sample(sunward*d))
	var tsunami_before := await capture("tsunami_before")
	ocean.shadow_strength = 0.45
	check(receiver() != null,"live strength attaches receiver")
	check(receiver().shader.code.contains("if (hull_waves_enabled)"),"same projected hull wave vertices")
	var tsunami_after := await capture("tsunami_after")
	check(boundary.snapshot.packed() == physical_buffer,"physical tsunami buffer bit exact")
	for i in physical_samples.size():
		check(physical_samples[i] == boundary.snapshot.sample(sunward*[200.0,220.0,240.0][i]),"physical tsunami sample bit exact")
	metrics.tsunami_dark_pixels = darkened(tsunami_before,tsunami_after)
	check(metrics.tsunami_dark_pixels > 1000,"tsunami shadow visibly darkens actual water")
	# With shadows disabled the extra pass must have zero visual contribution.
	sun.shadow_enabled = false
	ocean.shadow_strength = 0.0
	var no_shadow_before := await capture("no_shadow_before")
	ocean.shadow_strength = 0.45
	var no_shadow_after := await capture("no_shadow_after")
	metrics.no_shadow_dark_pixels = darkened(no_shadow_before,no_shadow_after)
	metrics.no_shadow_exact_image_match = no_shadow_before.get_data() == no_shadow_after.get_data()
	check(metrics.no_shadow_exact_image_match,"shadow-free rendered image bit exact")
	check(metrics.no_shadow_dark_pixels == 0,"no artificial shadow when Godot shadow is absent")
	sun.shadow_enabled = true
	# Isolate only the boat's water shadow, excluding its own shaded pixels.
	boundary.snapshot.center_radius.w = 0.0
	boundary.snapshot.cast_shadows = false
	ocean.cast_shadows = false
	surface.set_wave_area_state(ocean.get_wave_area_runtime())
	var ski: Node3D = scene.get_node("JetSki")
	ski.position = Vector3(0,2,0) # Deliberately lifted visual fixture; no simulated forces.
	ski.reset_physics_interpolation()
	var meshes: Array[MeshInstance3D] = []
	for node in ski.find_children("*","MeshInstance3D",true,false):
		meshes.append(node)
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	aim(Vector3(5,9,10),Vector3.ZERO)
	ocean.shadow_strength = 0.0
	var boat_before := await capture("boat_before")
	ocean.shadow_strength = 0.45
	var boat_after := await capture("boat_after")
	metrics.boat_dark_pixels = darkened(boat_before,boat_after)
	check(metrics.boat_dark_pixels > 20,"boat shadow darkens water without self-shading pixels")
	for mesh in meshes: mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var boat_absent := await capture("boat_absent")
	metrics.boat_cast_pixels = darkened(boat_absent,boat_after)
	check(metrics.boat_cast_pixels > 20,"boat cast setting controls native shadow mask")
	for enabled in [false,true]:
		ocean.optics = enabled
		ocean.reflections = enabled
		await frames(8)
		check(receiver() != null,"receiver survives Optics/reflection variants")
		check(receiver().get_shader_parameter("ocean_shadow_strength") == 0.45,"strength survives variant")
	for mode in [OceanReflectionProfile.ReflectionMode.PLANAR,OceanReflectionProfile.ReflectionMode.SCREEN_SPACE]:
		ocean.reflection_profile.reflection_mode = mode
		await frames(8)
		check(receiver() != null,"receiver survives Planar/SSPR switch")
	surface.set_camera_surface_signed_distance(-1.0)
	check(receiver().get_shader_parameter("surface_air_blend") == 0.0,"underwater presentation disables overlay")
	surface.set_camera_surface_signed_distance(1.0)
	check(receiver().get_shader_parameter("surface_air_blend") == 1.0,"air presentation re-enables overlay")
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	metrics.gpu_off = await gpu_window(0.0)
	metrics.gpu_on = await gpu_window(0.45)
	metrics.gpu_off_repeat = await gpu_window(0.0)
	ocean.shadow_strength = 0.0
	check(receiver() == null,"live disable removes next pass")
	check(sun.transform == original_light and Vector2(sun.shadow_bias,sun.shadow_normal_bias) == original_bias,"authored light unchanged")
	metrics.failures = failures
	var file := FileAccess.open(output+"results.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics,"\t")); file.close()
	print("SHADOW_RECEIVER_RESULT ",JSON.stringify(metrics))
	quit(0 if failures.is_empty() else 1)
