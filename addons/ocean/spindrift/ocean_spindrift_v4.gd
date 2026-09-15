class_name OceanSpindriftV4
extends Node3D
## Optional GPU-only Ocean V4 crest spray. No CPU particle simulation or readback.

const PARTICLE_SHADER := preload("res://addons/ocean/shaders/spindrift_particles.gdshader")
const RENDER_SHADER := preload("res://addons/ocean/shaders/spindrift_render.gdshader")
const SOURCE_MASK_SHADER := preload("res://addons/ocean/shaders/spindrift_source_mask.gdshader")
const ProfileScript := preload("res://addons/ocean/core/ocean_spindrift_profile.gd")
const CREST_BREAKUP_TEXTURE := preload("res://addons/ocean/surface/crest_breakup_noise.tres")

enum DebugMode { OFF, SOURCE_MASK, CHUNKS_ONLY, SPINDRIFT_ONLY, MIST_ONLY, FULL, FORCE_EMISSION, HEIGHT_ONLY, STEEPNESS_ONLY, CREST_ONLY, POSITION_DEBUG, SOURCE_MASK_FORCE_0, SOURCE_MASK_FORCE_1, POSITION_DEBUG_FORCE, DEBUG_HEIGHT_RAW, DEBUG_HEIGHT_GATE, DEBUG_STEEPNESS_RAW, DEBUG_STEEPNESS_GATE, DEBUG_CREST_RAW, DEBUG_CREST_GATE, DEBUG_BREAKUP_RAW, DEBUG_DOMAIN_FADE, DEBUG_CLIPMAP_FADE, DEBUG_SOURCE_PRE_THRESHOLD, DEBUG_SOURCE_FINAL, DEBUG_SHORT_FADE, DEBUG_MID_FADE, DEBUG_LONG_FADE, DEBUG_ACTIVE_RADIUS_FADE, DEBUG_CREST_GT_001, DEBUG_CREST_GT_002, DEBUG_CREST_GT_005, DEBUG_CREST_GT_010, DEBUG_CREST_GT_020, DEBUG_CREST_GT_040, DEBUG_CREST_GT_060, DEBUG_CREST_GAIN_1, DEBUG_CREST_GAIN_4, DEBUG_CREST_GAIN_8, DEBUG_CREST_GAIN_16 }

const DIAGNOSTIC_VISIBILITY_AABB := AABB(Vector3(-512.0, -256.0, -512.0), Vector3(1024.0, 512.0, 1024.0))
const FORCE_REGION_RADIUS_M := 6.0
const FORCE_REGION_DISTANCE_M := 10.0
const SOURCE_REGION_SIZE_M := 96.0
const POSITION_DEBUG_REGION_SIZE_M := 10.0
const DEBUG_HEIGHT_GAIN := 1.0
const DEBUG_STEEPNESS_GAIN := 4.0
const DEBUG_CREST_GAIN := 1.0
const DEBUG_BREAKUP_GAIN := 1.0
const LOCAL_CANDIDATE_COUNT := 6
const LOCAL_SEARCH_RADIUS_M := 4.0
const SPINDRIFT_RENDER_PRIORITY := 10
const CHUNKS_SPAWN_RADIUS_M := 6.0
const STREAKS_SPAWN_RADIUS_M := 10.0
const MIST_SPAWN_RADIUS_M := 8.0

var _source_provider: Node
var _profile: OceanSpindriftProfile
var _sea_level := 0.0
var _wind_speed_mps := 18.0
var _wind_direction_degrees := 0.0
var _debug_mode := DebugMode.FULL
var _enabled := false
var _source_bound := false
var _layers: Array[GPUParticles3D] = []
var _process_materials: Array[ShaderMaterial] = []
var _render_materials: Array[ShaderMaterial] = []
var _source_mask: MeshInstance3D
var _source_mask_material: ShaderMaterial
var _surface_node: Node3D
var _surface_initial_visible := true
var _last_origin := Vector2.INF
var _debug_camera_mask := 0
var _debug_camera_near := 0.0
var _debug_camera_far := 0.0
var _short_fade_range_m := Vector2(0.0, 55.0)
var _mid_fade_range_m := Vector2(96.0, 280.0)
var _long_fade_range_m := Vector2(768.0, 2500.0)
var _crest_detail_contribution := 0.35
var _crest_intensity := 0.96
var _crest_contrast := 1.19
var _crest_distance_fade_range_m := Vector2(0.0, 5000.0)
var _crest_breakup_strength := 0.45
var _crest_breakup_world_size_m := 14.0
var _crest_edge_softness := 0.32
var _long_whitecap_threshold := 0.62
var _mid_whitecap_threshold := 0.66
var _short_whitecap_threshold := 0.68
var _long_crest_weight := 1.0
var _mid_crest_weight := 0.65
var _short_crest_weight := 0.10
var _spatial_debug_printed := false
var _last_reported_mode := -1
var _source_audit_printed := false
var _crest_min := 0.001
var _crest_full := 0.03

@export_group("Crest Gate")
@export_range(0.0, 1.0, 0.001) var crest_min: float:
	get:
		return _crest_min
	set(value):
		_crest_min = clampf(value, 0.0, 0.999)
		if _crest_full <= _crest_min:
			_crest_full = minf(_crest_min + 0.001, 1.0)
		_apply_crest_gate_uniforms()

@export_range(0.0, 1.0, 0.001) var crest_full: float:
	get:
		return _crest_full
	set(value):
		_crest_full = clampf(value, 0.0, 1.0)
		if _crest_full <= _crest_min:
			_crest_full = minf(_crest_min + 0.001, 1.0)
		_apply_crest_gate_uniforms()

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
	_apply_crest_gate_uniforms()
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
	var configured := 0
	var active_layers := 0
	for layer in _layers:
		if layer == null: continue
		if layer.emitting:
			configured += layer.amount
			active_layers += 1
	return {
		"enabled": _enabled,
		"debug_mode": _debug_mode,
		"source_ready": _source_bound,
		"active_layers": active_layers,
		"configured_max_live_particles": configured,
		"chunks_amount": _layers[0].amount if _layers.size() > 0 else 0,
		"streaks_amount": _layers[1].amount if _layers.size() > 1 else 0,
		"mist_amount": _layers[2].amount if _layers.size() > 2 else 0,
		"region_radius_m": _profile.spindrift_radius if _profile != null else 0.0,
		"force_emission": _debug_mode == DebugMode.FORCE_EMISSION,
		"position_debug_force": _is_position_debug_force(),
		"crest_min": _crest_min,
		"crest_full": _safe_crest_full(),
		"debug_mode_name": debug_mode_name(_debug_mode),
		"visibility_aabb": DIAGNOSTIC_VISIBILITY_AABB,
		"source_region_center_world": _last_origin,
		"source_region_size_m": SOURCE_REGION_SIZE_M,
		"short_fade_range_m": _short_fade_range_m,
		"mid_fade_range_m": _mid_fade_range_m,
		"long_fade_range_m": _long_fade_range_m,
	}


func _ready() -> void:
	top_level = true


func _process(_delta: float) -> void:
	if not _enabled or _source_provider == null:
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
	var force_center := origin + forward_xz * FORCE_REGION_DISTANCE_M
	_debug_camera_mask = camera.cull_mask
	_debug_camera_near = camera.near
	_debug_camera_far = camera.far
	_last_origin = origin
	global_position = Vector3(origin.x, _sea_level, origin.y)
	for layer in _layers:
		if layer == null: continue
		# The culling region follows the emitter; particle transforms do not.
		layer.global_position = Vector3(origin.x, _sea_level, origin.y)
	_bind_sources()
	_apply_surface_debug_visibility()
	_update_uniforms(origin, force_center)
	_update_source_mask(origin)
	_emit_spatial_debug(origin, _source_domains())


func _create_layers() -> void:
	if not _layers.is_empty():
		return
	_layers.append(_create_layer("CrestChunks", 0))
	_layers.append(_create_layer("SpindriftStreaks", 1))
	_layers.append(_create_layer("FineMist", 2))
	_source_mask_material = ShaderMaterial.new()
	_source_mask_material.shader = SOURCE_MASK_SHADER
	_source_mask_material.set_shader_parameter(&"crest_breakup_texture", CREST_BREAKUP_TEXTURE)
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


func _create_layer(layer_name: String, layer_kind: int) -> GPUParticles3D:
	var particles := GPUParticles3D.new()
	particles.name = layer_name
	particles.top_level = true
	particles.local_coords = false
	particles.layers = 1
	particles.randomness = 0.90
	particles.explosiveness = 0.0
	particles.visibility_aabb = DIAGNOSTIC_VISIBILITY_AABB
	particles.draw_passes = 4
	var process_material := ShaderMaterial.new()
	process_material.shader = PARTICLE_SHADER
	process_material.set_shader_parameter(&"layer_kind", layer_kind)
	process_material.set_shader_parameter(&"crest_breakup_texture", CREST_BREAKUP_TEXTURE)
	particles.process_material = process_material
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var render_material := ShaderMaterial.new()
	render_material.shader = RENDER_SHADER
	render_material.render_priority = SPINDRIFT_RENDER_PRIORITY
	render_material.set_shader_parameter(&"layer_kind", layer_kind)
	quad.material = render_material
	particles.draw_pass_1 = quad
	particles.draw_pass_2 = null
	particles.draw_pass_3 = null
	particles.draw_pass_4 = null
	add_child(particles)
	_process_materials.append(process_material)
	_render_materials.append(render_material)
	return particles


func _apply_profile() -> void:
	if _profile == null or _layers.size() != 3: return
	_layers[0].amount = _profile.chunks_amount
	_layers[1].amount = _profile.streaks_amount
	_layers[2].amount = _profile.mist_amount
	_layers[0].lifetime = _profile.chunks_lifetime
	_layers[1].lifetime = _profile.streaks_lifetime
	_layers[2].lifetime = _profile.mist_lifetime
	for index in 3:
		_layers[index].visibility_aabb = DIAGNOSTIC_VISIBILITY_AABB
	_render_materials[0].set_shader_parameter(&"particle_tint", Color(_profile.chunks_color, 1.0))
	_render_materials[0].set_shader_parameter(&"opacity", _profile.chunks_alpha)
	_render_materials[0].set_shader_parameter(&"lod_end_m", _profile.chunks_lod_end_m)
	_render_materials[1].set_shader_parameter(&"particle_tint", Color(_profile.streaks_color, 1.0))
	_render_materials[1].set_shader_parameter(&"opacity", _profile.streaks_alpha)
	_render_materials[1].set_shader_parameter(&"lod_end_m", _profile.streaks_lod_end_m)
	_render_materials[2].set_shader_parameter(&"particle_tint", Color(_profile.mist_color, 1.0))
	_render_materials[2].set_shader_parameter(&"opacity", _profile.mist_alpha)
	_render_materials[2].set_shader_parameter(&"lod_end_m", _profile.mist_lod_end_m)
	_apply_debug_visuals()


func _update_uniforms(origin: Vector2, force_center: Vector2) -> void:
	if _profile == null: return
	var radians := deg_to_rad(_wind_direction_degrees)
	var direction := Vector2(cos(radians), sin(radians)).normalized()
	var domains := _source_domains()
	var position_debug := _is_position_debug()
	var position_debug_force := _is_position_debug_force()
	var source_override := _source_mask_override()
	for index in _process_materials.size():
		var process_material := _process_materials[index]
		process_material.set_shader_parameter(&"spindrift_origin", origin)
		process_material.set_shader_parameter(&"wind_direction", direction)
		process_material.set_shader_parameter(&"wind_speed_mps", _wind_speed_mps)
		process_material.set_shader_parameter(&"sea_level", _sea_level)
		process_material.set_shader_parameter(&"domain_long_m", domains.x)
		process_material.set_shader_parameter(&"domain_mid_m", domains.y)
		process_material.set_shader_parameter(&"domain_short_m", domains.z)
		process_material.set_shader_parameter(&"spindrift_radius", _profile.spindrift_radius)
		process_material.set_shader_parameter(&"spawn_radius_m", _spawn_radius_for_layer(index))
		process_material.set_shader_parameter(&"spawn_search_radius_m", LOCAL_SEARCH_RADIUS_M)
		process_material.set_shader_parameter(&"layer_amount", float(_layers[index].amount) if index < _layers.size() else 1.0)
		process_material.set_shader_parameter(&"source_spawn_min", _profile.source_spawn_min)
		process_material.set_shader_parameter(&"min_wave_strength", _profile.min_wave_strength)
		process_material.set_shader_parameter(&"emission_density", 1.0 if _is_force_emission() or position_debug else _profile.emission_density)
		process_material.set_shader_parameter(&"storm_strength", 1.0 if _is_force_emission() else _profile.storm_strength)
		process_material.set_shader_parameter(&"wind_velocity_multiplier", _profile.wind_velocity_multiplier)
		process_material.set_shader_parameter(&"crest_kick", _profile.crest_kick)
		process_material.set_shader_parameter(&"horizontal_spread", _profile.horizontal_spread)
		process_material.set_shader_parameter(&"vertical_spread", _profile.vertical_spread)
		process_material.set_shader_parameter(&"turbulence_strength", _profile.turbulence_strength)
		process_material.set_shader_parameter(&"turbulence_scale", _profile.turbulence_scale)
		process_material.set_shader_parameter(&"turbulence_speed", _profile.turbulence_speed)
		process_material.set_shader_parameter(&"long_whitecap_threshold", _long_whitecap_threshold)
		process_material.set_shader_parameter(&"mid_whitecap_threshold", _mid_whitecap_threshold)
		process_material.set_shader_parameter(&"short_whitecap_threshold", _short_whitecap_threshold)
		process_material.set_shader_parameter(&"long_crest_weight", _long_crest_weight)
		process_material.set_shader_parameter(&"mid_crest_weight", _mid_crest_weight)
		process_material.set_shader_parameter(&"short_crest_weight", _short_crest_weight)
		process_material.set_shader_parameter(&"force_emission", _is_force_emission())
		process_material.set_shader_parameter(&"force_center_xz", force_center)
		process_material.set_shader_parameter(&"force_center_y", _sea_level + 3.0)
		process_material.set_shader_parameter(&"force_region_radius", FORCE_REGION_RADIUS_M)
		process_material.set_shader_parameter(&"position_debug_center_xz", force_center)
		process_material.set_shader_parameter(&"position_debug_radius", POSITION_DEBUG_REGION_SIZE_M * 0.5)
		process_material.set_shader_parameter(&"position_debug_force", position_debug_force)
		process_material.set_shader_parameter(&"source_debug_stage", _source_debug_stage())
		process_material.set_shader_parameter(&"source_mask_override", source_override)
		process_material.set_shader_parameter(&"position_debug", position_debug)
		process_material.set_shader_parameter(&"short_fade_start_m", _short_fade_range_m.x)
		process_material.set_shader_parameter(&"short_fade_end_m", _short_fade_range_m.y)
		process_material.set_shader_parameter(&"mid_fade_start_m", _mid_fade_range_m.x)
		process_material.set_shader_parameter(&"mid_fade_end_m", _mid_fade_range_m.y)
		process_material.set_shader_parameter(&"long_fade_start_m", _long_fade_range_m.x)
		process_material.set_shader_parameter(&"long_fade_end_m", _long_fade_range_m.y)
		process_material.set_shader_parameter(&"crest_detail_contribution", _crest_detail_contribution)
		process_material.set_shader_parameter(&"crest_intensity", _crest_intensity)
		process_material.set_shader_parameter(&"crest_contrast", _crest_contrast)
		process_material.set_shader_parameter(&"crest_distance_fade_start_m", _crest_distance_fade_range_m.x)
		process_material.set_shader_parameter(&"crest_distance_fade_end_m", _crest_distance_fade_range_m.y)
		process_material.set_shader_parameter(&"crest_breakup_strength", _crest_breakup_strength)
		process_material.set_shader_parameter(&"crest_breakup_world_size_m", _crest_breakup_world_size_m)
		process_material.set_shader_parameter(&"crest_edge_softness", _crest_edge_softness)
	for render_material in _render_materials:
		render_material.set_shader_parameter(&"camera_world_xz", origin)
		render_material.set_shader_parameter(&"position_debug", position_debug)
	_source_mask_material.set_shader_parameter(&"mask_origin", origin)
	_source_mask_material.set_shader_parameter(&"sea_level", _sea_level)
	_source_mask_material.set_shader_parameter(&"domain_long_m", domains.x)
	_source_mask_material.set_shader_parameter(&"domain_mid_m", domains.y)
	_source_mask_material.set_shader_parameter(&"domain_short_m", domains.z)
	_source_mask_material.set_shader_parameter(&"min_wave_strength", _profile.min_wave_strength)
	_source_mask_material.set_shader_parameter(&"storm_strength", _profile.storm_strength)
	_source_mask_material.set_shader_parameter(&"source_debug_stage", _source_debug_stage())
	_source_mask_material.set_shader_parameter(&"short_fade_start_m", _short_fade_range_m.x)
	_source_mask_material.set_shader_parameter(&"short_fade_end_m", _short_fade_range_m.y)
	_source_mask_material.set_shader_parameter(&"mid_fade_start_m", _mid_fade_range_m.x)
	_source_mask_material.set_shader_parameter(&"mid_fade_end_m", _mid_fade_range_m.y)
	_source_mask_material.set_shader_parameter(&"long_fade_start_m", _long_fade_range_m.x)
	_source_mask_material.set_shader_parameter(&"long_fade_end_m", _long_fade_range_m.y)
	_source_mask_material.set_shader_parameter(&"long_whitecap_threshold", _long_whitecap_threshold)
	_source_mask_material.set_shader_parameter(&"mid_whitecap_threshold", _mid_whitecap_threshold)
	_source_mask_material.set_shader_parameter(&"short_whitecap_threshold", _short_whitecap_threshold)
	_source_mask_material.set_shader_parameter(&"long_crest_weight", _long_crest_weight)
	_source_mask_material.set_shader_parameter(&"mid_crest_weight", _mid_crest_weight)
	_source_mask_material.set_shader_parameter(&"short_crest_weight", _short_crest_weight)
	_source_mask_material.set_shader_parameter(&"crest_detail_contribution", _crest_detail_contribution)
	_source_mask_material.set_shader_parameter(&"crest_intensity", _crest_intensity)
	_source_mask_material.set_shader_parameter(&"crest_contrast", _crest_contrast)
	_source_mask_material.set_shader_parameter(&"crest_distance_fade_start_m", _crest_distance_fade_range_m.x)
	_source_mask_material.set_shader_parameter(&"crest_distance_fade_end_m", _crest_distance_fade_range_m.y)
	_source_mask_material.set_shader_parameter(&"crest_breakup_strength", _crest_breakup_strength)
	_source_mask_material.set_shader_parameter(&"crest_breakup_world_size_m", _crest_breakup_world_size_m)
	_source_mask_material.set_shader_parameter(&"crest_edge_softness", _crest_edge_softness)
	_source_mask_material.set_shader_parameter(&"source_override", source_override)
	_source_mask_material.set_shader_parameter(&"debug_output", _source_debug_output())
	_source_mask_material.set_shader_parameter(&"debug_height_gain", DEBUG_HEIGHT_GAIN)
	_source_mask_material.set_shader_parameter(&"debug_steepness_gain", DEBUG_STEEPNESS_GAIN)
	_source_mask_material.set_shader_parameter(&"debug_crest_gain", DEBUG_CREST_GAIN)
	_source_mask_material.set_shader_parameter(&"debug_breakup_gain", DEBUG_BREAKUP_GAIN)
	_source_mask_material.set_shader_parameter(&"debug_active_radius_m", _profile.spindrift_radius)


func _bind_sources() -> void:
	if _source_provider == null or not _source_provider.has_method(&"get_spindrift_sources"):
		return
	var data: Dictionary = _source_provider.get_spindrift_sources()
	if not bool(data.get("ready", false)):
		_source_bound = false
		_apply_gate(false)
		return
	for material in _process_materials:
		for key in ["displacement_long", "displacement_mid", "displacement_short", "normal_long", "normal_mid", "normal_short"]:
			material.set_shader_parameter(key, data[key])
	for key in ["displacement_long", "displacement_mid", "displacement_short", "normal_long", "normal_mid", "normal_short"]:
		_source_mask_material.set_shader_parameter(key, data[key])
	_source_bound = true
	if not _source_audit_printed:
		_source_audit_printed = true
		print("SPINDRIFT SOURCE AUDIT | productive spawn samples displacement_long/mid/short RGBA; xyz=displacement, a=instantaneous Jacobian from assemble_maps.glsl; thresholds/weights=OceanCrestFoamProfile; crest_foam textures are not sampled by Spindrift")
	_apply_gate()


func _update_source_mask(origin: Vector2) -> void:
	if _source_mask == null: return
	# The shader applies mask_origin to the mesh vertices. Keep the debug mesh at
	# world origin so the offset is not applied twice by the Node3D transform.
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
	if _layers.size() == 3:
		_layers[0].emitting = chunks
		_layers[1].emitting = streaks
		_layers[2].emitting = mist
		_layers[0].visible = chunks
		_layers[1].visible = streaks
		_layers[2].visible = mist


func _clear_particles_for_mask_debug() -> void:
	for layer in _layers:
		if layer == null:
			continue
		layer.emitting = false
		layer.restart()


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
	if _surface_node != null or _source_provider == null:
		return
	var candidate := _source_provider.get_node_or_null(^"OceanClipmapSurface") as Node3D
	if candidate == null:
		return
	_surface_node = candidate
	_surface_initial_visible = _surface_node.visible


func _apply_surface_debug_visibility() -> void:
	_cache_surface_node()
	if _surface_node == null:
		return
	_surface_node.visible = _surface_initial_visible and not (_enabled and _is_source_mask_debug())


func _source_debug_stage() -> int:
	match _debug_mode:
		DebugMode.HEIGHT_ONLY: return 1
		DebugMode.STEEPNESS_ONLY: return 2
		DebugMode.CREST_ONLY: return 3
		DebugMode.POSITION_DEBUG: return 3
		DebugMode.POSITION_DEBUG_FORCE: return 3
		_: return 0


func _source_debug_output() -> int:
	match _debug_mode:
		DebugMode.DEBUG_HEIGHT_RAW: return 1
		DebugMode.DEBUG_HEIGHT_GATE: return 2
		DebugMode.DEBUG_STEEPNESS_RAW: return 3
		DebugMode.DEBUG_STEEPNESS_GATE: return 4
		DebugMode.DEBUG_CREST_RAW: return 5
		DebugMode.DEBUG_CREST_GATE: return 6
		DebugMode.DEBUG_BREAKUP_RAW: return 7
		DebugMode.DEBUG_DOMAIN_FADE: return 8
		DebugMode.DEBUG_CLIPMAP_FADE: return 9
		DebugMode.DEBUG_SOURCE_PRE_THRESHOLD: return 10
		DebugMode.DEBUG_SOURCE_FINAL: return 11
		DebugMode.DEBUG_SHORT_FADE: return 12
		DebugMode.DEBUG_MID_FADE: return 13
		DebugMode.DEBUG_LONG_FADE: return 14
		DebugMode.DEBUG_ACTIVE_RADIUS_FADE: return 15
		DebugMode.DEBUG_CREST_GT_001: return 16
		DebugMode.DEBUG_CREST_GT_002: return 17
		DebugMode.DEBUG_CREST_GT_005: return 18
		DebugMode.DEBUG_CREST_GT_010: return 19
		DebugMode.DEBUG_CREST_GT_020: return 20
		DebugMode.DEBUG_CREST_GT_040: return 21
		DebugMode.DEBUG_CREST_GT_060: return 22
		DebugMode.DEBUG_CREST_GAIN_1: return 23
		DebugMode.DEBUG_CREST_GAIN_4: return 24
		DebugMode.DEBUG_CREST_GAIN_8: return 25
		DebugMode.DEBUG_CREST_GAIN_16: return 26
		DebugMode.SOURCE_MASK: return 11
		_: return 0


func _apply_debug_visuals() -> void:
	var force := _is_force_emission()
	var position_debug := _is_position_debug()
	var position_debug_force := _is_position_debug_force()
	for index in _layers.size():
		if index >= _render_materials.size(): continue
		_render_materials[index].set_shader_parameter(&"force_visible", force)
		_render_materials[index].set_shader_parameter(&"position_debug", position_debug)
		_process_materials[index].set_shader_parameter(&"force_emission", force)
		_process_materials[index].set_shader_parameter(&"position_debug", position_debug)
		_process_materials[index].set_shader_parameter(&"position_debug_force", position_debug_force)
		_layers[index].visibility_aabb = DIAGNOSTIC_VISIBILITY_AABB
		if _profile == null: continue
		if position_debug and index == 0:
			_layers[index].amount = 96
			_layers[index].lifetime = 5.0
		elif force:
			_layers[index].amount = [_profile.chunks_amount, _profile.streaks_amount, _profile.mist_amount][index]
			_layers[index].lifetime = maxf([_profile.chunks_lifetime, _profile.streaks_lifetime, _profile.mist_lifetime][index], 2.0)
		else:
			_layers[index].amount = [_profile.chunks_amount, _profile.streaks_amount, _profile.mist_amount][index]
			_layers[index].lifetime = [_profile.chunks_lifetime, _profile.streaks_lifetime, _profile.mist_lifetime][index]


func _safe_crest_full() -> float:
	return maxf(_crest_full, minf(_crest_min + 0.0001, 1.0))


func _spawn_radius_for_layer(layer_index: int) -> float:
	if _profile == null:
		return 0.0
	var emission_radius := MIST_SPAWN_RADIUS_M
	if layer_index == 0:
		emission_radius = CHUNKS_SPAWN_RADIUS_M
	elif layer_index == 1:
		emission_radius = STREAKS_SPAWN_RADIUS_M
	return minf(_profile.spindrift_radius, emission_radius)


func _apply_crest_gate_uniforms() -> void:
	var safe_full := _safe_crest_full()
	for process_material in _process_materials:
		if process_material == null:
			continue
		process_material.set_shader_parameter(&"crest_min", _crest_min)
		process_material.set_shader_parameter(&"crest_full", safe_full)
	if _source_mask_material != null:
		_source_mask_material.set_shader_parameter(&"crest_min", _crest_min)
		_source_mask_material.set_shader_parameter(&"crest_full", safe_full)


func _source_domains() -> Vector3:
	var domains := Vector3(512.0, 137.0, 37.0)
	if _source_provider != null and _source_provider.has_method(&"get_spindrift_sources"):
		var source_data: Dictionary = _source_provider.get_spindrift_sources()
		domains = source_data.get("domains", domains)
	return domains


func _print_startup_summary() -> void:
	if _profile == null:
		return
	print("SPINDRIFT READY | gate=[%.3f,%.3f] | spawn_min=%.3f | local_candidates=%d/radius=%.1fm | chunks=%d/%.1fm | streaks=%d/%.1fm | mist=%d/%.1fm" % [
		_crest_min, _safe_crest_full(), _profile.source_spawn_min, LOCAL_CANDIDATE_COUNT, LOCAL_SEARCH_RADIUS_M,
		_profile.chunks_amount, _spawn_radius_for_layer(0),
		_profile.streaks_amount, _spawn_radius_for_layer(1),
		_profile.mist_amount, _spawn_radius_for_layer(2)])


func _refresh_surface_alignment() -> void:
	if _source_provider == null:
		return
	var quality = _source_provider.get(&"_clipmap_quality")
	if quality != null:
		_short_fade_range_m = quality.get(&"short_fade_range_m")
		_mid_fade_range_m = quality.get(&"mid_fade_range_m")
		_long_fade_range_m = quality.get(&"long_fade_range_m")
	var crest_profile = _source_provider.get(&"_crest_foam_profile")
	if crest_profile != null:
		_crest_detail_contribution = float(crest_profile.get(&"detail_contribution"))
		_crest_intensity = float(crest_profile.get(&"intensity"))
		_crest_contrast = float(crest_profile.get(&"contrast"))
		_crest_distance_fade_range_m = crest_profile.get(&"distance_fade_range_m")
		_crest_breakup_strength = float(crest_profile.get(&"breakup_strength"))
		_crest_breakup_world_size_m = float(crest_profile.get(&"breakup_world_size_m"))
		_crest_edge_softness = float(crest_profile.get(&"edge_softness"))
		_long_whitecap_threshold = float(crest_profile.get(&"long_whitecap_threshold"))
		_mid_whitecap_threshold = float(crest_profile.get(&"mid_whitecap_threshold"))
		_short_whitecap_threshold = float(crest_profile.get(&"short_whitecap_threshold"))
		_long_crest_weight = float(crest_profile.get(&"long_weight"))
		_mid_crest_weight = float(crest_profile.get(&"mid_weight"))
		_short_crest_weight = float(crest_profile.get(&"short_weight"))


func _emit_spatial_debug(origin: Vector2, domains: Vector3) -> void:
	if not _is_position_debug() or _spatial_debug_printed:
		return
	_spatial_debug_printed = true
	var ocean_origin := Vector2(_source_provider.global_position.x, _source_provider.global_position.z) if _source_provider != null else Vector2.ZERO
	var position_center := origin + Vector2(0.0, -FORCE_REGION_DISTANCE_M)
	print("SPINDRIFT POSITION DEBUG | source_region_center_world=%s size_world=(%.1f, %.1f) | position_force_center_world=%s size_world=(%.1f, %.1f) | ocean_origin=%s spindrift_origin=%s surface_clipmap_origin=%s" % [origin, SOURCE_REGION_SIZE_M, SOURCE_REGION_SIZE_M, position_center, POSITION_DEBUG_REGION_SIZE_M, POSITION_DEBUG_REGION_SIZE_M, ocean_origin, origin, origin])
	print("SPINDRIFT POSITION DEBUG | source_texture_size=GPU Texture2DRD (no CPU readback) domains=(%.3f, %.3f, %.3f) | axes world X->U, world Z->V | V_inverted=NO | texture_phase_origin=(0,0) -> UV=(0.5,0.5)" % [domains.x, domains.y, domains.z])
	print("SPINDRIFT POSITION DEBUG | world_to_uv: uv=(world_xz/domain_m)+vec2(0.5) | inverse: world_xz=(uv-vec2(0.5))*domain_m | displacement=surface clipmap weighted bands with short=%s mid=%s long=%s | spawn_y=sea_level+2.0m (temporary XZ test)" % [_short_fade_range_m, _mid_fade_range_m, _long_fade_range_m])


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
	if _surface_node != null:
		_surface_node.visible = _surface_initial_visible
	for layer in _layers:
		if layer != null: layer.emitting = false
