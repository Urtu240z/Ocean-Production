class_name OceanRefinementManager
extends RefCounted
## Converts a world-space breaker footprint into logical 4 m tile coordinates.

var _origin_world := Vector2.ZERO
var _grid_s_axis := Vector2(0.0, 1.0)
var _grid_v_axis := Vector2(1.0, 0.0)
var _grid_width := 0
var _grid_height := 0
var _tile_size_m := 4.0


func configure(origin_world: Vector2, grid_s_direction: Vector2, grid_v_direction: Vector2, grid_width: int, grid_height: int, tile_size_m: float) -> void:
	_origin_world = origin_world
	_grid_s_axis = _safe_direction(grid_s_direction, Vector2(0.0, 1.0))
	_grid_v_axis = _safe_direction(grid_v_direction, Vector2(-_grid_s_axis.y, _grid_s_axis.x))
	_grid_width = maxi(grid_width, 1)
	_grid_height = maxi(grid_height, 1)
	_tile_size_m = maxf(tile_size_m, 0.001)


func set_origin_world(origin_world: Vector2) -> void:
	_origin_world = origin_world


func select_high_tiles(region: OceanBreakerRefinementRegion) -> Array[Vector2i]:
	var selected: Array[Vector2i] = []
	for tile_y in _grid_height:
		for tile_x in _grid_width:
			var frame_s := (float(tile_x) - float(_grid_width) * 0.5 + 0.5) * _tile_size_m
			var frame_v := (float(tile_y) - float(_grid_height) * 0.5 + 0.5) * _tile_size_m
			var tile_center := _origin_world + _grid_s_axis * frame_s + _grid_v_axis * frame_v
			if region.intersects_tile(tile_center, _tile_size_m * 0.5):
				selected.append(Vector2i(tile_x, tile_y))
	return selected


func get_tile_center(tile: Vector2i) -> Vector2:
	var frame_s := (float(tile.x) - float(_grid_width) * 0.5 + 0.5) * _tile_size_m
	var frame_v := (float(tile.y) - float(_grid_height) * 0.5 + 0.5) * _tile_size_m
	return _origin_world + _grid_s_axis * frame_s + _grid_v_axis * frame_v


func get_grid_width() -> int:
	return _grid_width


func get_grid_height() -> int:
	return _grid_height


func get_tile_size_m() -> float:
	return _tile_size_m


func _safe_direction(value: Vector2, fallback: Vector2) -> Vector2:
	var direction := value.normalized()
	if direction.length_squared() < 0.000001:
		return fallback.normalized()
	return direction
