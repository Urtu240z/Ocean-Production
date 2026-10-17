extends SceneTree
## E1 native replay. Generate with the production Windows scene, replay headless
## against the installed Linux extension. No changes to provider or FFT settings.
var options := {}
var failures: Array[String] = []
var report := {}

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--") and arg.contains("="):
			options[arg.get_slice("=", 0).trim_prefix("--")] = arg.substr(arg.find("=") + 1)
	run.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok and not failures.has(label):
		failures.append(label)
		push_error("E1_NATIVE: " + label)

func exercise(data: Dictionary) -> Array:
	var native: Object = ClassDB.instantiate("OceanQueryNative")
	check(native != null, "native instantiated")
	if native == null: return []
	native.call("perf1_set_enabled", false)
	native.call("set_gameplay_min_wavelength_m", data.minimum_wavelength)
	native.call("set_sea_level", data.sea_level)
	check(bool(native.call("set_production_spectrum", data.snapshots)), "production spectrum imported")
	var points: PackedVector3Array = data.points
	var warm := PackedVector3Array()
	var previous := PackedVector2Array()
	warm.resize(points.size())
	previous.resize(points.size())
	for i in points.size():
		warm[i] = Vector3(NAN, NAN, NAN)
		previous[i] = Vector2(NAN, NAN)
	var rows: Array = []
	for time in data.times:
		check(bool(native.call("build_dynamic_physics_lite", time, PackedInt32Array([128, 128, 128]))), "CPU Lite build")
		var contacts: PackedFloat64Array = native.call("sample_dynamic_lite_contacts", points, data.sea_level, PackedInt32Array([1, 1, 1]))
		var tracked: PackedFloat64Array = native.call("sample_dynamic_lite_contact_queries", points,
			PackedInt32Array([1, 1, 1]), data.weights, warm, previous, data.camera_xz, data.scales, data.fade_ranges)
		check(contacts.size() == 1 + points.size() * 6, "height normal velocity batch shape")
		check(tracked.size() == 1 + points.size() * 16, "tracked batch shape")
		if contacts.size() != 1 + points.size() * 6 or tracked.size() != 1 + points.size() * 16: break
		# Entry zero is elapsed microseconds, never part of numerical comparisons.
		rows.append([contacts.slice(1), tracked.slice(1)])
		for i in points.size():
			var offset := 1 + i * 16
			if tracked[offset] > 0.5:
				warm[i] = Vector3(tracked[offset + 5], points[i].y, tracked[offset + 6])
				previous[i] = Vector2(points[i].x, points[i].z)
	var profile: Dictionary = native.call("get_dynamic_lite_profile")
	check(bool(profile.get("valid", false)), "final field validity")
	check(profile.get("resolutions") == PackedInt64Array([128, 128, 128]), "production resolutions")
	report["cpu_supports_avx2_fma"] = native.call("get_cpu_supports_avx2")
	report["final_simulation_time"] = profile.get("simulation_time")
	return rows

func compare(a: Array, b: Array, tolerance: float) -> Dictionary:
	var maximum := 0.0
	var mismatches := 0
	var discrete_mismatches := 0
	var compared := 0
	check(a.size() == b.size(), "replay length")
	for tick in mini(a.size(), b.size()):
		for batch in 2:
			var left: PackedFloat64Array = a[tick][batch]
			var right: PackedFloat64Array = b[tick][batch]
			check(left.size() == right.size(), "replay batch length")
			var stride := 6 if batch == 0 else 16
			for value in mini(left.size(), right.size()):
				var x: float = left[value]
				var y: float = right[value]
				if is_nan(x) and is_nan(y): continue
				if not is_finite(x) or not is_finite(y):
					if x != y: mismatches += 1
					continue
				var error := absf(x - y)
				maximum = maxf(maximum, error)
				if error > tolerance: mismatches += 1
				var column := value % stride
				# Tracked columns 3/4 are direct/solved heights, not flags.
				if (column == 0 or (batch == 1 and column in [12, 13, 14, 15])) and x != y:
					discrete_mismatches += 1
				compared += 1
	return {"values": compared, "maximum_absolute_error": maximum, "outside_tolerance": mismatches,
		"discrete_mismatches": discrete_mismatches, "tolerance": tolerance}

func run() -> void:
	report["os"] = OS.get_name()
	report["engine"] = Engine.get_version_info()
	if not ClassDB.class_exists("OceanQueryNative"):
		report["descriptor_load_status"] = GDExtensionManager.load_extension("res://addons/ocean/physics/native/ocean_query/ocean_query_native.gdextension")
	check(ClassDB.class_exists("OceanQueryNative"), "extension registered")
	if not ClassDB.class_exists("OceanQueryNative"):
		finish()
		return
	var data: Dictionary
	if str(options.get("generate", "false")) == "true":
		var world: Node = load("res://gameplay/jet_ski_ocean.tscn").instantiate()
		root.add_child(world)
		for frame in 600:
			await process_frame
			if bool(world.get("ready_to_drive")): break
		check(bool(world.get("ready_to_drive")), "production world readiness")
		if not bool(world.get("ready_to_drive")):
			finish()
			return
		world.get("ski").freeze = true
		var water: Object = world.get("water")
		var fft: Node = world.get_node("Production/Ocean/OpenOceanFFT")
		var contract: Dictionary = water.call("get_surface_query_contract")
		data = {"snapshots": fft.call("get_phys2_band_spectrum_snapshots"),
			"minimum_wavelength": water.get("physics_min_wavelength_m"), "sea_level": water.get("sea_level"),
			"weights": water.get("physical_band_weights"), "camera_xz": contract.get("camera_world_xz", Vector2.ZERO),
			"scales": Vector2(float(contract.get("clipmap_geometry_scale", 1.0)), float(contract.get("ocean_surface_scale", 1.0))),
			"fade_ranges": contract.get("fade_ranges", PackedVector2Array())}
		var points := PackedVector3Array()
		for i in 24: points.append(Vector3(-12.0 + i * 1.1, 0.3, 42.0 + (i % 5) * 3.2))
		var times := PackedFloat64Array()
		for tick in 645:
			var time := 1.25 + tick / 60.0
			if tick >= 620: time += 0.4
			if tick >= 635: time -= 0.7
			times.append(time)
		data["points"] = points
		data["times"] = times
		data["reference"] = exercise(data)
		var file := FileAccess.open(str(options.fixture), FileAccess.WRITE)
		check(file != null, "fixture writable")
		if file != null:
			file.store_var(data)
			file.close()
		world.queue_free()
		await process_frame
	else:
		var file := FileAccess.open(str(options.fixture), FileAccess.READ)
		check(file != null, "fixture readable")
		if file == null:
			finish()
			return
		data = file.get_var()
		file.close()
	var first := exercise(data)
	var second := exercise(data)
	report["windows_reference"] = compare(data.reference, first, 1.0e-8)
	report["repeat_determinism"] = compare(first, second, 0.0)
	report["builds_per_replay"] = data.times.size()
	report["points_per_batch"] = data.points.size()
	check(int(report.windows_reference.outside_tolerance) == 0 and int(report.windows_reference.discrete_mismatches) == 0, "Windows numerical equivalence")
	check(int(report.repeat_determinism.outside_tolerance) == 0 and int(report.repeat_determinism.discrete_mismatches) == 0, "repeat determinism exact")
	finish()

func finish() -> void:
	report["failures"] = failures
	report["passed"] = failures.is_empty()
	var file := FileAccess.open(str(options.get("result", "user://e1_native.json")), FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report, "\t"))
	print("E1_NATIVE passed=", failures.is_empty())
	quit(0 if failures.is_empty() else 1)
