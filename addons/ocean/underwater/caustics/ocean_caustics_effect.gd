@tool
class_name OceanCausticsEffect
extends CompositorEffect

const SHADER_PATH := "res://addons/ocean/underwater/caustics/ocean_caustics.glsl"
const PARAMS_BYTES := 320
const THREAD_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _params_buffer := RID()
var _texture_rid := RID()
var _luma_gradient_rid := RID()
var _displacement_long_rid := RID()
var _displacement_mid_rid := RID()
var _displacement_short_rid := RID()
var _coastal_field_rid := RID()
var _coastal_warp_rid := RID()
var _surface_domains := Vector3.ONE
var _surface_ocean_scale := 1.0
var _surface_horizontal_scale := 1.0
var _surface_long_fade := Vector2.ZERO
var _surface_mid_fade := Vector2.ZERO
var _surface_short_fade := Vector2.ZERO
var _surface_coastal_enabled := false
var _surface_coastal_origin := Vector2.ZERO
var _surface_coastal_extent := Vector2.ONE
var _surface_coastal_warp_origin := Vector2.ZERO
var _surface_coastal_warp_extent := Vector2.ONE
var _surface_coastal_detj_safe := 0.5
var _surface_sources_ready := false
var _active := false
var _debug_mode := 0
var _sea_level := 0.0
var _scale := 4.0
var _speed := 0.1
var _strength := 1.0
var _power := 2.0
var _chroma_split := 0.002
var _layer_a_speed_multiplier := 0.75
var _layer_b_speed_multiplier := 1.0
var _layer_a_scale_multiplier := 1.0
var _layer_b_scale_multiplier := -1.0
var _layer_a_direction := Vector2(1.0, 0.0)
var _layer_b_direction := Vector2(1.0, 0.0)
var _luminance_mask_strength := 0.2
var _sun_strength := 1.0
var _fade_start := 4.0
var _max_depth := 6.0
var _surface_offset := 0.0
var _surface_fade_distance := 0.15
var _time := 0.0
var _sun_direction := Vector3(0.0, 1.0, 0.0)
var _bindings_ready := false
var _mutex := Mutex.new()


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_SKY
	access_resolved_color = true
	access_resolved_depth = true
	_rd = RenderingServer.get_rendering_device()


func set_settings(active: bool, sea_level: float, texture: Texture2D, luma_gradient: Texture2D,
		scale: float, speed: float, strength: float, power: float, chroma_split: float,
		layer_a_speed_multiplier: float, layer_b_speed_multiplier: float,
		layer_a_scale_multiplier: float, layer_b_scale_multiplier: float,
		layer_a_direction: Vector2, layer_b_direction: Vector2, luminance_mask_strength: float,
		sun_strength: float, fade_start: float, max_depth: float, surface_offset: float,
		surface_fade_distance: float, sun_direction: Vector3,
		debug_mode: int) -> bool:
	var texture_rid := RID()
	var luma_gradient_rid := RID()
	if texture != null and texture.get_rid().is_valid():
		var candidate_texture := RenderingServer.texture_get_rd_texture(texture.get_rid(), true)
		if candidate_texture.is_valid() and _rd != null and _rd.texture_is_valid(candidate_texture):
			texture_rid = candidate_texture
	if luma_gradient != null and luma_gradient.get_rid().is_valid():
		var candidate_luma := RenderingServer.texture_get_rd_texture(luma_gradient.get_rid(), true)
		if candidate_luma.is_valid() and _rd != null and _rd.texture_is_valid(candidate_luma):
			luma_gradient_rid = candidate_luma
	var bindings_ready := texture_rid.is_valid() and luma_gradient_rid.is_valid()
	_mutex.lock()
	_active = active and bindings_ready
	_bindings_ready = bindings_ready
	_sea_level = sea_level
	_texture_rid = texture_rid
	_luma_gradient_rid = luma_gradient_rid
	_scale = maxf(scale, 0.05)
	_speed = clampf(speed, -5.0, 5.0)
	_strength = maxf(strength, 0.0)
	_power = maxf(power, 0.01)
	_chroma_split = clampf(chroma_split, 0.0, 0.02)
	_layer_a_speed_multiplier = layer_a_speed_multiplier
	_layer_b_speed_multiplier = layer_b_speed_multiplier
	_layer_a_scale_multiplier = layer_a_scale_multiplier
	_layer_b_scale_multiplier = layer_b_scale_multiplier
	_layer_a_direction = layer_a_direction
	_layer_b_direction = layer_b_direction
	_luminance_mask_strength = clampf(luminance_mask_strength, -2.0, 2.0)
	_sun_strength = clampf(sun_strength, 0.0, 1.0)
	_fade_start = maxf(fade_start, 0.0)
	_max_depth = maxf(max_depth, _fade_start + 0.001)
	_surface_offset = clampf(surface_offset, -1.0, 1.0)
	_surface_fade_distance = clampf(surface_fade_distance, 0.0, 2.0)
	_sun_direction = sun_direction
	_debug_mode = debug_mode
	_mutex.unlock()
	return bindings_ready


func set_time(value: float) -> void:
	set_dynamic_state(value, _sun_direction)


func set_dynamic_state(value: float, sun_direction: Vector3) -> void:
	_mutex.lock()
	_time = value
	_sun_direction = sun_direction
	_mutex.unlock()


func set_surface_sources(sources: Dictionary) -> void:
	var long_rid: RID = sources.get("long", RID())
	var mid_rid: RID = sources.get("mid", RID())
	var short_rid: RID = sources.get("short", RID())
	var coastal_field_rid: RID = sources.get("coastal_field", long_rid)
	var coastal_warp_rid: RID = sources.get("coastal_warp", long_rid)
	var fft_ready := long_rid.is_valid() and mid_rid.is_valid() and short_rid.is_valid()
	var coastal_ready := coastal_field_rid.is_valid() and coastal_warp_rid.is_valid()
	_mutex.lock()
	_displacement_long_rid = long_rid
	_displacement_mid_rid = mid_rid
	_displacement_short_rid = short_rid
	_coastal_field_rid = coastal_field_rid if coastal_ready else long_rid
	_coastal_warp_rid = coastal_warp_rid if coastal_ready else long_rid
	_surface_domains = sources.get("domains", Vector3.ONE)
	_surface_ocean_scale = float(sources.get("ocean_scale", 1.0))
	_surface_horizontal_scale = float(sources.get("clipmap_geometry_scale", 1.0))
	_surface_long_fade = sources.get("long_fade", Vector2.ZERO)
	_surface_mid_fade = sources.get("mid_fade", Vector2.ZERO)
	_surface_short_fade = sources.get("short_fade", Vector2.ZERO)
	_surface_coastal_enabled = bool(sources.get("coastal_enabled", false)) and coastal_ready
	_surface_coastal_origin = sources.get("coastal_origin", Vector2.ZERO)
	_surface_coastal_extent = sources.get("coastal_extent", Vector2.ONE)
	_surface_coastal_warp_origin = sources.get("coastal_warp_origin", Vector2.ZERO)
	_surface_coastal_warp_extent = sources.get("coastal_warp_extent", Vector2.ONE)
	_surface_coastal_detj_safe = maxf(float(sources.get("coastal_warp_detj_safe", 0.5)), 0.001)
	_surface_sources_ready = fft_ready and _coastal_field_rid.is_valid() and _coastal_warp_rid.is_valid()
	_mutex.unlock()


func set_active(value: bool) -> void:
	_mutex.lock()
	_active = value and _bindings_ready
	_mutex.unlock()


func get_texture_binding_status() -> Dictionary:
	_mutex.lock()
	var status := {
		"pattern": _texture_rid.is_valid(),
		"luma": _luma_gradient_rid.is_valid(),
		"surface": _surface_sources_ready,
	}
	_mutex.unlock()
	return status


func free_resources() -> void:
	_mutex.lock()
	_active = false
	_bindings_ready = false
	_texture_rid = RID()
	_luma_gradient_rid = RID()
	_displacement_long_rid = RID()
	_displacement_mid_rid = RID()
	_displacement_short_rid = RID()
	_coastal_field_rid = RID()
	_coastal_warp_rid = RID()
	_surface_sources_ready = false
	var params_buffer: RID = _params_buffer
	var sampler: RID = _sampler
	var pipeline: RID = _pipeline
	var shader: RID = _shader
	_params_buffer = RID()
	_sampler = RID()
	_pipeline = RID()
	_shader = RID()
	_mutex.unlock()
	if _rd == null:
		return
	if params_buffer.is_valid():
		_rd.free_rid(params_buffer)
	if sampler.is_valid():
		_rd.free_rid(sampler)
	if pipeline.is_valid():
		_rd.free_rid(pipeline)
	if shader.is_valid():
		_rd.free_rid(shader)


func _ensure_pipeline() -> bool:
	if _pipeline.is_valid() and _sampler.is_valid() and _params_buffer.is_valid():
		return true
	var shader_file := load(SHADER_PATH) as RDShaderFile
	if shader_file == null:
		return false
	_shader = _rd.shader_create_from_spirv(shader_file.get_spirv(), "OceanCaustics.Project")
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	_sampler = _rd.sampler_create(sampler_state)
	_params_buffer = _rd.uniform_buffer_create(PARAMS_BYTES)
	return _pipeline.is_valid() and _sampler.is_valid() and _params_buffer.is_valid()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_SKY or _rd == null:
		return
	_mutex.lock()
	var active := _active
	var surface_sources_ready := _surface_sources_ready
	var sea_level := _sea_level
	var texture_rid := _texture_rid
	var luma_gradient_rid := _luma_gradient_rid
	var displacement_long_rid := _displacement_long_rid
	var displacement_mid_rid := _displacement_mid_rid
	var displacement_short_rid := _displacement_short_rid
	var coastal_field_rid := _coastal_field_rid
	var coastal_warp_rid := _coastal_warp_rid
	var surface_domains := _surface_domains
	var surface_ocean_scale := _surface_ocean_scale
	var surface_horizontal_scale := _surface_horizontal_scale
	var surface_long_fade := _surface_long_fade
	var surface_mid_fade := _surface_mid_fade
	var surface_short_fade := _surface_short_fade
	var surface_coastal_enabled := _surface_coastal_enabled
	var surface_coastal_origin := _surface_coastal_origin
	var surface_coastal_extent := _surface_coastal_extent
	var surface_coastal_warp_origin := _surface_coastal_warp_origin
	var surface_coastal_warp_extent := _surface_coastal_warp_extent
	var surface_coastal_detj_safe := _surface_coastal_detj_safe
	var scale := _scale
	var speed := _speed
	var strength := _strength
	var power := _power
	var chroma_split := _chroma_split
	var layer_a_speed_multiplier := _layer_a_speed_multiplier
	var layer_b_speed_multiplier := _layer_b_speed_multiplier
	var layer_a_scale_multiplier := _layer_a_scale_multiplier
	var layer_b_scale_multiplier := _layer_b_scale_multiplier
	var layer_a_direction := _layer_a_direction
	var layer_b_direction := _layer_b_direction
	var luminance_mask_strength := _luminance_mask_strength
	var sun_strength := _sun_strength
	var fade_start := _fade_start
	var max_depth := _max_depth
	var surface_offset := _surface_offset
	var surface_fade_distance := _surface_fade_distance
	var time := _time
	var sun_direction := _sun_direction
	var debug_mode := _debug_mode
	_mutex.unlock()
	if not active or not surface_sources_ready or not texture_rid.is_valid() or not luma_gradient_rid.is_valid() or not _ensure_pipeline():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null or scene_data == null or buffers.get_view_count() != 1:
		return
	var size := buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var color_image := buffers.get_color_layer(0)
	var depth_texture := buffers.get_depth_layer(0)
	if not color_image.is_valid() or not depth_texture.is_valid():
		return
	var projection: Projection = scene_data.get_view_projection(0)
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var inverse_view_projection := (projection * Projection(camera_transform.affine_inverse())).inverse()
	var params := PackedFloat32Array()
	_append_projection(params, inverse_view_projection)
	params.append(float(size.x)); params.append(float(size.y)); params.append(0.0); params.append(0.0)
	params.append(sea_level); params.append(1.0 / maxf(scale, 0.05)); params.append(strength); params.append(power)
	params.append(speed); params.append(chroma_split); params.append(luminance_mask_strength); params.append(sun_strength)
	params.append(layer_a_speed_multiplier); params.append(layer_a_scale_multiplier); params.append(layer_a_direction.x); params.append(layer_a_direction.y)
	params.append(layer_b_speed_multiplier); params.append(layer_b_scale_multiplier); params.append(layer_b_direction.x); params.append(layer_b_direction.y)
	params.append(fade_start); params.append(max_depth); params.append(time)
	params.append(0.0 if not active else 2.0 if debug_mode >= 1 else 1.0)
	params.append(sun_direction.x); params.append(sun_direction.y); params.append(sun_direction.z); params.append(0.0)
	params.append(surface_horizontal_scale); params.append(surface_ocean_scale); params.append(camera_transform.origin.x); params.append(camera_transform.origin.z)
	params.append(surface_domains.x); params.append(surface_domains.y); params.append(surface_domains.z); params.append(0.0)
	params.append(surface_long_fade.x); params.append(surface_long_fade.y); params.append(0.0); params.append(0.0)
	params.append(surface_mid_fade.x); params.append(surface_mid_fade.y); params.append(0.0); params.append(0.0)
	params.append(surface_short_fade.x); params.append(surface_short_fade.y); params.append(0.0); params.append(0.0)
	params.append(surface_coastal_origin.x); params.append(surface_coastal_origin.y); params.append(surface_coastal_extent.x); params.append(surface_coastal_extent.y)
	params.append(surface_coastal_warp_origin.x); params.append(surface_coastal_warp_origin.y); params.append(surface_coastal_warp_extent.x); params.append(surface_coastal_warp_extent.y)
	params.append(1.0 if surface_coastal_enabled else 0.0); params.append(surface_coastal_detj_safe); params.append(0.0); params.append(0.0)
	params.append(surface_offset); params.append(surface_fade_distance); params.append(0.0); params.append(0.0)
	_rd.buffer_update(_params_buffer, 0, PARAMS_BYTES, params.to_byte_array())
	var color_uniform := RDUniform.new()
	color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	color_uniform.binding = 0
	color_uniform.add_id(color_image)
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 1
	depth_uniform.add_id(_sampler); depth_uniform.add_id(depth_texture)
	var texture_uniform := RDUniform.new()
	texture_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	texture_uniform.binding = 2
	texture_uniform.add_id(_sampler); texture_uniform.add_id(texture_rid)
	var luma_gradient_uniform := RDUniform.new()
	luma_gradient_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	luma_gradient_uniform.binding = 3
	luma_gradient_uniform.add_id(_sampler); luma_gradient_uniform.add_id(luma_gradient_rid)
	var displacement_long_uniform := RDUniform.new()
	displacement_long_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	displacement_long_uniform.binding = 4
	displacement_long_uniform.add_id(_sampler); displacement_long_uniform.add_id(displacement_long_rid)
	var displacement_mid_uniform := RDUniform.new()
	displacement_mid_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	displacement_mid_uniform.binding = 5
	displacement_mid_uniform.add_id(_sampler); displacement_mid_uniform.add_id(displacement_mid_rid)
	var displacement_short_uniform := RDUniform.new()
	displacement_short_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	displacement_short_uniform.binding = 6
	displacement_short_uniform.add_id(_sampler); displacement_short_uniform.add_id(displacement_short_rid)
	var coastal_field_uniform := RDUniform.new()
	coastal_field_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	coastal_field_uniform.binding = 7
	coastal_field_uniform.add_id(_sampler); coastal_field_uniform.add_id(coastal_field_rid)
	var coastal_warp_uniform := RDUniform.new()
	coastal_warp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	coastal_warp_uniform.binding = 8
	coastal_warp_uniform.add_id(_sampler); coastal_warp_uniform.add_id(coastal_warp_rid)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 9
	params_uniform.add_id(_params_buffer)
	var uniform_set: RID = UniformSetCacheRD.get_cache(_shader, 0, [
		color_uniform, depth_uniform, texture_uniform, luma_gradient_uniform,
		displacement_long_uniform, displacement_mid_uniform, displacement_short_uniform,
		coastal_field_uniform, coastal_warp_uniform, params_uniform
	])
	if not uniform_set.is_valid() or not _rd.uniform_set_is_valid(uniform_set):
		return
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / THREAD_SIZE), ceili(float(size.y) / THREAD_SIZE), 1)
	_rd.compute_list_end()


func _append_projection(values: PackedFloat32Array, projection: Projection) -> void:
	for column in [projection.x, projection.y, projection.z, projection.w]:
		values.append(column.x); values.append(column.y); values.append(column.z); values.append(column.w)
