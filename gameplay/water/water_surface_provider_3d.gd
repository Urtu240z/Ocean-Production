class_name WaterSurfaceProvider3D
extends Node3D

## Minimal authoritative water-query contract.
##
## A provider returns one coherent surface position, normal, velocity, and
## geometric signed depth for an arbitrary world-space point. This supports
## both heightfield and non-heightfield water volumes.

func sample_water(
	_world_position: Vector3,
	out_sample: WaterSample3D = null
) -> WaterSample3D:
	push_error("WaterSurfaceProvider3D subclasses must implement sample_water().")
	return out_sample.reset() if out_sample != null else WaterSample3D.new()

func sample_propulsion_water(world_position: Vector3, out_sample: WaterSample3D = null) -> WaterSample3D:
	return sample_water(world_position, out_sample)

func sample_height(world_position: Vector3) -> float:
	var sample := sample_water(world_position)
	return sample.surface_position.y if sample.valid else NAN
