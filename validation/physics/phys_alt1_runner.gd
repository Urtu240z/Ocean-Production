extends SceneTree
## Standalone experiment: no gameplay or Production renderer configuration edits.
const OCEAN = preload("res://addons/ocean/ocean.tscn")
const BAKE = preload("res://validation/p4_paradise/coastal_bake.tres")
const ADAPTER = preload("res://addons/ocean/physics/phys1_spectrum_adapter.gd")
const SPECTRUM = preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const K_VALUES = [32, 64, 96, 128, 192, 256, 384, 512]
const HULL = [Vector3(-0.45,-0.15,-1.15), Vector3(0.45,-0.15,-1.15), Vector3(-0.5,-0.15,1.05), Vector3(0.5,-0.15,1.05)]
const STRIDE = 15
var report: Dictionary = {"hardware":"i7-5820K / GTX970", "states":[], "performance":[], "weather":[]}
var ocean: Node
var spectra: Array[Dictionary]
var coast: Dictionary
var sources: Array[Object] = []
var fixed: Array[Object] = []
var poses: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	load("res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension")
	if not ClassDB.class_exists("OceanQueryNative"):
		_fail("Native class missing"); return
	ocean = OCEAN.instantiate()
	for key in ["breakers", "crest_foam", "surface_foam", "reflections", "enable_spindrift"]: ocean.set(key, false)
	ocean.set("coastal_bake", BAKE); ocean.set("coastal", true)
	ocean.set("ocean_scale", 1.0); ocean.set("clipmap_geometry_scale", 1.0)
	root.add_child(ocean)
	for _i in 8: await RenderingServer.frame_post_draw
	var fft: Node = ocean.get_node("OpenOceanFFT")
	spectra = fft.call("get_phys2_band_spectrum_snapshots")
	coast = fft.call("get_phys3_coastal_snapshot")
	if spectra.size() != 3 or not bool(coast.get("active", false)):
		_fail("Production snapshots missing"); return
	ocean.set("wave_speed_multiplier", 0.0)
	var base := _source(spectra)
	if "--verification" in OS.get_cmdline_user_args():
		await _verification(base)
		return
	if "--motion" in OS.get_cmdline_user_args():
		await _motion(base)
		return
	if "--forces" in OS.get_cmdline_user_args():
		_poses()
		await _forces(base,10.0)
		var file := FileAccess.open("res://.godot/phys_alt1_force.json",FileAccess.WRITE)
		file.store_string(JSON.stringify(report,"\t"))
		print("PHYS_ALT_FORCE_COMPLETE")
		ocean.queue_free(); await process_frame; quit(0)
		return
	if "--performance" in OS.get_cmdline_user_args():
		_poses()
		for k in K_VALUES:
			report["performance"].append(_benchmark(_sparse(base,k,0),k,10.0))
			await process_frame
		var file := FileAccess.open("res://.godot/phys_alt1_performance.json",FileAccess.WRITE)
		file.store_string(JSON.stringify(report,"\t"))
		print("PHYS_ALT_PERFORMANCE_COMPLETE")
		ocean.queue_free(); await process_frame; quit(0)
		return
	report["hull"] = {"points":HULL, "mass_kg":300, "footprint_width_m":1.0, "footprint_length_m":2.2, "hull_width_m":1.2,"hull_length_m":3.1}
	report["source"] = ADAPTER.configure_bands(ClassDB.instantiate("OceanQueryNative"), spectra, 0.0)
	# Endpoint preparation uses Production's unique generator and unchanged seed.
	# These are validation configurations, never calls to Ocean.initialize().
	for state in [{"name":"calm","wind":4.0,"hs":0.8,"direction":20.0,"chop":0.8},
			{"name":"normal","retained":true},
			{"name":"storm","wind":18.0,"hs":3.0,"direction":20.0,"chop":2.0},
			{"name":"direction","wind":18.0,"hs":3.0,"direction":75.0,"chop":2.0}]:
		var started := Time.get_ticks_usec()
		var snapshots: Array[Dictionary] = spectra if bool(state.get("retained",false)) else _weather_snapshots(state)
		var source: Object = base if bool(state.get("retained",false)) else _source(snapshots)
		sources.append(source)
		state["endpoint_prepare_ms"] = (Time.get_ticks_usec()-started)/1000.0
		report["states"].append({"configuration":state, "sweep":[]})
		await process_frame
	_poses()
	for k in K_VALUES:
		fixed.append(_sparse(base,k,0))
	# Full-budget selection is an exact source/coordinate/kernel control.
	var control := _sparse(base,3*256*256,0)
	var control_points := PackedVector3Array([Vector3(-1000,0,750),Vector3(31,0,45),Vector3(511.9,0,-512.1),Vector3(330,0,200)])
	var t := float(ocean.call("get_wave_time"))
	var full_control: PackedFloat64Array = base.call("sample_material_q_batch",t,control_points)
	var subset_control: PackedFloat64Array = control.call("sample_material_q_batch",t,control_points)
	report["full_budget_control_max"] = _max_difference(full_control,subset_control)
	control = null
	for s in sources.size():
		var source := sources[s]
		var candidates: Array[Object] = []
		for k in K_VALUES:
			candidates.append(_sparse(source,k,0))
			candidates.append(_sparse(source,k,4))
		var measurements: Array[Dictionary] = []
		for c in candidates.size(): measurements.append(_empty_measurement())
		var fixed_measurements: Array[Dictionary] = []
		for _k in K_VALUES: fixed_measurements.append(_empty_measurement())
		for p in poses.size():
			var pose: Dictionary = poses[p]
			var points: PackedVector3Array = pose["points"]
			var time: float = pose["time"]
			var authority: PackedFloat64Array = source.call("sample_material_q_batch",time,points)
			for c in candidates.size():
				var sparse: PackedFloat64Array = candidates[c].call("sample_material_q_batch",time,points)
				_collect(measurements[c],authority,sparse,pose)
			for c in fixed.size():
				var sparse: PackedFloat64Array = _fixed_sample(fixed[c],source,time,points)
				_collect(fixed_measurements[c],authority,sparse,pose)
			if p % 32 == 0: await process_frame
		for c in candidates.size():
			var k: int = K_VALUES[c/2]
			var result := _finish(measurements[c])
			result["K"] = k; result["policy"] = "global" if c%2 == 0 else "quota4"
			result["selection"] = candidates[c].call("get_sparse_selection_stats")
			report["states"][s]["sweep"].append(result)
		for c in fixed.size():
			var result := _finish(fixed_measurements[c])
			result["K"] = K_VALUES[c]; result["policy"] = "fixed-normal"
			report["states"][s]["sweep"].append(result)
		print("PHYS_ALT_STATE ",s," K512 ",JSON.stringify(report["states"][s]["sweep"][14]["hull"]))
		_save()
		candidates.clear()
	for k in K_VALUES:
		var query := _sparse(base,k,0)
		report["performance"].append(_benchmark(query,k,t))
		await process_frame
	await _weather()
	await _forces(base,t)
	report["result"] = "BLOCKED"
	for state in report["states"]:
		for row in state["sweep"]:
			row["experimental_hull_target_met"] = row["hull"][0]["nrmse"] <= 0.05 and row["hull"][1]["nrmse"] <= 0.1 and row["hull"][2]["nrmse"] <= 0.1 and row["hull"][0]["correlation"] >= 0.98 and row["hull"][1]["correlation"] >= 0.95 and row["hull"][2]["correlation"] >= 0.95
	for k in K_VALUES:
		for policy in ["global","quota4","fixed-normal"]:
			var all_states := true
			for state in report["states"]:
				for row in state["sweep"]:
					if row["K"] == k and row["policy"] == policy: all_states = all_states and row["experimental_hull_target_met"]
			if all_states: report["result"] = "PARTIAL" # Renderer weather integration would still need validation.
	_save()
	print("PHYS_ALT_COMPLETE ",report["result"]," report=.godot/phys_alt1.json")
	ocean.queue_free()
	await process_frame
	quit(0)

func _source(snapshots: Array[Dictionary]) -> Object:
	var query: Object = ClassDB.instantiate("OceanQueryNative")
	assert(ADAPTER.configure_bands(query,snapshots,0.0)["ok"])
	assert(ADAPTER.configure_coastal(query,coast)["ok"])
	return query

func _sparse(source: Object,k: int,quota: int) -> Object:
	var query: Object = ClassDB.instantiate("OceanQueryNative")
	assert(query.call("configure_hull_sparse",source,PackedVector3Array(HULL),k,quota))
	return query

func _fixed_sample(query: Object,source: Object,t: float,points: PackedVector3Array) -> PackedFloat64Array:
	assert(query.call("blend_sparse_sources",source,source,0.0))
	return query.call("sample_material_q_batch",t,points)

func _weather_snapshots(state: Dictionary) -> Array[Dictionary]:
	var profile: Resource = ocean.get("wave_profile")
	var configs: Array = profile.call("build_fft_configs",state["hs"],state["wind"],state["direction"],ocean.get("swell"),ocean.get("long_wave_spacing"))
	var raw: Array[PackedByteArray] = []
	var variance := 0.0
	for b in 3:
		var config: Resource = configs[b]
		config.set("choppiness",state["chop"])
		var data := SPECTRUM.build_h0_rgba32f(config,SPECTRUM.derive_cascade_seed(int(ocean.get("simulation_seed")),config.get("id")),false)
		var scale: float = float(config.get("target_hs_m"))/float(state["hs"])
		if b == 1: scale *= float(ocean.get("mid_fill_amount"))
		raw.append(SPECTRUM.scale_packed_h0(data,scale))
		variance += pow(float(config.get("measured_hs_m"))*scale/4.0,2.0)
	var common := float(state["hs"])/(4.0*sqrt(variance))
	var result: Array[Dictionary] = []
	for b in 3:
		var snapshot := spectra[b].duplicate()
		snapshot["h0_rgba32f"] = SPECTRUM.scale_packed_h0(raw[b],common)
		snapshot["choppiness"] = state["chop"]
		result.append(snapshot)
	return result

func _poses() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 501310
	var origin: Vector2 = coast["field_origin"]; var extent: Vector2 = coast["field_extent"]
	for i in 256:
		var region := i%4
		var center := Vector2.ZERO
		match region:
			0: center = origin-Vector2(200.0,200.0)+Vector2(i*0.3,2.0*sin(i*0.1))
			1: center = origin+extent*Vector2(rng.randf_range(0.15,0.85),rng.randf_range(0.15,0.85))
			2: center = origin+Vector2(extent.x*rng.randf(),[-0.02,0.02,extent.y-0.02,extent.y+0.02][(i/4)%4])
			3: center = Vector2([-512.001,-256.001,-0.001,0.001,255.999,512.001][(i/4)%6],rng.randf_range(-512,512))
		var yaw := float(i%16)*TAU/16.0
		var points := PackedVector3Array()
		for point in HULL:
			var offset := Vector2(point.x,point.z).rotated(yaw)
			points.append(Vector3(center.x+offset.x,0.0,center.y+offset.y))
		poses.append({"points":points,"yaw":yaw,"time":0.25+i*0.073,"region":region})

func _empty_measurement() -> Dictionary:
	return {"surface":[[],[],[],[]],"hull_full":[[],[],[],[],[],[]],"hull_sparse":[[],[],[],[],[],[]],"regions":[[],[],[],[]]}

func _collect(m: Dictionary,full: PackedFloat64Array,sparse: PackedFloat64Array,pose: Dictionary) -> void:
	var hf := PackedFloat64Array(); hf.resize(6)
	var hs := PackedFloat64Array(); hs.resize(6)
	for j in 4:
		var b := j*STRIDE
		var height := absf(full[b+1]-sparse[b+1])
		m["surface"][0].append(height)
		m["surface"][1].append(absf(full[b+9]-sparse[b+9]))
		m["surface"][2].append(Vector2(full[b+2]-sparse[b+2],full[b+4]-sparse[b+4]).length())
		var n := Vector3(full[b+5],full[b+6],full[b+7]); var ns := Vector3(sparse[b+5],sparse[b+6],sparse[b+7])
		m["surface"][3].append(rad_to_deg(acos(clampf(n.dot(ns),-1,1))))
		m["regions"][pose["region"]].append(height)
		var weights := [0.25,(HULL[j].z+0.05)/4.4,HULL[j].x/1.9]
		for a in 3:
			hf[a] += weights[a]*full[b+1]; hs[a] += weights[a]*sparse[b+1]
			hf[a+3] += weights[a]*full[b+9]; hs[a+3] += weights[a]*sparse[b+9]
	for a in 6: m["hull_full"][a].append(hf[a]); m["hull_sparse"][a].append(hs[a])

func _finish(m: Dictionary) -> Dictionary:
	var result := {"surface":[],"hull":[],"regions":[]}
	for values in m["surface"]: result["surface"].append(_stats(values))
	for a in 6: result["hull"].append(_comparison(m["hull_full"][a],m["hull_sparse"][a]))
	for values in m["regions"]: result["regions"].append(_stats(values))
	return result

func _stats(values: Array) -> Dictionary:
	var sorted := values.duplicate(); sorted.sort()
	var sum := 0.0; var sq := 0.0
	for x in values: sum += float(x); sq += float(x)*float(x)
	var n := values.size()
	return {"count":n,"mean":sum/n,"rms":sqrt(sq/n),"p95":sorted[ceili(0.95*n)-1],"p99":sorted[ceili(0.99*n)-1],"max":sorted[-1]}

func _comparison(a: Array,b: Array) -> Dictionary:
	var errors: Array = []; var aa := 0.0; var ma := 0.0; var mb := 0.0
	for i in a.size(): errors.append(absf(a[i]-b[i])); aa += a[i]*a[i]; ma += a[i]; mb += b[i]
	ma /= a.size(); mb /= b.size()
	var va := 0.0; var vb := 0.0; var covariance := 0.0
	for i in a.size(): va += pow(a[i]-ma,2); vb += pow(b[i]-mb,2); covariance += (a[i]-ma)*(b[i]-mb)
	var stats := _stats(errors)
	stats["reference_rms"] = sqrt(aa/a.size())
	stats["nrmse"] = stats["rms"]/maxf(stats["reference_rms"],1e-12)
	stats["correlation"] = covariance/sqrt(maxf(va*vb,1e-24))
	return stats

func _benchmark(query: Object,k: int,t: float) -> Dictionary:
	var result := {"K":k,"selection":query.call("get_sparse_selection_stats"),"batches":[]}
	var prepare: Array = []
	for i in 300:
		var start := Time.get_ticks_usec(); query.call("ensure_prepared",t+i/60.0); prepare.append((Time.get_ticks_usec()-start)/1000.0)
	result["prepare_ms"] = _stats(prepare)
	for n in [4,8,16,64]:
		var points := PackedVector3Array()
		for i in n: points.append(poses[1]["points"][i%4]+Vector3((i/4)*0.07,0,0))
		query.call("sample_material_q_batch",t,points)
		query.call("set_coastal_profile_enabled",true)
		query.call("reset_coastal_profile")
		query.call("sample_material_q_batch",t,points)
		var work: PackedInt64Array = query.call("get_coastal_profile_detail")
		query.call("set_coastal_profile_enabled",false)
		var batch: Array = []; var scalar: Array = []
		for _i in 80:
			var start := Time.get_ticks_usec(); query.call("sample_material_q_batch",t,points); batch.append((Time.get_ticks_usec()-start)/1000.0)
			start = Time.get_ticks_usec()
			for p in points: query.call("sample_material_q",p.x,p.z,t)
			scalar.append((Time.get_ticks_usec()-start)/1000.0)
		result["batches"].append({"N":n,"coastal_batch_ms":_stats(batch),"coastal_scalar_ms":_stats(scalar),"warped_long_center_mode_evaluations":work[65]})
	return result

func _weather() -> void:
	var query := _sparse(sources[1],512,0)
	var identities: PackedInt64Array = query.call("get_sparse_mode_ids")
	var points: PackedVector3Array = poses[1]["points"]
	ocean.set("wave_speed_multiplier",1.0)
	for transition in [[0,2],[2,0],[1,3]]:
		var updates: Array = []; var jumps: Array = []; var previous := PackedFloat64Array()
		var identity_stable := true
		for step in 61:
			await physics_frame
			var t := float(ocean.call("get_wave_time"))
			var start := Time.get_ticks_usec()
			assert(query.call("blend_sparse_sources",sources[transition[0]],sources[transition[1]],step/60.0))
			updates.append((Time.get_ticks_usec()-start)/1000.0)
			var current: PackedFloat64Array = query.call("sample_material_q_batch",t,points)
			if not previous.is_empty(): jumps.append(_max_difference(previous,current))
			previous = current
			identity_stable = identity_stable and identities == query.call("get_sparse_mode_ids")
		report["weather"].append({"from":transition[0],"to":transition[1],"update_ms":_stats(updates),"maximum_sample_step":jumps.max(),"fixed_ids":identity_stable,"no_restart":true,"clock":"Ocean.get_wave_time","renderer_endpoint_uploaded":false})
		_save()

func _forces(source: Object,t: float) -> void:
	# Exact offline copy of Water Race's point normal buoyancy + tangential drag.
	# Identical prescribed body state for A/B, not an invented gameplay law.
	var queries: Array[Object] = []
	var full_values: Array = []; var sparse_values: Array = []
	for k in K_VALUES: queries.append(_sparse(source,k,0)); sparse_values.append([[],[],[],[],[],[]])
	for _a in 6: full_values.append([])
	var failures := 0
	var authority_failures := 0
	for p in 32:
		var pose: Dictionary = poses[p]
		var points: PackedVector3Array = pose["points"]
		var time := t+p*0.071
		var full: PackedFloat64Array = source.call("sample_batch",time,points)
		for j in 4:
			if full[j*STRIDE+13] > 0.001: authority_failures += 1
		var body_y := 0.0
		for j in 4: body_y += full[j*STRIDE+1]*0.25
		body_y += 0.15-0.2
		var f := _force(full,body_y,pose["yaw"])
		for a in 6: full_values[a].append(f[a])
		for c in queries.size():
			var sparse: PackedFloat64Array = queries[c].call("sample_batch",time,points)
			for j in 4:
				if sparse[j*STRIDE+13] > 0.001: failures += 1
			var value := _force(sparse,body_y,pose["yaw"])
			for a in 6: sparse_values[c][a].append(value[a])
		await process_frame
	report["forces"] = []
	for c in queries.size():
		var stats: Array = []
		for a in 6: stats.append(_comparison(full_values[a],sparse_values[c][a]))
		report["forces"].append({"K":K_VALUES[c],"samples":32,"force_xyz_torque_xyz":stats})
	report["force_sparse_world_nonconverged"] = failures
	report["force_authority_world_nonconverged"] = authority_failures

func _force(samples: PackedFloat64Array,body_y: float,yaw: float) -> PackedFloat64Array:
	var force := Vector3.ZERO; var torque := Vector3.ZERO
	var forward := Vector3(sin(yaw),0,-cos(yaw))
	for j in 4:
		var b := j*STRIDE
		var depth := samples[b+1]-(body_y-0.15)
		if depth <= 0.0: continue
		var n := Vector3(samples[b+5],samples[b+6],samples[b+7]).normalized()
		var offset2 := Vector2(HULL[j].x,HULL[j].z).rotated(yaw)
		var offset := Vector3(offset2.x,-0.15,offset2.y)
		var angular_velocity := Vector3(0.12,0.0,-0.08)
		var body_velocity := forward*6.0+angular_velocity.cross(offset)
		var relative := body_velocity-Vector3(samples[b+8],samples[b+9],samples[b+10])
		var ratio := clampf(depth/0.8,0,1)
		var excess := maxf(depth-1.0,0)
		var raw := minf(depth,0.8)*5500.0+excess*3500.0
		var magnitude := clampf(raw-relative.dot(n)*2500.0*ratio,0,5500.0+excess*5000.0)
		var point_force := n*magnitude
		var tangent := relative-n*relative.dot(n)
		var ft := (forward-n*forward.dot(n)).normalized()
		var rt := ft.cross(n).normalized()
		var fs := tangent.dot(ft); var rs := tangent.dot(rt)
		point_force -= ft*clampf((15.0*fs+1.5*fs*absf(fs))*ratio,-3500,3500)
		point_force -= rt*clampf((80.0*rs+7.0*rs*absf(rs))*ratio,-7000,7000)
		force += point_force; torque += offset.cross(point_force)
	var body_torque := Vector2(torque.x,torque.z).rotated(-yaw)
	return PackedFloat64Array([force.x,force.y,force.z,body_torque.x,torque.y,body_torque.y])

func _max_difference(a: PackedFloat64Array,b: PackedFloat64Array) -> float:
	var maximum := 0.0
	for i in a.size(): maximum = maxf(maximum,absf(a[i]-b[i]))
	return maximum

func _save() -> void:
	var file := FileAccess.open("res://.godot/phys_alt1.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))

func _fail(message: String) -> void:
	printerr("PHYS_ALT_FAILED ",message); quit(1)

func _verification(source: Object) -> void:
	var rows: Array = []
	var points := PackedVector3Array([Vector3(-1000,0,750),Vector3(31,0,45),Vector3(511.9,0,-512.1),Vector3(330,0,200)])
	var t := float(ocean.call("get_wave_time"))
	for k in K_VALUES:
		var selection_start := Time.get_ticks_usec()
		var query := _sparse(source,k,0)
		var selection_ms := (Time.get_ticks_usec()-selection_start)/1000.0
		var batch: PackedFloat64Array = query.call("sample_material_q_batch",t,points)
		var scalar := PackedFloat64Array()
		for p in points: scalar.append_array(query.call("sample_material_q",p.x,p.z,t))
		var row := {"K":k,"selection_ms":selection_ms,"material_scalar_batch_max":_max_difference(batch,scalar),"world":[]}
		batch = query.call("sample_batch",t,points); scalar.clear()
		for p in points: scalar.append_array(query.call("sample_world",p.x,p.z,t))
		row["world_scalar_batch_max"] = _max_difference(batch,scalar)
		for n in [4,16]:
			var world_points := PackedVector3Array()
			for j in n: world_points.append(points[j%4])
			query.call("sample_batch",t,world_points)
			var timings: Array = []
			for _j in 80:
				var start := Time.get_ticks_usec(); query.call("sample_batch",t,world_points); timings.append((Time.get_ticks_usec()-start)/1000.0)
			row["world"].append({"N":n,"ms":_stats(timings)})
		query.call("clear_coastal")
		var timings: Array = []
		for _j in 300:
			var start := Time.get_ticks_usec(); query.call("sample_material_q_batch",t,points); timings.append((Time.get_ticks_usec()-start)/1000.0)
		row["open_material_N4_ms"] = _stats(timings)
		# Exact fallback, not an approximation-specific empirical adjustment.
		var open_values: PackedFloat64Array = query.call("sample_material_q_batch",t,points)
		ADAPTER.configure_coastal(query,coast)
		var coastal_values: PackedFloat64Array = query.call("sample_material_q_batch",t,points)
		row["outside_fallback_max"] = 0.0
		var o: Vector2 = coast["field_origin"]; var e: Vector2 = coast["field_extent"]
		for j in 4:
			var p := points[j]
			if p.x < o.x or p.x > o.x+e.x or p.z < o.y or p.z > o.y+e.y:
				for a in STRIDE: row["outside_fallback_max"] = maxf(row["outside_fallback_max"],absf(open_values[j*STRIDE+a]-coastal_values[j*STRIDE+a]))
		rows.append(row)
		await process_frame
	var output := {"verification":rows,"sea_state":ocean.call("get_sea_state"),"default_source_unchanged":true}
	var file := FileAccess.open("res://.godot/phys_alt1_verification.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(output,"\t"))
	print("PHYS_ALT_VERIFY_COMPLETE")
	ocean.queue_free(); await process_frame; quit(0)

func _motion(source: Object) -> void:
	var queries: Array[Object] = []
	for k in K_VALUES: queries.append(_sparse(source,k,0))
	var paths: Array = []
	var origin: Vector2 = coast["field_origin"]; var extent: Vector2 = coast["field_extent"]
	for region in 4:
		var measures: Array[Dictionary] = []
		for _k in K_VALUES: measures.append(_empty_measurement())
		var center := origin-Vector2(200,200)
		var velocity := Vector2(8,2)
		var yaw := 0.0
		match region:
			1: center = origin+extent*0.5; velocity = Vector2(4,3); yaw = 0.6
			2: center = origin+Vector2(-2,extent.y*0.45); velocity = Vector2(1,0); yaw = 1.2
			3: center = Vector2(255,-300); velocity = Vector2(2,1); yaw = 2.4
		for tick in 240:
			var q := center+velocity*(tick/60.0)
			var points := PackedVector3Array()
			for r in HULL:
				var p := q+Vector2(r.x,r.z).rotated(yaw)
				points.append(Vector3(p.x,0,p.y))
			var t := 10.0+tick/60.0
			var full: PackedFloat64Array = source.call("sample_material_q_batch",t,points)
			for c in queries.size():
				var sparse: PackedFloat64Array = queries[c].call("sample_material_q_batch",t,points)
				_collect(measures[c],full,sparse,{"region":region})
			if tick%32 == 0: await process_frame
		var rows: Array = []
		for c in queries.size():
			# Only this region is populated in the motion data.
			var summary := {"K":K_VALUES[c],"surface":[],"hull":[]}
			for values in measures[c]["surface"]: summary["surface"].append(_stats(values))
			for a in 6: summary["hull"].append(_comparison(measures[c]["hull_full"][a],measures[c]["hull_sparse"][a]))
			rows.append(summary)
		paths.append({"region":region,"origin":center,"velocity_mps":velocity,"yaw_rad":yaw,"ticks":240,"physics_hz":60,"sweep":rows})
		print("PHYS_ALT_MOTION ",region)
	var file := FileAccess.open("res://.godot/phys_alt1_motion.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"paths":paths},"\t"))
	print("PHYS_ALT_MOTION_COMPLETE")
	ocean.queue_free(); await process_frame; quit(0)
