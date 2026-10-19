@tool
extends RefCounted
## Opt-in diagnostic recorder. Inclusive times; no printing or per-contact records.
var enabled := false
var ticks: Dictionary = {}
var frames: Dictionary = {}

func record(metric: StringName, elapsed_us: int, count := 1, tick := -1, frame := -1) -> void:
	if not enabled: return
	if tick < 0: tick = Engine.get_physics_frames()
	if frame < 0: frame = Engine.get_process_frames()
	_accumulate(ticks, tick, metric, elapsed_us, count)
	_accumulate(frames, frame, metric, elapsed_us, count)

func _accumulate(target: Dictionary, index: int, metric: StringName, elapsed_us: int, count: int) -> void:
	if not target.has(index): target[index] = {}
	var bucket: Dictionary = target[index]
	if not bucket.has(metric): bucket[metric] = Vector2i.ZERO
	bucket[metric] += Vector2i(count, elapsed_us)

func clear() -> void:
	ticks.clear()
	frames.clear()
