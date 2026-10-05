extends "res://validation/physics/phys_gpu_envelope_runner.gd"
const DIAGNOSTIC := preload("res://validation/physics/surface_contract_query.gd")
var audit:Dictionary={"phase":"PHYS-GPU-SURFACE-CONTRACT-1","starting_head":"a2f3da697cf73101a11989d140a6ef210603532d","checks":[],"cases":[]}
var _diagnostic_token:Object

func _run() -> void:
	load(DESCRIPTOR)
	_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
	for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
	root.add_child(_ocean)
	var camera:=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current=true
	for frame in 12: await process_frame
	_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT"); _coastal=_fft.call("get_phys3_coastal_snapshot")
	_states=[{"name":"current","bands":_fft.call("get_phys2_band_spectrum_snapshots")}]
	for s in [["calm",0.8,4.0,20.0,0.8],["storm",3.0,18.0,75.0,2.0],["direction",3.0,18.0,20.0,2.0],["choppiness",3.0,18.0,20.0,2.5]]:
		var configs:Array=PROFILE.build_fft_configs(s[1],s[2],s[3],0.8,1.0); configs[0].choppiness=s[4]
		var builder:Object=ClassDB.instantiate("OceanQueryNative")
		var state:Dictionary=STATE.build(configs,1,s[1],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,builder)
		builder.call("prepare_production_spectrum",state.bands); _states.append({"name":s[0],"bands":state.bands,"native":builder})
	var current:Object=ClassDB.instantiate("OceanQueryNative"); current.call("prepare_production_spectrum",_states[0].bands); _states[0]["native"]=current
	if OS.get_cmdline_user_args().has("--capture-identity-closure"):
		await _strict_capture_closure()
		_ocean.queue_free()
		for frame in 12: await process_frame
		quit(0 if audit.checks.is_empty() else 1); return
	if not OS.get_cmdline_user_args().has("--prototype"):
		if OS.get_cmdline_user_args().has("--material-closure") or OS.get_cmdline_user_args().has("--corpus-width-closure"):
			var raw:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_raw.json"))
			for c in raw.cases:
				if c.record.get("decisive",false)==OS.get_cmdline_user_args().has("--material-closure"): _corpus.append(c)
		elif OS.get_cmdline_user_args().has("--resume-captures"):
			_corpus=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_captured_corpus.json"))
			audit["corpus"]={"count":_corpus.size(),"reservoir_seed":73412026,"strata":[64,64,64,64],"resume_selection":true}
		elif OS.get_cmdline_user_args().has("--resume-corpus"):
			_corpus=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_corpus.json"))
			audit["corpus"]={"count":_corpus.size(),"reservoir_seed":73412026,"strata":[64,64,64,64],"resume_selection":true}
		else: _build_corpus()
		if not OS.get_cmdline_user_args().has("--resume-captures") and not OS.get_cmdline_user_args().has("--material-closure") and not OS.get_cmdline_user_args().has("--corpus-width-closure"): await _capture_groups()
	var ordinary:Object=_fft.call("enable_gpu_surface_queries")
	for frame in 6: await process_frame
	RenderingServer.call_on_render_thread(ordinary.shutdown)
	_query=DIAGNOSTIC.new(); _fft.set("_gpu_surface_query",_query)
	RenderingServer.call_on_render_thread(_query.initialize.bind(load(QUERY.SHADER)))
	for frame in 8: await process_frame
	if not _query.get_stats().ready:
		print("SURFACE_CONTRACT_INITIALIZATION_FAILED="+str(_query.get_stats().last_error))
		_ocean.queue_free()
		for frame in 12: await process_frame
		quit(1); return
	_query.set_validation_metrics_enabled(true)
	_diagnostic_token=_query
	audit["environment"]={"engine":Engine.get_version_info(),"cpu":OS.get_processor_name(),"gpu":RenderingServer.get_video_adapter_name(),"driver":RenderingServer.get_current_rendering_driver_name(),"renderer":RenderingServer.get_current_rendering_method()}
	audit["diagnostic_source_hashes"]={"runner":FileAccess.get_sha256("res://validation/physics/phys_gpu_surface_contract_runner.gd"),"wrapper":FileAccess.get_sha256("res://validation/physics/surface_contract_query.gd"),"shader":FileAccess.get_sha256("res://validation/physics/surface_contract_query.comp")}
	if OS.get_cmdline_user_args().has("--prototype"): await _prototype()
	elif OS.get_cmdline_user_args().has("--material-closure"): await _material_closure()
	elif OS.get_cmdline_user_args().has("--corpus-width-closure"): await _width_closure()
	else: await _audit_corpus()
	var token:=_query; _ocean.queue_free()
	for frame in 12: await process_frame
	audit["after_shutdown"]=token.get_stats()
	if _native!=null: _native.call("clear")
	var output:="phys_gpu_surface_contract_prototype" if OS.get_cmdline_user_args().has("--prototype") else "phys_gpu_surface_contract_raw"
	if OS.get_cmdline_user_args().has("--material-closure"): output="phys_gpu_surface_contract_material"
	if OS.get_cmdline_user_args().has("--corpus-width-closure"): output="phys_gpu_surface_contract_width"
	FileAccess.open("res://.godot/"+output+".json",FileAccess.WRITE).store_string(JSON.stringify(audit))
	print("SURFACE_CONTRACT_COMPLETE="+JSON.stringify({"checks":audit.checks})); quit(0 if audit.checks.is_empty() else 1)

func _diagnose(trials:Array) -> Array:
	var rows:Array=[]
	if OS.get_cmdline_user_args().has("--material-closure"):
		for trial in trials: trial["precise_seed"]=true
	var capacity:=64 if trials.any(func(t):return t.get("continuation",false)) else 1024
	for at in range(0,trials.size(),capacity):
		var batch:=DIAGNOSTIC.pack(trials.slice(at,mini(at+capacity,trials.size())))
		var generation:int=_query.submit(batch.packet,Engine.get_physics_frames(),NAN,false,batch.controls)
		if generation<0: audit.checks.append("diagnostic submit rejected"); return []
		var result:Dictionary={}
		for frame in 600:
			await process_frame; result=_query.consume(Engine.get_physics_frames())
			if not result.is_empty() and result.generation==generation: break
		if result.is_empty(): audit.checks.append("diagnostic timeout"); return []
		_query.drain_validation_completed()
		for i in int(result.count): rows.append(DIAGNOSTIC.decode(result,i))
	return rows

func _prototype() -> void:
	var baseline:Dictionary={}; var baseline_path:="res://.godot/phys_gpu_surface_contract_prototype.json"
	if FileAccess.file_exists(baseline_path):
		baseline=JSON.parse_string(FileAccess.get_file_as_string(baseline_path))
		audit["original_legacy_baseline_sha256"]=FileAccess.get_sha256(baseline_path)
	else:
		var committed:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-SURFACE-CONTRACT-1-MEASUREMENTS.json"))
		var baseline_rows:Array=committed.get("diagnostic_smoke",{}).get("legacy_rows",[])
		baseline={"cases":[{"rows":baseline_rows}]}
	var evidence:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-ENVELOPE-1-MEASUREMENTS.json"))
	var sample:Dictionary=evidence.current_field_confirmation.filter(func(s):return s.confirmed_wrong)[0]
	var record:Dictionary=sample.record
	_anchor_weather(record)
	if not await _snapshot(int(record.config),record.time,true): audit.checks.append("snapshot"); return
	var trials:Array=[]
	for axis in 2:
		for offset in [0.0,-0.0005,0.0005,-0.001,0.001,-0.002,0.002,-0.005,0.005,-0.01,0.01,-0.025,0.025,-0.05,0.05,-0.1,0.1,-0.2,0.2,-0.4,0.4]:
			var target:Array=record.target.duplicate(); target[axis]+=offset
			for root_record in record.reference.roots: trials.append({"target":target,"seed":root_record.q,"offset":offset,"axis":axis})
	var rows:=await _diagnose(trials)
	for i in rows.size(): rows[i]["trial"]=trials[i]
	var mismatches:Array=[]; var old_rows:Array=baseline.cases[0].rows
	if old_rows.size()!=rows.size(): mismatches.append("row count")
	for i in mini(old_rows.size(),rows.size()):
		if old_rows[i].valid!=rows[i].valid or (rows[i].valid and (_distance(old_rows[i].q,rows[i].q)>0.00002 or absf(old_rows[i].height-rows[i].height)>0.000005)): mismatches.append(i)
	if not mismatches.is_empty(): audit.checks.append("legacy prototype comparison")
	audit["legacy_prototype_comparison"]={"rows":old_rows.size(),"mismatches":mismatches,"q_tolerance_m":0.00002,"y_tolerance_m":0.000005}
	audit.cases.append({"record":record,"rows":rows})
	var raw:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_raw.json"))
	var smoke:Array=[]
	for c in raw.cases:
		if not c.record.get("decisive",false): continue
		_anchor_weather(c.record)
		if not await _snapshot(int(c.record.config),c.record.time,true): audit.checks.append("smoke snapshot"); continue
		var seed:Dictionary=c.center_roots[0]
		var trials64:Array=[{"target":c.record.target,"seed":seed.q,"precise_seed":true,"material":true},{"target":c.record.target,"seed":seed.q,"precise_seed":true,"continuation":true,"orientation":signf(seed.det)},{"target":[c.record.target[0]+0.1,c.record.target[1]],"seed":seed.q,"precise_seed":true,"continuation":true,"orientation":signf(seed.det)}]
		var checked:=await _diagnose(trials64)
		if checked.size()!=3: audit.checks.append("smoke row count"); continue
		if not checked[0].valid or _distance(checked[0].q,seed.q)>1e-9: audit.checks.append("smoke material q preservation")
		if not checked[1].valid or _distance(checked[1].q,seed.q)>0.00002 or absf(checked[1].height-seed.height)>0.000005: audit.checks.append("smoke self-continuation")
		smoke.append({"label":c.record.label,"rows":checked,"trials":trials64})
	audit["precise_continuation_smoke"]=smoke
	print("SURFACE_PROTOTYPE="+str(rows.size()))

func _case_key(r:Dictionary) -> String:
	return "%d/%.9f/%.9f/%.9f"%[r.config,r.time,r.target[0],r.target[1]]

func _slim_reference(ref:Dictionary) -> Dictionary:
	var roots:Array=[]
	for r in ref.roots: roots.append({"q":r.q,"height":r.height})
	return {"roots":roots,"envelope":ref.envelope}

func _build_corpus() -> void:
	var prior:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-ENVELOPE-1-MEASUREMENTS.json"))
	var used:Dictionary={}; var decisive:=0
	for s in prior.current_field_confirmation:
		if not s.confirmed_wrong: continue
		var r:Dictionary=s.record.duplicate(true); r["label"]="confirmed2048/"+str(decisive); r["decisive"]=true
		r["previous_gpu_confirmation"]={"upper_q":s.confirmed_max_q,"upper_y":s.confirmed_max_y,"selected_y":s.selected.surface_y}
		_corpus.append(r); used[_case_key(r)]=true; decisive+=1
	var old:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-1.3-OLD-RECLASSIFICATION.json"))
	for e in old.envelope_cases:
		var f:Dictionary=e.old_failure
		if int(f.ordinal) not in [1028,1029,1030,1031,1032,2521,2522]: continue
		var r:Dictionary={"label":"lateral/"+str(f.ordinal),"config":f.config,"time":f.time,"alpha":f.alpha,"target":[f.target_x,f.target_z],"reference":_slim_reference(e.reference),"decisive":false}
		if not used.has(_case_key(r)): _corpus.append(r); used[_case_key(r)]=true
	for collection in ["baseline_replay","dense_replay","cold_replay"]:
		for e in prior[collection].examples:
			var r:Dictionary=e.record.duplicate(true); r["label"]=collection+"/example/"+str(_corpus.size()); r["decisive"]=false
			if not used.has(_case_key(r)): _corpus.append(r); used[_case_key(r)]=true
	# Four independent deterministic reservoirs, 64 unique targets each. Random
	# reservoir is reserved last so it cannot duplicate a gap stratum.
	var pools:Array=[[],[],[],[]]; var seen_counts:Array=[0,0,0,0]
	var rng:=RandomNumberGenerator.new(); rng.seed=73412026
	var unique:Dictionary={}; var files:Array=[]
	for variant in ["main","supplement"]:
		for part in range(1,63 if variant=="main" else 37):
			var path:="res://validation/physics/gpu13_envelope/"+("cases" if variant=="main" else "reentry10-cases")+"-%03d.jsonl.gz"%part
			files.append({"path":path,"sha256":FileAccess.get_sha256(path)})
			var data:=FileAccess.get_file_as_bytes(path).decompress_dynamic(32*1024*1024,FileAccess.COMPRESSION_GZIP)
			var ordinal:=0
			for line in data.get_string_from_utf8().split("\n",false):
				ordinal+=1; var e:Dictionary=JSON.parse_string(line)
				if e.reference.roots.size()<2: continue
				var r:Dictionary={"config":e.config,"time":e.time,"alpha":e.alpha,"target":[e.context.target[0],e.context.target[2]],"reference":_slim_reference(e.reference),"source":variant,"archive":path,"line":ordinal,"cold":e.context.scenario=="fold" and not e.row.owned,"old_class":"wrong" if e.envelope_check.wrong_lower_sheet else "miss" if e.envelope_check.bounded_candidate_miss else "correct","decisive":false}
				var key:=_case_key(r)
				if used.has(key) or unique.has(key): continue
				unique[key]=true
				var ys:Array=r.reference.roots.map(func(root_record):return root_record.height); ys.sort(); var gap:float=ys[-1]-ys[-2]
				r["archive_next_root_gap"]=gap
				var bin:=0 if gap>0.2 else 1 if gap>=0.05 else 2 if gap>=0.002 else 3
				for bucket in [bin,3] if bin!=3 else [3]:
					seen_counts[bucket]+=1; var pool:Array=pools[bucket]
					if pool.size()<192: pool.append(r)
					else:
						var pick:=rng.randi_range(0,seen_counts[bucket]-1)
						if pick<192: pool[pick]=r
			print("SURFACE_CORPUS_READ="+variant+"/"+str(part))
	var names:Array=["very_large_gap","medium_gap","small_gap","random_fold"]
	var selected:Array=[]
	for bucket in 4:
		var n:=0
		for r in pools[bucket]:
			if used.has(_case_key(r)): continue
			r["label"]=names[bucket]+"/"+str(n); r["stratum"]=names[bucket]
			_corpus.append(r); used[_case_key(r)]=true; n+=1
			if n==64: break
		selected.append(n)
		if n<64: audit.checks.append("stratum shortfall: "+names[bucket])
	# This fixture is authored in the frozen GPU-1.3 runner, not an archive row.
	_corpus.append({"label":"physical_two_root","config":1,"time":2.25,"alpha":0.0,"target":[393.4588,-992.3107],"reference":{"envelope":{"q":[393.2003,-991.9864],"height":0.0},"roots":[{"q":[393.2003,-991.9864],"height":0.0},{"q":[393.3454,-992.2997],"height":0.0}]},"decisive":false})
	_corpus.sort_custom(func(a,b):return a.config<b.config or (a.config==b.config and a.time<b.time))
	audit["corpus"]={"count":_corpus.size(),"strata":selected,"reservoir_seed":73412026,"eligible_unique":unique.size(),"eligible_by_bucket":seen_counts,"archives":files}
	FileAccess.open("res://.godot/phys_gpu_surface_contract_corpus.json",FileAccess.WRITE).store_string(JSON.stringify(_corpus))
	print("SURFACE_CORPUS="+str(_corpus.size()))

func _capture_groups() -> void:
	# Frozen atlas, one stationary validation target/tile, independent reacquisition.
	for stage in 3:
		var resolution:int=[128,256,2048][stage]; var grid:int=[512,1024,2048][stage]
		_tile_width=16.0 if stage==0 else 8.0
		if not await _create_atlas(resolution,grid): audit.checks.append("capture atlas initialization"); return
		for r in _corpus:
			if stage==2 and r.capture.B.correct and not r.get("decisive",false): continue
			_anchor_weather(r)
			if not await _snapshot(int(r.config),r.time,true): audit.checks.append("capture snapshot"); continue
			var target:=Vector2(r.target[0],r.target[1])
			var result:=await _atlas_request(PackedVector3Array([Vector3(target.x,0.1,target.y)]),[{"slot":0,"vehicle_id":0,"generation":_occupant,"reset":true}],[{"center":target,"size":Vector2(_tile_width,_tile_width),"generation":_occupant}])
			_occupant+=1
			if result.is_empty(): audit.checks.append("capture request"); continue
			var row:=ENVELOPE.decode_envelope_contact(result,0)
			if not r.has("capture"): r["capture"]={}
			r.capture[["A","B","C"][stage]]={"correct":row.valid and absf(row.surface_y-r.reference.envelope.height)<0.002,"valid":row.valid,"q":[row.q.x,row.q.y],"height":row.surface_y,"resolution":resolution,"grid":grid,"tile_width":_tile_width}
		await _retire_atlas()
		print("SURFACE_CAPTURE_STAGE="+str(stage))
	audit["capture_retirement"]=atlas_report.after_shutdown
	FileAccess.open("res://.godot/phys_gpu_surface_contract_captured_corpus.json",FileAccess.WRITE).store_string(JSON.stringify(_corpus))

func _distance(a:Array,b:Array) -> float:
	return sqrt(pow(a[0]-b[0],2)+pow(a[1]-b[1],2))

func _predict(r:Dictionary,delta:Array) -> Array:
	var j:Array=r.j; var det:float=j[0]*j[3]-j[1]*j[2]
	if absf(det)<0.000001: return r.q.duplicate()
	var x:float=(j[3]*delta[0]-j[1]*delta[1])/det; var z:float=(-j[2]*delta[0]+j[0]*delta[1])/det
	var length:=sqrt(x*x+z*z)
	if length>0.15: x*=0.15/length; z*=0.15/length
	return [r.q[0]+x,r.q[1]+z]

func _discover(r:Dictionary,additional:Array=[]) -> Array:
	var trials:Array=[]; var target:Array=r.target
	for center in [target,r.reference.envelope.q]:
		for ix in range(-8,9):
			for iz in range(-8,9): trials.append({"target":target,"seed":[center[0]+ix*0.25,center[1]+iz*0.25]})
		for radius in [0.05,0.1,0.5,1.0,2.0,4.0,8.0]:
			for i in 16:
				var v:Vector2=Vector2.from_angle(i*TAU/16)*radius
				trials.append({"target":target,"seed":[center[0]+v.x,center[1]+v.y]})
	for root_record in r.reference.roots: trials.append({"target":target,"seed":root_record.q})
	for q in additional: trials.append({"target":target,"seed":q})
	var rows:=await _diagnose(trials); var roots:Array=[]
	for row in rows:
		if not row.valid: continue
		var duplicate:=false
		for other in roots:
			if _distance(row.q,other.q)<0.00002 and absf(row.height-other.height)<0.000005: duplicate=true; break
		if not duplicate: roots.append(row)
	roots.sort_custom(func(a,b):return a.height>b.height)
	return roots

func _node_key(x:int,z:int) -> String: return str(x)+"/"+str(z)

func _sample_nodes(coordinates:Array,nodes:Dictionary,center:Array,roots:Array) -> void:
	var trials:Array=[]; var owners:Array=[]; var predictions:Array=[]; var predecessors:Array=[]
	for coord in coordinates:
		var key:=_node_key(coord[0],coord[1])
		if nodes.has(key): continue
		var target:Array=[center[0]+(coord[0]-512)*0.8/1024,center[1]+(coord[1]-512)*0.8/1024]
		var node:Dictionary={"coord":coord,"target":target,"branches":{},"ambiguous":false,"roots":[],"upper":-1}
		nodes[key]=node
		var nearby:Array=[]; var nearby_seen:Dictionary={}
		if nodes.has("512/512"): nearby.append(nodes["512/512"]); nearby_seen["512/512"]=true
		for spacing in [1,2,4,8,16,32,64,128,256,512]:
			var sx:int=int(round(float(coord[0])/spacing))*spacing; var sz:int=int(round(float(coord[1])/spacing))*spacing
			for dx in [-spacing,0,spacing]:
				for dz in [-spacing,0,spacing]:
					var candidate_key:=_node_key(sx+dx,sz+dz)
					if nodes.has(candidate_key) and not nearby_seen.has(candidate_key): nearby.append(nodes[candidate_key]); nearby_seen[candidate_key]=true
		# Rank the same predecessor candidates once per world point. The stable
		# ordinal tie break preserves the original nearest-candidate selection.
		var ranked:Array=[]
		for index in nearby.size(): ranked.append([_distance(target,nearby[index].target),index,nearby[index]])
		ranked.sort_custom(func(a,b):return a[0]<b[0] or (a[0]==b[0] and a[1]<b[1]))
		for id in roots.size():
			var prior:Dictionary={"target":roots[id].get("anchor_target",center),"branches":{id:roots[id]}}
			for rank in ranked:
				var candidate:Dictionary=rank[2]
				if not candidate.branches.has(id): continue
				prior=candidate; break
			var p:Dictionary=prior.branches[id]; var predicted:=_predict(p,[target[0]-prior.target[0],target[1]-prior.target[1]])
			var move:=_distance(predicted,p.q)
			var continuation:bool=OS.get_cmdline_user_args().has("--material-closure")
			trials.append({"target":target,"seed":p.q if continuation else predicted,"radius":minf(0.2,maxf(0.003,move*3+0.001)),"trust":0.03,"orientation":signf(p.det),"continuation":continuation})
			owners.append([key,id]); predictions.append(predicted); predecessors.append({"q":p.q,"det":p.det,"distance_world":_distance(target,prior.target)})
	var rows:=await _diagnose(trials)
	for i in rows.size():
		var row:Dictionary=rows[i]; var node:Dictionary=nodes[owners[i][0]]; var id:int=owners[i][1]
		if not row.valid:
			if id==0 and OS.get_cmdline_user_args().has("--material-closure"): node["branch0_path_failed"]=true
			continue
		var predecessor:Dictionary=predecessors[i]; var predicted:Array=predictions[i]
		var movement:=_distance(row.q,predecessor.q); var error:=_distance(row.q,predicted)
		# Identity needs proximity to the continuation prediction AND a local
		# predecessor. Orientation guards prevent a crossing but do not assign IDs.
		var ambiguous:bool=error>maxf(0.003,movement*0.75) or movement>0.2
		row["identity_ambiguous"]=ambiguous; row["prediction_error"]=error; row["predecessor_q"]=predecessor.q
		node.branches[id]=row
	for coord in coordinates:
		var node:Dictionary=nodes[_node_key(coord[0],coord[1])]
		node.ambiguous=false
		var best:float=-INF
		for id in node.branches:
			var row:Dictionary=node.branches[id]; var duplicate:=false
			for other in node.roots:
				if _distance(row.q,other.q)<0.00002:
					duplicate=true
					if id==0 or other.id==0: node.ambiguous=true
					break
			if not duplicate: node.roots.append({"id":id,"q":row.q,"height":row.height})
			if row.height>best: best=row.height; node.upper=id
		if node.upper>=0: node["height"]=best
		if node.branches.has(0): node.ambiguous=node.ambiguous or node.branches[0].identity_ambiguous
		if node.upper>=0: node.ambiguous=node.ambiguous or node.branches[node.upper].identity_ambiguous

func _cell_points(c:Array) -> Array:
	var x:int=c[0]; var z:int=c[1]; var s:int=c[2]; var h:int=s/2
	return [[x,z],[x+s,z],[x,z+s],[x+s,z+s],[x+h,z+h]]

func _refine_cell(c:Array,nodes:Dictionary) -> bool:
	var first:Dictionary=nodes[_node_key(c[0],c[1])]; var ys:Array=[]; var dets:Array=[]; var q:Array=[]
	for coord in _cell_points(c):
		var n:Dictionary=nodes[_node_key(coord[0],coord[1])]
		if n.upper!=first.upper or n.roots.size()!=first.roots.size() or n.branches.has(0)!=first.branches.has(0): return true
		if n.ambiguous: return true
		if n.has("height"): ys.append(n.height)
		if n.branches.has(0):
			var b:Dictionary=n.branches[0]; dets.append(b.det); q.append(b.q)
			if b.smin<0.02 or b.prediction_error>0.003: return true
	if not ys.is_empty() and ys.max()-ys.min()>0.01: return true
	if not dets.is_empty() and dets.max()*dets.min()<0: return true
	if q.size()==5 and _distance(q[4],[(q[0][0]+q[1][0]+q[2][0]+q[3][0])/4,(q[0][1]+q[1][1]+q[2][1]+q[3][1])/4])>0.002: return true
	return false

func _decisive_cell_floor(c:Array,nodes:Dictionary,default_floor:int) -> int:
	if default_floor!=1 and OS.get_cmdline_user_args().has("--corpus-fine-interior"): return default_floor
	var winners:Array=[]; var presence:Array=[]
	for coord in _cell_points(c):
		var n:Dictionary=nodes[_node_key(coord[0],coord[1])]
		winners.append(n.upper==0 and not n.ambiguous); presence.append(n.branches.has(0))
		if n.branches.has(0) and n.branches[0].smin<0.02: return default_floor
	if (winners.has(true) and winners.has(false)) or (presence.has(true) and presence.has(false)): return default_floor
	# Other lower-root changes and smooth field variation stay measured on a
	# coarser grid; they do not establish the central sheet's boundary.
	return 16 if default_floor==1 else 64

func _patch(center:Array,roots:Array,decisive:bool,keep_nodes:=false) -> Dictionary:
	var nodes:Dictionary={}; var branches:Dictionary={}
	for id in roots.size():
		var row:Dictionary=roots[id].duplicate(true); row["identity_ambiguous"]=false; row["prediction_error"]=0.0
		branches[id]=row
	var highest_id:=0
	for id in roots.size():
		if roots[id].height>roots[highest_id].height: highest_id=id
	if roots[0].has("anchor_target"):
		await _sample_nodes([[512,512]],nodes,center,roots)
	else:
		nodes["512/512"]={"coord":[512,512],"target":center,"branches":branches,"ambiguous":false,"roots":roots.map(func(r):return {"q":r.q,"height":r.height}),"upper":highest_id,"height":roots[highest_id].height}
	# Initialize from the known center outwards, so initial labels have local
	# predecessors rather than one long Newton jump from the center.
	for radius in range(1,9):
		var ring:Array=[]
		for ix in range(-radius,radius+1):
			for iz in range(-radius,radius+1):
				if maxi(absi(ix),absi(iz))==radius: ring.append([512+ix*64,512+iz*64])
		await _sample_nodes(ring,nodes,center,roots)
	var cells:Array=[]
	for x in range(0,1024,128):
		for z in range(0,1024,128): cells.append([x,z,128])
	# All targets receive a measured patch. The six decisive failures have
	# sub-millimetre boundary cells; wider corpus boundaries retain 12.5 mm
	# cells and explicitly carry the resulting area interval.
	var leaves:Array=[]; var finest:=1 if decisive else 16; var capped:=false
	var node_limit:=100000 if decisive else 8000
	while not cells.is_empty():
		var coords:Array=[]; var queued:Dictionary={}
		for c in cells:
			for coord in _cell_points(c):
				var key:=_node_key(coord[0],coord[1])
				if not nodes.has(key) and not queued.has(key): coords.append(coord); queued[key]=true
		await _sample_nodes(coords,nodes,center,roots)
		var next:Array=[]
		for c in cells:
			var local_floor:=_decisive_cell_floor(c,nodes,finest)
			if c[2]>local_floor and _refine_cell(c,nodes) and nodes.size()<node_limit:
				var h:int=c[2]/2
				for dx in [0,h]:
					for dz in [0,h]: next.append([c[0]+dx,c[1]+dz,h])
			else:
				leaves.append(c)
				if nodes.size()>=node_limit: capped=true
		cells=next
		if decisive: print("SURFACE_ADAPT_LEVEL="+str(nodes.size())+"/remaining="+str(cells.size()))
	var anchor:Array=roots[0].get("anchor_target",center)
	var anchor_coord:Array=[512+(anchor[0]-center[0])*1024/0.8,512+(anchor[1]-center[1])*1024/0.8]
	var out:=_measure_patch(nodes,leaves,roots,finest,capped,anchor_coord)
	out["root_labels"]=roots.map(func(r):return {"q":r.q,"height":r.height,"det":r.det})
	var component_indices:Dictionary=_connected_component(nodes,leaves,anchor_coord).mask
	out["connected_component_metrics"]=_component_stats(nodes,leaves,component_indices)
	if keep_nodes:
		var map_cells:Array=[]; var index:=0
		for c in leaves:
			var n:Dictionary=nodes[_node_key(c[0]+int(c[2]/2),c[1]+int(c[2]/2))]
			map_cells.append({"x":(c[0]-512)*0.8/1024,"z":(c[1]-512)*0.8/1024,"size":c[2]*0.8/1024,"upper":n.upper,"central_component":component_indices.has(index),"highest_present":n.branches.has(0),"ambiguous":n.ambiguous,"height":n.get("height",null)})
			index+=1
		out["map_cells"]=map_cells
	out.erase("_component_mask")
	return out

func _component_stats(nodes:Dictionary,leaves:Array,component:Dictionary) -> Dictionary:
	var heights:Array=[]; var dets:Array=[]; var conditions:Array=[]; var gaps:Array=[]; var gradients:Array=[]
	var area:=0.0; var weighted_y:=0.0; var index:=-1; var negative:=0; var positive:=0
	for c in leaves:
		index+=1
		if not component.has(index): continue
		var n:Dictionary=nodes[_node_key(c[0]+int(c[2]/2),c[1]+int(c[2]/2))]
		var b:Dictionary=n.branches[0]; var weight:float=pow(c[2]*0.8/1024,2)
		area+=weight; weighted_y+=weight*b.height; heights.append([b.height,weight]); dets.append(b.det); conditions.append(b.condition)
		negative+=int(b.det<0); positive+=int(b.det>0)
		var lower:float=-INF
		for r in n.roots:
			if _distance(r.q,b.q)>0.00002 and r.height<b.height: lower=maxf(lower,r.height)
		if is_finite(lower): gaps.append(b.height-lower)
		var j:Array=b.j; var gy:Array=b.height_gradient_q
		if absf(b.det)>1e-9: gradients.append(sqrt(pow((gy[0]*j[3]-gy[1]*j[2])/b.det,2)+pow((-gy[0]*j[1]+gy[1]*j[0])/b.det,2)))
	return {"area_m2":area,"area_weighted_mean_y":weighted_y/area if area>0 else null,"area_weighted_median_y":_weighted_median(heights),"height_y":_percentiles(heights.map(func(v):return v[0])),"fine_det":_percentiles(dets),"abs_fine_det":_percentiles(dets.map(func(v):return absf(v))),"negative_det_cells":negative,"positive_det_cells":positive,"condition":_percentiles(conditions),"upper_next_gap":_percentiles(gaps),"world_height_gradient":_percentiles(gradients),"qualification":"representative cell samples in the reconstructed known winning component; finest unit cells use the lower-left sample, larger cells use the center. Extrema between samples remain unbounded"}

func _percentiles(values:Array) -> Dictionary:
	if values.is_empty(): return {}
	var sorted:=values.duplicate(); sorted.sort(); var out:Dictionary={"n":sorted.size()}
	for pair in [["min",0.0],["p05",0.05],["p25",0.25],["p50",0.5],["p75",0.75],["p95",0.95],["max",1.0]]:
		out[pair[0]]=sorted[int(round(pair[1]*(sorted.size()-1)))]
	return out

func _union_root(parents:Array,i:int) -> int:
	while parents[i]!=i: parents[i]=parents[parents[i]]; i=parents[i]
	return i

func _connected_component(nodes:Dictionary,leaves:Array,anchor:Array=[512,512]) -> Dictionary:
	var parents:Array=[]; var edges:Dictionary={}; var candidates:Dictionary={}
	var nearest:=INF; var start:=-1
	for i in leaves.size():
		parents.append(i); var c:Array=leaves[i]
		var n:Dictionary=nodes[_node_key(c[0]+int(c[2]/2),c[1]+int(c[2]/2))]
		if n.upper!=0 or n.ambiguous: continue
		candidates[i]=true
		var ds:=pow(clampf(anchor[0],c[0],c[0]+c[2])-anchor[0],2)+pow(clampf(anchor[1],c[1],c[1]+c[2])-anchor[1],2)
		if ds<nearest: nearest=ds; start=i
		for e in [["x/"+str(c[0]),0,c[1],c[1]+c[2]],["x/"+str(c[0]+c[2]),1,c[1],c[1]+c[2]],["z/"+str(c[1]),0,c[0],c[0]+c[2]],["z/"+str(c[1]+c[2]),1,c[0],c[0]+c[2]]]:
			if not edges.has(e[0]): edges[e[0]]=[[],[]]
			edges[e[0]][e[1]].append([e[2],e[3],i])
	for pair in edges.values():
		pair[0].sort_custom(func(a,b):return a[0]<b[0]); pair[1].sort_custom(func(a,b):return a[0]<b[0])
		var a:=0; var b:=0
		while a<pair[0].size() and b<pair[1].size():
			var left:Array=pair[0][a]; var right:Array=pair[1][b]
			if mini(left[1],right[1])>maxi(left[0],right[0]): parents[_union_root(parents,left[2])]=_union_root(parents,right[2])
			if left[1]<right[1]: a+=1
			else: b+=1
	var component:Dictionary={}; var groups:Dictionary={}; var hull_points:=PackedVector2Array()
	if start<0: return {"mask":component,"groups":0,"central_cell_missing":true,"min_feret_m":0.0,"max_feret_m":0.0}
	var root_id:=_union_root(parents,start)
	for i in candidates:
		var group:=_union_root(parents,i); groups[group]=true
		if group!=root_id: continue
		component[i]=true; var c:Array=leaves[i]
		for p in [[c[0],c[1]],[c[0]+c[2],c[1]],[c[0],c[1]+c[2]],[c[0]+c[2],c[1]+c[2]]]: hull_points.append(Vector2(p[0]-512,p[1]-512)*0.8/1024)
	var hull:=Geometry2D.convex_hull(hull_points); var min_width:=INF; var max_width:=0.0
	for i in range(1,hull.size()):
		var direction:Vector2=(hull[i]-hull[i-1]).orthogonal().normalized(); var lo:=INF; var hi:=-INF
		for point in hull: var value:float=point.dot(direction); lo=minf(lo,value); hi=maxf(hi,value)
		min_width=minf(min_width,hi-lo)
		for point in hull: max_width=maxf(max_width,hull[i].distance_to(point))
	return {"mask":component,"groups":groups.size(),"central_cell_missing":nearest>2.0,"min_feret_m":min_width if is_finite(min_width) else 0.0,"max_feret_m":max_width}

func _weighted_median(values:Array) -> Variant:
	if values.is_empty(): return null
	values.sort_custom(func(a,b):return a[0]<b[0]); var total:=0.0
	for v in values: total+=v[1]
	var summed:=0.0
	for v in values:
		summed+=v[1]
		if summed>=total*0.5: return v[0]
	return values[-1][0]

func _disk_integral(x:float,r:float) -> float:
	x=clampf(x,0,r)
	return 0.5*(x*sqrt(maxf(0,r*r-x*x))+r*r*asin(x/r))

func _disk_quadrant(a:float,b:float,c:float,d:float,r:float) -> float:
	a=maxf(0,a); c=maxf(0,c); b=minf(r,b); d=minf(r,d)
	if a>=b or c>=d: return 0.0
	var flat_until:=sqrt(maxf(0,r*r-d*d)); var end:=sqrt(maxf(0,r*r-c*c))
	var flat:=maxf(0,minf(b,flat_until)-a)*(d-c)
	var lo:=maxf(a,flat_until); var hi:=minf(b,end)
	return flat+(_disk_integral(hi,r)-_disk_integral(lo,r)-c*(hi-lo) if hi>lo else 0.0)

func _disk_rectangle(x:float,z:float,width:float,r:float) -> float:
	var sum:=0.0
	for xs in [[maxf(0,x),maxf(0,x+width)],[maxf(0,-x-width),maxf(0,-x)]]:
		for zs in [[maxf(0,z),maxf(0,z+width)],[maxf(0,-z-width),maxf(0,-z)]]:
			sum+=_disk_quadrant(xs[0],xs[1],zs[0],zs[1],r)
	return sum

func _measure_patch(nodes:Dictionary,leaves:Array,roots:Array,finest:int,capped:bool,anchor_coord:Array=[512,512]) -> Dictionary:
	var scales:Array=[]
	var anchor_support:Array=[]
	var anchor_offset:Array=[(anchor_coord[0]-512)*0.8/1024,(anchor_coord[1]-512)*0.8/1024]
	for half in [0.01,0.025,0.05,0.1,0.2,0.4]:
		anchor_support.append({"diameter_m":2*half,"area_m2":PI*half*half,"known_winner_area":0.0,"possible_winner_area":0.0})
		scales.append({"half_width_m":half,"area_m2":pow(2*half,2),"winner_area":0.0,"present_area":0.0,"uncertain_area":0.0,"weighted_y":0.0,"valid_area":0.0,"values":[],"lower_area":0.0,"lower_y":0.0,"max_y":-INF})
		scales[-1]["circle"]={"radius_m":half,"diameter_m":2*half,"area_m2":PI*half*half,"winner_area":0.0,"present_area":0.0,"uncertain_area":0.0,"weighted_y":0.0,"valid_area":0.0,"values":[],"lower_area":0.0,"lower_y":0.0,"max_y":-INF}
		for measure in [scales[-1],scales[-1].circle]: measure["known_full_winner_area"]=0.0; measure["possible_winner_area"]=0.0
	var connected:=_connected_component(nodes,leaves,anchor_coord); var leaf_index:=-1
	var area:=0.0; var uncertain:=0.0; var present:=0.0; var bbox:Array=[INF,INF,-INF,-INF]; var dets:Array=[]; var conditions:Array=[]; var smins:Array=[]; var gaps:Array=[]; var heights:Array=[]; var gradients:Array=[]; var boundary:=INF; var edge_censored:=false
	var boundary_cells:=0; var ambiguous_nodes:=0; var max_boundary_cell:=0.0
	for n in nodes.values():
		ambiguous_nodes+=int(n.ambiguous)
		if n.branches.has(0):
			var b:Dictionary=n.branches[0]; dets.append(b.det); conditions.append(b.condition); smins.append(b.smin); heights.append(b.height)
			var j:Array=b.j; var gy:Array=b.height_gradient_q
			if absf(b.det)>1e-9: gradients.append(sqrt(pow((gy[0]*j[3]-gy[1]*j[2])/b.det,2)+pow((-gy[0]*j[1]+gy[1]*j[0])/b.det,2)))
			var lower:float=-INF
			for r in n.roots:
				if _distance(r.q,b.q)>0.00002 and r.height<b.height: lower=maxf(lower,r.height)
			if is_finite(lower): gaps.append(b.height-lower)
	for c in leaves:
		leaf_index+=1; var in_component:bool=connected.mask.has(leaf_index)
		var h:int=c[2]/2; var n:Dictionary=nodes[_node_key(c[0]+h,c[1]+h)]
		var x:float=(c[0]-512)*0.8/1024; var z:float=(c[1]-512)*0.8/1024; var width:float=c[2]*0.8/1024; var a:=width*width
		var memberships:Array=[]
		for coord in _cell_points(c):
			var v:Dictionary=nodes[_node_key(coord[0],coord[1])]; memberships.append(v.upper==0 and not v.ambiguous)
		var crossing:bool=memberships.has(true) and memberships.has(false)
		var uncertain_cell:bool=crossing or n.ambiguous or n.get("branch0_path_failed",false)
		if crossing:
			boundary_cells+=1
			max_boundary_cell=maxf(max_boundary_cell,width)
			boundary=minf(boundary,sqrt(pow(clampf(0,x,x+width),2)+pow(clampf(0,z,z+width),2)))
		if in_component:
			area+=a; bbox=[minf(bbox[0],x),minf(bbox[1],z),maxf(bbox[2],x+width),maxf(bbox[3],z+width)]
			if c[0]==0 or c[1]==0 or c[0]+c[2]==1024 or c[1]+c[2]==1024: edge_censored=true
		if n.branches.has(0): present+=a
		if uncertain_cell: uncertain+=a
		if OS.get_cmdline_user_args().has("--material-closure"):
			for measure in anchor_support:
				var anchor_weight:=_disk_rectangle(x-anchor_offset[0],z-anchor_offset[1],width,measure.diameter_m/2)
				if in_component and not uncertain_cell: measure.known_winner_area+=anchor_weight
				if in_component or uncertain_cell: measure.possible_winner_area+=anchor_weight
		var lower:float=-INF
		for r in n.roots:
			if not n.branches.has(0) or _distance(r.q,n.branches[0].q)>0.00002: lower=maxf(lower,r.height)
		for scale in scales:
			var half:float=scale.half_width_m; var clipped:=maxf(0,minf(x+width,half)-maxf(x,-half))*maxf(0,minf(z+width,half)-maxf(z,-half))
			if clipped==0: continue
			var circle_clip:=_disk_rectangle(x,z,width,half)
			for pair in [[scale,clipped],[scale.circle,circle_clip]]:
				var measure:Dictionary=pair[0]; var weight:float=pair[1]
				if weight==0: continue
				if in_component: measure.winner_area+=weight
				if in_component and not uncertain_cell: measure.known_full_winner_area+=weight
				if in_component or uncertain_cell: measure.possible_winner_area+=weight
				if n.branches.has(0): measure.present_area+=weight
				if uncertain_cell: measure.uncertain_area+=weight
				if n.has("height"):
					measure.weighted_y+=weight*n.height; measure.valid_area+=weight; measure.values.append([n.height,weight]); measure.max_y=maxf(measure.max_y,n.height)
				if is_finite(lower): measure.lower_area+=weight; measure.lower_y+=weight*lower
	for scale in scales:
		for measure in [scale,scale.circle]:
			measure["highest_component_fraction"]=measure.winner_area/measure.area_m2
			measure["highest_sheet_present_fraction"]=measure.present_area/measure.area_m2
			measure["uncertainty_fraction"]=measure.uncertain_area/measure.area_m2
			measure["support_lower_bound"]=maxf(0,(measure.winner_area-measure.uncertain_area)/measure.area_m2)
			measure["support_upper_bound"]=minf(1,(measure.winner_area+measure.uncertain_area)/measure.area_m2)
			if OS.get_cmdline_user_args().has("--material-closure"):
				measure["support_lower_bound"]=measure.known_full_winner_area/measure.area_m2
				measure["support_upper_bound"]=measure.possible_winner_area/measure.area_m2
			measure["area_weighted_upper_y"]=measure.weighted_y/measure.valid_area if measure.valid_area>0 else null
			measure["area_weighted_median_upper_y"]=_weighted_median(measure.values)
			measure["lower_dominant_area_weighted_y"]=measure.lower_y/measure.lower_area if measure.lower_area>0 else null
			measure["max_y"]=measure.max_y if is_finite(measure.max_y) else null
			measure.erase("values")
	var widths:Array=[bbox[2]-bbox[0],bbox[3]-bbox[1]] if area>0 else [0.0,0.0]
	if OS.get_cmdline_user_args().has("--material-closure"):
		for i in anchor_support.size():
			var measure:Dictionary=anchor_support[i]
			measure["support_lower_bound"]=measure.known_winner_area/measure.area_m2
			measure["support_upper_bound"]=minf(1,measure.possible_winner_area/measure.area_m2)
			measure["patch_censored"]=absf(anchor_offset[0])+measure.diameter_m/2>0.4 or absf(anchor_offset[1])+measure.diameter_m/2>0.4
			measure["world_offset_m"]=anchor_offset
			scales[i]["material_anchor_circle"]=measure
	connected["max_boundary_cell_m"]=max_boundary_cell
	return {"scales":scales,"projected_winner_area_m2":area,"sheet_present_area_m2":present,"uncertain_area_m2":uncertain,"equivalent_circle_diameter_m":sqrt(4*area/PI),"bbox_m":bbox if area>0 else null,"bbox_min_width_m":minf(widths[0],widths[1]),"bbox_max_width_m":maxf(widths[0],widths[1]),"min_feret_width_m":connected.min_feret_m,"max_feret_width_m":connected.max_feret_m,"winner_components":connected.groups,"central_component_unresolved":connected.central_cell_missing,"nearest_candidate_boundary_m":boundary if is_finite(boundary) else null,"patch_edge_censored":edge_censored,"finest_boundary_cell_m":finest*0.8/1024,"max_boundary_cell_m":max_boundary_cell,"boundary_cells":boundary_cells,"ambiguous_nodes":ambiguous_nodes,"nodes":nodes.size(),"leaves":leaves.size(),"budget_capped":capped,"fine_det":_percentiles(dets),"abs_fine_det":_percentiles(dets.map(func(v):return absf(v))),"condition":_percentiles(conditions),"smin":_percentiles(smins),"height":_percentiles(heights),"gap_to_next_lower":_percentiles(gaps),"world_height_gradient":_percentiles(gradients),"confidence":"bounded continuation; unidentified disconnected roots and subcell topology remain possible"}

func _audit_corpus() -> void:
	var at:=0
	var ordered_corpus:=_corpus.filter(func(r):return r.get("decisive",false))+_corpus.filter(func(r):return not r.get("decisive",false))
	var completed:Dictionary={}
	if OS.get_cmdline_user_args().has("--resume-results"):
		var previous:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_raw.json"))
		if not previous.get("checks",[]).is_empty(): audit["resume_history"]={"prior_run_errors":previous.checks.size(),"only_completed_cases_retained":true,"failure":"diagnostic shader compilation; reserved GLSL keyword corrected"}
		for c in previous.get("cases",[]): audit.cases.append(c); completed[_case_key(c.record)]=true
	for r in ordered_corpus:
		if completed.has(_case_key(r)): continue
		_anchor_weather(r)
		if not await _snapshot(int(r.config),r.time,true): audit.checks.append("audit snapshot"); continue
		var roots:=await _discover(r)
		print("SURFACE_CENTER_ROOTS="+r.label+"/"+str(roots.size()))
		if roots.is_empty(): audit.checks.append("no center root: "+r.label); continue
		var case:Dictionary={"record":r,"center_roots":roots,"temporal":[],"identity_uncertainty":[],"classification":"UNRESOLVED","method_variant":"decisive_fine_boundary" if r.get("decisive",false) else "corpus_fine_interiors" if OS.get_cmdline_user_args().has("--corpus-fine-interior") else "corpus_coarse_interiors"}
		var center_upper:Dictionary=roots[0]
		var temporal_predecessor:Dictionary=center_upper
		var offsets:Array=[0.0,-1.0/60,-2.0/60,-3.0/60,-4.0/60,1.0/60,2.0/60,3.0/60,4.0/60]
		for dt in offsets:
			if dt==1.0/60: temporal_predecessor=center_upper
			if r.time+dt<0: case.temporal.append({"dt":dt,"censored":"negative field time"}); continue
			if not await _snapshot(int(r.config),r.time+dt,true): audit.checks.append("temporal snapshot"); continue
			var current_roots:Array=roots if dt==0 else await _discover(r,roots.map(func(root_record):return root_record.q))
			if current_roots.is_empty(): case.temporal.append({"dt":dt,"unresolved":"no roots"}); continue
			var nearest:=INF; var id:=-1; var second:=INF
			for index in current_roots.size():
				var ds:=_distance(current_roots[index].q,temporal_predecessor.q)
				if ds<nearest: second=nearest; nearest=ds; id=index
				else: second=minf(second,ds)
			var identity_ambiguous:bool=dt!=0 and (nearest>0.1 or second-nearest<0.0001 or signf(current_roots[id].det)!=signf(temporal_predecessor.det))
			# Measure the central sheet's temporal predecessor candidate, rather
			# than silently relabeling every newly highest root as the same sheet.
			var linked:Dictionary=current_roots[id]; var ordered:=current_roots.duplicate(); ordered.erase(linked); ordered.push_front(linked)
			temporal_predecessor=linked
			var patch:=await _patch(r.target,ordered,r.get("decisive",false),dt==0 and r.get("decisive",false))
			var upper:Dictionary=current_roots[0]
			var temporal:Dictionary={"dt":dt,"absolute_time":r.time+dt,"matched_q":linked.q,"matched_y":linked.height,"matched_det":linked.det,"matched_smin":linked.smin,"matched_condition":linked.condition,"q_distance":nearest,"runner_up_q_distance":second,"identity_ambiguous":identity_ambiguous,"highest_at_target":_distance(linked.q,upper.q)<0.00002,"root_count":current_roots.size(),"upper_y":upper.height,"next_lower_y":current_roots[1].height if current_roots.size()>1 else null,"upper_next_gap":upper.height-current_roots[1].height if current_roots.size()>1 else null,"patch":patch}
			case.temporal.append(temporal)
			if identity_ambiguous: case.identity_uncertainty.append(dt)
			if dt==0: case["patch"]=patch
			print("SURFACE_TIME="+r.label+"/"+str(dt)+"/nodes="+str(patch.nodes))
		case["center_upper_next_gap"]=roots[0].height-roots[1].height if roots.size()>1 else null
		for capture in r.capture.values(): capture["correct_current_fine_reference"]=capture.valid and absf(capture.height-roots[0].height)<0.002
		case["capture_group"]="C" if r.capture.has("C") and not r.capture.C.correct_current_fine_reference else "B" if not r.capture.B.correct_current_fine_reference else "A" if r.capture.A.correct_current_fine_reference else "coarse_miss_dense_capture"
		if r.get("decisive",false): await _refine_temporal(case)
		_classify(case)
		audit.cases.append(case); at+=1
		FileAccess.open("res://.godot/phys_gpu_surface_contract_raw.json",FileAccess.WRITE).store_string(JSON.stringify(audit))
		print("SURFACE_CASE_COMPLETE="+str(at)+"/"+str(_corpus.size())+"/"+r.label)
		if OS.get_cmdline_user_args().has("--limit-one"): break

func _refine_temporal(case:Dictionary) -> void:
	var samples:Array=case.temporal.duplicate(); samples.sort_custom(func(a,b):return a.dt<b.dt)
	var brackets:Array=[]
	for i in range(1,samples.size()):
		var left:Dictionary=samples[i-1]; var right:Dictionary=samples[i]
		if not left.has("matched_q") or not right.has("matched_q"): continue
		if not left.identity_ambiguous and not right.identity_ambiguous and left.highest_at_target==right.highest_at_target: continue
		var refined:Array=[]; var previous_q:Array=left.matched_q; var previous_det:float=left.matched_det
		for part in range(1,8):
			var dt:float=lerpf(left.dt,right.dt,part/8.0)
			if not await _snapshot(int(case.record.config),case.record.time+dt,true): continue
			var roots:=await _discover(case.record,[previous_q]); var candidates:Array=[]
			for root_record in roots:
				if signf(root_record.det)==signf(previous_det): candidates.append(root_record)
			candidates.sort_custom(func(a,b):return _distance(a.q,previous_q)<_distance(b.q,previous_q))
			var link:Dictionary=candidates[0] if not candidates.is_empty() else {}
			var ambiguous:bool=link.is_empty() or _distance(link.q,previous_q)>0.03 or (candidates.size()>1 and _distance(candidates[1].q,previous_q)-_distance(link.q,previous_q)<0.0001)
			refined.append({"dt":dt,"root_count":roots.size(),"matched_q":link.get("q",null),"matched_y":link.get("height",null),"identity_ambiguous":ambiguous,"highest_at_target":not link.is_empty() and _distance(link.q,roots[0].q)<0.00002})
			if not link.is_empty(): previous_q=link.q; previous_det=link.det
		brackets.append({"from":left.dt,"to":right.dt,"step":1.0/480,"samples":refined,"interpretation":"candidate loss/rank transition; absence is not a completeness certificate"})
	case["temporal_refinement"]=brackets

func _classify(case:Dictionary) -> void:
	var before:=0.0; var after:=0.0; var prior_lost:=false; var next_lost:=false
	for direction in [-1,1]:
		var matching:Array=case.temporal.filter(func(s):return s.has("matched_q") and s.dt*direction>0)
		matching.sort_custom(func(a,b):return absf(a.dt)<absf(b.dt))
		for sample in matching:
			if sample.identity_ambiguous or not sample.highest_at_target:
				if direction<0: prior_lost=true
				else: next_lost=true
				break
			if direction<0: before=absf(sample.dt)
			else: after=sample.dt
	case["observed_lifetime"]={"seconds_before":before,"seconds_after":after,"left_censored":not prior_lost,"right_censored":not next_lost,"identity_or_rank_loss_before":prior_lost,"identity_or_rank_loss_after":next_lost}
	var p:Dictionary=case.patch
	var broad:bool=p.min_feret_width_m>=0.1 or p.scales[3].circle.support_lower_bound>=0.25
	var tiny:bool=p.min_feret_width_m<=0.01 and p.scales[2].circle.support_upper_bound<=0.1
	var persistent:bool=before+after>=2.0/60
	var transient:bool=prior_lost and next_lost and before+after<=1.0/60
	case["review_indicators"]={"broad":broad,"tiny":tiny,"persistent_two_ticks":persistent,"transient_one_tick":transient}
	if p.central_component_unresolved or p.budget_capped or p.scales[3].circle.uncertainty_fraction>0.1 or not case.identity_uncertainty.is_empty(): case.classification="UNRESOLVED"
	elif persistent: case.classification="PERSISTENT_BROAD" if broad else "PERSISTENT_NARROW"
	elif transient: case.classification="TRANSIENT_NARROW" if tiny else "TRANSIENT_BROAD" if broad else "UNRESOLVED"
	elif prior_lost or next_lost: case.classification="CAUSTIC_BIRTH_OR_DEATH" if case.center_roots[0].smin<0.02 else "UNRESOLVED"

func _width_closure() -> void:
	# Retain only integer cell rectangles of the measured connected winner.
	# This permits offline local-thickness analysis for the wider corpus
	# without archiving another full root search or a raw image sequence.
	var completed:Dictionary={}
	if OS.get_cmdline_user_args().has("--resume-width"):
		var previous:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_width.json"))
		for c in previous.cases: audit.cases.append(c); completed[c.label]=true
	for original in _corpus:
		var r:Dictionary=original.record
		if completed.has(r.label): continue
		_anchor_weather(r)
		if not await _snapshot(int(r.config),r.time,true): audit.checks.append("width snapshot"); continue
		var p:=await _patch(r.target,original.center_roots,false,true)
		var rectangles:Array=[]
		for c in p.map_cells:
			if c.central_component:
				rectangles.append([int(round((c.x+0.4)*1024/0.8)),int(round((c.z+0.4)*1024/0.8)),int(round(c.size*1024/0.8))])
		p.erase("map_cells"); p["known_component_rectangles"]=rectangles
		audit.cases.append({"label":r.label,"patch":p,"method_variant":"corpus_coarse_interiors_width_replay","main_area_difference_m2":p.projected_winner_area_m2-original.patch.projected_winner_area_m2})
		FileAccess.open("res://.godot/phys_gpu_surface_contract_width.json",FileAccess.WRITE).store_string(JSON.stringify(audit))
		print("SURFACE_WIDTH_CASE="+str(audit.cases.size())+"/"+str(_corpus.size())+"/"+r.label)

func _material_closure() -> void:
	# A fixed-XZ branch can cease intersecting the target while a broad sheet
	# remains nearby. Material q is the physical temporal anchor; rank at the
	# fixed target is a separate observation. Every 1/480 s sample checks its
	# fine orientation, conditioning and projected world position.
	var completed:Dictionary={}
	if OS.get_cmdline_user_args().has("--resume-material"):
		var previous:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_material.json"))
		for c in previous.cases:
			if c.get("complete",false): audit.cases.append(c); completed[c.label]=true
		if not previous.checks.is_empty(): audit["resume_history"]={"prior_errors":previous.checks,"only_complete_cases_retained":true}
	for original in _corpus:
		var r:Dictionary=original.record; var seed:Dictionary=original.center_roots[0]
		if completed.has(r.label): continue
		var errors_before:int=audit.checks.size()
		_anchor_weather(r)
		var case:Dictionary={"label":r.label,"record":r,"material_q":seed.q,"material_trace":[],"temporal":[],"identity_ambiguous":false}
		var previous_det:float=seed.det; var sign_changes:=0
		for step in range(-32,33):
			var dt:float=step/480.0
			if not await _snapshot(int(r.config),r.time+dt,true): audit.checks.append("material snapshot"); continue
			var material:Array=await _diagnose([{ "target":r.target,"seed":seed.q,"material":true }])
			if material.is_empty() or not material[0].valid: audit.checks.append("material eval"); continue
			var anchor:Dictionary=material[0]
			if _distance(anchor.q,seed.q)>0.000000001: audit.checks.append("material q seed not preserved")
			if signf(anchor.det)!=signf(previous_det): sign_changes+=1
			previous_det=anchor.det
			var regular:bool=signf(anchor.det)==signf(seed.det) and anchor.smin>=0.0001
			if not regular: case.identity_ambiguous=true
			case.material_trace.append({"dt":dt,"q":anchor.q,"world":anchor.world,"height":anchor.height,"fine_det":anchor.det,"smin":anchor.smin,"condition":anchor.condition,"regular_same_orientation":regular})
			if step%8!=0: continue
			var current_roots:=await _discover(r,[seed.q]); var point_trials:=await _diagnose([{ "target":r.target,"seed":anchor.q,"continuation":true,"orientation":signf(anchor.det) }])
			var point:Dictionary=point_trials[0]
			var counterparts:Array=[]
			for root_record in current_roots:
				if point.valid and _distance(root_record.q,point.q)<0.00002: continue
				counterparts.append(root_record)
			anchor["anchor_target"]=[anchor.world[0],anchor.world[2]]; counterparts.push_front(anchor)
			var entry:Dictionary={"dt":dt,"material_world":anchor.world,"fine_det":anchor.det,"material_regular":regular,"fixed_target_branch_valid":point.valid,"fixed_target_q":point.q if point.valid else null,"fixed_target_y":point.height if point.valid else null,"fixed_target_upper_y":current_roots[0].height if not current_roots.is_empty() else null,"fixed_target_highest":point.valid and not current_roots.is_empty() and _distance(point.q,current_roots[0].q)<0.00002}
			entry["fixed_target_root_count"]=current_roots.size()
			entry["fixed_target_next_lower_y"]=current_roots[1].height if current_roots.size()>1 else null
			entry["fixed_target_upper_next_gap"]=current_roots[0].height-current_roots[1].height if current_roots.size()>1 else null
			if dt==0: entry["center_reference_upper_difference_m"]=current_roots[0].height-seed.height if not current_roots.is_empty() else null
			if maxf(absf(anchor.world[0]-r.target[0]),absf(anchor.world[2]-r.target[1]))>0.4:
				entry["spatially_censored"]=true; case.identity_ambiguous=true
			else:
				entry["patch"]=await _patch(r.target,counterparts,true,dt==0)
			if dt==0: case["local_discovery_checks"]=await _local_discovery_grid(r,anchor,original.center_roots)
			case.temporal.append(entry)
			print("SURFACE_MATERIAL_TIME="+r.label+"/"+str(dt))
		case["material_orientation_sign_changes"]=sign_changes
		case["material_lifetime_censoring"]={"seconds_before":4.0/60,"seconds_after":4.0/60,"left_censored":true,"right_censored":true,"qualification":"continuous parametric material point; regular-sheet identity is uncertain at orientation/conditioning transitions"}
		case["complete"]=case.material_trace.size()==65 and case.temporal.size()==9 and audit.checks.size()==errors_before
		case["diagnostic_source_hashes"]=audit.diagnostic_source_hashes
		audit.cases.append(case)
		FileAccess.open("res://.godot/phys_gpu_surface_contract_material.json",FileAccess.WRITE).store_string(JSON.stringify(audit))
		print("SURFACE_MATERIAL_COMPLETE="+r.label)

func _local_discovery_grid(record:Dictionary,anchor:Dictionary,center_roots:Array) -> Array:
	var samples:Array=[]
	for ix in range(-4,5):
		for iz in range(-4,5):
			var r:Dictionary=record.duplicate(true)
			r.target=[record.target[0]+ix*0.1,record.target[1]+iz*0.1]
			r.reference.roots=center_roots.map(func(root_record):return {"q":root_record.q,"height":root_record.height})
			var roots:=await _discover(r)
			var path:=await _diagnose([{ "target":r.target,"seed":anchor.q,"orientation":signf(anchor.det),"continuation":true }])
			var row:Dictionary=path[0]
			samples.append({"offset":[ix*0.1,iz*0.1],"root_count":roots.size(),"roots":roots.map(func(root_record):return {"q":root_record.q,"height":root_record.height,"det":root_record.det,"residual":root_record.residual}),"original_sheet_path_valid":row.valid,"original_sheet_q":row.q if row.valid else null,"original_sheet_y":row.height if row.valid else null,"enumerated_upper_y":roots[0].height if not roots.is_empty() else null,"original_sheet_wins":row.valid and not roots.is_empty() and row.height>=roots[0].height-0.000005})
	return samples

func _capture_identity_status(capture:Dictionary,roots:Array) -> String:
	if not capture.valid or absf(capture.height-roots[0].height)>0.002: return "MISS"
	var nearest:=INF; var next:=INF; var id:=-1
	for i in roots.size():
		var ds:=_distance(capture.q,roots[i].q)
		if ds<nearest: next=nearest; nearest=ds; id=i
		else: next=minf(next,ds)
	if nearest>0.02 or next-nearest<0.0001: return "UNRESOLVED"
	if id==0: return "CAPTURE"
	return "MISS" if absf(capture.height-roots[id].height)<=0.002 else "UNRESOLVED"

func _strict_capture_closure() -> void:
	var raw:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_surface_contract_raw.json"))
	var samples:Array=[]; _tile_width=8.0
	if not await _create_atlas(2048,2048): audit.checks.append("strict capture atlas"); return
	for c in raw.cases:
		var r:Dictionary=c.record
		if r.capture.has("C") or _capture_identity_status(r.capture.B,c.center_roots)!="MISS": continue
		_anchor_weather(r)
		if not await _snapshot(int(r.config),r.time,true): audit.checks.append("strict capture snapshot"); continue
		var target:=Vector2(r.target[0],r.target[1])
		var result:=await _atlas_request(PackedVector3Array([Vector3(target.x,0.1,target.y)]),[{"slot":0,"vehicle_id":0,"generation":_occupant,"reset":true}],[{"center":target,"size":Vector2(_tile_width,_tile_width),"generation":_occupant}])
		_occupant+=1
		if result.is_empty(): audit.checks.append("strict capture request"); continue
		var row:=ENVELOPE.decode_envelope_contact(result,0)
		samples.append({"label":r.label,"C":{"valid":row.valid,"q":[row.q.x,row.q.y],"height":row.surface_y,"resolution":2048,"grid":2048,"tile_width":8.0}})
	await _retire_atlas()
	FileAccess.open("res://.godot/phys_gpu_surface_contract_strict_capture.json",FileAccess.WRITE).store_string(JSON.stringify({"samples":samples,"checks":audit.checks,"retirement":atlas_report.after_shutdown}))
	print("SURFACE_STRICT_CAPTURE_COMPLETE="+str(samples.size()))
