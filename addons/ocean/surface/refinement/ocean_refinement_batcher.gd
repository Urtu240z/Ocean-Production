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
		batch.name = "BreakerShapeLabRefinementBatch_%02d" % variant_index
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
	_parent = null
	_material = null
	_active_batch_count = 0
	_transform_updates_last_transition = 0


func get_batch_node_count() -> int:
	return _batch_nodes.size()


func get_active_batch_count() -> int:
	return _active_batch_count


func get_transform_updates_last_transition() -> int:
	return _transform_updates_last_transition
