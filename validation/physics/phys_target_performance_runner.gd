extends "res://validation/physics/phys_branch_continuity_runner.gd"
## Validation-only timing. No oracle or GPU texture readback in measured loops.
const WORLD = preload("res://validation/physics/target_physics_benchmark_world.gd")
var _measuring := false
var _measured_tick := 0
var _frame_values := PackedFloat64Array()
var _frame_count := 0
var _frame_overflow := 0
var _last_frame_us := 0
var _last_step := {}
signal render_flushed

func _timer_read_on_render(viewport: RID, index: int) -> void:
	var cpu := RenderingServer.viewport_get_measured_render_time_cpu(viewport)
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(viewport)
	_store_render_timing.call_deferred(index,cpu,gpu)

func _store_render_timing(index: int, cpu: float, gpu: float) -> void:
	_frame_values[index*5+3]=cpu; _frame_values[index*5+4]=gpu

func _render_barrier() -> void:
	_emit_render_flushed.call_deferred()

func _emit_render_flushed() -> void:
	render_flushed.emit()

func _step(ocean: Node, native: Object) -> Dictionary:
	_tick += 1
	var now := float(ocean.call("get_wave_time"))
	var moving := float(ocean.get("wave_speed_multiplier")) > 0.0
	var advance: PackedInt64Array = native.call("advance_dynamic_async",_tick,now,now+DT if moving else now,DT)
	var at := Time.get_ticks_usec()
	var ready: Dictionary = _weather.call("poll",now)
	var poll_ms := (Time.get_ticks_usec()-at)/1000.0
	at = Time.get_ticks_usec()
	var sample: PackedFloat64Array = native.call("sample_dynamic_material_q",31.25,-72.5)
	_last_step={"age":advance[7]/1e6,"wait_ms":advance[6]/1000.0,"query_ms":(Time.get_ticks_usec()-at)/1000.0,
		"poll_ms":poll_ms,"valid":sample.size()==15 and sample[0]!=0}
	return ready

func _option(key: String, fallback: String) -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(key + "="): return arg.substr(key.length() + 1)
	return fallback

func _distribution(values: Array) -> Dictionary:
	if values.is_empty(): return {"count": 0, "mean": null, "p50": null, "p95": null, "p99": null, "max": null}
	var sorted := values.duplicate(); sorted.sort()
	var sum := 0.0
	for value in sorted: sum += float(value)
	return {"count": sorted.size(), "mean": sum / sorted.size(), "p50": sorted[int((sorted.size()-1)*0.5)],
		"p95": sorted[int((sorted.size()-1)*0.95)], "p99": sorted[int((sorted.size()-1)*0.99)], "max": sorted.back()}

func _frame() -> void:
	var now := Time.get_ticks_usec()
	if _measuring and _last_frame_us > 0:
		var frame_ms := (now - _last_frame_us) / 1000.0
		var viewport := root.get_viewport_rid()
		if (_frame_count+1)*5 <= _frame_values.size():
			var base := _frame_count*5
			_frame_values[base]=_measured_tick; _frame_values[base+1]=frame_ms
			_frame_values[base+2]=1000.0/maxf(frame_ms,0.000001)
			# Read counters on their owning thread; main-thread getters serialize
			# the separate render mode and distort its timings.
			RenderingServer.call_on_render_thread(_timer_read_on_render.bind(viewport,_frame_count))
			_frame_count+=1
		else: _frame_overflow+=1
	_last_frame_us = now

func _frame_distribution(first: int, last: int) -> Dictionary:
	var cpu: Array = []; var gpu: Array = []; var frames: Array = []; var fps: Array = []
	for i in _frame_count:
		var base := i*5
		if _frame_values[base]<first or _frame_values[base]>=last: continue
		frames.append(_frame_values[base+1]); fps.append(_frame_values[base+2])
		if _frame_values[base+3]>0: cpu.append(_frame_values[base+3])
		if _frame_values[base+4]>0: gpu.append(_frame_values[base+4])
	return {"frame_ms": _distribution(frames), "fps": _distribution(fps),
		"cpu_render_ms": _distribution(cpu), "gpu_ms": _distribution(gpu), "gpu_timer_available": not gpu.is_empty()}

func _request_state(ocean: Node, index: int) -> Dictionary:
	var state: Array = [[0.8,4.0,20.0,0.8], [3.0,18.0,75.0,2.0], [0.8,4.0,20.0,0.8], [3.0,18.0,20.0,2.0]][index % 4]
	var profile: Resource = ocean.get("wave_profile")
	var configs: Array = profile.call("build_fft_configs", state[0], state[1], state[2], ocean.get("swell"), ocean.get("long_wave_spacing"))
	configs[0].choppiness = state[3]
	var at := Time.get_ticks_usec()
	var serial: int = _weather.call("request", configs, {"seed": ocean.get("simulation_seed"), "overall_hs": state[0],
		"profile_hs": profile.call("combined_significant_wave_height_m"), "wave_height_scale": 1.0,
		"band_scales": [1.0,1.0,1.0], "mid_fill": ocean.get("mid_fill_amount")}, 3.0)
	return {"tick": _measured_tick, "serial": serial, "state": state, "duration_s": 3.0, "request_ms": (Time.get_ticks_usec()-at)/1000.0}

func _query_bench(native: Object) -> Dictionary:
	var report := {}; var empty := PackedVector3Array()
	for count in [4,16,64]:
		var positions := PackedVector3Array()
		for i in count: positions.append(Vector3(2000.0 + i * 2.5, 0, -2000.0 + i * 0.5))
		var material: Array = []
		for i in 300:
			var at := Time.get_ticks_usec()
			var result: PackedFloat64Array = native.call("sample_dynamic_material_q_batch", positions)
			material.append((Time.get_ticks_usec()-at)/1000.0)
			if result.size() != count * 15: return {"passed": false, "reason": "material packing"}
		report["material_N%d_ms" % count] = _distribution(material)
		var coastal_positions := PackedVector3Array(); var coastal_material: Array = []
		for i in count: coastal_positions.append(Vector3(37.0+i*0.3,0,81.0+i*0.1))
		for i in 300:
			var at := Time.get_ticks_usec()
			var result: PackedFloat64Array = native.call("sample_dynamic_material_q_batch",coastal_positions)
			coastal_material.append((Time.get_ticks_usec()-at)/1000.0)
			if result.size()!=count*15: return {"passed":false,"reason":"Coastal material packing"}
		report["coastal_material_N%d_ms" % count]=_distribution(coastal_material)
		if count != 4: continue
		var targets := PackedVector3Array(); var previous := PackedFloat64Array()
		for p in positions:
			var q := Vector2(p.x,p.z); var w := _world(native,q)
			targets.append(Vector3(w.x,0,w.y)); previous.append_array(_state_at(native,q,w))
		var cold: Array = []; var warm: Array = []; var statuses := [0,0,0,0]; var bad := 0
		for i in 300:
			var at := Time.get_ticks_usec()
			var result: PackedFloat64Array = native.call("sample_dynamic_world_batch",targets,empty,false)
			cold.append((Time.get_ticks_usec()-at)/1000.0)
			if result.size() != 4 * 17: bad += 1
			else:
				for j in 4:
					if result[j*17] == 0: bad += 1
			at = Time.get_ticks_usec()
			var contact: PackedFloat64Array = native.call("sample_dynamic_contact_batch",targets,previous)
			warm.append((Time.get_ticks_usec()-at)/1000.0)
			if contact.size() != 4 * CS: bad += 1
			else:
				for j in 4: statuses[int(contact[j*CS+STATUS])] += 1
				previous = contact
		report.cold_world_N4_ms = _distribution(cold); report.warm_contact_N4_ms = _distribution(warm)
		report.cold_invalid = bad; report.contact_status_counts = statuses
	report.passed = report.cold_invalid == 0 and report.contact_status_counts[3] == 0
	return report

func _run() -> void:
	var ticks := int(_option("--ticks","3600")); var warmup := int(_option("--warmup","180"))
	var workers := int(_option("--workers","4")); var load_ms := float(_option("--load-ms","0"))
	var integrated := OS.get_cmdline_user_args().has("--integrated")
	var changing := OS.get_cmdline_user_args().has("--weather")
	var output := _option("--output","res://.godot/phys_target_performance.json")
	Engine.physics_ticks_per_second = 60
	_frame_values.resize(ticks*64*5) # Fixed capacity up to 3840 FPS; never caps rendering.
	var world: Node3D; var ocean: Node; var scene_contract := {}
	if integrated:
		world = WORLD.new(); root.add_child(world); ocean = world.call("physics_ocean"); scene_contract = world.call("contract")
	else:
		ocean = OCEAN_SCENE.instantiate(); ocean.set("coastal_bake",COASTAL_BAKE); ocean.set("coastal",true)
		for property in ["breakers","crest_foam","surface_foam"]: ocean.set(property,false)
		root.add_child(ocean)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(),true)
	process_frame.connect(_frame)
	for i in 20: await physics_frame
	ocean.set("wave_speed_multiplier",0.0)
	for i in 4: await physics_frame
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native == null or native.call("get_dynamic_async_build_id") != preload("res://validation/physics/phys_native_build_contract.gd").ID:
		_fail("target package native build ID"); return
	var initial: Array = fft.call("get_phys2_band_spectrum_snapshots")
	if not native.call("set_production_spectrum",initial):
		_fail("spectrum import"); return
	if not bool(ADAPTER.configure_coastal(native,fft.call("get_phys3_coastal_snapshot")).get("ok",false)):
		_fail("Coastal snapshot"); return
	native.call("set_dynamic_worker_count",workers)
	if int(native.call("get_dynamic_worker_count"))!=workers: _fail("requested worker count was not applied"); return
	if not native.call("start_dynamic_async_fields",ocean.call("get_wave_time"),0): _fail("field startup"); return
	_weather = WEATHER.new(native,fft)
	var targets := PackedVector3Array(); var history := PackedFloat64Array()
	for q in [Vector2(2000,-2000),Vector2(37.13506,81.04028),Vector2(175.65347,-915.52533),Vector2(-168.3,-652.48)]:
		var w := _world(native,q); targets.append(Vector3(w.x,0,w.y)); history.append_array(_state_at(native,q,w))
	ocean.set("wave_speed_multiplier",1.0)
	var builds: Array = []; var waits: Array = []; var contacts: Array = []
	var events: Array = []; var records: Array = []; var memory: Array = []; var stage_rows: Array = []
	var queries: Array = []; var polls: Array = []
	for array in [builds,waits,contacts,queries,polls,records,stage_rows]: array.resize(ticks)
	for i in ticks:
		records[i]={"tick":i,"age_ticks":0.0,"build_ms":null,"field_time":0.0,"production_time":0.0,"version":0,"generation":0,"alpha":0.0,"status_mask":0}
		var capture := PackedInt64Array(); capture.resize(29)
		stage_rows[i]={"tick":i,"profile_us":capture}
	for i in warmup:
		await physics_frame; _step(ocean,native)
	var counts := [0,0,0,0]
	var start_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	var mixed := 0; var backwards := 0; var bad := 0; var last_build := int(start_stats[3]); var last_time := -1.0
	_measuring = true
	for i in ticks:
		_measured_tick = i
		if changing and i % 600 == 0: events.append(_request_state(ocean,i / 600))
		await physics_frame
		var ready := _step(ocean,native)
		if not ready.is_empty():
			events.append({"tick": i,"ready": ready.get("ok",false),"serial": ready.get("serial",-1),"prepare_ms":ready.get("prepare_ms",null)})
			if not bool(ready.get("ok",false)): bad += 1
		var stats: PackedInt64Array = native.call("get_dynamic_async_stats")
		var age: float = _last_step.age; waits[i]=_last_step.wait_ms; queries[i]=_last_step.query_ms; polls[i]=_last_step.poll_ms
		if not bool(_last_step.valid): bad+=1
		var new_build := int(stats[3]) != last_build
		if new_build:
			builds[i]=stats[34]/1000.0; last_build = int(stats[3])
			var profile_us: PackedInt64Array = native.call("get_dynamic_async_profile_us")
			stage_rows[i].profile_us=profile_us
		var info: PackedInt64Array = native.call("get_dynamic_snapshot_info")
		var times: PackedInt64Array = native.call("get_dynamic_snapshot_band_times")
		if times.size()!=3 or times[0]!=times[1] or times[1]!=times[2]: mixed += 1
		var field_time := info[1]/1e9
		if field_time < last_time: backwards += 1
		last_time = field_time
		var at := Time.get_ticks_usec()
		var contact: PackedFloat64Array = native.call("sample_dynamic_contact_batch",targets,history)
		var contact_ms := (Time.get_ticks_usec()-at)/1000.0; contacts[i]=contact_ms
		var status_mask := 0
		if contact.size()!=4*CS: bad += 1
		else:
			for j in 4:
				var status := int(contact[j*CS+STATUS]); counts[status] += 1
				if contact[j*CS] == 0: bad += 1
				if contact[j*CS+WT]!=contact[WT] or contact[j*CS+21]!=contact[21] or contact[j*CS+22]!=contact[22]: mixed += 1
				status_mask |= 1 << status
			history = contact
		var record: Dictionary = records[i]
		record.age_ticks=age; record.build_ms=stats[34]/1000.0 if new_build else null; record.field_time=field_time
		record.production_time=ocean.call("get_wave_time"); record.version=info[3]; record.generation=info[4]; record.alpha=info[5]/1e9
		record.status_mask=status_mask
		if i % 60 == 0:
			var field_info: PackedInt64Array = native.call("get_dynamic_field_info")
			var node_count := field_info[0]*field_info[0]+field_info[1]*field_info[1]+field_info[2]*field_info[2]
			memory.append({"tick":i,"godot_static_bytes":Performance.get_monitor(Performance.MEMORY_STATIC),
				"godot_static_max_bytes":Performance.get_monitor(Performance.MEMORY_STATIC_MAX),"published_field_bytes":field_info[3],
				"packed_snapshot_payload_bytes_derived":node_count*6*16,"triple_field_bytes_derived":node_count*6*16*3,
				"triple_retained_H0_bytes_derived":node_count*4*4*3,"endpoint_difference_bytes_derived":node_count*6*8,
				"builder_spectra_scratch_bytes_derived":node_count*6*16*2,"builder_phase_evolved_bytes_derived":node_count*8*8,
				"resolution":[field_info[0],field_info[1],field_info[2]],"native_total_bytes":"process private bytes; payload estimates exclude Cascade/config objects and allocator overhead",
				"validation_capture_rows":[records.size(),stage_rows.size(),_frame_count],"validation_allocations":"tick/stage/frame storage preallocated before warmup; sparse weather events and memory rows reported separately"})
		if load_ms > 0: native.call("run_dynamic_contention_us",int(load_ms*1000.0))
	_measuring = false
	RenderingServer.call_on_render_thread(_render_barrier)
	await render_flushed
	var final_stats: PackedInt64Array = native.call("get_dynamic_async_stats")
	ocean.set("wave_speed_multiplier",0.0)
	for i in 40: await physics_frame; _step(ocean,native)
	var query_benchmark := _query_bench(native)
	var thirds: Array = []
	for range_start in [0,ticks*2/3]:
		var range_end: int = int(range_start) + ticks/3
		var selected: Array = records.filter(func(r): return r.tick>=range_start and r.tick<range_end)
		thirds.append({"ticks":[range_start,range_end],"build_ms":_distribution(selected.filter(func(r):return r.build_ms!=null).map(func(r):return r.build_ms)),
			"age_ticks":_distribution(selected.map(func(r):return r.age_ticks)),"renderer":_frame_distribution(range_start,range_end)})
	var recovery := {}
	for s in 4:
		var packet_times: Array = []
		for i in ticks:
			if (s==0 and records[i].status_mask==1) or (s>0 and (int(records[i].status_mask) & (1<<s))!=0): packet_times.append(contacts[i])
		recovery[["continued","local","global","failed"][s]] = {"contact_count":counts[s],"packet_ms":_distribution(packet_times),
			"scope":"all four continued" if s==0 else "whole packet containing recovery; isolated cost measured by contact-cost runner"}
	var report := {"schema_version":1,"build_id":native.call("get_dynamic_async_build_id"),"ticks":ticks,"warmup":warmup,
		"fft_configuration":initial.map(func(s):return {"N":s.resolution,"L_m":s.domain_size_m,"choppiness":s.get("choppiness",null)}),
		"workers":workers,"integrated_renderer":integrated,"weather":changing,"load_ms":load_ms,"scene_contract":scene_contract,
		"runtime":{"gpu":RenderingServer.get_video_adapter_name(),"api":RenderingServer.get_video_adapter_api_version(),"driver":RenderingServer.get_current_rendering_driver_name(),"renderer":RenderingServer.get_current_rendering_method()},
		"build_ms":_distribution(builds.filter(func(v):return v!=null)),"field_age_ticks":_distribution(records.map(func(r):return r.age_ticks)),
		"stale_ge_1":records.filter(func(r):return r.age_ticks>=1.0).size(),"stale_ge_2":records.filter(func(r):return r.age_ticks>=2.0).size(),
		"stale_ge_3":records.filter(func(r):return r.age_ticks>=3.0).size(),"main_wait_ms":_distribution(waits),
		"material_N1_in_loop_ms":_distribution(queries),"contact_N4_in_loop_ms":_distribution(contacts),
		"weather_poll_including_renderer_upload_ms":_distribution(polls),"weather_events":events,
		"query_benchmark":query_benchmark,"contacts":recovery,"first_final_third":thirds,"renderer":_frame_distribution(0,ticks),
		"memory":memory,"memory_leak_verdict":"review process_memory.json together with known harness capture growth; no unsupported automatic leak verdict",
		"requests":final_stats[1]-start_stats[1],"published":final_stats[4]-start_stats[4],"coalesced":final_stats[24]-start_stats[24],"missed_deadlines":final_stats[7]-start_stats[7],
		"mixed":mixed,"time_backwards":backwards,"invalid":bad,"oracle_in_timed_loop":false,"gpu_texture_readback":false,
		"frame_capture_overflow":_frame_overflow,"validation_frame_buffer_bytes":_frame_values.size()*8,
		"passed":mixed==0 and backwards==0 and bad==0 and _frame_overflow==0 and bool(query_benchmark.get("passed",false))}
	var f := FileAccess.open(output,FileAccess.WRITE)
	if f==null: _fail("cannot create target output"); return
	f.store_string(JSON.stringify(report,"\t")); f.close()
	f = FileAccess.open(output.trim_suffix(".json")+".tick_trace.json",FileAccess.WRITE); f.store_string(JSON.stringify(records)); f.close()
	f = FileAccess.open(output.trim_suffix(".json")+".stage_trace.json",FileAccess.WRITE); f.store_string(JSON.stringify(stage_rows)); f.close()
	_weather.call("shutdown"); _weather=null
	RenderingServer.call_on_render_thread(_render_barrier)
	await render_flushed
	native.call("clear")
	process_frame.disconnect(_frame)
	# Keep the renderer alive while the owned world's async RID retirement drains.
	if integrated: world.queue_free(); await world.tree_exited
	else: ocean.queue_free(); await ocean.tree_exited
	RenderingServer.call_on_render_thread(_render_barrier)
	await render_flushed
	print("TARGET_PERFORMANCE_COMPLETE="+JSON.stringify({"passed":report.passed,"ticks":ticks,"build_ms":report.build_ms,"age":report.field_age_ticks}))
	quit(0 if report.passed else 1)
