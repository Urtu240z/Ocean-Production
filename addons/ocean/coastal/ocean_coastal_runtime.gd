class_name OceanCoastalRuntime
extends RefCounted
## Consume un Coastal Bake ya horneado; no contiene ni invoca herramientas de baking.
## La residencia de las texturas es independiente de que Coastal/Optics estén activos.

var _cached_bake: Resource
var _cached_propagation: Resource
var _cached_warp: Resource
var _cached_bathymetry: Resource
var _cached_textures: Dictionary = {}
var _cache_dirty := false
var _active := false
var _active_bake_instance_id := 0
var _connected_resources: Array[Resource] = []
var _build_count := 0
var _cache_hit_count := 0
var _deactivate_count := 0
var _generation := 0


func activate(bake: Resource) -> Dictionary:
	if not _is_valid_bake(bake):
		if _cached_bake != null and _resource_instance_id(_cached_bake) != _resource_instance_id(bake):
			_discard_cache()
		deactivate()
		return {}

	var propagation: Resource = bake.get("propagation") as Resource
	var warp: Resource = bake.get("warp") as Resource
	var bathymetry: Resource = bake.get("bathymetry") as Resource
	if propagation == null or warp == null or not _resources_can_build(propagation, warp):
		if _cached_bake != null and _resource_instance_id(_cached_bake) != _resource_instance_id(bake):
			_discard_cache()
		deactivate()
		return {}

	if _cache_matches(bake, propagation, warp, bathymetry) and _cache_is_valid():
		_cache_hit_count += 1
		_active = true
		_active_bake_instance_id = _resource_instance_id(bake)
		return _cached_textures.duplicate()

	# A new identity or an invalidated subresource replaces the one-bake cache.
	# Build into a local dictionary first so an incomplete build cannot publish a
	# mixture of the previous bake and the candidate bake.
	_discard_cache()
	var next_textures: Dictionary = _build_textures(propagation, warp, bathymetry)
	if next_textures.is_empty():
		deactivate()
		return {}

	_cached_bake = bake
	_cached_propagation = propagation
	_cached_warp = warp
	_cached_bathymetry = bathymetry
	_cached_textures = next_textures
	_cache_dirty = false
	_generation += 1
	_build_count += 1
	_active = true
	_active_bake_instance_id = _resource_instance_id(bake)
	_connect_cache_signals()
	return _cached_textures.duplicate()


func deactivate() -> void:
	_deactivate_count += 1
	_active = false
	_active_bake_instance_id = 0


func clear() -> void:
	# ImageTexture pertenece al Coastal Bake; este runtime sólo conserva referencias
	# mientras vive OpenOceanFFT y no posee RIDs de RenderingDevice.
	_discard_cache()
	_active = false
	_active_bake_instance_id = 0
	_cache_dirty = false


func get_runtime_state() -> Dictionary:
	return {
		"resident": _cached_bake != null and _cache_is_valid(),
		"active": _active,
		"active_bake_instance_id": _active_bake_instance_id,
		"resident_bake_instance_id": _resource_instance_id(_cached_bake),
		"cache_dirty": _cache_dirty,
		"build_count": _build_count,
		"cache_hit_count": _cache_hit_count,
		"deactivate_count": _deactivate_count,
		"generation": _generation,
		"connected_resource_count": _connected_resources.size(),
		"has_field": _has_texture("field"),
		"has_metrics": _has_texture("metrics"),
		"has_phase": _has_texture("phase"),
		"has_warp": _has_texture("warp"),
		"has_jacobian": _has_texture("jacobian"),
		"has_seabed_coverage": bool(_cached_textures.get("seabed_coverage_enabled", false)) and _has_texture("seabed_coverage"),
	}


func _is_valid_bake(bake: Resource) -> bool:
	return bake != null and is_instance_valid(bake) and bake.has_method(&"is_valid") and bake.is_valid()


func _resources_can_build(propagation: Resource, warp: Resource) -> bool:
	return propagation.has_method(&"build_gpu_textures") and warp.has_method(&"build_gpu_textures")


func _cache_matches(bake: Resource, propagation: Resource, warp: Resource, bathymetry: Resource) -> bool:
	return _cached_bake != null \
		and _resource_instance_id(_cached_bake) == _resource_instance_id(bake) \
		and _resource_instance_id(_cached_propagation) == _resource_instance_id(propagation) \
		and _resource_instance_id(_cached_warp) == _resource_instance_id(warp) \
		and _resource_instance_id(_cached_bathymetry) == _resource_instance_id(bathymetry) \
		and not _cache_dirty


func _build_textures(propagation: Resource, warp: Resource, bathymetry: Resource) -> Dictionary:
	var propagation_textures: Dictionary = propagation.build_gpu_textures()
	var warp_textures: Dictionary = warp.build_gpu_textures()
	if not _has_texture_in(propagation_textures, "field") or not _has_texture_in(propagation_textures, "metrics") or not _has_texture_in(propagation_textures, "phase"):
		return {}
	if not _has_texture_in(warp_textures, "warp") or not _has_texture_in(warp_textures, "jacobian"):
		return {}

	var textures: Dictionary = {
		"field": propagation_textures["field"],
		"metrics": propagation_textures["metrics"],
		"phase": propagation_textures["phase"],
		"warp": warp_textures["warp"],
		"jacobian": warp_textures["jacobian"],
		"origin": propagation.get("world_origin_xz"),
		"extent": propagation.call(&"world_max_xz") - propagation.get("world_origin_xz"),
		"warp_origin": warp.get("world_origin_xz"),
		"warp_extent": warp.call(&"world_max_xz") - warp.get("world_origin_xz"),
		"warp_detj_safe": warp.get("detj_safe_threshold"),
		# Water Optics consumes only the baked real-seabed mask. Coastal wave
		# validity never decides bathymetric authority.
		"seabed_coverage_enabled": false,
		"seabed_coverage": null,
		"seabed_origin": Vector2.ZERO,
		"seabed_extent": Vector2.ONE,
		"seabed_sea_level": 0.0,
	}
	if bathymetry != null and bathymetry.has_method(&"has_real_seabed_coverage") \
			and bathymetry.has_real_seabed_coverage() and bathymetry.has_method(&"build_gpu_seabed_coverage_texture"):
		var seabed_texture: Texture2D = bathymetry.build_gpu_seabed_coverage_texture()
		if seabed_texture != null:
			textures["seabed_coverage_enabled"] = true
			textures["seabed_coverage"] = seabed_texture
			textures["seabed_origin"] = bathymetry.get("world_origin_xz")
			textures["seabed_extent"] = bathymetry.call(&"world_max_xz") - bathymetry.get("world_origin_xz")
			textures["seabed_sea_level"] = bathymetry.get("sea_level_y")
	return textures


func _cache_is_valid() -> bool:
	return not _cached_textures.is_empty() \
		and _has_texture("field") \
		and _has_texture("metrics") \
		and _has_texture("phase") \
		and _has_texture("warp") \
		and _has_texture("jacobian")


func _has_texture(key: StringName) -> bool:
	return _has_texture_in(_cached_textures, key)


func _has_texture_in(values: Dictionary, key: StringName) -> bool:
	return values.has(key) and values[key] is Texture2D and values[key] != null


func _resource_instance_id(resource: Resource) -> int:
	return resource.get_instance_id() if resource != null and is_instance_valid(resource) else 0


func _connect_cache_signals() -> void:
	_disconnect_cache_signals()
	for resource in [_cached_bake, _cached_propagation, _cached_warp, _cached_bathymetry]:
		if resource == null or not is_instance_valid(resource) or _connected_resources.has(resource):
			continue
		var callback := Callable(self, "_on_cached_resource_changed")
		if not resource.changed.is_connected(callback):
			resource.changed.connect(callback)
		_connected_resources.append(resource)


func _disconnect_cache_signals() -> void:
	var callback := Callable(self, "_on_cached_resource_changed")
	for resource in _connected_resources:
		if resource != null and is_instance_valid(resource) and resource.changed.is_connected(callback):
			resource.changed.disconnect(callback)
	_connected_resources.clear()


func _on_cached_resource_changed() -> void:
	_cache_dirty = true


func _discard_cache() -> void:
	_disconnect_cache_signals()
	_cached_bake = null
	_cached_propagation = null
	_cached_warp = null
	_cached_bathymetry = null
	_cached_textures.clear()
	_cache_dirty = false
	_active = false
	_active_bake_instance_id = 0
