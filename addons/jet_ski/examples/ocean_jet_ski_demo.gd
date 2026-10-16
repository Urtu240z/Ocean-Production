extends Node3D
## Minimal host: configure Ocean once and hand its shared provider to vehicles.
## Driving, buoyancy, input bindings, camera and contact FX belong to Jet Ski.
var ready_to_drive := false

func _enter_tree() -> void:
	if $JetSki.ocean != null:
		return
	$JetSki.freeze = true
	$JetSki.configure_ocean($Ocean)

func _ready() -> void:
	if $JetSki.ocean != null:
		# An inspector-assigned vehicle owns startup; do not configure twice.
		while not bool($JetSki.get_node("OceanConnection").get("ready_to_drive")):
			await get_tree().process_frame
		ready_to_drive = true
		return
	# Match the existing production startup cadence; never build during a query
	# on behalf of the example. Subsequent builds are owned by Ocean's provider.
	for frame in 30: await get_tree().process_frame
	var ocean: Ocean = $Ocean
	for frame in 600:
		if str(ocean.get_physics_source_state().get("status", "")) == "OK": break
		await get_tree().process_frame
	var water := ocean.get_water_provider()
	water.lite_resolutions = PackedInt32Array([128, 128, 128])
	water.lite_interpolation_modes = PackedInt32Array([1, 1, 1])
	water.compare_other_cpu_backend = false
	water.capture_contact_trace = false
	# Existing production wave-dependent drift settings; configured once per Ocean.
	water.wave_drift_enabled = true
	water.wave_drift_strength = 0.75
	water.wave_drift_max_speed_mps = 0.5
	if not water.configure(ocean, CpuFftWaterProvider.Backend.CPU_LITE_B, false):
		push_error("Jet Ski demo: Ocean CPU Lite could not initialize")
		return
	water.set_query_mode(CpuFftWaterProvider.QueryMode.DIRECT)
	water.set_water_race_mode(true)
	$JetSki.reset_physics_interpolation()
	$JetSki.freeze = false
	ready_to_drive = true
