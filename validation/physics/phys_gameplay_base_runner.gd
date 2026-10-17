extends SceneTree
## Native renderer validation of the launchable, actual vehicle scene.
const World = preload("res://gameplay/jet_ski_ocean.tscn")
const Query = preload("res://addons/ocean/physics/gpu/ocean_surface_query.gd")
const Adapter = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const State = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
const Weather = preload("res://addons/ocean/physics/dynamic_ocean_weather.gd")
var world: Node3D
var ocean: Node
var fft: Node
var ski: JetSkiController
var water: Node
var query: RefCounted
var report := {"status":"PARTIAL", "failures":[], "phases":[], "reference":[], "mismatch":[]}
var rows: Array = []
var phase := ""
var native: Object
var weather: RefCounted
var physics_count := 0
var latency_diagnostic := false
var current_production_diagnostic := false
var artifact_prefix := "PHYS-GAMEPLAY-BASE-1-"
var output_path := "res://validation/physics/PHYS-GAMEPLAY-BASE-1-MEASUREMENTS.json"

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	world = World.instantiate(); world.capture_metrics = true
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--ring-size="): world.query_ring_size = int(argument.trim_prefix("--ring-size="))
		if argument == "--latency-diagnostic": latency_diagnostic = true
		if argument == "--current-production": current_production_diagnostic = true
	if latency_diagnostic:
		artifact_prefix = "PHYS-GAMEPLAY-BASE-1.1-ring-%d-" % world.query_ring_size
		output_path = "res://validation/physics/PHYS-GAMEPLAY-BASE-1.1-RING-%d-MEASUREMENTS.json" % world.query_ring_size
	elif current_production_diagnostic:
		artifact_prefix = "PHYS-GAMEPLAY-BASE-1.1-current-"
		output_path = "res://validation/physics/PHYS-GAMEPLAY-BASE-1.1-CURRENT-MEASUREMENTS.json"
	root.add_child(world)
	while not world.ready_to_drive: await process_frame
	ski = world.ski; water = world.water; fft = water.fft; query = water.query
	ocean = world.get_node("Production/Ocean")
	report["hardware"] = {"gpu":RenderingServer.get_video_adapter_name(), "cpu":OS.get_processor_name(), "renderer":RenderingServer.get_current_rendering_method(),"driver":RenderingServer.get_current_rendering_driver_name(),"engine":Engine.get_version_info()}
	report["ring_size"] = world.query_ring_size
	if latency_diagnostic or current_production_diagnostic:
		physics_frame.connect(_observe)
		var phase_name := "current_production_3000"
		if latency_diagnostic:
			await _transition()
			_reset(Vector3.ZERO,Vector3(393.939,0,-991.260))
			phase_name="coastal_historical_fold_3000"
		await _phase(phase_name,3000)
		await _finish_latency_diagnostic()
		return
	physics_frame.connect(_observe)
	# Same camera, frozen field, no vehicle/debug/UI: before/after query activation.
	ocean.wave_speed_multiplier = 0.0
	world.contact_debug = false; world.label.hide(); ski.hide(); ski.freeze = true
	world.follow_camera = false
	world.camera.position = Vector3(0,4,8); world.camera.look_at(Vector3.ZERO)
	for solver in fft.get("_solvers"): RenderingServer.call_on_render_thread(solver.set_query_fields_enabled.bind(false))
	for i in 10: await process_frame
	await _capture("visual-before")
	for solver in fft.get("_solvers"): RenderingServer.call_on_render_thread(solver.set_query_fields_enabled.bind(true))
	for i in 10: await process_frame
	await _capture("visual-after")
	ski.show(); world.label.show(); world.contact_debug = true
	world.follow_camera = true
	await _reference("current")
	await _set_state("calm",0.15,4.0)
	await _reference("calm")
	# Small nonzero actual waves; stationary calm settling and four restoring tilts.
	ocean.wave_speed_multiplier = 1.0
	_reset(Vector3.ZERO, Vector3.ZERO)
	ski.rider_dynamics_system.turn_lean_enabled = false
	await _phase("calm_settle",600)
	for tilt in [Vector3(0,0,10),Vector3(0,0,-10),Vector3(10,0,0),Vector3(-10,0,0)]:
		_reset(tilt,Vector3.ZERO)
		await _phase("tilt_"+str(tilt),360)
	ski.rider_dynamics_system.turn_lean_enabled = true
	await _set_state("normal",1.0,12.0)
	await _reference("normal")
	ocean.wave_speed_multiplier = 1.0
	_reset(Vector3.ZERO,Vector3.ZERO)
	await _phase("normal_stationary",600)
	Input.action_press("throttle",0.3)
	await _phase("low_throttle",420)
	Input.action_press("throttle",0.65)
	await _phase("medium_throttle",600)
	Input.action_press("steer_left")
	await _phase("steer_left",360)
	Input.action_release("steer_left"); Input.action_press("steer_right")
	await _phase("steer_right",360)
	Input.action_release("steer_right"); Input.action_release("throttle")
	# Controlled actual-body fall supplements naturally observed crest departures.
	_reset(Vector3(5,0,0),Vector3(0,3,0))
	await _phase("airborne_landing",420)
	await _transition()
	await _reference("storm")
	ocean.wave_speed_multiplier = 1.0
	_reset(Vector3.ZERO,Vector3.ZERO)
	Input.action_press("throttle",0.5)
	await _phase("storm_drive",1200)
	Input.action_release("throttle")
	await _pause_check()
	# Continue the same four-contact vehicle, including Coastal/fold-prone XZ.
	# No root diagnostics, global scan or extra diagnostic contacts.
	for center in [Vector3(-50,0,40),Vector3(32,0,-72)]:
		_reset(Vector3.ZERO,center)
		await _phase("coastal_"+str(center),900)
	_reset(Vector3.ZERO,Vector3(393.939,0,-991.260))
	await _phase("coastal_historical_fold_3000",3000)
	phase = "stress_completion"
	while int(query.get_stats().completed) < 10000:
		await process_frame
		if physics_count > 24000: report.failures.append("10000 batch timeout"); break
	await _capture("drive-final")
	report["age_ticks"] = _dist(water.all_ages)
	report["usable_age_ticks"] = _dist(water.ages)
	report["contact_input_age_ticks"] = _dist(water.input_ages)
	report["consumer"] = {"accepted_batches":water.accepted_batches,"unavailable_ticks":water.unavailable_ticks,"unavailable_reasons":water.unavailable_reasons,"result_rejections":water.result_rejections,"invalid_contacts":water.invalid_contacts,"physics_ticks":physics_count}
	var stats: Dictionary = query.get_stats()
	report["query"] = _query_summary(stats)
	report["stress"] = {"completed_four_contact_batches":stats.heightfield_batches,"validated_contacts":stats.heightfield_contacts,"inversion_calls":0,"multi_root_searches":0,"invalid_due_folds":0,"invalid_contacts":stats.heightfield_invalid_contacts}
	report["visual_features"] = ocean.get_feature_flags()
	report["frame_queue_size"] = ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size")
	report["body"] = {"mass":ski.mass,"center_of_mass":str(ski.center_of_mass),"equilibrium_depth":ski.water_physics_system.equilibrium_depth,"damping_ratio":ski.water_physics_system.damping_ratio,"spring_n_per_m":ski.mass*9.8/(4*ski.water_physics_system.equilibrium_depth),"damping_n_s_per_m":ski.water_physics_system.damping_ratio*2*sqrt(ski.mass*9.8/(4*ski.water_physics_system.equilibrium_depth)*ski.mass/4)}
	report.body["linear_damp"] = ski.linear_damp
	report.body["angular_damp"] = ski.angular_damp
	report.body["project_linear_damp"] = ProjectSettings.get_setting("physics/3d/default_linear_damp")
	report.body["project_angular_damp"] = ProjectSettings.get_setting("physics/3d/default_angular_damp")
	physics_frame.disconnect(_observe)
	world.queue_free()
	for i in 20: await process_frame
	report["shutdown"] = _query_summary(query.get_stats())
	if int(stats.heightfield_invalid_contacts)>0 or int(stats.errors)>0 or int(stats.mismatches)>0: report.failures.append("query validity/coherence failure")
	if float(report.query.gpu_us.get("mean",INF))>500.0: report.failures.append("GPU query mean exceeds 0.50 ms")
	if float(report.age_ticks.get("p95",INF))>2.0: report.failures.append("field-age p95 exceeds usable 2-tick budget; stale results were skipped")
	if report.failures.is_empty(): report.status = "PASS_AUTOMATED_USER_HANDLING_PENDING"
	var file := FileAccess.open(output_path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("GAMEPLAY_COMPLETE="+JSON.stringify({"status":report.status,"failures":report.failures,"query":report.query,"consumer":report.consumer}))
	quit(0 if report.failures.is_empty() else 1)

func _finish_latency_diagnostic() -> void:
	var stats_before_drain: Dictionary = query.get_stats()
	report["status"] = "PASS" if report.phase_latency[0].stage_latency.usable_force_ticks >= 2970 else "PARTIAL"
	report["consumer"] = {"unavailable_ticks":report.phase_latency[0].stage_latency.unavailable_force_ticks,"unavailable_reasons":report.phase_latency[0].stage_latency.unavailable_reasons,"result_rejections":water.result_rejections.duplicate(true),"invalid_contacts":water.invalid_contacts}
	report["query_before_shutdown"] = _query_summary(stats_before_drain)
	physics_frame.disconnect(_observe)
	ski.freeze = true
	RenderingServer.call_on_render_thread(query.shutdown)
	for _i in 180:
		await process_frame
		if int(query.get_stats().owned_buffers)==0: break
	var drained: Dictionary=query.get_stats()
	ocean.shutdown()
	world.queue_free()
	for _i in 8: await process_frame
	report["shutdown"]={"owned_buffers":drained.owned_buffers,"in_flight":drained.in_flight,"pending":drained.pending,"completed_pending":drained.completed_pending,"errors":drained.errors,"mismatches":drained.mismatches,"retired":drained.retired}
	report["query"]=_query_summary(drained)
	var file:=FileAccess.open(output_path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("GAMEPLAY_LATENCY_DIAGNOSTIC="+JSON.stringify({"ring_size":report.ring_size,"status":report.status,"phase":report.phase_latency[0],"query":report.query,"shutdown":report.shutdown}))
	quit(0)

func _observe() -> void:
	physics_count += 1
	if phase.is_empty() or ski == null or ski.freeze: return
	var w := ski.water_physics_system
	var row := {"position":[ski.position.x,ski.position.y,ski.position.z],"rotation_deg":[ski.rotation_degrees.x,ski.rotation_degrees.z],"vy":ski.linear_velocity.y,"speed":ski.linear_velocity.length(),"depths":Array(w.point_depths),"forces":Array(w.point_normal_forces),"mask":w.state.raw_contact_mask,"age":water.result_age,"yaw":ski.rotation.y,"valid":w.point_sample_valid.count(true)}
	rows.append(row)
	if not ski.position.is_finite() or not ski.linear_velocity.is_finite(): report.failures.append("nonfinite body "+phase)

func _phase(name: String, ticks: int) -> void:
	phase=name; rows=[]
	var phase_start_tick := physics_count
	var phase_start_generation := int(query.get_stats().submitted)
	var phase_stats_before: Dictionary = query.get_stats()
	var field_age_start: int = water.all_ages.size()
	var contact_age_start: int = water.input_ages.size()
	var unavailable_before: int = water.unavailable_ticks
	var unavailable_reason_before: Dictionary = water.unavailable_reasons.duplicate(true)
	for i in ticks: await physics_frame
	var summary := {"name":name,"ticks":ticks,"end_position":str(ski.position),"end_rotation_degrees":str(ski.rotation_degrees),"end_speed":ski.linear_velocity.length(),"end_yaw":ski.rotation.y,"air_ticks":0,"wet_ticks":0,"all_valid_ticks":0,"first_wet_force":0.0,"maximum_force":0.0,"force_step_max":0.0}
	var previous := 0.0
	for row in rows:
		var maximum := float(row.forces.max())
		summary.maximum_force=maxf(summary.maximum_force,maximum)
		summary.force_step_max=maxf(summary.force_step_max,absf(maximum-previous)); previous=maximum
		if row.mask==0: summary.air_ticks+=1
		else:
			if summary.wet_ticks==0: summary.first_wet_force=maximum
			summary.wet_ticks+=1
		if row.valid==4: summary.all_valid_ticks+=1
	var tail: Array = rows.slice(maxi(0,rows.size()-120))
	for key in ["vy","speed","age"]: summary[key]=_dist(tail.map(func(r): return r[key]))
	for field in ["depths","forces","rotation_deg","position"]:
		var values: Array = []
		for axis in tail[0][field].size() if not tail.is_empty() else 0: values.append(_dist(tail.map(func(r): return r[field][axis])))
		summary[field]=values
	report.phases.append(summary)
	var phase_stats_after: Dictionary = query.get_stats()
	var phase_trace := _latency_summary(phase_start_generation, int(phase_stats_after.submitted), phase_start_tick, physics_count)
	phase_trace["query_deltas"] = {"submitted":int(phase_stats_after.submitted)-int(phase_stats_before.submitted),"dispatched":int(phase_stats_after.dispatched)-int(phase_stats_before.dispatched),"completed":int(phase_stats_after.completed)-int(phase_stats_before.completed),"consumed":int(phase_stats_after.consumed)-int(phase_stats_before.consumed),"coalesced":int(phase_stats_after.coalesced)-int(phase_stats_before.coalesced),"no_free_slot":int(phase_stats_after.no_free_slot)-int(phase_stats_before.no_free_slot),"skipped_generations":int(phase_stats_after.generations_skipped_before_dispatch)-int(phase_stats_before.generations_skipped_before_dispatch),"superseded_completions":int(phase_stats_after.superseded_results)-int(phase_stats_before.superseded_results)}
	phase_trace["physics_ticks"] = physics_count-phase_start_tick
	phase_trace["usable_force_ticks"] = maxi(0, physics_count-phase_start_tick-(water.unavailable_ticks-unavailable_before))
	phase_trace["unavailable_force_ticks"] = water.unavailable_ticks-unavailable_before
	phase_trace["unavailable_reasons"] = {}
	for reason in water.unavailable_reasons.keys(): phase_trace.unavailable_reasons[reason]=int(water.unavailable_reasons[reason])-int(unavailable_reason_before.get(reason,0))
	phase_trace["water_age"] = _dist(water.all_ages.slice(field_age_start))
	phase_trace["contact_age"] = _dist(water.input_ages.slice(contact_age_start))
	phase_trace["ring_size"] = int(phase_stats_after.ring_size)
	report["phase_latency"] = report.get("phase_latency",[])
	report.phase_latency.append({"name":name,"ticks":physics_count-phase_start_tick,"stage_latency":phase_trace})
	print("GAMEPLAY_PHASE="+JSON.stringify(summary))
	print("GAMEPLAY_LATENCY_PHASE="+JSON.stringify(report.phase_latency[-1]))
	phase=""

func _latency_summary(first_generation: int, last_generation: int, first_tick: int, last_tick: int) -> Dictionary:
	var traces: Array = query.get_validation_trace()
	var selected: Array[Dictionary] = []
	for item in traces:
		if int(item.get("generation",-1)) < first_generation or int(item.get("generation",-1)) > last_generation: continue
		if int(item.get("contact_capture_tick",-1)) < first_tick or int(item.get("contact_capture_tick",-1)) > last_tick: continue
		selected.append(item)
	var values := {"contact_to_submit_us":[],"submit_to_enqueue_us":[],"enqueue_to_dispatch_us":[],"submit_to_dispatch_ticks":[],"field_age_at_dispatch_ticks":[],"dispatch_to_callback_ms":[],"gpu_execution_us":[],"callback_to_publish_us":[],"publish_to_consume_ticks":[],"total_contact_age_at_consume_ticks":[],"total_field_age_at_consume_ticks":[]}
	var per_slot: Dictionary = {}
	for item in selected:
		if item.has("slot_index") and item.has("dispatch_usec") and item.has("callback_usec"):
			var slot_id := str(item.slot_index)
			if not per_slot.has(slot_id): per_slot[slot_id]=[]
			per_slot[slot_id].append(int(item.callback_usec)-int(item.dispatch_usec))
		if item.has("submit_usec") and item.has("contact_capture_usec"): values.contact_to_submit_us.append(int(item.submit_usec)-int(item.contact_capture_usec))
		if item.has("query_enqueue_usec") and item.has("submit_usec"): values.submit_to_enqueue_us.append(int(item.query_enqueue_usec)-int(item.submit_usec))
		if item.has("dispatch_usec") and item.has("query_enqueue_usec"): values.enqueue_to_dispatch_us.append(int(item.dispatch_usec)-int(item.query_enqueue_usec))
		if item.has("dispatch_tick") and item.has("submit_tick"): values.submit_to_dispatch_ticks.append(int(item.dispatch_tick)-int(item.submit_tick))
		if item.has("dispatch_tick") and item.has("field_tick"): values.field_age_at_dispatch_ticks.append(int(item.dispatch_tick)-int(item.field_tick))
		if item.has("callback_usec") and item.has("dispatch_usec"): values.dispatch_to_callback_ms.append((int(item.callback_usec)-int(item.dispatch_usec))/1000.0)
		if item.has("gpu_us"): values.gpu_execution_us.append(float(item.gpu_us))
		if item.has("publish_usec") and item.has("callback_usec"): values.callback_to_publish_us.append(int(item.publish_usec)-int(item.callback_usec))
		if item.has("consume_tick") and item.has("publish_tick"): values.publish_to_consume_ticks.append(int(item.consume_tick)-int(item.publish_tick))
		if item.has("consume_tick") and item.has("contact_capture_tick"): values.total_contact_age_at_consume_ticks.append(int(item.consume_tick)-int(item.contact_capture_tick))
		if item.has("consume_tick") and item.has("field_tick"): values.total_field_age_at_consume_ticks.append(int(item.consume_tick)-int(item.field_tick))
	for key in values.keys(): values[key]=_dist(values[key])
	values["trace_generations"] = selected.size()
	values["slot_in_flight_us_by_slot"]={}
	for slot_id in per_slot: values.slot_in_flight_us_by_slot[slot_id]=_dist(per_slot[slot_id])
	return values

func _reset(tilt: Vector3, offset: Vector3) -> void:
	ski.freeze=true; ski.position=Vector3(0,0.6,0)+offset; ski.rotation_degrees=tilt
	ski.linear_velocity=Vector3.ZERO; ski.angular_velocity=Vector3.ZERO
	water.invalidate_contacts(); ski.reset_physics_interpolation(); ski.freeze=false

func _set_state(name: String, hs: float, wind: float) -> void:
	ocean.wave_speed_multiplier=0.0; ski.freeze=true
	load("res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension")
	var builder: Object=ClassDB.instantiate("OceanQueryNative")
	var profile: Resource=ocean.wave_profile
	var configs: Array=profile.build_fft_configs(hs,wind,210.0,ocean.swell,ocean.long_wave_spacing)
	var state: Dictionary=State.build(configs,ocean.simulation_seed,hs,profile.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],ocean.mid_fill_amount,7,builder)
	builder.call("set_production_spectrum",state.bands)
	builder.call("start_dynamic_async_fields",fft.get_wave_time(),physics_count)
	await _native_at(builder,fft.get_wave_time())
	fft.queue_dynamic_spectrum(builder,builder.call("get_dynamic_snapshot_spectrum",false))
	for i in 8: await process_frame
	builder.call("clear")
	print("GAMEPLAY_STATE="+name)

func _native_at(reference: Object, time: float) -> void:
	for i in 600:
		reference.call("advance_dynamic_async",physics_count+i,time,time,1.0/60.0)
		var info: PackedInt64Array=reference.call("get_dynamic_snapshot_info")
		if info[0]==1 and absf(info[1]/1e9-time)<1e-8: return
		await process_frame
	report.failures.append("reference field timeout")

func _reference(name: String) -> void:
	ocean.wave_speed_multiplier=2.0 if name == "current" else 1.0; ski.freeze=true
	for i in 8: await process_frame
	var reference: Object=ClassDB.instantiate("OceanQueryNative")
	reference.call("set_production_spectrum",fft.get_phys2_band_spectrum_snapshots())
	Adapter.configure_coastal(reference,fft.get_phys3_coastal_snapshot())
	var time: float=fft.get_wave_time()
	reference.call("start_dynamic_async_fields",time,physics_count)
	await _native_at(reference,time)
	var accuracy := {"state":name,"height_max_m":0.0,"vertical_velocity_max_mps":0.0,"normal_max_deg":0.0,"samples":0}
	var mismatch := {"state":name,"horizontal_displacement_m":[],"approximate_height_difference_m":[]}
	for center in [Vector2(0,0),Vector2(32,-72),Vector2(-50,40),Vector2(393.939,-991.260)]:
		var points := PackedVector3Array()
		for p in ski.water_physics_system.get_buoyancy_local_points(): points.append(Vector3(center.x+p.x,p.y,center.y+p.z))
		var generation: int=query.submit(Query.pack_heightfield(points),Engine.get_physics_frames())
		var result := {}
		for i in 180:
			await process_frame
			result=query.consume(Engine.get_physics_frames())
			if not result.is_empty() and result.generation==generation: break
		if result.is_empty(): report.failures.append("reference GPU timeout"); continue
		await _native_at(reference,float(result.sample_time))
		for i in 4:
			var p: Vector3=points[i]
			var gpu: Dictionary=Query.decode_heightfield(result.bytes,i)
			var cpu: PackedFloat64Array=reference.call("sample_dynamic_material_q",p.x,p.z)
			var xm: PackedFloat64Array=reference.call("sample_dynamic_material_q",p.x-0.01,p.z)
			var xp: PackedFloat64Array=reference.call("sample_dynamic_material_q",p.x+0.01,p.z)
			var zm: PackedFloat64Array=reference.call("sample_dynamic_material_q",p.x,p.z-0.01)
			var zp: PackedFloat64Array=reference.call("sample_dynamic_material_q",p.x,p.z+0.01)
			var normal := Vector3(-(xp[3]-xm[3])/0.02,1,-(zp[3]-zm[3])/0.02).normalized()
			accuracy.height_max_m=maxf(accuracy.height_max_m,absf(gpu.surface_world_y-(ocean.sea_level+cpu[3])))
			accuracy.vertical_velocity_max_mps=maxf(accuracy.vertical_velocity_max_mps,absf(gpu.surface_vertical_velocity-cpu[9]*float(result.wave_time_rate)))
			accuracy.normal_max_deg=maxf(accuracy.normal_max_deg,rad_to_deg(acos(clampf(gpu.normal.dot(normal),-1,1))))
			accuracy.samples+=1
			var h := Vector2(cpu[2],cpu[4])
			var shifted: PackedFloat64Array=reference.call("sample_dynamic_material_q",p.x+h.x,p.z+h.y)
			mismatch.horizontal_displacement_m.append(h.length())
			mismatch.approximate_height_difference_m.append(absf(shifted[3]-cpu[3]))
			if not gpu.valid: report.failures.append("invalid reference sample")
	if accuracy.height_max_m>0.001 or accuracy.vertical_velocity_max_mps>0.001 or accuracy.normal_max_deg>0.5: report.failures.append("reference accuracy "+name)
	for key in ["horizontal_displacement_m","approximate_height_difference_m"]: mismatch[key]=_dist(mismatch[key])
	report.reference.append(accuracy); report.mismatch.append(mismatch)
	reference.call("clear")
	ocean.wave_speed_multiplier=0.0
	print("GAMEPLAY_REFERENCE="+JSON.stringify(accuracy))

func _transition() -> void:
	ski.freeze=false; ocean.wave_speed_multiplier=1.0
	native=ClassDB.instantiate("OceanQueryNative")
	native.call("set_production_spectrum",fft.get_phys2_band_spectrum_snapshots())
	native.call("start_dynamic_async_fields",fft.get_wave_time(),physics_count)
	await _native_at(native,fft.get_wave_time())
	weather=Weather.new(native,fft)
	var configs: Array=ocean.wave_profile.build_fft_configs(3.0,25.0,210.0,ocean.swell,ocean.long_wave_spacing)
	var params := {"seed":ocean.simulation_seed,"overall_hs":3.0,"profile_hs":ocean.wave_profile.combined_significant_wave_height_m(),"wave_height_scale":1.0,"band_scales":[1.0,1.0,1.0],"mid_fill":ocean.mid_fill_amount}
	var serial: int=weather.request(configs,params,3.0)
	var started := false
	var done := false
	var epoch: int=fft.get("_gpu_generation").generation
	phase="weather_transition"; rows=[]
	for i in 1200:
		await physics_frame
		var time: float=fft.get_wave_time()
		native.call("advance_dynamic_async",physics_count,time,time,1.0/60.0)
		var result: Dictionary=weather.poll(time)
		if not result.is_empty(): started=bool(result.get("ok",false))
		var bands: Array=fft.get("_gpu_generation").get_runtime_spectrum()
		if started and bands.size()==3 and float(bands[0].weather_alpha)>=1.0: done=true; break
	report["weather"]={"serial":serial,"started":started,"completed":done,"epoch_unchanged":epoch==fft.get("_gpu_generation").generation,"body_position":str(ski.position)}
	if not done: report.failures.append("weather transition incomplete")
	weather.shutdown(); native.call("clear"); phase=""

func _pause_check() -> void:
	var time: float=fft.get_wave_time()
	var before: Vector3=ski.position
	paused=true
	for i in 60: await process_frame
	report["pause"]={"wave_time_delta":fft.get_wave_time()-time,"body_position_delta":ski.position.distance_to(before)}
	paused=false
	await _phase("resume",180)

func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://validation/physics/"+artifact_prefix+name+".png")

func _dist(values: Array) -> Dictionary:
	if values.is_empty(): return {}
	var sorted:=values.duplicate(); sorted.sort()
	var total:=0.0
	for v in sorted: total+=float(v)
	return {"n":sorted.size(),"mean":total/sorted.size(),"p50":sorted[mini(sorted.size()-1,int(sorted.size()*0.50))],"p95":sorted[mini(sorted.size()-1,int(sorted.size()*0.95))],"p99":sorted[mini(sorted.size()-1,int(sorted.size()*0.99))],"min":sorted[0],"max":sorted[-1]}

func _query_summary(stats: Dictionary) -> Dictionary:
	var result:=stats.duplicate()
	for key in ["latency_ms","latency_ticks","submit_us","consume_us","dispatch_cpu_us","ocean_gpu_us","oldest_in_flight_ticks","field_age_at_dispatch_ticks","contact_to_submit_us","submit_to_dispatch_ticks","callback_us","callback_to_publish_us","publish_to_consume_ticks","contact_age_ticks","field_age_at_consume_ticks","force_application_ticks"]: result[key]=_dist(stats[key])
	result.slot_in_flight_us=_dist(stats.slot_in_flight_us.map(func(r):return r.duration_us))
	result.gpu_us=_dist(stats.gpu_samples.map(func(r): return r.gpu_us)); result.erase("gpu_samples")
	return result
