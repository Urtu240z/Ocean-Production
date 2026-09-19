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
## Supplied spray artwork. Every layer material binds all three so the visual
## families can overlap per particle instead of being segregated by layer.
const SPRAY_CHUNKS_TEXTURE := preload("res://addons/ocean/spindrift/textures/chunks.png")
const SPRAY_STREAKS_TEXTURE := preload("res://addons/ocean/spindrift/textures/streaks.png")
const SPRAY_MIST_TEXTURE := preload("res://addons/ocean/spindrift/textures/mist.png")

enum DebugMode { OFF, SOURCE_MASK, CHUNKS_ONLY, SPINDRIFT_ONLY, MIST_ONLY, FULL, FORCE_EMISSION, HEIGHT_ONLY, STEEPNESS_ONLY, CREST_ONLY, POSITION_DEBUG, SOURCE_MASK_FORCE_0, SOURCE_MASK_FORCE_1, POSITION_DEBUG_FORCE, DEBUG_HEIGHT_RAW, DEBUG_HEIGHT_GATE, DEBUG_STEEPNESS_RAW, DEBUG_STEEPNESS_GATE, DEBUG_CREST_RAW, DEBUG_CREST_GATE, DEBUG_BREAKUP_RAW, DEBUG_DOMAIN_FADE, DEBUG_CLIPMAP_FADE, DEBUG_SOURCE_PRE_THRESHOLD, DEBUG_SOURCE_FINAL, DEBUG_SHORT_FADE, DEBUG_MID_FADE, DEBUG_LONG_FADE, DEBUG_ACTIVE_RADIUS_FADE, DEBUG_CREST_GT_001, DEBUG_CREST_GT_002, DEBUG_CREST_GT_005, DEBUG_CREST_GT_010, DEBUG_CREST_GT_020, DEBUG_CREST_GT_040, DEBUG_CREST_GT_060, DEBUG_CREST_GAIN_1, DEBUG_CREST_GAIN_4, DEBUG_CREST_GAIN_8, DEBUG_CREST_GAIN_16 }

const PARTICLE_VISIBILITY_SIZE := Vector3(1024.0, 512.0, 1024.0)
const FORCE_REGION_RADIUS_M := 6.0
const FORCE_REGION_DISTANCE_M := 10.0
const SOURCE_REGION_SIZE_M := 96.0
const POSITION_DEBUG_REGION_SIZE_M := 10.0
const SPINDRIFT_RENDER_PRIORITY := 10
const SENSOR_GRID_CELL_M := 2.5
const MAX_EVENT_MULTIPLICITY := 2
const SOURCE_EDGE_FEATHER_FRACTION := 0.10
const SOURCE_EDGE_FEATHER_MIN_M := 4.0
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
var _sensor_anchor_xz := Vector2.ZERO
var _sensor_anchor_initialized := false
var _sensor_recenter_count := 0
var _sensor_ocean_space_requantize_count := 0
var _ocean_space_requantize_pending := false
var _debug_camera_mask := 0
var _debug_camera_near := 0.0
var _debug_camera_far := 0.0
var _short_fade_range_m := Vector2(0.0, 55.0)
var _mid_fade_range_m := Vector2(96.0, 280.0)
var _long_fade_range_m := Vector2(768.0, 2500.0)
var _spatial_debug_printed := false
var _last_reported_mode := -1
var _source_audit_printed := false
var _ocean_space := {"ocean_scale": 1.0, "clipmap_geometry_scale": 1.0, "revision": 0}


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
	if _source_provider != null and _source_provider.has_method(&"get_ocean_space_contract"):
		set_ocean_space(_source_provider.get_ocean_space_contract())


func set_ocean_space(contract: Dictionary) -> void:
	var old_horizontal_scale: float = _horizontal_scale()
	_ocean_space = contract.duplicate(true)
	_apply_source_region_scale()
	var new_horizontal_scale: float = _horizontal_scale()
	if absf(new_horizontal_scale - old_horizontal_scale) > 0.0001:
		var camera: Camera3D = get_viewport().get_camera_3d()
		if camera == null:
			_sensor_anchor_initialized = false
			_ocean_space_requantize_pending = true
		else:
			_requantize_sensor_lattice(camera)
	_refresh_uniforms_from_current_camera()


func _horizontal_scale() -> float:
	return maxf(float(_ocean_space.get("clipmap_geometry_scale", 1.0)), 0.0001)


func _effective_source_radius_m() -> float:
	return (_profile.spindrift_radius if _profile != null else SOURCE_REGION_SIZE_M * 0.5) * _horizontal_scale()


func _layer_lod_end_m(index: int) -> float:
	if _profile == null:
		return 0.0
	match index:
		0:
			return _profile.chunks_lod_end_m
		1:
			return _profile.streaks_lod_end_m
		2:
			return _profile.mist_lod_end_m
	return 0.0


func _layer_emission_radius_m(index: int) -> float:
	return minf(_effective_source_radius_m(), _layer_lod_end_m(index))


func _sensor_anchor_drift_margin_m() -> float:
	# A sensor keeps its world cell while the camera drifts away from the anchor,
	# and the anchor is snapped back onto the lattice, so the lattice must still
	# reach the whole footprint at the worst drift plus one snap cell.
	return _sensor_recenter_distance_limit_m() + SENSOR_GRID_CELL_M * _horizontal_scale()


func _layer_sensor_radius_m(index: int) -> float:
	# The lattice of a layer only has to cover what that layer can actually show
	# plus the anchor drift. Spreading every layer's budget over the full source
	# disk leaves the near visual footprint with almost no sensor on it.
	var required := _layer_emission_radius_m(index) + _sensor_anchor_drift_margin_m()
	return clampf(required, SENSOR_GRID_CELL_M * _horizontal_scale() * 2.0, _effective_source_radius_m())


func _layer_footprint_sensor_estimate(index: int) -> float:
	# Uniform-by-area lattice: the share of a layer's sensors that can ever be
	# inside its own visual footprint.
	var sensor_radius := _layer_sensor_radius_m(index)
	if sensor_radius <= 0.0:
		return 0.0
	var ratio := _layer_emission_radius_m(index) / sensor_radius
	return _sensor_layer_amount(index) * ratio * ratio


func _sensor_layer_amount(index: int) -> float:
	if _profile == null:
		return 0.0
	match index:
		0:
			return float(_profile.chunks_amount)
		1:
			return float(_profile.streaks_amount)
	return float(_profile.mist_amount)


func _apply_source_region_scale() -> void:
	if _source_mask == null:
		return
	var plane := _source_mask.mesh as PlaneMesh
	if plane == null:
		return
	var size_m := _source_region_diameter_m()
	plane.size = Vector2(size_m, size_m)


func _source_region_diameter_m() -> float:
	var authored_radius := _profile.spindrift_radius if _profile != null else SOURCE_REGION_SIZE_M * 0.5
	return maxf(authored_radius * 2.0, SOURCE_REGION_SIZE_M) * _horizontal_scale()


func _source_edge_feather_m() -> float:
	var authored_radius := _profile.spindrift_radius if _profile != null else SOURCE_REGION_SIZE_M * 0.5
	return maxf(authored_radius * SOURCE_EDGE_FEATHER_FRACTION, SOURCE_EDGE_FEATHER_MIN_M) * _horizontal_scale()


func _particle_visibility_aabb(anchor_xz: Vector2) -> AABB:
	var center := Vector3(anchor_xz.x, _sea_level, anchor_xz.y)
	return AABB(center - PARTICLE_VISIBILITY_SIZE * 0.5, PARTICLE_VISIBILITY_SIZE)


func _sensor_recenter_distance_limit_m() -> float:
	var horizontal_scale := _horizontal_scale()
	var radius := (_profile.spindrift_radius if _profile != null else SOURCE_REGION_SIZE_M * 0.5) * horizontal_scale
	var max_layer_lod := 0.0
	if _profile != null:
		max_layer_lod = maxf(_profile.chunks_lod_end_m, maxf(_profile.streaks_lod_end_m, _profile.mist_lod_end_m))
	var cell := SENSOR_GRID_CELL_M * horizontal_scale
	return maxf(cell * 4.0, minf(radius * 0.25, max_layer_lod * 0.5))


func _requantize_sensor_lattice(camera: Camera3D) -> void:
	if camera == null:
		_sensor_anchor_initialized = false
		_ocean_space_requantize_pending = true
		return
	var origin := Vector2(camera.global_position.x, camera.global_position.z)
	_sensor_anchor_xz = _snap_sensor_anchor(origin)
	_sensor_anchor_initialized = true
	_last_origin = origin
	_set_particle_visibility_aabb(_sensor_anchor_xz)
	for sensor in _sensor_layers:
		if sensor != null:
			sensor.restart()
	_sensor_ocean_space_requantize_count += 1
	_ocean_space_requantize_pending = false
	_update_source_mask(_sensor_anchor_xz)


func _refresh_uniforms_from_current_camera() -> void:
	var camera: Camera3D = get_viewport().get_camera_3d()
	if camera == null:
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
	_last_origin = origin
	_update_uniforms(origin, origin + forward_xz * FORCE_REGION_DISTANCE_M * _horizontal_scale(), forward_xz, right_xz)


func _snap_sensor_anchor(camera_xz: Vector2) -> Vector2:
	var cell := maxf(SENSOR_GRID_CELL_M * _horizontal_scale(), 0.1)
	return Vector2(floor(camera_xz.x / cell), floor(camera_xz.y / cell)) * cell


func _set_particle_visibility_aabb(anchor_xz: Vector2) -> void:
	var aabb := _particle_visibility_aabb(anchor_xz)
	for sensor in _sensor_layers:
		if sensor != null:
			sensor.visibility_aabb = aabb
	for particle_layer in _layers:
		if particle_layer != null:
			particle_layer.visibility_aabb = aabb


func _update_sensor_anchor(camera_xz: Vector2) -> bool:
	var snapped_anchor := _snap_sensor_anchor(camera_xz)
	var changed := not _sensor_anchor_initialized
	if _sensor_anchor_initialized and camera_xz.distance_to(_sensor_anchor_xz) > _sensor_recenter_distance_limit_m():
		changed = true
	if changed:
		if _sensor_anchor_initialized:
			_sensor_recenter_count += 1
		_sensor_anchor_xz = snapped_anchor
		_sensor_anchor_initialized = true
		_set_particle_visibility_aabb(_sensor_anchor_xz)
	return changed


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
	var sensor_layer_amounts: Array[int] = []
	var visible_layer_capacities: Array[int] = []
	var visible_layer_lifetimes: Array[float] = []
	for layer in _sensor_layers:
		if layer != null:
			sensor_count += layer.amount
			sensor_layer_amounts.append(layer.amount)
	for layer in _layers:
		if layer != null:
			visible_layer_capacities.append(layer.amount)
			visible_layer_lifetimes.append(layer.lifetime)
			if layer.visible:
				visible_count += layer.amount
	return {
		"enabled": _enabled,
		"debug_mode": _debug_mode,
		"source_ready": _source_bound,
		"active_layers": _active_layer_count(),
		"configured_max_live_particles": visible_count,
		"sensor_count": sensor_count,
		"sensor_layer_amounts": sensor_layer_amounts,
		"visible_layer_capacities": visible_layer_capacities,
		"visible_layer_lifetimes": visible_layer_lifetimes,
		"visible_particle_capacity": visible_count,
		"visible_particle_budget": visible_count,
		"max_event_multiplicity": MAX_EVENT_MULTIPLICITY,
		"event_density": _profile.emission_density if _profile != null else 0.0,
		"trigger_threshold": _profile.breaking_trigger_threshold if _profile != null else 0.0,
		"rearm_threshold": _profile.breaking_rearm_threshold if _profile != null else 0.0,
		"breaking_activity_authority": "crest_g_long",
		"breaking_activity_channel": 1,
		"breaking_activity_range": Vector2(0.0, 1.0),
		"world_cell_identity": "floor(world_xz / sensor_grid_cell_m)",
		"detached_particles": true,
		"spindrift_radius_m": _profile.spindrift_radius if _profile != null else 0.0,
		"source_region_shape": "snapped_sensor_anchor_disk",
		"effective_source_radius_m": _effective_source_radius_m(),
		"source_edge_feather_m": _source_edge_feather_m(),
		"layer_lod_end_m": [
			_profile.chunks_lod_end_m,
			_profile.streaks_lod_end_m,
			_profile.mist_lod_end_m
		] if _profile != null else [],
		"effective_visual_radius_m": [
			_layer_emission_radius_m(0),
			_layer_emission_radius_m(1),
			_layer_emission_radius_m(2)
		],
		"layer_emission_radius_m": [
			_layer_emission_radius_m(0),
			_layer_emission_radius_m(1),
			_layer_emission_radius_m(2)
		],
		"layer_sensor_radius_m": [
			_layer_sensor_radius_m(0),
			_layer_sensor_radius_m(1),
			_layer_sensor_radius_m(2)
		],
		"layer_footprint_sensor_estimate": [
			_layer_footprint_sensor_estimate(0),
			_layer_footprint_sensor_estimate(1),
			_layer_footprint_sensor_estimate(2)
		],
		"sensor_anchor_drift_margin_m": _sensor_anchor_drift_margin_m(),
		"sensor_distribution_rule": "layer_lattice_radius_is_emission_radius_plus_anchor_drift",
		"sensor_distribution": "low_discrepancy_disk_index",
		"debug_mode_name": debug_mode_name(_debug_mode),
		"visibility_aabb": _particle_visibility_aabb(_sensor_anchor_xz),
		"particle_visibility_aabb": _particle_visibility_aabb(_sensor_anchor_xz),
		"particle_visibility_center_world": Vector3(_sensor_anchor_xz.x, _sea_level, _sensor_anchor_xz.y),
		"sensor_anchor_world": Vector3(_sensor_anchor_xz.x, _sea_level, _sensor_anchor_xz.y),
		"source_region_center_world": _sensor_anchor_xz,
		"sensor_anchor_distance_from_camera": _last_origin.distance_to(_sensor_anchor_xz) if _last_origin.is_finite() else 0.0,
		"sensor_recenter_distance_m": _sensor_recenter_distance_limit_m(),
		"sensor_recenter_count": _sensor_recenter_count,
		"sensor_ocean_space_requantize_count": _sensor_ocean_space_requantize_count,
		"camera_inside_particle_visibility": _particle_visibility_aabb(_sensor_anchor_xz).has_point(Vector3(_last_origin.x, _sea_level, _last_origin.y)) if _last_origin.is_finite() else false,
		"camera_distance_from_visibility_center": _last_origin.distance_to(_sensor_anchor_xz) if _last_origin.is_finite() else 0.0,
		"source_region_size_m": _source_region_diameter_m(),
		"ocean_space": _ocean_space.duplicate(true),
		"sensor_grid_cell_m": SENSOR_GRID_CELL_M * _horizontal_scale(),
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
	var force_center := origin + forward_xz * FORCE_REGION_DISTANCE_M * _horizontal_scale()
	_debug_camera_mask = camera.cull_mask
	_debug_camera_near = camera.near
	_debug_camera_far = camera.far
	_last_origin = origin
	var sensor_anchor_changed := _update_sensor_anchor(origin)
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
	if sensor_anchor_changed:
		for sensor in _sensor_layers:
			if sensor != null:
				sensor.restart()
		if _ocean_space_requantize_pending:
			_sensor_ocean_space_requantize_count += 1
			_ocean_space_requantize_pending = false
	_update_source_mask(_sensor_anchor_xz)
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
	plane.size = Vector2(_source_region_diameter_m(), _source_region_diameter_m())
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
	sensor.visibility_aabb = _particle_visibility_aabb(_sensor_anchor_xz)
	# The sensor has no draw mesh. Its only visible output is its sub-emitter.
	sensor.draw_passes = 1
	var process_material := ShaderMaterial.new()
	process_material.shader = PARTICLE_SHADER
	process_material.set_shader_parameter(&"layer_kind", layer_kind)
	sensor.process_material = process_material
	add_child(sensor)

	var visible_particles := GPUParticles3D.new()
	visible_particles.name = layer_name + "Visible"
	visible_particles.top_level = true
	visible_particles.local_coords = false
	visible_particles.layers = 1
	visible_particles.randomness = 0.0
	visible_particles.explosiveness = 1.0
	visible_particles.visibility_aabb = _particle_visibility_aabb(_sensor_anchor_xz)
	var detached_material := ShaderMaterial.new()
	detached_material.shader = DETACHED_PARTICLE_SHADER
	visible_particles.process_material = detached_material
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var render_material := ShaderMaterial.new()
	render_material.shader = RENDER_SHADER
	render_material.render_priority = SPINDRIFT_RENDER_PRIORITY
	render_material.set_shader_parameter(&"layer_kind", layer_kind)
	render_material.set_shader_parameter(&"spray_chunks", SPRAY_CHUNKS_TEXTURE)
	render_material.set_shader_parameter(&"spray_streaks", SPRAY_STREAKS_TEXTURE)
	render_material.set_shader_parameter(&"spray_mist", SPRAY_MIST_TEXTURE)
	quad.material = render_material
	visible_particles.draw_pass_1 = quad
	visible_particles.draw_passes = 1
	add_child(visible_particles)
	sensor.sub_emitter = NodePath("../" + visible_particles.name)
	_sensor_layers.append(sensor)
	_layers.append(visible_particles)
	_process_materials.append(process_material)
	_detached_materials.append(detached_material)
	_render_materials.append(render_material)


func _art_arrays() -> Dictionary:
	## Per-layer art values, read once per call instead of repeating index
	## ternaries. Layer order is always chunks, streaks, mist.
	if _profile == null:
		return {}
	return {
		"fade_in": [_profile.chunks_fade_in_fraction, _profile.streaks_fade_in_fraction, _profile.mist_fade_in_fraction],
		"fade_out_start": [_profile.chunks_fade_out_start_fraction, _profile.streaks_fade_out_start_fraction, _profile.mist_fade_out_start_fraction],
		"water_fade_height": [_profile.chunks_water_fade_height_m, _profile.streaks_water_fade_height_m, _profile.mist_water_fade_height_m],
		"gravity": [_profile.chunks_gravity_mps2, _profile.streaks_gravity_mps2, _profile.mist_gravity_mps2],
		"wind_drag": [_profile.chunks_wind_drag, _profile.streaks_wind_drag, _profile.mist_wind_drag],
		"turbulence_multiplier": [_profile.chunks_turbulence_multiplier, _profile.streaks_turbulence_multiplier, _profile.mist_turbulence_multiplier],
		"visual_scale": [_profile.chunks_visual_scale, _profile.streaks_visual_scale, _profile.mist_visual_scale],
		"shape_width_scale": [_profile.chunks_width_scale, _profile.streaks_width_scale, _profile.mist_width_scale],
		"shape_length_scale": [_profile.chunks_length_scale, _profile.streaks_length_scale, _profile.mist_length_scale],
		"edge_softness": [_profile.chunks_edge_softness, _profile.streaks_edge_softness, _profile.mist_edge_softness],
		"breakup_strength": [_profile.chunks_breakup_strength, _profile.streaks_breakup_strength, _profile.mist_breakup_strength],
		"mottle_strength": [_profile.chunks_mottle_strength, _profile.streaks_mottle_strength, _profile.mist_mottle_strength],
		"terminal_scale": [_profile.chunks_terminal_scale, _profile.streaks_terminal_scale, _profile.mist_terminal_scale],
		"core_strength": [_profile.chunks_core_strength, _profile.streaks_core_strength, _profile.mist_core_strength],
	}


func _apply_art_bindings() -> void:
	## Art values only change with the profile, so they are bound here instead of
	## on every frame. Art changes must not reset sensor hysteresis or emission.
	var art := _art_arrays()
	if art.is_empty():
		return
	var fade_in: Array = art["fade_in"]
	var fade_out_start: Array = art["fade_out_start"]
	var water_fade_height: Array = art["water_fade_height"]
	var gravity: Array = art["gravity"]
	var wind_drag: Array = art["wind_drag"]
	var turbulence_multiplier: Array = art["turbulence_multiplier"]
	var visual_scale: Array = art["visual_scale"]
	var shape_width_scale: Array = art["shape_width_scale"]
	var shape_length_scale: Array = art["shape_length_scale"]
	var edge_softness: Array = art["edge_softness"]
	var breakup_strength: Array = art["breakup_strength"]
	var mottle_strength: Array = art["mottle_strength"]
	var terminal_scale: Array = art["terminal_scale"]
	var core_strength: Array = art["core_strength"]
	for index in 3:
		_render_materials[index].set_shader_parameter(&"sea_level", _sea_level)
		_render_materials[index].set_shader_parameter(&"fade_in_fraction", float(fade_in[index]))
		_render_materials[index].set_shader_parameter(&"fade_out_start_fraction", float(fade_out_start[index]))
		_render_materials[index].set_shader_parameter(&"water_fade_height_m", float(water_fade_height[index]))
		_render_materials[index].set_shader_parameter(&"visual_scale", float(visual_scale[index]))
		_render_materials[index].set_shader_parameter(&"shape_width_scale", float(shape_width_scale[index]))
		_render_materials[index].set_shader_parameter(&"shape_length_scale", float(shape_length_scale[index]))
		_render_materials[index].set_shader_parameter(&"edge_softness", float(edge_softness[index]))
		_render_materials[index].set_shader_parameter(&"breakup_strength", float(breakup_strength[index]))
		_render_materials[index].set_shader_parameter(&"mottle_strength", float(mottle_strength[index]))
		_render_materials[index].set_shader_parameter(&"terminal_scale", float(terminal_scale[index]))
		_render_materials[index].set_shader_parameter(&"core_strength", float(core_strength[index]))
		_detached_materials[index].set_shader_parameter(&"gravity_mps2", float(gravity[index]))
		_detached_materials[index].set_shader_parameter(&"wind_drag", float(wind_drag[index]))
		_detached_materials[index].set_shader_parameter(&"turbulence_strength", _profile.turbulence_strength * float(turbulence_multiplier[index]))
		_detached_materials[index].set_shader_parameter(&"turbulence_scale", _profile.turbulence_scale)
		_detached_materials[index].set_shader_parameter(&"turbulence_speed", _profile.turbulence_speed)
		_detached_materials[index].set_shader_parameter(&"sea_level", _sea_level)
		_detached_materials[index].set_shader_parameter(&"water_kill_depth_m", _profile.water_kill_depth_m)


func _apply_profile() -> void:
	if _profile == null or _sensor_layers.size() != 3:
		return
	var amounts := [_profile.chunks_amount, _profile.streaks_amount, _profile.mist_amount]
	var lifetimes := [_profile.chunks_lifetime, _profile.streaks_lifetime, _profile.mist_lifetime]
	for index in 3:
		# Structural values are assigned only when they really change: setting
		# amount/lifetime reallocates the particle buffer and would restart the
		# sensors on a purely artistic profile edit.
		if _sensor_layers[index].amount != int(amounts[index]):
			_sensor_layers[index].amount = amounts[index]
		if not is_equal_approx(_sensor_layers[index].lifetime, SENSOR_LIFETIME_S):
			_sensor_layers[index].lifetime = SENSOR_LIFETIME_S
		var visible_capacity: int = int(amounts[index]) * MAX_EVENT_MULTIPLICITY
		if _layers[index].amount != visible_capacity:
			_layers[index].amount = visible_capacity
		if not is_equal_approx(_layers[index].lifetime, float(lifetimes[index])):
			_layers[index].lifetime = lifetimes[index]
		_sensor_layers[index].visibility_aabb = _particle_visibility_aabb(_sensor_anchor_xz)
		_layers[index].visibility_aabb = _particle_visibility_aabb(_sensor_anchor_xz)
		_render_materials[index].set_shader_parameter(&"particle_tint", Color([_profile.chunks_color, _profile.streaks_color, _profile.mist_color][index], 1.0))
		_render_materials[index].set_shader_parameter(&"opacity", [_profile.chunks_alpha, _profile.streaks_alpha, _profile.mist_alpha][index])
		_render_materials[index].set_shader_parameter(&"lod_end_m", [_profile.chunks_lod_end_m, _profile.streaks_lod_end_m, _profile.mist_lod_end_m][index])
	_apply_art_bindings()
	_apply_debug_visuals()


func _update_uniforms(origin: Vector2, force_center: Vector2, camera_forward_xz: Vector2, camera_right_xz: Vector2) -> void:
	if _profile == null:
		return
	var radians := deg_to_rad(_wind_direction_degrees)
	var wind_direction := Vector2(cos(radians), sin(radians)).normalized()
	var wind_velocity := Vector3(wind_direction.x, 0.0, wind_direction.y) * _wind_speed_mps * _profile.wind_velocity_multiplier * lerpf(0.30, 1.0, _profile.storm_strength)
	var domains := _source_domains()
	var horizontal_scale := maxf(float(_ocean_space.get("clipmap_geometry_scale", 1.0)), 0.0001)
	var vertical_scale := maxf(float(_ocean_space.get("ocean_scale", 1.0)), 0.0001)
	var position_debug := _is_position_debug()
	var position_debug_force := _is_position_debug_force()
	var source_override := _source_mask_override()
	for index in _process_materials.size():
		var process_material := _process_materials[index]
		process_material.set_shader_parameter(&"sensor_anchor_xz", _sensor_anchor_xz)
		process_material.set_shader_parameter(&"camera_forward_xz", camera_forward_xz)
		process_material.set_shader_parameter(&"camera_right_xz", camera_right_xz)
		process_material.set_shader_parameter(&"sensor_grid_cell_m", SENSOR_GRID_CELL_M * horizontal_scale)
		process_material.set_shader_parameter(&"source_edge_feather_m", _source_edge_feather_m())
		process_material.set_shader_parameter(&"wind_direction", wind_direction)
		process_material.set_shader_parameter(&"wind_speed_mps", _wind_speed_mps)
		process_material.set_shader_parameter(&"sea_level", _sea_level)
		process_material.set_shader_parameter(&"domain_long_m", domains.x)
		process_material.set_shader_parameter(&"domain_mid_m", domains.y)
		process_material.set_shader_parameter(&"domain_short_m", domains.z)
		process_material.set_shader_parameter(&"ocean_surface_scale", vertical_scale)
		process_material.set_shader_parameter(&"clipmap_geometry_scale", horizontal_scale)
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
		process_material.set_shader_parameter(&"force_region_radius", FORCE_REGION_RADIUS_M * horizontal_scale)
		process_material.set_shader_parameter(&"position_debug_center_xz", force_center)
		process_material.set_shader_parameter(&"position_debug_radius", POSITION_DEBUG_REGION_SIZE_M * 0.5 * horizontal_scale)
		process_material.set_shader_parameter(&"position_debug", position_debug)
		process_material.set_shader_parameter(&"position_debug_force", position_debug_force)
		process_material.set_shader_parameter(&"short_fade_start_m", _short_fade_range_m.x)
		process_material.set_shader_parameter(&"short_fade_end_m", _short_fade_range_m.y)
		process_material.set_shader_parameter(&"mid_fade_start_m", _mid_fade_range_m.x)
		process_material.set_shader_parameter(&"mid_fade_end_m", _mid_fade_range_m.y)
		process_material.set_shader_parameter(&"long_fade_start_m", _long_fade_range_m.x)
		process_material.set_shader_parameter(&"long_fade_end_m", _long_fade_range_m.y)
		process_material.set_shader_parameter(&"camera_world_xz", origin)
		process_material.set_shader_parameter(&"active_radius_m", _effective_source_radius_m())
		process_material.set_shader_parameter(&"sensor_radius_m", _layer_sensor_radius_m(index))
		process_material.set_shader_parameter(&"emission_radius_m", _layer_emission_radius_m(index))
		_detached_materials[index].set_shader_parameter(&"wind_velocity", wind_velocity)
	for render_material in _render_materials:
		render_material.set_shader_parameter(&"camera_world_xz", origin)
		render_material.set_shader_parameter(&"source_radius_m", _profile.spindrift_radius * horizontal_scale)
		render_material.set_shader_parameter(&"position_debug", position_debug)
	_source_mask_material.set_shader_parameter(&"sensor_anchor_xz", _sensor_anchor_xz)
	_source_mask_material.set_shader_parameter(&"sea_level", _sea_level)
	_source_mask_material.set_shader_parameter(&"domain_long_m", domains.x)
	_source_mask_material.set_shader_parameter(&"domain_mid_m", domains.y)
	_source_mask_material.set_shader_parameter(&"domain_short_m", domains.z)
	_source_mask_material.set_shader_parameter(&"ocean_surface_scale", vertical_scale)
	_source_mask_material.set_shader_parameter(&"clipmap_geometry_scale", horizontal_scale)
	_source_mask_material.set_shader_parameter(&"source_override", source_override)
	_source_mask_material.set_shader_parameter(&"debug_output", _source_debug_output())
	_source_mask_material.set_shader_parameter(&"active_radius_m", _profile.spindrift_radius * horizontal_scale)
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
	_source_mask.global_position = Vector3(origin.x, _sea_level, origin.y)
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
	print("SPINDRIFT READY | authority=Crest G/LONG | trigger=[%.3f,%.3f] | cell=%.2fm | source_disk_radius=%.1fm edge_feather=%.1fm | detached=true" % [
		_profile.breaking_trigger_threshold, _profile.breaking_rearm_threshold, SENSOR_GRID_CELL_M, _profile.spindrift_radius, _source_edge_feather_m()])
	print("SPINDRIFT LATTICE | anchor_margin=%.1fm | layer_emission_radius=%s | layer_sensor_radius=%s | footprint_sensors=%s of %s" % [
		_sensor_anchor_drift_margin_m(),
		[_layer_emission_radius_m(0), _layer_emission_radius_m(1), _layer_emission_radius_m(2)],
		[_layer_sensor_radius_m(0), _layer_sensor_radius_m(1), _layer_sensor_radius_m(2)],
		[snappedf(_layer_footprint_sensor_estimate(0), 0.1), snappedf(_layer_footprint_sensor_estimate(1), 0.1), snappedf(_layer_footprint_sensor_estimate(2), 0.1)],
		[_profile.chunks_amount, _profile.streaks_amount, _profile.mist_amount]])


func _emit_spatial_debug(origin: Vector2, domains: Vector3) -> void:
	if not _is_position_debug() or _spatial_debug_printed:
		return
	_spatial_debug_printed = true
	var source_radius := (_profile.spindrift_radius if _profile != null else SOURCE_REGION_SIZE_M * 0.5) * _horizontal_scale()
	print("SPINDRIFT POSITION DEBUG | world-cell sensors | source_region_center_world=%s shape=snapped_sensor_anchor_disk radius=%.1f | domains=(%.3f, %.3f, %.3f) | axes world X->U, world Z->V" % [_sensor_anchor_xz, source_radius, domains.x, domains.y, domains.z])


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
	_apply_source_region_scale()


func _exit_tree() -> void:
	if _profile != null and _profile.changed.is_connected(_on_profile_changed):
		_profile.changed.disconnect(_on_profile_changed)
	if _surface_debug_hidden:
		_surface_debug_hidden = false
		_restore_surface_visibility()
	for sensor in _sensor_layers:
		if sensor != null:
			sensor.emitting = false
