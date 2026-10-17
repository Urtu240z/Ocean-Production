extends SceneTree
## Deterministic masks derived from Ocean's existing crest noise, built once.
func _initialize() -> void:
	var texture: NoiseTexture2D = load("res://addons/ocean/surface/crest_breakup_noise.tres")
	var noise := texture.noise as FastNoiseLite
	for kind in ["contact", "wake"]:
		var image := Image.create(128, 256, false, Image.FORMAT_RGBA8)
		for y in 256:
			for x in 128:
				var u := (float(x) + 0.5) / 128.0
				var v := (float(y) + 0.5) / 256.0
				var n := noise.get_noise_2d(x * 4.1, y * 3.7) * 0.5 + 0.5
				var fine := noise.get_noise_2d(x * 15.3 + 1300, y * 15.7) * 0.5 + 0.5
				var ridge := 1.0 - smoothstep(0.018, 0.075, absf(fine - 0.50))
				var holes := smoothstep(0.28, 0.58, n)
				var lateral := absf(u * 2.0 - 1.0)
				var shape := 0.0
				if kind == "contact":
					var hull_width := 0.62 + 0.08 * sin(v * PI) - 0.24 * pow(1.0 - v, 3.0)
					var width := 0.065 + n * 0.065
					shape = exp(-pow((lateral - hull_width - (n - 0.5) * 0.08) / width, 2))
				else:
					var arm := 0.05 + v * 0.77 + (n - 0.5) * 0.11
					shape = exp(-pow((lateral - arm) / (0.04 + v * 0.06), 2))
					shape += exp(-pow(lateral / 0.17, 2)) * 0.28 * (1.0 - v)
				var edge := smoothstep(0.0, 0.08, minf(minf(u, 1-u), minf(v, 1-v)))
				var alpha := clampf(shape * (ridge * holes + smoothstep(0.60, 0.76, fine) * 0.30) * edge, 0.0, 1.0)
				image.set_pixel(x, y, Color(n, fine, ridge, alpha))
		var path := "res://addons/ocean/surface/foam2d/%s_mask.png" % kind
		image.save_png(path)
		print("FOAM2D_MASK ", path)
	quit()
