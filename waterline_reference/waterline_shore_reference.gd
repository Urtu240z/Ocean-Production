extends Node3D

# Isolated Waterline reference. It does not use any production ocean module.
# Unreal units are centimeters; Godot values below are explicitly meters.

const WAVE_REFERENCE_EXR := "C:/Users/DEV/Desktop/WaterlinePRO6_AUDIT/Audit/reference_textures/T_PL_Wave_1_Disp.exr"
const BREAKUP_REFERENCE_TGA := "C:/Users/DEV/Desktop/WaterlinePRO6_AUDIT/Audit/reference_textures/Displacement_Contrast.tga"
const SHADER := preload("res://waterline_reference/waterline_shore_reference.gdshader")

enum ComparisonMode {
	BASE_SHORE,
	SHORE_PLUS_BREAKUP,
	SHORE_PLUS_BREAKUP_4_WAY,
}

@export_category("Waterline preset — original units")
@export var shore_wave_displacement_cm := Vector3(500.0, 1.0, 800.0)
@export var shore_shallows_range := -0.256
@export var shore_normal_shift := 3.0

@export_category("MF_Ocean_Displacement_Gen4 — source values")
# Water_Parameters.DefaultValue[Water Height] = 15 Unreal cm (a traced source fallback).
@export var breakup_wave_height_cm := 15.0
# Traced scalar defaults: Wave Speed = 0.09; Wave Tile = 2000 cm.
@export var displacement_wave_speed := 0.09
@export var water_tile_cm := 2000.0

@export_category("Reference presentation")
@export var comparison_mode: ComparisonMode = ComparisonMode.BASE_SHORE
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
	_set_comparison_mode(comparison_mode)
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
	_material.set_shader_parameter("shore_wave_displacement_m", shore_wave_displacement_cm * 0.01)
	_material.set_shader_parameter("shore_shallows_range", shore_shallows_range)
	_material.set_shader_parameter("shore_normal_shift", shore_normal_shift)
	_material.set_shader_parameter("wave_speed", wave_speed)
	_material.set_shader_parameter("audit_multiplier", audit_multiplier if audit_exaggerated else 1.0)
	_material.set_shader_parameter("breakup_wave_height_m", breakup_wave_height_cm * 0.01)
	_material.set_shader_parameter("displacement_wave_speed", displacement_wave_speed)
	_material.set_shader_parameter("water_tile_m", water_tile_cm * 0.01)
	_material.set_shader_parameter("waterline_disp_texture", _load_reference_texture(WAVE_REFERENCE_EXR, "T_PL_Wave_1_Disp"))
	_material.set_shader_parameter("breakup_texture", _load_reference_texture(BREAKUP_REFERENCE_TGA, "Displacement_Contrast"))
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
	_status.text += "1 BASE SHORE · 2 SHORE + BREAKUP · 3 SHORE + BREAKUP + 4 WAY"
	layer.add_child(_status)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_set_comparison_mode(ComparisonMode.BASE_SHORE)
			KEY_2:
				_set_comparison_mode(ComparisonMode.SHORE_PLUS_BREAKUP)
			KEY_3:
				_set_comparison_mode(ComparisonMode.SHORE_PLUS_BREAKUP_4_WAY)


func _set_comparison_mode(mode: ComparisonMode) -> void:
	comparison_mode = mode
	if _material != null:
		_material.set_shader_parameter("comparison_mode", int(mode))
	if _status != null:
		_status.text = "WATERLINE → GODOT REFERENCE\nDense continuous mesh: 0.0625 m spacing\n"
		_status.text += "1 BASE SHORE · 2 SHORE + BREAKUP · 3 SHORE + BREAKUP + 4 WAY\n"
		_status.text += "MODE: " + _mode_name(mode)


func _mode_name(mode: ComparisonMode) -> String:
	match mode:
		ComparisonMode.BASE_SHORE:
			return "BASE SHORE"
		ComparisonMode.SHORE_PLUS_BREAKUP:
			return "SHORE + BREAKUP"
		_:
			return "SHORE + BREAKUP + 4 WAY"


func _load_reference_texture(path: String, label: String) -> Texture2D:
	var image := Image.load_from_file(path)
	if image != null and not image.is_empty():
		_status_text_later("Reference texture loaded locally (not in Git): " + label)
		return ImageTexture.create_from_image(image)
	if label == "Displacement_Contrast" and _material != null:
		_material.set_shader_parameter("breakup_reference_available", 0.0)
	_status_text_later("Reference texture missing; " + label + " branch disabled.")
	return _make_zero_texture()


func _status_text_later(text: String) -> void:
	call_deferred("_append_status", text)


func _append_status(text: String) -> void:
	if _status != null:
		_status.text += "\n" + text


func _make_zero_texture() -> Texture2D:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBAF)
	image.set_pixel(0, 0, Color(0.0, 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(image)


func _save_preview() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var preview_path := OS.get_user_data_dir().path_join("waterline_shore_reference_preview.png")
	var error := get_viewport().get_texture().get_image().save_png(preview_path)
	print("WATERLINE_REFERENCE_PREVIEW=", preview_path, " error=", error)
