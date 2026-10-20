extends "res://addons/jet_ski/common/systems/jet_ski_hull_buoyancy_v1.gd"
## Replay-only capture. Each retained result is tagged with its evaluation tick.
var recorded: Array = []
var recorded_ticks := PackedInt64Array()

func _init() -> void:
	recorded.resize(12)
	recorded_ticks.resize(12)
	recorded_ticks.fill(-1)

func native_cell_result(index: int) -> Dictionary:
	var result := super(index)
	recorded[index] = result
	recorded_ticks[index] = Engine.get_physics_frames()
	return result

func integrate_native_batch(transform: Transform3D, samples: Array[WaterSample3D], draft: float) -> bool:
	var result := super(transform,samples,draft)
	if result:
		# Observe the batch itself as well: consumers may read compact cells
		# without invoking the legacy Dictionary adapter. Validation only.
		for index in 12:
			if _native_valid[index] == 0: continue
			recorded[index] = super.native_cell_result(index)
			recorded_ticks[index] = Engine.get_physics_frames()
	return result
