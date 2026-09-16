class_name OceanRefinementBatcher
extends RefCounted
## Agrupa tiles de refinement por variante de malla sin reconstruir geometría.

var _parent: Node3D
var _material: Material
var _batch_nodes: Array[MultiMeshInstance3D] = []
var _multimeshes: Array[MultiMesh] = []
var _tile_transforms: Array[Transform3D] = []
var _variant_meshes: Array[ArrayMesh] = []
var _active_batch_count := 0
var _transform_updates_last_transition := 0
var _variant_assignments: Array[int] = []
var _culling_aabb := AABB()
var _has_culling_aabb := false


func configure(parent: Node3D, material: Material, variant_meshes: Array[ArrayMesh], tile_transforms: Array[Transform3D]) -> Dictionary:
	clear()
	if parent == null or variant_meshes.is_empty() or tile_transforms.is_empty():
		return {}
	_parent = parent
	_material = material
	_variant_meshes = variant_meshes
	_tile_transforms = tile_transforms
	for variant_index in _variant_meshes.size():
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.instance_count = _tile_transforms.size()
		multimesh.mesh = _variant_meshes[variant_index]
		var batch := MultiMeshInstance3D.new()
		batch.name = "OceanRefinementBatch_%02d" % variant_index
		batch.multimesh = multimesh
		batch.material_override = _material
		batch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		batch.extra_cull_margin = 4.0
		multimesh.visible_instance_count = 0
		batch.visible = false
		_parent.add_child(batch)
		_batch_nodes.append(batch)
		_multimeshes.append(multimesh)
	return {
		"batch_node_count": _batch_nodes.size(),
		"multimesh_count": _multimeshes.size(),
		"logical_instance_count": _tile_transforms.size(),
	}


func set_culling_aabb(aabb: AABB) -> bool:
	if _has_culling_aabb and _culling_aabb.position.is_equal_approx(aabb.position) and _culling_aabb.size.is_equal_approx(aabb.size):
		return false
	_culling_aabb = aabb
	_has_culling_aabb = true
	for multimesh in _multimeshes:
		if is_instance_valid(multimesh):
			multimesh.custom_aabb = aabb
	for batch in _batch_nodes:
		if is_instance_valid(batch):
			batch.custom_aabb = aabb
	return true


func get_culling_aabb() -> AABB:
	return _culling_aabb


func get_authored_aabb() -> AABB:
	var result := AABB()
	var has_result := false
	for mesh in _variant_meshes:
		if mesh == null:
			continue
		var mesh_aabb := mesh.get_aabb()
		for transform in _tile_transforms:
			var transformed := _transform_aabb(mesh_aabb, transform)
			if not has_result:
				result = transformed
				has_result = true
			else:
				result = _merge_aabbs(result, transformed)
	return result if has_result else AABB()


func update_tile_transforms(tile_transforms: Array[Transform3D]) -> Dictionary:
	if _batch_nodes.is_empty() or tile_transforms.size() != _tile_transforms.size():
		return {}
	_tile_transforms = tile_transforms
	if _variant_assignments.is_empty():
		return {"instance_transform_updates": 0}
	var updates := 0
	for variant_index in _batch_nodes.size():
		var multimesh := _multimeshes[variant_index]
		var instance_index := 0
		for tile_index in _variant_assignments.size():
			if _variant_assignments[tile_index] != variant_index:
				continue
			multimesh.set_instance_transform(instance_index, _tile_transforms[tile_index])
			instance_index += 1
			updates += 1
	_transform_updates_last_transition = updates
	return {"instance_transform_updates": updates}


func apply_variant_assignments(variant_assignments: Array[int]) -> Dictionary:
	if _batch_nodes.is_empty() or variant_assignments.size() != _tile_transforms.size():
		return {}
	var grouped := []
	grouped.resize(_batch_nodes.size())
	for variant_index in _batch_nodes.size():
		grouped[variant_index] = []
	for tile_index in variant_assignments.size():
		var variant_index: int = clampi(variant_assignments[tile_index], 0, _batch_nodes.size() - 1)
		grouped[variant_index].append(tile_index)
	var transform_updates := 0
	_variant_assignments = variant_assignments.duplicate()
	_active_batch_count = 0
	for variant_index in _batch_nodes.size():
		var tile_indices: Array = grouped[variant_index]
		var active_count: int = tile_indices.size()
		var batch := _batch_nodes[variant_index]
		var multimesh := _multimeshes[variant_index]
		multimesh.visible_instance_count = active_count
		batch.visible = active_count > 0
		if active_count > 0:
			_active_batch_count += 1
		for instance_index in active_count:
			var tile_index: int = tile_indices[instance_index]
			multimesh.set_instance_transform(instance_index, _tile_transforms[tile_index])
			transform_updates += 1
	_transform_updates_last_transition = transform_updates
	var active_batch_variants: Array[int] = []
	for variant_index in _batch_nodes.size():
		if not grouped[variant_index].is_empty():
			active_batch_variants.append(variant_index)
	return {
		"active_batch_count": _active_batch_count,
		"batch_node_count": _batch_nodes.size(),
		"multimesh_count": _multimeshes.size(),
		"logical_instance_count": variant_assignments.size(),
		"active_batch_variants": active_batch_variants,
		"active_surface_count": _active_batch_count,
		"draw_call_count_approx": _active_batch_count,
		"instance_transform_updates_last_transition": _transform_updates_last_transition,
		"mesh_assignments_last_transition": 0,
	}


func hide() -> void:
	for batch in _batch_nodes:
		if is_instance_valid(batch):
			batch.multimesh.visible_instance_count = 0
			batch.visible = false
	_active_batch_count = 0


func clear() -> void:
	for batch in _batch_nodes:
		if is_instance_valid(batch):
			batch.queue_free()
	_batch_nodes.clear()
	_multimeshes.clear()
	_tile_transforms.clear()
	_variant_meshes.clear()
	_variant_assignments.clear()
	_parent = null
	_material = null
	_active_batch_count = 0
	_transform_updates_last_transition = 0
	_culling_aabb = AABB()
	_has_culling_aabb = false


func get_batch_node_count() -> int:
	return _batch_nodes.size()


func get_active_batch_count() -> int:
	return _active_batch_count


func get_transform_updates_last_transition() -> int:
	return _transform_updates_last_transition


func _transform_aabb(source: AABB, transform: Transform3D) -> AABB:
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for x in [source.position.x, source.position.x + source.size.x]:
		for y in [source.position.y, source.position.y + source.size.y]:
			for z in [source.position.z, source.position.z + source.size.z]:
				var point := transform * Vector3(x, y, z)
				minimum.x = minf(minimum.x, point.x)
				minimum.y = minf(minimum.y, point.y)
				minimum.z = minf(minimum.z, point.z)
				maximum.x = maxf(maximum.x, point.x)
				maximum.y = maxf(maximum.y, point.y)
				maximum.z = maxf(maximum.z, point.z)
	return AABB(minimum, maximum - minimum)


func _merge_aabbs(a: AABB, b: AABB) -> AABB:
	var minimum := Vector3(
		minf(a.position.x, b.position.x),
		minf(a.position.y, b.position.y),
		minf(a.position.z, b.position.z))
	var a_max := a.position + a.size
	var b_max := b.position + b.size
	var maximum := Vector3(
		maxf(a_max.x, b_max.x),
		maxf(a_max.y, b_max.y),
		maxf(a_max.z, b_max.z))
	return AABB(minimum, maximum - minimum)
