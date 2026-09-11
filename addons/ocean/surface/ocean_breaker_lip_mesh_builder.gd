class_name OceanBreakerLipMeshBuilder
extends RefCounted
## Construye una malla única de patchlets ribbon para el lip P7.

static func build(cells_per_side: int, base_spacing_m: float) -> ArrayMesh:
	var near_half_extent_m := float(cells_per_side) * base_spacing_m * 0.5
	var seed_stride_m := maxf(base_spacing_m * 4.0, 0.75)
	var seed_count := maxi(ceili((near_half_extent_m * 2.0) / seed_stride_m), 1)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var row_count := 6
	for z_index in seed_count:
		var seed_z := -near_half_extent_m + (float(z_index) + 0.5) * seed_stride_m
		for x_index in seed_count:
			var seed_x := -near_half_extent_m + (float(x_index) + 0.5) * seed_stride_m
			var segment_base := vertices.size()
			for row in row_count:
				var u := float(row) / float(row_count - 1)
				for side in [-1.0, 1.0]:
					vertices.append(Vector3(seed_x, 0.0, seed_z))
					normals.append(Vector3.UP)
					uvs.append(Vector2(side, u))
			for row in row_count - 1:
				var row_base := segment_base + row * 2
				var next_row_base := row_base + 2
				indices.append_array([row_base, next_row_base, row_base + 1])
				indices.append_array([row_base + 1, next_row_base, next_row_base + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
