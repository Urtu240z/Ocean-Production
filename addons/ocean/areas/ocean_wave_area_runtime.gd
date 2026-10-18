@tool
extends RefCounted
## One ordered snapshot shared by rendered waves and CPU water contacts.
const MAX_SHAPES := 8
const MAX_COMPONENTS := 32
const RECORD_BYTES := 1184
const BUFFER_BYTES := 16 + MAX_SHAPES * RECORD_BYTES
var entries: Array[Dictionary] = []
var time_s := 0.0
var sea_level := 0.0
var _overflow_reported := false
var _wave_cache: Dictionary = {}

func synchronize(host: Node3D, time: float) -> void:
	time_s = time
	sea_level = float(host.get("sea_level"))
	entries.clear()
	if not host.is_inside_tree(): return
	var areas := host.get_tree().get_nodes_in_group(&"ocean_wave_areas")
	areas.sort_custom(func(a, b):
		if a.wave_priority != b.wave_priority: return a.wave_priority < b.wave_priority
		return str(a.get_path()) < str(b.get_path()))
	var live_ids: Array[int] = []
	for area in areas:
		if not area.applies_to(host): continue
		live_ids.append(area.get_instance_id())
		var spectrum := _spectrum(area)
		for child in area.get_children():
			if not child is CollisionShape3D or child.disabled or child.shape == null: continue
			var shape := Vector4.ZERO
			if child.shape is BoxShape3D:
				var half: Vector3 = child.shape.size * 0.5
				shape = Vector4(half.x, half.y, half.z, 0.0)
			elif child.shape is SphereShape3D:
				shape = Vector4(child.shape.radius, 0.0, 0.0, 1.0)
			elif child.shape is CylinderShape3D:
				shape = Vector4(child.shape.radius, child.shape.height * 0.5, 0.0, 2.0)
			else: continue
			var frame: Transform3D = child.global_transform
			var scale := minf(frame.basis.x.length(), frame.basis.z.length())
			if scale < 0.0001 or absf(frame.basis.determinant()) < 0.000001: continue
			var scale_x := frame.basis.x.length()
			var scale_z := frame.basis.z.length()
			var yaw := atan2(-frame.basis.x.z, frame.basis.x.x)
			frame = Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(Vector3(scale_x,1,scale_z)), Vector3(frame.origin.x,0,frame.origin.z))
			entries.append({"inverse": frame.affine_inverse(), "shape": shape,
				"blend": Vector4(maxf(area.blend_distance_m, 0.1), scale_x, scale_z, 0),
				"settings": Vector4(maxf(area.wave_height_m, 0), maxf(area.wavelength_m, 0.5), maxf(area.wave_speed, 0), clampf(area.choppiness, 0, 2)),
				"wind": Vector4(deg_to_rad(area.wind_direction_degrees), maxf(area.wind_speed_mps, 0), area.directional_spread, area.phase_seed),
				"meta": spectrum.meta, "groups": spectrum.groups,
				"components0": spectrum.components0, "components1": spectrum.components1,
				"detail_strength": clampf(area.surface_detail_strength,0,1)})
	for id in _wave_cache.keys():
		if id not in live_ids: _wave_cache.erase(id)
	if entries.size() > MAX_SHAPES:
		# Keep the highest-priority shapes, with a stable path tie break.
		entries = entries.slice(entries.size() - MAX_SHAPES)
		if not _overflow_reported:
			push_warning("Ocean wave areas: at most 8 active shapes per Ocean; lower-priority shapes were omitted.")
		_overflow_reported = true
	else:
		_overflow_reported = false

func weight(entry: Dictionary, point: Vector3) -> float:
	var q: Vector3 = entry.inverse * point
	var s: Vector4 = entry.shape
	var distance: float
	if s.w < 0.5:
		var d := (Vector2(absf(q.x),absf(q.z)) - Vector2(s.x,s.z)) * Vector2(entry.blend.y,entry.blend.z)
		distance = Vector2(maxf(d.x,0),maxf(d.y,0)).length() + minf(maxf(d.x,d.y),0)
	else:
		distance = (Vector2(q.x,q.z).length() - s.x) * minf(entry.blend.y,entry.blend.z)
	return (1.0 - smoothstep(0.0, entry.blend.x, distance)) * entry.meta.z

func wave(entry: Dictionary, point: Vector2, time: float) -> Vector4:
	var result := Vector4.ZERO
	for i in int(entry.meta.x):
		var c: Vector4 = entry.components0[i]
		var extra: Vector4 = entry.components1[i]
		var phase := point.dot(Vector2(c.x,c.y)) - time * c.w + extra.x
		var derivative := c.z * (cos(phase) - 2.0 * extra.y * sin(2.0 * phase))
		result.x += c.z * (sin(phase) + extra.y * cos(2.0 * phase))
		result.y += derivative * c.x
		result.z += derivative * c.y
		result.w -= derivative * c.w
	var group: Vector4 = entry.groups
	if group.x > 0.0:
		var phase: float = point.dot(Vector2(group.y,group.z)) - time * group.w + entry.wind.w * 0.723
		var norm := sqrt(1.0 + group.x * group.x * 0.5)
		var envelope := (1.0 + group.x * sin(phase)) / norm
		var derivative := group.x * cos(phase) / norm
		result.y = result.y * envelope + result.x * derivative * group.y
		result.z = result.z * envelope + result.x * derivative * group.z
		result.w = result.w * envelope - result.x * derivative * group.w
		result.x *= envelope
	return result

func _spectrum(area: Node) -> Dictionary:
	var names := ["phase_seed","wave_height_m","wavelength_m","wave_speed","wind_direction_degrees","wind_speed_mps","choppiness","directional_spread","wave_components","wavelength_variation","height_variation","wind_height_influence","cross_sea_amount","cross_sea_angle_degrees","wave_group_strength","wave_group_size_m","wave_group_speed","swell_height_m","swell_wavelength_m","swell_direction_degrees","swell_speed","ripple_height_m","ripple_wavelength_m","ripple_speed","influence","local_foam_strength"]
	var values: Array = []
	for name in names: values.append(area.get(name))
	var signature := hash(values)
	var id := area.get_instance_id()
	if _wave_cache.has(id) and _wave_cache[id].signature == signature: return _wave_cache[id]
	var random := RandomNumberGenerator.new()
	random.seed = area.phase_seed
	var c0 := PackedVector4Array()
	var c1 := PackedVector4Array()
	var height := maxf(area.wave_height_m,0) * lerpf(1.0,clampf(area.wind_speed_mps / 8.0,0,3),clampf(area.wind_height_influence,0,1))
	_append_band(c0,c1,random,height,area.wavelength_m,area.wave_speed,deg_to_rad(area.wind_direction_degrees),area.directional_spread*PI*0.5,area.wavelength_variation,area.height_variation,clampi(area.wave_components,4,24),area.choppiness*0.25,area.wind_speed_mps,area.cross_sea_amount,deg_to_rad(area.cross_sea_angle_degrees))
	_append_band(c0,c1,random,maxf(area.swell_height_m,0),area.swell_wavelength_m,area.swell_speed,deg_to_rad(area.swell_direction_degrees),0.12,0.18,0.3,3,area.choppiness*0.1,0,0,0)
	_append_band(c0,c1,random,maxf(area.ripple_height_m,0),area.ripple_wavelength_m,area.ripple_speed,deg_to_rad(area.wind_direction_degrees),0.8,0.4,0.5,4,0.05,area.wind_speed_mps,0,0)
	var k := TAU / maxf(area.wave_group_size_m,1.0)
	var angle := deg_to_rad(area.wind_direction_degrees) + 0.61
	var group := Vector4(clampf(area.wave_group_strength,0,1),cos(angle)*k,sin(angle)*k,sqrt(9.81*k)*0.25*maxf(area.wave_speed,0)*maxf(area.wave_group_speed,0))
	var bound := 0.0
	for i in c0.size(): bound += absf(c0[i].z) * (1.0 + c1[i].y)
	bound *= (1.0 + group.x) / sqrt(1.0 + group.x*group.x*0.5)
	var result := {"signature":signature,"components0":c0,"components1":c1,"meta":Vector4(c0.size(),maxf(area.local_foam_strength,0),clampf(area.influence,0,1),bound),"groups":group}
	_wave_cache[id] = result
	return result

func _append_band(c0: PackedVector4Array, c1: PackedVector4Array, random: RandomNumberGenerator, height: float, length_m: float, speed: float, angle: float, spread: float, length_variation: float, amplitude_variation: float, count: int, chop: float, wind: float, cross_amount: float, cross_angle: float) -> void:
	if height <= 0.0: return
	var weights := PackedFloat32Array()
	var sum_squared := 0.0
	for i in count:
		var w := random.randf_range(maxf(0.05,1.0-amplitude_variation),1.0+amplitude_variation)
		weights.append(w)
		sum_squared += w*w
	for i in count:
		var direction := angle + random.randf_range(-spread,spread)
		if i % 2 == 1: direction += cross_angle * cross_amount
		var k := TAU / maxf(length_m * exp(random.randf_range(-1,1)*length_variation*1.38629436),0.1)
		var a := height / (2.0 * sqrt(2.0)) * weights[i] / sqrt(sum_squared) / sqrt(1.0+chop*chop)
		c0.append(Vector4(cos(direction)*k,sin(direction)*k,a,(sqrt(9.81*k)+0.03*wind*k)*maxf(speed,0)))
		c1.append(Vector4(random.randf()*TAU,chop,0,0))

func compose(point: Vector2, base: Vector4) -> Vector4:
	var p := Vector3(point.x, sea_level, point.y)
	var value := base
	for entry in entries:
		var w := weight(entry, p)
		if w <= 0.0: continue
		const E := 0.05
		var dw := Vector2(weight(entry, p + Vector3(E,0,0)) - weight(entry, p - Vector3(E,0,0)), weight(entry, p + Vector3(0,0,E)) - weight(entry, p - Vector3(0,0,E))) / (2.0 * E)
		var local := wave(entry, point, time_s)
		value.y = lerpf(value.y, local.y, w) + dw.x * (local.x - value.x)
		value.z = lerpf(value.z, local.z, w) + dw.y * (local.x - value.x)
		value.x = lerpf(value.x, local.x, w)
		value.w = lerpf(value.w, local.w, w)
	return value

func apply(samples: Array, positions: PackedVector3Array, time_rate: float) -> void:
	if entries.is_empty(): return
	for i in mini(samples.size(), positions.size()):
		var sample = samples[i]
		if not sample.valid: continue
		var affected := false
		for entry in entries:
			if weight(entry, Vector3(positions[i].x, sea_level, positions[i].z)) > 0.0:
				affected = true
				break
		if not affected: continue
		var n: Vector3 = sample.normal
		var rate := maxf(absf(time_rate), 0.00001)
		var value := compose(Vector2(positions[i].x, positions[i].z), Vector4(sample.surface_position.y - sea_level, -n.x / maxf(n.y, 0.01), -n.z / maxf(n.y, 0.01), sample.velocity.y / rate))
		sample.surface_position.y = sea_level + value.x
		sample.normal = Vector3(-value.y, 1, -value.z).normalized()
		sample.velocity.y = value.w * time_rate
		sample.signed_depth = sample.surface_position.y - positions[i].y

func shader_parameters() -> Dictionary:
	var parameters := {&"wave_area_count": entries.size(), &"wave_area_time": time_s, &"wave_area_sea_level": sea_level}
	var detail := PackedFloat32Array()
	for i in MAX_SHAPES: detail.append(entries[i].detail_strength if i < entries.size() else 1.0)
	parameters[&"wave_area_detail_strength"] = detail
	for key in ["inverse", "shape", "blend", "settings", "wind", "meta", "groups"]:
		var values: Array = []
		for entry in entries: values.append(Projection(entry[key]) if key == "inverse" else entry[key])
		while values.size() < MAX_SHAPES: values.append(Projection.IDENTITY if key == "inverse" else Vector4.ZERO)
		parameters[StringName("wave_area_" + key)] = values if key == "inverse" else PackedVector4Array(values)
	for key in ["components0", "components1"]:
		var values := PackedVector4Array()
		for i in MAX_SHAPES:
			for j in MAX_COMPONENTS:
				values.append(entries[i][key][j] if i < entries.size() and j < entries[i][key].size() else Vector4.ZERO)
		parameters[StringName("wave_area_" + key)] = values
	return parameters

func pack_gpu() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(16)
	bytes.encode_float(0, entries.size())
	bytes.encode_float(4, time_s)
	bytes.encode_float(8, sea_level)
	for i in entries.size():
		var entry := entries[i]
		var matrix := Projection(entry.inverse)
		var values := PackedFloat32Array()
		for column in [matrix.x, matrix.y, matrix.z, matrix.w, entry.shape, entry.blend, entry.settings, entry.wind, entry.meta, entry.groups]:
			values.append_array(PackedFloat32Array([column.x, column.y, column.z, column.w]))
		for key in ["components0", "components1"]:
			for j in MAX_COMPONENTS:
				var component: Vector4 = entry[key][j] if j < entry[key].size() else Vector4.ZERO
				values.append_array(PackedFloat32Array([component.x,component.y,component.z,component.w]))
		var row := values.to_byte_array()
		bytes.append_array(row)
	bytes.resize(BUFFER_BYTES)
	return bytes
