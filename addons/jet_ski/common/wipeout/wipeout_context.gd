class_name WipeoutContext
extends RefCounted

var reason: StringName
var incident_impulse: Vector3


func _init(
	value_reason: StringName = &"",
	value_incident_impulse: Vector3 = Vector3.ZERO
) -> void:
	reason = value_reason
	incident_impulse = (
		value_incident_impulse
		if value_incident_impulse.is_finite()
		else Vector3.ZERO
	)
