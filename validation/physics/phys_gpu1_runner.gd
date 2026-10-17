extends SceneTree
## Real Forward+/D3D12 renderer; deterministic oracle matrix and async stress.
const OCEAN_SCENE = preload("res://addons/ocean/ocean.tscn")
const BAKE = preload("res://validation/p4_paradise/coastal_bake.tres")
const ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const QUERY = preload("res://addons/ocean/physics/gpu/ocean_surface_query.gd")
const PROFILE = preload("res://addons/ocean/resources/default_wave_profile.tres")
const STATE = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
const DESCRIPTOR = "res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension"
const BATCHES = [4,8,32,64,80,128,160,256]
var _ocean: Node
var _fft: Node
var _query: RefCounted
var _native: Object
var _coastal: Dictionary
var _points := PackedVector2Array()
var _labels: Array[String] = []
var _tick := 0
var _parity_bins: Dictionary = {}
var _world_bins: Dictionary = {}
var _report := {"status": "PARTIAL", "matrix": [], "batch": [], "failures": [], "world": [], "api": {}}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	load(DESCRIPTOR)
	if not ClassDB.class_exists("OceanQueryNative"): _fail("native extension unavailable"); return
	_report["engine"] = Engine.get_version_info()
	_report["driver"] = RenderingServer.get_current_rendering_driver_name()
	_report["renderer"] = RenderingServer.get_current_rendering_method()
	_report["gpu"] = RenderingServer.get_video_adapter_name()
	_report["cpu"] = OS.get_processor_name()
	_report["frame_queue"] = ProjectSettings.get_setting("rendering/rendering_device/vsync/frame_queue_size")
	for method in ClassDB.class_get_method_list("RenderingDevice"):
		if method.name == "buffer_get_data_async": _report.api = method
	_ocean = OCEAN_SCENE.instantiate()
	_ocean.set("coastal_bake", BAKE); _ocean.set("coastal", true)
	for property in ["breakers", "crest_foam", "surface_foam"]: _ocean.set(property, false)
	root.add_child(_ocean)
	var camera := Camera3D.new(); root.add_child(camera)
	camera.position = Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current = true
	var light := DirectionalLight3D.new(); root.add_child(light); light.rotation_degrees = Vector3(-45,-30,0)
	for _i in 12: await process_frame
	_ocean.set("wave_speed_multiplier", 0.0)
	_fft = _ocean.get_node("OpenOceanFFT")
	_coastal = _fft.call("get_phys3_coastal_snapshot")
	var initial: Array = _fft.call("get_phys2_band_spectrum_snapshots")
	if initial.size() != 3 or not _coastal.get("active", false): _fail("three bands/Coastal missing"); return
	_report["bands"] = initial.map(func(s): return {"band": s.band, "resolution": s.resolution, "domain": s.domain_size_m})
	_report["coastal"] = {"field_size": str(_coastal.field_resolution), "warp_size": str(_coastal.warp_resolution),
		"origin": str(_coastal.field_origin), "extent": str(_coastal.field_extent)}
	_query = _fft.call("enable_gpu_surface_queries")
	if _query != null: _query.set_validation_metrics_enabled(true)
	for _i in 6: await process_frame
	if _query == null or not _query.get_stats().ready: _fail("query initialization: " + str(_query.get_stats() if _query else {})); return
	_make_points()
	var states: Array = [{"name": "current", "bands": initial}]
	for s in [["calm",0.8,4.0,20.0,0.8],["storm",3.0,18.0,75.0,2.0],["direction",3.0,18.0,20.0,2.0]]:
		var configs: Array = PROFILE.build_fft_configs(s[1],s[2],s[3],0.8,1.0); configs[0].choppiness = s[4]
		var builder: Object = ClassDB.instantiate("OceanQueryNative")
		var state: Dictionary = STATE.build(configs,1,s[1],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,builder)
		if not builder.call("prepare_production_spectrum",state.bands): _fail("weather endpoint import"); return
		states.append({"name": s[0], "bands": state.bands, "native": builder})
	var smoke := OS.get_cmdline_user_args().has("--smoke")
	var matrix_only := OS.get_cmdline_user_args().has("--matrix-only")
	_report["ocean_cost"] = []
	for enabled in [false,true]:
		for solver in _fft.get("_solvers"): RenderingServer.call_on_render_thread(solver.set_query_fields_enabled.bind(enabled))
		for _warmup in 8: await process_frame
		var first: int = _query.get_stats().ocean_gpu_us.size()
		for _frame in 40: await process_frame
		_report.ocean_cost.append({"velocity_packing":enabled,"gpu_us":_distribution(_query.get_stats().ocean_gpu_us.slice(first))})
	for state in (states.slice(0,1) if smoke else states):
		_native = _new_mirror(state.bands,0.36)
		if _native == null: return
		for time in ([0.36] if smoke else [0.36,2.25,16.89]):
			if not await _at(time): return
			var result := await _request(_points,false,PackedVector2Array(),false,time)
			if result.is_empty(): return
			_compare(result,state.name)
			await _world(result,state.name)
		_native.call("clear")
	if not smoke:
		for pair in [[1,2],[2,1],[2,3]]:
			_native = _new_mirror(states[pair[0]].bands,9.0)
			var source: Object = ClassDB.instantiate("OceanQueryNative"); source.call("prepare_production_spectrum",states[pair[0]].bands)
			if not _native.call("transition_dynamic_spectrum",source,states[pair[1]].native,10.0,3.0): _fail("transition rejected"); return
			for time in [10.0,10.3,11.5,12.7,13.0]:
				if not await _at(time): return
				var result := await _request(_points,false,PackedVector2Array(),false,time)
				if result.is_empty(): return
				_compare(result,"%s_to_%s" % [states[pair[0]].name,states[pair[1]].name])
			_native.call("clear")
	# Separate query dispatch CPU/payload scaling. No CPU FFT in the timed loop.
	for world in ([] if matrix_only else [false,true]):
		for compact in [false,true]:
			for count in BATCHES:
				var before: Dictionary = _query.get_stats()
				for _repeat in (2 if smoke else 12):
					var q := _points.slice(0,count)
					var result := await _request(q,world,q if world else PackedVector2Array(),compact,NAN)
					if result.is_empty(): return
				var after: Dictionary = _query.get_stats()
				var gpu_values: Array = []
				for row: Dictionary in after.gpu_samples.slice(before.gpu_samples.size()): gpu_values.append(row.gpu_us)
				_report.batch.append({"mode": "world" if world else "material", "compact": compact, "count": count,
					"payload": count*(64 if compact else 96), "submit_us": _distribution(after.submit_us.slice(before.submit_us.size())),
					"gpu_us": _distribution(gpu_values),
					"dispatch_cpu_us": _distribution(after.dispatch_cpu_us.slice(before.dispatch_cpu_us.size())),
					"consume_us": _distribution(after.consume_us.slice(before.consume_us.size())),
					"latency_ms": _distribution(after.latency_ms.slice(before.latency_ms.size())),
					"latency_ticks": _distribution(after.latency_ticks.slice(before.latency_ticks.size()))})
		print("GPU1_BATCH_DONE=" + str(world))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/phys_gpu1_renderer.png")
	if not smoke and not matrix_only: await _stress(states)
	_report["parity_aggregate"] = {}
	for scope in _parity_bins:
		var row: Dictionary = {}
		for key in _parity_bins[scope]: row[key] = _distribution(_parity_bins[scope][key])
		_report.parity_aggregate[scope] = row
	_report["ring"] = _query.get_stats()
	_report["world_aggregate"] = {}
	for scope in _world_bins:
		var row: Dictionary = _world_bins[scope].duplicate()
		for key in ["q_error", "residual", "cpu_q_error"]: row[key] = _distribution(row[key])
		_report.world_aggregate[scope] = row
	for key in ["latency_ms","latency_ticks","submit_us","consume_us","dispatch_cpu_us","ocean_gpu_us"]:
		_report.ring[key] = _distribution(_report.ring[key])
	_report["global_gpu_sync"] = false
	if not matrix_only:
		var trace_file := FileAccess.open("res://.godot/phys_gpu1_trace.json",FileAccess.WRITE)
		trace_file.store_string(JSON.stringify(_query.get_validation_trace())); trace_file.close()
	_report["status"] = "PASS" if _report.failures.is_empty() else "PARTIAL"
	_save()
	_native.call("clear")
	_ocean.queue_free()
	for _i in 8: await process_frame
	_report["after_shutdown"] = _query.get_stats()
	_save()
	print("PHYS_GPU1_COMPLETE=" + JSON.stringify({"status":_report.status,"matrix":_report.matrix.size(),"failures":_report.failures,"stress":_report.get("stress",{}),"latency_ms":_report.ring.latency_ms,"latency_ticks":_report.ring.latency_ticks}))
	quit(0 if _report.failures.is_empty() else 1)

func _new_mirror(bands: Array,time: float) -> Object:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native.call("get_dynamic_async_build_id") != preload("res://validation/physics/phys_native_build_contract.gd").ID:
		_fail("native DLL build mismatch"); return null
	if not native.call("set_production_spectrum",bands) or not ADAPTER.configure_coastal(native,_coastal).ok \
		or not native.call("start_dynamic_async_fields",time,_tick): _fail("mirror import/start failed"); return null
	return native

func _at(time: float) -> bool:
	_tick += 1
	for _i in 300:
		_native.call("advance_dynamic_async",_tick,time,time,1.0/60.0)
		var info: PackedInt64Array = _native.call("get_dynamic_snapshot_info")
		if info[0] == 1 and absf(info[1]/1e9-time)<2e-9:
			var metadata: Array = _native.call("get_dynamic_snapshot_spectrum",false)
			if info[3] == (_native.call("get_dynamic_async_stats") as PackedInt64Array)[21]:
				_fft.call("queue_dynamic_spectrum",_native,metadata)
				_fft.set("_wave_time",time)
				for _frame in 3: await process_frame
				return true
		await process_frame
	_fail("mirror exact-time timeout"); return false

func _request(points: PackedVector2Array,world: bool,previous: PackedVector2Array,compact: bool,time: float) -> Dictionary:
	var generation: int = _query.submit(QUERY.pack_queries(points,world,previous),Engine.get_physics_frames(),time,compact)
	if generation < 0: _fail("submit rejected"); return {}
	for _i in 180:
		await process_frame
		var result: Dictionary = _query.consume(Engine.get_physics_frames())
		if not result.is_empty():
			if result.generation != generation: _fail("unexpected generation"); return {}
			return result
	_fail("async result timeout: " + str(_query.get_stats())); return {}

func _make_points() -> void:
	var origin: Vector2 = _coastal.field_origin; var extent: Vector2 = _coastal.field_extent
	var cell: Vector2 = extent/Vector2(_coastal.field_resolution-Vector2i.ONE)
	var valid: PackedByteArray = _coastal.field_valid
	var size: Vector2i = _coastal.field_resolution
	var internal: Array[Vector2] = []
	for y in range(2,size.y-2):
		for x in range(2,size.x-2):
			if valid[y*size.x+x] != valid[y*size.x+x+1]: internal.append(origin+Vector2((x+1.0)/size.x,(y+0.5)/size.y)*extent)
	for i in 256:
		var q: Vector2; var label: String
		match i%5:
			0: q=origin+Vector2(-50-i*0.17,-40-i*0.31); label="open"
			1: q=origin+Vector2(fposmod(i*0.618,0.8)+0.1,fposmod(i*0.413,0.8)+0.1)*extent; label="interior"
			2:
				q=origin+Vector2(0.37,0.43)*extent
				var side: int=(i/5)%4; var amount: float=[-0.01,0.0,0.001,0.1,0.5,0.99,1.01][(i/20)%7]
				if side<2: q.x=origin.x+(amount*cell.x if side==0 else extent.x-amount*cell.x)
				else: q.y=origin.y+(amount*cell.y if side==2 else extent.y-amount*cell.y)
				label="boundary"
			3: q=Vector2((i/5)%3*512.0-256.0+[0.0,0.001,-0.001][i%3],-37.0*i/5); label="wrap"
			_: q=internal[i%internal.size()]+Vector2(0.01*(i%3-1),0) if not internal.is_empty() else origin+extent*0.5; label="mask"
		_points.append(q); _labels.append(label)

func _compare(result: Dictionary,state: String) -> void:
	var buckets: Dictionary = {}
	var bytes: PackedByteArray = result.bytes
	for i in _points.size():
		var q:=_points[i]; var oracle: PackedFloat64Array=_native.call("sample_dynamic_material_q",q.x,q.y)
		var base:=i*96
		if bytes.decode_float(base+28)<0.5: _report.failures.append("invalid material result"); continue
		var bucket: Dictionary=buckets.get(_labels[i],{"dx":[],"dy":[],"dz":[],"vx":[],"vy":[],"vz":[],"normal_deg":[],"det":[]})
		for axis in 3:
			bucket[["dx","dy","dz"][axis]].append(absf(bytes.decode_float(base+16+axis*4)-oracle[2+axis]))
			bucket[["vx","vy","vz"][axis]].append(absf(bytes.decode_float(base+48+axis*4)-oracle[8+axis]))
		var normal:=Vector3(bytes.decode_float(base+64),bytes.decode_float(base+68),bytes.decode_float(base+72))
		var reference:=Vector3(oracle[5],oracle[6],oracle[7])
		bucket.normal_deg.append(rad_to_deg(acos(clampf(normal.dot(reference),-1,1))))
		bucket.det.append(absf(bytes.decode_float(base+44)-oracle[11]))
		buckets[_labels[i]]=bucket
	for label in buckets:
		for scope in ["all", "region/"+label, "weather/"+state]:
			if not _parity_bins.has(scope): _parity_bins[scope] = {}
			for key in buckets[label]:
				if not _parity_bins[scope].has(key): _parity_bins[scope][key] = []
				_parity_bins[scope][key].append_array(buckets[label][key])
		var row: Dictionary={"state":state,"group":label,"time":result.sample_time,"config":result.config_version,"alpha":result.weather_alpha,"samples":buckets[label].dx.size()}
		for key in buckets[label]: row[key]=_distribution(buckets[label][key])
		_report.matrix.append(row)
		# Existing PHYS-3 physical budgets are not altered. Record all failures.
		if maxf(row.dx.max,maxf(row.dy.max,row.dz.max))>0.001: _report.failures.append("displacement >1mm: "+state+"/"+label)
		if maxf(row.vx.max,maxf(row.vy.max,row.vz.max))>0.001: _report.failures.append("velocity >1mm/s: "+state+"/"+label)
		if row.normal_deg.max>0.5: _report.failures.append("normal >0.5deg: "+state+"/"+label)
	print("GPU1_PARITY="+state+" time="+str(result.sample_time)+" failures="+str(_report.failures.size()))
	_save()

func _world(material: Dictionary,state: String) -> void:
	var targets:=PackedVector2Array(); var warm:=PackedVector2Array()
	var bytes: PackedByteArray=material.bytes
	for i in _points.size():
		var base:=i*96
		targets.append(Vector2(bytes.decode_float(base+32),bytes.decode_float(base+40)))
		warm.append(_points[i]+Vector2(0.001,-0.001))
	var result:=await _request(targets,true,warm,false,material.sample_time)
	if result.is_empty(): return
	var errors:Array=[]; var residuals:Array=[]; var failures:=0; var folded:=0; var branch_failures:=0
	var cpu_failures:=0; var validity_mismatches:=0; var cpu_q_errors:Array=[]; var cpu_branch_mismatches:=0
	bytes=result.bytes
	for i in _points.size():
		var base:=i*96; var q:=Vector2(bytes.decode_float(base),bytes.decode_float(base+4))
		var residual:=bytes.decode_float(base+8); residuals.append(residual); errors.append(q.distance_to(_points[i]))
		var reference: PackedFloat64Array = _native.call("sample_dynamic_world",targets[i].x,targets[i].y,warm[i].x,warm[i].y,true)
		var gpu_valid:=bytes.decode_float(base+28)>0.5
		var cpu_valid:=reference[0]>0.5
		if not cpu_valid: cpu_failures+=1
		if cpu_valid!=gpu_valid: validity_mismatches+=1
		if cpu_valid and gpu_valid:
			var cpu_q:=Vector2(reference[15],reference[16])
			cpu_q_errors.append(q.distance_to(cpu_q))
			if q.distance_to(cpu_q)>0.01: cpu_branch_mismatches+=1
		if bytes.decode_float(base+28)<0.5: failures+=1
		if bytes.decode_float(base+28)<0.5: print("GPU1_WORLD_FAILURE="+str({"q":_points[i],"target":targets[i],"recovered":q,"residual":residual,"iterations":bytes.decode_float(base+12),"label":_labels[i]}))
		if (material.bytes as PackedByteArray).decode_float(base+44)<=0:
			folded+=1
			if q.distance_to(_points[i])>0.01: branch_failures+=1
		var is_folded: bool = (material.bytes as PackedByteArray).decode_float(base+44)<=0
		for scope in ["all", "region/"+_labels[i], "weather/"+state, "folded" if is_folded else "unfolded"]:
			var bin: Dictionary = _world_bins.get(scope, {"q_error":[], "residual":[], "cpu_q_error":[], "failures":0, "validity_mismatches":0, "cpu_branch_mismatches":0, "owned_branch_mismatches":0})
			bin.q_error.append(q.distance_to(_points[i])); bin.residual.append(residual)
			if not gpu_valid: bin.failures += 1
			if cpu_valid != gpu_valid: bin.validity_mismatches += 1
			if is_folded and q.distance_to(_points[i])>0.01: bin.owned_branch_mismatches += 1
			if cpu_valid and gpu_valid:
				var delta: float = q.distance_to(Vector2(reference[15],reference[16]))
				bin.cpu_q_error.append(delta)
				if delta>0.01: bin.cpu_branch_mismatches += 1
			_world_bins[scope] = bin
	_report.world.append({"state":state,"time":material.sample_time,"q_error":_distribution(errors),"residual":_distribution(residuals),"failures":failures,"folded":folded,"branch_failures":branch_failures,
		"cpu_failures":cpu_failures,"validity_mismatches":validity_mismatches,"cpu_q_error":_distribution(cpu_q_errors),"cpu_branch_mismatches":cpu_branch_mismatches})
	if failures>0 or branch_failures>0: _report.failures.append("world inversion/branch failures: "+state)

func _stress(states: Array) -> void:
	var before: Dictionary=_query.get_stats()
	var submitted:=0; var invalid:=0; var started:=Time.get_ticks_usec()
	_native=_new_mirror(states[1].bands,0.0)
	if _native==null: return
	var source:Object=ClassDB.instantiate("OceanQueryNative")
	source.call("prepare_production_spectrum",states[1].bands)
	var simulation_time:=0.0
	var trend:Array=[]
	var observed_configs:Dictionary={}
	var pause_times:Array=[]
	var warm_history:=PackedVector2Array(); warm_history.resize(_points.size())
	var warm_valid:=PackedByteArray(); warm_valid.resize(_points.size())
	var world_contacts:=0
	# Rendering continues while physics submits; no exact-time oracle waits here.
	for tick in 10000:
		await physics_frame
		if tick<4000 or tick>=4200: simulation_time+=1.0/60.0
		if tick==2000: _native.call("transition_dynamic_spectrum",source,states[2].native,simulation_time,3.0)
		if tick==6000: _native.call("transition_dynamic_spectrum",states[2].native,states[1].native,simulation_time,3.0)
		_native.call("advance_dynamic_async",20000+tick,simulation_time,simulation_time,1.0/60.0)
		var weather:Array=_native.call("get_dynamic_snapshot_spectrum",false)
		if weather.size()==3: _fft.call("queue_dynamic_spectrum",_native,weather)
		_fft.set("_wave_time",simulation_time)
		var count:int=BATCHES[tick%BATCHES.size()]
		var q:=_points.slice(0,count)
		var world:=tick%2==1
		var packet:=QUERY.pack_queries(q,world,warm_history.slice(0,count) if world else PackedVector2Array())
		if world:
			for i in count: packet.encode_u32(i*32+20,warm_valid[i])
		if _query.submit(packet,Engine.get_physics_frames(),NAN,tick%3==0)>0: submitted+=1
		var result:Dictionary=_query.consume(Engine.get_physics_frames())
		if not result.is_empty():
			observed_configs[result.config_version]=true
			if tick>=4010 and tick<4190: pause_times.append(result.sample_time)
			var bytes:PackedByteArray=result.bytes
			for i in int(result.count):
				if bytes.decode_float(i*int(result.stride)+28)<0.5: invalid+=1
				if result.first_mode==1:
					world_contacts+=1
					if bytes.decode_float(i*int(result.stride)+28)>0.5:
						warm_history[i]=Vector2(bytes.decode_float(i*int(result.stride)),bytes.decode_float(i*int(result.stride)+4)); warm_valid[i]=1
		if tick%1000==0:
			var stats:Dictionary=_query.get_stats()
			trend.append({"tick":tick,"buffers":stats.owned_buffers,"in_flight":stats.in_flight,"pending":stats.pending,"static_memory":OS.get_static_memory_usage()})
			print("GPU1_STRESS="+str(tick)+" inflight="+str(stats.in_flight))
	for _i in 12: await process_frame
	_query.consume(Engine.get_physics_frames())
	var after:Dictionary=_query.get_stats()
	_report["stress"]={"submissions":submitted,"dispatched":after.dispatched-before.dispatched,"completed":after.completed-before.completed,
		"coalesced":after.coalesced-before.coalesced,"invalid_contacts":invalid,"max_in_flight":after.max_in_flight,"pending":after.pending,
		"mismatches":after.mismatches-before.mismatches,"errors":after.errors-before.errors,"owned_buffers":after.owned_buffers,"elapsed_s":(Time.get_ticks_usec()-started)/1e6}
	_report.stress["resource_trend"]=trend
	_report.stress["world_contacts"]=world_contacts
	_report.stress["weather_configs"]=observed_configs.keys()
	_report.stress["pause_samples"]=_distribution(pause_times)
	if not pause_times.is_empty() and float(pause_times.max())-float(pause_times.min())>1e-8: _report.failures.append("paused sample time advanced")
	if submitted!=10000 or after.mismatches>0 or after.errors>0: _report.failures.append("stress integrity failed")

func _distribution(values: Array) -> Dictionary:
	if values.is_empty(): return {"count":0,"mean":0,"rms":0,"p50":0,"p95":0,"p99":0,"max":0}
	var sorted:=values.duplicate(); sorted.sort(); var total:=0.0; var squares:=0.0
	for v in sorted: total+=float(v); squares+=float(v)*float(v)
	return {"count":sorted.size(),"mean":total/sorted.size(),"rms":sqrt(squares/sorted.size()),
		"p50":sorted[int(ceil(sorted.size()*0.5))-1],"p95":sorted[int(ceil(sorted.size()*0.95))-1],
		"p99":sorted[int(ceil(sorted.size()*0.99))-1],"max":sorted.back()}

func _save() -> void:
	var output: String = "res://.godot/phys_gpu1_matrix.json" if OS.get_cmdline_user_args().has("--matrix-only") else "res://.godot/phys_gpu1_results.json"
	var file:=FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify(_report,"\t")); file.close()

func _fail(message: String) -> void:
	_report.failures.append(message); _save(); push_error("PHYS_GPU1_FAIL="+message); quit(1)
