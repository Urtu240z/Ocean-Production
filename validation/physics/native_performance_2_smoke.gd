extends "res://validation/physics/final_master_integration_smoke.gd"

func finish(state: Dictionary) -> void:
	state["failures"] = failures
	state["driver"] = RenderingServer.get_current_rendering_driver_name()
	DirAccess.make_dir_recursive_absolute("res://temp/native_performance_2")
	var file := FileAccess.open("res://temp/native_performance_2/production_smoke.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(state,"\t")); file.close()
	print("NP2_SMOKE ",JSON.stringify(state))
	quit(0 if failures.is_empty() else 1)
