extends SceneTree
## GPU integration: off-screen geometry, material swaps, method changes,
## disable/resume, resize, underwater fallback and layer restoration.
const PLANAR := preload("res://addons/ocean/reflections/ocean_planar_reflection.gd")
var _scene: Node3D
var _ocean: Ocean
var _camera: Camera3D
var _profile: OceanReflectionProfile
var _surface: OceanClipmapSurface

func _initialize() -> void:
	call_deferred(&"_run")

func _wait_frames(count: int) -> void:
	for frame in count:
		await process_frame
	await RenderingServer.frame_post_draw

func _require(value: bool, message: String) -> void:
	if not value:
		push_error("PLANAR_FAIL: " + message)
		quit(1)
		assert(value, message)

func _run() -> void:
	_scene = load("res://validation/p5_reflections.tscn").instantiate()
	_ocean = _scene.get_node(^"P0/Ocean")
	_ocean.wave_height_scale = 0.0
	_ocean.crest_foam = false
	_ocean.surface_foam = false
	_ocean.surface_detail = false
	_ocean.optics = false
	_ocean.breakers = false
	_ocean.enable_spindrift = false
	_scene.get_node(^"ReflectionObjects").visible = false
	_profile = OceanReflectionProfile.new()
	_profile.reflection_mode = OceanReflectionProfile.ReflectionMode.PLANAR
	_profile.distortion_strength = 0.0
	_profile.edge_fade = 0.0
	_profile.radiance_exposure_ev = 0.0
	_profile.radiance_saturation = 1.0
	_profile.screen_space_weight = 1.0
	_ocean.reflection_profile = _profile
	root.add_child(_scene)
	_camera = Camera3D.new()
	_scene.add_child(_camera)
	_camera.position = Vector3(0, 10, 30)
	_camera.rotation_degrees.x = -60
	_camera.current = true
	_camera.attributes = CameraAttributesPractical.new()
	_camera.environment = _camera.get_world_3d().environment.duplicate()
	_camera.environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	_camera.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_camera.environment.tonemap_exposure = 1.0
	_camera.environment.adjustment_enabled = false
	_camera.environment.ssao_enabled = false
	_camera.environment.ssil_enabled = false
	_camera.environment.fog_enabled = false
	_camera.environment.glow_enabled = false
	var marker := MeshInstance3D.new()
	marker.mesh = BoxMesh.new()
	marker.mesh.size = Vector3(6, 6, 6)
	marker.position = Vector3(0, 15, 0)
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.albedo_color = Color(1, 0, 0)
	material.emission_enabled = true
	material.emission = Color(1, 0, 0)
	material.emission_energy_multiplier = 16.0
	marker.material_override = material
	_scene.add_child(marker)
	await _wait_frames(40)
	_surface = _ocean.get_node(^"OpenOceanFFT/OceanClipmapSurface")
	var owner := _ocean.get_node(^"OpenOceanFFT/OceanSSPR")
	var planar: Node = owner.get("_planar")
	var capture: Camera3D = planar.get("_camera")
	var viewport: SubViewport = planar.get("_viewport")
	_require(not _camera.is_position_in_frustum(marker.global_position), "marker must be off-screen in main camera")
	_require(capture.is_position_in_frustum(marker.global_position), "mirrored view must retain off-screen marker")
	_require(is_equal_approx(capture.global_position.y, -10.0), "camera mirrored about sea level")
	_require(_surface.get("_reflection_texture_available"), "planar texture published")
	_require(_surface.get("_material").get_shader_parameter(&"reflection_planar_enabled"), "planar projection bound")
	_require(capture.compositor.compositor_effects.is_empty(), "capture must not inherit underwater postprocessing")
	var image := viewport.get_texture().get_image()
	_require(image != null and not image.is_empty(), "rendered capture exists")
	var red_pixels := 0
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			if pixel.r > 0.5 and pixel.g < 0.1 and pixel.b < 0.1:
				red_pixels += 1
	_require(red_pixels > 20, "off-screen red marker actually rendered into reflection")
	DirAccess.make_dir_recursive_absolute("res://temp/planar_validation")
	image.convert(Image.FORMAT_RGBA8)
	image.save_png("res://temp/planar_validation/capture.png")
	var ocean_image := root.get_texture().get_image()
	ocean_image.save_png("res://temp/planar_validation/ocean.png")
	var reflected_marker := marker.global_position
	reflected_marker.y = -reflected_marker.y
	var screen_point := _camera.unproject_position(reflected_marker) * Vector2(ocean_image.get_size()) / root.get_visible_rect().size
	var reflected_red := 0
	for y in range(maxi(0, int(screen_point.y) - 25), mini(ocean_image.get_height(), int(screen_point.y) + 25)):
		for x in range(maxi(0, int(screen_point.x) - 25), mini(ocean_image.get_width(), int(screen_point.x) + 25)):
			var pixel := ocean_image.get_pixel(x, y)
			if pixel.r > 0.003 and pixel.g < pixel.r * 0.6 and pixel.b < pixel.r * 0.6:
				reflected_red += 1
	_require(reflected_red > 20, "off-screen object appears at its reflected position on ocean")
	print("PLANAR_SURFACE_PASS reflected_pixels=", reflected_red, " expected_position=", screen_point)
	print("PLANAR_OFFSCREEN_PASS red_pixels=", red_pixels, " size=", viewport.size)
	var original_size := viewport.size
	_profile.planar_resolution_scale = 0.75
	await _wait_frames(5)
	_require(viewport.size.x > original_size.x, "resolution change reallocates capture")
	_ocean.optics = not _ocean.optics
	await _wait_frames(5)
	_require(_surface.get("_material").get_shader_parameter(&"reflection_planar_enabled"), "material variant retains projection")
	_profile.reflection_mode = OceanReflectionProfile.ReflectionMode.SCREEN_SPACE
	await _wait_frames(10)
	_require(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "SSR disables capture")
	_require(not _surface.get("_planar_reflection_enabled"), "SSR clears planar projection")
	_require(_surface.get("_reflection_texture_available"), "SSR republishes texture")
	_profile.reflection_mode = OceanReflectionProfile.ReflectionMode.PLANAR
	await _wait_frames(5)
	_ocean.reflections = false
	await _wait_frames(3)
	_require(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "off disables capture")
	for instance in _surface.find_children("*", "VisualInstance3D", true, false):
		_require(instance.layers != PLANAR.WATER_LAYER, "off restores original ocean layers")
	_ocean.reflections = true
	await _wait_frames(5)
	_require(_surface.get("_reflection_texture_available"), "resume republishes planar")
	_camera.position.y = -2
	await _wait_frames(5)
	_require(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "underwater capture disabled")
	_require(not _surface.get("_reflection_texture_available"), "underwater uses environment fallback")
	_camera.position.y = 10
	await _wait_frames(5)
	_require(_surface.get("_reflection_texture_available"), "above water resumes")
	var mirrored := PLANAR.mirror_transform(Transform3D(Basis.from_euler(Vector3(-0.6, 0.4, 0.2)), Vector3(2, 13, 8)), 3.0)
	_require(is_equal_approx(mirrored.origin.y, -7.0) and is_equal_approx(mirrored.basis.determinant(), 1.0), "nonzero sea level and rolled camera")
	_ocean.reflections = false
	await _wait_frames(2)
	print("PLANAR_LIFECYCLE_PASS")
	_scene.queue_free()
	await _wait_frames(3)
	quit(0)
