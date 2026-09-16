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
const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")
const SpindriftController := preload("res://addons/ocean/spindrift/ocean_spindrift_v4.gd")

var _solvers: Array = []
var _wave_configs: Array = []
var _clipmap_quality: Resource
var _textures: Array[Texture2DRD] = []
var _normal_textures: Array[Texture2DRD] = []
var _crest_foam_textures: Array[Texture2DRD] = []
var _crest_resolutions: Array[int] = []
var _crest_neutral_texture := Texture2DRD.new()
var _crest_neutral_rid := RID()
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
var _surface_initialized := false
var _published_displacement_rids: Array[RID] = []
var _published_normal_rids: Array[RID] = []
var _published_crest_rids: Array[RID] = []
var _crest_foam_requested := false
var _surface_scale := 1.0
var _clipmap_geometry_scale := 1.0
var _debug_view := 0
var _optics_requested := false
var _optics_profile: Resource
var _reflections_requested := false
var _reflection_profile: OceanReflectionProfile
var _surface_detail_requested := false
var _surface_detail_profile: OceanSurfaceDetailProfile
var _breaker_profile: OceanBreakerProfile
var _coastal_data: Dictionary = {}
var _coastal_waves_active := true
var _surface_foam_requested := false
var _coastal_waves_requested := false
var _breakers_requested := false
var _local_breaker_refinement_enabled := false
var _local_breaker_refinement_authority: Dictionary = {}
var _runtime_water_state: StringName = &"TRANSITION"
var _spindrift: OceanSpindriftV4
var _wind_speed_mps := 18.0
var _wind_direction_degrees := 0.0


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
	var weighted_variance: float = 0.0
	for index in configs.size():
		var config = configs[index]
		if not _cascade_state.is_active(_band_for_index(index)):
			raw_h0.append(PackedByteArray())
			continue
		var raw: PackedByteArray = Spectrum.build_h0_rgba32f(config, Spectrum.derive_cascade_seed(seed, config.id), false)
		# WIND_DRIVEN uses the natural band-pass spectrum.  The per-band Hs values
		# are legacy/manual targets and must not suppress MID/SHORT as weights.
		var legacy_amplitude: float = 1.0 if overall_hs_m < 0.0 else float(config.target_hs_m / global_target_hs if global_target_hs > 0.0000001 else 0.0)
		var band_scale: float = [long_band_scale, mid_band_scale, short_band_scale][index] if overall_hs_m < 0.0 else 1.0
		var relative_amplitude: float = legacy_amplitude * band_scale
		if index == 1:
			relative_amplitude *= clampf(mid_fill_amount, 0.0, 1.5)
		raw = Spectrum.scale_packed_h0(raw, relative_amplitude)
		raw_h0.append(raw)
		weighted_variance += pow(config.measured_hs_m * relative_amplitude / 4.0, 2.0)
	var common_scale: float = wave_height_scale if overall_hs_m < 0.0 else float(global_target_hs / (4.0 * sqrt(weighted_variance)) if weighted_variance > 0.0000000001 else 0.0)
	var generation := _gpu_generation
	RenderingServer.call_on_render_thread(generation.create_neutral_resources)
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


func set_debug_view(value: int) -> void:
	_debug_view = clampi(value, 0, 1)
	if _surface_initialized: _surface.set_debug_view(_debug_view)


func set_surface_scale(value: float) -> void:
	_surface_scale = value
	if _surface_initialized:
		_surface.set_surface_scale(_surface_scale)


func set_clipmap_geometry_scale(value: float) -> void:
	_clipmap_geometry_scale = value
	if _surface_initialized:
		_surface.set_clipmap_geometry_scale(_clipmap_geometry_scale)


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
	return {
		"long": rids[0],
		"mid": rids[1],
		"short": rids[2],
		"domains": Vector3(_wave_configs[0].domain_size_m, _wave_configs[1].domain_size_m, _wave_configs[2].domain_size_m),
		"long_fade": _clipmap_quality.long_fade_range_m,
		"mid_fade": _clipmap_quality.mid_fade_range_m,
		"short_fade": _clipmap_quality.short_fade_range_m,
	}


func get_runtime_feature_state() -> Dictionary:
	var surface_state: Dictionary = _surface.get_runtime_feature_state() if _surface != null and _surface.has_method(&"get_runtime_feature_state") else {}
	return {
		"surface_present": _surface != null and is_instance_valid(_surface),
		"shader_variant_key": surface_state.get("shader_variant_key", ""),
		"crest_foam": surface_state.get("crest_foam", false),
		"surface_foam": surface_state.get("surface_foam", false),
		"optics": surface_state.get("optics", false),
		"reflections": surface_state.get("reflections", false),
		"surface_detail": surface_state.get("surface_detail", false),
		"breakers_requested": _breakers_requested,
		"breakers": surface_state.get("breakers", false),
		"sspr": surface_state.get("reflections", false) and _sspr != null and is_instance_valid(_sspr),
		"runtime_water_state": String(_runtime_water_state),
		"sspr_runtime_active": surface_state.get("reflections", false) and _sspr != null,
		"optics_runtime_active": surface_state.get("optics", false),
		"surface_detail_runtime_active": surface_state.get("surface_detail", false),
		"breakers_runtime_active": surface_state.get("breakers", false),
		"local_breaker_refinement_enabled": surface_state.get("local_breaker_refinement_enabled", false),
		"local_breaker_refinement": surface_state.get("local_breaker_refinement", {}),
		"surface_foam_presentation_active": surface_state.get("surface_foam", false),
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
		_surface.set_surface_foam_presentation(state != &"UNDERWATER_SAFE")
	if _sspr != null and _sspr.has_method(&"set_runtime_active"):
		_sspr.set_runtime_active(state != &"UNDERWATER_SAFE")
	if _surface_foam != null:
		var update_hz := 10.0 if state == &"UNDERWATER_SAFE" else 30.0
		RenderingServer.call_on_render_thread(_surface_foam.set_update_hz.bind(update_hz))


func set_coastal(enabled: bool, bake: Resource) -> void:
	_coastal_waves_requested = enabled
	var waves_active := enabled and _cascade_state.is_active(CascadeState.LONG)
	_coastal_waves_active = waves_active
	if not enabled and bake == null:
		if _coastal_runtime != null:
			_coastal_runtime.clear()
		_coastal_data = {}
		if _surface_initialized: _surface.set_coastal_data(_coastal_data, waves_active)
		return
	if bake == null:
		if _coastal_runtime != null:
			_coastal_runtime.clear()
		_coastal_data = {}
		if _surface_initialized: _surface.set_coastal_data(_coastal_data, waves_active)
		return
	if _coastal_runtime == null: _coastal_runtime = CoastalRuntime.new()
	# The real-seabed bake has independent P4 optical authority.  We keep it
	# available with Coastal waves off, while only the wave material route obeys
	# `enabled`.
	_coastal_data = _coastal_runtime.activate(bake)
	if _surface_initialized: _surface.set_coastal_data(_coastal_data, waves_active)


func set_breakers(enabled: bool, profile: OceanBreakerProfile) -> void:
	_breakers_requested = enabled
	_breaker_profile = profile
	if _surface_initialized:
		_surface.set_breakers(enabled, profile)


func set_breaker_profile(profile: OceanBreakerProfile) -> void:
	_breaker_profile = profile
	if _surface_initialized:
		_surface.set_breaker_profile(profile)


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
		_publish_crest_neutral_textures()
		for solver in _solvers:
			if solver != null:
				if _gpu_generation != null:
					RenderingServer.call_on_render_thread(_gpu_generation.set_solver_crest_enabled.bind(solver, false))
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
		var resources: Dictionary = solver.get_runtime_resource_state() if solver != null else {
			"solver": false,
			"h0": false,
			"fft_resources": false,
			"displacement": false,
			"normal": false,
			"dispatch": false,
		}
		bands.append({
			"name": ["LONG", "MID", "SHORT"][index],
			"requested": _cascade_state.requested_is_active(band),
			"effective": _cascade_state.is_active(band),
			"solver": solver != null and solver.ready,
			"displacement": "REAL" if _textures.size() > index and _textures[index] != _neutral_displacement_texture else "NEUTRAL",
			"normal": "REAL" if _normal_textures.size() > index and _normal_textures[index] != _neutral_normal_texture else "NEUTRAL",
			"dispatch": solver != null and solver.ready,
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
	var generation := _gpu_generation
	var bands: Array = []
	for index in 3:
		var solver = _solvers[index] if index < _solvers.size() else null
		var displacement := _textures[index].texture_rd_rid if index < _textures.size() and _textures[index] != null else RID()
		var normal := _normal_textures[index].texture_rd_rid if index < _normal_textures.size() and _normal_textures[index] != null else RID()
		var crest := _crest_foam_textures[index].texture_rd_rid if index < _crest_foam_textures.size() and _crest_foam_textures[index] != null else RID()
		bands.append({
			"solver_generation": solver.generation if solver != null else -1,
			"solver_ready": solver != null and solver.ready,
			"solver_error": solver.last_error if solver != null else "",
			"crest_ready": solver != null and solver.crest_ready,
			"displacement_valid": displacement.is_valid(),
			"normal_valid": normal.is_valid(),
			"crest_valid": crest.is_valid(),
			"displacement_rid": displacement,
			"normal_rid": normal,
			"crest_rid": crest,
			"solver_displacement_rid": solver.displacement_rid if solver != null else RID(),
			"solver_normal_rid": solver.normal_rid if solver != null else RID(),
			"solver_crest_rid": solver.crest_foam_rid if solver != null else RID(),
			"published_displacement": _published_displacement_rids[index] if index < _published_displacement_rids.size() else RID(),
			"published_normal": _published_normal_rids[index] if index < _published_normal_rids.size() else RID(),
			"published_crest": _published_crest_rids[index] if index < _published_crest_rids.size() else RID(),
		})
	return {
		"generation": generation.generation if generation != null else -1,
		"generation_sequence": generation.sequence if generation != null else -1,
		"generation_active": generation != null and generation.active,
		"neutral_ready": generation != null and generation.neutral_ready,
		"neutral_error": generation.neutral_error if generation != null else "",
		"neutral_displacement_rid": generation.neutral_displacement_rid if generation != null else RID(),
		"neutral_normal_rid": generation.neutral_normal_rid if generation != null else RID(),
		"neutral_crest_rid": generation.neutral_crest_rid if generation != null else RID(),
		"published_generation": _published_generation,
		"surface_initialized": _surface_initialized,
		"crest_requested": _crest_foam_requested,
		"crest_surface_enabled": _surface_initialized and _surface.get_runtime_feature_state().get("crest_foam", false),
		"surface_foam_ready": _surface_foam != null and _surface_foam.ready,
		"surface_foam_error": _surface_foam.last_error if _surface_foam != null else "",
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
	if _gpu_generation == null or not _gpu_generation.active or not mid_solver.ready or mid_solver.generation != _gpu_generation.generation or not mid_solver.displacement_rid.is_valid():
		foam.shutdown()
		return
	# This callback is queued after MID solver initialization and therefore binds
	# the current MID displacement RID on the render thread, never a stale one.
	foam.set_profile(profile)
	foam.initialize(seed, mid_solver.displacement_rid, mid_resolution)


func _publish_surface_foam_if_ready() -> void:
	if _surface_foam == null or not _surface_initialized or _surface_foam_published: return
	if not _surface_foam.ready:
		if not _surface_foam.last_error.is_empty(): push_error("Ocean Surface Foam: %s" % _surface_foam.last_error)
		return
	_set_surface_foam_texture_rid(_surface_foam_field, _surface_foam.field_rid, 0)
	_set_surface_foam_texture_rid(_surface_foam_topology, _surface_foam.topology_rid, 1)
	_set_surface_foam_texture_rid(_surface_foam_mid_history, _surface_foam.mid_history_rid, 2)
	_surface.set_surface_foam(_surface_foam_field, _surface_foam_topology, _surface_foam_mid_history, true)
	_surface.set_surface_foam_presentation(_runtime_water_state != &"UNDERWATER_SAFE")
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
	_free_surface_foam()
	if _surface != null:
		_surface.set_coastal_data({})
		_surface.shutdown()
		_surface.queue_free()
		_surface = null
	_surface_initialized = false
	if _coastal_runtime != null:
		_coastal_runtime.clear()
		_coastal_runtime = null
	for index in _textures.size(): _set_texture_rid(_textures[index], RID(), _published_displacement_rids, index)
	for index in _normal_textures.size(): _set_texture_rid(_normal_textures[index], RID(), _published_normal_rids, index)
	for index in _crest_foam_textures.size(): _set_texture_rid(_crest_foam_textures[index], RID(), _published_crest_rids, index)
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


func set_reflections(enabled: bool, profile: Resource) -> void:
	_reflections_requested = enabled
	_reflection_profile = profile as OceanReflectionProfile
	if not enabled:
		# Material fallback first: no SSPR sampling can outlive a published RID.
		if _surface_initialized: _surface.set_reflections(false, profile)
		if _sspr != null:
			_sspr.shutdown()
			_sspr.queue_free()
			_sspr = null
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
		_sspr.set_runtime_active(_runtime_water_state != &"UNDERWATER_SAFE")


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
	_publish_fft_textures_if_ready()
	for index in _solvers.size():
		var solver = _solvers[index]
		if solver == null: continue
		RenderingServer.call_on_render_thread(solver.dispatch.bind(_wave_time, delta))
	_publish_crest_textures()
	_update_crest_surface_state()
	if _surface_foam != null:
		_surface_foam.set_wave_time(_wave_time)
		RenderingServer.call_on_render_thread(_surface_foam.advance.bind(delta))
		_publish_surface_foam_if_ready()
		if _surface_foam_published:
			_set_surface_foam_texture_rid(_surface_foam_field, _surface_foam.field_rid, 0)
			_set_surface_foam_texture_rid(_surface_foam_topology, _surface_foam.topology_rid, 1)
			_set_surface_foam_texture_rid(_surface_foam_mid_history, _surface_foam.mid_history_rid, 2)


func get_spindrift_sources() -> Dictionary:
	if _textures.size() != 3 or _normal_textures.size() != 3 or _wave_configs.size() != 3:
		return {"ready": false}
	var all_ready := true
	for texture in _textures + _normal_textures:
		if texture == null or not texture.texture_rd_rid.is_valid():
			all_ready = false
	return {
		"ready": all_ready,
		"displacement_long": _textures[0],
		"displacement_mid": _textures[1],
		"displacement_short": _textures[2],
		"normal_long": _normal_textures[0],
		"normal_mid": _normal_textures[1],
		"normal_short": _normal_textures[2],
		"crest_foam_long": _crest_foam_textures[0],
		"domains": Vector3(_wave_configs[0].domain_size_m, _wave_configs[1].domain_size_m, _wave_configs[2].domain_size_m),
	}


func _publish_fft_textures_if_ready() -> bool:
	var generation := _gpu_generation
	if generation == null or not generation.active or not generation.neutral_ready:
		return false
	var displacement_rids: Array[RID] = []
	var normal_rids: Array[RID] = []
	var crest_rids: Array[RID] = []
	for index in 3:
		var solver = _solvers[index] if index < _solvers.size() else null
		if solver == null:
			displacement_rids.append(generation.neutral_displacement_rid)
			normal_rids.append(generation.neutral_normal_rid)
			crest_rids.append(generation.neutral_crest_rid)
			continue
		if solver.generation != generation.generation or not solver.ready:
			return false
		if not solver.displacement_rid.is_valid() or not solver.normal_rid.is_valid():
			return false
		displacement_rids.append(solver.displacement_rid)
		normal_rids.append(solver.normal_rid)
		crest_rids.append(generation.neutral_crest_rid)

	_neutral_displacement_rid = generation.neutral_displacement_rid
	_neutral_normal_rid = generation.neutral_normal_rid
	_crest_neutral_rid = generation.neutral_crest_rid
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
	_published_generation = generation.generation
	_ensure_surface_initialized()
	return true


func _ensure_surface_initialized() -> void:
	if _surface_initialized or _surface == null or _gpu_generation == null:
		return
	if _published_generation != _gpu_generation.generation:
		return
	_surface.initialize(_clipmap_quality, _sea_level, _wave_configs, _textures, _normal_textures, _crest_foam_textures)
	_surface_initialized = true
	_surface.set_surface_scale(_surface_scale)
	_surface.set_clipmap_geometry_scale(_clipmap_geometry_scale)
	_surface.set_debug_view(_debug_view)
	_surface.set_crest_foam_profile(_crest_profile_or_default())
	_surface.set_surface_foam_profile(_surface_profile_or_default())
	_surface.set_runtime_water_state(_runtime_water_state)
	_surface.set_coastal_data(_coastal_data, _coastal_waves_active)
	_surface.set_crest_foam_enabled(false)
	_apply_surface_feature_state()
	_surface.visible = _enabled


func _apply_surface_feature_state() -> void:
	if not _surface_initialized:
		return
	_surface.set_optics(_optics_requested, _optics_profile)
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
		_sspr.set_runtime_active(_runtime_water_state != &"UNDERWATER_SAFE")


func _set_texture_rid(texture: Texture2DRD, rid: RID, cache: Array[RID], index: int) -> void:
	if texture == null or index < 0 or index >= cache.size() or cache[index] == rid:
		return
	texture.texture_rd_rid = rid
	cache[index] = rid


func _publish_crest_textures() -> void:
	var generation := _gpu_generation
	if generation == null or not generation.active or not generation.neutral_ready:
		return
	for index in _crest_foam_textures.size():
		var solver = _solvers[index] if index < _solvers.size() else null
		var rid := generation.neutral_crest_rid
		if _crest_foam_requested and solver != null and solver.generation == generation.generation and solver.ready and solver.crest_ready and solver.crest_foam_rid.is_valid():
			rid = solver.crest_foam_rid
		_set_texture_rid(_crest_foam_textures[index], rid, _published_crest_rids, index)


func _publish_crest_neutral_textures() -> void:
	var generation := _gpu_generation
	if generation == null or not generation.active or not generation.neutral_ready:
		return
	for index in _crest_foam_textures.size():
		_set_texture_rid(_crest_foam_textures[index], generation.neutral_crest_rid, _published_crest_rids, index)


func _all_crest_rids_valid() -> bool:
	var generation := _gpu_generation
	if generation == null or not generation.active or not generation.neutral_ready or _solvers.size() != 3:
		return false
	for solver in _solvers:
		if solver != null and (solver.generation != generation.generation or not solver.crest_ready or not solver.crest_foam_rid.is_valid()):
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
