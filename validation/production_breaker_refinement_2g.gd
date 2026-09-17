extends Node3D
## Production-only 2G validation shell. It supplies one real Coastal authority
## footprint and leaves FFT, Coastal, P7, material and lighting untouched.

const COASTAL_BAKE_PATH := "res://validation/p4_paradise/coastal_bake.tres"
const BREAKER_PROFILE_PATH := "res://validation/profiles/production_breaker_2g_profile.tres"
const VALIDATION_MIN_CREST_LENGTH_M := 4.0
const DETERMINISTIC_BREAKER_WORLD_XZ := Vector2(131.7186, -477.2817)
const CAMERA_TRAVEL_OFFSET_M := 14.0
const CAMERA_CREST_OFFSET_M := 8.0
const CAMERA_HEIGHT_M := 6.0
const CAMERA_TARGET_HEIGHT_M := 0.8

@export var refinement_enabled := true
@export var debug_tiles := false

var _ocean: Ocean
var _camera: Camera3D
var _origin := Vector2.ZERO
var _authority: Dictionary = {}
var _hud: Label
var _debug_layer: Node3D
var _debug_base: MeshInstance3D
var _debug_high: MeshInstance3D
var _last_debug_key := ""
var _elapsed := 0.0
var _bathymetry_sample
var _propagation_sample
var _warp_sample
var _p5_activation_proxy := 0.0
var _last_input := "none"
var _validation_printed := false


func _ready() -> void:
	_parse_args()
	call_deferred(&"_activate")


func _parse_args() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument == "--ocean-2g=off": refinement_enabled = false
		elif argument == "--ocean-2g=on": refinement_enabled = true
		elif argument == "--ocean-2g-debug": debug_tiles = true


func _activate() -> void:
	await get_tree().process_frame
	_ocean = get_node_or_null(^"P7Breakers/P0/Ocean") as Ocean
	_camera = get_node_or_null(^"P7Breakers/P0/FreeCamera") as Camera3D
	if _ocean == null or _camera == null:
		push_error("2G: P7 production scene nodes are missing.")
		return
	var bake := load(COASTAL_BAKE_PATH) as Resource
	if bake == null or bake.bathymetry == null or bake.propagation == null:
		push_error("2G: Coastal bake is missing.")
		return
	_origin = DETERMINISTIC_BREAKER_WORLD_XZ
	_bathymetry_sample = bake.bathymetry.sample_bathymetry(_origin)
	_propagation_sample = bake.propagation.sample_propagation(_origin)
	_warp_sample = bake.warp.sample_warp(_origin)
	if not _bathymetry_sample.in_bounds or not _bathymetry_sample.is_water or not _propagation_sample.valid or not _warp_sample.valid:
		push_error("2G: deterministic Production breaker point is not valid in the Coastal bake.")
		return
	var travel: Vector2 = -_propagation_sample.render_direction_xz.normalized()
	if travel.length_squared() < 0.000001:
		travel = _bathymetry_sample.gradient.normalized()
	if travel.length_squared() < 0.000001:
		travel = Vector2(0.0, 1.0)
	var crest := Vector2(-travel.y, travel.x)
	var crest_length: float = clampf(float(_propagation_sample.wavelength_m), VALIDATION_MIN_CREST_LENGTH_M, 12.0)
	_authority = {
		"active": true,
		"center_world": _origin,
		"travel_direction_world": travel,
		"crest_direction_world": crest,
		"crest_length": crest_length,
		"rear_extent": 2.0,
		"front_extent": 5.0,
		"strength": 1.0,
	}
	# The production clipmap is world-stationary. Re-anchor this validation
	# shell at the fixed bake-authoritative location so its L0 covers the breaker.
	_ocean.global_position = Vector3(_origin.x, 0.0, _origin.y)
	_ocean.coastal_bake = bake
	_ocean.coastal = true
	_ocean.breaker_profile = load(BREAKER_PROFILE_PATH)
	_ocean.breakers = true
	_ocean.set_local_breaker_refinement_authority(_authority)
	_ocean.set_local_breaker_refinement_debug_visible(debug_tiles)
	_ocean.set_local_breaker_refinement_enabled(refinement_enabled)
	_camera.set_process(false)
	_camera.set_process_input(false)
	var view_xz: Vector2 = _origin - travel * CAMERA_TRAVEL_OFFSET_M + crest * CAMERA_CREST_OFFSET_M
	_camera.global_position = Vector3(view_xz.x, CAMERA_HEIGHT_M, view_xz.y)
	_camera.look_at(Vector3(_origin.x, CAMERA_TARGET_HEIGHT_M, _origin.y), Vector3.UP)
	_p5_activation_proxy = _calculate_p5_activation_proxy()
	_build_debug_layer()
	_build_hud()
	_refresh()
	_validate_startup()
	print("2G AUTHORITY | node=P7Breakers/P0/Ocean | center=(%.3f,%.3f) travel=(%.3f,%.3f) crest_length=%.3f rear=2.000 front=5.000" % [_origin.x, _origin.y, travel.x, travel.y, crest_length])


func _process(delta: float) -> void:
	if _ocean == null:
		return
	_elapsed += maxf(delta, 0.0)
	if _elapsed < 0.10:
		return
	_elapsed = 0.0
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).keycode
	if key == KEY_F6:
		_last_input = "F6 received (A/B refinement)"
		refinement_enabled = not refinement_enabled
		_ocean.set_local_breaker_refinement_enabled(refinement_enabled)
		_refresh()
	elif key == KEY_F7:
		_last_input = "F7 received (HIGH region debug)"
		debug_tiles = not debug_tiles
		_ocean.set_local_breaker_refinement_debug_visible(debug_tiles)
		_refresh()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(14.0, 14.0)
	_hud.add_theme_font_size_override(&"font_size", 15)
	layer.add_child(_hud)


func _build_debug_layer() -> void:
	_debug_layer = Node3D.new()
	_debug_layer.name = "LocalBreakerRefinementDebug"
	add_child(_debug_layer)


func _refresh() -> void:
	if _hud == null or _ocean == null:
		return
	var info := _ocean.get_local_breaker_refinement_info()
	var runtime := _ocean.get_runtime_feature_state()
	var center: Vector2 = info.get("breaker_center_world", _origin)
	var camera_state := _camera_validation_state(Vector3(center.x, CAMERA_TARGET_HEIGHT_M, center.y))
	_hud.text = "2G PRODUCTION BREAKER VALIDATION\nBREAKER: ACTIVE | P5: %s | %s\nREFINEMENT: %s | F6: A OFF / B ON | F7: HIGH debug %s\nHIGH TILES: %d | COARSE TILES: %d | ACTIVE BATCHES: %d\nBREAKER POSITION: (%.3f, %.3f, %.3f)\nCAMERA POSITION: (%.3f, %.3f, %.3f)\nCAMERA FORWARD DOT: %.3f | DISTANCE: %.3f m | FRUSTUM: %s\nP5 AUTHORITY: P7Breakers/P0/Ocean | breakers=true | Coastal/VDM\nP5 INPUTS: depth %.2f m | shoaling %.3f | detJ %.3f | proxy %.3f\nDEBUG: F7 or launch with --ocean-2g-debug | last input: %s\nGPU/CPU: production benchmark --ocean-production=2g | rebuilds: %d" % [
		"READY" if bool(runtime.get("breakers_runtime_active", false)) and _p5_activation_proxy > 0.0 else "CHECK",
		"B — REFINEMENT ON" if refinement_enabled else "A — PRODUCTION BASE",
		"ON" if refinement_enabled else "OFF",
		"ON" if debug_tiles else "OFF",
		int(info.get("high_tile_count", 0)), int(info.get("coarse_tile_count", 0)), int(info.get("active_batch_count", 0)),
		center.x, 0.0, center.y,
		_camera.global_position.x, _camera.global_position.y, _camera.global_position.z,
		float(camera_state["dot"]), float(camera_state["distance"]), "YES" if bool(camera_state["in_frustum"]) else "NO",
		float(_bathymetry_sample.depth_m), float(_propagation_sample.shoaling_scale), float(_warp_sample.jacobian_det), _p5_activation_proxy,
		_last_input,
		int(info.get("arraymesh_rebuilds_runtime", 0)),
	]
	_update_debug(info)


func _calculate_p5_activation_proxy() -> float:
	# This mirrors the Production shader's Coastal gates using the same bake
	# inputs. It is a diagnostic, not a second deformation authority.
	var profile = _ocean.breaker_profile
	var shoreline_gate := smoothstep(float(profile.shallow_fade_start_m), maxf(float(profile.shallow_fade_end_m), float(profile.shallow_fade_start_m) + 0.001), float(_propagation_sample.depth_m))
	var deep_gate := 1.0 - smoothstep(float(profile.deep_activation_start_m), maxf(float(profile.deep_activation_end_m), float(profile.deep_activation_start_m) + 0.001), float(_propagation_sample.depth_m))
	var shoaling_gate := smoothstep(float(profile.shoaling_start), maxf(float(profile.shoaling_full), float(profile.shoaling_start) + 0.001), float(_propagation_sample.shoaling_scale))
	var compression_gate := 1.0 - smoothstep(float(profile.detj_compression_full), maxf(float(profile.detj_compression_start), float(profile.detj_compression_full) + 0.001), float(_warp_sample.jacobian_det))
	var confidence := float(_warp_sample.jacobian_det) / maxf(float(_ocean.coastal_bake.warp.detj_safe_threshold), 0.001)
	return clampf(clampf(confidence, 0.0, 1.0) * maxf(shoaling_gate, compression_gate) * shoreline_gate * deep_gate, 0.0, 1.0)


func _camera_validation_state(breaker_position: Vector3) -> Dictionary:
	var camera_forward := -_camera.global_transform.basis.z.normalized()
	var to_breaker := breaker_position - _camera.global_position
	var distance := to_breaker.length()
	var projected := _camera.unproject_position(breaker_position)
	var viewport_rect := get_viewport().get_visible_rect()
	var in_front := camera_forward.dot(to_breaker) > 0.0
	return {
		"dot": camera_forward.dot(to_breaker),
		"distance": distance,
		"in_front": in_front,
		"in_frustum": in_front and distance >= 8.0 and distance <= 24.0 and viewport_rect.has_point(projected),
	}


func _validate_startup() -> void:
	var info := _ocean.get_local_breaker_refinement_info()
	var state := _camera_validation_state(Vector3(_origin.x, CAMERA_TARGET_HEIGHT_M, _origin.y))
	var runtime := _ocean.get_runtime_feature_state()
	_validation_printed = true
	print("2G VALIDATION | breaker_active=%s | p5_runtime=%s | p5_activation_proxy=%.3f | depth=%.3f | shoaling=%.3f | detJ=%.3f | high_tiles=%d | coarse_tiles=%d" % [str(bool(_authority.get("active", false))), str(bool(runtime.get("breakers_runtime_active", false))), _p5_activation_proxy, float(_propagation_sample.depth_m), float(_propagation_sample.shoaling_scale), float(_warp_sample.jacobian_det), int(info.get("high_tile_count", 0)), int(info.get("coarse_tile_count", 0))])
	print("2G CAMERA | position=%s | forward=%s | breaker=%s | dot(camera_forward, breaker-camera)=%.3f | distance=%.3f | in_front=%s | frustum=%s" % [_camera.global_position, -_camera.global_transform.basis.z.normalized(), Vector3(_origin.x, CAMERA_TARGET_HEIGHT_M, _origin.y), float(state["dot"]), float(state["distance"]), str(bool(state["in_front"])), str(bool(state["in_frustum"]))])
	print("2G INPUT | F6=InputEventKey refinement OFF/ON | F7=InputEventKey HIGH region debug | startup_refinement=%s | startup_debug=%s" % [str(refinement_enabled), str(debug_tiles)])


func _update_debug(info: Dictionary) -> void:
	if _debug_layer == null:
		return
	var visible := debug_tiles and refinement_enabled
	if not visible:
		if is_instance_valid(_debug_base): _debug_base.visible = false
		if is_instance_valid(_debug_high): _debug_high.visible = false
		return
	var high_tiles: Array = info.get("high_tiles", [])
	var key := str(high_tiles) + ":" + str(info.get("grid_width", 0)) + ":" + str(info.get("grid_height", 0))
	if key == _last_debug_key:
		if is_instance_valid(_debug_base): _debug_base.visible = true
		if is_instance_valid(_debug_high): _debug_high.visible = true
		return
	_last_debug_key = key
	if is_instance_valid(_debug_base): _debug_base.queue_free()
	if is_instance_valid(_debug_high): _debug_high.queue_free()
	_debug_base = _make_debug_mesh("CoarseL0Outline", Color(0.2, 0.8, 1.0, 0.95), _debug_tile_lines(info, []))
	_debug_high = _make_debug_mesh("HighTiles", Color(1.0, 0.35, 0.05, 1.0), _debug_tile_lines(info, high_tiles))


func _debug_tile_lines(info: Dictionary, tiles: Array) -> Array[Vector3]:
	var lines: Array[Vector3] = []
	var width := int(info.get("grid_width", 0))
	var height := int(info.get("grid_height", 0))
	var tile_size_m: float = maxf(float(info.get("tile_size_m", VALIDATION_MIN_CREST_LENGTH_M)), 0.001)
	var origin: Vector2 = info.get("surface_origin_world", Vector2.ZERO)
	if tiles.is_empty():
		var extent := float(width) * tile_size_m * 0.5
		_append_rect(lines, origin, -extent, -extent, extent, extent)
		return lines
	for tile_value in tiles:
		var tile: Vector2i = tile_value
		var x0 := (float(tile.x) - float(width) * 0.5) * tile_size_m
		var z0 := (float(tile.y) - float(height) * 0.5) * tile_size_m
		_append_rect(lines, origin, x0, z0, x0 + tile_size_m, z0 + tile_size_m)
	return lines


func _append_rect(lines: Array[Vector3], origin: Vector2, x0: float, z0: float, x1: float, z1: float) -> void:
	var p0 := Vector3(origin.x + x0, 0.18, origin.y + z0)
	var p1 := Vector3(origin.x + x1, 0.18, origin.y + z0)
	var p2 := Vector3(origin.x + x1, 0.18, origin.y + z1)
	var p3 := Vector3(origin.x + x0, 0.18, origin.y + z1)
	lines.append_array([p0, p1, p1, p2, p2, p3, p3, p0])


func _make_debug_mesh(node_name: String, color: Color, lines: Array[Vector3]) -> MeshInstance3D:
	var immediate := ImmediateMesh.new()
	immediate.surface_begin(Mesh.PRIMITIVE_LINES)
	for point in lines:
		immediate.surface_set_color(color)
		immediate.surface_add_vertex(point)
	immediate.surface_end()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.no_depth_test = true
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = immediate
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_debug_layer.add_child(instance)
	return instance
