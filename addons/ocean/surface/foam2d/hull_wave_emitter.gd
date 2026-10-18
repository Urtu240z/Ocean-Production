extends RefCounted
## Finite wave packets from existing V1 contacts; shared by render and physics.
const MAX_PACKETS := 128
var packets: Array[Dictionary] = []
var submitted_wakes := 0
var submitted_impacts := 0
var dropped_packets := 0
var _states: Dictionary = {}

func update(delta: float, clock: float, vehicles: Array, style: Resource, physical := false) -> void:
	for i in range(packets.size()-1,-1,-1):
		if clock-packets[i].born >= packets[i].life+packets[i].get("time_span",0.0): packets.remove_at(i)
	var live := {}
	for ski: RigidBody3D in vehicles:
		if not is_instance_valid(ski) or not ski.is_inside_tree(): continue
		var id := ski.get_instance_id()
		live[id] = true
		var physics: Node = ski.get("water_physics_system")
		if not is_instance_valid(physics): continue
		var wet := false
		var impact_speed := 0.0
		for point in mini(4,mini(physics.point_sample_valid.size(),physics.point_depths.size())):
			if physics.point_sample_valid[point] and not physics.contact_is_airborne and physics.point_depths[point] > 0.0:
				wet = true
				if point < physics.point_relative_normal_speeds.size(): impact_speed = maxf(impact_speed,-physics.point_relative_normal_speeds[point])
		var transform := ski.global_transform if physical else ski.get_global_transform_interpolated()
		var hull_position := Vector2(transform.origin.x,transform.origin.z)
		var forward := Vector2(-transform.basis.z.x,-transform.basis.z.z).normalized()
		if forward.is_zero_approx(): forward = Vector2(0,-1)
		if not _states.has(id):
			# Cache the midpoint of the existing bow contacts. Only the moving
			# deformation starts here; landing rings keep their hull-center origin.
			var points: PackedVector3Array = physics.get_buoyancy_local_points()
			var bow_local := (points[0]+points[1])*0.5 if points.size() >= 2 else Vector3(0,0,-1.15)
			var bow_world: Vector3 = transform*bow_local
			_states[id] = {"wet":wet,"vy":ski.linear_velocity.y,"elapsed":0.0,"previous":Vector2(bow_world.x,bow_world.z),"last_impact":-100.0,"strength":0.0,"bow_local":bow_local,"live":{},"source_start":clock}
		var state: Dictionary = _states[id]
		var source_world: Vector3 = transform*Vector3(state.bow_local)
		var position := Vector2(source_world.x,source_world.z)
		state.elapsed += delta
		impact_speed = maxf(impact_speed,-float(state.vy))
		if wet and not state.wet and clock-state.last_impact > 0.4 and impact_speed > style.impact_wave_min_speed_mps and style.impact_wave_height_m > 0.0:
			var strength := clampf((impact_speed-style.impact_wave_min_speed_mps)/4.0,0.0,1.0)
			_add({"owner":id,"position":hull_position,"forward":forward,"born":clock,"life":style.impact_wave_duration_s,
				"amplitude":style.impact_wave_height_m*strength,"speed":style.impact_wave_speed_mps,
				"width":style.impact_wave_width_m,"wavelength":style.impact_wave_wavelength_m,"half_length":1.0,"impact":true,"start_radius":0.0,
				"rise":style.impact_wave_rise_s,"fade":style.impact_wave_fade_s})
			state.last_impact = clock
			submitted_impacts += 1
		var speed := Vector2(ski.linear_velocity.x,ski.linear_velocity.z).length()
		var target := clampf((speed*3.6-style.wake_wave_min_speed_kmh)/maxf(style.wake_wave_full_speed_kmh-style.wake_wave_min_speed_kmh,1.0),0.0,1.0) if wet else 0.0
		state.strength = lerpf(float(state.get("strength",0.0)),target,1.0-exp(-delta/maxf(style.wake_wave_response_s,0.05)))
		# Keep a bounded packet budget even with long lifetimes and many boats.
		var interval := maxf(0.2,style.wake_wave_duration_s*vehicles.size()/(MAX_PACKETS*0.85))
		if wet and speed*3.6 > style.wake_wave_min_speed_kmh and style.wake_wave_height_m > 0.0:
			var traveled: float = position.distance_to(state.previous)
			var max_travel := maxf(12.0,speed*float(state.elapsed)*1.5)
			if traveled >= max_travel:
				_finish_live(state)
				state.previous = position
				state.elapsed = 0.0
				state.source_start = clock
			elif traveled >= 0.01:
				var half_length := maxf(maxf(traveled*0.85,speed*style.wake_wave_rise_s*0.6),1.0)
				var direction := (position-Vector2(state.previous)).normalized()
				var inverse_speed := float(state.elapsed)/traveled
				var time_span := half_length*inverse_speed
				var packet := {"owner":id,"position":position-direction*half_length,"forward":direction,"born":clock-time_span,"life":style.wake_wave_duration_s,
					"amplitude":style.wake_wave_height_m*float(state.strength),"speed":style.wake_wave_speed_mps,
					"width":style.wake_wave_width_m,"wavelength":style.wake_wave_wavelength_m,
					"half_length":half_length,"impact":false,"start_radius":style.initial_width_m*0.5,
					"rise":style.wake_wave_rise_s,"fade":style.wake_wave_fade_s,"inverse_speed":inverse_speed,"time_span":time_span,
					"source_start":state.source_start,"birth_distance":style.wake_wave_birth_distance_m,"live":true}
				# One mutable leading segment follows the bow every frame. Archive
				# that same segment in place; the head never waits for the cadence.
				if state.live.is_empty():
					state.live = packet
					_add(packet)
				else:
					state.live.assign(packet)
				if state.elapsed >= interval and traveled >= 0.35:
					_finish_live(state)
					state.previous = position
					state.elapsed = 0.0
		else:
			_finish_live(state)
			state.previous = position
			state.elapsed = 0.0
			state.source_start = clock
		state.wet = wet
		state.vy = ski.linear_velocity.y
	for id in _states.keys():
		if not live.has(id):
			_finish_live(_states[id])
			_states.erase(id)

func _finish_live(state: Dictionary) -> void:
	if state.live.is_empty(): return
	state.live.live = false
	state.live = {}
	submitted_wakes += 1

func _add(packet: Dictionary) -> void:
	if packets.size() >= MAX_PACKETS:
		var oldest := 0
		for i in packets.size():
			if not packets[i].get("live",false):
				oldest = i
				break
		packets.remove_at(oldest)
		dropped_packets += 1
	packets.append(packet)

func diagnostic_state() -> Dictionary:
	var heads := 0
	for state: Dictionary in _states.values():
		if not state.live.is_empty(): heads += 1
	return {"packets":packets.size(),"submitted_wakes":submitted_wakes,"submitted_impacts":submitted_impacts,
		"live_heads":heads,"dropped_packets":dropped_packets,"max_packets":MAX_PACKETS,"extra_queries":0,"new_meshes":0}
