class_name OceanBreakerRefinementRegion
extends RefCounted
## Geometric footprint only; P5 remains responsible for the deformation shape.

var active := false
var center_world := Vector2.ZERO
var travel_direction_world := Vector2(0.0, 1.0)
var crest_direction_world := Vector2(1.0, 0.0)
var crest_length := 0.0
var rear_extent := 0.0
var front_extent := 0.0
var strength := 0.0


func update_from_authority(authority: Dictionary) -> void:
	active = bool(authority.get("active", false))
	center_world = authority.get("center_world", Vector2.ZERO)
	travel_direction_world = _safe_direction(authority.get("travel_direction_world", Vector2(0.0, 1.0)), Vector2(0.0, 1.0))
	crest_direction_world = _safe_direction(authority.get("crest_direction_world", Vector2(-travel_direction_world.y, travel_direction_world.x)), Vector2(-travel_direction_world.y, travel_direction_world.x))
	crest_length = maxf(float(authority.get("crest_length", 0.0)), 0.0)
	rear_extent = maxf(float(authority.get("rear_extent", 0.0)), 0.0)
	front_extent = maxf(float(authority.get("front_extent", 0.0)), 0.0)
	strength = clampf(float(authority.get("strength", 0.0)), 0.0, 1.0)


func intersects_tile(tile_center_world: Vector2, tile_half_extent_m: float) -> bool:
	if not active or crest_length <= 0.0 or front_extent + rear_extent <= 0.0:
		return false
	var offset := tile_center_world - center_world
	var travel_axis := travel_direction_world
	var crest_axis := crest_direction_world
	var tile_half := maxf(tile_half_extent_m, 0.0)
	# Conservative OBB-vs-square test. The extra tile radius intentionally
	# favors refinement over leaving a crest/lip seam at coarse resolution.
	var crest_projection := absf(offset.dot(crest_axis))
	var tile_radius := tile_half * (absf(travel_axis.x) + absf(travel_axis.y))
	var crest_radius := tile_half * (absf(crest_axis.x) + absf(crest_axis.y))
	var travel_min := -rear_extent - tile_radius
	var travel_max := front_extent + tile_radius
	var crest_half := crest_length * 0.5 + crest_radius
	var signed_travel := offset.dot(travel_axis)
	return signed_travel >= travel_min and signed_travel <= travel_max and crest_projection <= crest_half


func _safe_direction(value: Variant, fallback: Vector2) -> Vector2:
	var direction: Vector2 = value if value is Vector2 else fallback
	if direction.length_squared() < 0.000001:
		return fallback.normalized()
	return direction.normalized()
