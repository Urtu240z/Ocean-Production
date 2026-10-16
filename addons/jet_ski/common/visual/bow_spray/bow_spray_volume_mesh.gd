extends RefCounted
## Shared grid ribbons; UV2 carries layer position/phase for GPU deformation.

const LONG_STEPS := 32
const CROSS_STEPS := 12


static func build(layer_count: int) -> ArrayMesh:
	var count := clampi(layer_count, 1, 5)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var indices := PackedInt32Array()
	for layer in count:
		var layer_fraction := float(layer) / float(count - 1) if count > 1 else 0.5
		var layer_offset := layer_fraction * 2.0 - 1.0
		var base := vertices.size()
		for u_index in LONG_STEPS + 1:
			for v_index in CROSS_STEPS + 1:
				var u := float(u_index) / float(LONG_STEPS)
				var v := float(v_index) / float(CROSS_STEPS)
				vertices.append(Vector3(u, 0.0, v))
				normals.append(Vector3.UP)
				uv.append(Vector2(u, v))
				uv2.append(Vector2(layer_offset, layer_fraction))
		for u_index in LONG_STEPS:
			for v_index in CROSS_STEPS:
				var a := base + u_index * (CROSS_STEPS + 1) + v_index
				var b := a + 1
				var c := a + CROSS_STEPS + 1
				var d := c + 1
				indices.append_array(PackedInt32Array([a, b, c, b, d, c]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
