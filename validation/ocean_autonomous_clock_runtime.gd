extends SceneTree
## Ocean without any physics consumer, then 12 contexts sharing CPU Lite.
## --result=<absolute JSON path>. Run with a real Forward+ renderer.
var result_path := ""
var failures: Array[String] = []
var rows: Array[Dictionary] = []
var world: Node3D
var ocean: Ocean
var water: CpuFftWaterProvider
var fft: Node
var contexts: Array = []
var points := PackedVector3Array([Vector3(-0.4, 0, -1), Vector3(0.4, 0, -1), Vector3(-0.4, 0, 1), Vector3(0.4, 0, 1)])
var tick_index := 0
var previous_time := 0.0
var previous_visual := 0.0
var visual_changes := 0
var standalone_delta := 0.0
var provider_created_during_standalone := false
var valid_samples := 0
var max_builds_per_tick := 0
var recording := false

class TickProbe extends Node:
	var test: SceneTree
	func _physics_process(delta: float) -> void:
		test.inspect_tick(delta)

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--result="):
			result_path = arg.trim_prefix("--result=")
	start.call_deferred()

func check(ok: bool, label: String) -> void:
	if not ok and not failures.has(label):
		failures.append(label)
		push_error(label)

func start() -> void:
	world = Node3D.new()
	root.add_child(world)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 6, 10)
	camera.look_at(Vector3.ZERO)
	camera.current = true
	var sun := DirectionalLight3D.new()
	world.add_child(sun)
	sun.rotation_degrees = Vector3(-45, -30, 0)
	ocean = load("res://addons/ocean/ocean.tscn").instantiate()
	world.add_child(ocean)
	fft = ocean.get_node("OpenOceanFFT")
	for frame in 30:
		await process_frame
	check(fft.is_surface_initialized(), "FFT surface initialized")
	previous_time = ocean.get_wave_time()
	previous_visual = fft.get_visual_wave_time()
	var probe := TickProbe.new()
	probe.test = self
	probe.process_physics_priority = 100
	world.add_child(probe)
	recording = true

func _process(_delta: float) -> bool:
	if recording and is_instance_valid(fft):
		var visual: float = fft.get_visual_wave_time()
		if visual > previous_visual:
			visual_changes += 1
		previous_visual = visual
	return false

func inspect_tick(delta: float) -> void:
	if not recording:
		return
	tick_index += 1
	var before_contacts: float = ocean.get_wave_time()
	var expected := delta
	if tick_index > 90 and tick_index <= 105:
		expected = 0.0
	elif tick_index > 105 and tick_index <= 120:
		expected = 0.0
	elif tick_index > 120 and tick_index <= 135:
		expected = delta * 1.5
	check(absf(before_contacts - previous_time - expected) < 1e-9,
		"clock advances exactly once with no consumers, consumers, disabled state and speed changes")
	if tick_index <= 45:
		standalone_delta += before_contacts - previous_time
		provider_created_during_standalone = provider_created_during_standalone or is_instance_valid(ocean.get("_cpu_water_provider"))
	if tick_index == 45:
		check(standalone_delta > 0.5, "standalone Ocean clock advances without Jet Ski")
		check(not provider_created_during_standalone, "standalone rendering does not build a CPU provider")
		water = ocean.get_water_provider()
		check(water.configure(ocean, 1, false), "CPU Lite configuration")
		water.set_water_race_mode(true)
		for consumer in 12:
			contexts.append(water.create_consumer_context())
	if tick_index > 45 and tick_index <= 90:
		var builds_before: int = water.field_update_count
		for consumer in 12:
			water.select_consumer(contexts[consumer])
			var pose := Transform3D(Basis.IDENTITY, Vector3(consumer * 10, 0, -tick_index * 0.1))
			water.prepare_water_queries(pose, points, PackedVector3Array(), delta)
			var samples := water.sample_surface_batch(PackedVector3Array([pose.origin]))
			check(samples.size() == 1 and samples[0].valid, "valid samples for every consumer")
			if samples.size() == 1 and samples[0].valid:
				valid_samples += 1
		var builds: int = water.field_update_count - builds_before
		max_builds_per_tick = maxi(max_builds_per_tick, builds)
		check(builds == 1, "one shared CPU build for twelve consumers per tick")
		check(ocean.get_wave_time() == before_contacts, "consumer preparation does not advance clock twice")
	rows.append({"tick": tick_index, "physics_tick": Engine.get_physics_frames(), "wave_time": before_contacts})
	previous_time = ocean.get_wave_time()
	if tick_index == 90:
		fft.set_enabled(false)
	elif tick_index == 105:
		fft.set_wave_speed_multiplier(0.0)
		fft.set_enabled(true)
	elif tick_index == 120:
		fft.set_wave_speed_multiplier(1.5)
	elif tick_index == 135:
		check(visual_changes > 10, "visual wave time advances")
		check(water.field_update_failures == 0, "no native FFT failures")
		recording = false
		finish.call_deferred()

func finish() -> void:
	var report := {"failures": failures, "standalone_delta_s": standalone_delta,
		"standalone_created_cpu_provider": provider_created_during_standalone,
		"valid_samples": valid_samples, "max_shared_builds_per_tick": max_builds_per_tick,
		"visual_clock_changes": visual_changes, "rows": rows}
	var file := FileAccess.open(result_path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	else:
		check(false, "report output writable")
	print("OCEAN_AUTONOMOUS_CLOCK failures=%d standalone_seconds=%.6f samples=%d max_builds=%d" % [failures.size(), standalone_delta, valid_samples, max_builds_per_tick])
	world.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
