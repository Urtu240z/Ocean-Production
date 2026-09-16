extends SceneTree
## H3.2 depth-aware candidate arbitration validation.
##
## CPU checks prove the key/tie contracts and source-ID independence. The GPU
## check owns a local RenderingDevice so submit/sync never target the game's
## global renderer device.

const DEPTH_PROJECT := "res://addons/ocean/reflections/shaders/ocean_sspr_project.glsl"
const SOURCE_PROJECT := "res://addons/ocean/reflections/shaders/ocean_sspr_project_source.glsl"
const RESOLVE := "res://addons/ocean/reflections/shaders/ocean_sspr_resolve.glsl"
const EFFECT := "res://addons/ocean/reflections/ocean_sspr_effect.gd"
const GPU_TEST_SHADER := preload("res://validation/shaders/ocean_sspr_depth_arbitration_test.glsl")
const INVALID_U32 := 0xffffffff
const DEPTH_EPSILON := 0.0001

var _failed := false
var _gpu_blocked := false


func _initialize() -> void:
	if not _run_source_contracts() or not _run_depth_key_tests():
		quit(1)
		return
	if not _run_arbitration_tests():
		quit(1)
		return
	var gpu_passed := _run_gpu_semantic_test()
	if _gpu_blocked:
		print("GPU_RUNTIME_BLOCKED_BY_ENVIRONMENT")
		quit(2)
		return
	if not gpu_passed:
		quit(1)
		return
	print("OCEAN_SSPR_GPU_DEPTH_ARBITRATION_PASS")
	quit(0)


func _run_source_contracts() -> bool:
	var depth_source := FileAccess.get_file_as_string(DEPTH_PROJECT)
	var source_source := FileAccess.get_file_as_string(SOURCE_PROJECT)
	var resolve_source := FileAccess.get_file_as_string(RESOLVE)
	var effect_source := FileAccess.get_file_as_string(EFFECT)
	if depth_source.is_empty() or source_source.is_empty() or resolve_source.is_empty() or effect_source.is_empty():
		return _fail("H3.2 source contract files are missing")
	if depth_source.contains("atomicMax") or source_source.contains("atomicMax") or resolve_source.contains("atomicMax"):
		return _fail("payload ordering atomicMax remains")
	if not depth_source.contains("atomicMin(candidate_depth") or not source_source.contains("atomicMin(candidate_source"):
		return _fail("two-pass depth/source atomics are missing")
	if not resolve_source.contains("candidate_source") or not resolve_source.contains("candidate_depth"):
		return _fail("Resolve does not consume explicit source/depth candidates")
	if not effect_source.contains("_candidate_depth") or not effect_source.contains("_candidate_source") or not effect_source.contains("_project_depth_pipeline") or not effect_source.contains("_project_source_pipeline"):
		return _fail("RD lifecycle does not expose both candidate resources/pipelines")
	var depth_helper := _shared_project_helper(depth_source)
	var source_helper := _shared_project_helper(source_source)
	if depth_helper.is_empty() or depth_helper != source_helper:
		return _fail("Project Depth and Project Source projection helpers diverged")
	if not effect_source.contains("source.x > 65535") or not effect_source.contains("source.y > 65535"):
		return _fail("source payload dimension guard is missing")
	print("OCEAN_SSPR_PROJECT_HELPER_PARITY_PASS")
	return true


func _shared_project_helper(source: String) -> String:
	var begin := source.find("// SHARED_PROJECT_CANDIDATE_BEGIN")
	var end := source.find("// SHARED_PROJECT_CANDIDATE_END")
	if begin < 0 or end <= begin:
		return ""
	return source.substr(begin, end - begin)


func _run_depth_key_tests() -> bool:
	var depths := [2.0, 5.0, 12.0, 50.0, 250.0]
	var keys: Array[int] = []
	for depth in depths:
		if not is_finite(depth) or depth <= DEPTH_EPSILON:
			return _fail("invalid depth in key-order test")
		var key := _depth_key(depth)
		if key == INVALID_U32:
			return _fail("valid depth collided with sentinel")
		keys.append(key)
	for index in range(1, keys.size()):
		if keys[index - 1] >= keys[index]:
			return _fail("positive float bit ordering is not monotonic")
	if INVALID_U32 <= keys.back():
		return _fail("depth sentinel is not greater than valid keys")
	var max_payload := ((65534 << 16) | 65534) + 1
	if max_payload >= INVALID_U32 or max_payload == 0:
		return _fail("16-bit source payload can collide with the UINT_MAX sentinel")
	print("OCEAN_SSPR_DEPTH_KEY_ORDER_PASS")
	print("OCEAN_SSPR_SOURCE_PAYLOAD_RANGE_PASS max_dimensions=65535 max_payload=%d" % max_payload)
	return true


func _run_arbitration_tests() -> bool:
	var near_small := {"depth": 5.0, "payload": 100}
	var far_large := {"depth": 20.0, "payload": 90000}
	if _cpu_winner([near_small, far_large]).payload != near_small.payload or _cpu_winner([far_large, near_small]).payload != near_small.payload:
		return _fail("source ID changed the winner in contradictory candidate test")
	print("OCEAN_SSPR_DEPTH_ARBITRATION_PASS")
	var triple := [
		{"depth": 35.0, "payload": 3},
		{"depth": 4.0, "payload": 90000},
		{"depth": 11.0, "payload": 1},
	]
	if _cpu_winner(triple).depth != 4.0:
		return _fail("triple collision did not choose nearest depth")
	print("OCEAN_SSPR_MULTI_CANDIDATE_DEPTH_PASS")
	var equal_a := {"depth": 12.0, "payload": 700}
	var equal_b := {"depth": 12.0, "payload": 12}
	if _cpu_winner([equal_a, equal_b]).payload != 12 or _cpu_winner([equal_b, equal_a]).payload != 12:
		return _fail("equal-depth tie is not deterministic")
	print("OCEAN_SSPR_EQUAL_DEPTH_TIE_PASS")
	var candidates := [
		{"depth": 35.0, "payload": 17},
		{"depth": 4.0, "payload": 90000},
		{"depth": 11.0, "payload": 2},
	]
	var winners := []
	for order in [
		[candidates[0], candidates[1], candidates[2]],
		[candidates[2], candidates[1], candidates[0]],
		[candidates[1], candidates[0], candidates[2]],
	]:
		winners.append(_cpu_winner(order).payload)
	if winners[0] != winners[1] or winners[1] != winners[2] or winners[0] != 90000:
		return _fail("candidate order changed the winner")
	print("OCEAN_SSPR_CANDIDATE_ORDER_INDEPENDENCE_PASS")
	return true


func _cpu_winner(candidates: Array) -> Dictionary:
	var winner: Dictionary = {}
	var winner_key := INVALID_U32
	for candidate in candidates:
		var key := _depth_key(float(candidate.depth))
		if key < winner_key or (key == winner_key and int(candidate.payload) < int(winner.get("payload", INVALID_U32))):
			winner = candidate
			winner_key = key
	return winner


func _depth_key(depth: float) -> int:
	var bytes := PackedFloat32Array([depth]).to_byte_array()
	return bytes.decode_u32(0)


func _run_gpu_semantic_test() -> bool:
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		_gpu_blocked = true
		return false
	var shader_file := GPU_TEST_SHADER as RDShaderFile
	if shader_file == null:
		rd.free()
		return _fail("GPU arbitration validation shader did not import")
	var shader := rd.shader_create_from_spirv(shader_file.get_spirv(), "OceanSSPR.DepthArbitrationValidation")
	if not shader.is_valid():
		rd.free()
		return _fail("GPU arbitration validation shader creation failed")
	var pipeline := rd.compute_pipeline_create(shader)
	if not pipeline.is_valid():
		rd.free_rid(shader)
		rd.free()
		return _fail("GPU arbitration validation shader/pipeline creation failed")
	var orders := [
		[{"depth": 35.0, "payload": 17}, {"depth": 4.0, "payload": 90000}, {"depth": 11.0, "payload": 2}],
		[{"depth": 11.0, "payload": 2}, {"depth": 4.0, "payload": 90000}, {"depth": 35.0, "payload": 17}],
		[{"depth": 4.0, "payload": 90000}, {"depth": 35.0, "payload": 17}, {"depth": 11.0, "payload": 2}],
	]
	for order in orders:
		var winner := _run_gpu_case(rd, shader, pipeline, order)
		if winner != 90000:
			rd.free_rid(pipeline); rd.free_rid(shader)
			rd.free()
			return _fail("GPU arbitration recovered payload %s instead of near payload 90000" % winner)
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free()
	return true


func _run_gpu_case(rd: RenderingDevice, shader: RID, pipeline: RID, candidates: Array) -> int:
	var depths := PackedFloat32Array()
	var payloads := PackedInt32Array()
	for candidate in candidates:
		depths.append(float(candidate.depth))
		payloads.append(int(candidate.payload))
	var input_depth := rd.storage_buffer_create(depths.to_byte_array().size(), depths.to_byte_array())
	var input_source := rd.storage_buffer_create(payloads.to_byte_array().size(), payloads.to_byte_array())
	var candidate_depth := rd.storage_buffer_create(4, PackedInt32Array([-1]).to_byte_array())
	var candidate_source := rd.storage_buffer_create(4, PackedInt32Array([-1]).to_byte_array())
	var uniforms := [
		_rd_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 0, input_depth),
		_rd_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, input_source),
		_rd_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 2, candidate_depth),
		_rd_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 3, candidate_source),
	]
	var uniform_set := rd.uniform_set_create(uniforms, shader, 0)
	if not uniform_set.is_valid():
		return _gpu_case_cleanup(rd, input_depth, input_source, candidate_depth, candidate_source, -1)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, PackedInt32Array([0, candidates.size()]).to_byte_array(), 8)
	rd.compute_list_dispatch(list, candidates.size(), 1, 1)
	rd.compute_list_add_barrier(list)
	rd.compute_list_set_push_constant(list, PackedInt32Array([1, candidates.size()]).to_byte_array(), 8)
	rd.compute_list_dispatch(list, candidates.size(), 1, 1)
	rd.compute_list_end()
	rd.submit()
	rd.sync()
	var depth_bytes := rd.buffer_get_data(candidate_depth)
	var expected_depth_key := INVALID_U32
	for candidate in candidates:
		expected_depth_key = mini(expected_depth_key, _depth_key(float(candidate.depth)))
	if int(depth_bytes.decode_u32(0)) != expected_depth_key:
		rd.free_rid(uniform_set)
		_gpu_case_cleanup(rd, input_depth, input_source, candidate_depth, candidate_source, -1)
		return -1
	var bytes := rd.buffer_get_data(candidate_source)
	var winner := int(bytes.decode_u32(0))
	rd.free_rid(uniform_set)
	return _gpu_case_cleanup(rd, input_depth, input_source, candidate_depth, candidate_source, winner)


func _rd_uniform(type: int, binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform


func _gpu_case_cleanup(rd: RenderingDevice, input_depth: RID, input_source: RID, candidate_depth: RID, candidate_source: RID, winner: int) -> int:
	rd.free_rid(input_depth)
	rd.free_rid(input_source)
	rd.free_rid(candidate_depth)
	rd.free_rid(candidate_source)
	return winner


func _fail(reason: String) -> bool:
	if not _failed:
		_failed = true
		push_error("OCEAN_SSPR_DEPTH_ARBITRATION_FAIL: " + reason)
	return false
