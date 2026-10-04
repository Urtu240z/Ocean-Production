extends SceneTree
## Compact evidence export only. GPU measurements are produced by the native
## Forward+/D3D12 runners; this script may run headless after they complete.
const OUTPUT := "res://validation/physics/PHYS-GPU-ENVELOPE-1-MEASUREMENTS.json"
var _inputs:Dictionary={}
var _errors:Array=[]

func _initialize() -> void:
	call_deferred("_export")

func _read(name:String) -> Dictionary:
	var path:="res://.godot/"+name+".json"
	if not FileAccess.file_exists(path): _errors.append("missing "+path); return {}
	var parsed=JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary: _errors.append("invalid "+path); return {}
	_inputs[name]={"scratch":path,"sha256":FileAccess.get_sha256(path),"bytes":FileAccess.get_file_as_bytes(path).size(),"source_hashes":parsed.get("source_hashes",{}),"checks":parsed.get("checks",parsed.get("failures",[])),"after_shutdown":parsed.get("after_shutdown",[])}
	return parsed

func _distribution(values:Array) -> Dictionary:
	if values.is_empty(): return {"count":0}
	values.sort(); var total:=0.0; var squares:=0.0
	for value in values: total+=float(value); squares+=float(value)*float(value)
	return {"count":values.size(),"mean":total/values.size(),"rms":sqrt(squares/values.size()),"p50":values[mini(values.size()-1,int(ceil(values.size()*0.5))-1)],"p95":values[mini(values.size()-1,int(ceil(values.size()*0.95))-1)],"max":values[-1]}

func _parity(rows:Array,keys:Array) -> Dictionary:
	var result:Dictionary={"count":rows.size(),"all":{},"by_profile":{}}
	for key in keys:
		var values:Array=[]
		for row in rows: values.append(row[key])
		result.all[key]=_distribution(values)
	for row in rows:
		var label:String=row.state
		if not result.by_profile.has(label): result.by_profile[label]=[]
		result.by_profile[label].append(row)
	for label in result.by_profile:
		var samples:Array=result.by_profile[label]; var summary:Dictionary={"count":samples.size()}
		for key in keys:
			var values:Array=[]
			for row in samples: values.append(row[key])
			summary[key]=_distribution(values)
		result.by_profile[label]=summary
	return result

func _replay(source:Dictionary) -> Dictionary:
	var result:Dictionary=source.get("replay",{}).duplicate(true)
	# Full summaries, six reviewable counterexamples; complete new results remain
	# scratch. The original 214 MiB reference archive is reused, never copied.
	result["retained_example_count"]=result.get("examples",[]).size()
	result["examples"]=result.get("examples",[]).slice(0,6)
	return result

func _export() -> void:
	var feasibility:=_read("phys_gpu_envelope_feasibility")
	var single:=_read("phys_gpu_envelope_single_tile")
	var dense:=_read("phys_gpu_envelope_dense")
	var baseline:=_read("phys_gpu_envelope_replay")
	var replay:=_read("phys_gpu_envelope_replay_dense")
	var cold:=_read("phys_gpu_envelope_cold_replay")
	var closure:=_read("phys_gpu_envelope_closure")
	var focused:=_read("phys_gpu_envelope_focused_parity")
	var atlas:=_read("phys_gpu_envelope_atlas_parity")
	var legacy:=_read("phys_gpu1_matrix")
	var resources:=_read("phys_gpu_envelope_resources")
	var confirmation:=_read("phys_gpu_envelope_confirm")
	var owned:=_read("phys_gpu_envelope_owned_boundary")
	if not _errors.is_empty(): print(_errors); quit(1); return
	# Sweep results are stored in order; the last 49 are 512 pixel / q2048.
	var selected:Array=dense.single_tile.slice(dense.single_tile.size()-49)
	var result:Dictionary={"phase":"PHYS-GPU-ENVELOPE-1","status":"BLOCKED","architectural_conclusion":"NOT READY FOR PHYS-GPU-2","starting_head":"98928f170aa53023c83215376c85990d9cf8a2b4","environment":replay.environment,"inputs":_inputs,"feasibility":feasibility,"initial_sweep":single.sweep,"dense_sweep":dense.sweep,"dense_512_q2048_samples":selected,"baseline_replay":_replay(baseline),"dense_replay":_replay(replay),"cold_replay":_replay(cold),"counterexample_sweep":closure.counterexample_sweep,"physical_two_root":closure.physical_two_root,"signed_depth":closure.depth,"in_flight_retirement":closure.lifecycle,"reloads":resources.reloads,"active_tile_changes":resources.active_tile_changes,"coalescing":atlas.coalescing,"tile_rejection":atlas.tile_rejection}
	result["historical_focused_parity"]=_parity(focused.focused_parity,["displacement_error","velocity_error","normal_angle","residual_gpu","residual_cpu","q_known","q_cpu"])
	result["current_field_confirmation"]=confirmation.current_field_confirmation
	result["physical_two_root"]=owned.physical_two_root
	result["owned_boundary"]=owned.owned_boundary.duplicate(true)
	result.owned_boundary["samples"]=owned.owned_boundary.samples.slice(0,16)
	result.owned_boundary["parity"]={}
	for key in ["displacement_error","velocity_error","normal_angle","residual"]:
		var values:Array=[]
		for row in owned.owned_boundary.parity: values.append(row[key])
		result.owned_boundary.parity[key]=_distribution(values)
	result["atlas_focused_parity"]=_parity(atlas.atlas_parity,["displacement_error","velocity_error","normal_angle","residual","q_known","depth_range_fraction","solves","iterations"])
	result["legacy_parity"]={"status":legacy.status,"failures":legacy.failures,"material_samples":legacy.parity_aggregate.all.dx.count,"material":legacy.parity_aggregate,"world":legacy.world_aggregate.all,"after_shutdown":{"buffers":legacy.after_shutdown.owned_buffers,"in_flight":legacy.after_shutdown.in_flight,"errors":legacy.after_shutdown.errors,"mismatches":legacy.after_shutdown.mismatches}}
	result["final_source_hashes"]={}
	for filename in ["ocean_surface_query.glsl","ocean_surface_query.gd","ocean_envelope_atlas.gd","ocean_envelope_shader_source.gd","ocean_envelope_query.comp","ocean_envelope_shared.inc","ocean_envelope_raster.vert","ocean_envelope_raster.frag","ocean_envelope_bounds.comp","ocean_envelope_holes.comp"]:
		result.final_source_hashes[filename]=FileAccess.get_sha256("res://addons/ocean/physics/gpu/"+filename)
	for filename in ["phys_gpu_envelope_runner.gd","phys_gpu_envelope_feasibility.gd","phys_gpu_envelope_export.gd"]:
		result.final_source_hashes[filename]=FileAccess.get_sha256("res://validation/physics/"+filename)
	result.final_source_hashes["open_ocean_fft.gd"]=FileAccess.get_sha256("res://addons/ocean/fft/open_ocean_fft.gd")
	result["reference_archives"]={}
	for filename in ["PHYS-GPU-1.3-EVIDENCE-MANIFEST.json","PHYS-GPU-1.3-MEASUREMENTS.json","PHYS-GPU-1.3-OLD-RECLASSIFICATION.json"]:
		var path:String="res://validation/physics/"+filename
		if not FileAccess.file_exists(path): _errors.append("missing reference "+path)
		result.reference_archives[filename]={"sha256":FileAccess.get_sha256(path),"bytes":FileAccess.get_file_as_bytes(path).size()}
	if result.dense_replay.cases!=52054 or result.dense_replay.main_wrong_before!=33017 or result.dense_replay.main_miss_before!=1145: _errors.append("full corpus incomplete")
	if result.cold_replay.by_source.main.cases!=1204: _errors.append("cold fold incomplete")
	if result.historical_focused_parity.count!=1280 or result.atlas_focused_parity.count!=1280 or result.legacy_parity.material_samples!=6912: _errors.append("parity incomplete")
	if result.dense_replay.wrong_sheet<=0: _errors.append("blocked conclusion lacks wrong-sheet evidence")
	if result.current_field_confirmation.filter(func(s):return s.confirmed_wrong).is_empty(): _errors.append("current GPU fields did not confirm wrong-sheet evidence")
	for name in _inputs:
		for check in _inputs[name].checks:
			# Retain the two measured accuracy failures in the BLOCKED artifact.
			# Protocol/lifetime/budget failures must still prevent export.
			if name=="phys_gpu_envelope_owned_boundary" and check=="owned boundary exact parity": continue
			_errors.append("runner checks failed: "+name+" / "+str(check))
	result["export_checks"]=_errors
	if not _errors.is_empty(): print(_errors); quit(1); return
	FileAccess.open(OUTPUT,FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print("ENVELOPE_COMPACT_EXPORT="+str(FileAccess.get_file_as_bytes(OUTPUT).size())); quit()
