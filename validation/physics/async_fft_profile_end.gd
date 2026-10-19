extends Node
var recorder: SceneTree
func _physics_process(_delta: float) -> void:
	recorder.end_tick()
func _process(_delta: float) -> void:
	recorder.end_process()
