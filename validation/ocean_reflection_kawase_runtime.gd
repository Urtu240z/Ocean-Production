extends SceneTree
const KAWASE := preload("res://addons/ocean/reflections/ocean_reflection_kawase.gd")
var _blur: Node
var _profile: OceanReflectionProfile

func _initialize() -> void:
	call_deferred(&"_run")

func _require(condition: bool, message: String) -> void:
	if not condition:
		push_error("KAWASE_FAIL: " + message)
		quit(1)
		assert(condition, message)

func _render(source: Texture2D, size: Vector2i) -> Texture2D:
	var output: Texture2D
	for frame in 8:
		output = _blur.filter_texture(source, size)
		await process_frame
	await RenderingServer.frame_post_draw
	return output

func _stats(image: Image) -> Dictionary:
	var weight := 0.0
	var moment := 0.0
	var peak := 0.0
	var max_radiance := 0.0
	var center := Vector2(image.get_size()) * 0.5 - Vector2(0.5, 0.5)
	for y in image.get_height():
		for x in image.get_width():
			var pixel := image.get_pixel(x, y)
			var energy := pixel.r * pixel.a
			weight += energy
			moment += energy * Vector2(x, y).distance_squared_to(center)
			peak = maxf(peak, energy)
			if pixel.a > 0.01:
				max_radiance = maxf(max_radiance, pixel.r)
	return {"energy": weight, "spread": moment / maxf(weight, 0.00001), "peak": peak, "radiance": max_radiance}

func _run() -> void:
	_blur = KAWASE.new()
	root.add_child(_blur)
	_profile = OceanReflectionProfile.new()
	var image := Image.create(128, 128, false, Image.FORMAT_RGBAF)
	image.fill(Color(0, 0, 0, 0))
	for y in range(62, 66):
		for x in range(62, 66):
			image.set_pixel(x, y, Color(16, 0, 0, 1))
	var source := ImageTexture.create_from_image(image)
	_blur.configure(_profile)
	_require(await _render(source, image.get_size()) == source, "disabled is exact passthrough")
	_require(_blur.get("_passes").is_empty(), "disabled allocates no blur targets")
	_profile.kawase_enabled = true
	_profile.kawase_strength = 1.0
	_blur.configure(_profile)
	var mild := await _render(source, image.get_size())
	var mild_image := mild.get_image()
	var a := _stats(mild_image)
	_require(absf(a.energy - 256.0) < 15.0 and a.radiance > 15.0, "fractional radius preserves HDR at confidence edges")
	_profile.kawase_strength = 4.0
	_blur.configure(_profile)
	var strong := await _render(source, image.get_size())
	var strong_image := strong.get_image()
	var b := _stats(strong_image)
	_require(b.spread > a.spread * 5.0, "strength increases blur footprint")
	_require(b.peak < a.peak * 0.5, "strength softens peak")
	_require(absf(b.energy - 256.0) < 15.0, "HDR confidence-weighted energy preserved")
	_require(b.radiance > 15.0, "confidence holes do not darken HDR radiance")
	DirAccess.make_dir_recursive_absolute("res://temp/kawase_validation")
	mild_image.convert(Image.FORMAT_RGBA8)
	strong_image.convert(Image.FORMAT_RGBA8)
	mild_image.save_png("res://temp/kawase_validation/strength_1.png")
	strong_image.save_png("res://temp/kawase_validation/strength_4.png")
	_profile.kawase_strength = 0.0
	_blur.configure(_profile)
	_require(await _render(source, image.get_size()) == source, "strength zero is exact passthrough")
	for viewport in _blur.get("_passes"):
		_require(viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "zero stops render passes")
	_profile.kawase_strength = 2.0
	_blur.configure(_profile)
	await _render(source, Vector2i(96, 64))
	for viewport in _blur.get("_passes"):
		_require(viewport.size == Vector2i(96, 64), "all passes resize")
	_blur.shutdown()
	_blur.queue_free()
	await process_frame
	print("KAWASE_GPU_PASS mild=", a, " strong=", b)
	quit(0)
