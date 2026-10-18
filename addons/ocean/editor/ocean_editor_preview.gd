@tool
extends Node3D
## Editor-only frozen snapshot using the production spectrum, GPU FFT and surface.
## No runtime Ocean instance, CPU provider, water queries or simulation clock.
const SpectrumState = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")
const Generation = preload("res://addons/ocean/fft/gpu_resource_generation.gd")
const Solver = preload("res://addons/ocean/fft/gpu_stockham_fft.gd")
const Surface = preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
const Reflections = preload("res://addons/ocean/reflections/ocean_sspr.gd")
const WATCHED_PROPERTIES := ["enabled", "open_ocean_fft", "preview_time", "sea_level", "simulation_seed",
	"wind_speed_mps", "wind_direction_degrees", "swell", "sea_state_mode", "significant_wave_height_m",
	"wave_height_scale", "long_band_scale", "mid_band_scale", "short_band_scale", "long_wave_spacing",
	"mid_fill_amount", "ocean_scale", "clipmap_geometry_scale", "visual_water_profile", "optics", "reflections", "surface_detail",
	"wave_profile", "quality_profile", "optics_profile", "reflection_profile", "surface_detail_profile",
	"crest_foam_profile", "surface_foam_profile", "underwater_medium_profile"]
const MATERIAL_PROPERTIES := ["ocean_scale", "clipmap_geometry_scale", "visual_water_profile", "optics", "reflections", "surface_detail",
	"optics_profile", "reflection_profile", "surface_detail_profile", "crest_foam_profile",
	"surface_foam_profile", "underwater_medium_profile"]
var ocean: Node3D
var _generation: OceanGPUResourceGeneration
var _solvers: Array = []
var _configs: Array = []
var _textures: Array[Texture2DRD] = []
var _normals: Array[Texture2DRD] = []
var _crest: Array[Texture2DRD] = []
var _surface: OceanClipmapSurface
var _sspr: OceanSSPR
var _camera: Camera3D
var _resources: Array[Resource] = []
var _bounds := Vector3.ZERO
var _fingerprint := 0
var _spectral_fingerprint := 0
var _poll := 0.0
var _dirty := true
var _material_dirty := false
var _pending := false
var _active := true
var build_count := 0
var snapshot_dispatch_count := 0

func configure(source: Node3D) -> void:
	ocean = source
	request_refresh()

func request_refresh() -> void:
	_dirty = true
	_poll = 0.15

func _request_material_refresh() -> void:
	_material_dirty = true

func _process(delta: float) -> void:
	if not Engine.is_editor_hint() or not _active or not is_instance_valid(ocean):
		return
	_poll += delta
	if _poll >= 0.15:
		_poll = 0.0
		var values: Array = []
		var spectral_values: Array = []
		for property in WATCHED_PROPERTIES:
			values.append(ocean.get(property))
			if not MATERIAL_PROPERTIES.has(property):
				spectral_values.append(ocean.get(property))
		var current := hash(values)
		if current != _fingerprint:
			_fingerprint = current
			_watch_resources(values)
			var spectral := hash(spectral_values)
			_dirty = _dirty or spectral != _spectral_fingerprint
			_spectral_fingerprint = spectral
			_material_dirty = true
		if _dirty:
			_dirty = false
			_build()
		elif _material_dirty and is_instance_valid(_surface):
			_apply_material()
	if _pending:
		_publish()
	_update_camera()
	if is_instance_valid(_surface):
		_surface.set_wave_area_state(ocean.get_wave_area_runtime())

func _watch_resources(values: Array) -> void:
	for resource in _resources:
		if resource.changed.is_connected(request_refresh):
			resource.changed.disconnect(request_refresh)
		if resource.changed.is_connected(_request_material_refresh):
			resource.changed.disconnect(_request_material_refresh)
	_resources.clear()
	for index in values.size():
		var value: Variant = values[index]
		if value is Resource and not _resources.has(value):
			_resources.append(value)
			value.changed.connect(_request_material_refresh if MATERIAL_PROPERTIES.has(WATCHED_PROPERTIES[index]) else request_refresh)

func _build() -> void:
	_clear_snapshot()
	if not bool(ocean.get("enabled")) or not bool(ocean.get("open_ocean_fft")):
		return
	if RenderingServer.get_rendering_device() == null:
		return
	var wave: Resource = ocean.get("wave_profile")
	var quality: Resource = ocean.get("quality_profile")
	if wave == null or quality == null:
		return
	var hs: float = float(ocean.get("significant_wave_height_m")) if int(ocean.get("sea_state_mode")) == 1 else -1.0
	_configs = wave.call("build_fft_configs", hs, ocean.get("wind_speed_mps"),
		ocean.get("wind_direction_degrees"), ocean.get("swell"), ocean.get("long_wave_spacing"))
	var spectrum: Dictionary = SpectrumState.build(_configs, int(ocean.get("simulation_seed")), hs,
		float(wave.call("combined_significant_wave_height_m")), float(ocean.get("wave_height_scale")),
		[ocean.get("long_band_scale"), ocean.get("mid_band_scale"), ocean.get("short_band_scale")], float(ocean.get("mid_fill_amount")))
	if spectrum.is_empty():
		return
	_bounds = spectrum.bounds
	build_count += 1
	_generation = Generation.new(build_count)
	RenderingServer.call_on_render_thread(_generation.create_neutral_resources)
	for band in 3:
		var solver: OceanGPUStockhamFFT = Solver.new()
		_solvers.append(solver)
		_textures.append(Texture2DRD.new())
		_normals.append(Texture2DRD.new())
		_crest.append(Texture2DRD.new())
		RenderingServer.call_on_render_thread(_generation.initialize_solver.bind(solver, _configs[band],
			spectrum.bands[band].h0_rgba32f, "Ocean.EditorPreview.%d.%d" % [build_count, band], []))
		RenderingServer.call_on_render_thread(solver.dispatch.bind(float(ocean.get("preview_time")), 0.0))
		snapshot_dispatch_count += 1
	_pending = true

func _publish() -> void:
	if _generation == null or not bool(_generation.get_publication_snapshot().get("neutral_ready", false)):
		return
	var neutral: RID = _generation.get_publication_snapshot().get("neutral_crest_rid", RID())
	for band in 3:
		var state: Dictionary = _solvers[band].get_publication_snapshot()
		if not bool(state.get("ready", false)):
			return
		_textures[band].texture_rd_rid = state.displacement_rid
		_normals[band].texture_rd_rid = state.normal_rid
		_crest[band].texture_rd_rid = neutral
	_surface = Surface.new()
	_surface.name = &"FrozenSurface"
	add_child(_surface, false, Node.INTERNAL_MODE_BACK)
	_surface.set_process(false)
	_surface.initialize(ocean.get("quality_profile"), float(ocean.get("sea_level")), _configs, _textures, _normals, _crest, _bounds)
	_surface.set_scene_lighting_source(ocean)
	_surface.set_wave_time(float(ocean.get("preview_time")))
	_pending = false
	_apply_material()
	_update_camera()

func _apply_material() -> void:
	_material_dirty = false
	_surface.set_surface_scale(float(ocean.get("ocean_scale")))
	_surface.set_clipmap_geometry_scale(float(ocean.get("clipmap_geometry_scale")))
	_surface.set_horizontal_displacement_multipliers(Vector3(0.0, 0.0, 1.0) if int(ocean.get("visual_water_profile")) == 1 else Vector3.ONE)
	_surface.set_optics(bool(ocean.get("optics")), ocean.get("optics_profile"))
	_surface.set_surface_detail(bool(ocean.get("surface_detail")), ocean.get("surface_detail_profile"))
	_surface.set_crest_foam_profile(ocean.get("crest_foam_profile"))
	_surface.set_surface_foam_profile(ocean.get("surface_foam_profile"))
	_surface.set_snell_profile(ocean.get("underwater_medium_profile"))
	_surface.set_reflections(bool(ocean.get("reflections")), ocean.get("reflection_profile"))
	if is_instance_valid(_sspr):
		if bool(ocean.get("reflections")):
			var profile: OceanReflectionProfile = ocean.get("reflection_profile")
			_sspr.update(float(ocean.get("sea_level")), profile if profile != null else OceanReflectionProfile.new())
		else:
			_sspr.shutdown()
			_sspr.queue_free()
			_sspr = null

func _update_camera() -> void:
	var camera: Camera3D
	if Engine.has_singleton("EditorInterface"):
		var viewport: SubViewport = Engine.get_singleton("EditorInterface").call("get_editor_viewport_3d", 0)
		if viewport != null:
			camera = viewport.get_camera_3d()
	if camera == null:
		camera = get_viewport().get_camera_3d()
	if camera == null or not is_instance_valid(_surface):
		return
	_surface.update_scene_lighting()
	_surface.global_position = Vector3(camera.global_position.x, float(ocean.get("sea_level")), camera.global_position.z)
	_surface.call("_set_surface_shader_parameter", &"camera_world_xz", Vector2(camera.global_position.x, camera.global_position.z))
	if bool(ocean.get("reflections")) and (_sspr == null or _camera != camera):
		if _sspr != null:
			_sspr.shutdown()
			_sspr.queue_free()
		_sspr = Reflections.new()
		add_child(_sspr, false, Node.INTERNAL_MODE_BACK)
		var profile: OceanReflectionProfile = ocean.get("reflection_profile")
		_sspr.configure(_surface, float(ocean.get("sea_level")), profile if profile != null else OceanReflectionProfile.new(), camera)
	_camera = camera

func _clear_snapshot() -> void:
	_pending = false
	if is_instance_valid(_sspr):
		_sspr.shutdown()
		_sspr.queue_free()
	_sspr = null
	_camera = null
	if is_instance_valid(_surface):
		_surface.shutdown()
		_surface.queue_free()
	_surface = null
	for texture in _textures + _normals + _crest:
		texture.texture_rd_rid = RID()
	_textures.clear()
	_normals.clear()
	_crest.clear()
	if _generation != null:
		_generation.retire()
		for solver in _solvers:
			RenderingServer.call_on_render_thread(solver.shutdown)
		RenderingServer.call_on_render_thread(_generation.shutdown_gpu)
	_generation = null
	_solvers.clear()
	_configs.clear()

func shutdown() -> void:
	_active = false
	set_process(false)
	for resource in _resources:
		if resource.changed.is_connected(request_refresh):
			resource.changed.disconnect(request_refresh)
		if resource.changed.is_connected(_request_material_refresh):
			resource.changed.disconnect(_request_material_refresh)
	_resources.clear()
	_clear_snapshot()

func _exit_tree() -> void:
	shutdown()
