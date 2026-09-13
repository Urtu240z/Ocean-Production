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
