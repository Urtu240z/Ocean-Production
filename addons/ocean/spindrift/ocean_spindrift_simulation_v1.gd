class_name OceanSpindriftSimulationV1
extends RefCounted
## H4.33 render-thread owner of the persistent Eulerian spindrift aerosol field.
##
## Two RG16F 3D state textures are ping-ponged by one compute dispatch per
## simulated step:
##
##   R = density mass
##   G = wave/source-coupled mass        (always clamped to 0 <= G <= R)
##
## Everything is allocated once. Nothing is created per frame, nothing is read
## back to the CPU, and the authoritative RID is published to the main thread
## through a mutex-protected snapshot exactly like the existing P3/P6 owners.
##
## Threading contract:
##   * advance() and shutdown() are RENDER THREAD operations. A queued call keeps
##     this object alive through its Callable, and a late call after shutdown()
##     is a harmless no-op because _rd is already null.
##   * every other method is main-thread and only reads the published snapshot.
##
## Ownership rule: this object owns the shader, pipeline, samplers, parameter
## buffer and both state textures. The caller owns the Texture3DRD wrapper that
## points at the published texture, so the wrapper can be re-pointed after a swap
## without reallocating anything on the GPU.

const ADVECT_SHADER := preload("res://addons/ocean/shaders/spindrift_volume_advect.glsl")

## 96 x 32 x 96 over a 96 m x 16 m x 96 m local volume: ~1.0 m x 0.5 m x 1.0 m
## base voxels. Fixed for V1; there is no runtime resolution resizing.
const RESOLUTION := Vector3i(96, 32, 96)
const LOCAL_SIZE := Vector3i(8, 4, 8)
const PARAMS_BYTES := 11 * 16
## Below this turnover the injector keeps filling at the floor rate, so lowering
## the density decay lengthens persistence instead of producing a dead volume.
const INJECTION_TURNOVER_FLOOR := 0.12
const WAVE_GRADIENT_STEP_M := 1.25
const MAX_MASS := 8.0

## Hard resource failure. Kept separate from the transient source errors so the
## caller can disable the volumetric path exactly once with a clear diagnostic
## instead of retrying or rendering an incorrect field.
var resource_error := ""
## Transient: FFT / Crest G resources not published yet.
var source_error := ""
var ready := false

var _rd: RenderingDevice
var _settings: Dictionary = {}
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _surface_sampler := RID()
var _params := RID()
var _state: Array[RID] = [RID(), RID()]
var _read_index := 0
var _origin := Vector3.ZERO
var _origin_valid := false
var _extent := Vector3(96.0, 16.0, 96.0)
var _simulation_time_s := 0.0
var _steps := 0
var _dispatches := 0
var _history_clears := 0
var _publication_mutex := Mutex.new()
var _published_rid := RID()
var _published_origin := Vector3.ZERO
var _published_valid := false
var _published_revision := 0


## Single authority for the world-space grid placement. The render shader is fed
## the published origin, so both stages agree by construction.
static func snapped_origin(anchor_xz: Vector2, sea_level: float, extent: Vector3, resolution: Vector3i) -> Vector3:
	var voxel_x := extent.x / maxf(float(resolution.x), 1.0)
	var voxel_z := extent.z / maxf(float(resolution.z), 1.0)
	var center_x := snappedf(anchor_xz.x, maxf(voxel_x, 0.001))
	var center_z := snappedf(anchor_xz.y, maxf(voxel_z, 0.001))
	return Vector3(center_x - extent.x * 0.5, sea_level, center_z - extent.z * 0.5)


func configure(settings: Dictionary) -> void:
	_settings = settings.duplicate(true)


func set_extent(extent: Vector3) -> void:
	## Only the world-space size changes here. Resolution stays fixed, so no GPU
	## resource is ever recreated by an artistic edit.
	var next := Vector3(
		clampf(extent.x, 16.0, 320.0),
		clampf(extent.y, 2.0, 64.0),
		clampf(extent.z, 16.0, 320.0))
	if next.is_equal_approx(_extent):
		return
	_extent = next
	if _origin_valid:
		# A different voxel metric cannot be reprojected honestly, so history is
		# dropped once instead of being resampled onto a different grid.
		_origin_valid = false
		_history_clears += 1
		_publish()


func get_publication_snapshot() -> Dictionary:
	_publication_mutex.lock()
	var snapshot := {
		"rid": _published_rid,
		"origin": _published_origin,
		"valid": _published_valid,
		"revision": _published_revision,
	}
	_publication_mutex.unlock()
	snapshot["resolution"] = RESOLUTION
	snapshot["extent"] = _extent
	snapshot["ready"] = ready
	snapshot["resource_error"] = resource_error
	snapshot["source_error"] = source_error
	snapshot["steps"] = _steps
	snapshot["dispatches"] = _dispatches
	snapshot["history_clears"] = _history_clears
	snapshot["simulation_time_s"] = _simulation_time_s
	snapshot["state_format"] = "RG16F"
	snapshot["read_index"] = _read_index
	return snapshot


func advance(anchor_xz: Vector2, sea_level: float, sources: Dictionary, dt: float) -> void:
	## RENDER THREAD. Exactly one fixed step.
	if _rd == null:
		_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		resource_error = "RenderingDevice global no disponible para el volumen persistente."
		return
	if not resource_error.is_empty():
		return
	if not ready and not _create_resources():
		return
	if not _sources_valid(sources):
		return
	var step := clampf(dt, 0.0, 0.25)
	if step <= 0.0:
		return
	var target := snapped_origin(anchor_xz, sea_level, _extent, RESOLUTION)
	var history_valid := _origin_valid \
		and absf(target.x - _origin.x) < _extent.x \
		and absf(target.y - _origin.y) < _extent.y \
		and absf(target.z - _origin.z) < _extent.z
	if _origin_valid and not history_valid:
		_history_clears += 1
	if not _dispatch_step(target, sea_level, sources, step, history_valid):
		return
	_simulation_time_s += step
	_origin = target
	_origin_valid = true
	_read_index = 1 - _read_index
	_steps += 1
	_publish()


func shutdown() -> void:
	## RENDER THREAD. Every RID is freed here and only here. The caller detaches
	## the Texture3DRD wrapper and the material binding before queuing this, so
	## nothing in the render graph still references a freed texture.
	ready = false
	_publication_mutex.lock()
	_published_rid = RID()
	_published_valid = false
	_published_revision += 1
	_publication_mutex.unlock()
	if _rd != null:
		for rid in [_state[0], _state[1], _params, _pipeline, _shader, _sampler, _surface_sampler]:
			if rid.is_valid():
				_rd.free_rid(rid)
	_state = [RID(), RID()]
	_params = RID()
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
	_surface_sampler = RID()
	_rd = null
	_origin = Vector3.ZERO
	_origin_valid = false
	_simulation_time_s = 0.0
	_settings.clear()


func _create_resources() -> bool:
	if _rd == null:
		resource_error = "RenderingDevice no disponible."
		return false
	var spirv := ADVECT_SHADER.get_spirv()
	var compile_error: String = spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		resource_error = compile_error
		return false
	_shader = _rd.shader_create_from_spirv(spirv, "OceanSpindriftVolumeAdvect")
	if not _shader.is_valid():
		resource_error = "No se pudo crear el shader de adveccion."
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		resource_error = "No se pudo crear el pipeline de adveccion."
		_release_partial()
		return false
	var state := RDSamplerState.new()
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(state)
	var surface := RDSamplerState.new()
	surface.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	surface.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	surface.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	surface.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	surface.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_surface_sampler = _rd.sampler_create(surface)
	_params = _rd.uniform_buffer_create(PARAMS_BYTES)
	_state[0] = _create_state_texture("Ocean.SpindriftVolume.StateA")
	_state[1] = _create_state_texture("Ocean.SpindriftVolume.StateB")
	if not _sampler.is_valid() or not _surface_sampler.is_valid() or not _params.is_valid() or not _state[0].is_valid() or not _state[1].is_valid():
		resource_error = "No se pudieron crear las texturas 3D RG16F del volumen."
		_release_partial()
		return false
	ready = true
	_publish()
	return true


func _release_partial() -> void:
	if _rd == null:
		return
	for rid in [_state[0], _state[1], _params, _pipeline, _shader, _sampler, _surface_sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_state = [RID(), RID()]
	_params = RID()
	_pipeline = RID()
	_shader = RID()
	_sampler = RID()
	_surface_sampler = RID()
	ready = false
	_rd = null


func _create_state_texture(resource_name: String) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = RESOLUTION.x
	format.height = RESOLUTION.y
	format.depth = RESOLUTION.z
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var initial := PackedByteArray()
	initial.resize(RESOLUTION.x * RESOLUTION.y * RESOLUTION.z * 4)
	var rid: RID = _rd.texture_create(format, RDTextureView.new(), [initial])
	if rid.is_valid():
		_rd.set_resource_name(rid, resource_name)
	return rid


func _sources_valid(sources: Dictionary) -> bool:
	for key in ["breaking_activity_long_rid", "displacement_long_rid"]:
		var rid: RID = sources.get(key, RID())
		if not rid.is_valid() or _rd == null or not _rd.texture_is_valid(rid):
			source_error = "Crest G / LONG displacement no publicados todavia."
			return false
	source_error = ""
	return true


func _dispatch_step(origin: Vector3, sea_level: float, sources: Dictionary, dt: float, history_valid: bool) -> bool:
	if _rd == null or not _pipeline.is_valid() or not ready:
		return false
	var breaking: RID = sources.get("breaking_activity_long_rid", RID())
	var displacement: RID = sources.get("displacement_long_rid", RID())
	_rd.buffer_update(_params, 0, PARAMS_BYTES, _pack_params(origin, sea_level, sources, dt, history_valid).to_byte_array())
	var set: RID = UniformSetCacheRD.get_cache(_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_sampler, _state[_read_index]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [_state[1 - _read_index]]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_surface_sampler, breaking]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_surface_sampler, displacement]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 4, [_params]),
	])
	if not set.is_valid() or not _rd.uniform_set_is_valid(set):
		resource_error = "Uniform set invalido durante la adveccion."
		return false
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list,
		ceili(float(RESOLUTION.x) / float(LOCAL_SIZE.x)),
		ceili(float(RESOLUTION.y) / float(LOCAL_SIZE.y)),
		ceili(float(RESOLUTION.z) / float(LOCAL_SIZE.z)))
	_rd.compute_list_end()
	_dispatches += 1
	return true


func _pack_params(origin: Vector3, sea_level: float, sources: Dictionary, dt: float, history_valid: bool) -> PackedFloat32Array:
	var domains: Vector3 = sources.get("domains", Vector3(512.0, 137.0, 37.0))
	var ocean_space: Dictionary = sources.get("ocean_space", {})
	var horizontal_scale := maxf(float(ocean_space.get("clipmap_geometry_scale", 1.0)), 0.0001)
	var wind_direction: Vector2 = sources.get("wind_direction", Vector2(1.0, 0.0))
	var wind_speed := maxf(float(sources.get("wind_speed_mps", 0.0)), 0.0)
	var density_decay := maxf(_setting("density_decay", 0.12), 0.0)
	var wave_decay := maxf(_setting("wave_memory_decay", 1.60), 0.0001)
	# Normalising by the steady-state ratio is what makes the affinity proxy read
	# ~1 on a continuously fed crest and -> 0 for a parcel whose crest has gone.
	var steady_ratio := clampf(density_decay / wave_decay, 0.02, 1.0)
	return PackedFloat32Array([
		origin.x, origin.y, origin.z, dt,
		_extent.x, _extent.y, _extent.z, _simulation_time_s,
		_origin.x, _origin.y, _origin.z, 1.0 if history_valid else 0.0,
		domains.x, domains.y, domains.z, 0.0,
		wind_direction.x, wind_direction.y, wind_speed, 0.0,
		density_decay, wave_decay, maxf(density_decay, INJECTION_TURNOVER_FLOOR), MAX_MASS,
		_setting("source_threshold", 0.55), _setting("source_gain", 1.0), _setting("injection_full_m", 0.75), _setting("injection_top_m", 2.50),
		_setting("wave_push_mps", 0.80), steady_ratio, WAVE_GRADIENT_STEP_M * horizontal_scale, 0.0,
		_setting("curl_strength_mps", 1.00), maxf(_setting("curl_scale", 0.030), 0.0001), _setting("curl_speed", 0.12), 0.0,
		clampf(_setting("flow_variation_strength", 0.45), 0.0, 1.0), maxf(_setting("flow_variation_scale", 0.012), 0.0001), 0.05, _setting("lift_mps", 0.12),
		sea_level, horizontal_scale, maxf(float(ocean_space.get("ocean_scale", 1.0)), 0.0001), 0.0,
	])


func _setting(key: String, fallback: float) -> float:
	var value: Variant = _settings.get(key, fallback)
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var result := float(value)
	return result if is_finite(result) else fallback


func _publish() -> void:
	_publication_mutex.lock()
	_published_rid = _state[_read_index] if _origin_valid and _state[_read_index].is_valid() else RID()
	_published_origin = _origin
	_published_valid = _origin_valid and _published_rid.is_valid()
	_published_revision += 1
	_publication_mutex.unlock()


func _uniform(type: int, binding: int, ids: Array) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		var rid: RID = id
		uniform.add_id(rid)
	return uniform
