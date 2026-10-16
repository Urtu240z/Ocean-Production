@tool
extends EditorPlugin
var failures: Array[String] = []
var report := {}
var result_dir := "user://ocean_editor_preview_validation/"

func _enter_tree() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--result-dir="):
			result_dir = arg.trim_prefix("--result-dir=").trim_suffix("/") + "/"
	DirAccess.make_dir_recursive_absolute(result_dir)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok and not failures.has(label):
		failures.append(label)
		push_error("EDITOR_PREVIEW_TEST: " + label)

func wait_frames(count: int) -> void:
	for frame in count:
		await get_tree().process_frame

func run() -> void:
	for frame in 900:
		await get_tree().process_frame
		if not EditorInterface.get_resource_filesystem().is_scanning():
			break
	await wait_frames(60)
	EditorInterface.open_scene_from_path("res://preview_probe.tscn")
	EditorInterface.set_main_screen_editor("3D")
	await wait_frames(90)
	var scene := EditorInterface.get_edited_scene_root()
	print("EDITOR_PROBE_SCENE=" + str(scene.scene_file_path if scene != null else "null"))
	check(scene != null and scene.scene_file_path == "res://preview_probe.tscn", "correct editor fixture scene")
	if scene == null or not scene.has_node("Ocean"):
		check(false, "edited scene opened")
		finish()
		return
	var ocean := scene.get_node("Ocean")
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	var camera := viewport.get_camera_3d()
	camera.global_position = Vector3(0, 8, 12)
	camera.look_at(Vector3(0, 0, -10))
	var preview: Node = ocean.get("_editor_preview_node")
	check(is_instance_valid(preview), "editor preview exists")
	for frame in 600:
		await get_tree().process_frame
		if is_instance_valid(preview) and preview.get("_surface") != null:
			break
	if not is_instance_valid(preview) or preview.get("_surface") == null:
		check(false, "frozen production surface ready")
		finish()
		return
	await wait_frames(60)
	viewport.get_texture().get_image().save_png(result_dir + "editor_preview.png")
	var builds: int = preview.get("build_count")
	var dispatches: int = preview.get("snapshot_dispatch_count")
	var first_surface: Node = preview.get("_surface")
	var first_material: ShaderMaterial = first_surface.get("_material")
	var time_before: float = first_material.get_shader_parameter("ocean_time_s")
	var image_before := viewport.get_texture().get_image()
	await wait_frames(60)
	check(first_material.get_shader_parameter("ocean_time_s") == time_before, "frozen material time unchanged")
	check(preview.get("build_count") == builds and preview.get("snapshot_dispatch_count") == dispatches, "no continuous FFT rebuild or dispatch")
	check(ocean.get("_cpu_water_provider") == null and ocean.get("_open_ocean") == null, "no runtime Ocean or CPU field in editor")
	check(is_instance_valid(preview.get("_camera")), "editor viewport camera resolved")
	var sspr: Node = preview.get("_sspr")
	check(is_instance_valid(sspr), "reflection compositor exists")
	if is_instance_valid(sspr):
		var state: Dictionary = sspr.call("get_compositor_attachment_state")
		report["reflections"] = state
		check(bool(state.get("attached", false)) and bool(state.get("effect_callback_seen", false)), "SSPR dispatches on editor camera")
	check(scene.get_node("WorldEnvironment").compositor == null, "scene environment compositor not modified")
	var packed := PackedScene.new()
	check(packed.pack(scene) == OK, "scene can be packed")
	var node_names: Array[String] = []
	for index in packed.get_state().get_node_count():
		node_names.append(str(packed.get_state().get_node_name(index)))
	check(not node_names.has("OceanEditorPreview") and not node_names.has("FrozenSurface"), "generated preview excluded from scene serialization")
	ocean.set("preview_time", 3.0)
	await wait_frames(90)
	var changed_surface: Node = preview.get("_surface")
	var changed_material: ShaderMaterial = changed_surface.get("_material")
	check(changed_material.get_shader_parameter("ocean_time_s") == 3.0, "preview time reaches production material")
	check(hash(viewport.get_texture().get_image().get_data()) != hash(image_before.get_data()), "preview time changes rendered image")
	var profile := OceanReflectionProfile.new()
	ocean.set("reflection_profile", profile)
	await wait_frames(60)
	var previous_builds: int = preview.get("build_count")
	profile.base_roughness = 0.35
	await wait_frames(90)
	check(int(preview.get("build_count")) == previous_builds, "material changes do not rebuild FFT")
	var surface: Node = preview.get("_surface")
	check(surface.get("_reflection_profile") == profile, "edited reflection profile reaches production material")
	var material: ShaderMaterial = surface.get("_material")
	check(material.get_shader_parameter("reflection_base_roughness") == 0.35, "edited roughness reaches shader uniform")
	report["edited_roughness"] = material.get_shader_parameter("reflection_base_roughness")
	viewport.get_texture().get_image().save_png(result_dir + "editor_preview_roughness.png")
	var optics := OceanOpticsProfile.new()
	ocean.set("optics_profile", optics)
	await wait_frames(60)
	var optics_builds: int = preview.get("build_count")
	optics.wave_body_opacity = 0.37
	optics.wave_body_thickness_m = 2.25
	optics.wave_body_softness_m = 0.6
	await wait_frames(90)
	var optics_material: ShaderMaterial = preview.get("_surface").get("_material")
	check(is_equal_approx(optics_material.get_shader_parameter("wave_body_opacity"), 0.37)
		and optics_material.get_shader_parameter("wave_body_thickness_m") == 2.25
		and is_equal_approx(optics_material.get_shader_parameter("wave_body_softness_m"), 0.6), "wave body controls reach editor shader")
	check(int(preview.get("build_count")) == optics_builds, "wave body controls do not rebuild FFT")
	report["wave_body_controls_live"] = true
	ocean.set("editor_preview", false)
	await wait_frames(15)
	check(ocean.get("_editor_preview_node") == null, "preview OFF releases editor surface")
	check(camera.compositor == null or camera.compositor.compositor_effects.is_empty(), "preview OFF detaches compositor effect")
	check(scene.get_node("WorldEnvironment").compositor == null, "environment still unchanged after teardown")
	ocean.set("editor_preview", true)
	await wait_frames(90)
	check(ocean.get("_editor_preview_node") != null, "preview ON recreates snapshot")
	report.merge({"initial_builds": builds, "initial_dispatches": dispatches, "packed_scene_nodes": node_names})
	finish()

func finish() -> void:
	report["passed"] = failures.is_empty()
	report["failures"] = failures
	var file := FileAccess.open(result_dir + "editor_preview.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("EDITOR_PREVIEW_RESULT=" + str(report.passed))
	get_tree().quit(0 if failures.is_empty() else 1)
