class_name OceanClipmapMeshBuilder
extends RefCounted
## Construye el centro y anillos 2:1. Se ejecuta sólo al inicializar el clipmap.

static func build_level(cells_per_side: int, spacing: float, level: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_indices := {}
	var stitch_positions := PackedVector3Array()
	var half_cells := int(float(cells_per_side) * 0.5)
	if level == 0:
		for z_cell in range(-half_cells, half_cells):
			for x_cell in range(-half_cells, half_cells):
				_add_regular_cell(vertices, normals, indices, vertex_indices, x_cell, z_cell, spacing)
	else:
		var inner_cells := int(float(half_cells) * 0.5)
		for z_cell in range(-half_cells, half_cells):
			for x_cell in range(-half_cells, half_cells):
				if x_cell >= -inner_cells and x_cell < inner_cells and z_cell >= -inner_cells and z_cell < inner_cells:
					continue
				if z_cell == -inner_cells - 1 and x_cell >= -inner_cells and x_cell < inner_cells:
					_add_horizontal_stitch(vertices, normals, indices, vertex_indices, stitch_positions, x_cell, -inner_cells, -1, spacing)
				elif z_cell == inner_cells and x_cell >= -inner_cells and x_cell < inner_cells:
					_add_horizontal_stitch(vertices, normals, indices, vertex_indices, stitch_positions, x_cell, inner_cells, 1, spacing)
				elif x_cell == -inner_cells - 1 and z_cell >= -inner_cells and z_cell < inner_cells:
					_add_vertical_stitch(vertices, normals, indices, vertex_indices, stitch_positions, -inner_cells, z_cell, -1, spacing)
				elif x_cell == inner_cells and z_cell >= -inner_cells and z_cell < inner_cells:
					_add_vertical_stitch(vertices, normals, indices, vertex_indices, stitch_positions, inner_cells, z_cell, 1, spacing)
				else:
					_add_regular_cell(vertices, normals, indices, vertex_indices, x_cell, z_cell, spacing)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func build_aligned_grid(s_extent_m: float, v_extent_m: float, spacing: float, reference_direction: Vector2) -> ArrayMesh:
	var safe_spacing := maxf(spacing, 0.001)
	var safe_direction := reference_direction.normalized()
	if safe_direction.length_squared() < 0.000001:
		safe_direction = Vector2(0.0, 1.0)
	var reference_tangent := Vector2(-safe_direction.y, safe_direction.x)
	var s_cells := maxi(roundi(maxf(s_extent_m, safe_spacing) / safe_spacing), 1)
	var v_cells := maxi(roundi(maxf(v_extent_m, safe_spacing) / safe_spacing), 1)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_indices := {}
	var s_start := -float(s_cells) * safe_spacing * 0.5
	var v_start := -float(v_cells) * safe_spacing * 0.5
	for v_cell in v_cells:
		for s_cell in s_cells:
			var s0 := s_start + float(s_cell) * safe_spacing
			var s1 := s0 + safe_spacing
			var v0 := v_start + float(v_cell) * safe_spacing
			var v1 := v0 + safe_spacing
			_add_aligned_regular_cell(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, s0, s1, v0, v1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func build_static_local_refinement_tile(outer_s_extent_m: float, outer_v_extent_m: float, core_s_extent_m: float, core_v_extent_m: float, outer_spacing: float, core_spacing: float, reference_direction: Vector2) -> Dictionary:
	var safe_outer_spacing := maxf(outer_spacing, 0.001)
	var safe_core_spacing := maxf(core_spacing, 0.001)
	var safe_direction := reference_direction.normalized()
	if safe_direction.length_squared() < 0.000001:
		safe_direction = Vector2(0.0, 1.0)
	var reference_tangent := Vector2(-safe_direction.y, safe_direction.x)
	var outer_s_cells := maxi(roundi(maxf(outer_s_extent_m, safe_outer_spacing) / safe_outer_spacing), 1)
	var outer_v_cells := maxi(roundi(maxf(outer_v_extent_m, safe_outer_spacing) / safe_outer_spacing), 1)
	var core_s_cells := maxi(roundi(maxf(core_s_extent_m, safe_core_spacing) / safe_core_spacing), 1)
	var core_v_cells := maxi(roundi(maxf(core_v_extent_m, safe_core_spacing) / safe_core_spacing), 1)
	var core_s_coarse_cells := maxi(roundi(maxf(core_s_extent_m, safe_outer_spacing) / safe_outer_spacing), 1)
	var core_v_coarse_cells := maxi(roundi(maxf(core_v_extent_m, safe_outer_spacing) / safe_outer_spacing), 1)
	var outer_s_min := -float(outer_s_cells) * safe_outer_spacing * 0.5
	var outer_v_min := -float(outer_v_cells) * safe_outer_spacing * 0.5
	var core_s_min := -float(core_s_coarse_cells) * safe_outer_spacing * 0.5
	var core_v_min := -float(core_v_coarse_cells) * safe_outer_spacing * 0.5
	var core_s_max := -core_s_min
	var core_v_max := -core_v_min
	var expanded_s_min := core_s_min - safe_outer_spacing
	var expanded_s_max := core_s_max + safe_outer_spacing
	var expanded_v_min := core_v_min - safe_outer_spacing
	var expanded_v_max := core_v_max + safe_outer_spacing
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var vertex_indices := {}
	var outer_triangles := 0
	var core_triangles := 0
	var stitch_triangles := 0
	var outer_cells := 0
	var core_cells := 0
	# The coarse outer region excludes the core and one-cell transition buffer.
	# The excluded buffer is filled below by explicit 2:1 stitch triangles.
	for v_cell in outer_v_cells:
		var v0 := outer_v_min + float(v_cell) * safe_outer_spacing
		var v1 := v0 + safe_outer_spacing
		for s_cell in outer_s_cells:
			var s0 := outer_s_min + float(s_cell) * safe_outer_spacing
			var s1 := s0 + safe_outer_spacing
			var inside_transition_box := s0 >= expanded_s_min - 0.00001 and s1 <= expanded_s_max + 0.00001 and v0 >= expanded_v_min - 0.00001 and v1 <= expanded_v_max + 0.00001
			if inside_transition_box:
				continue
			_add_aligned_regular_cell(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, s0, s1, v0, v1)
			outer_cells += 1
			outer_triangles += 2
	# The refined core is generated at the exact fine spacing.
	for v_cell in core_v_cells:
		var v0 := core_v_min + float(v_cell) * safe_core_spacing
		var v1 := v0 + safe_core_spacing
		for s_cell in core_s_cells:
			var s0 := core_s_min + float(s_cell) * safe_core_spacing
			var s1 := s0 + safe_core_spacing
			_add_aligned_regular_cell(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, s0, s1, v0, v1)
			core_cells += 1
			core_triangles += 2
	# Each coarse core-edge segment has two fine boundary segments. The three
	# triangles below replace the coarse cell row and make the seam conforming.
	for s_cell in core_s_coarse_cells:
		var s0 := core_s_min + float(s_cell) * safe_outer_spacing
		var s1 := s0 + safe_outer_spacing
		stitch_triangles += _add_refinement_horizontal_stitch(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, s0, s1, core_v_min, core_v_min - safe_outer_spacing)
		stitch_triangles += _add_refinement_horizontal_stitch(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, s0, s1, core_v_max, core_v_max + safe_outer_spacing)
	for v_cell in core_v_coarse_cells:
		var v0 := core_v_min + float(v_cell) * safe_outer_spacing
		var v1 := v0 + safe_outer_spacing
		stitch_triangles += _add_refinement_vertical_stitch(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, core_s_min, core_s_min - safe_outer_spacing, v0, v1)
		stitch_triangles += _add_refinement_vertical_stitch(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, core_s_max, core_s_max + safe_outer_spacing, v0, v1)
	# Four coarse corner cells close the corners of the transition buffer.
	_add_aligned_regular_cell(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, expanded_s_min, core_s_min, core_v_max, expanded_v_max)
	_add_aligned_regular_cell(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, core_s_max, expanded_s_max, core_v_max, expanded_v_max)
	_add_aligned_regular_cell(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, expanded_s_min, core_s_min, expanded_v_min, core_v_min)
	_add_aligned_regular_cell(vertices, normals, indices, vertex_indices, safe_direction, reference_tangent, core_s_max, expanded_s_max, expanded_v_min, core_v_min)
	stitch_triangles += 8
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var edge_summary := _edge_topology_summary(indices)
	return {
		"mesh": mesh,
		"outer_s_cells": outer_s_cells,
		"outer_v_cells": outer_v_cells,
		"core_s_cells": core_s_cells,
		"core_v_cells": core_v_cells,
		"outer_cells": outer_cells,
		"core_cells": core_cells,
		"outer_triangles": outer_triangles,
		"core_triangles": core_triangles,
		"stitch_triangles": stitch_triangles,
		"vertices": vertices.size(),
		"triangles": indices.size() / 3,
		"surface_count": 1,
		"edge_summary": edge_summary,
	}


static func _add_refinement_horizontal_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, lookup: Dictionary, direction: Vector2, tangent: Vector2, s0: float, s1: float, inner_v: float, outer_v: float) -> int:
	var a := _aligned_vertex(vertices, normals, lookup, direction, tangent, s0, inner_v)
	var middle := _aligned_vertex(vertices, normals, lookup, direction, tangent, (s0 + s1) * 0.5, inner_v)
	var b := _aligned_vertex(vertices, normals, lookup, direction, tangent, s1, inner_v)
	var c := _aligned_vertex(vertices, normals, lookup, direction, tangent, s0, outer_v)
	var d := _aligned_vertex(vertices, normals, lookup, direction, tangent, s1, outer_v)
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)
	return 3


static func _add_refinement_vertical_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, lookup: Dictionary, direction: Vector2, tangent: Vector2, inner_s: float, outer_s: float, v0: float, v1: float) -> int:
	var a := _aligned_vertex(vertices, normals, lookup, direction, tangent, inner_s, v0)
	var middle := _aligned_vertex(vertices, normals, lookup, direction, tangent, inner_s, (v0 + v1) * 0.5)
	var b := _aligned_vertex(vertices, normals, lookup, direction, tangent, inner_s, v1)
	var c := _aligned_vertex(vertices, normals, lookup, direction, tangent, outer_s, v0)
	var d := _aligned_vertex(vertices, normals, lookup, direction, tangent, outer_s, v1)
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)
	return 3


static func _aligned_vertex(vertices: PackedVector3Array, normals: PackedVector3Array, lookup: Dictionary, direction: Vector2, tangent: Vector2, s: float, v: float) -> int:
	return _vertex(vertices, normals, lookup, Vector3(direction.x * s + tangent.x * v, 0.0, direction.y * s + tangent.y * v))


static func _edge_topology_summary(indices: PackedInt32Array) -> Dictionary:
	var edge_counts := {}
	for index in range(0, indices.size(), 3):
		_count_edge(edge_counts, indices[index], indices[index + 1])
		_count_edge(edge_counts, indices[index + 1], indices[index + 2])
		_count_edge(edge_counts, indices[index + 2], indices[index])
	var boundary_edges := 0
	var interior_edges := 0
	var non_manifold_edges := 0
	for count in edge_counts.values():
		if count == 1:
			boundary_edges += 1
		elif count == 2:
			interior_edges += 1
		else:
			non_manifold_edges += 1
	return {
		"boundary_edges": boundary_edges,
		"interior_edges": interior_edges,
		"non_manifold_edges": non_manifold_edges,
		"is_manifold": non_manifold_edges == 0,
	}


static func _count_edge(edge_counts: Dictionary, a: int, b: int) -> void:
	var edge := Vector2i(mini(a, b), maxi(a, b))
	edge_counts[edge] = int(edge_counts.get(edge, 0)) + 1


static func _add_aligned_regular_cell(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, lookup: Dictionary, direction: Vector2, tangent: Vector2, s0: float, s1: float, v0: float, v1: float) -> void:
	var a := _vertex(vertices, normals, lookup, Vector3(direction.x * s0 + tangent.x * v0, 0.0, direction.y * s0 + tangent.y * v0))
	var b := _vertex(vertices, normals, lookup, Vector3(direction.x * s1 + tangent.x * v0, 0.0, direction.y * s1 + tangent.y * v0))
	var c := _vertex(vertices, normals, lookup, Vector3(direction.x * s1 + tangent.x * v1, 0.0, direction.y * s1 + tangent.y * v1))
	var d := _vertex(vertices, normals, lookup, Vector3(direction.x * s0 + tangent.x * v1, 0.0, direction.y * s0 + tangent.y * v1))
	_add_triangle(vertices, indices, a, c, b)
	_add_triangle(vertices, indices, a, d, c)


static func _add_regular_cell(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, lookup: Dictionary, x_cell: int, z_cell: int, spacing: float) -> void:
	var a := _vertex(vertices, normals, lookup, Vector3(float(x_cell) * spacing, 0.0, float(z_cell) * spacing))
	var b := _vertex(vertices, normals, lookup, Vector3(float(x_cell + 1) * spacing, 0.0, float(z_cell) * spacing))
	var c := _vertex(vertices, normals, lookup, Vector3(float(x_cell + 1) * spacing, 0.0, float(z_cell + 1) * spacing))
	var d := _vertex(vertices, normals, lookup, Vector3(float(x_cell) * spacing, 0.0, float(z_cell + 1) * spacing))
	_add_triangle(vertices, indices, a, c, b)
	_add_triangle(vertices, indices, a, d, c)


static func _add_horizontal_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, lookup: Dictionary, stitch_positions: PackedVector3Array, x_cell: int, inner_z_cell: int, outer_sign: int, spacing: float) -> void:
	var x0 := float(x_cell) * spacing
	var x1 := float(x_cell + 1) * spacing
	var inner_z := float(inner_z_cell) * spacing
	var outer_z := inner_z + float(outer_sign) * spacing
	var a := _vertex(vertices, normals, lookup, Vector3(x0, 0.0, inner_z))
	var middle := _vertex(vertices, normals, lookup, Vector3((x0 + x1) * 0.5, 0.0, inner_z))
	var b := _vertex(vertices, normals, lookup, Vector3(x1, 0.0, inner_z))
	var c := _vertex(vertices, normals, lookup, Vector3(x0, 0.0, outer_z))
	var d := _vertex(vertices, normals, lookup, Vector3(x1, 0.0, outer_z))
	stitch_positions.append_array([vertices[a], vertices[middle], vertices[b]])
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)


static func _add_vertical_stitch(vertices: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array, lookup: Dictionary, stitch_positions: PackedVector3Array, inner_x_cell: int, z_cell: int, outer_sign: int, spacing: float) -> void:
	var z0 := float(z_cell) * spacing
	var z1 := float(z_cell + 1) * spacing
	var inner_x := float(inner_x_cell) * spacing
	var outer_x := inner_x + float(outer_sign) * spacing
	var a := _vertex(vertices, normals, lookup, Vector3(inner_x, 0.0, z0))
	var middle := _vertex(vertices, normals, lookup, Vector3(inner_x, 0.0, (z0 + z1) * 0.5))
	var b := _vertex(vertices, normals, lookup, Vector3(inner_x, 0.0, z1))
	var c := _vertex(vertices, normals, lookup, Vector3(outer_x, 0.0, z0))
	var d := _vertex(vertices, normals, lookup, Vector3(outer_x, 0.0, z1))
	stitch_positions.append_array([vertices[a], vertices[middle], vertices[b]])
	_add_stitch_triangles(vertices, indices, a, middle, b, c, d)


static func _add_stitch_triangles(vertices: PackedVector3Array, indices: PackedInt32Array, a: int, middle: int, b: int, c: int, d: int) -> void:
	_add_triangle(vertices, indices, a, c, middle)
	_add_triangle(vertices, indices, middle, c, d)
	_add_triangle(vertices, indices, middle, d, b)


static func _vertex(vertices: PackedVector3Array, normals: PackedVector3Array, lookup: Dictionary, position: Vector3) -> int:
	var key := Vector2i(roundi(position.x * 1000.0), roundi(position.z * 1000.0))
	if lookup.has(key): return lookup[key]
	var index := vertices.size()
	lookup[key] = index
	vertices.append(position)
	normals.append(Vector3.UP)
	return index


static func _add_triangle(vertices: PackedVector3Array, indices: PackedInt32Array, a: int, b: int, c: int) -> void:
	if (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]).y > 0.0:
		indices.append_array([a, b, c])
	else:
		indices.append_array([a, c, b])
