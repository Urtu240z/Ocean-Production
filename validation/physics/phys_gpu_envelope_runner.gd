extends "res://validation/physics/phys_gpu13_runner.gd"
const ENVELOPE := preload("res://addons/ocean/physics/gpu/ocean_envelope_atlas.gd")
var atlas_report: Dictionary={"phase":"PHYS-GPU-ENVELOPE-1","starting_head":"98928f1","checks":[],"single_tile":[],"fixtures":[],"sweep":[],"after_shutdown":[],"status":"PARTIAL"}
var _fixtures: Array=[]
var _tile_width:=16.0

func _run() -> void:
	load(DESCRIPTOR)
	_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
	for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
	root.add_child(_ocean)
	var camera:=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current=true
	var light:=DirectionalLight3D.new(); root.add_child(light); light.rotation_degrees=Vector3(-45,-30,0)
	for frame in 12: await process_frame
	_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT"); _coastal=_fft.call("get_phys3_coastal_snapshot")
	_states=[{"name":"current","bands":_fft.call("get_phys2_band_spectrum_snapshots")}]
	for s in [["calm",0.8,4.0,20.0,0.8],["storm",3.0,18.0,75.0,2.0],["direction",3.0,18.0,20.0,2.0],["choppiness",3.0,18.0,20.0,2.5]]:
		var configs:Array=PROFILE.build_fft_configs(s[1],s[2],s[3],0.8,1.0); configs[0].choppiness=s[4]
		var builder:Object=ClassDB.instantiate("OceanQueryNative")
		var state:Dictionary=STATE.build(configs,1,s[1],PROFILE.combined_significant_wave_height_m(),1.0,[1.0,1.0,1.0],1.0,7,builder)
		builder.call("prepare_production_spectrum",state.bands); _states.append({"name":s[0],"bands":state.bands,"native":builder})
	var current:Object=ClassDB.instantiate("OceanQueryNative"); current.call("prepare_production_spectrum",_states[0].bands); _states[0]["native"]=current
	atlas_report["environment"]={"engine":Engine.get_version_info(),"cpu":OS.get_processor_name(),"gpu":RenderingServer.get_video_adapter_name(),"driver":RenderingServer.get_current_rendering_driver_name(),"renderer":RenderingServer.get_current_rendering_method()}
	atlas_report["source_hashes"]={}
	for filename in ["ocean_surface_query.glsl","ocean_surface_query.gd","ocean_envelope_atlas.gd","ocean_envelope_shader_source.gd","ocean_envelope_query.comp","ocean_envelope_shared.inc","ocean_envelope_raster.vert","ocean_envelope_raster.frag","ocean_envelope_bounds.comp","ocean_envelope_holes.comp"]:
		atlas_report.source_hashes[filename]=FileAccess.get_sha256("res://addons/ocean/physics/gpu/"+filename)
	atlas_report.source_hashes["runner"]=FileAccess.get_sha256("res://validation/physics/phys_gpu_envelope_runner.gd")
	if OS.get_cmdline_user_args().has("--dense"): _tile_width=8.0
	if OS.get_cmdline_user_args().has("--dense-replay"): _tile_width=8.0
	if OS.get_cmdline_user_args().has("--cold-replay"): _tile_width=8.0
	_read_atlas_fixtures()
	if OS.get_cmdline_user_args().has("--closure"):
		await _atlas_closure(); await _finish_atlas(); return
	if OS.get_cmdline_user_args().has("--atlas-parity"):
		if await _create_atlas(128,256):
			await _atlas_parity()
			await _atlas_coherence()
		await _finish_atlas(); return
	if OS.get_cmdline_user_args().has("--resources"):
		await _atlas_reloads(); await _finish_atlas(); return
	if OS.get_cmdline_user_args().has("--confirm"):
		await _atlas_confirm(); await _finish_atlas(); return
	if OS.get_cmdline_user_args().has("--owned-boundary"):
		if await _create_atlas(512,2048): await _atlas_physical_two_root()
		await _retire_atlas()
		if await _create_atlas(64,512): await _atlas_owned_boundary()
		await _finish_atlas(); return
	if OS.get_cmdline_user_args().has("--focused-parity"):
		_query=_fft.call("enable_gpu_surface_queries")
		for frame in 8: await process_frame
		_query.set_validation_metrics_enabled(true)
		_native=_new_mirror(_states[0].bands,0.36)
		await _oracle_matrix()
		atlas_report["focused_parity"]=_proof.oracle; atlas_report.checks.append_array(_proof.failures)
		_query=null; await _finish_atlas(); return
	if OS.get_cmdline_user_args().has("--dense"):
		var replay:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_envelope_replay.json"))
		var seen:Dictionary={}
		for example in replay.get("replay",{}).get("examples",[]):
			var record:Dictionary=example.record
			var key:=str(record.config)+"/"+str(record.time)+"/"+str(record.target)
			if seen.has(key): continue
			seen[key]=true
			_fixtures.append({"label":"replay/"+str(_fixtures.size()),"target":Vector2(record.target[0],record.target[1]),"config":record.config,"time":record.time,"alpha":record.alpha,"reference":record.reference})
	if OS.get_cmdline_user_args().has("--replay") or OS.get_cmdline_user_args().has("--cold-replay"):
		await _replay_atlas_failures(); await _finish_atlas(); return
	var smoke:=OS.get_cmdline_user_args().has("--smoke")
	var resolutions: Array=[128] if smoke else [64,128,256,512]
	var grids: Array=[128] if smoke else [64,128,256,512]
	if OS.get_cmdline_user_args().has("--dense"): resolutions=[256,512]; grids=[512,1024,2048]
	for resolution in resolutions:
		for grid in grids:
			if not await _create_atlas(resolution,grid): await _finish_atlas(); return
			var totals: Dictionary={"resolution":resolution,"grid":grid,"tile_width":_tile_width,"cases":0,"wrong_sheet":0,"failed":0,"unmatched":0,"holes_max":0,"coverage_misses":0,"max_seed_q_error":0.0,"max_raster_y_error":0.0,"max_final_y_error":0.0,"max_residual":0.0}
			for fixture in (_fixtures.slice(0,3) if smoke else _fixtures):
				_anchor_weather(fixture)
				if not await _snapshot(int(fixture.config),fixture.time,true): atlas_report.checks.append("snapshot failed"); break
				var target:Vector2=fixture.target
				var result:=await _atlas_request(PackedVector3Array([Vector3(target.x,0.1,target.y)]),[{"slot":0,"vehicle_id":0,"generation":_occupant,"reset":true}],[{"center":target,"size":Vector2(_tile_width,_tile_width),"generation":_occupant}])
				if result.is_empty(): break
				var row:=ENVELOPE.decode_envelope_contact(result,0)
				var reference:Dictionary=fixture.reference
				var check:=_check_atlas(row,reference)
				var bound:Vector3=row.coverage_bound
				var upper_q:=Vector2(reference.envelope.q[0],reference.envelope.q[1])
				var in_coverage:bool=absf(upper_q.x-target.x)<=_tile_width*0.5+bound.x and absf(upper_q.y-target.y)<=_tile_width*0.5+bound.z
				var sample:Dictionary={"fixture":fixture.label,"config":fixture.config,"time":fixture.time,"alpha":fixture.alpha,"roots":reference.roots.size(),"row":row,"check":check,"upper_q_inside_q_grid":in_coverage,"q_spacing":[(_tile_width+2*bound.x)/grid,(_tile_width+2*bound.z)/grid],"seed_q_error":row.atlas_seed_q.distance_to(upper_q),"raster_y_error":row.atlas_y-reference.envelope.height,"final_y_error":row.surface_y-reference.envelope.height}
				atlas_report.single_tile.append(sample)
				totals.cases+=1; totals.wrong_sheet+=int(check.wrong_lower_sheet); totals.failed+=int(not row.valid); totals.unmatched+=int(row.valid and not check.selected_matches_discovered_root)
				totals.coverage_misses+=int(not in_coverage); totals.holes_max=maxi(totals.holes_max,row.atlas_holes)
				totals.max_seed_q_error=maxf(totals.max_seed_q_error,absf(sample.seed_q_error)); totals.max_raster_y_error=maxf(totals.max_raster_y_error,absf(sample.raster_y_error)); totals.max_final_y_error=maxf(totals.max_final_y_error,absf(sample.final_y_error)); totals.max_residual=maxf(totals.max_residual,row.residual if row.valid else 0)
				if row.solves>5 or row.iterations>80: atlas_report.checks.append("query budget exceeded")
				if row.tile_generation!=result.generation: atlas_report.checks.append("tile generation mismatch")
				_occupant+=1
			for frame in 6: await process_frame
			var stats:Dictionary=_query.get_stats()
			totals["raster_gpu_us"]=_distribution(stats.envelope_gpu_samples.map(func(s):return s.gpu_us))
			totals["bounds_gpu_us"]=_distribution(stats.bounds_gpu_samples.map(func(s):return s.gpu_us))
			totals["query_gpu_us"]=_distribution(stats.gpu_samples.map(func(s):return s.gpu_us))
			totals["ocean_gpu_us"]=_distribution(stats.ocean_gpu_us)
			totals["resources"]={"color":stats.atlas_color_bytes,"depth":stats.atlas_depth_bytes,"mesh":stats.mesh_bytes,"tile_state":stats.tile_state_bytes}
			atlas_report.sweep.append(totals)
			print("ENVELOPE_SWEEP="+JSON.stringify(totals))
			_save_atlas()
			await _retire_atlas()
	await _finish_atlas()

func _read_atlas_fixtures() -> void:
	var found:Dictionary={}
	for part in range(1,63):
		var name:="res://validation/physics/gpu13_envelope/cases-%03d.jsonl.gz" % part
		var data:=FileAccess.get_file_as_bytes(name).decompress_dynamic(32*1024*1024,FileAccess.COMPRESSION_GZIP)
		for line in data.get_string_from_utf8().split("\n",false):
			var entry:Dictionary=JSON.parse_string(line); var roots:int=entry.reference.roots.size()
			var labels:Array=[]
			if roots in [7,11,17,34]: labels.append("roots/"+str(roots))
			if entry.envelope_check.wrong_lower_sheet: labels.append("wrong_lower")
			if entry.envelope_check.bounded_candidate_miss: labels.append("miss")
			if entry.context.scenario=="fold" and not entry.row.owned: labels.append("cold_fold")
			if entry.row.status==5 and not entry.envelope_check.wrong_lower_sheet: labels.append("handoff")
			for label in labels:
				if found.has(label): continue
				found[label]=true
				_fixtures.append({"label":label,"target":Vector2(entry.context.target[0],entry.context.target[2]),"config":entry.config,"time":entry.time,"alpha":entry.alpha,"reference":entry.reference})
			if found.size()==8: break
		if found.size()==8: break
	var old:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-1.3-OLD-RECLASSIFICATION.json"))
	for entry in old.envelope_cases:
		if int(entry.old_failure.ordinal) not in [1028,1029,1030,1031,1032,2521,2522]: continue
		var f:Dictionary=entry.old_failure
		_fixtures.append({"label":"lateral/"+str(f.ordinal),"target":Vector2(f.target_x,f.target_z),"config":f.config,"time":f.time,"alpha":f.alpha,"reference":entry.reference})
	atlas_report.fixtures=_fixtures
	print("ENVELOPE_FIXTURES="+str(_fixtures.size()))

func _create_atlas(resolution:int,grid:int) -> bool:
	_query=_fft.call("enable_gpu_envelope_queries",{"tile_resolution":resolution,"grid_resolution":grid,"tile_capacity":1})
	for frame in 12: await process_frame
	if _query==null or not _query.get_stats().ready:
		atlas_report.checks.append("atlas initialization: "+str(_query.get_stats() if _query else {})); return false
	_query.set_validation_metrics_enabled(true)
	return true

func _check_atlas(row:Dictionary,reference:Dictionary) -> Dictionary:
	var highest:float=reference.envelope.height; var matching:=false
	for root in reference.roots:
		var q:=Vector2(root.q[0],root.q[1])
		if row.valid and row.q.distance_to(q)<0.02 and absf(row.surface_y-root.height)<0.002: matching=true
	return {"wrong_lower_sheet":row.valid and row.surface_y<highest-0.002,"bounded_candidate_miss":not row.valid,"selected_matches_discovered_root":matching,"height_gap":highest-row.surface_y}

func _atlas_request(points:PackedVector3Array,descriptors:Array,tiles:Array,compact:=false) -> Dictionary:
	var generation:int=_query.submit_envelope_contacts(ENVELOPE.pack_envelope_contacts(points,descriptors,tiles),Engine.get_physics_frames(),NAN,compact)
	if generation<0: atlas_report.checks.append("atlas submit rejected"); return {}
	for frame in 300:
		await process_frame
		var result:Dictionary=_query.consume(Engine.get_physics_frames())
		if not result.is_empty() and result.generation==generation: _query.drain_validation_completed(); return result
	atlas_report.checks.append("atlas async timeout: "+str(_query.get_stats())); return {}

func _retire_atlas() -> void:
	if _query==null: return
	var token:=_query; _fft.call("disable_gpu_envelope_queries")
	for frame in 12: await process_frame
	var stats:Dictionary=token.get_stats(); atlas_report.after_shutdown.append({"owned":stats.envelope_owned_resources,"buffers":stats.owned_buffers,"in_flight":stats.in_flight,"errors":stats.errors,"mismatches":stats.mismatches})
	if stats.envelope_owned_resources!=0 or stats.owned_buffers!=0: atlas_report.checks.append("retirement resource leak")
	_query=null

func _save_atlas() -> void:
	var filename:="phys_gpu_envelope_replay" if OS.get_cmdline_user_args().has("--replay") else "phys_gpu_envelope_single_tile"
	if OS.get_cmdline_user_args().has("--dense"): filename="phys_gpu_envelope_dense"
	if OS.get_cmdline_user_args().has("--dense-replay"): filename="phys_gpu_envelope_replay_dense"
	if OS.get_cmdline_user_args().has("--closure"): filename="phys_gpu_envelope_closure"
	if OS.get_cmdline_user_args().has("--focused-parity"): filename="phys_gpu_envelope_focused_parity"
	if OS.get_cmdline_user_args().has("--atlas-parity"): filename="phys_gpu_envelope_atlas_parity"
	if OS.get_cmdline_user_args().has("--cold-replay"): filename="phys_gpu_envelope_cold_replay"
	if OS.get_cmdline_user_args().has("--resources"): filename="phys_gpu_envelope_resources"
	if OS.get_cmdline_user_args().has("--confirm"): filename="phys_gpu_envelope_confirm"
	if OS.get_cmdline_user_args().has("--owned-boundary"): filename="phys_gpu_envelope_owned_boundary"
	FileAccess.open("res://.godot/"+filename+".json",FileAccess.WRITE).store_string(JSON.stringify(_json_value(atlas_report),"\t"))

func _replay_atlas_failures() -> void:
	var records:Array=[]
	var totals:Dictionary={"cases":0,"main_wrong_before":0,"main_miss_before":0,"supplement_wrong_before":0,"supplement_miss_before":0,"cold_fold":0,"correct":0,"wrong_sheet":0,"failed":0,"unmatched":0,"holes_max":0,"coverage_misses":0,"max_iterations":0,"max_solves":0,"by_source":{},"by_old_class":{},"examples":[]}
	for variant in ["main","supplement"]:
		var prefix:="cases" if variant=="main" else "reentry10-cases"
		for part in range(1,63 if variant=="main" else 37):
			var data:=FileAccess.get_file_as_bytes("res://validation/physics/gpu13_envelope/"+prefix+"-%03d.jsonl.gz"%part).decompress_dynamic(32*1024*1024,FileAccess.COMPRESSION_GZIP)
			for line in data.get_string_from_utf8().split("\n",false):
				var entry:Dictionary=JSON.parse_string(line)
				var wrong:bool=entry.envelope_check.wrong_lower_sheet; var miss:bool=entry.envelope_check.bounded_candidate_miss
				var cold:bool=entry.context.scenario=="fold" and not entry.row.owned
				if OS.get_cmdline_user_args().has("--cold-replay") and not cold: continue
				if not wrong and not miss and not cold: continue
				var roots:Array=[]
				for r in entry.reference.roots: roots.append({"q":r.q,"height":r.height})
				records.append({"source":variant,"old_class":"wrong" if wrong else "miss" if miss else "cold_correct","cold":cold,"config":entry.config,"time":entry.time,"alpha":entry.alpha,"target":Vector2(entry.context.target[0],entry.context.target[2]),"contact_y":entry.context.target[1],"old_generation":entry.generation,"vehicle":entry.context.vehicle,"reference":{"envelope":entry.reference.envelope,"roots":roots}})
			print("ENVELOPE_READ="+variant+"/"+str(part))
	records.sort_custom(func(a,b): return a.config<b.config or (a.config==b.config and (a.time<b.time or (a.time==b.time and a.vehicle<b.vehicle))))
	print("ENVELOPE_REPLAY_CASES="+str(records.size()))
	var dense_replay:=OS.get_cmdline_user_args().has("--dense-replay") or OS.get_cmdline_user_args().has("--cold-replay")
	if not await _create_atlas(256 if dense_replay else 128,1024 if dense_replay else 512): return
	totals["tile_width"]=_tile_width; totals["tile_resolution"]=256 if dense_replay else 128; totals["grid_resolution"]=1024 if dense_replay else 512
	var at:=0; var batches:=0
	while at<records.size():
		var first:Dictionary=records[at]; var group:Array=[]
		while at<records.size() and group.size()<256:
			var candidate:Dictionary=records[at]
			if candidate.config!=first.config or absf(candidate.time-first.time)>1e-10 or candidate.alpha!=first.alpha or candidate.target.distance_to(first.target)>_tile_width*0.4: break
			group.append(candidate); at+=1
		_anchor_weather(first)
		if not await _snapshot(int(first.config),first.time,true): atlas_report.checks.append("replay snapshot failed"); return
		var points:=PackedVector3Array(); var descriptors:Array=[]
		for i in group.size():
			points.append(Vector3(group[i].target.x,group[i].contact_y,group[i].target.y))
			descriptors.append({"slot":i,"vehicle_id":0,"contact_id":i,"generation":_occupant,"reset":true})
		var result:=await _atlas_request(points,descriptors,[{"center":first.target,"size":Vector2(_tile_width,_tile_width),"generation":_occupant}])
		if result.is_empty(): return
		for i in group.size():
			var record:Dictionary=group[i]; var row:=ENVELOPE.decode_envelope_contact(result,i); var check:=_check_atlas(row,record.reference)
			var upper:Vector2=Vector2(record.reference.envelope.q[0],record.reference.envelope.q[1]); var bound:Vector3=row.coverage_bound
			var covered:bool=absf(upper.x-first.target.x)<=_tile_width*0.5+bound.x and absf(upper.y-first.target.y)<=_tile_width*0.5+bound.z
			totals.cases+=1; totals.cold_fold+=int(record.cold); totals.wrong_sheet+=int(check.wrong_lower_sheet); totals.failed+=int(not row.valid); totals.unmatched+=int(row.valid and not check.selected_matches_discovered_root); totals.correct+=int(row.valid and not check.wrong_lower_sheet and check.selected_matches_discovered_root)
			totals.coverage_misses+=int(not covered); totals.holes_max=maxi(totals.holes_max,row.atlas_holes); totals.max_iterations=maxi(totals.max_iterations,row.iterations); totals.max_solves=maxi(totals.max_solves,row.solves)
			var before_key:String=record.source+"_"+record.old_class+"_before"
			if totals.has(before_key): totals[before_key]+=1
			for grouping in ["by_source","by_old_class"]:
				var label:String=record.source if grouping=="by_source" else record.source+"/"+record.old_class
				var bin:Dictionary=totals[grouping].get(label,{"cases":0,"correct":0,"wrong":0,"failed":0,"unmatched":0,"cold":0})
				bin.cases+=1; bin.correct+=int(row.valid and not check.wrong_lower_sheet and check.selected_matches_discovered_root); bin.wrong+=int(check.wrong_lower_sheet); bin.failed+=int(not row.valid); bin.unmatched+=int(row.valid and not check.selected_matches_discovered_root); bin.cold+=int(record.cold); totals[grouping][label]=bin
			if (check.wrong_lower_sheet or not row.valid or not check.selected_matches_discovered_root) and totals.examples.size()<64: totals.examples.append({"record":record,"row":row,"check":check,"center":first.target})
			if row.solves>5 or row.iterations>80 or row.tile_generation!=result.generation: atlas_report.checks.append("replay budget/generation mismatch")
		_occupant+=1; batches+=1
		if batches%100==0:
			atlas_report["replay"]=totals; _save_atlas(); print("ENVELOPE_REPLAY="+JSON.stringify({"cases":totals.cases,"wrong":totals.wrong_sheet,"failed":totals.failed,"batches":batches}))
	for frame in 8: await process_frame
	var stats:Dictionary=_query.get_stats()
	totals["raster_gpu_us"]=_distribution(stats.envelope_gpu_samples.map(func(s):return s.gpu_us)); totals["query_gpu_us"]=_distribution(stats.gpu_samples.map(func(s):return s.gpu_us)); totals["bounds_gpu_us"]=_distribution(stats.bounds_gpu_samples.map(func(s):return s.gpu_us)); totals["ocean_gpu_us"]=_distribution(stats.ocean_gpu_us)
	totals["submit_cpu_us"]=_distribution(stats.submit_us); totals["consume_cpu_us"]=_distribution(stats.consume_us)
	var raster:Dictionary={}; var bounds:Dictionary={}; var combined:Array=[]
	for sample in stats.envelope_gpu_samples: raster[sample.generation]=sample.gpu_us
	for sample in stats.bounds_gpu_samples: bounds[sample.generation]=sample.gpu_us
	for sample in stats.gpu_samples:
		if raster.has(sample.generation) and bounds.has(sample.generation): combined.append(raster[sample.generation]+bounds[sample.generation]+sample.gpu_us)
	totals["combined_incremental_gpu_us"]=_distribution(combined)
	totals["cold_acquisition_replay"]=true; totals["tile_center_policy"]="first target in coherent local group; no reference q influences geometry or query seeds"; totals["batches"]=batches
	atlas_report["replay"]=totals

func _atlas_closure() -> void:
	# Phase B only: inspect failures at larger pixel resolution, then independent
	# physical/precision/lifetime checks. This does not begin multi-vehicle proof.
	var dense:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_envelope_replay_dense.json"))
	var examples:Array=[]; var seen:Dictionary={}
	for example in dense.get("replay",{}).get("examples",[]):
		var record:Dictionary=example.record
		var key:=str(record.config)+"/"+str(record.time)+"/"+str(record.target)
		if seen.has(key) or not example.check.wrong_lower_sheet: continue
		seen[key]=true; examples.append(record)
		if examples.size()==16: break
	atlas_report["counterexample_sweep"]=[]
	for resolution in [512,1024,2048]:
		if not await _create_atlas(resolution,2048): return
		var totals:Dictionary={"tile_width":8,"resolution":resolution,"grid":2048,"cases":0,"wrong":0,"failed":0,"holes":0,"samples":[]}
		for record in examples:
			_anchor_weather(record)
			if not await _snapshot(int(record.config),record.time,true): return
			var target:=Vector2(record.target[0],record.target[1])
			var result:=await _atlas_request(PackedVector3Array([Vector3(target.x,0.1,target.y)]),[{"slot":0,"generation":_occupant,"reset":true}],[{"center":target,"size":Vector2(8,8),"generation":_occupant}])
			if result.is_empty(): return
			var row:=ENVELOPE.decode_envelope_contact(result,0); var check:=_check_atlas(row,record.reference)
			totals.cases+=1; totals.wrong+=int(check.wrong_lower_sheet); totals.failed+=int(not row.valid); totals.holes=maxi(totals.holes,row.atlas_holes)
			totals.samples.append({"record":record,"row":row,"check":check}); _occupant+=1
		for frame in 8: await process_frame
		var stats:Dictionary=_query.get_stats()
		totals["raster_gpu_us"]=_distribution(stats.envelope_gpu_samples.map(func(s):return s.gpu_us)); totals["query_gpu_us"]=_distribution(stats.gpu_samples.map(func(s):return s.gpu_us)); totals["resources"]={"color":stats.atlas_color_bytes,"depth":stats.atlas_depth_bytes,"mesh":stats.mesh_bytes}
		atlas_report.counterexample_sweep.append(totals); print("ENVELOPE_COUNTEREXAMPLE="+JSON.stringify({"r":resolution,"cases":totals.cases,"wrong":totals.wrong,"failed":totals.failed,"raster":totals.raster_gpu_us})); _save_atlas()
		await _retire_atlas()
	if not await _create_atlas(512,2048): return
	await _atlas_physical_two_root()
	await _atlas_depth()
	await _atlas_lifetime()

func _atlas_physical_two_root() -> void:
	var evidence:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-1.3-MEASUREMENTS.json"))
	var branch:Dictionary=evidence.full.branches[0]
	_weather_start=NAN; _snapshot_config=-1
	if not await _snapshot(1,2.25,true): return
	var totals:Dictionary={"updates":0,"wrong":0,"failed":0,"initial_correct":true,"handoffs":0,"reversals":0,"max_iterations":0,"max_solves":0,"samples":[]}; var old:Array=[]; var older:Array=[]
	for sample in branch.samples:
		var ref:Dictionary=sample.reference; var target:=Vector2(ref.target[0],ref.target[1])
		var points:=PackedVector3Array([Vector3(target.x,0.2,target.y),Vector3(target.x,-0.2,target.y)])
		var result:=await _atlas_request(points,[{"slot":0,"contact_id":0,"generation":_occupant,"reset":sample.step==0},{"slot":1,"contact_id":1,"generation":_occupant,"reset":sample.step==0}],[{"center":Vector2(393.4588,-992.3107),"size":Vector2(8,8),"generation":_occupant}])
		if result.is_empty(): return
		var current:Array=[]
		for i in 2:
			var row:=ENVELOPE.decode_envelope_contact(result,i); var check:=_check_atlas(row,ref)
			totals.updates+=1; totals.wrong+=int(check.wrong_lower_sheet); totals.failed+=int(not row.valid); totals.handoffs+=int(row.status==5)
			totals.max_iterations=maxi(totals.max_iterations,row.iterations); totals.max_solves=maxi(totals.max_solves,row.solves)
			if sample.step==0 and (check.wrong_lower_sheet or not row.valid): totals.initial_correct=false
			if older.size()==2 and old.size()==2 and row.status==5 and row.q.distance_to(older[i])<0.02 and row.q.distance_to(old[i])>0.02: totals.reversals+=1
			current.append(row.q)
			if sample.step<8 or check.wrong_lower_sheet or not row.valid: totals.samples.append({"step":sample.step,"row":row,"check":check})
		older=old; old=current
	atlas_report["physical_two_root"]=totals; print("ENVELOPE_TWO_ROOT="+JSON.stringify({"updates":totals.updates,"wrong":totals.wrong,"failed":totals.failed,"initial_correct":totals.initial_correct})); _occupant+=1; _save_atlas()

func _atlas_depth() -> void:
	var evidence:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-1.3-MEASUREMENTS.json"))
	var fixtures:Array=[]
	for label in ["open","Coastal"]:
		for sample in evidence.full.depth:
			if sample.region==label and not sample.compact:
				fixtures.append({"label":label,"config":1,"time":2.25,"alpha":0.0,"target":Vector2(sample.result.world[0],sample.result.world[2]),"height":sample.result.surface_y}); break
	var b:Dictionary=evidence.full.branches[0].samples[0].reference
	fixtures.append({"label":"fold","config":1,"time":2.25,"alpha":0.0,"target":Vector2(b.target[0],b.target[1]),"height":b.envelope.height})
	var old:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://validation/physics/PHYS-GPU-1.3-OLD-RECLASSIFICATION.json"))
	for e in old.envelope_cases:
		if int(e.old_failure.ordinal)==2519:
			var f:Dictionary=e.old_failure
			fixtures.append({"label":"handoff","config":f.config,"time":f.time,"alpha":f.alpha,"target":Vector2(f.target_x,f.target_z),"height":e.reference.envelope.height}); break
	atlas_report["depth"]=[]
	for fixture in fixtures:
		_anchor_weather(fixture); if not await _snapshot(int(fixture.config),fixture.time,true): return
		for compact in [false,true]:
			var points:=PackedVector3Array(); var descriptors:Array=[]
			for offset in [0.1,0.0,-0.1]:
				points.append(Vector3(fixture.target.x,fixture.height+offset,fixture.target.y)); descriptors.append({"slot":points.size()-1,"contact_id":points.size()-1,"generation":_occupant,"reset":true})
			var result:=await _atlas_request(points,descriptors,[{"center":fixture.target,"size":Vector2(8,8),"generation":_occupant}],compact)
			if result.is_empty(): return
			for i in 3:
				var row:=ENVELOPE.decode_envelope_contact(result,i); var error:float=absf(row.signed_depth-[-0.1,0.0,0.1][i])
				atlas_report.depth.append({"region":fixture.label,"compact":compact,"expected":[-0.1,0.0,0.1][i],"error":error,"row":row})
				if not row.valid or error>0.001: atlas_report.checks.append("depth gate "+fixture.label)
		_occupant+=1

func _atlas_lifetime() -> void:
	atlas_report["lifecycle"]=[]
	await _retire_atlas()
	for cycle in 3:
		if not await _create_atlas(128,128): return
		var generation:int=_query.submit_envelope_contacts(ENVELOPE.pack_envelope_contacts(PackedVector3Array([Vector3(-260,0,-1350)]),[{"slot":0,"generation":1}],[{"center":Vector2(-260,-1350),"size":Vector2(8,8),"generation":1}]),Engine.get_physics_frames())
		var token:=_query; var before:Dictionary={}
		for frame in 30:
			await process_frame; before=token.get_stats()
			if before.in_flight>0: break
		_fft.call("disable_gpu_envelope_queries"); _query=null
		for frame in 120:
			await process_frame
			if token.get_stats().envelope_owned_resources==0: break
		var after:Dictionary=token.get_stats()
		atlas_report.lifecycle.append({"cycle":cycle,"generation":generation,"before_in_flight":before.get("in_flight",0),"owned_after":after.envelope_owned_resources,"buffers_after":after.owned_buffers,"in_flight_after":after.in_flight,"errors":after.errors,"mismatches":after.mismatches})
		if after.envelope_owned_resources!=0 or after.owned_buffers!=0 or after.in_flight!=0 or after.errors!=0 or after.mismatches!=0: atlas_report.checks.append("in-flight retirement failure")

func _atlas_parity() -> void:
	# The historical 1280 target/time/profile matrix, acquired through mode 5.
	# Two spatial groups run sequentially on ONE tile, never a multi-tile atlas.
	atlas_report["atlas_parity"]=[]
	for state in _states:
		if _native!=null: _native.call("clear")
		_native=_new_mirror(state.bands,0.36)
		for step in 16:
			var time:float=0.36+step/60.0
			if not await _at(time): return
			for group in 2:
				var points:=PackedVector3Array(); var known:Array=[]; var descriptors:Array=[]
				for local_index in 8:
					var i:int=group*8+local_index
					var q:=Vector2(-240+i*0.11,-1300)+Vector2(step*0.02,step*0.01)
					if i>=8: q=Vector2(300+(i-8)*0.11,-600)+Vector2(step*0.01,0)
					var material:PackedFloat64Array=_native.call("sample_dynamic_material_q",q.x,q.y)
					points.append(Vector3(q.x+material[2],0.1,q.y+material[4])); known.append(q)
					descriptors.append({"slot":i,"contact_id":i,"generation":_occupant,"reset":step==0})
				var center:=Vector2(points[0].x,points[0].z)
				var result:=await _atlas_request(points,descriptors,[{"center":center,"size":Vector2(8,8),"generation":_occupant}])
				if result.is_empty(): return
				for i in 8:
					var row:=ENVELOPE.decode_envelope_contact(result,i)
					var material:PackedFloat64Array=_native.call("sample_dynamic_material_q",row.q.x,row.q.y)
					var record:Dictionary={"state":state.name,"time":time,"index":group*8+i,"valid":row.valid,"q_known":row.q.distance_to(known[i]),"residual":row.residual,"displacement_error":row.displacement.distance_to(Vector3(material[2],material[3],material[4])),"velocity_error":row.velocity.distance_to(Vector3(material[8],material[9],material[10])),"normal_angle":rad_to_deg(acos(clampf(row.normal.dot(Vector3(material[5],material[6],material[7])),-1,1))),"depth_range_fraction":absf(row.surface_y)/(row.coverage_bound.y+1.0),"solves":row.solves,"iterations":row.iterations}
					atlas_report.atlas_parity.append(record)
					if not row.valid or record.displacement_error>0.001 or record.velocity_error>0.001 or record.normal_angle>0.5 or row.residual>0.001: atlas_report.checks.append("atlas exact parity mismatch")
		_occupant+=1
	if atlas_report.atlas_parity.size()!=1280: atlas_report.checks.append("atlas parity incomplete")
	print("ENVELOPE_ATLAS_PARITY="+str(atlas_report.atlas_parity.size())); _save_atlas()

func _atlas_coherence() -> void:
	var point:=Vector2(-240,-1300)
	var initial:=await _atlas_request(PackedVector3Array([Vector3(point.x,0.1,point.y)]),[{"slot":0,"generation":_occupant,"reset":true}],[{"center":point,"size":Vector2(8,8),"generation":_occupant}])
	if initial.is_empty(): return
	var before:Dictionary=_query.get_stats(); var generation:=-1; var tile_generation:=_occupant
	# Each packet owns an independent copied tile descriptor. An inactive middle
	# packet must invalidate ownership even when replaced before GPU dispatch.
	for step in 20:
		point=Vector2(-240+step*0.024,-1300+step*0.008); tile_generation=_occupant+step
		var batch:=ENVELOPE.pack_envelope_contacts(PackedVector3Array([Vector3(point.x,0.1,point.y)]),[{"slot":0,"generation":_occupant,"active":step!=7}],[{"center":point,"size":Vector2(8,8),"generation":tile_generation}])
		generation=_query.submit_envelope_contacts(batch,Engine.get_physics_frames())
		batch.tiles[0].center=Vector2(9000,9000) # must not alter the pending copy
	var final:Dictionary={}
	for frame in 300:
		await process_frame; final=_query.consume(Engine.get_physics_frames())
		if not final.is_empty() and final.generation==generation: break
	if final.is_empty(): atlas_report.checks.append("coalesced query timeout"); return
	var row:=ENVELOPE.decode_envelope_contact(final,0); var after:Dictionary=_query.get_stats()
	atlas_report["coalescing"]={"submissions":20,"coalesced":after.coalesced-before.coalesced,"generation":generation,"result_generation":final.generation,"row":row,"expected_tile_generation":tile_generation,"expected_target":point,"sample_time_gpu":final.sample_time_gpu,"callback_errors":after.errors,"generation_mismatches":after.mismatches}
	if not row.valid or row.owned or row.tile_generation!=generation or row.tile_occupant_generation!=tile_generation or row.world.distance_to(Vector3(point.x,row.surface_y,point.y))>0.001 or after.coalesced-before.coalesced!=19: atlas_report.checks.append("coalesced atlas coherence")
	var bad:=ENVELOPE.pack_envelope_contacts(PackedVector3Array([Vector3(point.x,0.1,point.y)]),[{"slot":0,"generation":_occupant}],[{"center":point,"size":Vector2(8,8),"generation":tile_generation}])
	bad.controls.encode_u32(24,tile_generation+1)
	generation=_query.submit_envelope_contacts(bad,Engine.get_physics_frames())
	for frame in 300:
		await process_frame; final=_query.consume(Engine.get_physics_frames())
		if not final.is_empty() and final.generation==generation: break
	if final.is_empty(): atlas_report.checks.append("mismatched tile timeout"); return
	row=ENVELOPE.decode_envelope_contact(final,0); atlas_report["tile_rejection"]={"valid":row.valid,"reason":row.reason}
	if row.valid or row.reason!=10: atlas_report.checks.append("mismatched tile assignment accepted")
	_save_atlas()

func _atlas_reloads() -> void:
	atlas_report["reloads"]=[]
	for cycle in 6:
		if not await _create_atlas(128,128): return
		var point:=Vector2(-260,-1350)
		var packet:=ENVELOPE.pack_envelope_contacts(PackedVector3Array([Vector3(point.x,0,point.y)]),[{"slot":0,"generation":cycle+1}],[{"center":point,"size":Vector2(8,8),"generation":cycle+1}])
		var generation:int=_query.submit_envelope_contacts(packet,Engine.get_physics_frames()); var token:=_query
		var before:Dictionary={}
		for frame in 30:
			await process_frame; before=token.get_stats()
			if before.in_flight>0: break
		if cycle%2==0:
			_ocean.queue_free()
		else:
			_ocean.call("shutdown")
			if not _ocean.call("initialize"): atlas_report.checks.append("ocean reinitialize rejected")
		_query=null
		for frame in 120:
			await process_frame
			if token.get_stats().envelope_owned_resources==0: break
		var after:Dictionary=token.get_stats()
		atlas_report.reloads.append({"cycle":cycle,"kind":"scene_reload" if cycle%2==0 else "ocean_reinitialize","generation":generation,"before_in_flight":before.get("in_flight",0),"owned_after":after.envelope_owned_resources,"buffers_after":after.owned_buffers,"in_flight_after":after.in_flight,"errors":after.errors,"mismatches":after.mismatches})
		if before.get("in_flight",0)==0 or after.envelope_owned_resources!=0 or after.owned_buffers!=0 or after.in_flight!=0 or after.errors!=0 or after.mismatches!=0: atlas_report.checks.append("reload retirement failure")
		if cycle%2==0:
			_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
			for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
			root.add_child(_ocean)
		for frame in 12: await process_frame
		_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT"); _coastal=_fft.call("get_phys3_coastal_snapshot")
	# Count changes within Phase B: active tile 1 -> 0 -> 1. Multi-tile changes
	# are deferred with Phase C; fixed resources must survive this transition.
	if not await _create_atlas(128,128): return
	atlas_report["active_tile_changes"]=[]
	for active in [true,false,true]:
		var result:=await _atlas_request(PackedVector3Array([Vector3(-260,0,-1350)]),[{"slot":0,"generation":1}],[{"center":Vector2(-260,-1350),"size":Vector2(8,8),"generation":1,"active":active}])
		if result.is_empty(): return
		var row:=ENVELOPE.decode_envelope_contact(result,0); var stats:Dictionary=_query.get_stats()
		atlas_report.active_tile_changes.append({"active":active,"valid":row.valid,"reason":row.reason,"owned_resources":stats.envelope_owned_resources,"buffers":stats.owned_buffers})
		if row.valid!=active: atlas_report.checks.append("active tile transition failed")
	_save_atlas()

func _atlas_confirm() -> void:
	# Validate archived roots against the actual current GPU fields. Mode 0
	# evaluates given material coordinates; it performs no root discovery and
	# supplies no seed or height to mode 5. Both paths share the same FFT updates.
	var closure:Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://.godot/phys_gpu_envelope_closure.json"))
	if not await _create_atlas(2048,2048): return
	var atlas:=_query; var material:Object=_fft.call("enable_gpu_surface_queries")
	for frame in 8: await process_frame
	material.set_validation_metrics_enabled(true)
	atlas_report["current_field_confirmation"]=[]
	for sample in closure.counterexample_sweep[-1].samples:
		var record:Dictionary=sample.record
		_anchor_weather(record)
		if not await _snapshot(int(record.config),record.time,true): return
		var target:=Vector2(record.target[0],record.target[1])
		var result:=await _atlas_request(PackedVector3Array([Vector3(target.x,0.1,target.y)]),[{"slot":0,"generation":_occupant,"reset":true}],[{"center":target,"size":Vector2(8,8),"generation":_occupant}])
		if result.is_empty(): return
		var selected:=ENVELOPE.decode_envelope_contact(result,0)
		var roots:=PackedVector2Array()
		for root_record in record.reference.roots: roots.append(Vector2(root_record.q[0],root_record.q[1]))
		_query=material
		var evaluated:=await _request(roots,false,PackedVector2Array(),false,record.time)
		_query=atlas
		if evaluated.is_empty(): atlas_report.checks.append("current-field root evaluation timeout"); return
		var bytes:PackedByteArray=evaluated.bytes; var confirmed_max:=-INF; var confirmed_q:=Vector2.ZERO; var confirmations:Array=[]
		for i in roots.size():
			var base:int=i*int(evaluated.stride)
			var world:=Vector3(bytes.decode_float(base+32),bytes.decode_float(base+36),bytes.decode_float(base+40))
			var residual:=Vector2(world.x,world.z).distance_to(target)
			var valid:bool=bytes.decode_float(base+28)>0.5 and residual<=0.001
			confirmations.append({"q":roots[i],"world":world,"residual":residual,"valid":valid,"archived_y":record.reference.roots[i].height})
			if valid and world.y>confirmed_max: confirmed_max=world.y; confirmed_q=roots[i]
		var confirmed_wrong:bool=selected.valid and is_finite(confirmed_max) and selected.surface_y<confirmed_max-0.002
		atlas_report.current_field_confirmation.append({"record":record,"selected":selected,"confirmed_max_y":confirmed_max,"confirmed_max_q":confirmed_q,"confirmed_gap":confirmed_max-selected.surface_y,"confirmed_wrong":confirmed_wrong,"roots":confirmations,"atlas_time":result.sample_time_gpu,"material_time":evaluated.sample_time_gpu,"atlas_config":result.config_version,"material_config":evaluated.config_version})
		if result.sample_time_gpu!=evaluated.sample_time_gpu or result.config_version!=evaluated.config_version: atlas_report.checks.append("confirmation field mismatch")
		_occupant+=1
	print("ENVELOPE_CONFIRMED_WRONG="+str(atlas_report.current_field_confirmation.filter(func(s):return s.confirmed_wrong).size())); _save_atlas()

func _atlas_owned_boundary() -> void:
	# Natural GPU history, no injected previous q. The coarse configuration is
	# an ambiguity/hysteresis audit, not an accepted upper-envelope selector.
	atlas_report["owned_boundary"]={"updates":0,"ambiguous_owned":0,"fifth_solves":0,"previous_outside_window":0,"failed":0,"max_solves":0,"max_iterations":0,"samples":[],"parity":[]}
	var totals:Dictionary=atlas_report.owned_boundary
	for step in 240:
		var phase:=sin(step*0.09)
		var target:=Vector2(393.4588,-992.3107)+Vector2(0.6*phase,0.4*sin(step*0.07))
		var result:=await _atlas_request(PackedVector3Array([Vector3(target.x,0.1,target.y)]),[{"slot":0,"generation":_occupant,"reset":step==0}],[{"center":Vector2(393.4588,-992.3107),"size":Vector2(8,8),"generation":_occupant}])
		if result.is_empty(): return
		var row:=ENVELOPE.decode_envelope_contact(result,0)
		totals.updates+=1; totals.ambiguous_owned+=int(row.ambiguous and row.owned); totals.fifth_solves+=int(row.solves==5); totals.failed+=int(not row.valid)
		totals.max_solves=maxi(totals.max_solves,row.solves); totals.max_iterations=maxi(totals.max_iterations,row.iterations)
		var outside:bool=row.solves==5 and absf(row.previous_candidate_y-row.maximum_candidate_y)>0.00201
		totals.previous_outside_window+=int(outside)
		if row.valid and (row.surface_y<row.maximum_candidate_y-0.00201 or row.surface_y>row.maximum_candidate_y+0.00001): atlas_report.checks.append("hysteresis candidate escaped atlas maximum")
		if row.solves>5 or row.iterations>80: atlas_report.checks.append("owned boundary budget exceeded")
		if step<4 or outside: totals.samples.append({"step":step,"row":row})
		if row.valid:
			var material:PackedFloat64Array=_native.call("sample_dynamic_material_q",row.q.x,row.q.y)
			var parity:Dictionary={"displacement_error":row.displacement.distance_to(Vector3(material[2],material[3],material[4])),"velocity_error":row.velocity.distance_to(Vector3(material[8],material[9],material[10])),"normal_angle":rad_to_deg(acos(clampf(row.normal.dot(Vector3(material[5],material[6],material[7])),-1,1))),"residual":row.residual}
			totals.parity.append(parity)
			if parity.displacement_error>0.001 or parity.velocity_error>0.001 or parity.normal_angle>0.5 or row.residual>0.001: atlas_report.checks.append("owned boundary exact parity")
	print("ENVELOPE_OWNED_BOUNDARY="+JSON.stringify({"updates":totals.updates,"fifth_solves":totals.fifth_solves,"previous_outside_window":totals.previous_outside_window,"failed":totals.failed})); _save_atlas()

func _finish_atlas() -> void:
	await _retire_atlas()
	if is_instance_valid(_ocean): _ocean.queue_free()
	for frame in 12: await process_frame
	if _native!=null: _native.call("clear")
	_save_atlas(); print("ENVELOPE_COMPLETE="+JSON.stringify({"checks":atlas_report.checks,"sweep":atlas_report.sweep.size()})); quit(0 if atlas_report.checks.is_empty() else 1)
