class_name OceanBreakerWavefrontLipMeshBuilder
extends RefCounted
## Builds one connected controlled-wavefront ribbon for the P7 lip prototype.

const COLUMNS := 96
const ROWS := 8
const WIDTH_M := 32.0

static func build() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	vertices.resize(COLUMNS * ROWS)
	normals.resize(COLUMNS * ROWS)
	uvs.resize(COLUMNS * ROWS)
	for row in ROWS:
		var v := float(row) / float(ROWS - 1)
		for column in COLUMNS:
			var u := float(column) / float(COLUMNS - 1)
			var vertex_index := row * COLUMNS + column
			vertices[vertex_index] = Vector3((u * 2.0 - 1.0) * WIDTH_M * 0.5, 0.0, 0.0)
			normals[vertex_index] = Vector3.UP
			uvs[vertex_index] = Vector2(u * 2.0 - 1.0, v)
	for row in ROWS - 1:
		for column in COLUMNS - 1:
			var row_base := row * COLUMNS + column
			var next_row_base := row_base + COLUMNS
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
