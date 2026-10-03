extends "res://validation/physics/phys_gpu1_runner.gd"
## Persistent hull contact proof. No forces or rigid bodies. World targets are
## hull trajectories; branch history is NOT fed back through CPU readback.
const SCENARIOS = ["stationary","slow","fast","acceleration","turning","lateral","crest","interior","boundary","fold","wrap","combined","reentry_cold","reentry_hint"]
const LAYOUTS = [[1,4],[1,8],[1,16],[4,8],[6,8],[10,8],[10,16],[16,16]]
var _proof := {"status":"PARTIAL","failures":[],"matrix":[],"stress":[],"bench":[],"oracle":[],"branches":[],"lifecycle":[]}
var _states:Array=[]
var _inbox:Dictionary={}
var _last_q:Dictionary={}
var _aggregate:Dictionary={}
var _records:Array=[]
var _reentry:Dictionary={}
var _simulation:=0.0
var _occupant:=1
var _current_case:Dictionary={}

func _run() -> void:
	load(DESCRIPTOR)
	if not ClassDB.class_exists("OceanQueryNative"): _fail("native unavailable"); return
	_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
	for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
	root.add_child(_ocean)
	var camera:=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current=true
	var light:=DirectionalLight3D.new(); root.add_child(light); light.rotation_degrees=Vector3(-45,-30,0)
	for _frame in 12: await process_frame
	_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT")
	_coastal=_fft.call("get_phys3_coastal_snapshot"); _query=_fft.call("enable_gpu_surface_queries")
	for _frame in 6: await process_frame
	var resource_only:=OS.get_cmdline_user_args().has("--resource-only")
	_query.set_validation_metrics_enabled(not resource_only)
	_proof["environment"]={"engine":Engine.get_version_info(),"driver":RenderingServer.get_current_rendering_driver_name(),"renderer":RenderingServer.get_current_rendering_method(),"gpu":RenderingServer.get_video_adapter_name(),"cpu":OS.get_processor_name()}
	_states=[{"name":"current","bands":_fft.call("get_phys2_band_spectrum_snapshots")}]
	for s in [["calm",0.8,4.0,20.0,0.8],["storm",3.0,18.0,75.0,2.0],["direction",3.0,18.0,20.0,2.0],["choppiness",3.0,18.0,20.0,2.5]]:
		var configs:Array=PROFILE.build_fft_configs(s[1],s[2],s[3],0.8,1.0); configs[0].choppiness=s[4]
		var builder:Object=ClassDB.instantiate("OceanQueryNative")
		var state:Dictionary=STATE.build(configs,1,s[1],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,builder)
		builder.call("prepare_production_spectrum",state.bands); _states.append({"name":s[0],"bands":state.bands,"native":builder})
	var current_builder:Object=ClassDB.instantiate("OceanQueryNative"); current_builder.call("prepare_production_spectrum",_states[0].bands); _states[0]["native"]=current_builder
	_native=_new_mirror(_states[0].bands,2.25)
	if not await _at(2.25): return
	if resource_only:
		await _trajectory(16,16,10000,true)
		_proof["ring"]=_metrics(_query.get_stats()); var resource_token:=_query; _ocean.queue_free()
		for _frame in 12: await process_frame
		_proof["after_shutdown"]=_metrics(resource_token.get_stats()); _proof.status="RESOURCE_ONLY"
		_native.call("clear"); _save(); print("GPU11_RESOURCE_COMPLETE"); quit(); return
	if OS.get_cmdline_user_args().has("--focused-only"):
		await _folded_continuation(); await _identity_and_reentry(); await _oracle_matrix()
		_native.call("clear"); _native=_new_mirror(_states[0].bands,2.25); await _at(2.25)
		await _benchmark()
		_proof["ring"]=_metrics(_query.get_stats()); var focused_token:=_query; _ocean.queue_free()
		for _frame in 12: await process_frame
		_proof["after_shutdown"]=_metrics(focused_token.get_stats()); _proof.status="FOCUSED_ONLY"
		_native.call("clear"); _save(); print("GPU11_FOCUSED_COMPLETE"); quit(); return
	await _folded_continuation()
	await _identity_and_reentry()
	await _oracle_matrix()
	await _benchmark()
	var smoke:=OS.get_cmdline_user_args().has("--smoke")
	for layout in LAYOUTS:
		await _trajectory(layout[0],layout[1],120 if smoke else 240,false)
	for layout in [[10,8],[16,16]]:
		await _trajectory(layout[0],layout[1],600 if smoke else 10000,true)
	await _diagnose_failures()
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/phys_gpu11_renderer.png")
	_proof["aggregate"]=_summarize_bins(_aggregate)
	_proof["failure_records"]=_records
	_proof["reentry"]=_reentry
	_proof["ring"]=_metrics(_query.get_stats())
	var token:=_query; _ocean.queue_free()
	for _frame in 12: await process_frame
	_proof["after_shutdown"]=_metrics(token.get_stats())
	if token.get_stats().owned_buffers!=0 or token.get_stats().in_flight!=0: _proof.failures.append("resources not drained")
	if token.get_stats().validation_capture_dropped!=0: _proof.failures.append("validation completion capture overflow")
	if _proof.oracle.size()!=1280: _proof.failures.append("oracle matrix incomplete")
	_proof.status="PASS" if _proof.failures.is_empty() and _records.is_empty() else "PARTIAL"
	_save(); print("GPU11_COMPLETE="+JSON.stringify({"status":_proof.status,"failed_contacts":_records.size(),"checks":_proof.failures,"aggregate":_proof.aggregate.get("all",{})})); quit()

func _contact_request(points:PackedVector2Array,descriptors:Array,compact:=false,validation_local:=false) -> Dictionary:
	var batch:Dictionary=QUERY.pack_contacts(points,descriptors)
	if validation_local:
		for i in points.size(): batch.controls.encode_u32(i*32+12,1)
	var generation:int=_query.submit_contacts(batch,Engine.get_physics_frames(),NAN,compact)
	if generation<0: _proof.failures.append("persistent submit rejected"); return {}
	for _frame in 180:
		await process_frame
		var result:Dictionary=_query.consume(Engine.get_physics_frames())
		if not result.is_empty() and result.generation==generation:
			_query.drain_validation_completed(); return result
	_proof.failures.append("persistent request timeout"); return {}

func _folded_continuation() -> void:
	var target:=Vector2(393.4588,-992.3107)
	var roots:=[Vector2(393.2003,-991.9864),Vector2(393.3454,-992.2997)]
	var failures:=0; var jumps:=0; var separation:=INF; var last:=roots.duplicate()
	var cpu_last:=roots.duplicate(); var cpu_failures:=0; var cpu_mismatches:=0
	var contact_previous:Array=[]; var contact_failures:=0; var contact_mismatches:=0
	for i in 2:
		var material:PackedFloat64Array=_native.call("sample_dynamic_material_q",roots[i].x,roots[i].y)
		var previous:=PackedFloat64Array(); previous.resize(27)
		for j in 15: previous[j]=material[j]
		previous[15]=roots[i].x; previous[16]=roots[i].y; previous[18]=target.x; previous[19]=target.y
		previous[20]=2.25; previous[25]=material[11]; contact_previous.append(previous)
	for step in 180:
		var points:=PackedVector2Array([target+Vector2(0.001,0.001)*sin(step*0.07),target+Vector2(0.001,0.001)*sin(step*0.07)])
		var descriptors:Array=[]
		for i in 2:
			var desc:Dictionary={"slot":i,"vehicle_id":1000+i,"contact_id":0,"generation":_occupant}
			if step==0: desc["owned_seed"]=true; desc["hint_q"]=roots[i]
			descriptors.append(desc)
		var result:=await _contact_request(points,descriptors)
		if result.is_empty(): return
		var qs:Array=[]
		for i in 2:
			var row:=_decode(result,i); qs.append(row.q)
			if not row.valid: failures+=1
			if row.q.distance_to(last[i])>0.02: jumps+=1
			var cpu:PackedFloat64Array=_native.call("sample_dynamic_world",points[i].x,points[i].y,cpu_last[i].x,cpu_last[i].y,true)
			if cpu[0]<0.5: cpu_failures+=1
			else:
				var cpu_q:=Vector2(cpu[15],cpu[16]); cpu_last[i]=cpu_q
				if cpu_q.distance_to(row.q)>0.01: cpu_mismatches+=1
			var cpu_contact:PackedFloat64Array=_native.call("sample_dynamic_contact",points[i].x,points[i].y,contact_previous[i])
			if cpu_contact[0]<0.5: contact_failures+=1
			else:
				contact_previous[i]=cpu_contact
				if Vector2(cpu_contact[15],cpu_contact[16]).distance_to(row.q)>0.01: contact_mismatches+=1
			last[i]=row.q
		separation=minf(separation,qs[0].distance_to(qs[1]))
	_proof.branches.append({"updates":360,"failures":failures,"jumps":jumps,"minimum_separation":separation,"initial":str(roots),"final":str(last),"time":2.25,"cpu_failures":cpu_failures,"cpu_root_mismatches":cpu_mismatches,"cpu_contact_failures":contact_failures,"cpu_contact_root_mismatches":contact_mismatches})
	if failures>0 or jumps>0 or separation<0.02: _proof.failures.append("folded owned branches not preserved")
	_occupant+=1

func _identity_and_reentry() -> void:
	for policy in ["cold","hint"]:
		for duration in [1,5,30]:
			var desc:Dictionary={"slot":0,"vehicle_id":2000,"contact_id":0,"generation":_occupant,"reset":true}
			var point:=Vector2(-240,-1300)
			var first:=await _contact_request(PackedVector2Array([point]),[desc]); var initial:=_decode(first,0)
			desc.erase("reset"); desc["active"]=false
			for tick in duration: await _contact_request(PackedVector2Array([point]),[desc])
			desc["active"]=true
			if policy=="hint": desc["retain_hint"]=true
			var result:=await _contact_request(PackedVector2Array([point+Vector2(0.03,0.02)]),[desc]); var row:=_decode(result,0)
			_proof.lifecycle.append({"policy":policy,"inactive_ticks":duration,"valid":row.valid,"status":row.status,"owned":row.owned,"residual":row.residual})
			if not row.valid or row.owned or row.status!=3: _proof.failures.append("reentry inherited branch")
			_occupant+=1
	# Same slot, new occupant with a distant target must acquire, never continue.
	var reuse:=await _contact_request(PackedVector2Array([Vector2(-900,-1600)]),[{"slot":0,"vehicle_id":9000,"contact_id":7,"generation":_occupant}])
	var row:=_decode(reuse,0)
	_proof.lifecycle.append({"slot_reuse":true,"status":row.status,"owned":row.owned,"valid":row.valid})
	if row.owned or not row.valid: _proof.failures.append("slot reuse leaked history")
	var teleport:=await _contact_request(PackedVector2Array([Vector2(-1500,-1800)]),[{"slot":0,"vehicle_id":9000,"contact_id":7,"generation":_occupant,"reset":true}])
	var teleported:=_decode(teleport,0)
	_proof.lifecycle.append({"teleport_reset":true,"status":teleported.status,"owned":teleported.owned,"valid":teleported.valid})
	if teleported.owned or not teleported.valid: _proof.failures.append("teleport inherited branch")
	# Per-contact invalidity must not poison the adjacent active hull contact.
	var mixed:=await _contact_request(PackedVector2Array([Vector2(-240,-1300),Vector2(-239,-1300)]),[
		{"slot":0,"vehicle_id":9001,"generation":_occupant+1,"active":false},{"slot":1,"vehicle_id":9001,"generation":_occupant+1}])
	var inactive:=_decode(mixed,0); var active:=_decode(mixed,1)
	_proof.lifecycle.append({"per_contact":true,"inactive_valid":inactive.valid,"active_valid":active.valid})
	if inactive.valid or not active.valid: _proof.failures.append("per-contact failure isolation")
	var malformed:=await _contact_request(PackedVector2Array([Vector2(NAN,0),Vector2(-239,-1300)]),[
		{"slot":0,"vehicle_id":9002,"generation":_occupant+2},{"slot":1,"vehicle_id":9002,"generation":_occupant+2}])
	var bad:=_decode(malformed,0); var good:=_decode(malformed,1)
	_proof.lifecycle.append({"invalid_input_isolation":true,"bad_valid":bad.valid,"bad_reason":bad.reason,"good_valid":good.valid})
	if bad.valid or bad.reason!=1 or not good.valid: _proof.failures.append("invalid input poisoned batch")
	var duplicate:=QUERY.pack_contacts(PackedVector2Array([Vector2.ZERO,Vector2.ONE]),[{"slot":0},{"slot":0}])
	if _query.submit_contacts(duplicate,0)>=0: _proof.failures.append("duplicate slot accepted")
	var persistent_packet:=QUERY.pack_contacts(PackedVector2Array([Vector2.ZERO]),[{"slot":0}])
	if _query.submit(persistent_packet.packet,0)>=0: _proof.failures.append("persistent packet missing controls accepted")
	_occupant+=2

func _oracle_matrix() -> void:
	# Exact snapshot waits are validation only. CPU and GPU own the same root.
	for state in _states:
		_native.call("clear"); _native=_new_mirror(state.bands,0.36)
		var previous:Array=[]
		for step in 16:
			var time:float=0.36+step/60.0
			if not await _at(time): return
			var targets:=PackedVector2Array(); var descriptors:Array=[]; var known:Array=[]
			for i in 16:
				var q:=Vector2(-240+i*0.11,-1300)+Vector2(step*0.02,step*0.01)
				if i>=8: q=Vector2(300+(i-8)*0.11,-600)+Vector2(step*0.01,0)
				var material:PackedFloat64Array=_native.call("sample_dynamic_material_q",q.x,q.y)
				targets.append(q+Vector2(material[2],material[4])); known.append(q)
				var desc:Dictionary={"slot":i,"vehicle_id":10000,"contact_id":i,"generation":_occupant}
				if step==0: desc["owned_seed"]=true; desc["hint_q"]=q
				descriptors.append(desc)
			var result:=await _contact_request(targets,descriptors)
			if result.is_empty(): return
			var next_cpu:Array=[]
			for i in 16:
				var row:=_decode(result,i); var material:PackedFloat64Array=_native.call("sample_dynamic_material_q",row.q.x,row.q.y)
				var prior:Vector2=known[i] if step==0 else previous[i]
				var cpu:PackedFloat64Array=_native.call("sample_dynamic_world",targets[i].x,targets[i].y,prior.x,prior.y,true)
				next_cpu.append(Vector2(cpu[15],cpu[16]) if cpu[0]>0.5 else prior)
				_proof.oracle.append({"state":state.name,"time":time,"index":i,"valid_gpu":row.valid,"valid_cpu":cpu[0]>0.5,"q_known":row.q.distance_to(known[i]),"q_cpu":row.q.distance_to(Vector2(cpu[15],cpu[16])),
					"residual_gpu":row.residual,"residual_cpu":cpu[13],"displacement_error":row.displacement.distance_to(Vector3(material[2],material[3],material[4])),"velocity_error":row.velocity.distance_to(Vector3(material[8],material[9],material[10])),
					"normal_angle":rad_to_deg(acos(clampf(row.normal.dot(Vector3(material[5],material[6],material[7])),-1,1))),"status":row.status})
				var latest:Dictionary=_proof.oracle[-1]
				if not row.valid or latest.displacement_error>0.001 or latest.velocity_error>0.001 or latest.normal_angle>0.5 or latest.q_known>0.01: _proof.failures.append("oracle physical mismatch")
			previous=next_cpu
		_occupant+=1

func _benchmark() -> void:
	for count in BATCHES:
		for mode in ["warm","local_forced_validation","cold"]:
			if mode!="cold":
				var initial_points:=PackedVector2Array(); var initial_descriptors:Array=[]
				for i in count:
					initial_points.append(Vector2(-240+(i%16)*0.1,-1300+(i/16)*0.1)); initial_descriptors.append({"slot":i,"vehicle_id":11000,"contact_id":i,"generation":_occupant})
				await _contact_request(initial_points,initial_descriptors)
			var before:Dictionary=_query.get_stats()
			var solver_counts:Dictionary={"continued":0,"local":0,"cold":0,"failed":0}
			var iterations:Array=[]; var residuals:Array=[]
			for step in 20:
				var points:=PackedVector2Array(); var descriptors:Array=[]
				for i in count:
					points.append(Vector2(-240+(i%16)*0.1+step*0.01,-1300+(i/16)*0.1))
					descriptors.append({"slot":i,"vehicle_id":11000,"contact_id":i,"generation":_occupant,"reset":mode=="cold"})
				var result:=await _contact_request(points,descriptors,false,mode=="local_forced_validation")
				if result.is_empty(): _proof.failures.append("benchmark missing result"); break
				for i in count:
					var row:=_decode(result,i)
					solver_counts[["unused","continued","local","cold","failed"][row.status]]+=1
					iterations.append(row.iterations); residuals.append(row.residual)
					if not row.valid: _proof.failures.append("benchmark invalid contact")
			var after:Dictionary=_query.get_stats(); var gpu:Array=[]
			for sample in after.gpu_samples.slice(before.gpu_samples.size()): gpu.append(sample.gpu_us)
			_proof.bench.append({"contacts":count,"mode":mode,"gpu_us":_distribution(gpu),"submit_us":_distribution(after.submit_us.slice(before.submit_us.size())),"consume_us":_distribution(after.consume_us.slice(before.consume_us.size())),
				"latency_ms":_distribution(after.latency_ms.slice(before.latency_ms.size())),"latency_ticks":_distribution(after.latency_ticks.slice(before.latency_ticks.size())),
				"solver_counts":solver_counts,"iterations":_distribution(iterations),"residual":_distribution(residuals)})
			_occupant+=1

func _layout(count:int) -> PackedVector2Array:
	if count==4: return PackedVector2Array([Vector2(-0.45,-1.15),Vector2(0.45,-1.15),Vector2(-0.50,1.05),Vector2(0.50,1.05)])
	var result:=PackedVector2Array()
	for i in count: result.append(Vector2(-0.48 if i%2==0 else 0.48,lerpf(-1.15,1.05,float(i/2)/float(count/2-1))))
	return result

func _pose(scenario:String,time:float,vehicle:int) -> Dictionary:
	var center:=Vector2(-260-vehicle*8,-1350-vehicle*3); var yaw:=0.0
	match scenario:
		"slow": center+=Vector2(2*time,0)
		"fast": center+=Vector2(24*time,0)
		"acceleration": center+=Vector2(50*sin(time*0.3),0)
		"turning": center+=Vector2(20*cos(time*0.4),20*sin(time*0.4)); yaw=time*0.4
		"lateral": center+=Vector2(0,30*sin(time*0.4))
		"crest": center=Vector2(time*8,100)
		"interior": center=Vector2(350,-550)+Vector2(12*sin(time*0.2),6*cos(time*0.2))
		"boundary": center=Vector2(_coastal.field_origin.x+2.5*sin(time*0.4),-520)
		"fold": center=Vector2(393.4588,-992.3107)+Vector2(0.001*sin(time*0.1),0.001*cos(time*0.1))
		"wrap": center=Vector2(-256+time*2,-37+time*0.2)
		"combined": center+=Vector2(30*cos(time*0.2),30*sin(time*0.2)); yaw=time*0.7
		"reentry_cold","reentry_hint": center+=Vector2(2*time,0); yaw=0.2*sin(time)
	return {"center":center,"yaw":yaw}

func _trajectory(vehicles:int,contacts:int,ticks:int,long_run:bool) -> void:
	_native.call("clear"); _native=_new_mirror(_states[0].bands,0)
	if not await _at(0.0): return
	_simulation=0.0; _aggregate={}; _inbox={}; _last_q={}
	var before:Dictionary=_query.get_stats(); var previous_state:=0; var weather:="current"
	_current_case={"vehicles":vehicles,"contacts":contacts,"ticks":ticks,"long":long_run}
	var trend:Array=[]; var pauses:Array=[]; var last_consumed:=0
	for tick in ticks:
		await physics_frame
		var paused:bool=long_run and tick>=5000 and tick<5200
		if not paused: _simulation+=1.0/60.0
		if long_run and tick in [1000,2000,4000,6000,8000]:
			var destination:int={1000:1,2000:2,4000:1,6000:3,8000:4}[tick]
			_native.call("transition_dynamic_spectrum",_states[previous_state].native,_states[destination].native,_simulation,3.0)
			weather=_states[previous_state].name+"->"+_states[destination].name; previous_state=destination
		_native.call("advance_dynamic_async",20000+tick,_simulation,_simulation,1.0/60.0)
		var published:Array=_native.call("get_dynamic_snapshot_spectrum",false)
		if published.size()==3: _fft.call("queue_dynamic_spectrum",_native,published)
		_fft.set("_wave_time",_simulation)
		var targets:=PackedVector2Array(); var descriptors:Array=[]; var contexts:Array=[]
		for vehicle in vehicles:
			var scenario:String=SCENARIOS[vehicle%SCENARIOS.size()]
			var pose:=_pose(scenario,_simulation,vehicle); var layout:=_layout(contacts)
			for contact in contacts:
				var slot_id:int=vehicle*contacts+contact
				var active:=true; var duration:=0
				if scenario.begins_with("reentry"):
					duration=[1,5,30][(tick/300)%3]; active=tick%300>=duration
				var desc:Dictionary={"slot":slot_id,"vehicle_id":vehicle,"contact_id":contact,"generation":_occupant,"active":active}
				if scenario=="reentry_hint" and tick%300==duration: desc["retain_hint"]=true
				targets.append(pose.center+layout[contact].rotated(pose.yaw)); descriptors.append(desc)
				contexts.append({"vehicle":vehicle,"contact":contact,"slot":slot_id,"scenario":scenario,"active":active,"reentry":scenario.begins_with("reentry") and tick%300==duration,"duration":duration,"weather":weather,"tick":tick,"target":targets[-1],"paused":paused})
		var generation:int=_query.submit_contacts(QUERY.pack_contacts(targets,descriptors),Engine.get_physics_frames(),NAN,tick%3==0)
		if generation<0: _proof.failures.append("trajectory submit rejected"); break
		_inbox[generation]=contexts
		# Deliberately withhold CPU consumption for ten ticks. GPU ownership still
		# continues; q is never put in the normal packet from _last_q.
		var withholding:bool=tick%1000>=700 and tick%1000<710
		if not withholding:
			var result:Dictionary=_query.consume(Engine.get_physics_frames())
			if not result.is_empty():
				last_consumed=int(result.generation)
		for captured in _query.drain_validation_completed(): _observe(captured,pauses)
		for key in _inbox.keys():
			if key<generation-32: _inbox.erase(key)
		if tick%1000==0:
			var stats:Dictionary=_query.get_stats(); trend.append({"tick":tick,"buffers":stats.owned_buffers,"state_buffers":stats.contact_state_buffers,"in_flight":stats.in_flight,"static_memory":OS.get_static_memory_usage()})
			print("GPU11_TRAJECTORY="+str(_current_case)+" tick="+str(tick)+" failures="+str(_records.size()))
	for _frame in 12:
		await process_frame; _query.consume(Engine.get_physics_frames())
		for captured in _query.drain_validation_completed(): _observe(captured,pauses)
	var after:Dictionary=_query.get_stats()
	var row:Dictionary=_current_case.duplicate(); row["bins"]=_summarize_bins(_aggregate); row["submitted"]=after.submitted-before.submitted; row["dispatched"]=after.dispatched-before.dispatched; row["completed"]=after.completed-before.completed; row["coalesced"]=after.coalesced-before.coalesced
	row["errors"]=after.errors-before.errors; row["mismatches"]=after.mismatches-before.mismatches; row["superseded"]=after.superseded_results-before.superseded_results; row["last_consumed"]=last_consumed; row["trend"]=trend; row["pause_times"]=_distribution(pauses)
	row["latency_ms"]=_distribution(after.latency_ms.slice(before.latency_ms.size())); row["latency_ticks"]=_distribution(after.latency_ticks.slice(before.latency_ticks.size()))
	(_proof.stress if long_run else _proof.matrix).append(row)
	_occupant+=1; _save()

func _observe(result:Dictionary,pauses:Array) -> void:
	if result.is_empty() or not _inbox.has(result.generation): return
	var contexts:Array=_inbox[result.generation]
	for i in int(result.count):
		var context:Dictionary=contexts[i]; var row:=_decode(result,i)
		if not context.active:
			if row.valid: _proof.failures.append("inactive became valid")
			continue
		_last_q[context.slot]=row.q
		if context.paused and context.tick>=5010 and context.tick<5190: pauses.append(result.sample_time)
		for label in ["all",context.scenario,"warm" if row.owned else "cold","weather/"+context.weather,"reentry" if context.reentry else "ongoing","WEATHER_TRANSITION" if result.weather_alpha>0 and result.weather_alpha<1 else "STEADY","config/"+str(result.config_version)]:
			var bin:Dictionary=_aggregate.get(label,{"updates":0,"continued":0,"local":0,"cold":0,"failed":0,"q_delta":{},"residual":{},"iterations":{},"reasons":{}})
			bin.updates+=1
			bin[["unused","continued","local","cold","failed"][row.status]]+=1
			_online_sample(bin.q_delta,row.delta); _online_sample(bin.residual,row.residual); _online_sample(bin.iterations,row.iterations)
			if not row.valid: bin.reasons[str(row.reason)]=int(bin.reasons.get(str(row.reason),0))+1
			_aggregate[label]=bin
		if context.reentry:
			var key:String=context.scenario+"/"+str(context.duration); var bin:Dictionary=_reentry.get(key,{"queries":0,"failed":0})
			bin.queries+=1
			if not row.valid: bin.failed+=1
			_reentry[key]=bin
		if not row.valid:
			var failure:Dictionary=context.duplicate(); failure["case"]=_current_case.duplicate(); failure["time"]=result.sample_time; failure["config"]=result.config_version; failure["alpha"]=result.weather_alpha
			failure["target_xy"]=[context.target.x,context.target.y]; failure["generation"]=result.generation; failure["previous_q"]=[row.previous.x,row.previous.y]; failure["final_q"]=[row.q.x,row.q.y]; failure["residual"]=row.residual; failure["iterations"]=row.iterations; failure["solves"]=row.solves; failure["reason"]=row.reason; failure["owned"]=row.owned; failure["det"]=row.det; failure["radius"]=row.radius
			_records.append(failure)
	_inbox.erase(result.generation)

func _decode(result:Dictionary,index:int) -> Dictionary:
	var bytes:PackedByteArray=result.bytes; var base:int=index*int(result.stride); var extra:int=base+(64 if result.compact else 96)
	return {"q":Vector2(bytes.decode_float(base),bytes.decode_float(base+4)),"residual":bytes.decode_float(base+8),"iterations":bytes.decode_float(base+12),"valid":bytes.decode_float(base+28)>0.5,
		"displacement":Vector3(bytes.decode_float(base+16),bytes.decode_float(base+20),bytes.decode_float(base+24)),"velocity":Vector3(bytes.decode_float(base+(32 if result.compact else 48)),bytes.decode_float(base+(36 if result.compact else 52)),bytes.decode_float(base+(40 if result.compact else 56))),
		"normal":Vector3(bytes.decode_float(base+(48 if result.compact else 64)),bytes.decode_float(base+(52 if result.compact else 68)),bytes.decode_float(base+(56 if result.compact else 72))),"det":bytes.decode_float(base+44),
		"status":bytes.decode_u32(extra),"solves":bytes.decode_u32(extra+4),"reason":bytes.decode_u32(extra+8),"owned":bytes.decode_u32(extra+12)!=0,
		"previous":Vector2(bytes.decode_float(extra+16),bytes.decode_float(extra+20)),"delta":bytes.decode_float(extra+24),"radius":bytes.decode_float(extra+28)}

func _summarize_bins(bins:Dictionary) -> Dictionary:
	var result:=bins.duplicate(true)
	for row in result.values():
		for key in ["q_delta","residual","iterations"]: row[key]=_online_summary(row[key])
	return result

func _online_sample(bin:Dictionary,value:float) -> void:
	if bin.is_empty(): bin.merge({"count":0,"sum":0.0,"squares":0.0,"max":0.0,"hist":{}})
	bin.count+=1; bin.sum+=value; bin.squares+=value*value; bin.max=maxf(bin.max,value)
	# Bounded logarithmic histogram. Quantiles are upper bounds (<=12.21%
	# relative bucket width); count/mean/RMS/max remain exact for finite inputs.
	var key:int=-240 if value<=0 else clampi(int(ceil(log(value)/log(10.0)*20.0)),-239,100)
	bin.hist[key]=int(bin.hist.get(key,0))+1

func _online_summary(bin:Dictionary) -> Dictionary:
	if bin.is_empty(): return {"count":0}
	var keys:Array=bin.hist.keys(); keys.sort(); var quantiles:Dictionary={}
	for fraction in [0.5,0.95,0.99]:
		var seen:=0
		for key in keys:
			seen+=int(bin.hist[key])
			if seen>=int(ceil(bin.count*fraction)):
				quantiles[{0.5:"p50",0.95:"p95",0.99:"p99"}[fraction]]=0.0 if key==-240 else pow(10.0,float(key)/20.0); break
	quantiles.merge({"count":bin.count,"mean":bin.sum/bin.count,"rms":sqrt(bin.squares/bin.count),"max":bin.max,"quantile_method":"bounded log histogram upper bound"})
	return quantiles

func _metrics(stats:Dictionary) -> Dictionary:
	var result:=stats.duplicate(true)
	for key in ["submit_us","consume_us","dispatch_cpu_us","latency_ms","latency_ticks","ocean_gpu_us"]: result[key]=_distribution(result[key])
	result.erase("gpu_samples"); return result

func _diagnose_failures() -> void:
	_proof["diagnostic_probes"]=[]
	var selected:Dictionary={}
	for failure in _records:
		var key:String=failure.scenario+"/"+str(failure.owned)+"/"+str(failure.reason)+"/"+str(failure.config)
		if selected.has(key): continue
		selected[key]=true
		var config:int=failure.config
		var sources:Array=[0,0,1,2,1,3]; var destinations:Array=[0,0,1,2,1,3,4]
		var starts:Array=[0.0,0.0,1001.0/60.0,2001.0/60.0,4001.0/60.0,5801.0/60.0,7801.0/60.0]
		var destination:int=destinations[mini(config,6)]
		_native.call("clear"); _native=_new_mirror(_states[sources[mini(config-1,5)]].bands,float(failure.time))
		if config>1: _native.call("transition_dynamic_spectrum",_states[sources[mini(config-1,5)]].native,_states[destination].native,starts[mini(config,6)],3.0)
		if not await _at(float(failure.time)): return
		var target:=Vector2(failure.target_xy[0],failure.target_xy[1]); var previous:=Vector2(failure.previous_q[0],failure.previous_q[1])
		var targets:=PackedVector2Array(); var seeds:=PackedVector2Array()
		for center in [previous,target]:
			for delta in [Vector2.ZERO,Vector2(0.05,0),Vector2(-0.05,0),Vector2(0,0.05),Vector2(0,-0.05),Vector2(0.25,0),Vector2(-0.25,0),Vector2(0,0.25),Vector2(0,-0.25)]:
				targets.append(target); seeds.append(center+delta)
		var result:=await _request(targets,true,seeds,false,float(failure.time))
		var valid_roots:=0; var closest:=INF; var minimum:=INF
		for i in seeds.size():
			var residual:float=result.bytes.decode_float(i*96+8); minimum=minf(minimum,residual)
			if result.bytes.decode_float(i*96+28)>0.5:
				valid_roots+=1; closest=minf(closest,Vector2(result.bytes.decode_float(i*96),result.bytes.decode_float(i*96+4)).distance_to(previous))
		var cpu:PackedFloat64Array=_native.call("sample_dynamic_world",target.x,target.y,previous.x,previous.y,true)
		_proof.diagnostic_probes.append({"key":key,"failure":failure,"seeds":seeds.size(),"unguarded_gpu_valid_seeds":valid_roots,"nearest_root_to_previous":closest,"minimum_residual":minimum,"cpu_warm_valid":cpu[0]>0.5,"cpu_residual":cpu[13]})
		if selected.size()>=48: break

func _save() -> void:
	var path:String="res://.godot/phys_gpu11_resource.json" if OS.get_cmdline_user_args().has("--resource-only") else "res://.godot/phys_gpu11_results.json"
	if OS.get_cmdline_user_args().has("--focused-only"): path="res://.godot/phys_gpu11_focused.json"
	var file:=FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(_proof)); file.close()
