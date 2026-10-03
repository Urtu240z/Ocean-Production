extends "res://validation/physics/phys_gpu11_runner.gd"
## PHYS-GPU-1.2 offline only. The production shader is initially unchanged.
var _study_data:Dictionary={"phase":"PHYS-GPU-1.2","checks":[],"cpu_replay":[],"studies":[]}
var _snapshot_config:=-1
var _snapshot_time:=-INF
var _corpus:Array=[]
var _weather_start:=NAN

func _anchor_weather(failure:Dictionary) -> void:
	var start:float=failure.time-3.0*failure.alpha if failure.config>1 and failure.alpha<1 else NAN
	if is_finite(start)!=is_finite(_weather_start) or (is_finite(start) and absf(start-_weather_start)>1e-8): _snapshot_config=-1
	_weather_start=start

func _run() -> void:
	load(DESCRIPTOR)
	_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
	for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
	root.add_child(_ocean)
	var camera:=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current=true
	var light:=DirectionalLight3D.new(); root.add_child(light); light.rotation_degrees=Vector3(-45,-30,0)
	for _frame in 12: await process_frame
	_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT")
	_coastal=_fft.call("get_phys3_coastal_snapshot"); _query=_fft.call("enable_gpu_surface_queries")
	for _frame in 6: await process_frame
	_query.set_validation_metrics_enabled(true)
	_states=[{"name":"current","bands":_fft.call("get_phys2_band_spectrum_snapshots")}]
	for s in [["calm",0.8,4.0,20.0,0.8],["storm",3.0,18.0,75.0,2.0],["direction",3.0,18.0,20.0,2.0],["choppiness",3.0,18.0,20.0,2.5]]:
		var configs:Array=PROFILE.build_fft_configs(s[1],s[2],s[3],0.8,1.0); configs[0].choppiness=s[4]
		var builder:Object=ClassDB.instantiate("OceanQueryNative")
		var state:Dictionary=STATE.build(configs,1,s[1],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,builder)
		builder.call("prepare_production_spectrum",state.bands); _states.append({"name":s[0],"bands":state.bands,"native":builder})
	var current:Object=ClassDB.instantiate("OceanQueryNative"); current.call("prepare_production_spectrum",_states[0].bands); _states[0]["native"]=current
	_read_corpus()
	_study_data["bands"]=_states[0].bands.map(func(b): return {"domain":b.domain_size_m,"resolution":b.resolution})
	_study_data["coastal_rectangle"]={"origin":[_coastal.field_origin.x,_coastal.field_origin.y],"extent":[_coastal.field_extent.x,_coastal.field_extent.y]}
	_study_data["environment"]={"engine":Engine.get_version_info(),"gpu":RenderingServer.get_video_adapter_name(),"cpu":OS.get_processor_name(),"renderer":RenderingServer.get_current_rendering_method(),"driver":RenderingServer.get_current_rendering_driver_name()}
	if not OS.get_cmdline_user_args().has("--corpus-only"):
		var selected:Array=[]; var seen:Dictionary={}
		var connected:Dictionary={}
		if OS.get_cmdline_user_args().has("--connected-only"):
			var replay:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu12_corpus.json"))
			for row in replay.cpu_replay:
				if row.valid and int(row.status)==0: connected[int(row.ordinal)]=true
		for failure in _corpus:
			if OS.get_cmdline_user_args().has("--lateral-only") and failure.scenario!="lateral": continue
			if OS.get_cmdline_user_args().has("--connected-only") and not connected.has(int(failure.ordinal)): continue
			var key:String=failure.scenario+"/"+str(failure.owned)+"/"+str(failure.reason)+"/"+str(failure.config)
			if not seen.has(key) or failure.scenario=="lateral" or OS.get_cmdline_user_args().has("--connected-only"):
				seen[key]=true; selected.append(failure)
		for i in selected.size():
			if OS.get_cmdline_user_args().has("--comparison-only") or OS.get_cmdline_user_args().has("--gpu-replay-only"):
				var existing:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu12_connected.json"))
				for study in existing.studies:
					if int(study.failure.ordinal)==int(selected[i].ordinal):
						_study_data.studies.append(await _gpu_replay(selected[i],study) if OS.get_cmdline_user_args().has("--gpu-replay-only") else await _corrector_comparison(selected[i],study.best_history))
			else: await _root_study(selected[i])
			_save_study(); print("GPU12_STUDY="+str(i+1)+"/"+str(selected.size()))
	if not OS.get_cmdline_user_args().has("--study-only"): await _replay_corpus()
	_study_data["checks"].append_array(_proof.failures)
	_study_data["ring"]=_metrics(_query.get_stats()); var token:=_query; _ocean.queue_free()
	for _frame in 12: await process_frame
	_study_data["after_shutdown"]=_metrics(token.get_stats())
	if _native!=null: _native.call("clear")
	_save_study(); print("GPU12_DIAGNOSTIC_COMPLETE"); quit()

func _read_corpus() -> void:
	var file:=FileAccess.open("res://validation/physics/PHYS-GPU-1.1-FAILURES.csv",FileAccess.READ)
	var header:=file.get_csv_line()
	while not file.eof_reached():
		var values:=file.get_csv_line()
		if values.size()!=header.size(): continue
		var row:Dictionary={}
		for i in header.size():
			var key:String=header[i]; var value:String=values[i]
			if key in ["case","scenario","region","weather"]: row[key]=value
			elif key in ["owned","paused"]: row[key]=value=="true"
			else: row[key]=value.to_float()
		row["ordinal"]=_corpus.size(); _corpus.append(row)
	file.close()

func _snapshot(config:int,time:float,gpu:=false) -> bool:
	if config!=_snapshot_config or time<_snapshot_time-1e-9:
		if _native!=null: _native.call("clear")
		var sources:Array=[0,0,1,2,1,3]; var destinations:Array=[0,0,1,2,1,3,4]
		var starts:Array=[0.0,0.0,1001.0/60.0,2001.0/60.0,4001.0/60.0,5801.0/60.0,7801.0/60.0]
		_native=_new_mirror(_states[sources[config-1]].bands,time)
		if config>1: _native.call("transition_dynamic_spectrum",_states[sources[config-1]].native,_states[destinations[config]].native,_weather_start if is_finite(_weather_start) else starts[config],3.0)
		_snapshot_config=config
	_tick+=1
	for _i in 300:
		_native.call("advance_dynamic_async",_tick,time,time,1.0/60.0)
		var info:PackedInt64Array=_native.call("get_dynamic_snapshot_info")
		if info[0]==1 and absf(info[1]/1e9-time)<2e-9 and info[3]==(_native.call("get_dynamic_async_stats") as PackedInt64Array)[21]:
			_snapshot_time=time
			if gpu:
				_fft.call("queue_dynamic_spectrum",_native,_native.call("get_dynamic_snapshot_spectrum",false)); _fft.set("_wave_time",time)
				for _frame in 3: await process_frame
			return true
		await process_frame
	_study_data.checks.append("snapshot timeout"); return false

func _target_at(failure:Dictionary,time:float) -> Vector2:
	var count:int=int(failure.case.split("/")[0].split("x")[1])
	var pose:Dictionary=_pose(failure.scenario,time,int(failure.vehicle))
	return pose.center+_layout(count)[int(failure.contact)].rotated(pose.yaw)

func _material(x:float,z:float) -> PackedFloat64Array:
	return _native.call("sample_dynamic_material_q",x,z)

func _jac(x:float,z:float,e:=0.0001) -> Array:
	var xp:=_material(x+e,z); var xm:=_material(x-e,z); var zp:=_material(x,z+e); var zm:=_material(x,z-e)
	var a:float=1+(xp[2]-xm[2])/(2*e); var b:float=(zp[2]-zm[2])/(2*e)
	var c:float=(xp[4]-xm[4])/(2*e); var d:float=1+(zp[4]-zm[4])/(2*e)
	return [a,b,c,d,a*d-b*c]

func _contact_history(failure:Dictionary,prior_time:float) -> PackedFloat64Array:
	var x:float=failure.previous_q_x; var z:float=failure.previous_q_z
	var m:=_material(x,z); var previous:=PackedFloat64Array(); previous.resize(27)
	for i in 15: previous[i]=m[i]
	previous[15]=x; previous[16]=z
	var target:=_target_at(failure,prior_time); previous[18]=target.x; previous[19]=target.y
	previous[20]=prior_time; previous[25]=m[11]
	return previous

func _replay_corpus() -> void:
	var sorted:Array=_corpus.duplicate()
	sorted.sort_custom(func(a,b): return a.config<b.config or (a.config==b.config and a.time<b.time))
	var at:=0
	while at<sorted.size():
		var group:Array=[]; var first:Dictionary=sorted[at]
		while at<sorted.size() and sorted[at].config==first.config and sorted[at].time==first.time and sorted[at].alpha==first.alpha:
			group.append(sorted[at]); at+=1
		_anchor_weather(first)
		# Corpus lacks previous executed timestamp/J. One-tick row is explicitly
		# labeled reconstructed; detailed studies search the possible history.
		var previous:Array=[]
		if not await _snapshot(int(first.config),maxf(0,first.time-1.0/60.0)): return
		for failure in group: previous.append(_contact_history(failure,maxf(0,failure.time-1.0/60.0)) if failure.owned else PackedFloat64Array())
		if not await _snapshot(int(first.config),first.time): return
		for i in group.size():
			var failure:Dictionary=group[i]
			var cpu:PackedFloat64Array=_native.call("sample_dynamic_contact",failure.target_x,failure.target_z,previous[i])
			_study_data.cpu_replay.append({"ordinal":failure.ordinal,"class":failure.scenario+"/"+str(failure.owned)+"/"+str(failure.reason),"config":failure.config,"time":failure.time,
				"gpu_residual":failure.residual,"valid":cpu[0]>0.5,"status":cpu[17],"q":[cpu[15],cpu[16]],"residual":cpu[13],"det":cpu[25],"height":cpu[1],
				"distance_from_previous":sqrt(pow(cpu[15]-failure.previous_q_x,2)+pow(cpu[16]-failure.previous_q_z,2)),"iterations":cpu[14],
				"previous_det":previous[i][25] if failure.owned else 0,"history_time_assumption":"one tick; original timestamp not captured"})
		if at%100<group.size(): _save_study(); print("GPU12_CPU_REPLAY="+str(at)+"/"+str(sorted.size()))

func _correct(x:float,z:float,wx:float,wz:float,trust:=0.03,limit:=48,epsilon:=0.000001,orientation:=0.0) -> Dictionary:
	var initial_x:=x; var initial_z:=z
	var residual:=INF; var min_det:=INF; var sign_changes:=0; var previous_sign:=0.0
	for iteration in limit:
		var m:=_material(x,z); var rx:float=x+m[2]-wx; var rz:float=z+m[4]-wz; residual=sqrt(rx*rx+rz*rz)
		var j:=_jac(x,z,epsilon); min_det=minf(min_det,absf(j[4]))
		var current_sign:float=signf(j[4])
		if previous_sign!=0 and current_sign!=previous_sign: sign_changes+=1
		previous_sign=current_sign
		if residual<=0.000001: return {"valid":true,"q":[x,z],"residual":residual,"det":j[4],"physical_det":m[11],"height":m[1],"iterations":iteration,"distance":sqrt(pow(x-initial_x,2)+pow(z-initial_z,2)),"min_abs_det":min_det,"sign_changes":sign_changes}
		if absf(j[4])<1e-10: break
		if orientation!=0.0 and orientation*j[4]<=0.0: break
		var dx:float=(j[3]*rx-j[1]*rz)/j[4]; var dz:float=(-j[2]*rx+j[0]*rz)/j[4]
		var length:=sqrt(dx*dx+dz*dz); var scale:=minf(1,trust/maxf(length,1e-12)); var accepted:=false
		for trial in 16:
			var nx:=x-dx*scale; var nz:=z-dz*scale; var next:=_material(nx,nz)
			var guarded:bool=orientation!=0.0 and (_jac(nx,nz,epsilon)[4]*orientation<=0.0 or _jac((nx+x)*0.5,(nz+z)*0.5,epsilon)[4]*orientation<=0.0)
			if not guarded and sqrt(pow(nx+next[2]-wx,2)+pow(nz+next[4]-wz,2))<residual:
				x=nx; z=nz; accepted=true; break
			scale*=0.5
		if not accepted: break
	return {"valid":false,"q":[x,z],"residual":residual,"det":_jac(x,z,0.000001)[4],"min_abs_det":min_det,"sign_changes":sign_changes}

func _corrector_comparison(failure:Dictionary,history:Dictionary) -> Dictionary:
	_anchor_weather(failure)
	if not await _snapshot(int(failure.config),history.time): return {}
	var previous_j:=_jac(failure.previous_q_x,failure.previous_q_z)
	var velocity:=_material(failure.previous_q_x,failure.previous_q_z)
	var dt:float=failure.time-history.time
	var rx:float=failure.target_x-history.target[0]-velocity[8]*dt
	var rz:float=failure.target_z-history.target[1]-velocity[10]*dt
	var px:float=failure.previous_q_x; var pz:float=failure.previous_q_z
	var prediction:Dictionary={"usable":absf(previous_j[4])>1e-8,"previous_j":previous_j,"elapsed":dt}
	if prediction.usable:
		var dx:float=(previous_j[3]*rx-previous_j[1]*rz)/previous_j[4]
		var dz:float=(-previous_j[2]*rx+previous_j[0]*rz)/previous_j[4]
		var length:=sqrt(dx*dx+dz*dz); var scale:=minf(1.0,1.0/maxf(length,1e-12))
		px+=dx*scale; pz+=dz*scale; prediction["unclamped_delta"]=length
	if not await _snapshot(int(failure.config),failure.time): return {}
	var orientation:float=signf(previous_j[4])
	var variants:Dictionary={}
	variants["guarded_100um"]=_correct(failure.previous_q_x,failure.previous_q_z,failure.target_x,failure.target_z,0.072265625,128,0.0001,orientation)
	variants["guarded_1um"]=_correct(failure.previous_q_x,failure.previous_q_z,failure.target_x,failure.target_z,0.072265625,128,0.000001,orientation)
	variants["velocity_predictor_guarded_1um"]=_correct(px,pz,failure.target_x,failure.target_z,0.072265625,128,0.000001,orientation)
	prediction["q"]=[px,pz]
	return {"failure":failure,"history":history,"predictor":prediction,"variants":variants,"current_anchor_j":_jac(failure.previous_q_x,failure.previous_q_z)}

func _gpu_replay(failure:Dictionary,study:Dictionary) -> Dictionary:
	_anchor_weather(failure)
	var history:Dictionary=study.best_history
	if not await _snapshot(int(failure.config),history.time,true): return {}
	var desc:Dictionary={"slot":0,"vehicle_id":12000,"contact_id":0,"generation":_occupant,"owned_seed":true,"hint_q":Vector2(failure.previous_q_x,failure.previous_q_z)}
	var initial:=await _contact_request(PackedVector2Array([Vector2(history.target[0],history.target[1])]),[desc])
	var previous:=_decode(initial,0); desc.erase("owned_seed"); desc.erase("hint_q")
	if not await _snapshot(int(failure.config),failure.time,true): return {}
	var result:=await _contact_request(PackedVector2Array([Vector2(failure.target_x,failure.target_z)]),[desc])
	var row:=_decode(result,0)
	var reference:Dictionary=study.fine[3].path[-1].root
	var gpu_us:=-1.0
	for sample in _query.get_stats().gpu_samples:
		if int(sample.get("generation",-1))==int(result.generation): gpu_us=sample.gpu_us
	_occupant+=1
	return {"failure":failure,"history":history,"previous_valid":previous.valid,
		"same_previous_fp32_q":previous.q==Vector2(failure.previous_q_x,failure.previous_q_z),"previous_q":[previous.q.x,previous.q.y],
		"valid":row.valid,"owned":row.owned,"q":[row.q.x,row.q.y],"residual":row.residual,"status":row.status,"reason":row.reason,"solves":row.solves,"iterations":row.iterations,
		"reference_endpoint_valid":study.fine[3].endpoint_valid,"reference_q":reference.q,
		"reference_distance":row.q.distance_to(Vector2(reference.q[0],reference.q[1])) if study.fine[3].endpoint_valid else -1.0,"gpu_us":gpu_us}

func _root_study(failure:Dictionary) -> void:
	_anchor_weather(failure)
	var report:Dictionary={"failure":failure,"roots":[],"history_candidates":[],"fine":[]}
	var best:Dictionary={}; var best_error:=INF
	if failure.owned:
		for ticks_back in range(1,9):
			var prior_time:float=maxf(0,failure.time-ticks_back/60.0)
			if not await _snapshot(int(failure.config),prior_time): return
			var m:=_material(failure.previous_q_x,failure.previous_q_z); var target:=_target_at(failure,prior_time)
			var residual:=sqrt(pow(failure.previous_q_x+m[2]-target.x,2)+pow(failure.previous_q_z+m[4]-target.y,2))
			var candidate:Dictionary={"ticks_back":ticks_back,"time":prior_time,"residual":residual,"physical_det":m[11],"local_det":_jac(failure.previous_q_x,failure.previous_q_z)[4],"target":[target.x,target.y],"material":Array(m)}
			report.history_candidates.append(candidate)
			if residual<best_error: best_error=residual; best=candidate
		report["best_history"]=best
		# Refine to a 1 µm residual; then independently follow 60/120/240/480Hz.
		for hz in [60,120,240,480]:
			if not await _snapshot(int(failure.config),best.time): return
			var start:=_correct(failure.previous_q_x,failure.previous_q_z,best.target[0],best.target[1])
			var path:Array=[{"time":best.time,"target":best.target,"root":start}]
			var root:Dictionary=start; var count:int=maxi(1,ceili((failure.time-best.time)*hz-1e-8))
			for step in range(1,count+1):
				if not root.valid: break
				var time:float=lerpf(best.time,failure.time,float(step)/count)
				if not await _snapshot(int(failure.config),time): return
				var target:=_target_at(failure,time)
				if step==count: target=Vector2(failure.target_x,failure.target_z)
				root=_correct(root.q[0],root.q[1],target.x,target.y)
				path.append({"time":time,"target":[target.x,target.y],"root":root})
			report.fine.append({"hz":hz,"path":path,"endpoint_valid":root.valid and path.size()==count+1})
	if not await _snapshot(int(failure.config),failure.time,true): return
	# 17x17 local seed grid plus broad deterministic rings around previous and
	# target. Discovery only: this is not exhaustive global root certification.
	var target:=Vector2(failure.target_x,failure.target_z); var anchor:=Vector2(failure.previous_q_x,failure.previous_q_z)
	var points:=PackedVector2Array(); var seeds:=PackedVector2Array()
	for center in [anchor,target]:
		for ix in range(-8,9):
			for iz in range(-8,9): points.append(target); seeds.append(center+Vector2(ix,iz)*0.25)
		for radius in [0.05,0.1,0.5,1.0,2.0,4.0,8.0]:
			for i in 16: points.append(target); seeds.append(center+Vector2.from_angle(i*TAU/16)*radius)
	var result:=await _request(points,true,seeds,false,failure.time)
	if result.is_empty(): return
	for i in seeds.size():
		if result.bytes.decode_float(i*96+28)<0.5: continue
		var root:=_correct(result.bytes.decode_float(i*96),result.bytes.decode_float(i*96+4),failure.target_x,failure.target_z,0.02,24)
		if not root.valid: continue
		var duplicate:=false
		for old in report.roots:
			if sqrt(pow(old.q[0]-root.q[0],2)+pow(old.q[1]-root.q[1],2))<0.002: duplicate=true; break
		if not duplicate:
			root["distance_from_previous"]=sqrt(pow(root.q[0]-failure.previous_q_x,2)+pow(root.q[1]-failure.previous_q_z,2)); report.roots.append(root)
	report["seed_count"]=seeds.size()
	if failure.scenario=="lateral":
		report["local_pair"]=await _lateral_pair_study(failure,report.fine[3].path)
		report["cell_continuation"]=await _cell_continuation(failure,best)
	var previous:=PackedFloat64Array()
	if failure.owned:
		if not await _snapshot(int(failure.config),best.time): return
		previous=_contact_history(failure,best.time)
		if not await _snapshot(int(failure.config),failure.time): return
	var cpu:PackedFloat64Array=_native.call("sample_dynamic_contact",failure.target_x,failure.target_z,previous)
	report["cpu_contact"]={"valid":cpu[0]>0.5,"q":[cpu[15],cpu[16]],"residual":cpu[13],"status":cpu[17],"det":cpu[25],"height":cpu[1],"distance":sqrt(pow(cpu[15]-failure.previous_q_x,2)+pow(cpu[16]-failure.previous_q_z,2))}
	_study_data.studies.append(report)

func _partition(lo:float,hi:float) -> Array:
	var edges:Array=[lo,hi]
	for b in _states[0].bands:
		var cell:float=b.domain_size_m/b.resolution
		for i in range(floori(lo/cell-0.5)-1,ceili(hi/cell-0.5)+2):
			var edge:float=(i+0.5)*cell
			if edge>lo+1e-10 and edge<hi-1e-10: edges.append(edge)
	edges.sort()
	var unique:Array=[]
	for edge in edges:
		if unique.is_empty() or edge-unique[-1]>1e-9: unique.append(edge)
	return unique

func _open_bilinear_roots(failure:Dictionary,cx:float,cz:float,radius:float,time:float) -> Dictionary:
	var xs:=_partition(cx-radius,cx+radius); var zs:=_partition(cz-radius,cz+radius)
	var nodes:Array=[]; var error:=0.0; var roots:Array=[]; var degenerate:=0
	var target:=_target_at(failure,time)
	if absf(time-failure.time)<1e-9: target=Vector2(failure.target_x,failure.target_z)
	for x in xs:
		var row:Array=[]
		for z in zs:
			var m:=_material(x,z); row.append([x+m[2]-target.x,z+m[4]-target.y])
		nodes.append(row)
	for ix in xs.size()-1:
		for iz in zs.size()-1:
			var c00:Array=nodes[ix][iz]; var c10:Array=nodes[ix+1][iz]; var c01:Array=nodes[ix][iz+1]; var c11:Array=nodes[ix+1][iz+1]
			var a:Array=[c00[0],c10[0]-c00[0],c01[0]-c00[0],c11[0]-c10[0]-c01[0]+c00[0]]
			var b:Array=[c00[1],c10[1]-c00[1],c01[1]-c00[1],c11[1]-c10[1]-c01[1]+c00[1]]
			var mx:float=(xs[ix]+xs[ix+1])*0.5; var mz:float=(zs[iz]+zs[iz+1])*0.5; var m:=_material(mx,mz)
			error=maxf(error,absf(mx+m[2]-target.x-(a[0]+0.5*a[1]+0.5*a[2]+0.25*a[3])))
			error=maxf(error,absf(mz+m[4]-target.y-(b[0]+0.5*b[1]+0.5*b[2]+0.25*b[3])))
			var aa:float=b[1]*a[3]-b[3]*a[1]
			var bb:float=b[0]*a[3]+b[1]*a[2]-b[2]*a[1]-b[3]*a[0]
			var cc:float=b[0]*a[2]-b[2]*a[0]
			var us:Array=[]
			if absf(aa)<1e-16:
				if absf(bb)>1e-16: us.append(-cc/bb)
				elif absf(cc)<1e-16: degenerate+=1
			else:
				var disc:float=bb*bb-4*aa*cc
				if disc>=0:
					var q:float=-0.5*(bb+(1.0 if bb>=0 else -1.0)*sqrt(disc))
					if absf(q)>1e-20: us.append(q/aa); us.append(cc/q)
					else: us.append(-bb/(2*aa))
			for u in us:
				if u< -1e-8 or u>1+1e-8: continue
				var den_a:float=a[2]+a[3]*u; var den_b:float=b[2]+b[3]*u
				if maxf(absf(den_a),absf(den_b))<1e-16: continue
				var v:float=-(a[0]+a[1]*u)/den_a if absf(den_a)>absf(den_b) else -(b[0]+b[1]*u)/den_b
				if v< -1e-8 or v>1+1e-8: continue
				var qx:float=lerpf(xs[ix],xs[ix+1],u); var qz:float=lerpf(zs[iz],zs[iz+1],v)
				var material:=_material(qx,qz)
				var residual:=sqrt(pow(qx+material[2]-target.x,2)+pow(qz+material[4]-target.y,2))
				if residual>1e-7: continue
				var dx:float=xs[ix+1]-xs[ix]; var dz:float=zs[iz+1]-zs[iz]
				var determinant:float=((a[1]+a[3]*v)*(b[2]+b[3]*u)-(a[2]+a[3]*u)*(b[1]+b[3]*v))/(dx*dz)
				var duplicate:=false
				for old in roots:
					if sqrt(pow(old.q[0]-qx,2)+pow(old.q[1]-qz,2))<1e-5: duplicate=true; break
				if not duplicate: roots.append({"q":[qx,qz],"residual":residual,"det":determinant,"height":material[1],"cell":[xs[ix],xs[ix+1],zs[iz],zs[iz+1]]})
	var outside:bool=cx+radius<_coastal.field_origin.x or cx-radius>_coastal.field_origin.x+_coastal.field_extent.x or cz+radius<_coastal.field_origin.y or cz-radius>_coastal.field_origin.y+_coastal.field_extent.y
	return {"time":time,"target":[target.x,target.y],"q_box":[cx-radius,cx+radius,cz-radius,cz+radius],"outside_coastal":outside,"cells":(xs.size()-1)*(zs.size()-1),"degenerate_cells":degenerate,"bilinear_midpoint_error":error,"roots":roots}

func _cell_continuation(failure:Dictionary,history:Dictionary) -> Dictionary:
	# Offline only: shrink time steps until a unique nearby root is isolated.
	# This follows exact cell roots rather than treating Newton failure as death.
	var time:float=history.time; var qx:float=failure.previous_q_x; var qz:float=failure.previous_q_z
	if not await _snapshot(int(failure.config),time): return {}
	var initial:=_open_bilinear_roots(failure,qx,qz,0.5,time)
	initial.roots.sort_custom(func(a,b): return pow(a.q[0]-qx,2)+pow(a.q[1]-qz,2)<pow(b.q[0]-qx,2)+pow(b.q[1]-qz,2))
	if initial.roots.is_empty(): return {"unresolved":"no isolated start root","initial":initial}
	qx=initial.roots[0].q[0]; qz=initial.roots[0].q[1]
	var path:Array=[{"time":time,"root":initial.roots[0]}]; var rejected:Array=[]; var dt:=1.0/480.0
	for iteration in 4096:
		if time>=failure.time-1e-9: return {"endpoint_valid":true,"path":path,"rejected":rejected,"initial":initial}
		var next_time:float=minf(time+dt,failure.time)
		if not await _snapshot(int(failure.config),next_time): return {}
		var frame:=_open_bilinear_roots(failure,qx,qz,0.5,next_time)
		frame.roots.sort_custom(func(a,b): return pow(a.q[0]-qx,2)+pow(a.q[1]-qz,2)<pow(b.q[0]-qx,2)+pow(b.q[1]-qz,2))
		var distance:float=INF if frame.roots.is_empty() else sqrt(pow(frame.roots[0].q[0]-qx,2)+pow(frame.roots[0].q[1]-qz,2))
		var isolated:bool=frame.roots.size()<2 or sqrt(pow(frame.roots[1].q[0]-qx,2)+pow(frame.roots[1].q[1]-qz,2))>distance*3.0
		if frame.degenerate_cells==0 and frame.bilinear_midpoint_error<1e-9 and frame.outside_coastal and distance<=0.03 and isolated:
			qx=frame.roots[0].q[0]; qz=frame.roots[0].q[1]; time=next_time
			path.append({"time":time,"root":frame.roots[0],"dt":dt,"neighbours":frame.roots.size()}); dt=minf(dt*1.5,1.0/480.0)
		else:
			rejected.append({"time":next_time,"dt":dt,"roots":frame.roots,"distance":distance,"isolated":isolated})
			if dt<=1.0/491520.0:
				return {"endpoint_valid":false,"path":path,"rejected":rejected,"terminal_frame":frame,"initial":initial,"unresolved":"adaptive time floor reached; not a termination certificate"}
			dt*=0.5
	return {"endpoint_valid":false,"path":path,"rejected":rejected,"unresolved":"adaptive iteration bound"}

func _lateral_pair_study(failure:Dictionary,path:Array) -> Dictionary:
	var valid:Array=path.filter(func(p): return p.root.valid)
	var failed:Array=path.filter(func(p): return not p.root.valid)
	if valid.is_empty() or failed.is_empty(): return {"unresolved":"no bracketing fine path"}
	var lo:float=valid[-1].time; var hi:float=failed[0].time
	var cx:float=failed[0].root.q[0]; var cz:float=failed[0].root.q[1]
	var frames:Array=[]
	for time in [lo,hi,failure.time]:
		if not await _snapshot(int(failure.config),time): return {}
		frames.append(_open_bilinear_roots(failure,cx,cz,1.0,time))
	var bisection:Array=[]
	for i in 10:
		var time:float=(lo+hi)*0.5
		if not await _snapshot(int(failure.config),time): return {}
		var frame:=_open_bilinear_roots(failure,cx,cz,1.0,time); bisection.append(frame)
		if frame.roots.is_empty(): hi=time
		else: lo=time
	return {"frames":frames,"bisection":bisection,"time_bracket":[lo,hi],"interpretation":"exact local bilinear patch enumeration, not a Newton-seed exhaustion argument"}

func _save_study() -> void:
	var path:String="res://.godot/phys_gpu12_study.json" if OS.get_cmdline_user_args().has("--study-only") else "res://.godot/phys_gpu12_corpus.json" if OS.get_cmdline_user_args().has("--corpus-only") else "res://.godot/phys_gpu12_diagnostics.json"
	if OS.get_cmdline_user_args().has("--connected-only"): path="res://.godot/phys_gpu12_connected.json"
	if OS.get_cmdline_user_args().has("--lateral-only"): path="res://.godot/phys_gpu12_lateral.json"
	if OS.get_cmdline_user_args().has("--comparison-only"): path="res://.godot/phys_gpu12_comparison.json"
	if OS.get_cmdline_user_args().has("--gpu-replay-only"): path="res://.godot/phys_gpu12_gpu_after.json" if OS.get_cmdline_user_args().has("--after") else "res://.godot/phys_gpu12_gpu_before.json"
	var file:=FileAccess.open(path,FileAccess.WRITE); file.store_string(JSON.stringify(_study_data)); file.close()
