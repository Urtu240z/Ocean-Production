extends "res://validation/physics/phys_gpu1_runner.gd"
## Diagnostic replay of the original generator; no runtime/shader edits.
var _baseline := {"bins":{},"failure_records":[],"probes":[]}
var _packets: Dictionary = {}
var _last_success := PackedInt32Array()

func _run() -> void:
	load(DESCRIPTOR)
	_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
	for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
	root.add_child(_ocean)
	var camera:=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current=true
	for _frame in 12: await process_frame
	_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT")
	_coastal=_fft.call("get_phys3_coastal_snapshot"); _query=_fft.call("enable_gpu_surface_queries")
	for _frame in 6: await process_frame
	_make_points(); _last_success.resize(256); _last_success.fill(-1)
	var states:Array=[{"bands":_fft.call("get_phys2_band_spectrum_snapshots")}]
	for s in [[0.8,4.0,20.0,0.8],[3.0,18.0,75.0,2.0]]:
		var configs:Array=PROFILE.build_fft_configs(s[0],s[1],s[2],0.8,1.0); configs[0].choppiness=s[3]
		var builder:Object=ClassDB.instantiate("OceanQueryNative")
		var state:Dictionary=STATE.build(configs,1,s[0],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,builder)
		builder.call("prepare_production_spectrum",state.bands); states.append({"bands":state.bands,"native":builder})
	_native=_new_mirror(states[1].bands,0.0)
	var source:Object=ClassDB.instantiate("OceanQueryNative"); source.call("prepare_production_spectrum",states[1].bands)
	var history:=PackedVector2Array(); history.resize(256)
	var valid:=PackedByteArray(); valid.resize(256)
	var simulation_time:=0.0; var submitted:=0
	for tick in 10000:
		await physics_frame
		if tick<4000 or tick>=4200: simulation_time+=1.0/60.0
		if tick==2000: _native.call("transition_dynamic_spectrum",source,states[2].native,simulation_time,3.0)
		if tick==6000: _native.call("transition_dynamic_spectrum",states[2].native,states[1].native,simulation_time,3.0)
		_native.call("advance_dynamic_async",20000+tick,simulation_time,simulation_time,1.0/60.0)
		var weather:Array=_native.call("get_dynamic_snapshot_spectrum",false)
		if weather.size()==3: _fft.call("queue_dynamic_spectrum",_native,weather)
		_fft.set("_wave_time",simulation_time)
		var count:int=BATCHES[tick%BATCHES.size()]; var world:=tick%2==1
		var packet:=QUERY.pack_queries(_points.slice(0,count),world,history.slice(0,count) if world else PackedVector2Array())
		if world:
			for i in count: packet.encode_u32(i*32+20,valid[i])
		var generation:int=_query.submit(packet,Engine.get_physics_frames(),NAN,tick%3==0)
		if generation>0:
			submitted+=1; _packets[generation]={"packet":packet,"tick":tick,"last":_last_success.duplicate()}
		_classify(_query.consume(Engine.get_physics_frames()),history,valid)
		for key in _packets.keys():
			if key<generation-16: _packets.erase(key)
		if tick%1000==0: print("GPU11_BASELINE="+str(tick))
	for _frame in 12:
		await process_frame; _classify(_query.consume(Engine.get_physics_frames()),history,valid)
	_baseline["submitted"]=submitted; _baseline["stats"]=_query.get_stats()
	_baseline["failure_count"]=_baseline.failure_records.size()
	for bin in _baseline.bins.values():
		for key in ["failed_residual","failed_iterations","seed_age"]: bin[key]=_distribution(bin[key])
	await _probe_roots(states)
	_save(); _native.call("clear"); _ocean.queue_free()
	for _frame in 12: await process_frame
	_baseline["after_shutdown"]=_query.get_stats(); _save()
	print("GPU11_BASELINE_COMPLETE="+str(_baseline.failure_count)); quit()

func _classify(result:Dictionary,history:PackedVector2Array,valid:PackedByteArray) -> void:
	if result.is_empty() or not _packets.has(result.generation): return
	var submitted:Dictionary=_packets[result.generation]; var packet:PackedByteArray=submitted.packet
	var bytes:PackedByteArray=result.bytes
	if result.first_mode!=1: _packets.erase(result.generation); return
	for i in int(result.count):
		var base:int=i*int(result.stride); var warm:bool=packet.decode_u32(i*32+20)!=0
		var success:bool=bytes.decode_float(base+28)>0.5
		var folded:bool=bytes.decode_float(base+(44 if result.stride==96 else 44))<=0
		var transition:bool=result.weather_alpha>0 and result.weather_alpha<1
		var age:int=int(submitted.tick)-int(submitted.last[i])
		for label in ["all","warm" if warm else "cold","region/"+_labels[i],"folded_final" if folded else "nonfolded_final","transition" if transition else "steady","config/"+str(result.config_version)]:
			var bin:Dictionary=_baseline.bins.get(label,{"queries":0,"failures":0,"failed_residual":[],"failed_iterations":[],"seed_age":[]})
			bin.queries+=1
			if warm: bin.seed_age.append(age)
			if not success:
				bin.failures+=1; bin.failed_residual.append(bytes.decode_float(base+8)); bin.failed_iterations.append(bytes.decode_float(base+12))
			_baseline.bins[label]=bin
		if success:
			history[i]=Vector2(bytes.decode_float(base),bytes.decode_float(base+4)); valid[i]=1; _last_success[i]=int(submitted.tick)
		else:
			_baseline.failure_records.append({"generation":result.generation,"vehicle":i/8,"contact":i%8,"index":i,"time":result.sample_time,"tick":submitted.tick,
				"target":[_points[i].x,_points[i].y],"previous_q":[packet.decode_float(i*32+8),packet.decode_float(i*32+12)],"warm":warm,"seed_age":age,
				"final_q":[bytes.decode_float(base),bytes.decode_float(base+4)],"residual":bytes.decode_float(base+8),"iterations":bytes.decode_float(base+12),
				"det":bytes.decode_float(base+44),"region":_labels[i],"config":result.config_version,"alpha":result.weather_alpha})
	_packets.erase(result.generation)

func _probe_roots(states:Array) -> void:
	var chosen:Dictionary={}
	for failure in _baseline.failure_records:
		var key:String=str(failure.config)+"/"+failure.region+"/"+str(failure.warm)
		if chosen.has(key): continue
		chosen[key]=true
		_native.call("clear")
		var config:int=failure.config
		_native=_new_mirror(states[1 if config!=3 else 2].bands,float(failure.time))
		if config>=2:
			var source:Object=ClassDB.instantiate("OceanQueryNative"); source.call("prepare_production_spectrum",states[1 if config==2 else 2].bands)
			_native.call("transition_dynamic_spectrum",source,states[2 if config==2 else 1].native,2001.0/60.0 if config==2 else 5801.0/60.0,3.0)
		if not await _at(float(failure.time)): return
		var target:=Vector2(failure.target[0],failure.target[1]); var prior:=Vector2(failure.previous_q[0],failure.previous_q[1])
		var targets:=PackedVector2Array(); var seeds:=PackedVector2Array()
		for center in [prior,target]:
			for delta in [Vector2.ZERO,Vector2(0.05,0),Vector2(-0.05,0),Vector2(0,0.05),Vector2(0,-0.05),Vector2(0.5,0),Vector2(-0.5,0),Vector2(0,0.5),Vector2(0,-0.5)]:
				targets.append(target); seeds.append(center+delta)
		var result:=await _request(targets,true,seeds,false,float(failure.time))
		var successful:=0; var minimum:=INF
		for i in seeds.size():
			if result.bytes.decode_float(i*96+28)>0.5: successful+=1
			minimum=minf(minimum,result.bytes.decode_float(i*96+8))
		_baseline.probes.append({"failure":failure,"seeds":seeds.size(),"valid_roots":successful,"min_residual":minimum})
		if chosen.size()>=12: break

func _save() -> void:
	var file:=FileAccess.open("res://.godot/phys_gpu11_baseline.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(_baseline)); file.close()
