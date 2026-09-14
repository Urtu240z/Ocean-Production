extends Node3D
## Production-only 2G validation shell. It supplies one real Coastal authority
## footprint and leaves FFT, Coastal, P7, material and lighting untouched.

const COASTAL_BAKE_PATH := "res://validation/p4_paradise/coastal_bake.tres"
const TILE_SIZE_M := 4.0

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
	var selected := _find_shallow_test_location(bake.bathymetry, Vector2(_camera.global_position.x, _camera.global_position.z))
	if selected.is_empty():
		push_error("2G: no valid shallow Coastal point was found.")
		return
	_origin = selected["world_xz"]
	var bathymetry_sample = selected["sample"]
	var propagation_sample = bake.propagation.sample_propagation(_origin)
	var travel: Vector2 = -propagation_sample.render_direction_xz.normalized()
	if travel.length_squared() < 0.000001:
		travel = bathymetry_sample.gradient.normalized()
	if travel.length_squared() < 0.000001:
		travel = Vector2(0.0, 1.0)
	var crest := Vector2(-travel.y, travel.x)
	var crest_length: float = clampf(float(propagation_sample.wavelength_m), TILE_SIZE_M, 12.0)
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
	# shell at the bake-authoritative location so its L0 covers the breaker.
	_ocean.global_position = Vector3(_origin.x, 0.0, _origin.y)
	_ocean.set_local_breaker_refinement_authority(_authority)
	_ocean.set_local_breaker_refinement_debug_visible(debug_tiles)
	_ocean.set_local_breaker_refinement_enabled(refinement_enabled)
	var view_xz: Vector2 = _origin - travel * 18.0
	_camera.global_position = Vector3(view_xz.x, 8.0, view_xz.y)
	_camera.look_at(Vector3(_origin.x, 1.5, _origin.y), Vector3.UP)
	_build_debug_layer()
	_build_hud()
	_refresh()
	print("2G AUTHORITY | center=(%.3f,%.3f) travel=(%.3f,%.3f) crest_length=%.3f rear=2.000 front=5.000" % [_origin.x, _origin.y, travel.x, travel.y, crest_length])


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
		refinement_enabled = not refinement_enabled
		_ocean.set_local_breaker_refinement_enabled(refinement_enabled)
		_refresh()
	elif key == KEY_F7:
		debug_tiles = not debug_tiles
		_ocean.set_local_breaker_refinement_debug_visible(debug_tiles)
		_refresh()


func _find_shallow_test_location(bathymetry: Resource, camera_xz: Vector2) -> Dictionary:
	var best_score := INF
	var best_camera_distance := INF
	var best: Dictionary = {}
	for z in bathymetry.height:
		for x in bathymetry.width:
			var world_xz: Vector2 = bathymetry.world_origin_xz + Vector2(float(x), float(z)) * bathymetry.cell_size_m
			var sample = bathymetry.sample_bathymetry(world_xz)
			if not sample.in_bounds or not sample.is_water:
				continue
			if sample.depth_m < 1.5 or sample.depth_m > 4.0:
				continue
			var score := absf(sample.depth_m - 2.5)
			var camera_distance: float = world_xz.distance_squared_to(camera_xz)
			if score < best_score or (is_equal_approx(score, best_score) and camera_distance < best_camera_distance):
				best_score = score
				best_camera_distance = camera_distance
				best = {"world_xz": world_xz, "sample": sample}
	return best


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
	_hud.text = "PRODUCTION BREAKER REFINEMENT — 2G\n%s | F6: refinement %s | F7: tile debug %s\nA OFF / B ON comparison\ncenter: (%.1f, %.1f) | crest: %.1f m | front/rear: %.1f / %.1f m\nL0 triangles: %d | Production triangles: %d\nHIGH tiles: %d | COARSE tiles: %d | active batches: %d\nGPU/CPU: use production benchmark --ocean-production=2g\nP5/Coastal/FFT path: %s | ArrayMesh rebuilds: %d" % [
		"B — REFINEMENT ON" if refinement_enabled else "A — PRODUCTION BASE",
		"ON" if refinement_enabled else "OFF",
		"ON" if debug_tiles else "OFF",
		center.x, center.y,
		float(info.get("breaker_crest_length_m", _authority.get("crest_length", 0.0))),
		float(info.get("breaker_front_extent_m", 5.0)), float(info.get("breaker_rear_extent_m", 2.0)),
		int(info.get("total_triangles", 0)), int(info.get("production_total_triangles", 0)),
		int(info.get("high_tile_count", 0)), int(info.get("coarse_tile_count", 0)), int(info.get("active_batch_count", 0)),
		"INTACT" if bool(runtime.get("breakers_runtime_active", false)) else "CHECK",
		int(info.get("arraymesh_rebuilds_runtime", 0)),
	]
	_update_debug(info)


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
	var origin: Vector2 = info.get("surface_origin_world", Vector2.ZERO)
	if tiles.is_empty():
		var extent := float(width) * TILE_SIZE_M * 0.5
		_append_rect(lines, origin, -extent, -extent, extent, extent)
		return lines
	for tile_value in tiles:
		var tile: Vector2i = tile_value
		var x0 := (float(tile.x) - float(width) * 0.5) * TILE_SIZE_M
		var z0 := (float(tile.y) - float(height) * 0.5) * TILE_SIZE_M
		_append_rect(lines, origin, x0, z0, x0 + TILE_SIZE_M, z0 + TILE_SIZE_M)
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
