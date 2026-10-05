class_name WaterSample3D
extends RefCounted

## Coherent result of querying a water provider at a world-space point.
##
## valid means every authoritative field is coherent and usable. Consumers may
## still apply their own defensive checks for their specific force calculations.
##
## signed_depth is geometric: positive means the queried point is inside
## water, zero is on its surface, and negative is outside water. Providers
## must not assume this is a vertical distance unless their geometry is a
## heightfield.

var valid: bool = false
var surface_position: Vector3 = Vector3.ZERO
var normal: Vector3 = Vector3.UP
var velocity: Vector3 = Vector3.ZERO
var signed_depth: float = 0.0
var provider: Node


func reset() -> WaterSample3D:
	valid = false
	surface_position = Vector3.ZERO
	normal = Vector3.UP
	velocity = Vector3.ZERO
	signed_depth = 0.0
	provider = null
	return self
