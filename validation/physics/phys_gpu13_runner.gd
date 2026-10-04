extends "res://validation/physics/phys_gpu12_diagnostics.gd"
## Validation only: physical envelope samples never seed production history.
var _physical_proof:Dictionary={"phase":"PHYS-GPU-1.3","starting_head":"641c856","status":"PARTIAL","checks":[],"depth":[],"envelope_cases":[],"bench":[],"matrix":[],"stress":[],"oracle":[],"branches":[]}
var _envelope_ledger:Array=[]
var _executed:Dictionary={}
var _handoff_history:Dictionary={}
var _chatter:Dictionary={"handoffs":0,"immediate_reversals":0,"max_per_slot_second":0,"windows":{}}

func _run() -> void:
	load(DESCRIPTOR)
	if not ClassDB.class_exists("OceanQueryNative"):
		_physical_proof.checks.append("native unavailable"); _save(); quit(1); return
	_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
	for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
	root.add_child(_ocean)
	var camera:=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current=true
	var light:=DirectionalLight3D.new(); root.add_child(light); light.rotation_degrees=Vector3(-45,-30,0)
	for _frame in 12: await process_frame
	_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT")
	_coastal=_fft.call("get_phys3_coastal_snapshot"); _query=_fft.call("enable_gpu_surface_queries")
	for _frame in 6: await process_frame
	if _query==null or not _query.get_stats().ready:
		_physical_proof.checks.append("query initialization failed"); _save(); quit(1); return
	_query.set_validation_metrics_enabled(not (OS.get_cmdline_user_args().has("--resource-only") or OS.get_cmdline_user_args().has("--lifecycle")))
	_states=[{"name":"current","bands":_fft.call("get_phys2_band_spectrum_snapshots")}]
	for s in [["calm",0.8,4.0,20.0,0.8],["storm",3.0,18.0,75.0,2.0],["direction",3.0,18.0,20.0,2.0],["choppiness",3.0,18.0,20.0,2.5]]:
		var configs:Array=PROFILE.build_fft_configs(s[1],s[2],s[3],0.8,1.0); configs[0].choppiness=s[4]
		var builder:Object=ClassDB.instantiate("OceanQueryNative")
		var state:Dictionary=STATE.build(configs,1,s[1],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,builder)
		builder.call("prepare_production_spectrum",state.bands); _states.append({"name":s[0],"bands":state.bands,"native":builder})
	var current:Object=ClassDB.instantiate("OceanQueryNative"); current.call("prepare_production_spectrum",_states[0].bands); _states[0]["native"]=current
	_physical_proof["environment"]={"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"cpu":OS.get_processor_name(),"driver":RenderingServer.get_current_rendering_driver_name(),"renderer":RenderingServer.get_current_rendering_method()}
	_physical_proof["source_hashes"]={"shader":FileAccess.get_sha256("res://addons/ocean/physics/gpu/ocean_surface_query.glsl"),"wrapper":FileAccess.get_sha256("res://addons/ocean/physics/gpu/ocean_surface_query.gd"),"runner":FileAccess.get_sha256("res://validation/physics/phys_gpu13_runner.gd")}
	var args:=OS.get_cmdline_user_args()
	if args.has("--resource-only"):
		await _trajectory(16,16,10000,true)
	elif args.has("--lifecycle"):
		await _physical_lifecycle()
	elif args.has("--envelope-replay"):
		await _replay_envelope_ledger()
	elif args.has("--old-replay"):
		await _old_reclassification()
	elif args.has("--ties"):
		await _physical_ties()
	elif args.has("--bench-only"):
		await _snapshot(1,2.25,true); await _physical_benchmark()
	elif args.has("--success-bench"):
		await _successful_handoff_benchmark()
	elif args.has("--current12-replay"):
		await _current12_reclassification()
	elif args.has("--reentry10"):
		await _successful_handoff_depth()
		await _trajectory(10,8,10000,true)
	elif args.has("--reentry10-envelope"):
		await _replay_envelope_ledger()
	else:
		if args.has("--trajectory-only"):
			_physical_proof=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu13_full.json"))
			_physical_proof.matrix=[]; _physical_proof.stress=[]; _physical_proof.checks=[]
		elif not await _snapshot(1,2.25,true): _physical_proof.checks.append("setup snapshot failed")
		else:
			await _depth_samples(); await _physical_fold(); await _physical_identity()
			if not args.has("--smoke"):
				await _folded_continuation(); await _oracle_matrix()
				_physical_proof["numerical_regression"]=_proof.branches
				_physical_proof.oracle=_proof.oracle
				_snapshot_config=-1; await _snapshot(1,2.25,true)
				await _physical_benchmark()
		if args.has("--full") or args.has("--resource-smoke"):
			for layout in LAYOUTS: await _trajectory(layout[0],layout[1],240,false)
			for layout in [[10,8],[16,16]]: await _trajectory(layout[0],layout[1],10000,true)
	_physical_proof.checks.append_array(_proof.failures)
	_physical_proof["ring"]=_metrics(_query.get_stats()); var token:=_query
	if is_instance_valid(_ocean): _ocean.queue_free()
	for _frame in 12: await process_frame
	_physical_proof["after_shutdown"]=_metrics(token.get_stats())
	if _native!=null: _native.call("clear")
	_physical_proof["chatter"]=_chatter; _physical_proof["reentry"]=_reentry
	_save(); print("GPU13_COMPLETE="+JSON.stringify({"checks":_physical_proof.checks,"depth_count":_physical_proof.depth.size(),"envelope_cases":_physical_proof.envelope_cases.size(),"captured":_envelope_ledger.size()})); quit(0 if _physical_proof.checks.is_empty() else 1)

func _physical_request(points:PackedVector3Array,descriptors:Array,compact:=false,force_acquire:=false) -> Dictionary:
	var batch:=QUERY.pack_physical_contacts(points,descriptors)
	if force_acquire:
		for i in points.size(): batch.controls.encode_u32(i*32+12,1)
	var generation:int=_query.submit_contacts(batch,Engine.get_physics_frames(),NAN,compact)
	if generation<0: _physical_proof.checks.append("physical submit rejected"); return {}
	for _frame in 180:
		await process_frame
		var result:Dictionary=_query.consume(Engine.get_physics_frames())
		if not result.is_empty() and result.generation==generation:
			_query.drain_validation_completed(); return result
	_physical_proof.checks.append("physical request timeout"); return {}

func _depth_samples() -> void:
	var qs:=[Vector2(-300,-1200),Vector2(350,-550)]
	for region in qs.size():
		var material:=_material(qs[region].x,qs[region].y)
		var points:=PackedVector3Array(); var descriptors:Array=[]
		for offset in [0.1,0.0,-0.1]:
			points.append(Vector3(qs[region].x+material[2],material[1]+offset,qs[region].y+material[4]))
			descriptors.append({"slot":points.size()-1,"vehicle_id":100+region,"generation":_occupant,"reset":true})
		for compact in [false,true]:
			var result:=await _physical_request(points,descriptors,compact)
			if result.is_empty(): return
			for i in points.size():
				var row:=QUERY.decode_physical_contact(result,i)
				var error:float=absf(row.signed_depth-([-0.1,0.0,0.1][i]))
				_physical_proof.depth.append({"region":"open" if region==0 else "Coastal","compact":compact,"expected":[-0.1,0.0,0.1][i],"result":row,"error":error})
				if not row.valid or error>0.001: _physical_proof.checks.append("signed depth regression")
				if row.solves>5 or row.iterations>80: _physical_proof.checks.append("physical budget exceeded")
		_occupant+=1

func _json_value(value:Variant) -> Variant:
	if value is Vector2: return [value.x,value.y]
	if value is Vector3: return [value.x,value.y,value.z]
	if value is Dictionary:
		var result:Dictionary={}
		for key in value: result[key]=_json_value(value[key])
		return result
	if value is Array:
		var result:Array=[]
		for item in value: result.append(_json_value(item))
		return result
	if value is float and not is_finite(value): return null
	return value

func _envelope_reference(target:Vector2,anchor:Vector2,additional:Array=[]) -> Dictionary:
	var started:=Time.get_ticks_usec()
	var positions:=PackedVector3Array(); var seeds:=PackedVector3Array()
	for center in [target,anchor]:
		for ix in range(-8,9):
			for iz in range(-8,9):
				var q:Vector2=center+Vector2(ix,iz)*0.25
				positions.append(Vector3(target.x,0,target.y)); seeds.append(Vector3(q.x,0,q.y))
		for radius in [0.05,0.1,0.5,1.0,2.0,4.0,8.0]:
			for i in 16:
				var q:Vector2=center+Vector2.from_angle(i*TAU/16)*radius
				positions.append(Vector3(target.x,0,target.y)); seeds.append(Vector3(q.x,0,q.y))
	var sampled:PackedFloat64Array=_native.call("sample_dynamic_world_batch",positions,seeds,true)
	var rough:Array=additional.duplicate(true); var roots:Array=[]
	for i in seeds.size():
		if sampled[i*17+13]>0.05: continue
		var q:=[sampled[i*17+15],sampled[i*17+16]]
		var duplicate:=false
		for old in rough:
			if sqrt(pow(old[0]-q[0],2)+pow(old[1]-q[1],2))<0.002: duplicate=true; break
		if not duplicate: rough.append(q)
	for q in rough:
		var root:=_correct(q[0],q[1],target.x,target.y,0.1,48,0.000001)
		if not root.valid: continue
		var duplicate:=false
		for old in roots:
			if sqrt(pow(old.q[0]-root.q[0],2)+pow(old.q[1]-root.q[1],2))<0.002: duplicate=true; break
		if duplicate: continue
		var material:=_material(root.q[0],root.q[1])
		root["world"]=[root.q[0]+material[2],material[1],root.q[1]+material[4]]
		root["normal"]=[material[5],material[6],material[7]]
		root["distance_from_previous"]=sqrt(pow(root.q[0]-anchor.x,2)+pow(root.q[1]-anchor.y,2))
		roots.append(root)
	var highest:Dictionary={}
	for root in roots:
		if highest.is_empty() or root.height>highest.height: highest=root
	return {"target":[target.x,target.y],"anchor":[anchor.x,anchor.y],"seeds":seeds.size(),"roots":roots,"envelope":highest,"elapsed_us":Time.get_ticks_usec()-started,"method":"802 deterministic native warm seeds plus strict 1 micrometre refinement; strong discovery, not exhaustive global topology proof"}

func _envelope_reference_gpu(target:Vector2,anchor:Vector2,additional:Array=[]) -> Dictionary:
	var rows:=await _reference_many([{"target":target,"anchor":anchor,"additional":additional}])
	return rows[0] if not rows.is_empty() else {}

func _reference_many(cases:Array) -> Array:
	# Same authoritative field, asynchronous ring; packets never alter contact state.
	var started:=Time.get_ticks_usec()
	var points:=PackedVector2Array(); var seeds:=PackedVector2Array(); var owners:Array=[]
	var references:Array=[]
	for index in cases.size():
		var case:Dictionary=cases[index]; var target:Vector2=case.target; var anchor:Vector2=case.anchor
		var start:=points.size()
		for center in [target,anchor]:
			for ix in range(-8,9):
				for iz in range(-8,9): points.append(target); seeds.append(center+Vector2(ix,iz)*0.25); owners.append(index)
			for radius in [0.05,0.1,0.5,1.0,2.0,4.0,8.0]:
				for i in 16: points.append(target); seeds.append(center+Vector2.from_angle(i*TAU/16)*radius); owners.append(index)
		for q in case.get("additional",[]):
			points.append(target); seeds.append(Vector2(q[0],q[1])); owners.append(index)
		references.append({"target":target,"anchor":anchor,"seeds":points.size()-start,"roots":[],"envelope":{},"method":"802 deterministic GPU validation seeds plus supplied discovered roots; 48 fine iterations, 1 micrometre residual. Strong bounded discovery, not a global completeness certificate."})
	var next:=0; var outstanding:Dictionary={}; var completed:=0; var frames:=0
	while completed<points.size() and frames<maxi(600,points.size()*4):
		# One submission per rendered frame avoids replacing a pending packet.
		var stats:Dictionary=_query.get_stats()
		if next<points.size() and stats.in_flight<3 and stats.pending==0:
			var end:=mini(next+1024,points.size())
			var generation:int=_query.submit(QUERY.pack_envelope_validation_queries(points.slice(next,end),seeds.slice(next,end)),Engine.get_physics_frames())
			if generation<0: _physical_proof.checks.append("oracle packet rejected"); break
			outstanding[generation]=[next,end]; next=end
		await process_frame; frames+=1; _query.consume(Engine.get_physics_frames())
		for packet in _query.drain_validation_completed():
			if not outstanding.has(packet.generation): continue
			var range_pair:Array=outstanding[packet.generation]; outstanding.erase(packet.generation)
			for i in int(packet.count):
				var index:int=owners[range_pair[0]+i]; var b:PackedByteArray=packet.bytes; var base:=i*96
				if b.decode_float(base+28)<0.5: continue
				var q:=Vector2(b.decode_float(base),b.decode_float(base+4)); var height:=b.decode_float(base+36)
				var duplicate:=false
				for root in references[index].roots:
					if root.q.distance_to(q)<0.0001 and absf(root.height-height)<0.0005: duplicate=true; break
				if duplicate: continue
				# The GPU's actual field determines validity. CPU refinement cannot
				# veto a root near a caustic because the fields differ by roundoff.
				var root:Dictionary={"q":q,"height":height,"residual":b.decode_float(base+8),"valid":true,"world":Vector3(b.decode_float(base+32),height,b.decode_float(base+40)),"normal":Vector3(b.decode_float(base+64),b.decode_float(base+68),b.decode_float(base+72)),"det":b.decode_float(base+44)}
				root["distance_from_previous"]=q.distance_to(cases[index].anchor)
				references[index].roots.append(root)
			completed+=range_pair[1]-range_pair[0]
	if completed!=points.size(): _physical_proof.checks.append("oracle incomplete "+str(completed)+"/"+str(points.size()))
	for ref in references:
		for root in ref.roots:
			if ref.envelope.is_empty() or root.height>ref.envelope.height: ref.envelope=root
		ref["elapsed_us_shared"]=Time.get_ticks_usec()-started
	return references

func _validate_envelope(row:Dictionary,ref:Dictionary) -> Dictionary:
	var roots:Array=ref.get("roots",[]); var max_y:float=-INF
	for root in roots: max_y=maxf(max_y,root.height)
	var wrong:bool=row.valid and is_finite(max_y) and row.surface_y<max_y-0.002
	var miss:bool=not row.valid and not roots.is_empty()
	var matching:=false
	for root in roots:
		if row.valid and row.q.distance_to(root.q)<0.02 and absf(row.surface_y-root.height)<0.002: matching=true
	return {"wrong_lower_sheet":wrong,"bounded_candidate_miss":miss,"selected_matches_discovered_root":matching,"height_gap":max_y-row.surface_y if row.valid and is_finite(max_y) else null,"reference_roots":roots.size(),"max_y":max_y}

func _physical_fold() -> void:
	var target:=Vector2(393.4588,-992.3107)
	var anchor:=Vector2(393.2003,-991.9864)
	var samples:Array=[]; var cases:Array=[]
	for step in 180:
		var xz:=target+Vector2(0.001,0.001)*sin(step*0.07)
		var points:=PackedVector3Array([Vector3(xz.x,0.2,xz.y),Vector3(xz.x,-0.2,xz.y)])
		var descriptors:Array=[]
		for i in 2:
			var descriptor:Dictionary={"slot":i,"vehicle_id":12000+i,"contact_id":0,"generation":_occupant}
			if step==0: descriptor.merge({"owned_seed":true,"hint_q":anchor if i==0 else Vector2(393.3454,-992.2997)})
			descriptors.append(descriptor)
		var result:=await _physical_request(points,descriptors,step%3==0)
		if result.is_empty(): return
		var rows:Array=[]
		for i in 2:
			var row:=QUERY.decode_physical_contact(result,i); rows.append(row)
			if row.solves>5 or row.iterations>80: _physical_proof.checks.append("fold production budget")
		samples.append({"step":step,"rows":rows}); cases.append({"target":xz,"anchor":anchor})
	var refs:=await _reference_many(cases)
	for index in samples.size():
		for row in samples[index].rows: row["envelope_check"]=_validate_envelope(row,refs[index])
		samples[index]["reference"]=refs[index]
	_physical_proof.branches.append({"kind":"PHYSICAL_UPPER_ENVELOPE","updates":360,"samples":samples})
	# Above/on/below and handoff all use the SAME highest-sheet reference.
	var ref:Dictionary=refs[0]
	if not ref.envelope.is_empty():
		for acquisition in ["cold","handoff"]:
			var points:=PackedVector3Array(); var descriptors:Array=[]
			for delta in [0.1,0.0,-0.1]:
				points.append(Vector3(target.x,ref.envelope.height+delta,target.y))
				var descriptor:Dictionary={"slot":points.size()-1,"vehicle_id":12100,"generation":_occupant+1,"reset":acquisition=="cold"}
				if acquisition=="handoff": descriptor.merge({"owned_seed":true,"hint_q":Vector2(393.3454,-992.2997)})
				descriptors.append(descriptor)
			for compact in [false,true]:
				var result:=await _physical_request(points,descriptors,compact)
				if result.is_empty(): return
				for i in points.size():
					var row:=QUERY.decode_physical_contact(result,i)
					var formula_error:float=absf(row.signed_depth-(row.surface_y-points[i].y))
					_physical_proof.depth.append({"region":"fold "+acquisition,"compact":compact,"expected":[-0.1,0.0,0.1][i],"result":row,"error":absf(row.signed_depth-[-0.1,0.0,0.1][i]),"formula_error":formula_error,"envelope_check":_validate_envelope(row,ref)})
					if formula_error>0.000001: _physical_proof.checks.append("fold signed depth formula")
	_occupant+=2

func _physical_identity() -> void:
	var points:=PackedVector3Array([Vector3(-240,0.1,-1300)])
	var base:Dictionary={"slot":0,"vehicle_id":13000,"contact_id":3,"generation":_occupant}
	var rows:Array=[]
	var first:=await _physical_request(points,[base])
	rows.append({"test":"cold","result":QUERY.decode_physical_contact(first,0),"expected_owned":false})
	var continued:=await _physical_request(points,[base])
	rows.append({"test":"continued","result":QUERY.decode_physical_contact(continued,0),"expected_owned":true})
	for action in ["inactive","reset","occupant"]:
		var skipped:=base.duplicate()
		if action=="inactive": skipped["active"]=false
		elif action=="reset": skipped["reset"]=true
		else: skipped["vehicle_id"]=13001
		_query.submit_contacts(QUERY.pack_physical_contacts(points,[skipped]),Engine.get_physics_frames())
		var next:=await _physical_request(points,[base])
		rows.append({"test":"coalesced "+action,"result":QUERY.decode_physical_contact(next,0),"expected_owned":false})
	for gap in [1,5,30]:
		var inactive:=base.duplicate(); inactive["active"]=false
		for frame in gap:
			var packet:=await _physical_request(points,[inactive])
			if QUERY.decode_physical_contact(packet,0).valid: _physical_proof.checks.append("physical inactive valid")
		var hint:=base.duplicate(); hint["retain_hint"]=true
		var reentry:=await _physical_request(points,[hint])
		rows.append({"test":"reentry hint "+str(gap),"result":QUERY.decode_physical_contact(reentry,0),"expected_owned":false})
	for action in ["reset","generation","vehicle_id","contact_id"]:
		var descriptor:=base.duplicate()
		if action=="reset": descriptor["reset"]=true
		else: descriptor[action]=int(descriptor[action])+1
		var result:=await _physical_request(points,[descriptor])
		rows.append({"test":action,"result":QUERY.decode_physical_contact(result,0),"expected_owned":false})
		await _physical_request(points,[base])
	var teleport_descriptor:=base.duplicate(); teleport_descriptor["reset"]=true
	var teleported:=await _physical_request(PackedVector3Array([Vector3(350,0.1,-550)]),[teleport_descriptor])
	rows.append({"test":"teleport reset","result":QUERY.decode_physical_contact(teleported,0),"expected_owned":false})
	var malformed:=await _physical_request(PackedVector3Array([Vector3(-240,NAN,-1300)]),[base])
	if QUERY.decode_physical_contact(malformed,0).valid: _physical_proof.checks.append("nonfinite physical Y valid")
	_query.set_validation_metrics_enabled(false)
	if _query.submit(QUERY.pack_envelope_validation_queries(PackedVector2Array([Vector2.ZERO]),PackedVector2Array([Vector2.ZERO])),0)>=0: _physical_proof.checks.append("production envelope diagnostic mode accepted")
	var diagnostic:=base.duplicate(); diagnostic["owned_seed"]=true; diagnostic["hint_q"]=Vector2.ZERO
	if _query.submit_contacts(QUERY.pack_physical_contacts(points,[diagnostic]),0)>=0: _physical_proof.checks.append("production physical owned seed accepted")
	_query.set_validation_metrics_enabled(true)
	for item in rows:
		if item.has("expected_owned") and item.result.owned!=item.expected_owned: _physical_proof.checks.append("physical ownership "+item.test)
		if not item.result.valid: _physical_proof.checks.append("identity ordinary invalid "+item.test)
	var reference:=await _envelope_reference_gpu(Vector2(points[0].x,points[0].z),Vector2(points[0].x,points[0].z))
	for item in rows:
		if item.test!="teleport reset": item["envelope_check"]=_validate_envelope(item.result,reference)
	_physical_proof["identity"]=rows; _physical_proof["identity_reference"]=reference; _occupant+=2

func _physical_benchmark() -> void:
	var reference:=await _envelope_reference_gpu(Vector2(393.4588,-992.3107),Vector2(393.2003,-991.9864))
	for frame in 6: await process_frame
	for count in [1,80,256]:
		for mode in (["one_handoff"] if count==1 else ["ordinary","mixed_one_handoff","exceptional"]):
			var iterations:Array=[]; var solves:Array=[]; var counts:Dictionary={"continued":0,"handoff":0,"cold":0,"failed":0}
			var wrong:=0; var misses:=0
			var before:Dictionary=_query.get_stats()
			for step in 24:
				var points:=PackedVector3Array(); var descriptors:Array=[]
				for i in count:
					var exceptional:bool=mode in ["exceptional","one_handoff"] or (mode=="mixed_one_handoff" and i==count-1)
					var xz:=Vector2(393.4588,-992.3107) if exceptional else Vector2(-240+(i%16)*0.1+step*0.001,-1300+(i/16)*0.1)
					points.append(Vector3(xz.x,0.1,xz.y))
					var descriptor:Dictionary={"slot":i,"vehicle_id":14000,"contact_id":i,"generation":_occupant}
					if exceptional: descriptor.merge({"owned_seed":true,"hint_q":Vector2(393.3454,-992.2997)})
					descriptors.append(descriptor)
				var result:=await _physical_request(points,descriptors)
				if result.is_empty(): return
				for i in count:
					var row:=QUERY.decode_physical_contact(result,i)
					iterations.append(row.iterations); solves.append(row.solves)
					counts[{"1":"continued","3":"cold","4":"failed","5":"handoff"}[str(row.status)]]+=1
					if mode in ["exceptional","one_handoff"] or (mode=="mixed_one_handoff" and i==count-1):
						var check:=_validate_envelope(row,reference); wrong+=int(check.wrong_lower_sheet); misses+=int(check.bounded_candidate_miss)
					if row.solves>5 or row.iterations>80: _physical_proof.checks.append("benchmark budget")
				for frame in 6: await process_frame
			var after:Dictionary=_query.get_stats(); var times:Array=[]
			for sample in after.gpu_samples.slice(before.gpu_samples.size()): times.append(sample.gpu_us)
			_physical_proof.bench.append({"contacts":count,"mode":mode,"gpu_us":_distribution(times),"iterations":_distribution(iterations),"solves":_distribution(solves),"statuses":counts,"wrong_sheet":wrong,"oracle_supported_misses":misses,"reference":reference})
			_occupant+=1

func _trajectory(vehicles:int,contacts:int,ticks:int,long_run:bool) -> void:
	if _native!=null: _native.call("clear")
	_native=_new_mirror(_states[0].bands,0)
	if not await _at(0.0): return
	_simulation=0.0; _aggregate={}; _inbox={}; _last_q={}; _executed={}; _handoff_history={}
	var before:Dictionary=_query.get_stats(); var previous_state:=0; var weather:="current"
	_current_case={"vehicles":vehicles,"contacts":contacts,"ticks":ticks,"long":long_run}
	if OS.get_cmdline_user_args().has("--reentry10"): _current_case["variant"]="stationary reentry overlay; authored XZ poses unchanged"
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
		var targets:=PackedVector3Array(); var descriptors:Array=[]; var contexts:Array=[]
		for vehicle in vehicles:
			var scenario:String=SCENARIOS[vehicle%SCENARIOS.size()]
			var pose:=_pose(scenario,_simulation,vehicle); var layout:=_layout(contacts)
			for contact in contacts:
				var slot_id:int=vehicle*contacts+contact
				var active:=true; var duration:=0
				var reentry:bool=scenario.begins_with("reentry") or (OS.get_cmdline_user_args().has("--reentry10") and vehicle==0)
				if reentry:
					duration=[1,5,30][(tick/300)%3]; active=tick%300>=duration
				var desc:Dictionary={"slot":slot_id,"vehicle_id":vehicle,"contact_id":contact,"generation":_occupant,"active":active}
				if scenario=="reentry_hint" and tick%300==duration: desc["retain_hint"]=true
				var xz:Vector2=pose.center+layout[contact].rotated(pose.yaw)
				targets.append(Vector3(xz.x,0.15+0.05*sin(_simulation*0.7+vehicle),xz.y)); descriptors.append(desc)
				contexts.append({"vehicle":vehicle,"contact":contact,"slot":slot_id,"scenario":"stationary_reentry" if reentry and scenario=="stationary" else scenario,"active":active,"reentry":reentry and tick%300==duration,"duration":duration,"weather":weather,"tick":tick,"target":targets[-1],"paused":paused})
		var generation:int=_query.submit_contacts(QUERY.pack_physical_contacts(targets,descriptors),Engine.get_physics_frames(),NAN,tick%3==0)
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
			print("GPU13_TRAJECTORY="+str(_current_case)+" tick="+str(tick)+" protocol_checks="+str(_physical_proof.checks.size()+_proof.failures.size()))
	for _frame in 12:
		await process_frame; _query.consume(Engine.get_physics_frames())
		for captured in _query.drain_validation_completed(): _observe(captured,pauses)
	var after:Dictionary=_query.get_stats()
	var row:Dictionary=_current_case.duplicate(); row["bins"]=_summarize_bins(_aggregate); row["submitted"]=after.submitted-before.submitted; row["dispatched"]=after.dispatched-before.dispatched; row["completed"]=after.completed-before.completed; row["coalesced"]=after.coalesced-before.coalesced
	row["errors"]=after.errors-before.errors; row["mismatches"]=after.mismatches-before.mismatches; row["superseded"]=after.superseded_results-before.superseded_results; row["last_consumed"]=last_consumed; row["trend"]=trend; row["pause_times"]=_distribution(pauses)
	row["latency_ms"]=_distribution(after.latency_ms.slice(before.latency_ms.size())); row["latency_ticks"]=_distribution(after.latency_ticks.slice(before.latency_ticks.size()))
	var gpu_times:Array=[]
	for sample in after.gpu_samples.slice(before.gpu_samples.size()): gpu_times.append(sample.gpu_us)
	row["query_gpu_us"]=_distribution(gpu_times)
	(_physical_proof.stress if long_run else _physical_proof.matrix).append(row)
	_occupant+=1; _save()

func _observe(result:Dictionary,pauses:Array) -> void:
	if result.is_empty() or not _inbox.has(result.generation): return
	var contexts:Array=_inbox[result.generation]
	for i in int(result.count):
		var context:Dictionary=contexts[i]; var row:=QUERY.decode_physical_contact(result,i)
		if not context.active:
			if row.valid: _physical_proof.checks.append("inactive physical valid")
			_executed.erase(context.slot); _handoff_history.erase(context.slot)
			continue
		if row.solves>5 or row.iterations>80: _physical_proof.checks.append("trajectory production budget")
		if row.valid and row.residual>0.001: _physical_proof.checks.append("valid physical residual")
		# Capture the first executed cold return even if its logical activation
		# submission was coalesced before dispatch in the supplemental fixture.
		var observed_reentry:bool=context.reentry or (context.scenario=="stationary_reentry" and not row.owned)
		if context.paused and context.tick>=5010 and context.tick<5190: pauses.append(result.sample_time)
		for label in ["all",context.scenario,"warm" if row.owned else "cold","weather/"+context.weather,"reentry" if observed_reentry else "ongoing","WEATHER_TRANSITION" if result.weather_alpha>0 and result.weather_alpha<1 else "STEADY","config/"+str(result.config_version)]:
			var bin:Dictionary=_aggregate.get(label,{"updates":0,"continued":0,"handoff":0,"cold":0,"failed":0,"q_delta":{},"residual":{},"iterations":{},"reasons":{}})
			bin.updates+=1; bin[{"1":"continued","3":"cold","4":"failed","5":"handoff"}[str(row.status)]]+=1
			_online_sample(bin.q_delta,row.delta); _online_sample(bin.residual,row.residual); _online_sample(bin.iterations,row.iterations)
			if not row.valid: bin.reasons[str(row.reason)]=int(bin.reasons.get(str(row.reason),0))+1
			_aggregate[label]=bin
		if observed_reentry:
			var key:String=context.scenario+"/"+str(context.duration); var bin:Dictionary=_reentry.get(key,{"queries":0,"failed":0,"owned":0})
			bin.queries+=1; bin.failed+=int(not row.valid); bin.owned+=int(row.owned); _reentry[key]=bin
		var predecessor:Dictionary=_executed.get(context.slot,{})
		if row.status==5:
			_chatter.handoffs+=1
			var window:String=str(_occupant)+"/"+str(context.slot)+"/"+str(int(result.sample_time))
			_chatter.windows[window]=int(_chatter.windows.get(window,0))+1
			_chatter.max_per_slot_second=maxi(_chatter.max_per_slot_second,_chatter.windows[window])
			var old:Dictionary=_handoff_history.get(context.slot,{})
			if not old.is_empty() and result.sample_time-old.time<0.1 and row.q.distance_to(old.previous)<0.02: _chatter.immediate_reversals+=1
			_handoff_history[context.slot]={"time":result.sample_time,"previous":row.previous_q,"q":row.q}
		if row.ambiguous or not row.valid or context.scenario=="fold" or observed_reentry or (context.tick%64==0 and context.contact==0):
			_envelope_ledger.append({"case":_current_case,"context":context,"time":result.sample_time,"config":result.config_version,"alpha":result.weather_alpha,"spectrum_time":result.spectrum_time,"generation":result.generation,"row":row,"predecessor":predecessor})
		_executed[context.slot]={"q":row.q,"surface_y":row.surface_y,"valid":row.valid,"generation":result.generation,"time":result.sample_time,"target":context.target,"config":result.config_version,"alpha":result.weather_alpha}
	_inbox.erase(result.generation)

func _replay_envelope_ledger() -> void:
	var variant:=OS.get_cmdline_user_args().has("--reentry10-envelope")
	var ledger_name:="reentry10" if variant else "full"
	var record_name:="reentry10_envelope_cases" if variant else "envelope_cases"
	var ledger:Array=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu13_"+ledger_name+"_ledger.json"))
	var case_file:=FileAccess.open("res://.godot/phys_gpu13_"+record_name+".jsonl",FileAccess.WRITE)
	var grouped:Dictionary={}
	for entry in ledger:
		var key:String=str(entry.config)+"/"+str(entry.time)+"/"+str(entry.alpha)
		if not grouped.has(key): grouped[key]=[]
		grouped[key].append(entry)
	var count:=0; var totals:Dictionary={"cases":0,"wrong_lower_sheet":0,"bounded_candidate_miss":0,"empty_reference":0,"false_handoff_retained":0,"height_tie_band":0,"total_roots":0,"max_roots":0,"envelope_matching_handoffs":0,"by_scenario":{},"by_ownership":{},"by_status":{}}
	for group in grouped.values():
		var first:Dictionary=group[0]; _anchor_weather(first)
		if not await _snapshot(int(first.config),first.time,true): return
		var cases:Array=[]
		for entry in group:
			cases.append({"target":Vector2(entry.context.target[0],entry.context.target[2]),"anchor":Vector2(entry.row.previous_q[0],entry.row.previous_q[1]),"additional":[entry.row.q] if entry.row.valid else []})
		var refs:=await _reference_many(cases)
		for index in group.size():
			var entry:Dictionary=group[index]; var row:Dictionary=entry.row.duplicate()
			row.q=Vector2(row.q[0],row.q[1])
			var check:=_validate_envelope(row,refs[index])
			for key in ["wrong_lower_sheet","bounded_candidate_miss"]: totals[key]+=int(check[key])
			totals.empty_reference+=int(refs[index].roots.is_empty())
			totals.cases+=1
			totals.total_roots+=refs[index].roots.size(); totals.max_roots=maxi(totals.max_roots,refs[index].roots.size())
			totals.envelope_matching_handoffs+=int(row.status==5 and row.valid and not check.wrong_lower_sheet and check.selected_matches_discovered_root)
			for grouping in ["by_scenario","by_ownership","by_status"]:
				var label:String=entry.context.scenario if grouping=="by_scenario" else (("warm" if row.owned else "cold") if grouping=="by_ownership" else str(row.status))
				var bin:Dictionary=totals[grouping].get(label,{"cases":0,"wrong_sheet":0,"misses":0,"envelope_exists":0,"empty_reference":0})
				bin.cases+=1; bin.wrong_sheet+=int(check.wrong_lower_sheet); bin.misses+=int(check.bounded_candidate_miss)
				bin.envelope_exists+=int(not refs[index].roots.is_empty()); bin.empty_reference+=int(refs[index].roots.is_empty())
				totals[grouping][label]=bin
			entry["envelope_check"]=check; entry["reference"]=refs[index]
			# Retained candidates must be measured on the current field.
			if row.owned and is_finite(row.previous_candidate_y) and not refs[index].envelope.is_empty():
				var gap:float=refs[index].envelope.height-row.previous_candidate_y
				if absf(gap)<=0.002: totals.height_tie_band+=1
				if int(row.status)==5 and gap<=0.002 and int(row.reason)==8: totals.false_handoff_retained+=1
			case_file.store_line(JSON.stringify(_json_value(entry)))
			if _physical_proof.envelope_cases.size()<2048 and (check.wrong_lower_sheet or check.bounded_candidate_miss): _physical_proof.envelope_cases.append(entry)
		count+=group.size()
		_physical_proof["envelope_totals"]=totals
		if count%1000<group.size(): case_file.flush(); _save(); print("GPU13_ENVELOPE="+str(count)+"/"+str(ledger.size()))
	case_file.close()
	_physical_proof["all_case_records"]="res://.godot/phys_gpu13_"+record_name+".jsonl"
	_physical_proof["envelope_totals"]=totals

func _old_reclassification() -> void:
	var studies:Dictionary={}
	for filename in ["ROOT-STUDIES","CONNECTED-STUDIES","LATERAL-STUDIES"]:
		var data:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-1.2-"+filename+".json"))
		for study in data.studies: studies[int(study.failure.ordinal)]=study
	for ordinal in studies:
		var study:Dictionary=studies[ordinal]; var failure:Dictionary=study.failure
		_anchor_weather(failure)
		if not await _snapshot(int(failure.config),failure.time,true): return
		var target:=Vector2(failure.target_x,failure.target_z); var previous:=Vector2(failure.previous_q_x,failure.previous_q_z)
		var additional:Array=[]
		for root in study.get("roots",[]): additional.append(root.q)
		var descriptors:Array=[{"slot":0,"vehicle_id":15000,"generation":_occupant,"reset":not failure.owned}]
		if failure.owned: descriptors[0].merge({"owned_seed":true,"hint_q":previous})
		var result:=await _physical_request(PackedVector3Array([Vector3(target.x,0.1,target.y)]),descriptors)
		if result.is_empty(): return
		var row:=QUERY.decode_physical_contact(result,0)
		var reference:=await _envelope_reference_gpu(target,previous,additional)
		var check:=_validate_envelope(row,reference)
		var classification:="insufficient evidence"
		var old_y:Variant=null; var survived:Dictionary={}
		if study.has("best_history"): old_y=study.best_history.material[1]
		for fine in study.get("fine",[]):
			if fine.endpoint_valid and not fine.path.is_empty(): survived=fine.path[-1].root
		if reference.roots.is_empty(): classification="no valid root found by reference"
		elif failure.scenario=="lateral": classification="previous local root pair terminated; another envelope exists"
		elif not survived.is_empty():
			classification="previous root still upper envelope" if survived.height>=reference.envelope.height-0.002 else "previous root survives; another sheet is higher"
		_physical_proof.envelope_cases.append({"ordinal":ordinal,"old_failure":failure,"old_cpu_contact":study.get("cpu_contact",{}),"old_pair_loss":failure.scenario=="lateral","old_selected_y_reconstructed":old_y,"envelope_y_after":reference.envelope.get("height",null),"envelope_q_after":reference.envelope.get("q",null),"signed_y_difference":reference.envelope.height-old_y if old_y!=null and not reference.envelope.is_empty() else null,"new_result":row,"reference":reference,"envelope_check":check,"classification":classification,"provenance":"Reconstructed coherent endpoint and conditional 1.2 local continuation evidence; this is not a byte-identical archived GPU texture replay."})
		_occupant+=1
		if _physical_proof.envelope_cases.size()%10==0: _save(); print("GPU13_OLD="+str(_physical_proof.envelope_cases.size())+"/"+str(studies.size()))

func _physical_lifecycle() -> void:
	var rows:Array=[]
	for cycle in 4:
		if cycle>0:
			_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
			for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
			root.add_child(_ocean)
			for frame in 12: await process_frame
			_fft=_ocean.get_node("OpenOceanFFT"); _query=_fft.call("enable_gpu_surface_queries")
			for frame in 6: await process_frame
		var points:=PackedVector3Array(); var descriptors:Array=[]
		for i in 256:
			points.append(Vector3(-240+(i%16)*0.1,0.1,-1300+(i/16)*0.1))
			descriptors.append({"slot":i,"vehicle_id":16000,"contact_id":i,"generation":1})
		var packet:=QUERY.pack_physical_contacts(points,descriptors)
		for submission in 32: _query.submit_contacts(packet,Engine.get_physics_frames())
		var in_flight:=0
		for frame in 8:
			await process_frame
			in_flight=int(_query.get_stats().in_flight)
			if in_flight>0: break
		var token:=_query; _ocean.queue_free()
		for frame in 12: await process_frame
		var stats:Dictionary=token.get_stats()
		rows.append({"cycle":cycle,"retired_in_flight":in_flight,"buffers_after":stats.owned_buffers,"in_flight_after":stats.in_flight,"errors":stats.errors,"mismatches":stats.mismatches,"coalesced":stats.coalesced,"metric_records":stats.latency_ms.size(),"trace_records":token.get_validation_trace().size(),"static_memory":OS.get_static_memory_usage()})
		if stats.owned_buffers!=0 or stats.in_flight!=0 or stats.errors!=0 or stats.mismatches!=0: _physical_proof.checks.append("physical lifecycle drain")
	_physical_proof["lifecycle"]=rows

func _physical_ties() -> void:
	# Authored ocean sheets, not a synthetic height clamp. Search the known
	# direction/choppiness crossing close to original failure ordinal 940.
	var target:=Vector2(393.939239501953,-991.9931640625)
	var anchor:=Vector2(393.111133813585,-992.51047675703)
	_weather_start=130.033333333329; _snapshot_config=-1
	var crossing:Dictionary={}; var scans:Array=[]
	for step in 41:
		var time:=130.143333333329+step*0.001
		await _snapshot(6,time,true)
		var reference:=await _envelope_reference_gpu(target,anchor)
		var roots:Array=reference.roots.duplicate(); roots.sort_custom(func(a,b): return a.height>b.height)
		if roots.size()<2: continue
		var gap:float=roots[0].height-roots[1].height
		scans.append({"time":time,"gap":gap,"highest":roots[0],"second":roots[1]})
		if gap<=0.002 and crossing.is_empty(): crossing={"time":time,"roots":roots.slice(0,2)}
	_physical_proof["tie_search"]=scans
	if crossing.is_empty(): _physical_proof.checks.append("no authored near-equal crossing found"); return
	var last:Array=[]; var switches:=0; var reversals:=0; var history:Array=[]; var results:Array=[]
	for step in 60:
		var time:float=crossing.time+step*0.0005
		await _snapshot(6,time,true)
		var points:=PackedVector3Array([Vector3(target.x,0.1,target.y),Vector3(target.x,0.1,target.y)])
		var descriptors:Array=[]
		for i in 2:
			var descriptor:Dictionary={"slot":i,"vehicle_id":17000+i,"generation":_occupant}
			if step==0: descriptor.merge({"owned_seed":true,"hint_q":crossing.roots[i].q})
			descriptors.append(descriptor)
		var packet:=await _physical_request(points,descriptors)
		var ref:=await _envelope_reference_gpu(target,anchor)
		var rows:Array=[]
		for i in 2:
			var row:=QUERY.decode_physical_contact(packet,i); row["envelope_check"]=_validate_envelope(row,ref)
			if row.status==5:
				switches+=1
				if history.size()>1 and row.q.distance_to(history[-2][i])<0.02: reversals+=1
			rows.append(row)
		results.append({"step":step,"time":time,"rows":rows,"reference":ref}); history.append([rows[0].q,rows[1].q]); last=rows
	_physical_proof["tie_results"]={"samples":results,"handoffs":switches,"immediate_reversals":reversals,"initial_gap":crossing.roots[0].height-crossing.roots[1].height}
	_occupant+=1

func _successful_handoff_benchmark() -> void:
	var old:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu13_old_replay.json"))
	var chosen:Dictionary={}
	for sample in old.envelope_cases:
		if sample.new_result.status==5 and sample.new_result.reason==8 and sample.new_result.valid and not sample.envelope_check.wrong_lower_sheet: chosen=sample; break
	if chosen.is_empty(): _physical_proof.checks.append("no successful envelope handoff fixture"); return
	var failure:Dictionary=chosen.old_failure; _anchor_weather(failure); await _snapshot(int(failure.config),failure.time,true)
	var target:=Vector2(failure.target_x,failure.target_z); var anchor:=Vector2(failure.previous_q_x,failure.previous_q_z)
	var reference:=await _envelope_reference_gpu(target,anchor)
	var ordinary_center:=Vector2(-240,-1300); var found:=false
	for area in 16:
		var points:=PackedVector3Array(); var descriptors:Array=[]
		var center:=Vector2(-240-area*16,-1300)
		for i in 256:
			points.append(Vector3(center.x+(i%16)*0.05,0.1,center.y+(i/16)*0.05)); descriptors.append({"slot":i,"vehicle_id":18000,"contact_id":i,"generation":_occupant,"reset":true})
		var packet:=await _physical_request(points,descriptors)
		var normal:=true
		for i in 256:
			var row:=QUERY.decode_physical_contact(packet,i)
			if not row.valid or row.solves!=1: normal=false; break
		_occupant+=1
		if normal: ordinary_center=center; found=true; break
	if not found: _physical_proof.checks.append("could not establish ordinary mixed benchmark area"); return
	for count in [1,80,256]:
		var counts:Dictionary={"continued":0,"cold":0,"handoff":0,"failed":0}; var wrong:=0; var normal_nonprimary:=0
		for frame in 6: await process_frame
		var before:Dictionary=_query.get_stats()
		for step in 24:
			var points:=PackedVector3Array(); var descriptors:Array=[]
			for i in count:
				var xz:=target if i==count-1 else ordinary_center+Vector2((i%16)*0.05+step*0.001,(i/16)*0.05)
				points.append(Vector3(xz.x,0.1,xz.y))
				var descriptor:Dictionary={"slot":i,"vehicle_id":18100,"contact_id":i,"generation":_occupant}
				if i==count-1: descriptor.merge({"owned_seed":true,"hint_q":anchor})
				descriptors.append(descriptor)
			var packet:=await _physical_request(points,descriptors)
			for i in count:
				var row:=QUERY.decode_physical_contact(packet,i)
				counts[{"1":"continued","3":"cold","4":"failed","5":"handoff"}[str(row.status)]]+=1
				if i==count-1: wrong+=int(_validate_envelope(row,reference).wrong_lower_sheet)
				elif row.solves!=1: normal_nonprimary+=1
			for frame in 6: await process_frame
		var after:Dictionary=_query.get_stats(); var times:Array=[]
		for sample in after.gpu_samples.slice(before.gpu_samples.size()): times.append(sample.gpu_us)
		_physical_proof.bench.append({"contacts":count,"mode":"successful_handoff" if count==1 else "ordinary_plus_successful_handoff","gpu_us":_distribution(times),"statuses":counts,"wrong_sheet":wrong,"ordinary_nonprimary":normal_nonprimary,"fixture_ordinal":chosen.ordinal,"reference":reference,"ordinary_center":ordinary_center})
		_occupant+=1

func _successful_handoff_depth() -> void:
	var old:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu13_old_replay.json"))
	var chosen:Dictionary={}
	for sample in old.envelope_cases:
		if sample.new_result.status==5 and sample.new_result.reason==8 and sample.new_result.valid and not sample.envelope_check.wrong_lower_sheet: chosen=sample; break
	if chosen.is_empty(): _physical_proof.checks.append("no handoff depth fixture"); return
	var failure:Dictionary=chosen.old_failure; _anchor_weather(failure)
	if not await _snapshot(int(failure.config),failure.time,true): return
	var target:=Vector2(failure.target_x,failure.target_z); var anchor:=Vector2(failure.previous_q_x,failure.previous_q_z)
	var reference:=await _envelope_reference_gpu(target,anchor)
	if reference.envelope.is_empty(): _physical_proof.checks.append("no handoff depth envelope"); return
	_physical_proof["successful_handoff_depth_reference"]=reference
	for compact in [false,true]:
		for expected in [-0.1,0.0,0.1]:
			var points:=PackedVector3Array([Vector3(target.x,reference.envelope.height-expected,target.y)])
			var descriptors:Array=[{"slot":0,"vehicle_id":19500,"contact_id":0,"generation":_occupant,"owned_seed":true,"hint_q":anchor}]
			var packet:=await _physical_request(points,descriptors,compact)
			if packet.is_empty(): return
			var row:=QUERY.decode_physical_contact(packet,0); var check:=_validate_envelope(row,reference)
			var error:float=absf(row.signed_depth-expected)
			_physical_proof.depth.append({"region":"successful_handoff","compact":compact,"expected":expected,"error":error,"result":row,"envelope_check":check,"fixture_ordinal":chosen.ordinal})
			if not row.valid or row.status!=5 or row.reason!=8 or check.wrong_lower_sheet or error>0.001: _physical_proof.checks.append("successful handoff depth")
			_occupant+=1

func _current12_reclassification() -> void:
	var data:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-1.2-FAILURES.json"))
	var grouped:Dictionary={}; var count:=0
	for failure in data.failure_records:
		var key:String=str(failure.config)+"/"+str(failure.time)+"/"+str(failure.alpha)
		if not grouped.has(key): grouped[key]=[]
		grouped[key].append(failure)
	var totals:Dictionary={"cases":0,"wrong_sheet":0,"misses":0,"envelope_exists":0,"no_root_discovered":0,"cold_no_prior_owner":0,"warm_ancestry_unproven":0,"near_prior_endpoint_is_upper":0,"near_prior_endpoint_is_lower":0,"near_prior_endpoint_not_found":0}
	for group in grouped.values():
		var first:Dictionary=group[0]; _anchor_weather(first); await _snapshot(int(first.config),first.time,true)
		var points:=PackedVector3Array(); var descriptors:Array=[]; var cases:Array=[]
		for i in group.size():
			var failure:Dictionary=group[i]; var target:=Vector2(failure.target_xy[0],failure.target_xy[1]); var anchor:=Vector2(failure.previous_q[0],failure.previous_q[1])
			points.append(Vector3(target.x,0.1,target.y))
			var descriptor:Dictionary={"slot":i,"vehicle_id":19000,"contact_id":i,"generation":_occupant,"reset":not failure.owned}
			if failure.owned: descriptor.merge({"owned_seed":true,"hint_q":anchor})
			descriptors.append(descriptor); cases.append({"target":target,"anchor":anchor})
		var packet:=await _physical_request(points,descriptors)
		if packet.is_empty(): return
		var refs:=await _reference_many(cases)
		for i in group.size():
			var failure:Dictionary=group[i]; var row:=QUERY.decode_physical_contact(packet,i); var check:=_validate_envelope(row,refs[i])
			totals.cases+=1; totals.wrong_sheet+=int(check.wrong_lower_sheet); totals.misses+=int(check.bounded_candidate_miss)
			totals.envelope_exists+=int(not refs[i].roots.is_empty()); totals.no_root_discovered+=int(refs[i].roots.is_empty())
			totals.cold_no_prior_owner+=int(not failure.owned); totals.warm_ancestry_unproven+=int(failure.owned)
			var endpoint:=_correct(cases[i].anchor.x,cases[i].anchor.y,cases[i].target.x,cases[i].target.y,0.03,48,0.000001)
			var near:bool=endpoint.valid and Vector2(endpoint.q[0],endpoint.q[1]).distance_to(cases[i].anchor)<0.05
			if failure.owned:
				if near and not refs[i].envelope.is_empty():
					if endpoint.height>=refs[i].envelope.height-0.002: totals.near_prior_endpoint_is_upper+=1
					else: totals.near_prior_endpoint_is_lower+=1
				else: totals.near_prior_endpoint_not_found+=1
			_physical_proof.envelope_cases.append({"old_failure":failure,"new_result":row,"reference":refs[i],"envelope_check":check,"near_prior_endpoint":endpoint,"near_prior_endpoint_within_5cm":near,"classification":"no valid root found by reference" if refs[i].roots.is_empty() else ("cold; no prior owned root" if not failure.owned else "insufficient ancestor proof"),"provenance":"Matched coherent endpoint reconstruction; validation-only warm seed from captured q. A nearby current root alone does not prove branch survival or termination."})
		count+=group.size(); _occupant+=1
		_physical_proof["current12_totals"]=totals
		if count%250<group.size(): _save(); print("GPU13_CURRENT12="+str(count)+"/"+str(data.failure_records.size()))

func _save() -> void:
	var args:=OS.get_cmdline_user_args()
	var kind:="full" if args.has("--full") else "focused"
	for flag in ["resource-only","envelope-replay","old-replay","smoke","lifecycle","ties","bench-only","success-bench","current12-replay","reentry10","reentry10-envelope"]:
		if args.has("--"+flag): kind=flag.replace("-","_")
	_physical_proof["ledger_count"]=_envelope_ledger.size()
	var file:=FileAccess.open("res://.godot/phys_gpu13_"+kind+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(_json_value(_physical_proof))); file.close()
	if not _envelope_ledger.is_empty():
		file=FileAccess.open("res://.godot/phys_gpu13_"+kind+"_ledger.json",FileAccess.WRITE)
		file.store_string(JSON.stringify(_json_value(_envelope_ledger))); file.close()
