class_name OpenOceanFFT
extends Node3D
## Propietario concreto del P0: H0, tres solvers y su clipmap.

const Spectrum := preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const Solver := preload("res://addons/ocean/fft/gpu_stockham_fft.gd")
const Surface := preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
const CoastalRuntime := preload("res://addons/ocean/coastal/ocean_coastal_runtime.gd")
const SurfaceFoam := preload("res://addons/ocean/surface/ocean_surface_foam.gd")
const OceanSSPR := preload("res://addons/ocean/reflections/ocean_sspr.gd")
const CrestFoamProfile := preload("res://addons/ocean/core/ocean_crest_foam_profile.gd")
const SurfaceFoamProfile := preload("res://addons/ocean/core/ocean_surface_foam_profile.gd")
const ReflectionProfile := preload("res://addons/ocean/core/ocean_reflection_profile.gd")
const SurfaceDetailProfile := preload("res://addons/ocean/core/ocean_surface_detail_profile.gd")
const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")

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
var _sspr: Node
var _sea_level := 0.0
var _wave_time := 0.0
var _wave_speed_multiplier := 1.0
var _cascade_state := CascadeState.new()
var _neutral_displacement_texture := Texture2DRD.new()
var _neutral_normal_texture := Texture2DRD.new()
var _neutral_displacement_rid := RID()
var _neutral_normal_rid := RID()
var _surface_foam_requested := false
var _coastal_waves_requested := false
var _breakers_requested := false
var _runtime_water_state: StringName = &"TRANSITION"


func initialize(profile: Resource, quality: Resource, seed: int, sea_level: float, overall_hs_m := -1.0, wind_speed_override_mps := -1.0, primary_direction_degrees := -1000.0, swell_override := -1.0, crest_enabled := true, surface_foam_enabled := true, crest_profile: OceanCrestFoamProfile = null, surface_profile: OceanSurfaceFoamProfile = null, wave_height_scale := 1.0, long_band_scale := 1.0, mid_band_scale := 1.0, short_band_scale := 1.0, initial_wave_time := 0.0, cascade_mask := CascadeState.FULL, long_wave_spacing := 1.0, mid_fill_amount := 1.0) -> bool:
	shutdown()
	_cascade_state.configure(cascade_mask)
	_wave_time = maxf(initial_wave_time, 0.0)
	_simulation_seed = seed
	_sea_level = sea_level
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
	RenderingServer.call_on_render_thread(_create_fft_neutral)
	for index in configs.size():
		var config = configs[index]
		if not _cascade_state.is_active(_band_for_index(index)):
			_solvers.append(null)
			_textures.append(_neutral_displacement_texture)
			_normal_textures.append(_neutral_normal_texture)
			_crest_foam_textures.append(_crest_neutral_texture)
			_crest_resolutions.append(config.resolution)
			continue
		var solver = Solver.new()
		var h0: PackedByteArray = Spectrum.scale_packed_h0(raw_h0[index], common_scale)
		config.measured_hs_m *= common_scale
		RenderingServer.call_on_render_thread(solver.initialize.bind(config, h0, "Ocean.%s" % config.id))
		var displacement := Texture2DRD.new()
		var normal := Texture2DRD.new()
		var crest_foam := Texture2DRD.new()
		displacement.texture_rd_rid = solver.displacement_rid
		normal.texture_rd_rid = solver.normal_rid
		_solvers.append(solver)
		_textures.append(displacement)
		_normal_textures.append(normal)
		_crest_foam_textures.append(crest_foam)
		_crest_resolutions.append(config.resolution)
		var settings: Array = _crest_settings_for_index(crest_values, index, config.resolution)
		RenderingServer.call_on_render_thread(solver.set_crest_foam_settings.bind(settings[0], settings[1], settings[2], settings[3], settings[4]))
	_mid_resolution = configs[1].resolution
	RenderingServer.call_on_render_thread(_create_crest_neutral)
	_publish_crest_textures()
	_surface = Surface.new()
	_surface.name = &"OceanClipmapSurface"
	add_child(_surface)
	_surface.initialize(quality, sea_level, configs, _textures, _normal_textures, _crest_foam_textures)
	_surface.set_crest_foam_profile(crest_values)
	_surface.set_surface_foam_profile(_surface_profile_or_default())
	set_crest_foam(crest_enabled)
	if surface_foam_enabled:
		_create_surface_foam(seed, configs[1].resolution)
	_enabled = true
	return true


func set_enabled(value: bool) -> void:
	_enabled = value
	visible = value
	set_process(value)


func set_debug_view(value: int) -> void:
	if _surface != null: _surface.set_debug_view(value)


func set_wave_speed_multiplier(value: float) -> void:
	_wave_speed_multiplier = clampf(value, 0.0, 3.0)


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
		"surface_foam_presentation_active": surface_state.get("surface_foam", false),
		"surface_foam_update_hz": _surface_foam.get_update_hz() if _surface_foam != null and _surface_foam.has_method(&"get_update_hz") else 30.0,
	}


func set_runtime_water_state(state: StringName) -> void:
	if state == _runtime_water_state:
		return
	_runtime_water_state = state
	if _surface != null and _surface.has_method(&"set_runtime_water_state"):
		_surface.set_runtime_water_state(state)
		_surface.set_surface_foam_presentation(state != &"UNDERWATER_SAFE")
	if _sspr != null and _sspr.has_method(&"set_runtime_active"):
		_sspr.set_runtime_active(state != &"UNDERWATER_SAFE")
	if _surface_foam != null:
		var update_hz := 10.0 if state == &"UNDERWATER_SAFE" else 30.0
		RenderingServer.call_on_render_thread(_surface_foam.set_update_hz.bind(update_hz))


func set_coastal(enabled: bool, bake: Resource) -> void:
	if _surface == null: return
	_coastal_waves_requested = enabled
	var waves_active := enabled and _cascade_state.is_active(CascadeState.LONG)
	if not enabled and bake == null:
		if _coastal_runtime != null:
			_coastal_runtime.clear()
		_surface.set_coastal_data({}, waves_active)
		return
	if bake == null:
		if _coastal_runtime != null:
			_coastal_runtime.clear()
		_surface.set_coastal_data({}, waves_active)
		return
	if _coastal_runtime == null: _coastal_runtime = CoastalRuntime.new()
	# The real-seabed bake has independent P4 optical authority.  We keep it
	# available with Coastal waves off, while only the wave material route obeys
	# `enabled`.
	_surface.set_coastal_data(_coastal_runtime.activate(bake), waves_active)


func set_breakers(enabled: bool, profile: OceanBreakerProfile) -> void:
	_breakers_requested = enabled
	if _surface != null:
		_surface.set_breakers(enabled, profile)


func set_breaker_profile(profile: OceanBreakerProfile) -> void:
	if _surface != null:
		_surface.set_breaker_profile(profile)


func set_crest_foam(enabled: bool) -> void:
	if not enabled:
		# The material stops sampling Crest before resources are released.
		if _surface != null: _surface.set_crest_foam_enabled(false)
		_publish_crest_neutral_textures()
		for solver in _solvers:
			if solver != null:
				RenderingServer.call_on_render_thread(solver.set_crest_foam_enabled.bind(false))
		return
	for solver in _solvers:
		if solver != null:
			RenderingServer.call_on_render_thread(solver.set_crest_foam_enabled.bind(true))
	if not _all_crest_rids_valid():
		_publish_crest_textures()
		if _surface != null: _surface.set_crest_foam_enabled(false)
		push_error("Ocean Crest Foam no pudo crear sus acumuladores.")
		return
	_publish_crest_textures()
	if _surface != null: _surface.set_crest_foam_enabled(true)


func set_crest_foam_profile(profile: OceanCrestFoamProfile) -> void:
	_crest_foam_profile = profile
	var values := _crest_profile_or_default()
	for index in _solvers.size():
		if _solvers[index] == null: continue
		var resolution: int = _crest_resolutions[index] if index < _crest_resolutions.size() else 0
		var settings: Array = _crest_settings_for_index(values, index, resolution)
		RenderingServer.call_on_render_thread(_solvers[index].set_crest_foam_settings.bind(settings[0], settings[1], settings[2], settings[3], settings[4]))
	if _surface != null: _surface.set_crest_foam_profile(values)


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
	if foam == null or generation != _surface_foam_generation or _solvers.size() < 2 or _solvers[1] == null: return
	# This callback is queued after MID solver initialization and therefore binds
	# the current MID displacement RID on the render thread, never a stale one.
	foam.set_profile(profile)
	foam.initialize(seed, _solvers[1].displacement_rid, mid_resolution)


func _publish_surface_foam_if_ready() -> void:
	if _surface_foam == null or _surface == null or _surface_foam_published: return
	if not _surface_foam.ready:
		if not _surface_foam.last_error.is_empty(): push_error("Ocean Surface Foam: %s" % _surface_foam.last_error)
		return
	_surface_foam_field.texture_rd_rid = _surface_foam.field_rid
	_surface_foam_topology.texture_rd_rid = _surface_foam.topology_rid
	_surface_foam_mid_history.texture_rd_rid = _surface_foam.mid_history_rid
	_surface.set_surface_foam(_surface_foam_field, _surface_foam_topology, _surface_foam_mid_history, true)
	_surface.set_surface_foam_presentation(_runtime_water_state != &"UNDERWATER_SAFE")
	_surface_foam_published = true


func _free_surface_foam() -> void:
	_surface_foam_generation += 1
	if _surface != null: _surface.set_surface_foam(null, null, null, false)
	_surface_foam_field.texture_rd_rid = RID()
	_surface_foam_topology.texture_rd_rid = RID()
	_surface_foam_mid_history.texture_rd_rid = RID()
	if _surface_foam != null:
		var foam := _surface_foam
		RenderingServer.call_on_render_thread(foam.shutdown)
		_surface_foam = null
	_surface_foam_published = false


func shutdown() -> void:
	_enabled = false
	_clipmap_quality = null
	set_reflections(false, null)
	_free_surface_foam()
	if _surface != null:
		_surface.set_coastal_data({})
		_surface.shutdown()
		_surface.queue_free()
		_surface = null
	if _coastal_runtime != null:
		_coastal_runtime.clear()
		_coastal_runtime = null
	for texture in _textures: texture.texture_rd_rid = RID()
	for texture in _normal_textures: texture.texture_rd_rid = RID()
	for texture in _crest_foam_textures: texture.texture_rd_rid = RID()
	for solver in _solvers:
		if solver != null:
			RenderingServer.call_on_render_thread(solver.shutdown)
	_solvers.clear()
	_wave_configs.clear()
	_textures.clear()
	_normal_textures.clear()
	_crest_foam_textures.clear()
	_crest_resolutions.clear()
	if _crest_neutral_rid.is_valid():
		RenderingServer.call_on_render_thread(_free_crest_neutral)
	if _neutral_displacement_rid.is_valid() or _neutral_normal_rid.is_valid():
		RenderingServer.call_on_render_thread(_free_fft_neutral)


func set_optics(enabled: bool, profile: Resource) -> void:
	if _surface != null:
		_surface.set_optics(enabled, profile)


func set_optics_profile(profile: OceanOpticsProfile) -> void:
	if _surface != null:
		_surface.set_optics_profile(profile)


func set_reflections(enabled: bool, profile: Resource) -> void:
	if _surface == null:
		return
	if not enabled:
		# Material fallback first: no SSPR sampling can outlive a published RID.
		_surface.set_reflections(false, profile)
		if _sspr != null:
			_sspr.shutdown()
			_sspr.queue_free()
			_sspr = null
		return
	var values: OceanReflectionProfile = profile as OceanReflectionProfile
	if values == null:
		values = ReflectionProfile.new()
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
	if _surface != null:
		_surface.set_reflection_profile(values)
	if _sspr != null:
		_sspr.update(_sea_level, values)


func set_surface_detail(enabled: bool, profile: OceanSurfaceDetailProfile) -> void:
	if _surface != null:
		_surface.set_surface_detail(enabled, profile)


func set_surface_detail_profile(profile: OceanSurfaceDetailProfile) -> void:
	if _surface != null:
		_surface.set_surface_detail_profile(profile)


func _process(delta: float) -> void:
	if not _enabled: return
	_wave_time += maxf(delta, 0.0) * _wave_speed_multiplier
	for index in _solvers.size():
		var solver = _solvers[index]
		if solver == null: continue
		RenderingServer.call_on_render_thread(solver.dispatch.bind(_wave_time, delta))
	_publish_crest_textures()
	if _surface_foam != null:
		_surface_foam.set_wave_time(_wave_time)
		RenderingServer.call_on_render_thread(_surface_foam.advance.bind(delta))
		_publish_surface_foam_if_ready()
		if _surface_foam_published:
			_surface_foam_field.texture_rd_rid = _surface_foam.field_rid
			_surface_foam_topology.texture_rd_rid = _surface_foam.topology_rid
			_surface_foam_mid_history.texture_rd_rid = _surface_foam.mid_history_rid


func _create_crest_neutral() -> void:
	if _crest_neutral_rid.is_valid(): return
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	format.width = 1
	format.height = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var clear := PackedByteArray()
	clear.resize(4)
	_crest_neutral_rid = rd.texture_create(format, RDTextureView.new(), [clear])
	rd.set_resource_name(_crest_neutral_rid, "Ocean.CrestFoamNeutral")
	_crest_neutral_texture.texture_rd_rid = _crest_neutral_rid


func _create_fft_neutral() -> void:
	if _neutral_displacement_rid.is_valid() and _neutral_normal_rid.is_valid(): return
	var rd := RenderingServer.get_rendering_device()
	if rd == null: return
	var displacement_format := RDTextureFormat.new()
	displacement_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	displacement_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	displacement_format.width = 1
	displacement_format.height = 1
	displacement_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	_neutral_displacement_rid = rd.texture_create(displacement_format, RDTextureView.new(), [PackedFloat32Array([0.0, 0.0, 0.0, 0.0]).to_byte_array()])
	if _neutral_displacement_rid.is_valid():
		rd.set_resource_name(_neutral_displacement_rid, "Ocean.FFT.NeutralDisplacement")
		_neutral_displacement_texture.texture_rd_rid = _neutral_displacement_rid
	var normal_format := RDTextureFormat.new()
	normal_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	normal_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	normal_format.width = 1
	normal_format.height = 1
	normal_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
	var normal_bytes := PackedByteArray([0, 0, 0, 60, 0, 0, 0, 60])
	_neutral_normal_rid = rd.texture_create(normal_format, RDTextureView.new(), [normal_bytes])
	if _neutral_normal_rid.is_valid():
		rd.set_resource_name(_neutral_normal_rid, "Ocean.FFT.NeutralNormal")
		_neutral_normal_texture.texture_rd_rid = _neutral_normal_rid


func _free_fft_neutral() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		for rid in [_neutral_displacement_rid, _neutral_normal_rid]:
			if rid.is_valid(): rd.free_rid(rid)
	_neutral_displacement_rid = RID()
	_neutral_normal_rid = RID()
	_neutral_displacement_texture.texture_rd_rid = RID()
	_neutral_normal_texture.texture_rd_rid = RID()


func _free_crest_neutral() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd != null and _crest_neutral_rid.is_valid(): rd.free_rid(_crest_neutral_rid)
	_crest_neutral_rid = RID()
	_crest_neutral_texture.texture_rd_rid = RID()


func _publish_crest_textures() -> void:
	for index in _crest_foam_textures.size():
		var solver = _solvers[index]
		var rid: RID = solver.crest_foam_rid if solver != null else RID()
		_crest_foam_textures[index].texture_rd_rid = rid if rid.is_valid() else _crest_neutral_rid


func _publish_crest_neutral_textures() -> void:
	for texture in _crest_foam_textures:
		texture.texture_rd_rid = _crest_neutral_rid


func _all_crest_rids_valid() -> bool:
	if _solvers.size() != 3: return false
	for solver in _solvers:
		if solver != null and not solver.crest_foam_rid.is_valid(): return false
	return true


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
