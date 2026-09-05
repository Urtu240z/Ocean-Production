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


func initialize(profile: Resource, quality: Resource, seed: int, sea_level: float, overall_hs_m := -1.0, wind_speed_override_mps := -1.0, primary_direction_degrees := -1000.0, swell_override := -1.0, crest_enabled := true, surface_foam_enabled := true, crest_profile: OceanCrestFoamProfile = null, surface_profile: OceanSurfaceFoamProfile = null) -> bool:
	shutdown()
	_simulation_seed = seed
	_sea_level = sea_level
	_clipmap_quality = quality
	_crest_foam_profile = crest_profile
	_surface_foam_profile = surface_profile
	var crest_values := _crest_profile_or_default()
	var configs: Array = profile.build_fft_configs(overall_hs_m, wind_speed_override_mps, primary_direction_degrees, swell_override)
	if configs.size() != 3 or not configs.all(func(config): return config.is_valid()):
		push_error("Ocean: perfil FFT P0 inválido.")
		return false
	_wave_configs = configs.duplicate()
	for index in configs.size():
		var config = configs[index]
		var solver = Solver.new()
		var h0 := Spectrum.build_h0_rgba32f(config, Spectrum.derive_cascade_seed(seed, config.id))
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


func get_underwater_medium_sources() -> Dictionary:
	# Publication uses the actual solver RIDs once all three bands used by the
	# visible clipmap exist. A null RID is never a successful publication.
	if _solvers.size() < 3 or _wave_configs.size() < 3 or _clipmap_quality == null:
		return {}
	var long_rid: RID = _solvers[0].displacement_rid
	var mid_rid: RID = _solvers[1].displacement_rid
	var short_rid: RID = _solvers[2].displacement_rid
	var long_domain := float(_wave_configs[0].domain_size_m)
	var mid_domain := float(_wave_configs[1].domain_size_m)
	var short_domain := float(_wave_configs[2].domain_size_m)
	if not long_rid.is_valid() or not mid_rid.is_valid() or not short_rid.is_valid() or long_domain <= 0.0 or mid_domain <= 0.0 or short_domain <= 0.0:
		return {}
	return {
		"long": long_rid, "mid": mid_rid, "short": short_rid,
		"domains": Vector3(long_domain, mid_domain, short_domain),
		"short_fade": _clipmap_quality.short_fade_range_m,
		"mid_fade": _clipmap_quality.mid_fade_range_m,
		"long_fade": _clipmap_quality.long_fade_range_m,
	}


func set_coastal(enabled: bool, bake: Resource) -> void:
	if _surface == null: return
	if not enabled and bake == null:
		if _coastal_runtime != null:
			_coastal_runtime.clear()
		_surface.set_coastal_data({}, false)
		return
	if bake == null:
		if _coastal_runtime != null:
			_coastal_runtime.clear()
		_surface.set_coastal_data({}, enabled)
		return
	if _coastal_runtime == null: _coastal_runtime = CoastalRuntime.new()
	# The real-seabed bake has independent P4 optical authority.  We keep it
	# available with Coastal waves off, while only the wave material route obeys
	# `enabled`.
	_surface.set_coastal_data(_coastal_runtime.activate(bake), enabled)


func set_crest_foam(enabled: bool) -> void:
	if not enabled:
		# The material stops sampling Crest before resources are released.
		if _surface != null: _surface.set_crest_foam_enabled(false)
		_publish_crest_neutral_textures()
		for solver in _solvers:
			RenderingServer.call_on_render_thread(solver.set_crest_foam_enabled.bind(false))
		return
	for solver in _solvers:
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


func set_surface_foam(enabled: bool) -> void:
	if enabled:
		if _surface_foam == null and _solvers.size() >= 2:
			_create_surface_foam(_simulation_seed, _mid_resolution)
	else:
		_free_surface_foam()


func _create_surface_foam(seed: int, mid_resolution: int) -> void:
	if _surface_foam != null or _solvers.size() < 2: return
	_surface_foam = SurfaceFoam.new()
	_surface_foam_generation += 1
	_surface_foam_published = false
	var foam := _surface_foam
	RenderingServer.call_on_render_thread(_initialize_surface_foam.bind(foam, _surface_foam_generation, seed, mid_resolution, _surface_profile_or_default()))


func _initialize_surface_foam(foam, generation: int, seed: int, mid_resolution: int, profile: OceanSurfaceFoamProfile) -> void:
	if foam == null or generation != _surface_foam_generation or _solvers.size() < 2: return
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
		RenderingServer.call_on_render_thread(solver.shutdown)
	_solvers.clear()
	_wave_configs.clear()
	_textures.clear()
	_normal_textures.clear()
	_crest_foam_textures.clear()
	_crest_resolutions.clear()
	if _crest_neutral_rid.is_valid():
		RenderingServer.call_on_render_thread(_free_crest_neutral)


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
	var render_time := Time.get_ticks_msec() * 0.001
	for index in _solvers.size():
		var solver = _solvers[index]
		RenderingServer.call_on_render_thread(solver.dispatch.bind(render_time, delta))
	_publish_crest_textures()
	if _surface_foam != null:
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


func _free_crest_neutral() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd != null and _crest_neutral_rid.is_valid(): rd.free_rid(_crest_neutral_rid)
	_crest_neutral_rid = RID()
	_crest_neutral_texture.texture_rd_rid = RID()


func _publish_crest_textures() -> void:
	for index in _crest_foam_textures.size():
		var rid: RID = _solvers[index].crest_foam_rid
		_crest_foam_textures[index].texture_rd_rid = rid if rid.is_valid() else _crest_neutral_rid


func _publish_crest_neutral_textures() -> void:
	for texture in _crest_foam_textures:
		texture.texture_rd_rid = _crest_neutral_rid


func _all_crest_rids_valid() -> bool:
	if _solvers.size() != 3: return false
	for solver in _solvers:
		if not solver.crest_foam_rid.is_valid(): return false
	return true


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
