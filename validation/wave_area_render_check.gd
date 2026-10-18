extends SceneTree
const Runtime := preload("res://addons/ocean/areas/ocean_wave_area_runtime.gd")
const AreaScene := preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
class Host extends Node3D:
	var sea_level := 2.0

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(128,128)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var host := Host.new()
	viewport.add_child(host)
	var center := Vector3(1625,2,1613)
	var area = AreaScene.instantiate()
	area.ocean = host
	area.position = center
	area.wave_height_m = 0.0
	host.add_child(area)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.position = center + Vector3(0,100,0)
	camera.rotation_degrees = Vector3(-90,0,0)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 140
	camera.far = 200
	camera.current = true
	var plane := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(180,180)
	mesh.subdivide_width = 64
	mesh.subdivide_depth = 64
	plane.mesh = mesh
	plane.position = center
	viewport.add_child(plane)
	var shader := Shader.new()
	shader.code = 'shader_type spatial; render_mode unshaded, cull_disabled;\n#include "res://addons/ocean/areas/wave_area_surface.gdshaderinc"\nvarying vec3 rendered_position; void vertex(){vec3 p=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;wave_area_base_height=3.0;VERTEX.y=wave_areas_compose(vec3(p.x,wave_area_sea_level,p.z),vec4(3.0,0.0,0.0,0.0)).x;rendered_position=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;} void fragment(){float w=wave_area_weight(vec3(rendered_position.x,wave_area_sea_level,rendered_position.z),wave_area_inverse[0],wave_area_shape[0],wave_area_blend[0]);ALBEDO=vec3(w,0.0,clamp((rendered_position.y-wave_area_sea_level)/3.0,0.0,1.0));}'
	var material := ShaderMaterial.new()
	material.shader = shader
	var state := Runtime.new()
	state.synchronize(host,2.0)
	var values: Dictionary = state.shader_parameters()
	for key in values: material.set_shader_parameter(key,values[key])
	plane.material_override = material
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var pixel := image.get_pixel(64,64)
	DirAccess.make_dir_recursive_absolute("res://temp/wave_areas")
	image.save_png("res://temp/wave_areas/translated_material.png")
	var passed := pixel.r > 0.95 and pixel.b < 0.05
	print("WAVE_AREA_RENDER_RESULT pass=",passed," center_pixel=",pixel," cpu_weight=",state.weight(state.entries[0],center))
	viewport.queue_free()
	for i in 3: await process_frame
	quit(0 if passed else 1)
