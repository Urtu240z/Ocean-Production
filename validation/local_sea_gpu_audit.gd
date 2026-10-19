extends SceneTree
## Isolated fragment kernel using actual local FFT textures and the production include.
var rows: Array = []
var timings: Array = []
var measuring := false
var viewport: SubViewport
signal flushed
func _initialize() -> void:
	Engine.max_fps = 0
	call_deferred("run")
func stats(values: Array) -> Dictionary:
	if values.is_empty(): return {"n":0}
	values.sort()
	return {"n":values.size(),"p50":values[int((values.size()-1)*0.5)],"p95":values[int((values.size()-1)*0.95)]}
func read_timer() -> void:
	var ms := RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
	store_timer.call_deferred(ms)
func store_timer(ms: float) -> void:
	if ms > 0: timings.append(ms)
func barrier() -> void: emit_barrier.call_deferred()
func emit_barrier() -> void: flushed.emit()
func frame() -> void:
	if measuring: RenderingServer.call_on_render_thread(read_timer)
func run() -> void:
	root.size = Vector2i(1280,720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var world := Node3D.new()
	root.add_child(world)
	var ocean: Node3D = load("res://addons/ocean/ocean.tscn").instantiate()
	for property in ["coastal","reflections","enable_spindrift","underwater_medium","underwater_bubbles","underwater_sunrays"]: ocean.set(property,false)
	world.add_child(ocean)
	var areas: Array = []
	for i in 2:
		var area = load("res://addons/ocean/areas/ocean_wave_area_3d.tscn").instantiate()
		area.ocean = ocean
		area.sea_state = i
		world.add_child(area)
		areas.append(area)
	var runtime: RefCounted
	for i in 1800:
		await process_frame
		runtime = ocean.get_wave_area_runtime()
		if runtime.states[0]!=null and runtime.states[1]!=null and runtime.states[0].ready and runtime.states[1].ready: break
	viewport = SubViewport.new()
	viewport.size = root.size
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(),true)
	var rect := ColorRect.new()
	rect.size = Vector2(viewport.size)
	viewport.add_child(rect)
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = kernel_source().replace("res://addons/ocean/areas/wave_area_surface.gdshaderinc",include_path())
	rect.material = material
	process_frame.connect(frame)
	for scenario in ["disabled","small_one","large_one","large_two_same","large_two_slots"]:
		areas[0].enabled = true
		areas[1].enabled = scenario.begins_with("large_two")
		areas[1].sea_state = 1 if scenario == "large_two_slots" else 0
		for area in areas: area.get_node("CollisionShape3D").shape.size = Vector3(10,60,10) if scenario == "small_one" else Vector3(200,60,120)
		for i in 120: await process_frame
		runtime = ocean.get_wave_area_runtime()
		for key in runtime.shader_parameters():
			if str(key).begins_with("wave_area_") or str(key).begins_with("local_fft_"): material.set_shader_parameter(key,runtime.shader_parameters()[key])
		material.set_shader_parameter("compose_enabled",scenario!="disabled")
		for i in 120: await process_frame
		timings.clear()
		measuring = true
		for i in 360: await process_frame
		measuring = false
		RenderingServer.call_on_render_thread(barrier)
		await flushed
		var row := {"scenario":scenario,"fragment_kernel_gpu_ms":stats(timings)}
		rows.append(row)
		print("LOCAL_SEA_GPU ",JSON.stringify(row))
	DirAccess.make_dir_recursive_absolute("res://temp/local_sea_audit")
	var phase := "phase1"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="): phase=arg.trim_prefix("--phase=")
	var file := FileAccess.open("res://temp/local_sea_audit/"+phase+"_gpu.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"resolution":[1280,720],"notes":"Isolated compose fragment kernel, includes canvas pass overhead; disabled case is its control. Actual local FFT textures, no physics queries.","cases":rows},"\t"))
	file.close()
	world.queue_free()
	viewport.queue_free()
	for i in 10: await process_frame
	quit()

func include_path() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg == "--reference": return "res://validation/fixtures/local_sea_base/wave_area_surface.gdshaderinc"
	return "res://addons/ocean/areas/wave_area_surface.gdshaderinc"

func kernel_source() -> String:
	return """shader_type canvas_item;
uniform vec2 camera_world_xz = vec2(0.0);
uniform vec2 long_fade_range_m = vec2(1800.0,2200.0);
uniform vec2 mid_fade_range_m = vec2(350.0,600.0);
uniform vec2 short_fade_range_m = vec2(70.0,160.0);
uniform vec3 visual_horizontal_displacement_scale = vec3(1.0);
uniform bool compose_enabled = true;
float fade_weight(float d,vec2 range_m){return 1.0-smoothstep(range_m.x,range_m.y,d);}
#include "res://addons/ocean/areas/wave_area_surface.gdshaderinc"
void fragment(){
 vec3 p=vec3((UV.x-0.5)*200.0,0.0,(UV.y-0.5)*120.0);
 vec4 v=vec4(0.2,0.1,0.15,0.0);
 if(compose_enabled){v=wave_areas_compose(p,v);}
 COLOR=vec4(v.xyz*0.05+vec3(0.5),1.0);
}
"""
