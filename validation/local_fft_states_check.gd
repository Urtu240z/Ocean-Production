extends SceneTree
const AreaScene = preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
var failures: Array[String] = []
var map_ready := false
func _initialize() -> void:
	Engine.max_fps=120
	call_deferred("run")
func check(ok: bool,label: String) -> void:
	if not ok: failures.append(label); push_error(label)
func frames(count: int) -> void:
	for i in count: await process_frame
func run() -> void:
	root.size=Vector2i(320,240)
	var world:=Node3D.new()
	root.add_child(world)
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.position=Vector3(0,12,25)
	camera.look_at(Vector3.ZERO)
	camera.current=true
	var ocean: Node3D=load("res://addons/ocean/ocean.tscn").instantiate()
	for property in ["coastal","reflections","surface_detail","enable_spindrift","underwater_bubbles","underwater_sunrays"]: ocean.set(property,false)
	ocean.set("underwater_medium",true)
	ocean.set("sea_level",0.0)
	ocean.set("visual_water_profile",1)
	ocean.set("wave_speed_multiplier",0.0)
	ocean.local_sea_state_1.sea_state_mode=1
	ocean.local_sea_state_1.significant_wave_height_m=0.0
	ocean.local_sea_state_1.wave_speed_multiplier=0.0
	ocean.local_sea_state_2.sea_state_mode=1
	ocean.local_sea_state_2.significant_wave_height_m=0.7
	ocean.local_sea_state_2.wave_speed_multiplier=0.0
	var areas: Array=[]
	for i in 3:
		var area=AreaScene.instantiate()
		area.ocean=ocean
		area.name="LocalArea%d"%i
		area.sea_state=1 if i==1 else 0
		area.position.x=i*400
		area.blend_distance_m=100
		world.add_child(area)
		areas.append(area)
	world.add_child(ocean)
	var ready:=false
	for i in 2400:
		await process_frame
		var state=ocean.get_wave_area_runtime()
		if ocean.get_physics_source_state().get("status","")=="OK" and state.states[0]!=null and state.states[1]!=null and state.states[0].ready and state.states[1].ready:
			ready=true; break
	check(ready,"three FFT seas publish")
	if not ready: quit(1); return
	var runtime=ocean.get_wave_area_runtime()
	check(runtime.states.size()==2 and runtime.entries.size()==3,"three areas share only two extra FFTs")
	check(runtime.pack_gpu().size()==1152,"underwater ABI")
	check(runtime.weight(runtime.entries[0],Vector3.ZERO)==1.0,"full core with 100m feather")
	check(runtime.weight(runtime.entries[0],Vector3(75,999,0))==1.0,"footprint boundary stays full strength independent of height")
	check(absf(runtime.weight(runtime.entries[0],Vector3(125,0,0))-0.5)<0.0001,"feather halfway outside")
	check(runtime.weight(runtime.entries[0],Vector3(175,0,0))==0.0,"exterior unchanged")
	var bank: RefCounted=runtime.states[1]
	var builds: int=bank.build_count
	for i in 10: ocean.get_wave_area_runtime()
	check(bank.build_count==builds,"unchanged settings reuse spectra")
	var provider: Node=ocean.get_water_provider()
	check(provider.configure(ocean),"real CPU provider configures")
	provider.begin_contacts(Transform3D.IDENTITY,PackedVector3Array([Vector3.ZERO]))
	var calm=provider.sample_water(Vector3.ZERO)
	check(calm.valid and absf(calm.surface_position.y)<0.0001,"calm FFT reaches real contacts")
	var points:=PackedVector3Array([Vector3(400,0,0),Vector3(401.3,0,2.7),Vector3(406,0,-3),Vector3(390,0,8)])
	var samples: PackedVector4Array=bank.sample(points,runtime.time_s,false)
	check(samples.size()==points.size(),"native local FFT field samples")
	# Render a four-pixel data probe instead of reading non-readable solver RIDs.
	var viewport:=SubViewport.new()
	viewport.size=Vector2i(4,1)
	viewport.disable_3d=true
	viewport.render_target_update_mode=SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var rectangle:=ColorRect.new()
	rectangle.size=Vector2(4,1)
	viewport.add_child(rectangle)
	var probe:=ShaderMaterial.new()
	probe.shader=Shader.new()
	probe.shader.code="""shader_type canvas_item;
uniform sampler2D a:filter_linear,repeat_enable; uniform sampler2D b:filter_linear,repeat_enable; uniform sampler2D c:filter_linear,repeat_enable;
uniform vec2 points[4]; uniform vec3 domains;
void fragment(){ vec2 p=points[min(int(UV.x*4.0),3)]; float h=texture(a,p/domains.x+vec2(0.5)).g+texture(b,p/domains.y+vec2(0.5)).g+texture(c,p/domains.z+vec2(0.5)).g; float v=clamp(0.5+h/16.0,0.0,0.9999)*255.0; COLOR=vec4(floor(v)/255.0,fract(v),0.0,1.0); }
"""
	probe.set_shader_parameter("a",bank.textures[0])
	probe.set_shader_parameter("b",bank.textures[1])
	probe.set_shader_parameter("c",bank.textures[2])
	probe.set_shader_parameter("domains",Vector3(bank.configs[0].domain_size_m,bank.configs[1].domain_size_m,bank.configs[2].domain_size_m))
	var xz:=PackedVector2Array()
	for p in points: xz.append(Vector2(p.x,p.z))
	probe.set_shader_parameter("points",xz)
	rectangle.material=probe
	await frames(5)
	await RenderingServer.frame_post_draw
	var gpu_image:=viewport.get_texture().get_image()
	map_ready=gpu_image!=null
	check(map_ready,"real GPU FFT probe renders")
	var error:=0.0
	if map_ready:
		for i in points.size():
			var pixel:=gpu_image.get_pixel(i,0)
			var gpu: float=(pixel.r+pixel.g/255.0-0.5)*16.0
			error=maxf(error,absf(gpu-samples[i].x))
		check(error<0.015,"same H0 gives matching CPU/GPU local heights")
	viewport.queue_free()
	provider.begin_contacts(Transform3D(Basis.IDENTITY,Vector3(400,0,0)),PackedVector3Array([Vector3.ZERO]))
	var rough=provider.sample_water(Vector3(400,0,0))
	check(rough.valid and absf(rough.surface_position.y-samples[0].x)<0.0001,"selected second state reaches contacts")
	ocean.set_waterline_state_readback_enabled(true)
	camera.position=Vector3(0,-1,0)
	camera.rotation=Vector3.ZERO
	await frames(40)
	var waterline: Dictionary=ocean.get_waterline_state()
	check(waterline.get("valid",false) and absf(float(waterline.get("water_surface_y",999)))<0.001,"underwater sees calm local FFT")
	ocean.set("visual_water_profile",0)
	bank.settings.clipmap_geometry_scale=1.3
	bank.settings.ocean_scale=1.2
	camera.position=Vector3(400,-1,0)
	await frames(30)
	var choppy: PackedVector4Array=bank.sample(PackedVector3Array([Vector3(400,0,0)]),runtime.time_s,true)
	waterline=ocean.get_waterline_state()
	check(choppy.size()==1 and waterline.get("valid",false) and absf(float(waterline.get("water_surface_y",999))-choppy[0].x)<0.025,"full chop and independent Ocean Space match underwater sensor")
	# Restore baseline scales for the identical-settings spectrum comparison.
	bank.settings.clipmap_geometry_scale=1.0
	bank.settings.ocean_scale=1.0
	builds=bank.build_count
	# A state rebuild must replace its spectrum, not alter the exterior settings.
	bank.settings.wind_direction_degrees+=40.0
	ocean.get_wave_area_runtime()
	check(bank.build_count==builds+1,"state edits rebuild exactly its own spectrum")
	# Identical authoring must yield the exterior's actual production spectrum.
	for key in ["sea_state_mode","significant_wave_height_m","wave_height_scale","wind_speed_mps","wind_direction_degrees","swell","long_wave_spacing","mid_fill_amount","long_band_scale","mid_band_scale","short_band_scale"]:
		bank.settings.set(key,ocean.get(key))
	ocean.get_wave_area_runtime()
	var exterior: Array=ocean.get_node("OpenOceanFFT").get_phys2_band_spectrum_snapshots()
	var spectrum_error:=0.0
	var spectrum_peak:=0.0
	for band in 3:
		var a: PackedFloat32Array=exterior[band].h0_rgba32f.to_float32_array()
		var b: PackedFloat32Array=bank.spectrum.bands[band].h0_rgba32f.to_float32_array()
		check(a.size()==b.size(),"matching production lattice")
		for i in range(0,mini(a.size(),b.size()),17):
			spectrum_error=maxf(spectrum_error,absf(a[i]-b[i]))
			spectrum_peak=maxf(spectrum_peak,absf(a[i]))
	check(spectrum_error/maxf(spectrum_peak,0.000001)<0.00001,"identical settings reproduce exterior FFT H0")
	var phase: float=bank.time_s
	var stable_builds: int=bank.build_count
	bank.settings.wave_speed_multiplier=1.0
	await frames(12)
	check(bank.time_s>phase,"local clock runs independently while exterior is frozen")
	bank.settings.wave_speed_multiplier=0.0
	ocean.get_wave_area_runtime()
	phase=bank.time_s
	await frames(8)
	check(is_equal_approx(bank.time_s,phase) and bank.build_count==stable_builds,"speed freezes current phase without restarting/rebuilding FFT")
	areas[1].enabled=false
	ocean.get_wave_area_runtime()
	check(runtime.states[1]==null and runtime.states[0]!=null,"unused state releases all its solvers")
	print("LOCAL_FFT_RESULT failures=",failures," cpu_gpu_max_error_m=",error," h0_relative_error=",spectrum_error/maxf(spectrum_peak,0.000001)," cpu_field_us=",bank.cpu_build_us)
	world.queue_free()
	await frames(10)
	quit(0 if failures.is_empty() else 1)
