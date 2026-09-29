extends SceneTree

const OCEAN_SCENE := preload("res://addons/ocean/ocean.tscn")
const SPEED_CASES := [1.0, 1.75]
const SAMPLE_FRAMES := 60
const PARITY_EPSILON := 0.000001
const RATE_TOLERANCE := 0.15


class FrameDeltaAccumulator:
	extends Node
	var elapsed := 0.0

	func _process(delta: float) -> void:
		elapsed += maxf(delta, 0.0)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var ocean := OCEAN_SCENE.instantiate()
	root.add_child(ocean)
	var delta_accumulator := FrameDeltaAccumulator.new()
	root.add_child(delta_accumulator)
	await process_frame

	var fft_runtime: Node = ocean.get_node_or_null("OpenOceanFFT")
	if fft_runtime == null or not fft_runtime.has_method("get_wave_time"):
		_fail("OpenOceanFFT did not start with a runtime clock.")
		return

	for speed in SPEED_CASES:
		ocean.set("wave_speed_multiplier", speed)
		await process_frame
		var t0 := float(ocean.call("get_wave_time"))
		var elapsed0: float = delta_accumulator.elapsed
		for frame in SAMPLE_FRAMES:
			await process_frame
		var t1 := float(ocean.call("get_wave_time"))
		var elapsed := delta_accumulator.elapsed - elapsed0
		var fft_time := float(fft_runtime.call("get_wave_time"))
		var parity_error := absf(t1 - fft_time)
		var measured_scale := (t1 - t0) / elapsed if elapsed > 0.0 else 0.0
		var allowed_rate_error := maxf(RATE_TOLERANCE, speed * RATE_TOLERANCE)
		if t1 <= t0:
			_fail("Ocean clock did not advance at wave_speed_multiplier=%s." % speed)
			return
		if parity_error > PARITY_EPSILON:
			_fail("Ocean/FFT clock parity error %s at wave_speed_multiplier=%s." % [parity_error, speed])
			return
		if elapsed <= 0.0 or absf(measured_scale - speed) > allowed_rate_error:
			_fail("Clock scale %s did not match requested multiplier %s." % [measured_scale, speed])
			return
		print("CLOCK_CASE speed=%s wave_delta=%.6f frame_delta=%.6f measured_scale=%.4f parity_error=%.9f" % [speed, t1 - t0, elapsed, measured_scale, parity_error])

	print("LIVE_CLOCK_CHECK PASS")
	quit(0)


func _fail(message: String) -> void:
	push_error("LIVE_CLOCK_CHECK FAIL: " + message)
	quit(1)
