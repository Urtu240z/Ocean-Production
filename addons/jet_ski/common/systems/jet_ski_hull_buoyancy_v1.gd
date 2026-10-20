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
var perf2_sink: Object

var geometry_generation := 0
var native_batch_count := 0
var native_geometry_uploads := 0
var native_failure_reason := ""
var _native_geometry: Object
var _native_generation := -1
var _native_profile_active := false
var _native_surfaces := PackedVector3Array()
var _native_normals := PackedVector3Array()
var _native_valid := PackedByteArray()
var _native_values := PackedFloat64Array()


func configure(collision: CollisionShape3D) -> bool:
	geometry_generation += 1
	_native_generation = -1
	_native_geometry = null
	_native_profile_active = false
	_native_values.clear()
	_native_surfaces.clear()
	_native_normals.clear()
	_native_valid.clear()
	native_failure_reason = ""
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
				"contact": side + (0 if station < STATION_COUNT * 0.5 else 2)})
			total_volume_m3 += volume_moment.w
	return local_points.size() == SAMPLE_COUNT and prepare_native_geometry()


func prepare_native_geometry() -> bool:
	if _native_generation == geometry_generation and _native_geometry != null: return true
	if local_points.size() != SAMPLE_COUNT or cells.size() != SAMPLE_COUNT:
		_native_error("Hull geometry unavailable")
		return false
	if not ClassDB.class_exists("HullBuoyancyGeometryNative"):
		_native_error("HullBuoyancyGeometryNative unavailable; install the matching Ocean GDExtension")
		return false
	var vertices := PackedVector3Array()
	var offsets := PackedInt32Array([0])
	for cell in cells:
		vertices.append_array(cell.tetrahedra)
		offsets.append(vertices.size())
	_native_geometry = _create_native_geometry()
	if _native_geometry == null:
		_native_error("HullBuoyancyGeometryNative could not be instantiated")
		return false
	if not _native_geometry.configure_geometry(vertices,offsets,local_points):
		_native_error("Native hull geometry configuration rejected")
		_native_geometry = null
		return false
	_native_generation = geometry_generation
	_native_surfaces.resize(SAMPLE_COUNT)
	_native_normals.resize(SAMPLE_COUNT)
	_native_valid.resize(SAMPLE_COUNT)
	native_geometry_uploads += 1
	native_failure_reason = ""
	return true


func integrate_native_batch(transform: Transform3D, samples: Array[WaterSample3D], draft_offset_m: float) -> bool:
	var started := Time.get_ticks_usec() if perf2_sink != null else 0
	if not is_native_ready() or samples.size() != SAMPLE_COUNT:
		_native_error("Native hull batch has no configured geometry or twelve samples")
		return false
	for i in SAMPLE_COUNT:
		var sample := samples[i]
		var valid := sample.valid and sample.normal.is_finite() and sample.velocity.is_finite() \
			and sample.surface_position.is_finite() and sample.normal.length_squared() >= 0.000001
		_native_valid[i] = int(valid)
		_native_surfaces[i] = sample.surface_position
		var normal := sample.normal.normalized() if valid else Vector3.UP
		if normal.y < 0.0: normal = -normal
		_native_normals[i] = normal
	var profiling := perf2_sink != null
	if profiling != _native_profile_active:
		_native_geometry.set_profiling_enabled(profiling)
		_native_profile_active = profiling
	_native_values = _native_geometry.integrate_cells(transform,_native_surfaces,_native_normals,_native_valid,draft_offset_m)
	var ready := _native_values.size() == SAMPLE_COUNT*10
	if ready:
		for i in SAMPLE_COUNT:
			if _native_valid[i] != 0 and _native_values[i*10] != 1.0: ready = false
	if ready:
		native_batch_count += 1
		native_failure_reason = ""
	else:
		_native_error("Native hull integration returned an invalid batch; simulation suspended")
		_native_values.clear()
		_native_generation = -1
	if perf2_sink != null:
		perf2_sink.call("perf2_record_span",3,Engine.get_process_frames(),Engine.get_physics_frames(),started,Time.get_ticks_usec(),1)
	return ready


func native_cell_result(index: int) -> Dictionary:
	var started := Time.get_ticks_usec() if perf2_sink != null else 0
	var offset := index*10
	var result := {"volume":_native_values[offset+1],
		"center":Vector3(_native_values[offset+2],_native_values[offset+3],_native_values[offset+4]),
		"depth":_native_values[offset+5]}
	if perf2_sink != null:
		perf2_sink.call("perf2_record_span",3,Engine.get_process_frames(),Engine.get_physics_frames(),started,Time.get_ticks_usec(),1)
	return result


func native_geometry_profile() -> PackedInt64Array:
	return _native_geometry.get_last_profile() if _native_geometry != null else PackedInt64Array()


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


func _create_native_geometry() -> Object:
	return ClassDB.instantiate("HullBuoyancyGeometryNative")

func is_native_ready() -> bool:
	return _native_geometry != null and _native_generation == geometry_generation

func _native_error(reason: String) -> void:
	if native_failure_reason != reason: push_error("HULL_BUOYANCY_V1: "+reason)
	native_failure_reason = reason
