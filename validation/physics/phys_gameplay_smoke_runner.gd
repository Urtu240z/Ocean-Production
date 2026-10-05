extends SceneTree
const World = preload("res://gameplay/jet_ski_ocean.tscn")

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var world: Node = World.instantiate(); root.add_child(world)
	while not world.ready_to_drive: await process_frame
	Input.action_press("throttle",0.3)
	for i in 120: await physics_frame
	Input.action_release("throttle")
	world.ski.reset_vehicle(&"smoke_reset")
	for i in 90: await physics_frame
	print("GAMEPLAY_LAUNCH_SMOKE="+JSON.stringify({"position":str(world.ski.position),"age":world.water.result_age,"minimum_generation":world.water.minimum_generation,"completed":world.water.query.get_stats().heightfield_batches}))
	world._close_gracefully()
