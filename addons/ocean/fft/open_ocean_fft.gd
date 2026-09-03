class_name OpenOceanFFT
extends Node3D
## Propietario concreto del P0: H0, tres solvers y su clipmap.

const Spectrum := preload("res://addons/ocean/fft/jonswap_hasselmann_spectrum.gd")
const Solver := preload("res://addons/ocean/fft/gpu_stockham_fft.gd")
const Surface := preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
const CoastalRuntime := preload("res://addons/ocean/coastal/ocean_coastal_runtime.gd")

var _solvers: Array = []
var _textures: Array[Texture2DRD] = []
var _normal_textures: Array[Texture2DRD] = []
var _surface: Node3D
var _enabled := false
var _coastal_runtime: RefCounted


func initialize(profile: Resource, quality: Resource, seed: int, sea_level: float, overall_hs_m := -1.0, wind_speed_override_mps := -1.0, primary_direction_degrees := -1000.0, swell_override := -1.0) -> bool:
	shutdown()
	var configs: Array = profile.build_fft_configs(overall_hs_m, wind_speed_override_mps, primary_direction_degrees, swell_override)
	if configs.size() != 3 or not configs.all(func(config): return config.is_valid()):
		push_error("Ocean: perfil FFT P0 inválido.")
		return false
	for config in configs:
		var solver = Solver.new()
		var h0 := Spectrum.build_h0_rgba32f(config, Spectrum.derive_cascade_seed(seed, config.id))
		RenderingServer.call_on_render_thread(solver.initialize.bind(config, h0, "Ocean.%s" % config.id))
		var displacement := Texture2DRD.new()
		var normal := Texture2DRD.new()
		displacement.texture_rd_rid = solver.displacement_rid
		normal.texture_rd_rid = solver.normal_rid
		_solvers.append(solver)
		_textures.append(displacement)
		_normal_textures.append(normal)
	_surface = Surface.new()
	_surface.name = &"OceanClipmapSurface"
	add_child(_surface)
	_surface.initialize(quality, sea_level, configs, _textures, _normal_textures)
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
	if _surface != null: _surface.set_crest_foam_enabled(enabled)


func shutdown() -> void:
	_enabled = false
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
	for solver in _solvers:
		RenderingServer.call_on_render_thread(solver.shutdown)
	_solvers.clear()
	_textures.clear()
	_normal_textures.clear()


func _process(_delta: float) -> void:
	if not _enabled: return
	var render_time := Time.get_ticks_msec() * 0.001
	for solver in _solvers:
		RenderingServer.call_on_render_thread(solver.dispatch.bind(render_time))
