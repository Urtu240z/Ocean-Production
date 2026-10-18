extends SceneTree
## Fixed-input GPU test of the actual projected foam fragment. The test plane
## is an isolated material fixture, not an additional gameplay effect mesh.
const Style:=preload("res://addons/ocean/surface/foam2d/foam2d_style.gd")
const OUTPUT:="res://temp/foam_relief/material"
var material: ShaderMaterial

func _initialize() -> void:
	run.call_deferred()

func capture() -> Image:
	for frame in 8: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func difference(a: Image, b: Image) -> Dictionary:
	assert(a.get_size()==b.get_size())
	a.convert(Image.FORMAT_RGB8)
	b.convert(Image.FORMAT_RGB8)
	var av:=a.get_data()
	var bv:=b.get_data()
	var total:=0.0
	var maximum:=0
	var changed:=0
	for i in av.size():
		var d:=absi(int(av[i])-int(bv[i]))
		total+=d
		maximum=maxi(maximum,d)
		if d>0: changed+=1
	return {"mean":total/(av.size()*255.0),"max_byte":maximum,"changed_channels":changed}

func compare(name: String) -> Dictionary:
	material.set_shader_parameter("foam2d_relief_enabled",false)
	var off: Image=await capture()
	material.set_shader_parameter("foam2d_relief_enabled",true)
	var on: Image=await capture()
	if name in ["white","normals","white_tint"]:
		off.save_png(OUTPUT+"/"+name+"_off.png")
		on.save_png(OUTPUT+"/"+name+"_on.png")
	return difference(off,on)

func run() -> void:
	root.size=Vector2i(960,640)
	DirAccess.make_dir_recursive_absolute(OUTPUT)
	var world:=Node3D.new()
	root.add_child(world)
	var environment:=WorldEnvironment.new()
	environment.environment=Environment.new()
	environment.environment.background_mode=Environment.BG_COLOR
	environment.environment.background_color=Color(0.05,0.12,0.18)
	environment.environment.ambient_light_source=Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color=Color(0.8,0.9,1.0)
	environment.environment.ambient_light_energy=0.5
	world.add_child(environment)
	var sun:=DirectionalLight3D.new()
	sun.rotation_degrees=Vector3(-28,-40,0)
	sun.light_energy=1.4
	world.add_child(sun)
	var camera:=Camera3D.new()
	world.add_child(camera)
	camera.position=Vector3(0,3.4,5.2)
	camera.look_at(Vector3.ZERO)
	camera.make_current()
	var source: String="""shader_type spatial;
render_mode cull_disabled;
varying vec3 ocean_world_position;
uniform sampler2D interaction_foam_texture: filter_linear,repeat_disable;
uniform sampler2D crest_breakup_texture: filter_linear_mipmap,repeat_enable;
uniform vec2 interaction_foam_origin_xz=vec2(-12.0);
uniform float interaction_foam_domain_m=24.0;
uniform float surface_air_blend=1.0;
uniform float underwater_camera_signed_distance_m=1.0;
uniform bool hull_waves_enabled=false;
uniform int hull_waves_debug=0;
uniform float hull_waves_max_height=2.0;
uniform vec2 camera_world_xz=vec2(0.0);
uniform int test_output=0;
vec3 hull_wave_sample(vec2 p) { return vec3(0.0); }
"""
	source+=FileAccess.get_file_as_string("res://addons/ocean/surface/foam2d/contact_projection.gdshaderinc")
	source+="\nvoid vertex() { ocean_world_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }\nvoid fragment() {\nALBEDO=vec3(0.025,0.12,0.18); ROUGHNESS=0.3; SPECULAR=0.75;\n"
	source+=FileAccess.get_file_as_string("res://addons/ocean/surface/foam2d/projected_fragment.inc")
	source+="\nif(test_output==1){ ALBEDO=vec3(0.0); EMISSION=NORMAL*0.5+0.5; SPECULAR=0.0; ROUGHNESS=1.0; }\n}\n"
	material=ShaderMaterial.new()
	material.shader=Shader.new()
	material.shader.code=source
	var style:=Style.new()
	style.opacity=1.3
	style.white_strength=1.2
	style.low_speed_white_strength=1.0
	style.high_speed_white_strength=1.0
	style.variation=1.0
	style.running_enabled=false
	style.roughness=0.3
	style.specular=1.0
	for key in style.shader_parameters(): material.set_shader_parameter(key,style.shader_parameters()[key])
	material.set_shader_parameter("foam2d_wake_enabled",true)
	material.set_shader_parameter("foam2d_time",4.25)
	var history:=Image.create(128,128,false,Image.FORMAT_RGBAF)
	for y in 128:
		for x in 128:
			var p: Vector2=(Vector2(x,y)+Vector2.ONE*0.5)/128.0*24.0-Vector2.ONE*12.0
			var coverage: float=(1.0-smoothstep(2.5,3.5,absf(p.x)))*(1.0-smoothstep(4.0,5.0,absf(p.y)))
			history.set_pixel(x,y,Color(coverage,0,0,coverage))
	material.set_shader_parameter("interaction_foam_texture",ImageTexture.create_from_image(history))
	material.set_shader_parameter("foam2d_speed_texture",ImageTexture.create_from_image(history))
	var noise: Texture2D=load("res://addons/ocean/surface/crest_breakup_noise.tres")
	for frame in 600:
		await process_frame
		if noise.get_image()!=null and not noise.get_image().is_empty(): break
	material.set_shader_parameter("crest_breakup_texture",noise)
	var mesh:=MeshInstance3D.new()
	var plane:=PlaneMesh.new()
	plane.size=Vector2(24,24)
	mesh.mesh=plane
	mesh.material_override=material
	world.add_child(mesh)
	var white: Dictionary=await compare("white")
	assert(white.changed_channels>2000 and white.mean>0.002,"White relief is not visible")
	material.set_shader_parameter("test_output",1)
	var normals: Dictionary=await compare("normals")
	assert(normals.changed_channels>1000 and normals.mean>0.001,"White normals do not contain relief")
	material.set_shader_parameter("test_output",0)
	material.set_shader_parameter("foam2d_white_strength",0.0)
	var calm: Dictionary=await compare("calm_blue")
	assert(calm.max_byte==0,"Relief altered the calm blue foam/water")
	material.set_shader_parameter("foam2d_water_tint",Color.WHITE)
	material.set_shader_parameter("foam2d_tint_strength",1.0)
	var white_tint: Dictionary=await compare("white_tint")
	assert(white_tint.changed_channels>2000 and white_tint.mean>0.001,"White tint bypassed relief controls")
	material.set_shader_parameter("foam2d_speed_white_strength",Vector2(0.3,1.0))
	var white_tint_low: Image=await capture()
	material.set_shader_parameter("foam2d_speed_white_strength",Vector2.ONE)
	var white_tint_full: Image=await capture()
	assert(difference(white_tint_low,white_tint_full).mean>0.002,"White tint bypassed speed whitening")
	material.set_shader_parameter("foam2d_water_tint",style.water_tint)
	material.set_shader_parameter("foam2d_tint_strength",style.tint_strength)
	material.set_shader_parameter("foam2d_white_strength",1.2)
	material.set_shader_parameter("underwater_camera_signed_distance_m",-0.2)
	var underwater: Dictionary=await compare("underwater")
	assert(underwater.max_byte==0,"Relief leaked below the water surface")
	material.set_shader_parameter("underwater_camera_signed_distance_m",1.0)
	material.set_shader_parameter("foam2d_debug",1)
	material.set_shader_parameter("foam2d_speed_white_strength",Vector2(0.3,1.0))
	var speed_means: Array[float]=[]
	for speed in [0.0,5.0/3.6,20.0/3.6,35.0/3.6,60.0/3.6]:
		var speed_image:=Image.create(128,128,false,Image.FORMAT_RF)
		for y in 128:
			for x in 128: speed_image.set_pixel(x,y,Color(history.get_pixel(x,y).r*speed,0,0))
		material.set_shader_parameter("foam2d_speed_texture",ImageTexture.create_from_image(speed_image))
		var shot: Image=await capture()
		shot.convert(Image.FORMAT_RGB8)
		var sum:=0.0
		for channel in shot.get_data(): sum+=channel
		speed_means.append(sum/shot.get_data().size())
	assert(absf(speed_means[0]-speed_means[1])<0.05,"Low speed plateau changed")
	assert(speed_means[2]>speed_means[1]*1.1 and speed_means[3]>speed_means[2]*1.05,"Speed whitening did not grow smoothly")
	assert(absf(speed_means[3]-speed_means[4])<0.05,"High speed plateau changed")
	material.set_shader_parameter("foam2d_debug",4)
	material.set_shader_parameter("foam2d_patch_size",0.85)
	material.set_shader_parameter("foam2d_transport_detail",false)
	material.set_shader_parameter("foam2d_filament_deformation",0.8)
	material.set_shader_parameter("foam2d_filament_speed",3.0)
	material.set_shader_parameter("foam2d_time",0.0)
	var animation_first: Image=await capture()
	material.set_shader_parameter("foam2d_time",1.0/60.0)
	var animation_next: Image=await capture()
	material.set_shader_parameter("foam2d_time",0.5)
	var animation_later: Image=await capture()
	var animation_short:=difference(animation_first,animation_next)
	var animation_long:=difference(animation_first,animation_later)
	assert(animation_short.mean<0.12 and animation_long.changed_channels>2000,"Filament animation snapped or failed to evolve")
	animation_first.save_png(OUTPUT+"/patch085_t0.png")
	animation_later.save_png(OUTPUT+"/patch085_t05.png")
	material.set_shader_parameter("foam2d_filament_speed",0.0)
	var stopped_first: Image=await capture()
	material.set_shader_parameter("foam2d_time",4.0)
	var stopped_last: Image=await capture()
	assert(difference(stopped_first,stopped_last).max_byte==0,"Zero filament speed did not stop internal deformation")
	# Fresh stern pigment fills filament holes at speed and settles back to the
	# exact configured older wake. Motion/deformation stay disabled throughout.
	material.set_shader_parameter("foam2d_debug",1)
	material.set_shader_parameter("foam2d_filament_deformation",0.0)
	material.set_shader_parameter("foam2d_white_strength",0.3)
	material.set_shader_parameter("foam2d_fresh_wake_settling_s",0.8)
	var fresh_shots: Array[Image]=[]
	var fresh_means: Array[float]=[]
	for age in [0.0,0.4,0.8]:
		var metadata:=Image.create(128,128,false,Image.FORMAT_RGBAF)
		for y in 128:
			for x in 128:
				var coverage:=history.get_pixel(x,y).r
				metadata.set_pixel(x,y,Color(coverage*15.0,coverage*exp(-age),0,0))
		material.set_shader_parameter("foam2d_speed_texture",ImageTexture.create_from_image(metadata))
		material.set_shader_parameter("foam2d_fresh_wake_enabled",true)
		var shot: Image=await capture()
		shot.convert(Image.FORMAT_RGB8)
		var sum:=0.0
		for channel in shot.get_data(): sum+=channel
		fresh_means.append(sum/shot.get_data().size())
		fresh_shots.append(shot)
		shot.save_png(OUTPUT+"/fresh_age_"+str(age)+".png")
	material.set_shader_parameter("foam2d_fresh_wake_enabled",false)
	var old_wake: Image=await capture()
	assert(fresh_means[0]>fresh_means[1]*1.05 and fresh_means[1]>fresh_means[2]*1.2,"Fresh wake did not settle smoothly")
	assert(difference(fresh_shots[2],old_wake).max_byte==0,"Settled wake did not recover its exact original filaments")
	var rest_meta:=Image.create(128,128,false,Image.FORMAT_RGBAF)
	for y in 128:
		for x in 128: rest_meta.set_pixel(x,y,Color(0,history.get_pixel(x,y).r,0,0))
	material.set_shader_parameter("foam2d_speed_texture",ImageTexture.create_from_image(rest_meta))
	var rest_off: Image=await capture()
	material.set_shader_parameter("foam2d_fresh_wake_enabled",true)
	var rest_on: Image=await capture()
	assert(difference(rest_off,rest_on).max_byte==0,"Fresh wake whitened a stationary hull")
	var report: Dictionary={"white":white,"normals":normals,"calm_blue":calm,"underwater":underwater,"extra_textures":0,"extra_simulations":0}
	report.speed_whitening_means=speed_means
	report.white_tint=white_tint
	report.animation_short=animation_short
	report.animation_long=animation_long
	report.fresh_wake_means=fresh_means
	FileAccess.open(OUTPUT+"/report.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("FOAM_RELIEF_MATERIAL_PASS ",JSON.stringify(report))
	world.queue_free()
	for frame in 3: await process_frame
	quit()
