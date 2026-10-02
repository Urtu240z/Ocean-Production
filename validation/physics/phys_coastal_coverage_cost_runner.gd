extends "res://validation/physics/phys_weather_velocity_runner.gd"
## Identical points/time/repetitions for a saved baseline DLL and the current DLL.
func _run() -> void:
	var expected: String = preload("res://validation/physics/phys_native_build_contract.gd").ID
	var label := "after"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--expected-build="): expected = arg.trim_prefix("--expected-build=")
		if arg.begins_with("--label="): label = arg.trim_prefix("--label=")
	var ocean: Node = OCEAN_SCENE.instantiate()
	ocean.set("coastal_bake", COASTAL_BAKE); ocean.set("coastal", true)
	for p in ["breakers", "crest_foam", "surface_foam"]: ocean.set(p, false)
	root.add_child(ocean)
	for _i in 20: await physics_frame
	ocean.set("wave_speed_multiplier", 0.0)
	var fft: Node = ocean.get_node("OpenOceanFFT")
	var bake: Dictionary = fft.call("get_phys3_coastal_snapshot")
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	if native.call("get_dynamic_async_build_id") != expected: _fail("cost benchmark DLL guard"); return
	if not native.call("prepare_production_spectrum", fft.call("get_phys2_band_spectrum_snapshots")) \
			or not ADAPTER.configure_coastal(native, bake).ok:
		_fail("cost benchmark spectrum/bake"); return
	native.call("set_dynamic_worker_count", 4)
	if not native.call("build_dynamic_physics_fields", 2.25): _fail("cost benchmark build"); return
	var material := PackedVector3Array(); var world := PackedVector3Array(); var history := PackedFloat64Array()
	var q: Vector2 = bake.field_origin + bake.field_extent * Vector2(0.35, 0.46)
	for i in 4:
		var x: float = q.x + (i % 2) * 1.2; var z: float = q.y + (i / 2) * 3.1
		material.append(Vector3(x, 0, z))
		var row: PackedFloat64Array = native.call("sample_dynamic_material_q", x, z)
		world.append(Vector3(x + row[2], 0, z + row[4]))
		var contact: PackedFloat64Array = native.call("sample_dynamic_contact", world[i].x, world[i].z, PackedFloat64Array())
		if contact[0] < 0.5: _fail("cost benchmark initial contact"); return
		history.append_array(contact)
	for _i in 100:
		native.call("sample_dynamic_material_q_batch", material)
		history = native.call("sample_dynamic_contact_batch", world, history)
	var material_ms: Array = []; var contact_ms: Array = []; var producer_ms: Array = []
	for _i in 2000:
		var started := Time.get_ticks_usec()
		native.call("sample_dynamic_material_q_batch", material)
		material_ms.append((Time.get_ticks_usec() - started) / 1000.0)
		started = Time.get_ticks_usec()
		history = native.call("sample_dynamic_contact_batch", world, history)
		contact_ms.append((Time.get_ticks_usec() - started) / 1000.0)
	for i in 200:
		var started := Time.get_ticks_usec()
		if not native.call("build_dynamic_physics_fields", 2.25 + i * DT): _fail("cost producer build"); return
		producer_ms.append((Time.get_ticks_usec() - started) / 1000.0)
	var report := {"build_id": expected, "material_q": str(material), "wave_time": 2.25, "workers": 4,
		"material_N4_ms": _metrics(material_ms), "contact_N4_ms": _metrics(contact_ms),
		"synchronous_producer_ms": _metrics(producer_ms), "transform_count": 18}
	var file := FileAccess.open("res://.godot/phys_coastal_coverage_cost_%s.json" % label, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t")); file.close()
	print("COVERAGE_COST_COMPLETE=" + JSON.stringify(report))
	native.call("clear"); quit(0)
