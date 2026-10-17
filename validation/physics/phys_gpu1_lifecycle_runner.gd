extends "res://validation/physics/phys_gpu1_runner.gd"
## Focused follow-up: open derivatives, multiple owned roots, in-flight teardown.
func _run() -> void:
	load(DESCRIPTOR)
	if not ClassDB.class_exists("OceanQueryNative"): _fail("native unavailable"); return
	_report = {"status":"PARTIAL","matrix":[],"world":[],"failures":[],"lifecycle":[],"branches":[]}
	var camera:=Camera3D.new(); root.add_child(camera); camera.position=Vector3(0,16,35); camera.look_at(Vector3.ZERO); camera.current=true
	for cycle in 4:
		_ocean=OCEAN_SCENE.instantiate(); _ocean.set("coastal_bake",BAKE); _ocean.set("coastal",true)
		for property in ["breakers","crest_foam","surface_foam"]: _ocean.set(property,false)
		root.add_child(_ocean)
		for _frame in 12: await process_frame
		_ocean.set("wave_speed_multiplier",0.0); _fft=_ocean.get_node("OpenOceanFFT")
		_coastal=_fft.call("get_phys3_coastal_snapshot")
		_query=_fft.call("enable_gpu_surface_queries")
		for _frame in 4: await process_frame
		_points.clear(); _labels.clear(); _make_points()
		if cycle==0:
			_native=_new_mirror(_fft.call("get_phys2_band_spectrum_snapshots"),2.25)
			if not await _at(2.25): return
			var material:=await _request(_points,false,PackedVector2Array(),false,2.25)
			if material.is_empty(): return
			await _branch_pairs(material)
			# Same sources with Coastal disabled exercises the packed spectral slopes.
			_fft.set("_coastal_waves_active",false); _native.call("clear_coastal")
			var open_result:=await _request(_points,false,PackedVector2Array(),false,2.25)
			if open_result.is_empty(): return
			_compare(open_result,"open_without_coastal")
			_native.call("clear")
		# Deliberately overload the single pending mailbox, then retire while
		# the resulting GPU readback is in flight. Callbacks own only the token.
		for _submission in 32: _query.submit(QUERY.pack_queries(_points),Engine.get_physics_frames())
		var observed_in_flight:=0
		for _frame in 8:
			await process_frame
			observed_in_flight=int(_query.get_stats().in_flight)
			if observed_in_flight>0: break
		var token:=_query
		_ocean.queue_free()
		for _frame in 12: await process_frame
		var stats:Dictionary=token.get_stats()
		_report.lifecycle.append({"cycle":cycle,"retired_in_flight":observed_in_flight,"buffers_after":stats.owned_buffers,
			"in_flight_after":stats.in_flight,"errors":stats.errors,"mismatches":stats.mismatches,"coalesced":stats.coalesced,
			"metric_records":stats.latency_ms.size(),"trace_records":token.get_validation_trace().size(),"static_memory":OS.get_static_memory_usage()})
		if stats.owned_buffers!=0 or stats.in_flight!=0 or stats.errors!=0 or stats.mismatches!=0: _report.failures.append("teardown failed")
	_report.status="PASS" if _report.failures.is_empty() else "PARTIAL"
	_save(); print("GPU1_LIFECYCLE="+JSON.stringify(_report)); quit(0 if _report.failures.is_empty() else 1)

func _branch_pairs(material: Dictionary) -> void:
	var bytes:PackedByteArray=material.bytes
	var proved:=false
	for index in _points.size():
		if bytes.decode_float(index*96+44)>=0.0: continue
		var target:=Vector2(bytes.decode_float(index*96+32),bytes.decode_float(index*96+40))
		var targets:=PackedVector2Array(); var seeds:=PackedVector2Array()
		for seed in 256:
			targets.append(target); seeds.append(_points[index]+Vector2((seed%16-7.5)*0.08,(seed/16-7.5)*0.08))
		var result:=await _request(targets,true,seeds,false,2.25)
		if result.is_empty(): return
		var roots:=PackedVector2Array(); bytes=result.bytes
		for seed in 256:
			if bytes.decode_float(seed*96+28)<0.5: continue
			var q:=Vector2(bytes.decode_float(seed*96),bytes.decode_float(seed*96+4))
			var distinct:=true
			for root_q in roots:
				if q.distance_to(root_q)<0.02: distinct=false; break
			if distinct: roots.append(q)
		if roots.size()>=2:
			var a:=roots[0]; var b:=roots[1]
			var continued:=await _request(PackedVector2Array([target+Vector2(0.002,0.002),target+Vector2(0.002,0.002)]),
				true,PackedVector2Array([a,b]),false,2.25)
			if continued.is_empty(): return
			var cb:PackedByteArray=continued.bytes
			var qa:=Vector2(cb.decode_float(0),cb.decode_float(4)); var qb:=Vector2(cb.decode_float(96),cb.decode_float(100))
			proved=cb.decode_float(28)>0.5 and cb.decode_float(124)>0.5 and qa.distance_to(qb)>0.01
			_report.branches.append({"target":str(target),"distinct_roots":roots.size(),"seed_a":str(a),"seed_b":str(b),
				"continued_a":str(qa),"continued_b":str(qb),"separation":qa.distance_to(qb),"owned_branches_preserved":proved})
			break
		bytes=material.bytes
	if not proved: _report.failures.append("multiple-root continuation not proved")

func _save() -> void:
	var file:=FileAccess.open("res://.godot/phys_gpu1_lifecycle.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(_report,"\t")); file.close()
