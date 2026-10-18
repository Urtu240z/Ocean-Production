extends SceneTree
const AreaScene := preload("res://addons/ocean/areas/ocean_wave_area_3d.tscn")
const Runtime := preload("res://addons/ocean/areas/ocean_wave_area_runtime.gd")

class Host extends Node3D:
	var sea_level := 0.0

var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok:
		failures.append(label)
		push_error(label)

func run() -> void:
	var host := Host.new()
	root.add_child(host)
	var area = AreaScene.instantiate()
	area.ocean = host
	area.blend_distance_m = 10.0
	area.wave_height_m = 0.6
	area.wavelength_m = 12.0
	root.add_child(area)
	var state := Runtime.new()
	state.synchronize(host, 2.0)
	check(state.entries.size() == 1, "area registration")
	var base := Vector4(1.2, 0.1, 0.2, 0.3)
	check(state.compose(Vector2(90, 0), base) == base, "exterior unchanged")
	check(state.weight(state.entries[0],Vector3(75,0,0)) == 1.0, "shape boundary retains local climate")
	var center := state.compose(Vector2.ZERO, base)
	check(center.is_equal_approx(state.wave(state.entries[0], Vector2.ZERO, 2.0)), "interior local climate")
	# Verify the blend includes height-dependent slopes, not just normal lerp.
	var p := Vector2(80, 2)
	var e := 0.01
	var base_at := func(q: Vector2) -> Vector4: return Vector4(1.2 + 0.1 * q.x + 0.2 * q.y, 0.1, 0.2, 0.3)
	var result := state.compose(p, base_at.call(p))
	var dx := (state.compose(p + Vector2(e,0), base_at.call(p + Vector2(e,0))).x - state.compose(p - Vector2(e,0), base_at.call(p - Vector2(e,0))).x) / ((p+Vector2(e,0)).x-(p-Vector2(e,0)).x)
	var dz := (state.compose(p + Vector2(0,e), base_at.call(p + Vector2(0,e))).x - state.compose(p - Vector2(0,e), base_at.call(p - Vector2(0,e))).x) / ((p+Vector2(0,e)).y-(p-Vector2(0,e)).y)
	check(absf(result.y - dx) < 0.001 and absf(result.z - dz) < 0.001, "transition gradient")
	if absf(result.y-dx) >= 0.001 or absf(result.z-dz) >= 0.001: print("GRADIENT actual=",result," finite=",Vector2(dx,dz))
	var local_before := center
	state.time_s += e
	var local_after := state.compose(Vector2.ZERO, base)
	state.time_s -= 2.0 * e
	var local_before_time := state.compose(Vector2.ZERO, base)
	check(absf((local_after.x - local_before_time.x) / (2.0 * e) - center.w) < 0.005, "vertical velocity")
	area.wave_height_m = 0.0
	state.synchronize(host, 2.0)
	check(state.compose(Vector2.ZERO, base) == Vector4.ZERO, "calm harbor")
	area.enabled = false
	state.synchronize(host, 2.0)
	check(state.entries.is_empty(), "disabled area")
	area.enabled = true
	area.wave_height_m = 0.6
	var collision: CollisionShape3D = area.get_node("CollisionShape3D")
	var box := collision.shape
	var sphere := SphereShape3D.new()
	sphere.radius = 20.0
	collision.shape = sphere
	state.synchronize(host, 2.0)
	check(state.weight(state.entries[0],Vector3.ZERO) == 1.0 and state.weight(state.entries[0],Vector3(30,0,0)) == 0.0, "sphere footprint")
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 20.0
	cylinder.height = 60.0
	collision.shape = cylinder
	state.synchronize(host, 2.0)
	check(state.weight(state.entries[0],Vector3.ZERO) == 1.0 and state.weight(state.entries[0],Vector3(30,0,0)) == 0.0, "cylinder footprint")
	collision.shape = box
	area.blend_distance_m = 100.0
	state.synchronize(host,2.0)
	check(state.weight(state.entries[0],Vector3.ZERO) == 1.0 and state.weight(state.entries[0],Vector3(65,999,0)) == 1.0, "large feather and shape height never dilute core")
	area.blend_distance_m = 10.0
	area.rotation.y = 0.4
	area.scale = Vector3(1.5, 1, 0.8)
	state.synchronize(host, 2.0)
	check(state.pack_gpu().size() == Runtime.BUFFER_BYTES, "GPU buffer layout")
	var shader_values := state.shader_parameters()
	check(shader_values.wave_area_count == 1, "shader parameter snapshot")
	var second = AreaScene.instantiate()
	second.ocean = host
	second.wave_priority = 10
	second.wave_height_m = 0.0
	root.add_child(second)
	state.synchronize(host, 2.0)
	check(state.compose(Vector2.ZERO, base) == Vector4.ZERO, "overlap priority")
	second.queue_free()
	await process_frame
	state.synchronize(host, 2.0)
	var sample := WaterSample3D.new()
	sample.valid = true
	sample.surface_position = Vector3(0, base.x, 0)
	sample.normal = Vector3(-base.y,1,-base.z).normalized()
	sample.velocity.y = base.w
	state.apply([sample], PackedVector3Array([Vector3.ZERO]), 1.0)
	check(is_equal_approx(sample.surface_position.y, state.compose(Vector2.ZERO, base).x), "physics height")
	check(is_equal_approx(sample.signed_depth, sample.surface_position.y), "signed depth")
	var coefficients: PackedVector4Array = state.entries[0].components0.duplicate()
	state.synchronize(host,2.0)
	check(state.entries[0].components0 == coefficients and coefficients.size() > 4, "stable broadband spectrum")
	area.phase_seed += 1
	state.synchronize(host,2.0)
	check(state.entries[0].components0 != coefficients, "seed changes spectrum")
	area.apply_preset("harbor")
	state.synchronize(host,2.0)
	check(state.entries[0].meta.x == 23.0,"independent swell and ripples")
	if "--gpu" in OS.get_cmdline_user_args():
		check_gpu(state)
	area.free()
	host.free()
	print("WAVE_AREA_RESULT failures=", failures)
	quit(0 if failures.is_empty() else 1)

func check_gpu(state: RefCounted) -> void:
	var rd := RenderingServer.create_local_rendering_device()
	check(rd != null, "RenderingDevice available")
	if rd == null: return
	var math := FileAccess.get_file_as_string("res://addons/ocean/areas/wave_area_math.gdshaderinc")
	var buffer := FileAccess.get_file_as_string("res://addons/ocean/areas/wave_area_buffer.gdshaderinc")
	buffer = math + "\n" + buffer
	var source := RDShaderSource.new()
	source.source_compute = "#version 450\n#define WAVE_AREA_BINDING 0\n" + buffer + "\nlayout(local_size_x=1) in; layout(std430,set=0,binding=1) buffer Output { float heights[5]; }; void main(){ for(int i=0;i<5;i++){vec2 p=vec2(float(i)*22.0,2.0);heights[i]=wave_areas_height(p,1.2);}}"
	var spirv := rd.shader_compile_spirv_from_source(source)
	var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	check(error.is_empty(), "GPU shader compilation: " + error)
	if not error.is_empty():
		rd.free()
		return
	var shader := rd.shader_create_from_spirv(spirv)
	var pipeline := rd.compute_pipeline_create(shader)
	var input := rd.storage_buffer_create(Runtime.BUFFER_BYTES, state.pack_gpu())
	var output := rd.storage_buffer_create(32)
	var uniforms: Array[RDUniform] = []
	for i in 2:
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = i
		uniform.add_id(input if i == 0 else output)
		uniforms.append(uniform)
	var set := rd.uniform_set_create(uniforms, shader, 0)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, set, 0)
	rd.compute_list_dispatch(list,1,1,1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var results := rd.buffer_get_data(output).to_float32_array()
	for i in 5:
		check(absf(results[i] - state.compose(Vector2(i*22.0,2),Vector4(1.2,0,0,0)).x) < 0.0005, "CPU/GPU height parity %d" % i)
	for rid in [set, pipeline, shader, input, output]: rd.free_rid(rid)
	rd.free()
