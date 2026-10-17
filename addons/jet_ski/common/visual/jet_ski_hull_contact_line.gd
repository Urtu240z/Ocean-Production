extends MeshInstance3D
## Visual intersection of the existing convex hull and four cached V1 water planes.
## No Ocean queries. The mesh is two open side strips, never a closed crown.
const STATIONS := 16
const BREAKUP = preload("res://addons/ocean/surface/crest_breakup_noise.tres")
const CONTACT_SHADER = preload("res://addons/jet_ski/common/visual/hull_contact_line.gdshader")
var _ski: JetSkiController
var _physics: JetSkiWaterPhysicsSystem
var _sections: Array[PackedVector2Array] = []
var _station_z := PackedFloat32Array()
var _mesh := ArrayMesh.new()
var _vertices := PackedVector3Array()
var _material: ShaderMaterial
var visible_segments := 0

func configure(ski: JetSkiController) -> void:
	_ski = ski
	_physics = ski.water_physics_system
	mesh = _mesh
	top_level = true
	global_transform = Transform3D.IDENTITY
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = CONTACT_SHADER
	material.set_shader_parameter("breakup_texture", BREAKUP)
	material_override = material
	_material = material
	var shapes := ski.find_children("*", "CollisionShape3D", true, false)
	if shapes.is_empty(): return
	var collision := shapes[0] as CollisionShape3D
	if not collision.shape is ConvexPolygonShape3D: return
	var hull := PackedVector3Array()
	var z_min := INF
	var z_max := -INF
	for vertex in (collision.shape as ConvexPolygonShape3D).points:
		var p: Vector3 = ski.global_transform.affine_inverse() * collision.global_transform * vertex
		hull.append(p)
		z_min = minf(z_min, p.z)
		z_max = maxf(z_max, p.z)
	for station in STATIONS + 1:
		var z := lerpf(z_min + 0.02, z_max - 0.02, float(station) / STATIONS)
		_station_z.append(z)
		_sections.append(_physics.hull_buoyancy._cross_section(hull, z))
	# Allocate one fixed surface. Updating its vertex buffer avoids rebuilding
	# render surfaces and their deferred allocations for every vehicle/frame.
	_vertices.resize(STATIONS * 2 * 6)
	var normals := PackedVector3Array()
	normals.resize(_vertices.size())
	normals.fill(Vector3.UP)
	var uvs := PackedVector2Array()
	uvs.resize(_vertices.size())
	for i in _vertices.size():
		uvs[i] = Vector2(0.0, 1.0 if i % 6 in [1, 2, 4] else 0.0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE)

func update_contact() -> void:
	visible_segments = 0
	visible = not _physics.contact_is_airborne
	if not visible or _sections.is_empty(): return
	var pose := _ski.get_global_transform_interpolated()
	_vertices.fill(pose.origin)
	custom_aabb = AABB(pose.origin - Vector3.ONE * 4.0, Vector3.ONE * 8.0)
	var relative := _physics.point_relative_velocities[0]
	_material.set_shader_parameter("activity", clampf(relative.length() / 14.0, 0.0, 1.0))
	for side in 2:
		var previous := {}
		for station in _sections.size():
			var current := _intersection(station, side, pose)
			if not previous.is_empty() and not current.is_empty():
				var base := (side * STATIONS + station - 1) * 6
				var a: Vector3 = previous.position - previous.outward * previous.width * 0.3
				var b: Vector3 = previous.position + previous.outward * previous.width * 0.7
				var c: Vector3 = current.position + current.outward * current.width * 0.7
				var d: Vector3 = current.position - current.outward * current.width * 0.3
				_vertices[base] = a
				_vertices[base + 1] = b
				_vertices[base + 2] = c
				_vertices[base + 3] = a
				_vertices[base + 4] = c
				_vertices[base + 5] = d
				visible_segments += 1
			previous = current
	_mesh.surface_update_vertex_region(0, 0, _vertices.to_byte_array())
	visible = visible_segments > 0

func _intersection(station: int, side: int, pose: Transform3D) -> Dictionary:
	var front := side
	var rear := side + 2
	if not _physics.point_sample_valid[front] or not _physics.point_sample_valid[rear]: return {}
	var z := _station_z[station]
	var local_front: Vector3 = pose.affine_inverse() * _physics.point_water_surface_positions[front]
	var local_rear: Vector3 = pose.affine_inverse() * _physics.point_water_surface_positions[rear]
	var t := clampf((z - local_front.z) / maxf(local_rear.z - local_front.z, 0.1), 0.0, 1.0)
	var normal := _physics.point_water_normals[front].lerp(_physics.point_water_normals[rear], t).normalized()
	if normal.y < 0.25: return {}
	var polygon := _sections[station]
	var best := Vector3.ZERO
	var best_x := -INF
	for i in polygon.size():
		var a := pose * Vector3(polygon[i].x, polygon[i].y, z)
		var b := pose * Vector3(polygon[(i + 1) % polygon.size()].x, polygon[(i + 1) % polygon.size()].y, z)
		var da := a.y - _water_height(a, front, rear, t)
		var db := b.y - _water_height(b, front, rear, t)
		if da * db > 0.0 or absf(da - db) < 0.00001: continue
		var point := a.lerp(b, clampf(da / (da - db), 0.0, 1.0))
		var local_point: Vector3 = pose.affine_inverse() * point
		var signed_x := local_point.x * (-1.0 if side == 0 else 1.0)
		if signed_x > best_x:
			best_x = signed_x
			best = point
	if best_x < 0.01: return {}
	var depth := lerpf(_physics.point_depths[front], _physics.point_depths[rear], t)
	var wet := smoothstep(0.0, 0.055, depth)
	if wet <= 0.001: return {}
	var velocity := _physics.point_relative_velocities[front].lerp(_physics.point_relative_velocities[rear], t)
	var activity := clampf((Vector2(velocity.x, velocity.z).length() + absf(velocity.dot(normal)) * 2.0) / 14.0, 0.0, 1.0)
	var outward := pose.basis.x * (-1.0 if side == 0 else 1.0)
	outward = (outward - normal * outward.dot(normal)).normalized()
	return {"position": best + normal * 0.009, "normal": normal, "outward": outward,
		"wet": wet, "speed": activity, "width": lerpf(0.055, 0.12, activity) * wet, "along": z}

func _water_height(point: Vector3, front: int, rear: int, t: float) -> float:
	var heights := Vector2.ZERO
	for i in 2:
		var index := front if i == 0 else rear
		var sample := _physics.point_water_surface_positions[index]
		var normal := _physics.point_water_normals[index]
		heights[i] = sample.y - (normal.x * (point.x - sample.x) + normal.z * (point.z - sample.z)) / maxf(normal.y, 0.25)
	return lerpf(heights.x, heights.y, t)
