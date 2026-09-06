class_name OceanUnderwaterBubbles
extends RefCounted
## Render-thread owner for the camera-following, world-reprojected entrained-air
## density field. The visible result is composed by the existing P6.5 pass.

const UPDATE_SHADER := preload("res://addons/ocean/underwater/bubbles/shaders/ocean_underwater_bubbles_update.glsl")
const UPDATE_PARAMS_BYTES := 13 * 16
const RENDER_PARAMS_BYTES := 12 * 16
const LOCAL_SIZE := Vector3i(4, 4, 4)
const MAX_CATCHUP_STEPS := 4

var last_error := ""

var _rd: RenderingDevice
var _settings := {}
var _shader := RID()
var _pipeline := RID()
var _update_params := RID()
var _render_params := RID()
var _density_sampler := RID()
var _surface_sampler := RID()
var _fallback_density := RID()
var _density: Array[RID] = [RID(), RID()]
var _read_index := 0
var _volume_size := Vector3i.ZERO
var _volume_origin := Vector3.ZERO
var _volume_origin_valid := false
var _last_wall_time_s := -1.0
var _accumulator_s := 0.0
var _simulation_time_s := 0.0
var _render_state_enabled := false


func prepare(rd: RenderingDevice) -> bool:
	if rd == null:
		last_error = "RenderingDevice global no disponible."
		return false
	_rd = rd
	if _fallback_density.is_valid() and _render_params.is_valid() and _density_sampler.is_valid() and _surface_sampler.is_valid():
		return true
	var density_state := RDSamplerState.new()
	density_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	density_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	density_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	density_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	density_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	density_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_density_sampler = _rd.sampler_create(density_state)
	var surface_state := RDSamplerState.new()
	surface_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	surface_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	surface_state.mip_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	surface_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	surface_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_surface_sampler = _rd.sampler_create(surface_state)
	_fallback_density = _create_density_texture(Vector3i(1, 1, 1), "Ocean.UnderwaterBubbles.Fallback")
	_render_params = _rd.uniform_buffer_create(RENDER_PARAMS_BYTES)
	if not _fallback_density.is_valid() or not _render_params.is_valid() or not _density_sampler.is_valid() or not _surface_sampler.is_valid():
		last_error = "No se pudieron crear los bindings fallback del volumen."
		shutdown()
		return false
	_update_render_params(Vector3.ZERO, Vector3.ONE, Vector3.ZERO, 0.0, {})
	return true


func configure(settings: Dictionary) -> void:
	var requested_size := Vector3i(
		clampi(int(settings.get("resolution_x", 96)), 16, 192),
		clampi(int(settings.get("resolution_y", 32)), 8, 96),
		clampi(int(settings.get("resolution_z", 96)), 16, 192)
	)
	var requested_extent := _volume_extent_for(settings)
	var extent_changed := _volume_origin_valid and not requested_extent.is_equal_approx(_volume_extent())
	if _volume_size != Vector3i.ZERO and (requested_size != _volume_size or extent_changed):
		_release_volume()
	_settings = settings.duplicate(true)


func advance(camera_position: Vector3, sea_level: float, sources: Dictionary, wall_time_s: float) -> void:
	if _rd == null or not prepare(_rd):
		return
	var enabled := bool(_settings.get("enabled", false))
	var extent := _volume_extent()
	if not enabled:
		_last_wall_time_s = wall_time_s
		_accumulator_s = 0.0
		if _render_state_enabled:
			_update_render_params(_volume_origin, extent, camera_position, sea_level, sources, false)
		return
	if bool(_settings.get("freeze_simulation", false)):
		# Freezing also freezes the AABB origin: the texels remain bit-identical and
		# therefore stay at their existing world-space positions while inspected.
		_last_wall_time_s = wall_time_s
		_accumulator_s = 0.0
		_update_render_params(_volume_origin, extent, camera_position, sea_level, sources, _volume_origin_valid)
		return
	if not _sources_valid(sources) or not _ensure_simulation_resources():
		_last_wall_time_s = wall_time_s
		_update_render_params(_volume_origin, extent, camera_position, sea_level, sources, false)
		return

	var simulation_hz := clampf(float(_settings.get("simulation_hz", 30.0)), 1.0, 60.0)
	var fixed_dt := 1.0 / simulation_hz
	var elapsed := fixed_dt if _last_wall_time_s < 0.0 else clampf(wall_time_s - _last_wall_time_s, 0.0, 0.25)
	_last_wall_time_s = wall_time_s
	_accumulator_s = minf(_accumulator_s + elapsed, fixed_dt * MAX_CATCHUP_STEPS)
	var steps := mini(int(floor(_accumulator_s / fixed_dt)), MAX_CATCHUP_STEPS)
	for _step in steps:
		var target_origin := _snapped_origin(camera_position, sea_level, extent)
		var history_valid := _volume_origin_valid and absf(target_origin.x - _volume_origin.x) < extent.x and absf(target_origin.y - _volume_origin.y) < extent.y and absf(target_origin.z - _volume_origin.z) < extent.z
		if not _dispatch_step(target_origin, extent, camera_position, sea_level, sources, fixed_dt, history_valid):
			break
		_simulation_time_s += fixed_dt
		_volume_origin = target_origin
		_volume_origin_valid = true
		_read_index = 1 - _read_index
		_accumulator_s -= fixed_dt
	_update_render_params(_volume_origin, extent, camera_position, sea_level, sources, _volume_origin_valid)


func get_density_rid() -> RID:
	return _density[_read_index] if _volume_origin_valid and _density[_read_index].is_valid() else _fallback_density


func get_density_sampler_rid() -> RID:
	return _density_sampler


func get_surface_sampler_rid() -> RID:
	return _surface_sampler


func get_render_params_rid() -> RID:
	return _render_params


func bindings_ready() -> bool:
	return _fallback_density.is_valid() and _density_sampler.is_valid() and _surface_sampler.is_valid() and _render_params.is_valid()


func shutdown() -> void:
	if _rd != null:
		_release_volume()
		for rid in [_update_params, _pipeline, _shader, _render_params, _fallback_density, _density_sampler, _surface_sampler]:
			if rid.is_valid():
				_rd.free_rid(rid)
	_update_params = RID()
	_pipeline = RID()
	_shader = RID()
	_render_params = RID()
	_fallback_density = RID()
	_density_sampler = RID()
	_surface_sampler = RID()
	_last_wall_time_s = -1.0
	_accumulator_s = 0.0
	_simulation_time_s = 0.0
	_render_state_enabled = false
	_rd = null


func _ensure_simulation_resources() -> bool:
	if not _pipeline.is_valid():
		var spirv := UPDATE_SHADER.get_spirv()
		var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
		if not error.is_empty():
			last_error = error
			return false
		_shader = _rd.shader_create_from_spirv(spirv, "OceanUnderwaterBubblesUpdate")
		_pipeline = _rd.compute_pipeline_create(_shader)
		_update_params = _rd.uniform_buffer_create(UPDATE_PARAMS_BYTES)
		if not _shader.is_valid() or not _pipeline.is_valid() or not _update_params.is_valid():
			last_error = "No se pudo crear el pipeline de simulación volumétrica."
			for rid in [_update_params, _pipeline, _shader]:
				if rid.is_valid(): _rd.free_rid(rid)
			_update_params = RID(); _pipeline = RID(); _shader = RID()
			return false
	var requested_size := Vector3i(
		clampi(int(_settings.get("resolution_x", 96)), 16, 192),
		clampi(int(_settings.get("resolution_y", 32)), 8, 96),
		clampi(int(_settings.get("resolution_z", 96)), 16, 192)
	)
	if _density[0].is_valid() and _density[1].is_valid() and _volume_size == requested_size:
		return true
	_release_volume()
	_volume_size = requested_size
	_density[0] = _create_density_texture(_volume_size, "Ocean.UnderwaterBubbles.DensityA")
	_density[1] = _create_density_texture(_volume_size, "Ocean.UnderwaterBubbles.DensityB")
	if not _density[0].is_valid() or not _density[1].is_valid():
		last_error = "No se pudieron crear las texturas 3D R16F del volumen."
		_release_volume()
		return false
	return true


func _dispatch_step(current_origin: Vector3, extent: Vector3, camera_position: Vector3, sea_level: float, sources: Dictionary, dt: float, history_valid: bool) -> bool:
	var previous_density := _density[_read_index]
	var next_density := _density[1 - _read_index]
	var long_rid: RID = sources.get("long", RID())
	var mid_rid: RID = sources.get("mid", RID())
	var short_rid: RID = sources.get("short", RID())
	_rd.buffer_update(_update_params, 0, UPDATE_PARAMS_BYTES, _pack_update_params(current_origin, extent, camera_position, sea_level, sources, dt, history_valid).to_byte_array())
	var set := UniformSetCacheRD.get_cache(_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [_density_sampler, previous_density]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 1, [next_density]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [_surface_sampler, long_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 3, [_surface_sampler, mid_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [_surface_sampler, short_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 5, [_update_params]),
	])
	if not set.is_valid() or not _rd.uniform_set_is_valid(set):
		last_error = "Uniform set inválido durante la simulación volumétrica."
		return false
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, set, 0)
	_rd.compute_list_dispatch(list,
		ceili(float(_volume_size.x) / float(LOCAL_SIZE.x)),
		ceili(float(_volume_size.y) / float(LOCAL_SIZE.y)),
		ceili(float(_volume_size.z) / float(LOCAL_SIZE.z)))
	_rd.compute_list_end()
	return true


func _pack_update_params(current_origin: Vector3, extent: Vector3, camera_position: Vector3, sea_level: float, sources: Dictionary, dt: float, history_valid: bool) -> PackedFloat32Array:
	var domains: Vector3 = sources.get("domains", Vector3.ONE)
	var long_fade: Vector2 = sources.get("long_fade", Vector2(0.0, 1.0))
	var mid_fade: Vector2 = sources.get("mid_fade", Vector2(0.0, 1.0))
	var short_fade: Vector2 = sources.get("short_fade", Vector2(0.0, 1.0))
	var thresholds: Vector3 = _settings.get("source_thresholds", Vector3(0.62, 0.66, 0.68))
	var weights: Vector3 = _settings.get("source_weights", Vector3(1.0, 0.65, 0.10))
	var wind_radians := deg_to_rad(float(_settings.get("wind_direction_degrees", 0.0)))
	var drift_speed := clampf(float(_settings.get("horizontal_drift_mps", 0.20)), 0.0, 2.0)
	var drift := Vector2(cos(wind_radians), sin(wind_radians)) * drift_speed
	var half_life := maxf(float(_settings.get("decay_half_life_s", 5.0)), 0.1)
	var decay_multiplier := exp(-log(2.0) * dt / half_life)
	return PackedFloat32Array([
		current_origin.x, current_origin.y, current_origin.z, dt,
		_volume_origin.x, _volume_origin.y, _volume_origin.z, 1.0 if history_valid else 0.0,
		extent.x, extent.y, extent.z, _simulation_time_s,
		float(_settings.get("injection_strength", 1.0)), float(_settings.get("injection_depth_m", 2.5)), float(_settings.get("downward_entrainment_mps", 1.0)), float(_settings.get("buoyancy_mps", 0.35)),
		drift.x, drift.y, float(_settings.get("curl_strength_mps", 0.80)), float(_settings.get("curl_scale_m", 3.0)),
		float(_settings.get("curl_time_scale", 0.20)), float(_settings.get("diffusion", 0.04)), decay_multiplier, float(_settings.get("max_density", 1.0)),
		camera_position.x, camera_position.y, camera_position.z, sea_level,
		domains.x, domains.y, domains.z, 0.0,
		long_fade.x, long_fade.y, 0.0, 0.0,
		mid_fade.x, mid_fade.y, 0.0, 0.0,
		short_fade.x, short_fade.y, 0.0, 0.0,
		thresholds.x, thresholds.y, thresholds.z, 0.0,
		weights.x, weights.y, weights.z, 0.0,
	])


func _update_render_params(origin: Vector3, extent: Vector3, camera_position: Vector3, sea_level: float, sources: Dictionary, render_enabled := false) -> void:
	if not _render_params.is_valid():
		return
	var domains: Vector3 = sources.get("domains", Vector3.ONE)
	var long_fade: Vector2 = sources.get("long_fade", Vector2(0.0, 1.0))
	var mid_fade: Vector2 = sources.get("mid_fade", Vector2(0.0, 1.0))
	var short_fade: Vector2 = sources.get("short_fade", Vector2(0.0, 1.0))
	var thresholds: Vector3 = _settings.get("source_thresholds", Vector3(0.62, 0.66, 0.68))
	var weights: Vector3 = _settings.get("source_weights", Vector3(1.0, 0.65, 0.10))
	var tint: Color = _settings.get("bubble_tint", Color(0.92, 0.985, 1.0))
	var values := PackedFloat32Array([
		origin.x, origin.y, origin.z, 1.0 if render_enabled else 0.0,
		extent.x, extent.y, extent.z, float(_settings.get("debug_mode", 0)),
		float(_settings.get("scatter_strength", 1.25)), float(_settings.get("extinction_strength", 1.0)), float(_settings.get("density_gamma", 0.8)), float(_settings.get("march_steps", 12)),
		tint.r, tint.g, tint.b, 0.0,
		camera_position.x, camera_position.y, camera_position.z, sea_level,
		float(_settings.get("injection_strength", 1.0)), float(_settings.get("injection_depth_m", 2.5)), float(_settings.get("resolution_y", 32)), 0.0,
		domains.x, domains.y, domains.z, 0.0,
		long_fade.x, long_fade.y, 0.0, 0.0,
		mid_fade.x, mid_fade.y, 0.0, 0.0,
		short_fade.x, short_fade.y, 0.0, 0.0,
		thresholds.x, thresholds.y, thresholds.z, 0.0,
		weights.x, weights.y, weights.z, 0.0,
	])
	_rd.buffer_update(_render_params, 0, RENDER_PARAMS_BYTES, values.to_byte_array())
	_render_state_enabled = render_enabled


func _volume_extent() -> Vector3:
	return _volume_extent_for(_settings)


func _volume_extent_for(settings: Dictionary) -> Vector3:
	var extent_xz := clampf(float(settings.get("volume_extent_xz_m", 64.0)), 8.0, 256.0)
	var top := clampf(float(settings.get("volume_top_above_sea_m", 6.0)), 0.0, 32.0)
	var depth := clampf(float(settings.get("volume_depth_below_sea_m", 12.0)), 1.0, 64.0)
	return Vector3(extent_xz, top + depth, extent_xz)


func _snapped_origin(camera_position: Vector3, sea_level: float, extent: Vector3) -> Vector3:
	var resolution_x := maxf(float(_settings.get("resolution_x", 96)), 1.0)
	var resolution_z := maxf(float(_settings.get("resolution_z", 96)), 1.0)
	var voxel_x := extent.x / resolution_x
	var voxel_z := extent.z / resolution_z
	var center_x := snappedf(camera_position.x, voxel_x)
	var center_z := snappedf(camera_position.z, voxel_z)
	var bottom := sea_level - clampf(float(_settings.get("volume_depth_below_sea_m", 12.0)), 1.0, 64.0)
	return Vector3(center_x - extent.x * 0.5, bottom, center_z - extent.z * 0.5)


func _sources_valid(sources: Dictionary) -> bool:
	for key in ["long", "mid", "short"]:
		var rid: RID = sources.get(key, RID())
		if not rid.is_valid() or not _rd.texture_is_valid(rid):
			return false
	return true


func _create_density_texture(size: Vector3i, resource_name: String) -> RID:
	var format := RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.width = size.x
	format.height = size.y
	format.depth = size.z
	format.array_layers = 1
	format.mipmaps = 1
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	var initial := PackedByteArray()
	initial.resize(size.x * size.y * size.z * 2)
	var rid := _rd.texture_create(format, RDTextureView.new(), [initial])
	if rid.is_valid():
		_rd.set_resource_name(rid, resource_name)
	return rid


func _uniform(type: int, binding: int, ids: Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		uniform.add_id(id)
	return uniform


func _release_volume() -> void:
	if _rd != null:
		for rid in _density:
			if rid.is_valid():
				_rd.free_rid(rid)
	_density = [RID(), RID()]
	_read_index = 0
	_volume_size = Vector3i.ZERO
	_volume_origin = Vector3.ZERO
	_volume_origin_valid = false
	_accumulator_s = 0.0
