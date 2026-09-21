class_name OpenOceanFFT
extends Node3D
## Propietario concreto del P0: H0, tres solvers y su clipmap.

const Spectrum := preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const Solver := preload("res://addons/ocean/fft/gpu_stockham_fft.gd")
const GPUGeneration := preload("res://addons/ocean/fft/gpu_resource_generation.gd")
const Surface := preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
const CoastalRuntime := preload("res://addons/ocean/coastal/ocean_coastal_runtime.gd")
const SurfaceFoam := preload("res://addons/ocean/surface/ocean_surface_foam.gd")
const OceanSSPR := preload("res://addons/ocean/reflections/ocean_sspr.gd")
const CrestFoamProfile := preload("res://addons/ocean/core/ocean_crest_foam_profile.gd")
const SurfaceFoamProfile := preload("res://addons/ocean/core/ocean_surface_foam_profile.gd")
const ReflectionProfile := preload("res://addons/ocean/core/ocean_reflection_profile.gd")
const SurfaceDetailProfile := preload("res://addons/ocean/core/ocean_surface_detail_profile.gd")
const BreakerProfile := preload("res://addons/ocean/core/ocean_breaker_profile.gd")
const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")
const SpindriftController := preload("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")
const OceanSpace := preload("res://addons/ocean/core/ocean_space_contract.gd")

var _solvers: Array = []
var _wave_configs: Array = []
var _clipmap_quality: Resource
var _textures: Array[Texture2DRD] = []
var _normal_textures: Array[Texture2DRD] = []
var _crest_foam_textures: Array[Texture2DRD] = []
var _crest_resolutions: Array[int] = []
var _crest_neutral_texture := Texture2DRD.new()
var _crest_neutral_rid := RID()
var _breaker_lifecycle_texture := Texture2DRD.new()
var _published_breaker_lifecycle_rid := RID()
var _breaker_lifecycle_publication_revision := 0
var _breaker_lifecycle_retire_pending := false
var _breaker_lifecycle_retire_revision := -1
var _breaker_multiphase_vdm_texture := Texture2DRD.new()
var _published_breaker_multiphase_vdm_rid := RID()
var _surface: Node3D
var _enabled := false
var _coastal_runtime: RefCounted
var _surface_foam: RefCounted
var _surface_foam_field := Texture2DRD.new()
var _surface_foam_topology := Texture2DRD.new()
var _surface_foam_mid_history := Texture2DRD.new()
var _simulation_seed := 1
var _mid_resolution := 256
var _crest_foam_profile: OceanCrestFoamProfile
var _surface_foam_profile: OceanSurfaceFoamProfile
var _surface_foam_generation := 0
var _surface_foam_published := false
var _surface_foam_published_rids: Array[RID] = [RID(), RID(), RID()]
var _sspr: Node
var _sea_level := 0.0
var _wave_time := 0.0
var _wave_speed_multiplier := 1.0
var _cascade_state := CascadeState.new()
var _neutral_displacement_texture := Texture2DRD.new()
var _neutral_normal_texture := Texture2DRD.new()
var _neutral_displacement_rid := RID()
var _neutral_normal_rid := RID()
var _gpu_generation: OceanGPUResourceGeneration
var _generation_counter := 0
var _published_generation := -1
var _stale_publication_rejections := 0
var _surface_initialized := false
var _fft_displacement_bounds := Vector3.ZERO
var _published_displacement_rids: Array[RID] = []
var _published_normal_rids: Array[RID] = []
var _published_crest_rids: Array[RID] = []
var _crest_foam_requested := false
var _surface_scale := 1.0
var _clipmap_geometry_scale := 1.0
var _debug_view := 0
var _optics_requested := false
var _optics_profile: Resource
var _snell_profile: Resource
var _reflections_requested := false
var _reflection_profile: OceanReflectionProfile
var _surface_detail_requested := false
var _surface_detail_profile: OceanSurfaceDetailProfile
var _breaker_profile: OceanBreakerProfile
var _coastal_data: Dictionary = {}
var _borrowed_coastal_rd_cache: Dictionary = {}
var _borrowed_rd_cache_hits := 0
var _borrowed_rd_cache_misses := 0
var _borrowed_rd_conversions := 0
var _coastal_waves_active := true
var _surface_foam_requested := false
var _coastal_waves_requested := false
var _breakers_requested := false
var _local_breaker_refinement_enabled := false
var _local_breaker_refinement_authority: Dictionary = {}
var _runtime_water_state: StringName = &"TRANSITION"
var _camera_surface_signed_distance_m := 1.0
var _spindrift: OceanSpindriftV4
var _wind_speed_mps := 18.0
var _wind_direction_degrees := 0.0
var _ocean_space := OceanSpace.new()


func initialize(profile: Resource, quality: Resource, seed: int, sea_level: float, overall_hs_m := -1.0, wind_speed_override_mps := -1.0, primary_direction_degrees := -1000.0, swell_override := -1.0, crest_enabled := true, surface_foam_enabled := true, crest_profile: OceanCrestFoamProfile = null, surface_profile: OceanSurfaceFoamProfile = null, wave_height_scale := 1.0, long_band_scale := 1.0, mid_band_scale := 1.0, short_band_scale := 1.0, initial_wave_time := 0.0, cascade_mask := CascadeState.FULL, long_wave_spacing := 1.0, mid_fill_amount := 1.0) -> bool:
	shutdown()
	_cascade_state.configure(cascade_mask)
	_wave_time = maxf(initial_wave_time, 0.0)
	_simulation_seed = seed
	_sea_level = sea_level
	_wind_speed_mps = maxf(wind_speed_override_mps, 0.0)
	_wind_direction_degrees = primary_direction_degrees if primary_direction_degrees > -999.0 else 0.0
	_clipmap_quality = quality
	_crest_foam_profile = crest_profile
	_surface_foam_profile = surface_profile
	_surface_foam_requested = surface_foam_enabled
	var crest_values := _crest_profile_or_default()
	var configs: Array = profile.build_fft_configs(overall_hs_m, wind_speed_override_mps, primary_direction_degrees, swell_override, long_wave_spacing)
	if configs.size() != 3 or not configs.all(func(config): return config.is_valid()):
		push_error("Ocean: perfil FFT P0 inválido.")
		return false
	_wave_configs = configs.duplicate()
	_generation_counter += 1
	_gpu_generation = GPUGeneration.new(_generation_counter)
	_published_generation = -1
	_crest_foam_requested = crest_enabled
	var global_target_hs: float = overall_hs_m if overall_hs_m >= 0.0 else profile.combined_significant_wave_height_m()
	var raw_h0: Array[PackedByteArray] = []
	var relative_amplitudes: Array[float] = []
	var weighted_variance: float = 0.0
	for index in configs.size():
		var config = configs[index]
		if not _cascade_state.is_active(_band_for_index(index)):
			raw_h0.append(PackedByteArray())
			relative_amplitudes.append(0.0)
			continue
		var raw: PackedByteArray = Spectrum.build_h0_rgba32f(config, Spectrum.derive_cascade_seed(seed, config.id), false)
		# WIND_DRIVEN uses the natural band-pass spectrum.  The per-band Hs values
		# are legacy/manual targets and must not suppress MID/SHORT as weights.
		var legacy_amplitude: float = 1.0 if overall_hs_m < 0.0 else float(config.target_hs_m / global_target_hs if global_target_hs > 0.0000001 else 0.0)
		var band_scale: float = [long_band_scale, mid_band_scale, short_band_scale][index] if overall_hs_m < 0.0 else 1.0
		var relative_amplitude: float = legacy_amplitude * band_scale
		if index == 1:
			relative_amplitude *= clampf(mid_fill_amount, 0.0, 1.5)
		relative_amplitudes.append(relative_amplitude)
		raw = Spectrum.scale_packed_h0(raw, relative_amplitude)
		raw_h0.append(raw)
		weighted_variance += pow(config.measured_hs_m * relative_amplitude / 4.0, 2.0)
	var common_scale: float = wave_height_scale if overall_hs_m < 0.0 else float(global_target_hs / (4.0 * sqrt(weighted_variance)) if weighted_variance > 0.0000000001 else 0.0)
	_fft_displacement_bounds = Vector3.ZERO
	for index in configs.size():
		if not _cascade_state.is_active(_band_for_index(index)):
			continue
		var effective_hs := absf(float(configs[index].measured_hs_m)) * absf(relative_amplitudes[index]) * absf(common_scale)
		_fft_displacement_bounds.x += effective_hs * maxf(float(configs[index].choppiness), 0.0)
		_fft_displacement_bounds.y += effective_hs
	var generation := _gpu_generation
	RenderingServer.call_on_render_thread(generation.create_neutral_resources)
	RenderingServer.call_on_render_thread(generation.create_breaker_multiphase_vdm)
	for index in configs.size():
		var config = configs[index]
		if not _cascade_state.is_active(_band_for_index(index)):
			_solvers.append(null)
			_textures.append(_neutral_displacement_texture)
			_normal_textures.append(_neutral_normal_texture)
			_crest_foam_textures.append(_crest_neutral_texture)
			_crest_resolutions.append(config.resolution)
			_published_displacement_rids.append(RID())
			_published_normal_rids.append(RID())
			_published_crest_rids.append(RID())
			continue
		var solver = Solver.new()
		var h0: PackedByteArray = Spectrum.scale_packed_h0(raw_h0[index], common_scale)
		config.measured_hs_m *= common_scale
		var settings: Array = _crest_settings_for_index(crest_values, index, config.resolution)
		RenderingServer.call_on_render_thread(generation.initialize_solver.bind(solver, config, h0, "Ocean.%s.G%d" % [config.id, generation.generation], settings))
		var displacement := Texture2DRD.new()
		var normal := Texture2DRD.new()
		var crest_foam := Texture2DRD.new()
		_solvers.append(solver)
		_textures.append(displacement)
		_normal_textures.append(normal)
		_crest_foam_textures.append(crest_foam)
		_crest_resolutions.append(config.resolution)
		_published_displacement_rids.append(RID())
		_published_normal_rids.append(RID())
		_published_crest_rids.append(RID())
	_mid_resolution = configs[1].resolution
	# The material is intentionally not initialized until this generation has
	# valid neutral resources and FFT displacement/normal RIDs.
	_surface = Surface.new()
	_surface.name = &"OceanClipmapSurface"
	add_child(_surface)
	_surface.visible = false
	set_crest_foam(crest_enabled)
	if surface_foam_enabled:
		_create_surface_foam(seed, configs[1].resolution)
	_enabled = true
	return true


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	if _surface != null:
		_surface.visible = value and _surface_initialized
	set_process(value)


func is_enabled() -> bool:
	return _enabled


func is_surface_initialized() -> bool:
	return _surface_initialized and _surface != null and is_instance_valid(_surface)


func is_surface_authoritatively_visible() -> bool:
	# This reports OpenOceanFFT's desired visibility. A debug consumer may
	# temporarily hide the surface, but it must restore this authority when it
	# leaves that explicit debug mode.
	return is_surface_initialized() and _enabled


func set_debug_view(value: int) -> void:
	_debug_view = clampi(value, 0, 1)
	if _surface_initialized: _surface.set_debug_view(_debug_view)


func set_surface_scale(value: float) -> void:
	_surface_scale = clampf(value, 0.25, 4.0)
	_ocean_space.configure(_surface_scale, _clipmap_geometry_scale)
	if _surface_initialized:
		_surface.set_surface_scale(_surface_scale)
	if _spindrift != null and _spindrift.has_method(&"set_ocean_space"):
		_spindrift.set_ocean_space(_ocean_space.as_dictionary())


func set_clipmap_geometry_scale(value: float) -> void:
	_clipmap_geometry_scale = clampf(value, 0.25, 4.0)
	_ocean_space.configure(_surface_scale, _clipmap_geometry_scale)
	if _surface_initialized:
		_surface.set_clipmap_geometry_scale(_clipmap_geometry_scale)
	if _spindrift != null and _spindrift.has_method(&"set_ocean_space"):
		_spindrift.set_ocean_space(_ocean_space.as_dictionary())


func get_ocean_space_contract() -> Dictionary:
	return _ocean_space.as_dictionary()


func set_wave_speed_multiplier(value: float) -> void:
	_wave_speed_multiplier = clampf(value, 0.0, 3.0)


func set_spindrift_enabled(enabled: bool, profile: OceanSpindriftProfile, debug_mode: int) -> void:
	if not enabled:
		if _spindrift != null:
			_spindrift.set_enabled(false)
			_spindrift.queue_free()
			_spindrift = null
		return
	if _spindrift == null:
		_spindrift = SpindriftController.new()
		_spindrift.name = &"OceanSpindriftV4"
		add_child(_spindrift)
	_spindrift.configure(self, profile, _sea_level, _wind_speed_mps, _wind_direction_degrees, debug_mode)


func set_spindrift_debug_mode(debug_mode: int) -> void:
	if _spindrift != null:
		_spindrift.set_debug_mode(debug_mode)


func get_spindrift_runtime_state() -> Dictionary:
	if _spindrift == null:
		return {"enabled": false, "configured_max_live_particles": 0}
	return _spindrift.get_runtime_state()


func get_wave_time() -> float:
	return _wave_time


func get_underwater_medium_raster_surface() -> OceanClipmapSurface:
	return _surface as OceanClipmapSurface


func get_underwater_medium_raster_sources() -> Dictionary:
	# RIDs are published only after every FFT displacement texture exists. The
	# P6 owner retries this startup publication; it never treats RID() as ready.
	if _textures.size() != 3 or _wave_configs.size() != 3 or _clipmap_quality == null:
		return {}
	var rids: Array[RID] = []
	for texture in _textures:
		if texture == null or not texture.texture_rd_rid.is_valid():
			return {}
		rids.append(texture.texture_rd_rid)
	if _crest_foam_textures.size() < 1 or _crest_foam_textures[0] == null or not _crest_foam_textures[0].texture_rd_rid.is_valid():
		return {}
	var coastal_enabled := _coastal_waves_active and _coastal_source_data_valid()
	var coastal_field_rid := rids[0]
	var coastal_warp_rid := rids[0]
	var coastal_origin := Vector2.ZERO
	var coastal_extent := Vector2.ONE
	var coastal_warp_origin := Vector2.ZERO
	var coastal_warp_extent := Vector2.ONE
	var coastal_warp_detj_safe := 0.5
	if coastal_enabled:
		var candidate_field := _get_cached_borrowed_rd_rid(&"field", _coastal_data.get("field") as Texture2D)
		var candidate_warp := _get_cached_borrowed_rd_rid(&"warp", _coastal_data.get("warp") as Texture2D)
		if candidate_field.is_valid() and candidate_warp.is_valid():
			coastal_field_rid = candidate_field
			coastal_warp_rid = candidate_warp
			coastal_origin = _coastal_data.get("origin", Vector2.ZERO)
			coastal_extent = _coastal_data.get("extent", Vector2.ONE)
			coastal_warp_origin = _coastal_data.get("warp_origin", Vector2.ZERO)
			coastal_warp_extent = _coastal_data.get("warp_extent", Vector2.ONE)
			coastal_warp_detj_safe = float(_coastal_data.get("warp_detj_safe", 0.5))
		else:
			coastal_enabled = false
	var breaker_enabled := false
	var breaker_phase_rid := coastal_field_rid
	var breaker_metrics_rid := coastal_field_rid
	var breaker_normal_long_rid := rids[0]
	var breaker_multiphase_vdm_rid := rids[0]
	var breaker_normal_ready := false
	if _normal_textures.size() > 0 and _normal_textures[0] != null and _normal_textures[0].texture_rd_rid.is_valid():
		breaker_normal_long_rid = _normal_textures[0].texture_rd_rid
		breaker_normal_ready = true
	var surface_state: Dictionary = _surface.get_runtime_feature_state() if _surface != null and is_instance_valid(_surface) and _surface.has_method(&"get_runtime_feature_state") else {}
	if bool(surface_state.get("breakers", false)) and coastal_enabled and _breaker_multiphase_vdm_texture.texture_rd_rid.is_valid():
		var candidate_phase := _get_cached_borrowed_rd_rid(&"phase", _coastal_data.get("phase") as Texture2D)
		var candidate_metrics := _get_cached_borrowed_rd_rid(&"metrics", _coastal_data.get("metrics") as Texture2D)
		if candidate_phase.is_valid() and candidate_metrics.is_valid() and breaker_normal_ready and _published_breaker_lifecycle_rid.is_valid() and _published_breaker_lifecycle_rid != _crest_neutral_rid:
			breaker_enabled = true
			breaker_phase_rid = candidate_phase
			breaker_metrics_rid = candidate_metrics
			breaker_multiphase_vdm_rid = _breaker_multiphase_vdm_texture.texture_rd_rid
	return {
		"long": rids[0],
		"mid": rids[1],
		"short": rids[2],
		"breaking_activity_long": _crest_foam_textures[0].texture_rd_rid,
		"breaker_lifecycle": _breaker_lifecycle_texture.texture_rd_rid,
		"breaker_lifecycle_publication_revision": _breaker_lifecycle_publication_revision,
		"breaking_activity_channel": 1,
		"breaking_activity_range": Vector2(0.0, 1.0),
		"breaking_activity_generation": _published_generation,
		"domains": _ocean_space.ocean_domains(Vector3(_wave_configs[0].domain_size_m, _wave_configs[1].domain_size_m, _wave_configs[2].domain_size_m)),
		"ocean_scale": _ocean_space.ocean_scale,
		"clipmap_geometry_scale": _ocean_space.clipmap_geometry_scale,
		"long_fade": _clipmap_quality.long_fade_range_m,
		"mid_fade": _clipmap_quality.mid_fade_range_m,
		"short_fade": _clipmap_quality.short_fade_range_m,
		"coastal_enabled": coastal_enabled,
		"coastal_field": coastal_field_rid,
		"coastal_warp": coastal_warp_rid,
		"coastal_origin": coastal_origin,
		"coastal_extent": coastal_extent,
		"coastal_warp_origin": coastal_warp_origin,
		"coastal_warp_extent": coastal_warp_extent,
		"coastal_warp_detj_safe": coastal_warp_detj_safe,
		"breaker_enabled": breaker_enabled,
		"breaker_phase": breaker_phase_rid,
		"breaker_metrics": breaker_metrics_rid,
		"breaker_normal_long": breaker_normal_long_rid,
		"breaker_multiphase_vdm": breaker_multiphase_vdm_rid,
		"breaker_profile": _breaker_profile_values(),
	}


func _breaker_profile_values() -> PackedFloat32Array:
	var values: OceanBreakerProfile = _breaker_profile if _breaker_profile != null else BreakerProfile.new()
	return PackedFloat32Array([
		float(values.get("strength")),
		float(values.get("shallow_fade_start_m")), float(values.get("shallow_fade_end_m")),
		float(values.get("deep_activation_start_m")), float(values.get("deep_activation_end_m")),
		float(values.get("shoaling_start")), float(values.get("shoaling_full")),
		float(values.get("detj_compression_start")), float(values.get("detj_compression_full")),
		float(values.get("crest_height_start_m")), float(values.get("crest_height_full_m")),
		float(values.get("front_slope_start")), float(values.get("front_slope_full")),
		float(values.get("forward_push_fraction")), float(values.get("face_compression_fraction")),
		float(values.get("crest_lift_scale")), float(values.get("crest_curve")),
		float(values.get("pre_lip_strength")), float(values.get("pre_lip_forward_fraction")), float(values.get("pre_lip_lift_scale")),
		float(values.get("max_horizontal_fraction")), float(values.get("max_vertical_lift_scale")),
		float(values.get("lip_strength")), float(values.get("lip_forward_fraction")),
		float(values.get("lip_drop_scale")), float(values.get("lip_lift_scale")),
		float(values.get("lip_prefold_start_j")), float(values.get("lip_prefold_full_j")),
		float(values.get("lip_unsafe_j")), float(values.get("lip_recover_j")),
	])


func _breaker_lifecycle_values() -> PackedFloat32Array:
	var values: OceanBreakerProfile = _breaker_profile if _breaker_profile != null else BreakerProfile.new()
	const EVENT_HISTORY_DECAY_S := 2.0
	const EVENT_REFRACTORY_S := 3.0
	const EVENT_HISTORY_DRIFT_MPS := 0.3
	return PackedFloat32Array([
		values.breaker_lateral_propagation_speed_mps, values.breaker_event_duration_s, EVENT_HISTORY_DECAY_S,
		EVENT_REFRACTORY_S, values.breaker_foam_spawn_threshold, values.breaker_lateral_continuity_m,
		1.0, EVENT_HISTORY_DRIFT_MPS, 1.0,
		values.breaker_event_energy_scale, 0.0,
	])


func _coastal_source_data_valid() -> bool:
	if _coastal_data.is_empty():
		return false
	var field_texture := _coastal_data.get("field") as Texture2D
	var warp_texture := _coastal_data.get("warp") as Texture2D
	var origin: Vector2 = _coastal_data.get("origin", Vector2.ZERO)
	var extent: Vector2 = _coastal_data.get("extent", Vector2.ZERO)
	var warp_origin: Vector2 = _coastal_data.get("warp_origin", Vector2.ZERO)
	var warp_extent: Vector2 = _coastal_data.get("warp_extent", Vector2.ZERO)
	var detj_safe := float(_coastal_data.get("warp_detj_safe", NAN))
	if field_texture == null or warp_texture == null:
		return false
	if not origin.is_finite() or not warp_origin.is_finite():
		return false
	if not extent.is_finite() or extent.x <= 0.00001 or extent.y <= 0.00001:
		return false
	if not warp_extent.is_finite() or warp_extent.x <= 0.00001 or warp_extent.y <= 0.00001:
		return false
	return is_finite(detj_safe) and detj_safe > 0.00001


func _get_cached_borrowed_rd_rid(key: StringName, texture: Texture2D) -> RID:
	if texture == null or not is_instance_valid(texture):
		_borrowed_coastal_rd_cache.erase(key)
		return RID()
	var texture_rid: RID = texture.get_rid()
	if not texture_rid.is_valid():
		_borrowed_coastal_rd_cache.erase(key)
		return RID()
	var source_instance_id: int = texture.get_instance_id()
	var cached_value: Variant = _borrowed_coastal_rd_cache.get(key, null)
	if cached_value is Dictionary:
		var cached: Dictionary = cached_value
		var cached_texture_rid: RID = cached.get("texture_rid", RID())
		var cached_rd_rid: RID = cached.get("rd_rid", RID())
		if int(cached.get("texture_instance_id", 0)) == source_instance_id and cached_texture_rid == texture_rid and cached_rd_rid.is_valid():
			_borrowed_rd_cache_hits += 1
			return cached_rd_rid
	_borrowed_rd_cache_misses += 1
	_borrowed_rd_conversions += 1
	var rd_rid: RID = RenderingServer.texture_get_rd_texture(texture_rid, false)
	if rd_rid.is_valid():
		_borrowed_coastal_rd_cache[key] = {
			"texture_instance_id": source_instance_id,
			"texture_rid": texture_rid,
			"rd_rid": rd_rid,
		}
	else:
		_borrowed_coastal_rd_cache.erase(key)
	return rd_rid if rd_rid.is_valid() else RID()


func _clear_borrowed_coastal_rd_cache() -> void:
	# These are borrowed references. Clearing the map drops only our handles;
	# CoastalRuntime/RenderingServer retain ownership of the actual textures.
	_borrowed_coastal_rd_cache.clear()


func get_runtime_feature_state() -> Dictionary:
	var surface_state: Dictionary = _surface.get_runtime_feature_state() if _surface != null and _surface.has_method(&"get_runtime_feature_state") else {}
	var coastal_runtime_state: Dictionary = _coastal_runtime.get_runtime_state() if _coastal_runtime != null and _coastal_runtime.has_method(&"get_runtime_state") else {"resident": false, "active": false}
	var lifecycle_snapshot: Dictionary = _solvers[0].get_publication_snapshot() if not _solvers.is_empty() and _solvers[0] != null else {}
	var lifecycle_published := _published_breaker_lifecycle_rid.is_valid() and _published_breaker_lifecycle_rid != _crest_neutral_rid
	return {
		"surface_present": _surface != null and is_instance_valid(_surface),
		"shader_variant_key": surface_state.get("shader_variant_key", ""),
		"crest_foam": surface_state.get("crest_foam", false),
		"surface_foam": surface_state.get("surface_foam", false),
		"optics": surface_state.get("optics", false),
		"snell_tir": surface_state.get("snell_tir", false),
		"reflections": surface_state.get("reflections", false),
		"surface_detail": surface_state.get("surface_detail", false),
		"breakers_requested": _breakers_requested,
		"breaker_lifecycle_requested": _breakers_requested,
		"breaker_lifecycle_dispatch_enabled": lifecycle_snapshot.get("breaker_lifecycle_dispatch_enabled", false),
		"breaker_lifecycle_published": lifecycle_published,
		"breaker_lifecycle_retire_pending": _breaker_lifecycle_retire_pending or bool(lifecycle_snapshot.get("breaker_lifecycle_retire_pending", false)),
		"breaker_lifecycle_published_rid_valid": _breaker_lifecycle_texture != null and _breaker_lifecycle_texture.texture_rd_rid.is_valid(),
		"breakers": surface_state.get("breakers", false),
		"breaker_multiphase_vdm_ready": _published_breaker_multiphase_vdm_rid.is_valid(),
		"breaker_multiphase_vdm_rid_valid": _breaker_multiphase_vdm_texture != null and _breaker_multiphase_vdm_texture.texture_rd_rid.is_valid(),
		"breaker_material_enabled": surface_state.get("breaker_material_enabled", false),
		"sspr": _sspr != null and is_instance_valid(_sspr),
		"runtime_water_state": String(_runtime_water_state),
		"camera_surface_signed_distance_m": _camera_surface_signed_distance_m,
		"sspr_runtime_active": _sspr_should_be_runtime_active() and _sspr != null and is_instance_valid(_sspr),
		"optics_runtime_active": surface_state.get("optics", false),
		"surface_detail_runtime_active": surface_state.get("surface_detail", false),
		"breakers_runtime_active": surface_state.get("breakers", false),
		"local_breaker_refinement_enabled": surface_state.get("local_breaker_refinement_enabled", false),
		"local_breaker_refinement": surface_state.get("local_breaker_refinement", {}),
		"surface_foam_presentation_active": surface_state.get("surface_foam", false),
		"coastal_runtime": coastal_runtime_state,
		"surface_foam_update_hz": _surface_foam.get_update_hz() if _surface_foam != null and _surface_foam.has_method(&"get_update_hz") else 30.0,
		"spindrift": _spindrift != null and is_instance_valid(_spindrift),
		"spindrift_runtime": get_spindrift_runtime_state(),
	}


func set_runtime_water_state(state: StringName) -> void:
	if state == _runtime_water_state:
		return
	_runtime_water_state = state
	if _surface_initialized and _surface.has_method(&"set_runtime_water_state"):
		_surface.set_runtime_water_state(state)
	if _sspr != null and _sspr.has_method(&"set_runtime_active"):
		_sspr.set_runtime_active(_sspr_should_be_runtime_active())
	if _surface_foam != null:
		var update_hz := 10.0 if state == &"UNDERWATER_SAFE" else 30.0
		RenderingServer.call_on_render_thread(_surface_foam.set_update_hz.bind(update_hz))


func set_camera_surface_signed_distance(distance_m: float) -> void:
	if not is_finite(distance_m):
		return
	_camera_surface_signed_distance_m = distance_m
	if _surface_initialized and _surface != null and is_instance_valid(_surface):
		_surface.set_camera_surface_signed_distance(distance_m)


func set_coastal(enabled: bool, bake: Resource) -> void:
	_coastal_waves_requested = enabled
	var waves_active := enabled and _cascade_state.is_active(CascadeState.LONG)
	_coastal_waves_active = waves_active
	if bake == null:
		if _coastal_runtime != null:
			_coastal_runtime.deactivate()
		_coastal_data = {}
		if _surface_initialized: _surface.set_coastal_data(_coastal_data, waves_active)
		return
	if _coastal_runtime == null: _coastal_runtime = CoastalRuntime.new()
	# The real-seabed bake has independent P4 optical authority.  We keep its
	# resident data available with Coastal waves off, while only the wave
	# material route obeys `enabled`.
	_coastal_data = _coastal_runtime.activate(bake)
	if _surface_initialized: _surface.set_coastal_data(_coastal_data, waves_active)


func set_breakers(enabled: bool, profile: OceanBreakerProfile) -> void:
	if not enabled and _surface_initialized:
		_surface.set_breakers(false, profile)
	var lifecycle_was_published := _published_breaker_lifecycle_rid.is_valid() and _published_breaker_lifecycle_rid != _crest_neutral_rid
	_breakers_requested = enabled
	_breaker_profile = profile
	if not enabled:
		# Phase A: stop lifecycle dispatch and unpublish it from the solver snapshot.
		_update_breaker_lifecycle_state()
		_publish_breaker_lifecycle_texture()
		if lifecycle_was_published and _published_breaker_lifecycle_rid == _crest_neutral_rid:
			_breaker_lifecycle_retire_pending = true
			_breaker_lifecycle_retire_revision = _breaker_lifecycle_publication_revision
	else:
		_breaker_lifecycle_retire_pending = false
		_breaker_lifecycle_retire_revision = -1
		_update_breaker_lifecycle_state()
	if enabled and _surface_initialized:
		_surface.set_breakers(enabled, profile)


func set_breaker_profile(profile: OceanBreakerProfile) -> void:
	_breaker_profile = profile
	_update_breaker_lifecycle_state()
	if _surface_initialized:
		_surface.set_breaker_profile(profile)


func _update_breaker_lifecycle_state() -> void:
	if _solvers.is_empty() or _gpu_generation == null: return
	var solver = _solvers[0]
	if solver == null: return
	if _breakers_requested:
		RenderingServer.call_on_render_thread(_gpu_generation.set_solver_crest_enabled.bind(solver, true))
	RenderingServer.call_on_render_thread(_gpu_generation.set_solver_breaker_lifecycle_enabled.bind(solver, _breakers_requested, _breaker_lifecycle_values()))
	if not _breakers_requested and not _crest_foam_requested:
		RenderingServer.call_on_render_thread(_gpu_generation.set_solver_crest_enabled.bind(solver, false))


func acknowledge_breaker_lifecycle_publication(publication_revision: int) -> void:
	if _breakers_requested or not _breaker_lifecycle_retire_pending or publication_revision != _breaker_lifecycle_retire_revision:
		return
	if _breaker_lifecycle_texture == null or not _breaker_lifecycle_texture.texture_rd_rid.is_valid() or _breaker_lifecycle_texture.texture_rd_rid != _crest_neutral_rid:
		return
	if _gpu_generation == null or _solvers.is_empty() or _solvers[0] == null:
		return
	_breaker_lifecycle_retire_pending = false
	_breaker_lifecycle_retire_revision = -1
	RenderingServer.call_on_render_thread(_gpu_generation.retire_solver_breaker_lifecycle_resources.bind(_solvers[0]))


func set_local_breaker_refinement_enabled(enabled: bool) -> void:
	_local_breaker_refinement_enabled = enabled
	if _surface_initialized:
		_surface.set_local_breaker_refinement_enabled(enabled)
		if not _local_breaker_refinement_authority.is_empty():
			_surface.set_local_breaker_refinement_authority(_local_breaker_refinement_authority)


func set_local_breaker_refinement_authority(authority: Dictionary) -> void:
	_local_breaker_refinement_authority = authority.duplicate(true)
	if _surface_initialized:
		_surface.set_local_breaker_refinement_authority(_local_breaker_refinement_authority)


func set_local_breaker_refinement_debug_visible(visible: bool) -> void:
	if _surface_initialized and _surface.has_method(&"set_local_breaker_refinement_debug_visible"):
		_surface.set_local_breaker_refinement_debug_visible(visible)


func get_local_breaker_refinement_info() -> Dictionary:
	if _surface != null and _surface.has_method(&"get_local_breaker_refinement_info"):
		return _surface.get_local_breaker_refinement_info()
	return {}


func set_crest_foam(enabled: bool) -> void:
	_crest_foam_requested = enabled
	if not enabled:
		# The material stops sampling Crest before resources are released.
		if _surface_initialized: _surface.set_crest_foam_enabled(false)
		for index in _solvers.size():
			var solver = _solvers[index]
			if solver != null:
				if _gpu_generation != null:
					RenderingServer.call_on_render_thread(_gpu_generation.set_solver_crest_enabled.bind(solver, index == 0 and _breakers_requested))
		_publish_crest_textures()
		return
	for solver in _solvers:
		if solver != null:
			if _gpu_generation != null:
				RenderingServer.call_on_render_thread(_gpu_generation.set_solver_crest_enabled.bind(solver, true))
	_publish_crest_textures()
	_update_crest_surface_state()


func set_crest_foam_profile(profile: OceanCrestFoamProfile) -> void:
	_crest_foam_profile = profile
	var values := _crest_profile_or_default()
	for index in _solvers.size():
		if _solvers[index] == null: continue
		var resolution: int = _crest_resolutions[index] if index < _crest_resolutions.size() else 0
		var settings: Array = _crest_settings_for_index(values, index, resolution)
		if _gpu_generation != null:
			RenderingServer.call_on_render_thread(_gpu_generation.set_solver_crest_settings.bind(_solvers[index], settings))
	if _surface_initialized: _surface.set_crest_foam_profile(values)


func set_surface_foam_profile(profile: OceanSurfaceFoamProfile) -> void:
	_surface_foam_profile = profile
	var values := _surface_profile_or_default()
	if _surface != null: _surface.set_surface_foam_profile(values)
	if _surface_foam != null:
		RenderingServer.call_on_render_thread(_surface_foam.set_profile.bind(values))


func get_cascade_runtime_state() -> Dictionary:
	var bands: Array = []
	for index in 3:
		var band := _band_for_index(index)
		var solver = _solvers[index] if index < _solvers.size() else null
		var resources: Dictionary = solver.get_publication_snapshot() if solver != null else {
			"solver": false,
			"h0": false,
			"fft_resources": false,
			"displacement": false,
			"normal": false,
			"dispatch": false,
		}
		var solver_ready: bool = bool(resources.get("ready", resources.get("solver", false)))
		bands.append({
			"name": ["LONG", "MID", "SHORT"][index],
			"requested": _cascade_state.requested_is_active(band),
			"effective": _cascade_state.is_active(band),
			"solver": solver_ready,
			"displacement": "REAL" if _textures.size() > index and _textures[index] != _neutral_displacement_texture else "NEUTRAL",
			"normal": "REAL" if _normal_textures.size() > index and _normal_textures[index] != _neutral_normal_texture else "NEUTRAL",
			"dispatch": solver_ready,
			"resources": resources,
		})
	return {
		"mode": _cascade_state.mode_name(),
		"requested_mask": _cascade_state.requested_mask,
		"effective_mask": _cascade_state.effective_mask,
		"features": {
			"surface_foam": {
				"requested": _surface_foam_requested,
				"runtime_active": _surface_foam != null,
				"reason": "" if _surface_foam != null or not _surface_foam_requested else "MID_UNAVAILABLE",
			},
			"coastal_waves": {
				"requested": _coastal_waves_requested,
				"runtime_active": _coastal_waves_requested and _cascade_state.is_active(CascadeState.LONG),
				"reason": "" if not _coastal_waves_requested or _cascade_state.is_active(CascadeState.LONG) else "LONG_UNAVAILABLE",
			},
		},
		"bands": bands,
	}


func get_fft_resource_lifecycle_state() -> Dictionary:
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	var bands: Array = []
	for index in 3:
		var solver = _solvers[index] if index < _solvers.size() else null
		var solver_snapshot: Dictionary = solver.get_publication_snapshot() if solver != null else {}
		var displacement := _textures[index].texture_rd_rid if index < _textures.size() and _textures[index] != null else RID()
		var normal := _normal_textures[index].texture_rd_rid if index < _normal_textures.size() and _normal_textures[index] != null else RID()
		var crest := _crest_foam_textures[index].texture_rd_rid if index < _crest_foam_textures.size() and _crest_foam_textures[index] != null else RID()
		bands.append({
			"solver_generation": int(solver_snapshot.get("generation", -1)),
			"solver_ready": bool(solver_snapshot.get("ready", false)),
			"solver_error": String(solver_snapshot.get("error", "")),
			"crest_ready": bool(solver_snapshot.get("crest_ready", false)),
			"displacement_valid": displacement.is_valid(),
			"normal_valid": normal.is_valid(),
			"crest_valid": crest.is_valid(),
			"displacement_rid": displacement,
			"normal_rid": normal,
			"crest_rid": crest,
			"solver_displacement_rid": solver_snapshot.get("displacement_rid", RID()),
			"solver_normal_rid": solver_snapshot.get("normal_rid", RID()),
			"solver_crest_rid": solver_snapshot.get("crest_foam_rid", RID()),
			"published_displacement": _published_displacement_rids[index] if index < _published_displacement_rids.size() else RID(),
			"published_normal": _published_normal_rids[index] if index < _published_normal_rids.size() else RID(),
			"published_crest": _published_crest_rids[index] if index < _published_crest_rids.size() else RID(),
		})
	return {
		"generation": int(generation_snapshot.get("generation", -1)),
		"generation_sequence": int(generation_snapshot.get("sequence", -1)),
		"generation_active": bool(generation_snapshot.get("active", false)),
		"neutral_ready": bool(generation_snapshot.get("neutral_ready", false)),
		"neutral_error": String(generation_snapshot.get("neutral_error", "")),
		"neutral_displacement_rid": generation_snapshot.get("neutral_displacement_rid", RID()),
		"neutral_normal_rid": generation_snapshot.get("neutral_normal_rid", RID()),
		"neutral_crest_rid": generation_snapshot.get("neutral_crest_rid", RID()),
		"published_generation": _published_generation,
		"gpu_publication_generation": int(generation_snapshot.get("generation", -1)),
		"gpu_publication_revision": int(generation_snapshot.get("publication_revision", 0)),
		"fft_publication_ready": bool(generation_snapshot.get("neutral_ready", false)) and _published_generation == int(generation_snapshot.get("generation", -1)),
		"crest_publication_ready": _crest_foam_requested and _all_crest_rids_valid(),
		"surface_foam_publication_revision": int((_surface_foam.get_publication_snapshot() if _surface_foam != null else {}).get("publication_revision", 0)),
		"surface_foam_completed_jobs": int((_surface_foam.get_publication_snapshot() if _surface_foam != null else {}).get("completed_jobs", 0)),
		"stale_publication_rejections": _stale_publication_rejections,
		"borrowed_rd_cache_hits": _borrowed_rd_cache_hits,
		"borrowed_rd_cache_misses": _borrowed_rd_cache_misses,
		"borrowed_rd_conversions": _borrowed_rd_conversions,
		"borrowed_rd_cache_entries": _borrowed_coastal_rd_cache.size(),
		"borrowed_rd_cache_keys": _borrowed_coastal_rd_cache.keys(),
		"surface_initialized": _surface_initialized,
		"crest_requested": _crest_foam_requested,
		"crest_surface_enabled": _surface_initialized and _surface.get_runtime_feature_state().get("crest_foam", false),
		"surface_foam_ready": _surface_foam != null and bool(_surface_foam.get_publication_snapshot().get("ready", false)),
		"surface_foam_error": String((_surface_foam.get_publication_snapshot() if _surface_foam != null else {}).get("error", "")),
		"ocean_space": get_ocean_space_contract(),
		"bands": bands,
	}


func print_cascade_runtime_graph() -> void:
	var state := get_cascade_runtime_state()
	print("FFT CASCADES | requested=%s effective=%d" % [state.mode, state.effective_mask])
	for band in state.bands:
		print("  %s | requested=%s effective=%s solver=%s displacement=%s normal=%s dispatch=%s" % [band.name, band.requested, band.effective, band.solver, band.displacement, band.normal, band.dispatch])


func set_surface_foam(enabled: bool) -> void:
	_surface_foam_requested = enabled
	if enabled:
		if _surface_foam == null and _solvers.size() >= 2 and _solvers[1] != null:
			_create_surface_foam(_simulation_seed, _mid_resolution)
	else:
		_free_surface_foam()


func _create_surface_foam(seed: int, mid_resolution: int) -> void:
	if _surface_foam != null or _solvers.size() < 2 or _solvers[1] == null: return
	_surface_foam = SurfaceFoam.new()
	_surface_foam_generation += 1
	_surface_foam_published = false
	var foam := _surface_foam
	RenderingServer.call_on_render_thread(_initialize_surface_foam.bind(foam, _surface_foam_generation, seed, mid_resolution, _surface_profile_or_default()))


func _initialize_surface_foam(foam, generation: int, seed: int, mid_resolution: int, profile: OceanSurfaceFoamProfile) -> void:
	if foam == null:
		return
	if generation != _surface_foam_generation or _solvers.size() < 2 or _solvers[1] == null:
		foam.shutdown()
		return
	var mid_solver = _solvers[1]
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	var mid_snapshot: Dictionary = mid_solver.get_publication_snapshot()
	var current_generation: int = int(generation_snapshot.get("generation", -1))
	var mid_generation: int = int(mid_snapshot.get("generation", -1))
	var mid_displacement: RID = mid_snapshot.get("displacement_rid", RID())
	if _gpu_generation == null or not bool(generation_snapshot.get("active", false)) or not bool(mid_snapshot.get("ready", false)) or mid_generation != current_generation or not mid_displacement.is_valid():
		foam.shutdown()
		return
	# This callback is queued after MID solver initialization and therefore binds
	# the current MID displacement RID on the render thread, never a stale one.
	foam.set_profile(profile)
	foam.initialize(seed, mid_displacement, mid_resolution)


func _publish_surface_foam_if_ready() -> void:
	if _surface_foam == null or not _surface_initialized: return
	var snapshot: Dictionary = _surface_foam.get_publication_snapshot()
	if not bool(snapshot.get("ready", false)):
		var error: String = String(snapshot.get("error", ""))
		if not error.is_empty(): push_error("Ocean Surface Foam: %s" % error)
		return
	var field: RID = snapshot.get("field_rid", RID())
	var topology: RID = snapshot.get("topology_rid", RID())
	var mid_history: RID = snapshot.get("mid_history_rid", RID())
	if not field.is_valid() or not topology.is_valid() or not mid_history.is_valid():
		return
	_set_surface_foam_texture_rid(_surface_foam_field, field, 0)
	_set_surface_foam_texture_rid(_surface_foam_topology, topology, 1)
	_set_surface_foam_texture_rid(_surface_foam_mid_history, mid_history, 2)
	if not _surface_foam_published:
		_surface.set_surface_foam(_surface_foam_field, _surface_foam_topology, _surface_foam_mid_history, true)
	_surface_foam_published = true


func _set_surface_foam_texture_rid(texture: Texture2DRD, rid: RID, index: int) -> void:
	if index < 0 or index >= _surface_foam_published_rids.size(): return
	if _surface_foam_published_rids[index] == rid: return
	texture.texture_rd_rid = rid
	_surface_foam_published_rids[index] = rid


func _free_surface_foam() -> void:
	_surface_foam_generation += 1
	if _surface_initialized: _surface.set_surface_foam(null, null, null, false)
	_set_surface_foam_texture_rid(_surface_foam_field, RID(), 0)
	_set_surface_foam_texture_rid(_surface_foam_topology, RID(), 1)
	_set_surface_foam_texture_rid(_surface_foam_mid_history, RID(), 2)
	if _surface_foam != null:
		var foam := _surface_foam
		RenderingServer.call_on_render_thread(foam.shutdown)
		_surface_foam = null
	_surface_foam_published = false


func shutdown() -> void:
	_enabled = false
	set_process(false)
	visible = false
	_clipmap_quality = null
	set_spindrift_enabled(false, null, 0)
	set_reflections(false, null)
	if _sspr != null:
		var sspr := _sspr
		sspr.shutdown()
		sspr.queue_free()
		_sspr = null
	_free_surface_foam()
	if _surface != null:
		_surface.set_coastal_data({})
		_surface.shutdown()
		_surface.queue_free()
		_surface = null
	_surface_initialized = false
	_camera_surface_signed_distance_m = 1.0
	if _coastal_runtime != null:
		_coastal_runtime.clear()
		_coastal_runtime = null
	_clear_borrowed_coastal_rd_cache()
	for index in _textures.size(): _set_texture_rid(_textures[index], RID(), _published_displacement_rids, index)
	for index in _normal_textures.size(): _set_texture_rid(_normal_textures[index], RID(), _published_normal_rids, index)
	for index in _crest_foam_textures.size(): _set_texture_rid(_crest_foam_textures[index], RID(), _published_crest_rids, index)
	_breaker_lifecycle_texture.texture_rd_rid = RID()
	_published_breaker_lifecycle_rid = RID()
	_breaker_lifecycle_retire_pending = false
	_breaker_lifecycle_retire_revision = -1
	_breaker_multiphase_vdm_texture.texture_rd_rid = RID()
	_published_breaker_multiphase_vdm_rid = RID()
	for solver in _solvers:
		if solver != null:
			RenderingServer.call_on_render_thread(solver.shutdown)
	_solvers.clear()
	_wave_configs.clear()
	_textures.clear()
	_normal_textures.clear()
	_crest_foam_textures.clear()
	_crest_resolutions.clear()
	_published_displacement_rids.clear()
	_published_normal_rids.clear()
	_published_crest_rids.clear()
	_published_generation = -1
	_fft_displacement_bounds = Vector3.ZERO
	_neutral_displacement_rid = RID()
	_neutral_normal_rid = RID()
	_crest_neutral_rid = RID()
	_neutral_displacement_texture.texture_rd_rid = RID()
	_neutral_normal_texture.texture_rd_rid = RID()
	_crest_neutral_texture.texture_rd_rid = RID()
	if _gpu_generation != null:
		var retired_generation := _gpu_generation
		retired_generation.retire()
		RenderingServer.call_on_render_thread(retired_generation.shutdown_gpu)
		_gpu_generation = null


func set_optics(enabled: bool, profile: Resource) -> void:
	_optics_requested = enabled
	_optics_profile = profile
	if _surface_initialized:
		_surface.set_optics(enabled, profile)


func set_optics_profile(profile: OceanOpticsProfile) -> void:
	_optics_profile = profile
	if _surface_initialized:
		_surface.set_optics_profile(profile)


func set_snell_profile(profile: Resource) -> void:
	_snell_profile = profile
	if _surface_initialized:
		_surface.set_snell_profile(profile)
	if _sspr != null and _sspr.has_method(&"set_runtime_active"):
		_sspr.set_runtime_active(_sspr_should_be_runtime_active())


func _sspr_should_be_runtime_active() -> bool:
	var snell_tir_requested: bool = _snell_profile != null and _snell_profile.snell_tir_enabled
	return _reflections_requested and (_runtime_water_state != &"UNDERWATER_SAFE" or snell_tir_requested)


func set_reflections(enabled: bool, profile: Resource) -> void:
	_reflections_requested = enabled
	_reflection_profile = profile as OceanReflectionProfile
	if not enabled:
		# Material fallback first; keep SSPR resident so a later enable reuses it.
		if _surface_initialized: _surface.set_reflections(false, profile)
		if _sspr != null and _sspr.has_method(&"set_runtime_active"):
			_sspr.set_runtime_active(false)
		return
	var values: OceanReflectionProfile = profile as OceanReflectionProfile
	if values == null:
		values = ReflectionProfile.new()
	_reflection_profile = values
	if not _surface_initialized:
		return
	_surface.set_reflections(true, values)
	if _sspr == null:
		_sspr = OceanSSPR.new()
		_sspr.name = &"OceanSSPR"
		add_child(_sspr)
		_sspr.configure(_surface, _sea_level, values)
	else:
		_sspr.update(_sea_level, values)
	if _sspr.has_method(&"set_runtime_active"):
		_sspr.set_runtime_active(_sspr_should_be_runtime_active())


func set_reflection_profile(profile: OceanReflectionProfile) -> void:
	var values := profile if profile != null else ReflectionProfile.new()
	_reflection_profile = values
	if _surface_initialized:
		_surface.set_reflection_profile(values)
	if _sspr != null:
		_sspr.update(_sea_level, values)


func set_surface_detail(enabled: bool, profile: OceanSurfaceDetailProfile) -> void:
	_surface_detail_requested = enabled
	_surface_detail_profile = profile
	if _surface_initialized:
		_surface.set_surface_detail(enabled, profile)


func set_surface_detail_profile(profile: OceanSurfaceDetailProfile) -> void:
	_surface_detail_profile = profile
	if _surface_initialized:
		_surface.set_surface_detail_profile(profile)


func _process(delta: float) -> void:
	if not _enabled: return
	_wave_time += maxf(delta, 0.0) * _wave_speed_multiplier
	if _surface_initialized:
		_surface.set_wave_time(_wave_time)
	_publish_fft_textures_if_ready()
	for index in _solvers.size():
		var solver = _solvers[index]
		if solver == null: continue
		RenderingServer.call_on_render_thread(solver.dispatch.bind(_wave_time, delta))
	_publish_crest_textures()
	_publish_breaker_lifecycle_texture()
	_update_crest_surface_state()
	if _surface_foam != null:
		RenderingServer.call_on_render_thread(_surface_foam.advance.bind(delta, _wave_time))
		_publish_surface_foam_if_ready()


func get_spindrift_sources() -> Dictionary:
	if _textures.size() != 3 or _normal_textures.size() != 3 or _wave_configs.size() != 3:
		return {"ready": false}
	var all_ready := true
	for texture in _textures + _normal_textures + [_crest_foam_textures[0] if _crest_foam_textures.size() > 0 else null]:
		if texture == null or not texture.texture_rd_rid.is_valid():
			all_ready = false
	return {
		"ready": all_ready,
		# OpenOceanBreakingActivity is intentionally the G channel of the LONG
		# Crest texture. R remains residual foam and is not an event authority.
		"breaking_activity_long": _crest_foam_textures[0] if _crest_foam_textures.size() > 0 else null,
		"breaking_activity_channel": 1,
		"breaking_activity_range": Vector2(0.0, 1.0),
		"breaking_activity_generation": _published_generation,
		"displacement_long": _textures[0],
		"displacement_mid": _textures[1],
		"displacement_short": _textures[2],
		"normal_long": _normal_textures[0],
		"normal_mid": _normal_textures[1],
		"normal_short": _normal_textures[2],
		"crest_foam_long": _crest_foam_textures[0],
		"domains": _ocean_space.ocean_domains(Vector3(_wave_configs[0].domain_size_m, _wave_configs[1].domain_size_m, _wave_configs[2].domain_size_m)),
		"ocean_space": _ocean_space.as_dictionary(),
	}


func _publish_fft_textures_if_ready() -> bool:
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	var generation_id: int = int(generation_snapshot.get("generation", -1))
	if _gpu_generation == null or not bool(generation_snapshot.get("active", false)) or not bool(generation_snapshot.get("neutral_ready", false)):
		return false
	var neutral_displacement: RID = generation_snapshot.get("neutral_displacement_rid", RID())
	var neutral_normal: RID = generation_snapshot.get("neutral_normal_rid", RID())
	var neutral_crest: RID = generation_snapshot.get("neutral_crest_rid", RID())
	if not neutral_displacement.is_valid() or not neutral_normal.is_valid() or not neutral_crest.is_valid():
		return false
	var displacement_rids: Array[RID] = []
	var normal_rids: Array[RID] = []
	var crest_rids: Array[RID] = []
	for index in 3:
		var solver = _solvers[index] if index < _solvers.size() else null
		if solver == null:
			displacement_rids.append(neutral_displacement)
			normal_rids.append(neutral_normal)
			crest_rids.append(neutral_crest)
			continue
		var solver_snapshot: Dictionary = solver.get_publication_snapshot()
		if int(solver_snapshot.get("generation", -1)) != generation_id or not bool(solver_snapshot.get("ready", false)):
			_stale_publication_rejections += 1 if int(solver_snapshot.get("generation", -1)) != generation_id else 0
			return false
		var solver_displacement: RID = solver_snapshot.get("displacement_rid", RID())
		var solver_normal: RID = solver_snapshot.get("normal_rid", RID())
		if not solver_displacement.is_valid() or not solver_normal.is_valid():
			return false
		displacement_rids.append(solver_displacement)
		normal_rids.append(solver_normal)
		crest_rids.append(neutral_crest)

	_neutral_displacement_rid = neutral_displacement
	_neutral_normal_rid = neutral_normal
	_crest_neutral_rid = neutral_crest
	if _neutral_displacement_texture.texture_rd_rid != _neutral_displacement_rid:
		_neutral_displacement_texture.texture_rd_rid = _neutral_displacement_rid
	if _neutral_normal_texture.texture_rd_rid != _neutral_normal_rid:
		_neutral_normal_texture.texture_rd_rid = _neutral_normal_rid
	if _crest_neutral_texture.texture_rd_rid != _crest_neutral_rid:
		_crest_neutral_texture.texture_rd_rid = _crest_neutral_rid
	for index in 3:
		_set_texture_rid(_textures[index], displacement_rids[index], _published_displacement_rids, index)
		_set_texture_rid(_normal_textures[index], normal_rids[index], _published_normal_rids, index)
		# Crest starts on a valid neutral texture. A later crest publication may
		# replace only this slot once its accumulator is ready.
		_set_texture_rid(_crest_foam_textures[index], crest_rids[index], _published_crest_rids, index)
	_published_generation = generation_id
	_publish_breaker_multiphase_vdm_texture()
	_publish_breaker_lifecycle_texture()
	_ensure_surface_initialized()
	return true


func _ensure_surface_initialized() -> void:
	if _surface_initialized or _surface == null or _gpu_generation == null:
		return
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot()
	if _published_generation != int(generation_snapshot.get("generation", -1)):
		return
	_surface.initialize(_clipmap_quality, _sea_level, _wave_configs, _textures, _normal_textures, _crest_foam_textures, _fft_displacement_bounds)
	_surface.set_breaker_lifecycle_texture(_breaker_lifecycle_texture)
	if _breaker_multiphase_vdm_texture.texture_rd_rid.is_valid():
		_surface.set_breaker_multiphase_vdm_texture(_breaker_multiphase_vdm_texture)
	_surface.set_wave_time(_wave_time)
	_surface_initialized = true
	_surface.set_surface_scale(_surface_scale)
	_surface.set_clipmap_geometry_scale(_clipmap_geometry_scale)
	_surface.set_ocean_space_contract(_ocean_space.as_dictionary())
	_surface.set_debug_view(_debug_view)
	_surface.set_crest_foam_profile(_crest_profile_or_default())
	_surface.set_surface_foam_profile(_surface_profile_or_default())
	_surface.set_runtime_water_state(_runtime_water_state)
	_surface.set_camera_surface_signed_distance(_camera_surface_signed_distance_m)
	_surface.set_coastal_data(_coastal_data, _coastal_waves_active)
	_surface.set_crest_foam_enabled(false)
	_apply_surface_feature_state()
	_surface.visible = _enabled


func _apply_surface_feature_state() -> void:
	if not _surface_initialized:
		return
	_surface.set_optics(_optics_requested, _optics_profile)
	_surface.set_snell_profile(_snell_profile)
	_surface.set_surface_detail(_surface_detail_requested, _surface_detail_profile)
	_surface.set_breakers(_breakers_requested, _breaker_profile)
	_surface.set_breaker_profile(_breaker_profile)
	_surface.set_local_breaker_refinement_enabled(_local_breaker_refinement_enabled)
	_surface.set_local_breaker_refinement_authority(_local_breaker_refinement_authority)
	if _reflections_requested:
		_configure_reflections()
	else:
		_surface.set_reflections(false, _reflection_profile)


func _configure_reflections() -> void:
	if not _surface_initialized:
		return
	var values := _reflection_profile if _reflection_profile != null else ReflectionProfile.new()
	_surface.set_reflections(true, values)
	if _sspr == null:
		_sspr = OceanSSPR.new()
		_sspr.name = &"OceanSSPR"
		add_child(_sspr)
		_sspr.configure(_surface, _sea_level, values)
	else:
		_sspr.update(_sea_level, values)
	if _sspr.has_method(&"set_runtime_active"):
		_sspr.set_runtime_active(_sspr_should_be_runtime_active())


func _set_texture_rid(texture: Texture2DRD, rid: RID, cache: Array[RID], index: int) -> void:
	if texture == null or index < 0 or index >= cache.size() or cache[index] == rid:
		return
	texture.texture_rd_rid = rid
	cache[index] = rid


func _publish_crest_textures() -> void:
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	var generation_id: int = int(generation_snapshot.get("generation", -1))
	if _gpu_generation == null or not bool(generation_snapshot.get("active", false)) or not bool(generation_snapshot.get("neutral_ready", false)):
		return
	var neutral_crest: RID = generation_snapshot.get("neutral_crest_rid", RID())
	if not neutral_crest.is_valid():
		return
	for index in _crest_foam_textures.size():
		var solver = _solvers[index] if index < _solvers.size() else null
		var rid: RID = neutral_crest
		if (_crest_foam_requested or (index == 0 and _breakers_requested)) and solver != null:
			var solver_snapshot: Dictionary = solver.get_publication_snapshot()
			var solver_crest: RID = solver_snapshot.get("crest_foam_rid", RID())
			if int(solver_snapshot.get("generation", -1)) == generation_id and bool(solver_snapshot.get("ready", false)) and bool(solver_snapshot.get("crest_ready", false)) and solver_crest.is_valid():
				rid = solver_crest
		_set_texture_rid(_crest_foam_textures[index], rid, _published_crest_rids, index)


func _publish_breaker_lifecycle_texture() -> bool:
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	var generation_id: int = int(generation_snapshot.get("generation", -1))
	if _gpu_generation == null or not bool(generation_snapshot.get("active", false)) or not bool(generation_snapshot.get("neutral_ready", false)):
		return false
	var rid: RID = generation_snapshot.get("neutral_crest_rid", RID())
	if not rid.is_valid():
		return false
	var solver_retire_pending := false
	if _breakers_requested and not _solvers.is_empty() and _solvers[0] != null:
		var snapshot: Dictionary = _solvers[0].get_publication_snapshot()
		var lifecycle_rid: RID = snapshot.get("breaker_lifecycle_rid", RID())
		if int(snapshot.get("generation", -1)) == generation_id and bool(snapshot.get("breaker_lifecycle_ready", false)) and lifecycle_rid.is_valid():
			rid = lifecycle_rid
	elif not _solvers.is_empty() and _solvers[0] != null:
		var snapshot: Dictionary = _solvers[0].get_publication_snapshot()
		solver_retire_pending = int(snapshot.get("generation", -1)) == generation_id and bool(snapshot.get("breaker_lifecycle_retire_pending", false))
	if rid != _published_breaker_lifecycle_rid:
		_breaker_lifecycle_texture.texture_rd_rid = rid
		_published_breaker_lifecycle_rid = rid
		_breaker_lifecycle_publication_revision += 1
		if _surface_initialized:
			_surface.set_breaker_lifecycle_texture(_breaker_lifecycle_texture)
	if not _breakers_requested and solver_retire_pending and not _breaker_lifecycle_retire_pending:
		_breaker_lifecycle_retire_pending = true
		_breaker_lifecycle_retire_revision = _breaker_lifecycle_publication_revision
	return _breaker_lifecycle_texture.texture_rd_rid.is_valid()


func _publish_breaker_multiphase_vdm_texture() -> void:
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	if _gpu_generation == null or not bool(generation_snapshot.get("active", false)) or not bool(generation_snapshot.get("breaker_multiphase_vdm_ready", false)):
		return
	var rid: RID = generation_snapshot.get("breaker_multiphase_vdm_rid", RID())
	if not rid.is_valid() or rid == _published_breaker_multiphase_vdm_rid:
		return
	_breaker_multiphase_vdm_texture.texture_rd_rid = rid
	_published_breaker_multiphase_vdm_rid = rid
	if _surface_initialized:
		_surface.set_breaker_multiphase_vdm_texture(_breaker_multiphase_vdm_texture)


func _publish_crest_neutral_textures() -> void:
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	if _gpu_generation == null or not bool(generation_snapshot.get("active", false)) or not bool(generation_snapshot.get("neutral_ready", false)):
		return
	var neutral_crest: RID = generation_snapshot.get("neutral_crest_rid", RID())
	if not neutral_crest.is_valid():
		return
	for index in _crest_foam_textures.size():
		_set_texture_rid(_crest_foam_textures[index], neutral_crest, _published_crest_rids, index)


func _all_crest_rids_valid() -> bool:
	var generation_snapshot: Dictionary = _gpu_generation.get_publication_snapshot() if _gpu_generation != null else {}
	var generation_id: int = int(generation_snapshot.get("generation", -1))
	if _gpu_generation == null or not bool(generation_snapshot.get("active", false)) or not bool(generation_snapshot.get("neutral_ready", false)) or _solvers.size() != 3:
		return false
	for solver in _solvers:
		if solver != null:
			var solver_snapshot: Dictionary = solver.get_publication_snapshot()
			var crest_rid: RID = solver_snapshot.get("crest_foam_rid", RID())
			if int(solver_snapshot.get("generation", -1)) != generation_id or not bool(solver_snapshot.get("ready", false)) or not bool(solver_snapshot.get("crest_ready", false)) or not crest_rid.is_valid():
				return false
		if solver == null:
			return false
	return true


func _update_crest_surface_state() -> void:
	if not _surface_initialized:
		return
	_surface.set_crest_foam_enabled(_crest_foam_requested and _all_crest_rids_valid())


func _band_for_index(index: int) -> int:
	return [CascadeState.LONG, CascadeState.MID, CascadeState.SHORT][clampi(index, 0, 2)]


func _crest_profile_or_default() -> OceanCrestFoamProfile:
	return _crest_foam_profile if _crest_foam_profile != null else CrestFoamProfile.new()


func _surface_profile_or_default() -> OceanSurfaceFoamProfile:
	return _surface_foam_profile if _surface_foam_profile != null else SurfaceFoamProfile.new()


func _crest_settings_for_index(profile: OceanCrestFoamProfile, index: int, resolution: int) -> Array:
	var settings: Array = [
		[profile.long_whitecap_threshold, profile.long_amount, profile.long_decay, profile.long_weight],
		[profile.mid_whitecap_threshold, profile.mid_amount, profile.mid_decay, profile.mid_weight],
		[profile.short_whitecap_threshold, profile.short_amount, profile.short_decay, profile.short_weight]
	][clampi(index, 0, 2)]
	return [settings[0], settings[1], settings[2], settings[3], resolution]
