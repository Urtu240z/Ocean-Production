@tool
extends RefCounted
## Two shared production FFT states; ordered footprints select/mix them.
const LocalFFT = preload("res://addons/ocean/areas/ocean_local_fft_state.gd")
const MAX_SHAPES := 8
const RECORD_BYTES := 128
const BUFFER_BYTES := 16+MAX_SHAPES*RECORD_BYTES+64+48
const TsunamiState := preload("res://addons/ocean/events/ocean_tsunami_state.gd")
var tsunami: RefCounted = TsunamiState.new()
var entries: Array[Dictionary] = []
var states: Array = [null,null]
var time_s := 0.0
var sea_level := 0.0
var displaced := false
var _overflow_reported := false
var _clock_tick := -1
var _clock := 0.0
var profiling_enabled := false
var metrics := preload("res://addons/ocean/areas/ocean_wave_area_metrics.gd").new()
var _measured_affected := Vector2i.ZERO

func synchronize(host: Node3D, time: float) -> void:
	var start := Time.get_ticks_usec() if metrics.enabled else 0
	_synchronize(host, time)
	if metrics.enabled: metrics.record(&"synchronize", Time.get_ticks_usec()-start)

func _synchronize(host: Node3D, time: float) -> void:
	if Engine.is_editor_hint(): _clock = time
	elif _clock_tick != Engine.get_physics_frames():
		if _clock_tick >= 0: _clock += float(Engine.get_physics_frames()-_clock_tick)/Engine.physics_ticks_per_second
		_clock_tick = Engine.get_physics_frames()
	time_s = _clock
	sea_level = float(host.get("sea_level"))
	tsunami=host.get_boundary_tsunami_state()
	displaced = int(host.get("visual_water_profile")) == 0
	entries.clear()
	if not host.is_inside_tree(): return
	var areas := host.get_tree().get_nodes_in_group(&"ocean_wave_areas")
	areas.sort_custom(func(a,b):
		if a.wave_priority != b.wave_priority: return a.wave_priority < b.wave_priority
		return str(a.get_path()) < str(b.get_path()))
	var used := [false,false]
	for area in areas:
		if not area.applies_to(host): continue
		if area.influence <= 0.0: continue
		var slot := clampi(area.sea_state,0,1)
		for child in area.get_children():
			if not child is CollisionShape3D or child.disabled or child.shape == null: continue
			var shape := Vector4.ZERO
			if child.shape is BoxShape3D:
				var half: Vector3 = child.shape.size*0.5
				shape = Vector4(half.x,half.y,half.z,0)
			elif child.shape is SphereShape3D: shape = Vector4(child.shape.radius,0,0,1)
			elif child.shape is CylinderShape3D: shape = Vector4(child.shape.radius,child.shape.height*0.5,0,2)
			else: continue
			var frame: Transform3D = child.global_transform
			var sx := frame.basis.x.length()
			var sz := frame.basis.z.length()
			if minf(sx,sz) < 0.0001 or absf(frame.basis.determinant()) < 0.000001: continue
			var yaw := atan2(-frame.basis.x.z,frame.basis.x.x)
			frame = Transform3D(Basis(Vector3.UP,yaw)*Basis.from_scale(Vector3(sx,1,sz)),Vector3(frame.origin.x,0,frame.origin.z))
			entries.append({"inverse":frame.affine_inverse(),"shape":shape,
				"blend":Vector4(maxf(area.blend_distance_m,0.1),sx,sz,0),
				"meta":Vector4(slot,1,clampf(area.influence,0,1),0),"detail_strength":area.surface_detail_strength})
	if entries.size() > MAX_SHAPES:
		entries = entries.slice(entries.size()-MAX_SHAPES)
		if not _overflow_reported: push_warning("Ocean: at most 8 active wave-area shapes; lower priorities omitted.")
		_overflow_reported = true
	else: _overflow_reported = false
	for entry in entries: used[int(entry.meta.x)] = true
	for slot in 2:
		if not used[slot] or not host.get("enabled") or not host.get("open_ocean_fft"):
			if states[slot] != null: states[slot].shutdown()
			states[slot] = null
			continue
		var settings: Resource = host.get("local_sea_state_1" if slot == 0 else "local_sea_state_2")
		if settings == null: continue
		if states[slot] == null: states[slot] = LocalFFT.new()
		states[slot].metrics = metrics
		states[slot].metric_slot = slot
		states[slot].profile_gpu = profiling_enabled
		states[slot].configure(settings,host,slot)
		states[slot].advance(_clock)
	for entry in entries:
		var state: RefCounted = states[int(entry.meta.x)]
		if state == null or not state.ready: entry.meta.z = 0.0
		elif not state.spectrum.is_empty(): entry.meta.w = state.spectrum.bounds.y*state.settings.ocean_scale*3.0

func weight(entry: Dictionary, point: Vector3) -> float:
	var q: Vector3 = entry.inverse*point
	var s: Vector4 = entry.shape
	var distance: float
	if s.w < 0.5:
		var d := (Vector2(absf(q.x),absf(q.z))-Vector2(s.x,s.z))*Vector2(entry.blend.y,entry.blend.z)
		distance = Vector2(maxf(d.x,0),maxf(d.y,0)).length()+minf(maxf(d.x,d.y),0)
	else: distance = (Vector2(q.x,q.z).length()-s.x)*minf(entry.blend.y,entry.blend.z)
	return (1.0-smoothstep(0.0,entry.blend.x,distance))*entry.meta.z

func wave(entry: Dictionary, point: Vector2, time: float) -> Vector4:
	var state: RefCounted = states[int(entry.meta.x)]
	if state == null: return Vector4.ZERO
	var samples: PackedVector4Array = state.sample(PackedVector3Array([Vector3(point.x,0,point.y)]),time,displaced)
	return samples[0] if samples.size() == 1 else Vector4.ZERO

func weight_gradient(entry: Dictionary,p: Vector3) -> Vector2:
	const E := 0.1
	return Vector2(weight(entry,p+Vector3(E,0,0))-weight(entry,p-Vector3(E,0,0)),weight(entry,p+Vector3(0,0,E))-weight(entry,p-Vector3(0,0,E)))/(2*E)

func compose(point: Vector2, base: Vector4) -> Vector4:
	var value := base
	var p := Vector3(point.x,sea_level,point.y)
	for entry in entries:
		var w := weight(entry,p)
		if w <= 0.0: continue
		var local := wave(entry,point,time_s)
		var dw := weight_gradient(entry,p)
		value.y = lerpf(value.y,local.y,w)+dw.x*(local.x-value.x)
		value.z = lerpf(value.z,local.z,w)+dw.y*(local.x-value.x)
		value.x = lerpf(value.x,local.x,w)
		value.w = lerpf(value.w,local.w,w)
	return value

func apply(samples: Array, positions: PackedVector3Array, _time_rate: float) -> void:
	var start := Time.get_ticks_usec() if metrics.enabled else 0
	_apply(samples, positions, _time_rate)
	if metrics.enabled:
		metrics.record(&"apply", Time.get_ticks_usec()-start)
		metrics.record(&"input_contacts", 0, positions.size())
		metrics.record(&"slot0.affected", 0, _measured_affected.x)
		metrics.record(&"slot1.affected", 0, _measured_affected.y)

func _apply(samples: Array, positions: PackedVector3Array, _time_rate: float) -> void:
	_measured_affected = Vector2i.ZERO
	# Query each shared native field once per contact batch, not once per area.
	var local_values: Array = [PackedVector4Array(),PackedVector4Array()]
	for slot in 2:
		if states[slot] == null: continue
		var affected := false
		for entry in entries:
			if int(entry.meta.x) != slot: continue
			for p in positions:
				if weight(entry,p) > 0.0: affected = true; break
			if affected: break
		if affected: local_values[slot] = states[slot].sample(positions,time_s,displaced)
	for i in mini(samples.size(),positions.size()):
		var sample = samples[i]
		if not sample.valid: continue
		var measured_slots := 0
		var n: Vector3 = sample.normal
		var value := Vector4(sample.surface_position.y-sea_level,-n.x/maxf(n.y,0.01),-n.z/maxf(n.y,0.01),sample.velocity.y)
		for entry in entries:
			var w := weight(entry,positions[i])
			var slot := int(entry.meta.x)
			if w <= 0.0 or local_values[slot].size() != positions.size(): continue
			if metrics.enabled and (measured_slots & (1 << slot)) == 0:
				_measured_affected[slot] += 1
				measured_slots |= 1 << slot
			var local: Vector4 = local_values[slot][i]
			var dw := weight_gradient(entry,positions[i])
			value.y = lerpf(value.y,local.y,w)+dw.x*(local.x-value.x)
			value.z = lerpf(value.z,local.z,w)+dw.y*(local.x-value.x)
			value.x = lerpf(value.x,local.x,w)
			value.w = lerpf(value.w,local.w,w)
		sample.surface_position.y = sea_level+value.x
		sample.normal = Vector3(-value.y,1,-value.z).normalized()
		sample.velocity.y = value.w
		sample.signed_depth = sample.surface_position.y-positions[i].y

func shader_parameters() -> Dictionary:
	var parameters := {&"wave_area_count":entries.size(),&"wave_area_sea_level":sea_level,&"wave_area_displaced":displaced}
	parameters.merge(tsunami.shader_parameters())
	var detail := PackedFloat32Array()
	for i in MAX_SHAPES: detail.append(entries[i].detail_strength if i < entries.size() else 1.0)
	parameters[&"wave_area_detail_strength"] = detail
	for key in ["inverse","shape","blend","meta"]:
		var values: Array = []
		for entry in entries: values.append(Projection(entry[key]) if key == "inverse" else entry[key])
		while values.size() < MAX_SHAPES: values.append(Projection.IDENTITY if key == "inverse" else Vector4.ZERO)
		parameters[StringName("wave_area_"+key)] = values if key == "inverse" else PackedVector4Array(values)
	for slot in 2:
		var state: RefCounted = states[slot]
		var valid: bool = state != null and state.ready
		parameters[StringName("local_fft_space_%d"%slot)] = Vector4(state.settings.clipmap_geometry_scale,state.settings.ocean_scale,1 if valid else 0,0) if state != null else Vector4(1,1,0,0)
		parameters[StringName("local_fft_domains_%d"%slot)] = Vector3(state.configs[0].domain_size_m,state.configs[1].domain_size_m,state.configs[2].domain_size_m) if valid else Vector3(512,137,37)
		for band in 3: parameters[StringName("local_fft_%d_%d"%[slot,band])] = state.textures[band] if valid else null
	return parameters

func pack_gpu() -> PackedByteArray:
	var values := PackedFloat32Array([entries.size(),time_s,sea_level,1 if displaced else 0])
	for i in MAX_SHAPES:
		var entry: Dictionary = entries[i] if i < entries.size() else {}
		var matrix := Projection(entry.inverse) if not entry.is_empty() else Projection.IDENTITY
		for column in [matrix.x,matrix.y,matrix.z,matrix.w,entry.get("shape",Vector4.ZERO),entry.get("blend",Vector4.ZERO),entry.get("meta",Vector4.ZERO),Vector4.ZERO]:
			values.append_array(PackedFloat32Array([column.x,column.y,column.z,column.w]))
	for slot in 2:
		var state: RefCounted = states[slot]
		var valid: bool = state != null and state.ready
		values.append_array(PackedFloat32Array([state.settings.clipmap_geometry_scale if valid else 1.0,state.settings.ocean_scale if valid else 1.0,1 if valid else 0,0]))
		values.append_array(PackedFloat32Array([state.configs[0].domain_size_m,state.configs[1].domain_size_m,state.configs[2].domain_size_m,0]) if valid else PackedFloat32Array([512,137,37,0]))
	values.append_array(tsunami.packed())
	return values.to_byte_array()

func gpu_sources() -> Array[RID]:
	var result: Array[RID] = []
	for slot in 2:
		for band in 3: result.append(states[slot].textures[band].texture_rd_rid if states[slot] != null and states[slot].ready else RID())
	return result

func shutdown() -> void:
	for state in states:
		if state != null: state.shutdown()
	states = [null,null]
	entries.clear()
