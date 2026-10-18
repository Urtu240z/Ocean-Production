extends RefCounted
## One authoritative packet snapshot per Ocean and physics tick. No GPU readback.
const Emitter := preload("res://addons/ocean/surface/foam2d/hull_wave_emitter.gd")
var emitter := Emitter.new()
var clock := 0.0
var tick := -1
var updates := 0
var publication_us := 0
var query_us := 0
var query_count := 0
var status := "Not initialized"
var _native: Object
var _attempted := false
var _ready := false

func advance(next_tick: int, delta: float, vehicles: Array, style: Resource) -> bool:
	if tick == next_tick: return _ready
	tick = next_tick
	if not _attempted:
		_attempted = true
		if ClassDB.class_exists("OceanQueryNative"):
			_native = ClassDB.instantiate("OceanQueryNative")
		if _native == null or not _native.has_method("publish_hull_waves"):
			status = "Hull wave native extension unavailable; restart with the updated extension"
			push_warning(status)
			return false
	if _native == null or not _native.has_method("publish_hull_waves"): return false
	var started := Time.get_ticks_usec()
	clock += maxf(delta,0.0)
	emitter.update(delta,clock,vehicles,style,true)
	# Copy scalar rows into native storage once; no mutable Dictionary crosses
	# the consumer boundary. Rendering receives its own deep packet snapshot.
	var rows := PackedFloat64Array()
	var owners := PackedInt64Array()
	for p: Dictionary in emitter.packets:
		rows.append_array(PackedFloat64Array([p.position.x,p.position.y,p.forward.x,p.forward.y,
			p.amplitude,p.speed,p.width,p.wavelength,p.life,p.half_length,p.born,
			p.get("rise",0.75),p.get("fade",p.life*0.45),p.get("inverse_speed",0.0),
			p.get("start_radius",0.28),p.get("source_start",clock-100000.0),p.get("birth_distance",0.65),
			1.0 if p.impact else 0.0]))
		owners.append(p.get("owner",0))
	_ready = _native.call("publish_hull_waves",rows,owners,clock)
	status = "OK" if _ready else "Invalid hull wave snapshot"
	publication_us = Time.get_ticks_usec()-started
	updates += 1
	return _ready

func sample(positions: PackedVector3Array, style: Resource, owner_id := 0,
		center := Vector3.ZERO) -> PackedFloat64Array:
	if not _ready: return PackedFloat64Array()
	var started := Time.get_ticks_usec()
	var values: PackedFloat64Array = _native.call("sample_hull_waves",positions,owner_id,center,
		style.wave_physics_self_delay_s,style.wave_physics_self_radius_m,style.deformation_max_height_m)
	query_us += Time.get_ticks_usec()-started
	query_count += positions.size()
	return values

func apply(samples: Array[WaterSample3D], positions: PackedVector3Array, style: Resource,
		owner_id := 0, center := Vector3.ZERO) -> void:
	if samples.size() != positions.size(): return
	var values := sample(positions,style,owner_id,center)
	if values.size() != samples.size()*4: return
	var limit: float = maxf(style.wave_physics_max_vertical_speed_mps,0.1)
	for i in samples.size():
		var s := samples[i]
		if not s.valid: continue
		var offset := i*4
		s.surface_position.y += values[offset]
		s.signed_depth = s.surface_position.y-positions[i].y
		s.normal = (s.normal-Vector3(values[offset+1],0.0,values[offset+2])*s.normal.y).normalized()
		# Extreme visual settings can imply enormous water speeds. This bound
		# affects the added vertical velocity only, never FFT velocity or height.
		s.velocity.y += clampf(values[offset+3],-limit,limit)

func diagnostic_state() -> Dictionary:
	return {"status":status,"tick":tick,"clock":clock,"updates":updates,
		"publication_us":publication_us,"query_us":query_us,"query_points":query_count,
		"packets":emitter.packets.size(),"max_packets":Emitter.MAX_PACKETS,
		"extra_ffts":0,"gpu_readbacks":0,"camera_dependent":false}
