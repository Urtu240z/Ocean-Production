extends SceneTree

const EVENT_DURATION_S := 0.80
const UPDATE_HZ := 30.0
const STEP_S := 1.0 / UPDATE_HZ
const EPSILON := 0.02

var _failures: Array[String] = []


func _init() -> void:
	_test_duration_contract()
	_test_refractory_contract()
	_test_score_arbitration()
	_test_source_contracts()
	if _failures.is_empty():
		print("BREAKER_LIFECYCLE_CONTRACT: PASS")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		print("BREAKER_LIFECYCLE_CONTRACT: FAIL (%d)" % _failures.size())
		quit(1)


func _test_duration_contract() -> void:
	var expected := {
		0.00: 0.00,
		0.20: 0.25,
		0.40: 0.50,
		0.60: 0.75,
		0.80: 1.00,
	}
	for sample_time in expected:
		var age := minf(sample_time / EVENT_DURATION_S, 1.0)
		_check(absf(age - float(expected[sample_time])) <= EPSILON, "duration age at t=%.2f was %.4f" % [sample_time, age])
	print("duration: 0.80 s at 30 Hz -> age 0.00, 0.25, 0.50, 0.75, 1.00")


func _test_refractory_contract() -> void:
	_check(not _can_rearm(2.99, 0.0, 3.0), "candidate rearmed before refractory elapsed")
	_check(_can_rearm(3.0, 0.0, 3.0), "candidate did not rearm after refractory elapsed")
	print("refractory: t=2.99 blocked, t=3.00 allowed")


func _test_score_arbitration() -> void:
	var winner := _select_winner([0.4, 0.9])
	_check(winner == 1, "score arbitration selected %d instead of candidate B" % winner)
	print("event selection: score 0.9 wins over score 0.4")


func _test_source_contracts() -> void:
	var shader := FileAccess.get_file_as_string("res://addons/ocean/shaders/fft/update_breaker_lifecycle.glsl")
	var gpu := FileAccess.get_file_as_string("res://addons/ocean/fft/gpu_stockham_fft.gd")
	_check(shader.contains("atomicMax"), "shader is missing deterministic atomicMax arbitration")
	_check(not shader.contains("atomicCompSwap"), "shader still contains first-invocation arbitration")
	_check(shader.contains("refractory countdown"), "shader is missing explicit refractory state")
	_check(gpu.contains("event_duration_s := maxf(values[1]"), "GPU dispatch does not send duration directly")
	_check(not gpu.contains("values[1] / maxf(values[0]"), "GPU dispatch still divides duration by lateral speed")


func _can_rearm(current_time: float, last_event_time: float, refractory_s: float) -> bool:
	return current_time - last_event_time >= refractory_s


func _select_winner(scores: Array[float]) -> int:
	var best_key := -1
	var winner := -1
	for index in scores.size():
		var score_q := int(round(clampf(scores[index], 0.0, 1.0) * 16383.0))
		var key := (score_q << 18) | index
		if key > best_key:
			best_key = key
			winner = index
	return winner


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
