extends "res://validation/physics/hull_native_deterministic_scene.gd"
## Existing six-body replay plus live local-spectrum edits and cache evidence.
var hot_profile: Resource
var configuration_checks := 0
var np2_coverage := {"hull_wave_packets_max":0,"drift_ticks":0,"tsunami_ticks":0,"local_slots":0}

func create_profile_scene(scene_path: String) -> Node:
	var instance := super(scene_path)
	var host: Ocean = instance.get_node("JetSkiOcean/Production/Ocean")
	hot_profile = host.wave_profile.duplicate(true)
	host.local_sea_state_1.wave_profile = hot_profile
	return instance

func begin_tick() -> void:
	super()
	if not recording: return
	var tick := Engine.get_physics_frames()-replay_start_tick
	if tick == 350:
		var first := ocean.local_sea_state_1.fingerprint(hot_profile,ocean.simulation_seed)
		ocean.local_sea_state_1.wind_speed_mps += 0.75
		assert(first != ocean.local_sea_state_1.fingerprint(hot_profile,ocean.simulation_seed))
		configuration_checks += 1
	if tick == 390:
		var first := ocean.local_sea_state_1.fingerprint(hot_profile,ocean.simulation_seed)
		hot_profile.long_band.choppiness += 0.125
		assert(first != ocean.local_sea_state_1.fingerprint(hot_profile,ocean.simulation_seed))
		configuration_checks += 1
	if tick == 450:
		ocean.local_sea_state_2.ocean_scale = 1.125
		ocean.local_sea_state_2.clipmap_geometry_scale = 0.9
	if tick == 570:
		ocean.local_sea_state_2.wave_speed_multiplier = 0.0
	if tick == 590:
		ocean.local_sea_state_2.wave_speed_multiplier = 1.0

func sample_row(sample: WaterSample3D) -> Array:
	return [sample.valid,sample.surface_position,sample.normal,sample.velocity,sample.signed_depth,
		sample.provider == world.water,sample.sample_time_seconds,
		Engine.get_physics_frames()-sample.sample_physics_tick if sample.sample_physics_tick >= 0 else -1]

func end_tick() -> void:
	var before := replay_rows.size()
	super()
	if replay_rows.size() == before: return
	var provider: CpuFftWaterProvider = world.water
	var consumers := []
	for body in replay_bodies:
		var context: RefCounted = body.get("_water_consumer_context")
		var owner: Object = provider if provider.get("_active_consumer") == context else context
		var cache := []
		for sample in owner.get("_selected_contact_cache"): cache.append(sample_row(sample))
		var history: RefCounted = owner.get("_local_contacts")
		var base_samples := []
		for sample in history.last_samples:
			base_samples.append(sample_row(sample) if sample != null else [])
		consumers.append({"positions":owner.get("_contact_positions"),"cache":cache,
			"cursor":owner.get("_contact_cache_cursor"),"base_samples":base_samples,
			"history":history.history,"field_time":history.field_time,"mode_seam":history.mode_seam_pending})
	var waves: RefCounted = ocean.get_physical_hull_wave_state()
	if waves != null: np2_coverage.hull_wave_packets_max = maxi(np2_coverage.hull_wave_packets_max,waves.emitter.packets.size())
	if provider.wave_drift_enabled and provider.wave_drift_strength > 0: np2_coverage.drift_ticks += 1
	if tsunami_state.center_radius.w > 0: np2_coverage.tsunami_ticks += 1
	for slot in 2:
		if runtime.states[slot] != null: np2_coverage.local_slots |= 1 << slot
	replay_rows[-1]["np2_water"] = {"consumers":consumers,"field_time":provider.current_field_time,
		"field_tick_age":Engine.get_physics_frames()-provider.last_build_tick,"mode":provider.query_mode,
		"rate":provider.wave_time_rate,"hot_configuration_checks":configuration_checks,"coverage":np2_coverage.duplicate()}
	var physical: Dictionary = replay_rows[-1].duplicate(true)
	physical.erase("hull_backend_diagnostics"); physical.erase("physical_binary_sha256")
	physical_hasher.start(HashingContext.HASH_SHA256)
	physical_hasher.update(var_to_bytes(physical))
	replay_rows[-1]["physical_binary_sha256"] = physical_hasher.finish().hex_encode()
