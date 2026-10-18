extends SceneTree
const AreaScene = preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
var rows: Array[Dictionary] = []
func _initialize() -> void:
	Engine.max_fps=120
	call_deferred("run")
func stats(values: Array[float]) -> Dictionary:
	if values.is_empty(): return {}
	values.sort()
	return {"median_ms":values[values.size()/2]/1000.0,"p95_ms":values[int(values.size()*0.95)]/1000.0,"count":values.size()}
func run() -> void:
	root.size=Vector2i(320,240)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var world:=Node3D.new()
	root.add_child(world)
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.position=Vector3(0,12,25)
	camera.look_at(Vector3.ZERO)
	camera.current=true
	var ocean: Node3D=load("res://addons/ocean/ocean.tscn").instantiate()
	for property in ["coastal","reflections","surface_detail","enable_spindrift","underwater_bubbles","underwater_sunrays","underwater_medium"]: ocean.set(property,false)
	var areas: Array=[]
	for i in 2:
		var area=AreaScene.instantiate()
		area.ocean=ocean
		area.sea_state=i
		area.position.x=i*400
		area.enabled=false
		world.add_child(area)
		areas.append(area)
	world.add_child(ocean)
	for i in 120: await process_frame
	var runtime=ocean.get_wave_area_runtime()
	runtime.profiling_enabled=true
	for active in 3:
		for i in 2: areas[i].enabled=i<active
		for i in 100: await process_frame
		var cpu: Array[float]=[]
		var gpu: Array[float]=[]
		var frame: Array[float]=[]
		var previous:=Time.get_ticks_usec()
		for i in 100:
			await physics_frame
			await process_frame
			runtime=ocean.get_wave_area_runtime()
			var cpu_sum:=0.0
			var gpu_sum:=0.0
			for slot in active:
				var state: RefCounted=runtime.states[slot]
				if state==null: continue
				state.sample(PackedVector3Array([Vector3(slot*400,0,0)]),runtime.time_s,false)
				cpu_sum+=state.cpu_build_us
				state._mutex.lock()
				gpu_sum+=state.gpu_us
				state._mutex.unlock()
			if active>0:
				cpu.append(cpu_sum)
				if gpu_sum>0: gpu.append(gpu_sum)
			var now:=Time.get_ticks_usec()
			frame.append(now-previous)
			previous=now
		rows.append({"total_seas":active+1,"extra_fft_gpu":stats(gpu),"extra_cpu_fields":stats(cpu),"test_loop_wall":stats(frame)})
	DirAccess.make_dir_recursive_absolute("res://temp/wave_areas")
	var file:=FileAccess.open("res://temp/wave_areas/local_fft_performance.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"driver":"D3D12","test_resolution":"320x240","notes":"FFT-only GPU timestamp sum; CPU field builds with contacts in every active state. Wall loop includes 60 Hz physics wait; not a game FPS benchmark.","results":rows},"\t"))
	file.close()
	print("LOCAL_FFT_PERFORMANCE ",JSON.stringify(rows))
	world.queue_free()
	for i in 10: await process_frame
	quit()
