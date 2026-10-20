extends "res://validation/physics/perf_contact_real_scene_profile.gd"
## Extra subsystem clocks are routed only in the diagnostic run.
func perf2_record_span(stage: int, frame_id: int, tick_id: int, started: int, finished: int, calls: int) -> void:
	super(stage,frame_id,tick_id,started,finished,calls)
	if measured and stage in [2,3,4]:
		runtime.metrics.record(StringName("contact.stage%d"%stage),finished-started,calls,tick_id,frame_id)
