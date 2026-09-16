extends SceneTree
## H3.3 SSPR depth-reprojected temporal validation.
##
## The CPU section verifies the exact current-depth -> world -> previous-VP
## contract, including camera motion, rotation, flat-plane regression and
## depth disocclusion. The GPU section runs the same reconstruction on a local
## RenderingDevice only; no global renderer RID is shared or submitted.

const TEMPORAL_SHADER := "res://addons/ocean/reflections/shaders/ocean_sspr_temporal.glsl"
const GPU_TEST_SHADER := preload("res://validation/shaders/ocean_sspr_temporal_reprojection_test.glsl")
const EPSILON := 0.0001
const DEPTH_EPSILON := 0.000001

var _failed := false
var _gpu_blocked := false


func _initialize() -> void:
	if not _run_source_contract() or not _run_math_tests():
		quit(1)
		return
	var gpu_passed := _run_gpu_test()
	if _gpu_blocked:
		print("GPU_RUNTIME_BLOCKED_BY_ENVIRONMENT")
		quit(2)
		return
	if not gpu_passed:
		quit(1)
		return
	print("OCEAN_SSPR_GPU_TEMPORAL_REPROJECTION_PASS")
	quit(0)


func _run_source_contract() -> bool:
	var shader := FileAccess.get_file_as_string(TEMPORAL_SHADER)
	if shader.is_empty():
		return _fail("Temporal shader is missing")
	for token in ["reproject_previous", "current_depth_value", "current_inverse_view_projection", "previous_view_projection", "expected_previous_depth", "abs(expected_previous_depth - old_depth)"]:
		if not shader.contains(token):
			return _fail("H3.3 temporal source contract missing: " + token)
	if shader.contains("params.ocean_level") or shader.contains("(params.ocean_level.x"):
		return _fail("Temporal shader still uses ocean_level for reprojection")
	if shader.contains("vec4 a") or shader.contains("vec4 b") or shader.contains("b.y-a.y"):
		return _fail("Flat-plane ray reconstruction remains in Temporal")
	if shader.contains("abs(current_depth_value-old_depth)"):
		return _fail("Temporal disocclusion still compares current depth with history depth")
	if not shader.contains("history_depth_output, pixel, vec4(current_valid ? current_depth_value : 0.0)"):
		return _fail("Temporal history depth no longer stores current reflected depth")
	print("OCEAN_SSPR_TEMPORAL_SOURCE_CONTRACT_PASS")
	return true


func _run_math_tests() -> bool:
	var world_point := Vector3(4.0, -12.0, -30.0)
	var current := _make_projection(3.0, 12.0, 8.0)
	var previous := _make_projection(1.0, 5.0, 3.0)
	var current_projection := _project(current, world_point)
	var direct_previous := _project(previous, world_point)
	var reconstructed := _reproject(current, previous, current_projection.uv, current_projection.depth)
	if not bool(reconstructed.get("valid", false)):
		return _fail("H3.3 basic reprojection rejected a valid reflected point")
	if reconstructed.world.distance_to(world_point) > EPSILON:
		return _fail("current depth did not reconstruct the reflected world point")
	if reconstructed.previous_uv.distance_to(direct_previous.uv) > EPSILON or not is_equal_approx(reconstructed.expected_previous_depth, direct_previous.depth):
		return _fail("previous VP projection does not match direct projection")
	print("OCEAN_SSPR_TEMPORAL_WORLD_RECONSTRUCTION_PASS")

	var positions := [0.0, 1.0, 3.0, 7.0]
	for index in range(1, positions.size()):
		var current_vp := _make_projection(positions[index], 0.0, 0.0)
		var previous_vp := _make_projection(positions[index - 1], 0.0, 0.0)
		var current_sample := _project(current_vp, world_point)
		var result := _reproject(current_vp, previous_vp, current_sample.uv, current_sample.depth)
		var expected := _project(previous_vp, world_point)
		if not bool(result.get("valid", false)) or result.previous_uv.distance_to(expected.uv) > EPSILON or not is_equal_approx(result.expected_previous_depth, expected.depth):
			return _fail("camera translation reprojection mismatch at x=%s" % positions[index])
	print("OCEAN_SSPR_TEMPORAL_TRANSLATION_REPROJECTION_PASS positions=0,1,3,7")

	var yaws := [0.0, 5.0, 12.0, 20.0]
	var pitches := [0.0, 3.0, 8.0, 3.0]
	for index in range(1, yaws.size()):
		var current_vp := _make_projection(2.0, yaws[index], pitches[index])
		var previous_vp := _make_projection(2.0, yaws[index - 1], pitches[index - 1])
		var current_sample := _project(current_vp, world_point)
		var result := _reproject(current_vp, previous_vp, current_sample.uv, current_sample.depth)
		var expected := _project(previous_vp, world_point)
		if not bool(result.get("valid", false)) or result.previous_uv.distance_to(expected.uv) > EPSILON or not is_equal_approx(result.expected_previous_depth, expected.depth):
			return _fail("camera rotation reprojection mismatch at index %d" % index)
	print("OCEAN_SSPR_TEMPORAL_ROTATION_REPROJECTION_PASS yaw=0,5,12,20 pitch=0,3,8,3")

	var old_plane := _old_flat_plane_reconstruction(current, current_projection.uv, current_projection.depth, 0.0)
	if not bool(old_plane.get("valid", false)) or old_plane.world.distance_to(world_point) < 0.1:
		return _fail("flat-plane regression case did not diverge from reflected world point")
	if reconstructed.world.distance_to(world_point) > EPSILON:
		return _fail("depth reprojection did not preserve off-plane reflected point")
	print("OCEAN_SSPR_FLAT_PLANE_REPROJECTION_REMOVED_PASS")

	var moving_current := _project(_make_projection(3.0, 0.0, 0.0), world_point)
	var moving_previous := _project(_make_projection(0.0, 0.0, 0.0), world_point)
	var moving_result := _reproject(_make_projection(3.0, 0.0, 0.0), _make_projection(0.0, 0.0, 0.0), moving_current.uv, moving_current.depth)
	if is_equal_approx(moving_current.depth, moving_result.expected_previous_depth) or not is_equal_approx(moving_result.expected_previous_depth, moving_previous.depth):
		return _fail("previous depth confidence test did not separate current and previous clip depth")
	var same_confidence := _depth_confidence(moving_result.expected_previous_depth, moving_previous.depth, 0.05)
	var other_confidence := _depth_confidence(moving_result.expected_previous_depth, moving_previous.depth + 0.5, 0.05)
	if same_confidence < 0.99 or other_confidence > 0.001:
		return _fail("depth confidence does not use expected previous depth")
	print("OCEAN_SSPR_PREVIOUS_DEPTH_CONFIDENCE_PASS")
	print("OCEAN_SSPR_TEMPORAL_DISOCCLUSION_PASS same=%.3f different=%.3f" % [same_confidence, other_confidence])
	return true


func _make_projection(camera_x: float, yaw: float, pitch: float) -> Projection:
	var projection := Projection()
	projection.x = Vector4(0.05, 0.002 * yaw, 0.001 * pitch, 0.0)
	projection.y = Vector4(-0.001 * yaw, 0.045, 0.0005 * pitch, 0.0)
	projection.z = Vector4(0.0, 0.012 + 0.0003 * pitch, 0.012, 0.0)
	projection.w = Vector4(-0.025 * camera_x, 0.0, 0.68 + 0.004 * camera_x + 0.001 * yaw, 1.0)
	return projection


func _projection_xform(projection: Projection, value: Vector4) -> Vector4:
	return Vector4(
		projection.x.x * value.x + projection.y.x * value.y + projection.z.x * value.z + projection.w.x * value.w,
		projection.x.y * value.x + projection.y.y * value.y + projection.z.y * value.z + projection.w.y * value.w,
		projection.x.z * value.x + projection.y.z * value.y + projection.z.z * value.z + projection.w.z * value.w,
		projection.x.w * value.x + projection.y.w * value.y + projection.z.w * value.z + projection.w.w * value.w
	)


func _project(projection: Projection, world: Vector3) -> Dictionary:
	var clip := _projection_xform(projection, Vector4(world, 1.0))
	var ndc := clip.xyz / clip.w
	return {"uv": ndc.xy * 0.5 + 0.5, "depth": ndc.z}


func _reproject(current: Projection, previous: Projection, current_uv: Vector2, current_depth: float) -> Dictionary:
	var ndc_xy := current_uv * 2.0 - 1.0
	var current_world := _projection_xform(current.inverse(), Vector4(ndc_xy.x, ndc_xy.y, current_depth, 1.0))
	if abs(current_world.w) <= DEPTH_EPSILON:
		return {"valid": false}
	current_world /= current_world.w
	var previous_clip := _projection_xform(previous, Vector4(current_world.x, current_world.y, current_world.z, 1.0))
	if previous_clip.w <= DEPTH_EPSILON:
		return {"valid": false}
	var previous_ndc := previous_clip.xyz / previous_clip.w
	var previous_uv := previous_ndc.xy * 0.5 + 0.5
	var valid := previous_uv.x >= 0.0 and previous_uv.x <= 1.0 and previous_uv.y >= 0.0 and previous_uv.y <= 1.0 and previous_ndc.z >= 0.0 and previous_ndc.z <= 1.0
	return {"valid": valid, "world": current_world.xyz, "previous_uv": previous_uv, "expected_previous_depth": previous_ndc.z}


func _old_flat_plane_reconstruction(current: Projection, current_uv: Vector2, current_depth: float, ocean_level: float) -> Dictionary:
	var ndc_xy := current_uv * 2.0 - 1.0
	var inverse_current := current.inverse()
	var a := _projection_xform(inverse_current, Vector4(ndc_xy.x, ndc_xy.y, 0.0, 1.0))
	var b := _projection_xform(inverse_current, Vector4(ndc_xy.x, ndc_xy.y, 1.0, 1.0))
	if abs(a.w) <= DEPTH_EPSILON or abs(b.w) <= DEPTH_EPSILON:
		return {"valid": false}
	a /= a.w
	b /= b.w
	var denominator := b.y - a.y
	if abs(denominator) <= DEPTH_EPSILON:
		return {"valid": false}
	var t := (ocean_level - a.y) / denominator
	if t < 0.0 or t > 1.0:
		return {"valid": false}
	return {"valid": true, "world": a.lerp(b, t).xyz}


func _depth_confidence(expected_previous_depth: float, old_depth: float, threshold: float) -> float:
	var normalized := clampf((abs(expected_previous_depth - old_depth) - threshold) / threshold, 0.0, 1.0)
	return 1.0 - normalized * normalized * (3.0 - 2.0 * normalized)


func _run_gpu_test() -> bool:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		_gpu_blocked = true
		return false
	var shader_file := GPU_TEST_SHADER as RDShaderFile
	if shader_file == null:
		rd.free()
		return _fail("H3.3 GPU validation shader did not import")
	var shader := rd.shader_create_from_spirv(shader_file.get_spirv(), "OceanSSPR.TemporalReprojectionValidation")
	if not shader.is_valid():
		rd.free()
		return _fail("H3.3 GPU validation shader creation failed")
	var pipeline := rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		rd.free_rid(shader)
		rd.free()
		return _fail("H3.3 GPU validation pipeline creation failed")
	var current := _make_projection(3.0, 12.0, 8.0)
	var previous := _make_projection(1.0, 5.0, 3.0)
	var world_point := Vector3(4.0, -12.0, -30.0)
	var current_sample := _project(current, world_point)
	var input_buffer := rd.storage_buffer_create(144, _pack_gpu_input(current.inverse(), previous, current_sample.uv, current_sample.depth))
	var result_buffer := rd.storage_buffer_create(32)
	var input_uniform := RDUniform.new()
	input_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	input_uniform.binding = 0
	input_uniform.add_id(input_buffer)
	var result_uniform := RDUniform.new()
	result_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	result_uniform.binding = 1
	result_uniform.add_id(result_buffer)
	var uniform_set := rd.uniform_set_create([input_uniform, result_uniform], shader, 0)
	if not uniform_set.is_valid():
		rd.free_rid(input_buffer); rd.free_rid(result_buffer); rd.free_rid(pipeline); rd.free_rid(shader); rd.free()
		return _fail("H3.3 GPU validation uniform set creation failed")
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_dispatch(list, 1, 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var bytes := rd.buffer_get_data(result_buffer)
	var world_result := Vector3(bytes.decode_float(0), bytes.decode_float(4), bytes.decode_float(8))
	var previous_uv_result := Vector2(bytes.decode_float(16), bytes.decode_float(20))
	var expected_depth_result := bytes.decode_float(24)
	var valid_result := bytes.decode_float(28)
	var expected := _project(previous, world_point)
	var passed := valid_result > 0.5 and world_result.distance_to(world_point) <= EPSILON and previous_uv_result.distance_to(expected.uv) <= EPSILON and is_equal_approx(expected_depth_result, expected.depth)
	rd.free_rid(uniform_set)
	rd.free_rid(input_buffer)
	rd.free_rid(result_buffer)
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free()
	if not passed:
		return _fail("H3.3 GPU reprojection readback mismatch")
	return true


func _pack_gpu_input(current_inverse: Projection, previous: Projection, current_uv: Vector2, current_depth: float) -> PackedByteArray:
	var values := PackedFloat32Array()
	for projection in [current_inverse, previous]:
		for column in [projection.x, projection.y, projection.z, projection.w]:
			values.append_array([column.x, column.y, column.z, column.w])
	values.append_array([current_uv.x, current_uv.y, current_depth, 0.0])
	return values.to_byte_array()


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_SSPR_TEMPORAL_REPROJECTION_FAIL: " + reason)
	return false
