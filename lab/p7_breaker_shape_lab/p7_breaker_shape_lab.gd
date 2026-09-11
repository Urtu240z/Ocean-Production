extends Node3D
## Static world-space 2C1 breaker-shape proof on the production clipmap.

const VDMGenerator := preload("res://lab/p7_breaker_shape_lab/breaker_shape_vdm_generator.gd")
const WAVEFRONT_WIDTH_M := 18.0
const BREAKER_LENGTH_M := 12.0
const FLATTEN_STRENGTH := 0.90

@export_range(1, 4, 1) var debug_mode := 4

var _surface: OceanClipmapSurface
var _camera: Camera3D
var _vdm: ImageTexture
var _origin := Vector2.ZERO
var _propagation := Vector2(0.0, 1.0)
var _hud: Label


func _ready() -> void:
	_camera = get_node_or_null(^"P0/FreeCamera") as Camera3D
	call_deferred(&"_activate_lab")


func _activate_lab() -> void:
	await get_tree().process_frame
	if _camera == null:
		push_error("P7 2C1 lab: FreeCamera is missing.")
		return
	var ocean := get_node_or_null(^"P0/Ocean")
	_surface = ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface if ocean != null else null
	if _surface == null:
		push_error("P7 2C1 lab: production OceanClipmapSurface is not ready.")
		return
	var camera_forward := -_camera.global_transform.basis.z
	_propagation = Vector2(camera_forward.x, camera_forward.z).normalized()
	if _propagation.length_squared() < 0.000001:
		_propagation = Vector2(0.0, 1.0)
	_origin = Vector2(_camera.global_position.x, _camera.global_position.z) + _propagation * 18.0
	_vdm = VDMGenerator.build()
	_surface.enable_breaker_shape_lab(_vdm, _origin, _propagation, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH, debug_mode)
	_build_hud()
	_refresh_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var next_mode := -1
		match event.keycode:
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
	_hud.text = "P7 2C1 BREAKER SHAPE LAB\nmode: %s (5=BASE 6=FLATTEN 7=VDM 8=COMBINED)\norigin: %s\ndirection: %s\nwidth: %.1f m   length: %.1f m\nflatten: %.2f   VDM: 256 x 256 RGBAH" % [mode_name, _origin, _propagation, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH]
