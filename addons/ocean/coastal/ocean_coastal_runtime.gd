class_name OceanCoastalRuntime
extends RefCounted
## Consume un Coastal Bake ya horneado; no contiene ni invoca herramientas de baking.

var _bake: Resource
var _textures := {}


func activate(bake: Resource) -> Dictionary:
	clear()
	if bake == null or not bake.is_valid():
		return {}
	var propagation: Resource = bake.propagation
	var warp: Resource = bake.warp
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
	}
	return _textures


func clear() -> void:
	# ImageTexture pertenece al Coastal Bake; este runtime sólo conserva referencias
	# mientras Coastal está activo y no posee RIDs de RenderingDevice.
	_bake = null
	_textures.clear()
