class_name OceanSpindriftV4
extends Node3D
## Optional GPU-only Ocean V4 crest spray.
##
## The sensor pools are persistent GPU particles. They own world-cell identity
## and consume OpenOceanBreakingActivity (Crest G). A sensor emits a detached
## child particle only on a rising edge; the child never samples FFT again.

const PARTICLE_SHADER := preload("res://addons/ocean/shaders/spindrift_event_particles.gdshader")
const DETACHED_PARTICLE_SHADER := preload("res://addons/ocean/shaders/spindrift_detached_particles.gdshader")
const RENDER_SHADER := preload("res://addons/ocean/shaders/spindrift_render.gdshader")
const SOURCE_MASK_SHADER := preload("res://addons/ocean/shaders/spindrift_source_mask.gdshader")
const ProfileScript := preload("res://addons/ocean/core/ocean_spindrift_profile.gd")

enum DebugMode { OFF, SOURCE_MASK, CHUNKS_ONLY, SPINDRIFT_ONLY, MIST_ONLY, FULL, FORCE_EMISSION, HEIGHT_ONLY, STEEPNESS_ONLY, CREST_ONLY, POSITION_DEBUG, SOURCE_MASK_FORCE_0, SOURCE_MASK_FORCE_1, POSITION_DEBUG_FORCE, DEBUG_HEIGHT_RAW, DEBUG_HEIGHT_GATE, DEBUG_STEEPNESS_RAW, DEBUG_STEEPNESS_GATE, DEBUG_CREST_RAW, DEBUG_CREST_GATE, DEBUG_BREAKUP_RAW, DEBUG_DOMAIN_FADE, DEBUG_CLIPMAP_FADE, DEBUG_SOURCE_PRE_THRESHOLD, DEBUG_SOURCE_FINAL, DEBUG_SHORT_FADE, DEBUG_MID_FADE, DEBUG_LONG_FADE, DEBUG_ACTIVE_RADIUS_FADE, DEBUG_CREST_GT_001, DEBUG_CREST_GT_002, DEBUG_CREST_GT_005, DEBUG_CREST_GT_010, DEBUG_CREST_GT_020, DEBUG_CREST_GT_040, DEBUG_CREST_GT_060, DEBUG_CREST_GAIN_1, DEBUG_CREST_GAIN_4, DEBUG_CREST_GAIN_8, DEBUG_CREST_GAIN_16 }

const DIAGNOSTIC_VISIBILITY_AABB := AABB(Vector3(-512.0, -256.0, -512.0), Vector3(1024.0, 512.0, 1024.0))
const FORCE_REGION_RADIUS_M := 6.0
const FORCE_REGION_DISTANCE_M := 10.0
const SOURCE_REGION_SIZE_M := 96.0
const POSITION_DEBUG_REGION_SIZE_M := 10.0
const SPINDRIFT_RENDER_PRIORITY := 10
const SENSOR_GRID_CELL_M := 2.5
const SENSOR_FORWARD_NEAR_M := 2.0
const SENSOR_FORWARD_FAR_M := 38.0
const SENSOR_HALF_WIDTH_M := 20.0
const SENSOR_SIDE_FEATHER_M := 4.0
const SENSOR_NEAR_FEATHER_M := 3.0
const SENSOR_FAR_FEATHER_M := 7.0
const SENSOR_LIFETIME_S := 3600.0

var _source_provider: Node
var _profile: OceanSpindriftProfile
var _sea_level := 0.0
var _wind_speed_mps := 18.0
var _wind_direction_degrees := 0.0
var _debug_mode := DebugMode.FULL
var _enabled := false
var _source_bound := false
var _sensor_layers: Array[GPUParticles3D] = []
var _layers: Array[GPUParticles3D] = []
var _process_materials: Array[ShaderMaterial] = []
var _detached_materials: Array[ShaderMaterial] = []
var _render_materials: Array[ShaderMaterial] = []
var _source_mask: MeshInstance3D
var _source_mask_material: ShaderMaterial
var _surface_node: Node3D
var _surface_debug_hidden := false
var _surface_visibility_before_debug := true
var _last_origin := Vector2.INF
var _debug_camera_mask := 0
var _debug_camera_near := 0.0
var _debug_camera_far := 0.0
var _short_fade_range_m := Vector2(0.0, 55.0)
var _mid_fade_range_m := Vector2(96.0, 280.0)
var _long_fade_range_m := Vector2(768.0, 2500.0)
var _spatial_debug_printed := false
var _last_reported_mode := -1
var _source_audit_printed := false


func configure(source_provider: Node, profile: OceanSpindriftProfile, sea_level: float, wind_speed_mps: float, wind_direction_degrees: float, debug_mode: int) -> void:
	_source_provider = source_provider
	_profile = profile if profile != null else ProfileScript.new()
	_sea_level = sea_level
	_wind_speed_mps = maxf(wind_speed_mps, 0.0)
	_wind_direction_degrees = wind_direction_degrees
	_debug_mode = clampi(debug_mode, DebugMode.OFF, DebugMode.DEBUG_CREST_GAIN_16)
	_source_audit_printed = false
	_refresh_surface_alignment()
	if not _profile.changed.is_connected(_on_profile_changed):
		_profile.changed.connect(_on_profile_changed)
	_create_layers()
	_apply_profile()
	_apply_debug_visuals()
	_enabled = true
	_cache_surface_node()
	_apply_surface_debug_visibility()
	set_process(true)
	_apply_gate()
	_print_startup_summary()
	_report_mode_change()


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	_apply_surface_debug_visibility()
	_apply_gate()
	set_process(enabled)


func set_debug_mode(mode: int) -> void:
	_debug_mode = clampi(mode, DebugMode.OFF, DebugMode.DEBUG_CREST_GAIN_16)
	_spatial_debug_printed = false
	_apply_debug_visuals()
	_apply_surface_debug_visibility()
	_apply_gate()
	if _is_source_mask_debug():
		_clear_particles_for_mask_debug()
	_report_mode_change()


func get_runtime_state() -> Dictionary:
	var sensor_count := 0
	var visible_count := 0
	for layer in _sensor_layers:
		if layer != null:
			sensor_count += layer.amount
	for layer in _layers:
		if layer != null and layer.visible:
			visible_count += layer.amount
	return {
		"enabled": _enabled,
		"debug_mode": _debug_mode,
		"source_ready": _source_bound,
		"active_layers": _active_layer_count(),
		"configured_max_live_particles": visible_count,
		"sensor_count": sensor_count,
		"visible_particle_budget": visible_count,
		"breaking_activity_authority": "crest_g_long",
		"breaking_activity_channel": 1,
		"breaking_activity_range": Vector2(0.0, 1.0),
		"world_cell_identity": "floor(world_xz / sensor_grid_cell_m)",
		"detached_particles": true,
		"spindrift_radius_m": _profile.spindrift_radius if _profile != null else 0.0,
		"debug_mode_name": debug_mode_name(_debug_mode),
		"visibility_aabb": DIAGNOSTIC_VISIBILITY_AABB,
		"source_region_center_world": _last_origin,
		"source_region_size_m": SOURCE_REGION_SIZE_M,
	}


func _ready() -> void:
	top_level = true


func _process(_delta: float) -> void:
	if not _enabled or _source_provider == null or not is_instance_valid(_source_provider):
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_apply_gate(false)
		return
	var origin := Vector2(camera.global_position.x, camera.global_position.z)
	var camera_forward := -camera.global_transform.basis.z
	var forward_xz := Vector2(camera_forward.x, camera_forward.z).normalized()
	if forward_xz.length_squared() < 0.001:
		forward_xz = Vector2(0.0, -1.0)
	var camera_right := camera.global_transform.basis.x
	var right_xz := Vector2(camera_right.x, camera_right.z).normalized()
	if right_xz.length_squared() < 0.001:
		right_xz = Vector2(-forward_xz.y, forward_xz.x)
	var force_center := origin + forward_xz * FORCE_REGION_DISTANCE_M
	_debug_camera_mask = camera.cull_mask
	_debug_camera_near = camera.near
	_debug_camera_far = camera.far
	_last_origin = origin
	global_position = Vector3(origin.x, _sea_level, origin.y)
	for layer in _sensor_layers:
		if layer != null:
			layer.global_position = Vector3.ZERO
	for layer in _layers:
		if layer != null:
			layer.global_position = Vector3.ZERO
	_bind_sources()
	_apply_surface_debug_visibility()
	_update_uniforms(origin, force_center, forward_xz, right_xz)
	_update_source_mask(origin)
	_emit_spatial_debug(origin, _source_domains())


func _create_layers() -> void:
	if not _sensor_layers.is_empty():
		return
	_source_mask_material = ShaderMaterial.new()
	_source_mask_material.shader = SOURCE_MASK_SHADER
	_source_mask = MeshInstance3D.new()
	_source_mask.name = &"SpindriftSourceMask"
	_source_mask.top_level = true
	_source_mask.layers = 1
	var plane := PlaneMesh.new()
	plane.size = Vector2(SOURCE_REGION_SIZE_M, SOURCE_REGION_SIZE_M)
	plane.subdivide_width = 64
	plane.subdivide_depth = 64
	plane.material = _source_mask_material
	_source_mask.mesh = plane
	_source_mask.visible = false
	_source_mask.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_source_mask)
	_create_layer("CrestChunks", 0)
	_create_layer("SpindriftStreaks", 1)
	_create_layer("FineMist", 2)


func _create_layer(layer_name: String, layer_kind: int) -> void:
	var sensor := GPUParticles3D.new()
	sensor.name = layer_name + "Sensors"
	sensor.top_level = true
	sensor.local_coords = false
	sensor.layers = 1
	sensor.randomness = 0.0
	sensor.explosiveness = 1.0
	sensor.visibility_aabb = DIAGNOSTIC_VISIBILITY_AABB
	# The sensor has no draw mesh. Its only visible output is its sub-emitter.
	sensor.draw_passes = 1
	var process_material := ShaderMaterial.new()
	process_material.shader = PARTICLE_SHADER
	process_material.set_shader_parameter(&"layer_kind", layer_kind)
	sensor.process_material = process_material
	add_child(sensor)

	var visible := GPUParticles3D.new()
	visible.name = layer_name + "Visible"
	visible.top_level = true
	visible.local_coords = false
	visible.layers = 1
	visible.randomness = 0.0
	visible.explosiveness = 1.0
	visible.visibility_aabb = DIAGNOSTIC_VISIBILITY_AABB
	var detached_material := ShaderMaterial.new()
	detached_material.shader = DETACHED_PARTICLE_SHADER
	visible.process_material = detached_material
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var render_material := ShaderMaterial.new()
	render_material.shader = RENDER_SHADER
	render_material.render_priority = SPINDRIFT_RENDER_PRIORITY
	render_material.set_shader_parameter(&"layer_kind", layer_kind)
	quad.material = render_material
	visible.draw_pass_1 = quad
	visible.draw_passes = 1
	add_child(visible)
	sensor.sub_emitter = NodePath("../" + visible.name)
	_sensor_layers.append(sensor)
	_layers.append(visible)
	_process_materials.append(process_material)
	_detached_materials.append(detached_material)
	_render_materials.append(render_material)


func _apply_profile() -> void:
	if _profile == null or _sensor_layers.size() != 3:
		return
	var amounts := [_profile.chunks_amount, _profile.streaks_amount, _profile.mist_amount]
	var lifetimes := [_profile.chunks_lifetime, _profile.streaks_lifetime, _profile.mist_lifetime]
	for index in 3:
		_sensor_layers[index].amount = amounts[index]
		_sensor_layers[index].lifetime = SENSOR_LIFETIME_S
		_layers[index].amount = amounts[index]
		_layers[index].lifetime = lifetimes[index]
		_sensor_layers[index].visibility_aabb = DIAGNOSTIC_VISIBILITY_AABB
		_layers[index].visibility_aabb = DIAGNOSTIC_VISIBILITY_AABB
		_render_materials[index].set_shader_parameter(&"particle_tint", Color([_profile.chunks_color, _profile.streaks_color, _profile.mist_color][index], 1.0))
		_render_materials[index].set_shader_parameter(&"opacity", [_profile.chunks_alpha, _profile.streaks_alpha, _profile.mist_alpha][index])
		_render_materials[index].set_shader_parameter(&"lod_end_m", [_profile.chunks_lod_end_m, _profile.streaks_lod_end_m, _profile.mist_lod_end_m][index])
	_apply_debug_visuals()


func _update_uniforms(origin: Vector2, force_center: Vector2, camera_forward_xz: Vector2, camera_right_xz: Vector2) -> void:
	if _profile == null:
		return
	var radians := deg_to_rad(_wind_direction_degrees)
	var wind_direction := Vector2(cos(radians), sin(radians)).normalized()
	var wind_velocity := Vector3(wind_direction.x, 0.0, wind_direction.y) * _wind_speed_mps * _profile.wind_velocity_multiplier * lerpf(0.30, 1.0, _profile.storm_strength)
	var domains := _source_domains()
	var position_debug := _is_position_debug()
	var position_debug_force := _is_position_debug_force()
	var source_override := _source_mask_override()
	for index in _process_materials.size():
		var process_material := _process_materials[index]
		process_material.set_shader_parameter(&"spindrift_origin", origin)
		process_material.set_shader_parameter(&"camera_forward_xz", camera_forward_xz)
		process_material.set_shader_parameter(&"camera_right_xz", camera_right_xz)
		process_material.set_shader_parameter(&"sensor_grid_cell_m", SENSOR_GRID_CELL_M)
		process_material.set_shader_parameter(&"sensor_forward_near_m", SENSOR_FORWARD_NEAR_M)
		process_material.set_shader_parameter(&"sensor_forward_far_m", SENSOR_FORWARD_FAR_M)
		process_material.set_shader_parameter(&"sensor_half_width_m", SENSOR_HALF_WIDTH_M)
		process_material.set_shader_parameter(&"sensor_near_feather_m", SENSOR_NEAR_FEATHER_M)
		process_material.set_shader_parameter(&"sensor_far_feather_m", SENSOR_FAR_FEATHER_M)
		process_material.set_shader_parameter(&"sensor_side_feather_m", SENSOR_SIDE_FEATHER_M)
		process_material.set_shader_parameter(&"wind_direction", wind_direction)
		process_material.set_shader_parameter(&"wind_speed_mps", _wind_speed_mps)
		process_material.set_shader_parameter(&"sea_level", _sea_level)
		process_material.set_shader_parameter(&"domain_long_m", domains.x)
		process_material.set_shader_parameter(&"domain_mid_m", domains.y)
		process_material.set_shader_parameter(&"domain_short_m", domains.z)
		process_material.set_shader_parameter(&"layer_amount", float(_sensor_layers[index].amount))
		process_material.set_shader_parameter(&"event_trigger_threshold", _profile.breaking_trigger_threshold)
		process_material.set_shader_parameter(&"event_rearm_threshold", _profile.breaking_rearm_threshold)
		process_material.set_shader_parameter(&"event_density", 1.0 if _is_force_emission() or position_debug else _profile.emission_density)
		process_material.set_shader_parameter(&"storm_strength", _profile.storm_strength)
		process_material.set_shader_parameter(&"crest_kick", _profile.crest_kick)
		process_material.set_shader_parameter(&"horizontal_spread", _profile.horizontal_spread)
		process_material.set_shader_parameter(&"vertical_spread", _profile.vertical_spread)
		process_material.set_shader_parameter(&"source_mask_override", source_override)
		process_material.set_shader_parameter(&"force_emission", _is_force_emission())
		process_material.set_shader_parameter(&"force_center_xz", force_center)
		process_material.set_shader_parameter(&"force_center_y", _sea_level + 3.0)
		process_material.set_shader_parameter(&"force_region_radius", FORCE_REGION_RADIUS_M)
		process_material.set_shader_parameter(&"position_debug_center_xz", force_center)
		process_material.set_shader_parameter(&"position_debug_radius", POSITION_DEBUG_REGION_SIZE_M * 0.5)
		process_material.set_shader_parameter(&"position_debug", position_debug)
		process_material.set_shader_parameter(&"position_debug_force", position_debug_force)
		process_material.set_shader_parameter(&"short_fade_start_m", _short_fade_range_m.x)
		process_material.set_shader_parameter(&"short_fade_end_m", _short_fade_range_m.y)
		process_material.set_shader_parameter(&"mid_fade_start_m", _mid_fade_range_m.x)
		process_material.set_shader_parameter(&"mid_fade_end_m", _mid_fade_range_m.y)
		process_material.set_shader_parameter(&"long_fade_start_m", _long_fade_range_m.x)
		process_material.set_shader_parameter(&"long_fade_end_m", _long_fade_range_m.y)
		process_material.set_shader_parameter(&"active_radius_m", _profile.spindrift_radius)
		_detached_materials[index].set_shader_parameter(&"wind_velocity", wind_velocity)
		_detached_materials[index].set_shader_parameter(&"gravity_mps2", 9.81)
		_detached_materials[index].set_shader_parameter(&"wind_drag", 0.32 + _profile.turbulence_strength * 0.10)
		_detached_materials[index].set_shader_parameter(&"turbulence_strength", _profile.turbulence_strength)
		_detached_materials[index].set_shader_parameter(&"turbulence_scale", _profile.turbulence_scale)
		_detached_materials[index].set_shader_parameter(&"turbulence_speed", _profile.turbulence_speed)
	for render_material in _render_materials:
		render_material.set_shader_parameter(&"camera_world_xz", origin)
		render_material.set_shader_parameter(&"position_debug", position_debug)
	_source_mask_material.set_shader_parameter(&"mask_origin", origin)
	_source_mask_material.set_shader_parameter(&"sea_level", _sea_level)
	_source_mask_material.set_shader_parameter(&"domain_long_m", domains.x)
	_source_mask_material.set_shader_parameter(&"domain_mid_m", domains.y)
	_source_mask_material.set_shader_parameter(&"domain_short_m", domains.z)
	_source_mask_material.set_shader_parameter(&"source_override", source_override)
	_source_mask_material.set_shader_parameter(&"debug_output", _source_debug_output())
	_source_mask_material.set_shader_parameter(&"active_radius_m", _profile.spindrift_radius)
	_source_mask_material.set_shader_parameter(&"event_trigger_threshold", _profile.breaking_trigger_threshold)
	_source_mask_material.set_shader_parameter(&"long_fade_start_m", _long_fade_range_m.x)
	_source_mask_material.set_shader_parameter(&"long_fade_end_m", _long_fade_range_m.y)


func _bind_sources() -> void:
	if _source_provider == null or not is_instance_valid(_source_provider) or not _source_provider.has_method(&"get_spindrift_sources"):
		return
	var data: Dictionary = _source_provider.get_spindrift_sources()
	if not bool(data.get("ready", false)) or not data.has("breaking_activity_long"):
		_source_bound = false
		_apply_gate(false)
		return
	var sensor_keys := ["displacement_long", "displacement_mid", "displacement_short", "normal_long", "normal_mid", "normal_short", "breaking_activity_long"]
	for material in _process_materials:
		for key in sensor_keys:
			material.set_shader_parameter(key, data[key])
	for key in ["displacement_long", "displacement_mid", "displacement_short"]:
		_source_mask_material.set_shader_parameter(key, data[key])
	_source_mask_material.set_shader_parameter(&"breaking_activity_long", data["breaking_activity_long"])
	var was_bound := _source_bound
	_source_bound = true
	if not _source_audit_printed:
		_source_audit_printed = true
		print("SPINDRIFT SOURCE AUDIT | OpenOceanBreakingActivity=crest_foam_long.G; LONG is authority, MID/SHORT are displacement detail only; GPU sub-emitter events are detached")
	_apply_gate()
	# Sensors are persistent and keep their world-cell identity. They do not
	# restart when asynchronous FFT resources become ready.
	if not was_bound:
		for sensor in _sensor_layers:
			if sensor != null:
				sensor.restart()


func _update_source_mask(origin: Vector2) -> void:
	if _source_mask == null:
		return
	_source_mask.global_position = Vector3.ZERO
	_source_mask.visible = _enabled and _is_source_mask_debug() and (_source_bound or _source_mask_override() != 0)


func _apply_gate(force_emitting := true) -> void:
	var source_requirement := _source_bound or _is_force_emission() or _is_position_debug_force()
	var runtime_emitting := force_emitting or _is_force_emission()
	var all_source_layers := _debug_mode in [DebugMode.HEIGHT_ONLY, DebugMode.STEEPNESS_ONLY, DebugMode.CREST_ONLY]
	var position_debug := _is_position_debug()
	var chunks := _enabled and source_requirement and runtime_emitting and (_debug_mode in [DebugMode.CHUNKS_ONLY, DebugMode.FULL, DebugMode.FORCE_EMISSION, DebugMode.POSITION_DEBUG, DebugMode.POSITION_DEBUG_FORCE] or all_source_layers)
	var streaks := _enabled and source_requirement and runtime_emitting and not position_debug and (_debug_mode in [DebugMode.SPINDRIFT_ONLY, DebugMode.FULL, DebugMode.FORCE_EMISSION] or all_source_layers)
	var mist := _enabled and source_requirement and runtime_emitting and not position_debug and (_debug_mode in [DebugMode.MIST_ONLY, DebugMode.FULL, DebugMode.FORCE_EMISSION] or all_source_layers)
	var active := [chunks, streaks, mist]
	for index in 3:
		_sensor_layers[index].emitting = active[index]
		_layers[index].visible = active[index]


func _active_layer_count() -> int:
	var result := 0
	for layer in _layers:
		if layer != null and layer.visible:
			result += 1
	return result


func _clear_particles_for_mask_debug() -> void:
	for sensor in _sensor_layers:
		if sensor == null:
			continue
		sensor.emitting = false
		sensor.restart()


func _is_force_emission() -> bool:
	return _debug_mode == DebugMode.FORCE_EMISSION


func _is_position_debug() -> bool:
	return _debug_mode in [DebugMode.POSITION_DEBUG, DebugMode.POSITION_DEBUG_FORCE]


func _is_position_debug_force() -> bool:
	return _debug_mode == DebugMode.POSITION_DEBUG_FORCE


func _is_source_mask_debug() -> bool:
	return _debug_mode in [DebugMode.SOURCE_MASK, DebugMode.SOURCE_MASK_FORCE_0, DebugMode.SOURCE_MASK_FORCE_1] or _debug_mode >= DebugMode.DEBUG_HEIGHT_RAW


func _source_mask_override() -> int:
	if _debug_mode == DebugMode.SOURCE_MASK_FORCE_0:
		return 1
	if _debug_mode == DebugMode.SOURCE_MASK_FORCE_1:
		return 2
	return 0


func _cache_surface_node() -> void:
	if _surface_node != null or _source_provider == null or not is_instance_valid(_source_provider):
		return
	_surface_node = _source_provider.get_node_or_null(^"OceanClipmapSurface") as Node3D


func _apply_surface_debug_visibility() -> void:
	if _source_provider == null or not is_instance_valid(_source_provider):
		return
	_cache_surface_node()
	if _surface_node == null:
		return
	if _source_provider.has_method(&"is_surface_initialized") and not _source_provider.is_surface_initialized():
		return
	var should_hide := _enabled and _is_source_mask_debug()
	if should_hide:
		if not _surface_debug_hidden:
			_surface_visibility_before_debug = _surface_node.visible
			_surface_debug_hidden = true
			_surface_node.visible = false
		return
	if _surface_debug_hidden:
		_surface_debug_hidden = false
		_restore_surface_visibility()


func _restore_surface_visibility() -> void:
	if _surface_node == null or not is_instance_valid(_surface_node):
		return
	if _source_provider != null and is_instance_valid(_source_provider) and _source_provider.has_method(&"is_surface_authoritatively_visible"):
		_surface_node.visible = _source_provider.is_surface_authoritatively_visible()
	else:
		_surface_node.visible = _surface_visibility_before_debug


func _source_debug_output() -> int:
	# Existing debug modes remain available, but all source-valued outputs now
	# visualize the same Crest G activity consumed by the event path.
	match _debug_mode:
		DebugMode.DEBUG_CREST_GATE, DebugMode.SOURCE_MASK: return 1
		DebugMode.DEBUG_SOURCE_FINAL: return 2
		DebugMode.DEBUG_ACTIVE_RADIUS_FADE: return 3
		_: return 0


func _apply_debug_visuals() -> void:
	var force := _is_force_emission()
	var position_debug := _is_position_debug()
	for index in 3:
		if index >= _render_materials.size():
			continue
		_render_materials[index].set_shader_parameter(&"force_visible", force)
		_render_materials[index].set_shader_parameter(&"position_debug", position_debug)
		if index < _process_materials.size():
			_process_materials[index].set_shader_parameter(&"force_emission", force)
			_process_materials[index].set_shader_parameter(&"position_debug", position_debug)
			_process_materials[index].set_shader_parameter(&"position_debug_force", _is_position_debug_force())


func _source_domains() -> Vector3:
	var domains := Vector3(512.0, 137.0, 37.0)
	if _source_provider != null and is_instance_valid(_source_provider) and _source_provider.has_method(&"get_spindrift_sources"):
		var source_data: Dictionary = _source_provider.get_spindrift_sources()
		domains = source_data.get("domains", domains)
	return domains


func _refresh_surface_alignment() -> void:
	if _source_provider == null or not is_instance_valid(_source_provider):
		return
	var quality = _source_provider.get(&"_clipmap_quality")
	if quality != null:
		_short_fade_range_m = quality.get(&"short_fade_range_m")
		_mid_fade_range_m = quality.get(&"mid_fade_range_m")
		_long_fade_range_m = quality.get(&"long_fade_range_m")


func _print_startup_summary() -> void:
	if _profile == null:
		return
	print("SPINDRIFT READY | authority=Crest G/LONG | trigger=[%.3f,%.3f] | cell=%.2fm | footprint=%.1f-%.1fm/half_width=%.1fm | detached=true" % [
		_profile.breaking_trigger_threshold, _profile.breaking_rearm_threshold, SENSOR_GRID_CELL_M, SENSOR_FORWARD_NEAR_M, SENSOR_FORWARD_FAR_M, SENSOR_HALF_WIDTH_M])


func _emit_spatial_debug(origin: Vector2, domains: Vector3) -> void:
	if not _is_position_debug() or _spatial_debug_printed:
		return
	_spatial_debug_printed = true
	print("SPINDRIFT POSITION DEBUG | world-cell sensors | source_region_center_world=%s size_world=(%.1f, %.1f) | domains=(%.3f, %.3f, %.3f) | axes world X->U, world Z->V" % [origin, SOURCE_REGION_SIZE_M, SOURCE_REGION_SIZE_M, domains.x, domains.y, domains.z])


static func world_cell_id(world_xz: Vector2, spacing: float) -> Vector2i:
	var safe_spacing := maxf(spacing, 0.001)
	return Vector2i(floori(world_xz.x / safe_spacing), floori(world_xz.y / safe_spacing))


static func hysteresis_event_count(values: Array[float], trigger: float, rearm: float) -> int:
	var active := false
	var events := 0
	for value in values:
		if not active and value >= trigger:
			active = true
			events += 1
		elif active and value <= rearm:
			active = false
	return events


static func debug_mode_name(mode: int) -> String:
	return ["OFF", "SOURCE_MASK_REAL", "CHUNKS_ONLY", "SPINDRIFT_ONLY", "MIST_ONLY", "FULL", "FORCE_EMISSION", "HEIGHT_ONLY", "STEEPNESS_ONLY", "CREST_ONLY", "POSITION_DEBUG", "SOURCE_MASK_FORCE_0", "SOURCE_MASK_FORCE_1", "POSITION_DEBUG_FORCE", "DEBUG_HEIGHT_RAW", "DEBUG_HEIGHT_GATE", "DEBUG_STEEPNESS_RAW", "DEBUG_STEEPNESS_GATE", "DEBUG_CREST_RAW", "DEBUG_CREST_GATE", "DEBUG_BREAKUP_RAW", "DEBUG_DOMAIN_FADE", "DEBUG_CLIPMAP_FADE", "DEBUG_SOURCE_PRE_THRESHOLD", "DEBUG_SOURCE_FINAL", "DEBUG_SHORT_FADE", "DEBUG_MID_FADE", "DEBUG_LONG_FADE", "DEBUG_ACTIVE_RADIUS_FADE", "DEBUG_CREST_GT_001", "DEBUG_CREST_GT_002", "DEBUG_CREST_GT_005", "DEBUG_CREST_GT_010", "DEBUG_CREST_GT_020", "DEBUG_CREST_GT_040", "DEBUG_CREST_GT_060", "DEBUG_CREST_GAIN_1", "DEBUG_CREST_GAIN_4", "DEBUG_CREST_GAIN_8", "DEBUG_CREST_GAIN_16"][clampi(mode, 0, 39)]


func _report_mode_change() -> void:
	if _last_reported_mode == _debug_mode:
		return
	_last_reported_mode = _debug_mode
	print("SPINDRIFT MODE -> %s" % debug_mode_name(_debug_mode))


func _on_profile_changed() -> void:
	_apply_profile()


func _exit_tree() -> void:
	if _profile != null and _profile.changed.is_connected(_on_profile_changed):
		_profile.changed.disconnect(_on_profile_changed)
	if _surface_debug_hidden:
		_surface_debug_hidden = false
		_restore_surface_visibility()
	for sensor in _sensor_layers:
		if sensor != null:
			sensor.emitting = false
