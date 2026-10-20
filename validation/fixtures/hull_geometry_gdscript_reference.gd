extends "res://addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd"
## Validation only: frozen GDScript dynamic integration from PERF-HULL-NATIVE-1.

func integrate_cell(index: int, transform: Transform3D, sample: WaterSample3D,
		draft_offset_m: float) -> Dictionary:
	var perf2_started := Time.get_ticks_usec() if perf2_sink != null else 0
	var normal := sample.normal.normalized()
	var local_normal := transform.basis.transposed() * normal
	var local_surface := transform.affine_inverse() * sample.surface_position
	var raw_plane_d := local_normal.dot(local_surface)
	var support_plane_d := raw_plane_d - normal.y * draft_offset_m
	var tetrahedra: PackedVector3Array = cells[index].tetrahedra
	var moment := Vector4.ZERO
	var maximum_depth := -INF
	for vertex in tetrahedra:
		maximum_depth = maxf(maximum_depth,
			(raw_plane_d - local_normal.dot(vertex)) / maxf(normal.y, 0.05))
	var perf2_tetra_started := Time.get_ticks_usec() if perf2_sink != null else 0
	for offset in range(0, tetrahedra.size(), 4):
		moment += _submerged_tetra(tetrahedra[offset], tetrahedra[offset + 1],
			tetrahedra[offset + 2], tetrahedra[offset + 3], local_normal, support_plane_d)
	var perf2_tetra_ended := Time.get_ticks_usec() if perf2_sink != null else 0
	var center := local_points[index]
	if moment.w > VOLUME_EPSILON:
		center = Vector3(moment.x, moment.y, moment.z) / moment.w
	var result := {"volume": moment.w, "center": transform * center, "depth": maximum_depth}
	if perf2_sink != null:
		var ended := Time.get_ticks_usec()
		perf2_sink.call("perf2_record_span", 3, Engine.get_process_frames(), Engine.get_physics_frames(),
			perf2_started, ended, 1)
		perf2_sink.call("perf2_record_span", 4, Engine.get_process_frames(), Engine.get_physics_frames(),
			perf2_tetra_started, perf2_tetra_ended, tetrahedra.size() / 4)
	return result

func _plane_intersection(a: Vector3, b: Vector3, normal: Vector3, plane_d: float) -> Vector3:
	var depth_a := plane_d - normal.dot(a)
	var depth_b := plane_d - normal.dot(b)
	return a.lerp(b, depth_a / (depth_a - depth_b))

func _submerged_tetra(a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		normal: Vector3, plane_d: float) -> Vector4:
	var wet := PackedVector3Array()
	var dry := PackedVector3Array()
	for vertex in [a, b, c, d]:
		if normal.dot(vertex) <= plane_d:
			wet.append(vertex)
		else:
			dry.append(vertex)
	match wet.size():
		0:
			return Vector4.ZERO
		4:
			return _tetra_moment(a, b, c, d)
		1:
			return _tetra_moment(wet[0], _plane_intersection(wet[0], dry[0], normal, plane_d),
				_plane_intersection(wet[0], dry[1], normal, plane_d),
				_plane_intersection(wet[0], dry[2], normal, plane_d))
		3:
			return _tetra_moment(a, b, c, d) - _tetra_moment(dry[0],
				_plane_intersection(dry[0], wet[0], normal, plane_d),
				_plane_intersection(dry[0], wet[1], normal, plane_d),
				_plane_intersection(dry[0], wet[2], normal, plane_d))
		2:
			var p := _plane_intersection(wet[0], dry[0], normal, plane_d)
			var q := _plane_intersection(wet[0], dry[1], normal, plane_d)
			var r := _plane_intersection(wet[1], dry[0], normal, plane_d)
			var s := _plane_intersection(wet[1], dry[1], normal, plane_d)
			return _tetra_moment(wet[0], p, q, wet[1]) + _tetra_moment(p, q, wet[1], r) \
				+ _tetra_moment(q, wet[1], r, s)
	return Vector4.ZERO
