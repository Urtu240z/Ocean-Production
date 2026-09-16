class_name OceanSpaceContract
extends RefCounted
## Runtime contract shared by every ocean-space producer and consumer.
##
## `ocean_scale` is the authored vertical/displacement scale.  The clipmap
## scale is the authored horizontal Ocean Space scale.  Neither value mutates
## a profile or the Ocean node transform; consumers derive effective runtime
## values from this object.

const MIN_SCALE := 0.0001

var ocean_scale := 1.0
var clipmap_geometry_scale := 1.0
var revision := 0


func configure(next_ocean_scale: float, next_clipmap_geometry_scale: float) -> void:
	var safe_ocean := maxf(next_ocean_scale, MIN_SCALE)
	var safe_clipmap := maxf(next_clipmap_geometry_scale, MIN_SCALE)
	if is_equal_approx(ocean_scale, safe_ocean) and is_equal_approx(clipmap_geometry_scale, safe_clipmap):
		return
	ocean_scale = safe_ocean
	clipmap_geometry_scale = safe_clipmap
	revision += 1


func ocean_height(value_m: float) -> float:
	return value_m * ocean_scale


func ocean_length(value_m: float) -> float:
	return value_m * clipmap_geometry_scale


func ocean_domains(domains: Vector3) -> Vector3:
	return domains * clipmap_geometry_scale


func as_dictionary() -> Dictionary:
	return {
		"ocean_scale": ocean_scale,
		"clipmap_geometry_scale": clipmap_geometry_scale,
		"revision": revision,
		"space": "WORLD_OCEAN_CONTRACT",
	}
