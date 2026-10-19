extends SceneTree
const BaseRuntime = preload("res://validation/fixtures/local_sea_base/wave_area_runtime.gd")
const BaseFFT = preload("res://validation/fixtures/local_sea_base/local_fft_state.gd")
const AreaScene = preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
var failures: Array = []
var maxima := {"HEIGHT":0.0,"NORMAL":0.0,"VY":0.0,"signed_depth":0.0}
signal rids_checked
var retained_rids := 0

func check_rids(rids: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	var count := 0
	for rid in rids:
		if rid.is_valid() and rd.texture_is_valid(rid): count += 1
	rids_result.call_deferred(count)

func rids_result(count: int) -> void:
	retained_rids = count
	rids_checked.emit()
func _initialize() -> void: call_deferred("run")
func check(ok: bool, label: String) -> void:
	if not ok: failures.append(label)
func samples(points: PackedVector3Array) -> Array:
	var result: Array = []
	for p in points:
		var sample := WaterSample3D.new()
		sample.valid = true
		sample.surface_position = Vector3(p.x,0.2*sin(p.x*0.1),p.z)
		sample.normal = Vector3(-0.02*cos(p.x*0.1),1,0).normalized()
		sample.velocity = Vector3(0,0.3,0)
		sample.signed_depth = sample.surface_position.y-p.y
		result.append(sample)
	return result
func run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var ocean: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	for property in ["coastal","reflections","enable_spindrift","underwater_bubbles","underwater_sunrays","underwater_medium"]:
		ocean.set(property,false)
	world.add_child(ocean)
	for i in 2:
		var area = AreaScene.instantiate()
		area.ocean = ocean
		area.sea_state = i
		area.position.x = i*80.0
		area.blend_distance_m = 30.0
		world.add_child(area)
	var runtime: RefCounted
	var ready := false
	for i in 1800:
		await process_frame
		runtime = ocean.get_wave_area_runtime()
		if runtime.states[0] != null and runtime.states[1] != null and runtime.states[0].ready and runtime.states[1].ready:
			ready = true
			break
	check(ready,"FFT ready")
	if not ready: print("LOCAL_SEA_EQ ",failures); quit(1); return
	var oracle := BaseRuntime.new()
	oracle.entries.assign(runtime.entries.duplicate(true))
	oracle.sea_level = runtime.sea_level
	for slot in 2:
		var state := BaseFFT.new()
		state.settings = runtime.states[slot].settings
		state.native = ClassDB.instantiate("OceanQueryNative")
		state.native.set_gameplay_min_wavelength_m(0.0)
		state.native.set_sea_level(0.0)
		check(state.native.set_production_spectrum(runtime.states[slot].spectrum.bands),"reference spectrum")
		oracle.states[slot] = state
	var compared := 0
	for displaced in [false,true]:
		for time in [0.0,0.17,1.0,4.71,18.0]:
			var points := PackedVector3Array()
			for x in [-106.0,-105.0,-104.9,-90.0,-75.1,-75.0,-74.9,0.0,50.0,75.0,80.0,105.0,130.0,155.0,185.0,300.0]:
				for z in [-80.1,-65.0,-50.0,0.0,50.0,65.0,80.1]:
					points.append(Vector3(x+time*0.3,0.6,z))
			for slot in 2:
				for state in [runtime.states[slot],oracle.states[slot]]:
					state.time_s = time
					state._last_clock = time
			runtime.time_s = time
			oracle.time_s = time
			runtime.displaced = displaced
			oracle.displaced = displaced
			var actual := samples(points)
			var reference := samples(points)
			runtime.apply(actual,points,1.0)
			oracle.apply(reference,points,1.0)
			for i in points.size():
				maxima.HEIGHT = maxf(maxima.HEIGHT,absf(actual[i].surface_position.y-reference[i].surface_position.y))
				maxima.NORMAL = maxf(maxima.NORMAL,actual[i].normal.distance_to(reference[i].normal))
				maxima.VY = maxf(maxima.VY,absf(actual[i].velocity.y-reference[i].velocity.y))
				maxima.signed_depth = maxf(maxima.signed_depth,absf(actual[i].signed_depth-reference[i].signed_depth))
				compared += 1
	for metric in maxima: check(maxima[metric] <= 0.00001,metric)
	if runtime.has_method("invalidate"):
		await lifecycle(ocean,runtime,world)
	print("LOCAL_SEA_EQ ",JSON.stringify({"compared":compared,"max_error":maxima,"failures":failures}))
	world.queue_free()
	for i in 10: await process_frame
	quit(0 if failures.is_empty() else 1)

func lifecycle(ocean: Node3D, runtime: RefCounted, world: Node3D) -> void:
	runtime.metrics.enabled = true
	runtime.metrics.clear()
	runtime.invalidate()
	for i in 100: ocean.get_wave_area_runtime()
	var tick: Dictionary = runtime.metrics.ticks.get(Engine.get_physics_frames(),{})
	check(tick.get(&"synchronize",Vector2i.ZERO).x == 1,"one synchronization per tick")
	var points := PackedVector3Array([Vector3.ZERO,Vector3(10000,0,0)])
	runtime.apply(samples(points),points,1.0)
	tick = runtime.metrics.ticks.get(Engine.get_physics_frames(),{})
	check(tick.get(&"slot0.sample_contacts",Vector2i.ZERO).x == 1,"only influenced contact queried")
	var areas := world.get_tree().get_nodes_in_group(&"ocean_wave_areas")
	areas[0].influence = 0.5
	ocean.get_wave_area_runtime()
	var changed := false
	for entry in runtime.entries: changed = changed or is_equal_approx(entry.meta.z,0.5)
	check(changed,"explicit property invalidation within tick")
	areas[1].sea_state = 0
	ocean.get_wave_area_runtime()
	check(runtime.states[1] == null,"slot change releases unused state")
	var saved: Resource = ocean.local_sea_state_1
	var generation: RefCounted = runtime.states[0].generation
	var textures: Array = runtime.states[0].textures.duplicate()
	ocean.local_sea_state_1 = null
	ocean.get_wave_area_runtime()
	check(runtime.states[0] == null,"null resource releases state")
	check(not generation.is_active(),"null resource retires generation")
	await process_frame
	await RenderingServer.frame_post_draw
	var rids: Array = []
	for texture in textures: rids.append(texture.texture_rd_rid)
	RenderingServer.call_on_render_thread(check_rids.bind(rids))
	await rids_checked
	check(retained_rids == 0,"retired GPU textures freed on render thread")
	ocean.local_sea_state_1 = saved
	for i in 1200:
		await process_frame
		ocean.get_wave_area_runtime()
		if runtime.states[0] != null and runtime.states[0].ready: break
	check(runtime.states[0] != null and runtime.states[0].ready,"resource restoration")
	if runtime.states[0] != null:
		var state: RefCounted = runtime.states[0]
		var previous_build: int = state.build_count
		saved.wind_speed_mps += 0.25
		await physics_frame
		await process_frame
		ocean.get_wave_area_runtime()
		check(state.build_count > previous_build,"hot sea state change detected")
