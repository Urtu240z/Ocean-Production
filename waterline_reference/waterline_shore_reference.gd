extends Node3D

# Isolated Waterline reference.  It does not use any production ocean module.
# Unreal units are centimeters; Godot values below are explicitly meters.

const WAVE_REFERENCE_EXR := "C:/Users/DEV/Desktop/WaterlinePRO6_AUDIT/Audit/reference_textures/T_PL_Wave_1_Disp.exr"
const SHADER := preload("res://waterline_reference/waterline_shore_reference.gdshader")

@export_category("Waterline preset — original units")
@export var shore_wave_displacement_cm := Vector3(500.0, 1.0, 800.0)
@export var shore_shallows_range := -0.256
@export var shore_normal_shift := 3.0

@export_category("Reference presentation")
@export var audit_exaggerated := false
@export_range(0.25, 3.0, 0.05) var audit_multiplier := 1.0
@export var wave_speed := 0.15
@export var save_preview_on_start := true

var _surface: MeshInstance3D
var _material: ShaderMaterial
var _status: Label

func _ready() -> void:
	_create_reference_world()
	_create_surface()
	_create_camera_and_light()
	_create_status()
	if save_preview_on_start:
		call_deferred("_save_preview")


func _create_reference_world() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("78a9cf")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("dcecff")
	environment.ambient_light_energy = 0.55
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)


func _create_surface() -> void:
	# 8 m × 6 m with 128 × 96 quads: exactly 0.0625 m spacing.
	var plane := PlaneMesh.new()
	plane.size = Vector2(8.0, 6.0)
	plane.subdivide_width = 127
	plane.subdivide_depth = 95

	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("shore_wave_displacement_m", Vector3(
		shore_wave_displacement_cm.x * 0.01,
		shore_wave_displacement_cm.y * 0.01,
		shore_wave_displacement_cm.z * 0.01
	))
	_material.set_shader_parameter("shore_shallows_range", shore_shallows_range)
	_material.set_shader_parameter("shore_normal_shift", shore_normal_shift)
	_material.set_shader_parameter("wave_speed", wave_speed)
	_material.set_shader_parameter("audit_multiplier", audit_multiplier if audit_exaggerated else 1.0)
	_material.set_shader_parameter("waterline_disp_texture", _load_reference_texture())
	plane.material = _material

	_surface = MeshInstance3D.new()
	_surface.name = "DenseContinuousShoreSurface"
	_surface.mesh = plane
	add_child(_surface)


func _create_camera_and_light() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -28.0, 0.0)
	sun.light_energy = 2.1
	sun.shadow_enabled = true
	add_child(sun)

	var camera := Camera3D.new()
	camera.name = "FixedShoreReferenceCamera"
	camera.position = Vector3(3.9, 2.25, 4.4)
	camera.fov = 48.0
	add_child(camera)
	camera.look_at(Vector3(0.0, 0.25, -0.45), Vector3.UP)


func _create_status() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_status = Label.new()
	_status.position = Vector2(22.0, 18.0)
	_status.add_theme_font_size_override("font_size", 17)
	_status.add_theme_color_override("font_color", Color.WHITE)
	_status.text = "WATERLINE → GODOT REFERENCE\nDense continuous mesh: 0.0625 m spacing\n"
	_status.text += "X=horizontal amplitude, Y=unused by MF_Shore_Gen3 displacement, Z=vertical amplitude"
	layer.add_child(_status)


func _load_reference_texture() -> Texture2D:
	var image := Image.load_from_file(WAVE_REFERENCE_EXR)
	if image != null and not image.is_empty():
		_status_text_later("Reference texture: AUDIT EXR loaded (not in Git).")
		return ImageTexture.create_from_image(image)

	_status_text_later("Reference texture missing: procedural diagnostic fallback is active.")
	return _make_diagnostic_texture()


func _status_text_later(text: String) -> void:
	call_deferred("_append_status", text)


func _append_status(text: String) -> void:
	if _status != null:
		_status.text += "\n" + text


func _make_diagnostic_texture() -> Texture2D:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBAF)
	for y in range(32):
		for x in range(32):
			var u := float(x) / 31.0
			var v := float(y) / 31.0
			var profile := 0.5 + 0.5 * sin((u * 2.0 + v) * TAU)
			image.set_pixel(x, y, Color(profile, 0.0, 0.5 + 0.5 * cos(v * TAU), 1.0))
	return ImageTexture.create_from_image(image)


func _save_preview() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var preview_path := OS.get_user_data_dir().path_join("waterline_shore_reference_preview.png")
	var error := get_viewport().get_texture().get_image().save_png(preview_path)
	print("WATERLINE_REFERENCE_PREVIEW=", preview_path, " error=", error)
