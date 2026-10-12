extends RefCounted
## Twelve finite-volume cells: six longitudinal sections, split port/starboard.
## Sections come from the existing convex collision hull, in body coordinates.
## Each midpoint section is extruded over its station interval (a volume quadrature).
## Tetrahedral clipping integrates volume and its first moment even when inverted.

const STATION_COUNT := 6
const SAMPLE_COUNT := STATION_COUNT * 2
const WATER_DENSITY_KG_M3 := 1000.0
const VOLUME_EPSILON := 0.000000001

var local_points := PackedVector3Array()
var cells: Array[Dictionary] = []
var total_volume_m3 := 0.0
var submerged_volume_m3 := 0.0
var wet_sample_count := 0


func configure(collision: CollisionShape3D) -> bool:
	local_points.clear()
	cells.clear()
	total_volume_m3 = 0.0
	if collision == null or not collision.shape is ConvexPolygonShape3D:
		return false
	var hull := PackedVector3Array()
	var z_min := INF
	var z_max := -INF
	for vertex in (collision.shape as ConvexPolygonShape3D).points:
		var point: Vector3 = collision.transform * vertex
		hull.append(point)
		z_min = minf(z_min, point.z)
		z_max = maxf(z_max, point.z)
	if hull.size() < 4 or z_max - z_min < 0.001:
		return false
	var station_length := (z_max - z_min) / float(STATION_COUNT)
	for station in STATION_COUNT:
		var z := z_min + (float(station) + 0.5) * station_length
		var section := _cross_section(hull, z)
		for side in 2:
			var polygon := _half_section(section, side == 0)
			if polygon.size() < 3:
				cells.clear()
				local_points.clear()
				return false
			var tetrahedra := PackedVector3Array()
			var volume_moment := Vector4.ZERO
			var x_min := INF
			var x_max := -INF
			for vertex in polygon:
				x_min = minf(x_min, vertex.x)
				x_max = maxf(x_max, vertex.x)
			for triangle in range(1, polygon.size() - 1):
				var a := Vector3(polygon[0].x, polygon[0].y, z - station_length * 0.5)
				var b := Vector3(polygon[triangle].x, polygon[triangle].y, a.z)
				var c := Vector3(polygon[triangle + 1].x, polygon[triangle + 1].y, a.z)
				var offset := Vector3(0.0, 0.0, station_length)
				var vertices := PackedVector3Array([a, b, c, a + offset,
					b, c, a + offset, b + offset, c, a + offset, b + offset, c + offset])
				tetrahedra.append_array(vertices)
				for index in range(0, vertices.size(), 4):
					volume_moment += _tetra_moment(vertices[index], vertices[index + 1],
						vertices[index + 2], vertices[index + 3])
			if volume_moment.w <= VOLUME_EPSILON:
				return false
			var center := Vector3(volume_moment.x, volume_moment.y, volume_moment.z) / volume_moment.w
			local_points.append(center)
			cells.append({"tetrahedra": tetrahedra, "volume": volume_moment.w,
				"waterplane_area": (x_max - x_min) * station_length,
				"contact": side + (0 if station < STATION_COUNT / 2 else 2)})
			total_volume_m3 += volume_moment.w
	return local_points.size() == SAMPLE_COUNT


func integrate_cell(index: int, transform: Transform3D, sample: WaterSample3D,
		draft_offset_m: float) -> Dictionary:
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
	for offset in range(0, tetrahedra.size(), 4):
		moment += _submerged_tetra(tetrahedra[offset], tetrahedra[offset + 1],
			tetrahedra[offset + 2], tetrahedra[offset + 3], local_normal, support_plane_d)
	var center := local_points[index]
	if moment.w > VOLUME_EPSILON:
		center = Vector3(moment.x, moment.y, moment.z) / moment.w
	return {"volume": moment.w, "center": transform * center, "depth": maximum_depth}


func _cross_section(hull: PackedVector3Array, z: float) -> PackedVector2Array:
	# All vertex-pair intersections include all edge intersections. Their convex
	# hull therefore gives the exact slice of the convex collision shape.
	var intersections := PackedVector2Array()
	for a_index in hull.size():
		var a := hull[a_index]
		for b_index in range(a_index + 1, hull.size()):
			var b := hull[b_index]
			if absf(b.z - a.z) < 0.000001 or z < minf(a.z, b.z) or z > maxf(a.z, b.z):
				continue
			var point := a.lerp(b, (z - a.z) / (b.z - a.z))
			intersections.append(Vector2(point.x, point.y))
	var polygon := Geometry2D.convex_hull(intersections)
	if polygon.size() > 1 and polygon[0].is_equal_approx(polygon[-1]):
		polygon.resize(polygon.size() - 1)
	return polygon


func _half_section(polygon: PackedVector2Array, left: bool) -> PackedVector2Array:
	var result := PackedVector2Array()
	for index in polygon.size():
		var a := polygon[index]
		var b := polygon[(index + 1) % polygon.size()]
		var inside_a := a.x <= 0.0 if left else a.x >= 0.0
		var inside_b := b.x <= 0.0 if left else b.x >= 0.0
		if inside_a and (result.is_empty() or not result[-1].is_equal_approx(a)):
			result.append(a)
		if inside_a != inside_b:
			var intersection := a.lerp(b, -a.x / (b.x - a.x))
			if result.is_empty() or not result[-1].is_equal_approx(intersection):
				result.append(intersection)
	if result.size() > 1 and result[0].is_equal_approx(result[-1]):
		result.resize(result.size() - 1)
	return result


func _tetra_moment(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> Vector4:
	var volume := absf((b - a).dot((c - a).cross(d - a))) / 6.0
	var first_moment := (a + b + c + d) * (volume * 0.25)
	return Vector4(first_moment.x, first_moment.y, first_moment.z, volume)


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
