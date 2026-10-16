extends Node
## Inspector-only startup. No tick callback, contact adapter or FFT field here.
var ready_to_drive := false

func start(vehicle: JetSkiController, ocean: Ocean) -> void:
	var was_frozen := vehicle.freeze
	vehicle.freeze = true
	# Same startup allowance as the shipped demo, including render-thread setup.
	for frame in 30:
		await get_tree().process_frame
	for frame in 600:
		if not is_instance_valid(ocean) or not is_instance_valid(vehicle):
			return
		if str(ocean.get_physics_source_state().get("status", "")) == "OK":
			break
		await get_tree().process_frame
	if str(ocean.get_physics_source_state().get("status", "")) != "OK":
		push_error("Jet Ski: assigned Ocean is not ready; vehicle remains frozen.")
		return
	var water := ocean.get_water_provider()
	# The first vehicle configures the shared provider. Further vehicles retain
	# its native object and settings; each already has its own contact context.
	if not is_instance_valid(water.native):
		water.wave_drift_enabled = true
		water.wave_drift_strength = 0.75
		water.wave_drift_max_speed_mps = 0.5
		if not water.configure(ocean, CpuFftWaterProvider.Backend.CPU_LITE_B, false):
			push_error("Jet Ski: Ocean CPU Lite could not initialize; vehicle remains frozen.")
			return
		water.set_query_mode(CpuFftWaterProvider.QueryMode.DIRECT)
		water.set_water_race_mode(true)
	vehicle.reset_physics_interpolation()
	vehicle.freeze = was_frozen
	ready_to_drive = true
