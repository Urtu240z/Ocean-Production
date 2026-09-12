extends Node3D
## Static world-space 2C2C1 Waterline shore-space VDM proof on the production clipmap.

const VDMGenerator := preload("res://lab/p7_breaker_shape_lab/breaker_shape_vdm_generator.gd")
const WATERLINE_RAW_PATH := "res://temp/waterline_source/T_PL_Wave_1_Disp_source.bin"
const WATERLINE_RAW_BYTES := 2097152
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


func _ready() -> void:
	_camera = get_node_or_null(^"P0/FreeCamera") as Camera3D
	call_deferred(&"_activate_lab")


func _activate_lab() -> void:
	await get_tree().process_frame
	if _camera == null:
		push_error("P7 2C2C1 lab: FreeCamera is missing.")
		return
	var ocean := get_node_or_null(^"P0/Ocean")
	_surface = ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface if ocean != null else null
	if _surface == null:
		push_error("P7 2C2C1 lab: production OceanClipmapSurface is not ready.")
		return
	var camera_forward := -_camera.global_transform.basis.z
	_propagation = Vector2(camera_forward.x, camera_forward.z).normalized()
	if _propagation.length_squared() < 0.000001:
		_propagation = Vector2(0.0, 1.0)
	_origin = Vector2(_camera.global_position.x, _camera.global_position.z) + _propagation * 18.0
	_vdm = _load_vdm()
	if _vdm == null:
		push_error("P7 2C2C1 lab: Waterline RAW validation failed; lab not activated.")
		return
	_surface.enable_breaker_shape_lab(_vdm, _origin, _propagation, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH, debug_mode)
	_surface.configure_breaker_shape_lab_waterline(_vdm_source == "WATERLINE RAW", Vector3(6.0, 4.0, 18.0))
	_build_hud()
	_refresh_hud()


func _load_vdm() -> Texture2D:
	if FileAccess.file_exists(WATERLINE_RAW_PATH):
		var raw_bytes := FileAccess.get_file_as_bytes(WATERLINE_RAW_PATH)
		if raw_bytes.size() != WATERLINE_RAW_BYTES:
			push_error("P7 Waterline RAW: expected %d bytes at %s, got %d" % [WATERLINE_RAW_BYTES, WATERLINE_RAW_PATH, raw_bytes.size()])
			return null
		var waterline_image: Image = Image.create_from_data(512, 512, false, Image.FORMAT_RGBAH, raw_bytes)
		if waterline_image == null:
			push_error("P7 Waterline RAW: Image.create_from_data failed")
			return null
		if waterline_image.get_width() != 512 or waterline_image.get_height() != 512 or waterline_image.get_format() != Image.FORMAT_RGBAH:
			push_error("P7 Waterline RAW: image validation failed (expected 512x512 RGBAH)")
			return null
		if not _validate_waterline_raw_image(waterline_image):
			push_error("P7 Waterline RAW: numerical sanity check failed; refusing to compensate")
			return null
		var waterline_texture := ImageTexture.create_from_image(waterline_image)
		_vdm_source = "WATERLINE RAW"
		return waterline_texture
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


func _validate_waterline_raw_image(image: Image) -> bool:
	var min_r := INF
	var min_g := INF
	var min_b := INF
	var min_a := INF
	var max_r := -INF
	var max_g := -INF
	var max_b := -INF
	var max_a := -INF
	var invalid := false
	for y in 512:
		for x in 512:
			var pixel := image.get_pixel(x, y)
			if is_nan(pixel.r) or is_inf(pixel.r) or is_nan(pixel.g) or is_inf(pixel.g) or is_nan(pixel.b) or is_inf(pixel.b) or is_nan(pixel.a) or is_inf(pixel.a):
				invalid = true
			min_r = minf(min_r, pixel.r)
			min_g = minf(min_g, pixel.g)
			min_b = minf(min_b, pixel.b)
			min_a = minf(min_a, pixel.a)
			max_r = maxf(max_r, pixel.r)
			max_g = maxf(max_g, pixel.g)
			max_b = maxf(max_b, pixel.b)
			max_a = maxf(max_a, pixel.a)
	print("P7 WATERLINE RAW\npath=%s\nbytes=%d\nimage_format=RGBAH\nR=%.6f/%.6f\nG=%.6f/%.6f\nB=%.6f/%.6f\nA=%.6f/%.6f" % [WATERLINE_RAW_PATH, WATERLINE_RAW_BYTES, min_r, max_r, min_g, max_g, min_b, max_b, min_a, max_a])
	var ranges_ok := min_r >= -0.5 and max_r <= 1.0 and min_g >= -0.5 and max_g <= 0.1 and min_b >= -0.5 and max_b <= 0.5
	var alpha_ok := is_equal_approx(min_a, 1.0) and is_equal_approx(max_a, 1.0)
	return not invalid and ranges_ok and alpha_ok


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
	_hud.text = "P7 2C2C2 BREAKER SHAPE LAB\nPROFILE: WATERLINE RAW / STATIC\nVDM SOURCE: %s\nSHORE DRIVER: REAL COASTAL\nmode: %s (5=BASE 6=FLATTEN 7=VDM 8=COMBINED)\ndepth near/far: 0.25 / 8.0 m\nalong-shore period: 18.0 m\nWATERLINE U FLIP: LOCKED OFF\nWATERLINE V FLIP: LOCKED OFF\norigin: %s\nbox direction (test limit): %s\nwidth: %.1f m   length: %.1f m\nflatten: %.2f   VDM: %s" % [_vdm_source, mode_name, _origin, _propagation, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH, "512 x 512 RGBAH" if _vdm_source == "WATERLINE RAW" else ("512 x 256 RGBAH" if _vdm_source == "EXTERNAL EXR" else "256 x 256 RGBAH")]
