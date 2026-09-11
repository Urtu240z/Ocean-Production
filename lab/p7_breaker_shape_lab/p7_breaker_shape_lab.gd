extends Node3D
## Static world-space 2C2B Waterline VDM proof on the production clipmap.

const VDMGenerator := preload("res://lab/p7_breaker_shape_lab/breaker_shape_vdm_generator.gd")
const WATERLINE_VDM_PATH := "res://temp/waterline_source/T_PL_Wave_1_Disp.exr"
const EXTERNAL_VDM_PATH := "res://addons/ocean/breakers/assets/breaker_plunging_test_v01.exr"
const WAVEFRONT_WIDTH_M := 18.0
const BREAKER_LENGTH_M := 12.0
const FLATTEN_STRENGTH := 0.90

@export_range(1, 4, 1) var debug_mode := 3

var _surface: OceanClipmapSurface
var _camera: Camera3D
var _vdm: Texture2D
var _origin := Vector2.ZERO
var _propagation := Vector2(0.0, 1.0)
var _hud: Label
var _vdm_source := "PROCEDURAL FALLBACK"
var _waterline_flip_v := false
var _waterline_axis_mode := 0


func _ready() -> void:
	_camera = get_node_or_null(^"P0/FreeCamera") as Camera3D
	call_deferred(&"_activate_lab")


func _activate_lab() -> void:
	await get_tree().process_frame
	if _camera == null:
		push_error("P7 2C2B lab: FreeCamera is missing.")
		return
	var ocean := get_node_or_null(^"P0/Ocean")
	_surface = ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface if ocean != null else null
	if _surface == null:
		push_error("P7 2C2B lab: production OceanClipmapSurface is not ready.")
		return
	var camera_forward := -_camera.global_transform.basis.z
	_propagation = Vector2(camera_forward.x, camera_forward.z).normalized()
	if _propagation.length_squared() < 0.000001:
		_propagation = Vector2(0.0, 1.0)
	_origin = Vector2(_camera.global_position.x, _camera.global_position.z) + _propagation * 18.0
	_vdm = _load_vdm()
	_surface.enable_breaker_shape_lab(_vdm, _origin, _propagation, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH, debug_mode)
	_surface.configure_breaker_shape_lab_waterline(_vdm_source == "WATERLINE TEMP", _waterline_flip_v, _waterline_axis_mode, Vector3(6.0, 4.0, 18.0))
	_build_hud()
	_refresh_hud()


func _load_vdm() -> Texture2D:
	if ResourceLoader.exists(WATERLINE_VDM_PATH):
		var waterline := load(WATERLINE_VDM_PATH)
		if waterline is Texture2D:
			var waterline_image := (waterline as Texture2D).get_image()
			if waterline_image != null and waterline_image.get_width() == 512 and waterline_image.get_height() == 512:
				var waterline_format := waterline_image.get_format()
				if waterline_format == Image.FORMAT_RGBAH or waterline_format == Image.FORMAT_RGBAF:
					_vdm_source = "WATERLINE TEMP"
					print("P7 2C2B VDM | source=WATERLINE TEMP | size=512x512 | format=%s" % waterline_format)
					return waterline as Texture2D
			push_warning("P7 2C2B lab: Waterline EXR is not RGBAH/RGBAF 512x512; trying fallback sources.")
	if ResourceLoader.exists(EXTERNAL_VDM_PATH):
		var imported := load(EXTERNAL_VDM_PATH)
		if imported is Texture2D:
			var imported_image := (imported as Texture2D).get_image()
			if imported_image != null and imported_image.get_width() == 512 and imported_image.get_height() == 256:
				var imported_format := imported_image.get_format()
				if imported_format == Image.FORMAT_RGBAH or imported_format == Image.FORMAT_RGBAF:
					_vdm_source = "EXTERNAL EXR"
					print("P7 2C2 VDM | source=EXTERNAL EXR | size=512x256 | format=%s" % imported_format)
					return imported as Texture2D
				push_warning("P7 2C2 lab: EXR import is not RGBAH/RGBAF; using procedural fallback.")
	return VDMGenerator.build()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var next_mode := -1
		match event.keycode:
			KEY_0:
				_waterline_axis_mode = (_waterline_axis_mode + 1) % 3
				if _surface != null:
					_surface.configure_breaker_shape_lab_waterline(_vdm_source == "WATERLINE TEMP", _waterline_flip_v, _waterline_axis_mode, Vector3(6.0, 4.0, 18.0))
				_refresh_hud()
				return
			KEY_9:
				_waterline_flip_v = not _waterline_flip_v
				if _surface != null:
					_surface.configure_breaker_shape_lab_waterline(_vdm_source == "WATERLINE TEMP", _waterline_flip_v, _waterline_axis_mode, Vector3(6.0, 4.0, 18.0))
				_refresh_hud()
				return
			KEY_5: next_mode = 1
			KEY_6: next_mode = 2
			KEY_7: next_mode = 3
			KEY_8: next_mode = 4
		if next_mode > 0:
			debug_mode = next_mode
			if _surface != null:
				_surface.set_breaker_shape_lab_mode(debug_mode)
			_refresh_hud()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(14.0, 14.0)
	_hud.add_theme_font_size_override(&"font_size", 14)
	layer.add_child(_hud)


func _refresh_hud() -> void:
	if _hud == null:
		return
	var mode_names: Array[String] = ["", "BASE", "FLATTEN_ONLY", "VDM_ONLY", "COMBINED"]
	var mode_name: String = mode_names[clampi(debug_mode, 1, 4)]
	var axis_names: Array[String] = ["A R=PROP G=TAN B=VERT", "B R=PROP G=VERT B=TAN", "C R=TAN G=PROP B=VERT"]
	_hud.text = "P7 2C2B BREAKER SHAPE LAB\nPROFILE: WATERLINE TEMP / STATIC\nVDM SOURCE: %s\nmode: %s (5=BASE 6=FLATTEN 7=VDM 8=COMBINED)\nWATERLINE V FLIP: %s (9)\nWATERLINE AXES: %s (0)\norigin: %s\ndirection: %s\nwidth: %.1f m   length: %.1f m\nflatten: %.2f   VDM: %s" % [_vdm_source, mode_name, "ON" if _waterline_flip_v else "OFF", axis_names[clampi(_waterline_axis_mode, 0, 2)], _origin, _propagation, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH, "512 x 512 RGBAH" if _vdm_source == "WATERLINE TEMP" else ("512 x 256 RGBAH" if _vdm_source == "EXTERNAL EXR" else "256 x 256 RGBAH")]
