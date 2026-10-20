extends "res://addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd"
## Replay-only capture. Each retained result is tagged with its evaluation tick.
var recorded: Array = []
var recorded_ticks := PackedInt64Array()

func _init() -> void:
	recorded.resize(12)
	recorded_ticks.resize(12)
	recorded_ticks.fill(-1)

func integrate_cell(index: int, transform: Transform3D, sample: WaterSample3D, draft_offset_m: float) -> Dictionary:
	var result := super(index,transform,sample,draft_offset_m)
	recorded[index] = result
	recorded_ticks[index] = Engine.get_physics_frames()
	return result

func native_cell_result(index: int) -> Dictionary:
	var result := super(index)
	recorded[index] = result
	recorded_ticks[index] = Engine.get_physics_frames()
	return result
