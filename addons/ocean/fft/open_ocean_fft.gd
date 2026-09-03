class_name OpenOceanFFT
extends Node3D
## Propietario concreto del P0: H0, tres solvers y su clipmap.

const Spectrum := preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const Solver := preload("res://addons/ocean/fft/gpu_stockham_fft.gd")
const Surface := preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
const CoastalRuntime := preload("res://addons/ocean/coastal/ocean_coastal_runtime.gd")
const SurfaceFoam := preload("res://addons/ocean/surface/ocean_surface_foam.gd")

var _solvers: Array = []
var _textures: Array[Texture2DRD] = []
var _normal_textures: Array[Texture2DRD] = []
var _crest_foam_textures: Array[Texture2DRD] = []
var _surface: Node3D
var _enabled := false
var _coastal_runtime: RefCounted
var _surface_foam: RefCounted
var _surface_foam_field := Texture2DRD.new()
var _surface_foam_topology := Texture2DRD.new()
var _surface_foam_mid_history := Texture2DRD.new()
var _simulation_seed := 1
var _mid_resolution := 256


func initialize(profile: Resource, quality: Resource, seed: int, sea_level: float, overall_hs_m := -1.0, wind_speed_override_mps := -1.0, primary_direction_degrees := -1000.0, swell_override := -1.0, crest_enabled := true, surface_foam_enabled := true) -> bool:
	shutdown()
	_simulation_seed = seed
	var configs: Array = profile.build_fft_configs(overall_hs_m, wind_speed_override_mps, primary_direction_degrees, swell_override)
	if configs.size() != 3 or not configs.all(func(config): return config.is_valid()):
		push_error("Ocean: perfil FFT P0 inválido.")
		return false
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
		var settings: Array = [[0.62, 1.60, 4.50, 1.00, 1024], [0.66, 0.42, 4.50, 0.65, 512], [0.68, 0.22, 4.50, 0.10, 256]][index]
		RenderingServer.call_on_render_thread(solver.set_crest_foam_settings.bind(settings[0], settings[1], settings[2], settings[3], settings[4]))
		RenderingServer.call_on_render_thread(solver.set_crest_foam_enabled.bind(crest_enabled))
	_mid_resolution = configs[1].resolution
	_surface = Surface.new()
	_surface.name = &"OceanClipmapSurface"
	add_child(_surface)
	_surface.initialize(quality, sea_level, configs, _textures, _normal_textures, _crest_foam_textures)
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


func set_coastal(enabled: bool, bake: Resource) -> void:
	if _surface == null: return
	if not enabled:
		if _coastal_runtime != null: _coastal_runtime.clear()
		_surface.set_coastal_data({})
		return
	if _coastal_runtime == null: _coastal_runtime = CoastalRuntime.new()
	_surface.set_coastal_data(_coastal_runtime.activate(bake))


func set_crest_foam(enabled: bool) -> void:
	for solver in _solvers:
		RenderingServer.call_on_render_thread(solver.set_crest_foam_enabled.bind(enabled))
	if _surface != null: _surface.set_crest_foam_enabled(enabled)


func set_surface_foam(enabled: bool) -> void:
	if enabled:
		if _surface_foam == null and _solvers.size() >= 2:
			_create_surface_foam(_simulation_seed, _mid_resolution)
	else:
		_free_surface_foam()


func _create_surface_foam(seed: int, mid_resolution: int) -> void:
	if _surface_foam != null or _solvers.size() < 2: return
	_surface_foam = SurfaceFoam.new()
	RenderingServer.call_on_render_thread(_surface_foam.initialize.bind(seed, _solvers[1].displacement_rid, mid_resolution))
	if not _surface_foam.ready:
		push_error("Ocean Surface Foam: %s" % _surface_foam.last_error)
		RenderingServer.call_on_render_thread(_surface_foam.shutdown)
		_surface_foam = null
		return
	_surface_foam_field.texture_rd_rid = _surface_foam.field_rid
	_surface_foam_topology.texture_rd_rid = _surface_foam.topology_rid
	_surface_foam_mid_history.texture_rd_rid = _surface_foam.mid_history_rid
	_surface.set_surface_foam(_surface_foam_field, _surface_foam_topology, _surface_foam_mid_history, true)


func _free_surface_foam() -> void:
	if _surface != null: _surface.set_surface_foam(null, null, null, false)
	_surface_foam_field.texture_rd_rid = RID()
	_surface_foam_topology.texture_rd_rid = RID()
	_surface_foam_mid_history.texture_rd_rid = RID()
	if _surface_foam != null:
		RenderingServer.call_on_render_thread(_surface_foam.shutdown)
		_surface_foam = null


func shutdown() -> void:
	_enabled = false
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
	_textures.clear()
	_normal_textures.clear()
	_crest_foam_textures.clear()


func _process(delta: float) -> void:
	if not _enabled: return
	var render_time := Time.get_ticks_msec() * 0.001
	for index in _solvers.size():
		var solver = _solvers[index]
		RenderingServer.call_on_render_thread(solver.dispatch.bind(render_time, delta))
		_crest_foam_textures[index].texture_rd_rid = solver.crest_foam_rid
	if _surface_foam != null:
		RenderingServer.call_on_render_thread(_surface_foam.advance.bind(delta))
		_surface_foam_field.texture_rd_rid = _surface_foam.field_rid
		_surface_foam_topology.texture_rd_rid = _surface_foam.topology_rid
		_surface_foam_mid_history.texture_rd_rid = _surface_foam.mid_history_rid
