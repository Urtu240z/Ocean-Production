class_name OceanCoastalRuntime
extends RefCounted
## Consume un Coastal Bake ya horneado; no contiene ni invoca herramientas de baking.

var _bake: Resource
var _textures := {}


func activate(bake: Resource) -> Dictionary:
	clear()
	if bake == null or not bake.has_method(&"is_valid") or not bake.is_valid():
		return {}
	if not bake.has_method(&"get"):
		return {}
	var propagation: Resource = bake.propagation
	var warp: Resource = bake.warp
	if propagation == null or warp == null or not propagation.has_method(&"build_gpu_textures") or not warp.has_method(&"build_gpu_textures"):
		return {}
	var propagation_textures: Dictionary = propagation.build_gpu_textures()
	var warp_textures: Dictionary = warp.build_gpu_textures()
	if propagation_textures.is_empty() or warp_textures.is_empty():
		return {}
	_bake = bake
	_textures = {
		"field": propagation_textures.field,
		"metrics": propagation_textures.metrics,
		"phase": propagation_textures.phase,
		"warp": warp_textures.warp,
		"jacobian": warp_textures.jacobian,
		"origin": propagation.world_origin_xz,
		"extent": propagation.world_max_xz() - propagation.world_origin_xz,
		"warp_origin": warp.world_origin_xz,
		"warp_extent": warp.world_max_xz() - warp.world_origin_xz,
		"warp_detj_safe": warp.detj_safe_threshold,
		# Water Optics consumes only the baked real-seabed mask.  Coastal wave
		# propagation validity (field.a) never decides bathymetric authority.
		"seabed_coverage_enabled": false,
		"seabed_coverage": null,
		"seabed_origin": Vector2.ZERO,
		"seabed_extent": Vector2.ONE,
		"seabed_sea_level": 0.0,
	}
	var bathymetry: Resource = bake.get(&"bathymetry")
	if bathymetry != null and bathymetry.has_method(&"has_real_seabed_coverage") \
			and bathymetry.has_real_seabed_coverage() and bathymetry.has_method(&"build_gpu_seabed_coverage_texture"):
		var seabed_texture: Texture2D = bathymetry.build_gpu_seabed_coverage_texture()
		if seabed_texture != null:
			_textures["seabed_coverage_enabled"] = true
			_textures["seabed_coverage"] = seabed_texture
			_textures["seabed_origin"] = bathymetry.get(&"world_origin_xz")
			_textures["seabed_extent"] = bathymetry.call(&"world_max_xz") - bathymetry.get(&"world_origin_xz")
			_textures["seabed_sea_level"] = bathymetry.get(&"sea_level_y")
	return _textures


func clear() -> void:
	# ImageTexture pertenece al Coastal Bake; este runtime sólo conserva referencias
	# mientras Coastal está activo y no posee RIDs de RenderingDevice.
	_bake = null
	_textures.clear()
