extends SceneTree
## Exercise the real GPU history with a render clock that is not divisible by
## 20/30/60. Check wall-time conservation, switching and fixed allocation.
const History := preload("res://addons/ocean/surface/foam2d/projected_wake_history.gd")
var finished := false
var checks := []

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	for hz in [20,30,60,30]:
		finished=false
		RenderingServer.call_on_render_thread(check_history.bind(hz))
		while not finished: await process_frame
		await process_frame
	var result := {"rates":checks,"memory_bytes":4194304,"long_frame_single_pass":true}
	DirAccess.make_dir_recursive_absolute("res://temp/foam2d/wake_hz")
	FileAccess.open("res://temp/foam2d/wake_hz/cadence.json",FileAccess.WRITE).store_string(JSON.stringify(result,"\t"))
	print("FOAM2D_CADENCE_PASS ",JSON.stringify(result))
	quit()

func check_history(hz: int) -> void:
	var history := History.new()
	history.initialize()
	assert(history.ready,history.last_error)
	history.set_update_hz(hz)
	for frame in 288: history.advance(1.0/144.0)
	var count: int = history.completed_updates
	var seconds: float = history.diagnostic_state().flow_time_s
	assert(count == hz*2,"History cadence differs from selected Hz")
	assert(absf(seconds-2.0)<0.00001,"Fade/transport time depends on selected Hz")
	assert(history.diagnostic_state().history_bytes == 4194304)
	checks.append({"hz":hz,"updates":count,"simulated_seconds":seconds})
	# A pause must not trigger a burst of full-field catch-up dispatches.
	var initial_count: int = history.completed_updates
	history.advance(0.3)
	assert(history.completed_updates == initial_count+1)
	history.shutdown()
	finished=true
