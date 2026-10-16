class_name WaterSurfaceProvider3D
extends Node3D

## Minimal authoritative water-query contract.
##
## A provider returns one coherent surface position, normal, velocity, and
## geometric signed depth for an arbitrary world-space point. This supports
## both heightfield and non-heightfield water volumes.

## Prepare this consumer's contacts immediately before its force evaluation.
## Legacy providers retain their existing prefetch path. Queries below only read
## published fields; no FFT construction or clock advancement per query.
func prepare_water_queries(body_transform: Transform3D, local_points: PackedVector3Array,
		additional_local_points: PackedVector3Array, physics_delta_s: float) -> void:
	if has_method("begin_gameplay_contacts"):
		call("begin_gameplay_contacts", body_transform, local_points,
			additional_local_points, physics_delta_s)
	elif has_method("begin_contacts"):
		call("begin_contacts", body_transform, local_points)

## Backend-independent batch contract: one result per input, in input order.
## Invalid points remain invalid entries. Concrete providers may batch natively.
## Backend selection and diagnostic options stay outside this common interface.
func sample_surface_batch(positions: PackedVector3Array) -> Array[WaterSample3D]:
	var samples: Array[WaterSample3D] = []
	for position in positions:
		samples.append(sample_water(position))
	return samples

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
