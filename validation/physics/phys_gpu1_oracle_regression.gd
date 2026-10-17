extends "res://validation/physics/phys_opt2_fft_mirror_runner.gd"
## Retain the existing lattice/DirectSpectral/Coastal checks unchanged.
## Select a current-API initialization smoke instead of the legacy CPU worker
## scheduling matrix, which assumes five snapshot-info values (current API: six).
## PHYS-GPU-1's separate runner exercises the current async oracle and GPU ring.
func _run_async_publication_suite(ocean: Node, native: Object, _snapshots: Array[Dictionary]) -> Dictionary:
	ocean.set("wave_speed_multiplier",0.0)
	for _i in 6: await physics_frame
	var time:=float(ocean.call("get_wave_time"))
	if not native.call("start_dynamic_async_fields",time,0): return {"passed":false,"error":"reference publisher startup"}
	var info:PackedInt64Array=native.call("get_dynamic_snapshot_info")
	var passed:=info.size()==6 and info[0]==1 and absf(info[1]/1e9-time)<2e-9
	print("GPU1_REFERENCE_API_SMOKE="+JSON.stringify({"passed":passed,"snapshot_info_values":info.size(),
		"legacy_scheduling_matrix":"not executed; its size==5 guard is incompatible with the unchanged source branch's current API"}))
	return {"passed":passed}
