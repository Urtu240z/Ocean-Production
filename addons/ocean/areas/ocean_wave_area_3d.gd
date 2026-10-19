@tool
class_name OceanWaveArea3D
extends Area3D
## Full-strength XZ footprint; feather extends outside, independent of height.
@export var ocean: Node3D:
	set(value):
		if ocean == value: return
		ocean = value
		_invalidate_hosts()
@export var enabled := true:
	set(value):
		if enabled == value: return
		enabled = value
		_invalidate_hosts()
@export_enum("Local Sea State 1", "Local Sea State 2") var sea_state := 0:
	set(value):
		if sea_state == value: return
		sea_state = value
		_invalidate_hosts()
@export var wave_priority := 0:
	set(value):
		if wave_priority == value: return
		wave_priority = value
		_invalidate_hosts()
@export_range(0.1,500.0,0.1,"suffix:m") var blend_distance_m := 15.0:
	set(value):
		if blend_distance_m == value: return
		blend_distance_m = value
		_invalidate_hosts()
@export_range(0.0,1.0,0.01) var influence := 1.0:
	set(value):
		if influence == value: return
		influence = value
		_invalidate_hosts()
@export_range(0.0,1.0,0.01) var surface_detail_strength := 1.0:
	set(value):
		if surface_detail_strength == value: return
		surface_detail_strength = value
		_invalidate_hosts()

func _enter_tree() -> void:
	add_to_group(&"ocean_wave_areas")
	set_notify_transform(true)
	_invalidate_hosts()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED: _invalidate_hosts()

func _invalidate_hosts() -> void:
	if not is_inside_tree(): return
	for host in get_tree().get_nodes_in_group(&"ocean_wave_area_hosts"):
		if host.has_method("invalidate_wave_areas"): host.invalidate_wave_areas()

func applies_to(host: Node3D) -> bool:
	if not enabled: return false
	if is_instance_valid(ocean): return ocean == host
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor.has_method("get_wave_area_runtime"): return ancestor == host
		ancestor = ancestor.get_parent()
	var hosts := get_tree().get_nodes_in_group(&"ocean_wave_area_hosts")
	return hosts.size() == 1 and hosts[0] == host

func _get_configuration_warnings() -> PackedStringArray:
	var messages := PackedStringArray()
	var supported := false
	for child in get_children():
		if child is CollisionShape3D and not child.disabled:
			supported = supported or child.shape is BoxShape3D or child.shape is SphereShape3D or child.shape is CylinderShape3D
	if not supported: messages.append("Add an enabled CollisionShape3D with a Box, Sphere or Cylinder shape.")
	if is_inside_tree() and ocean == null and get_tree().get_nodes_in_group(&"ocean_wave_area_hosts").size() > 1:
		messages.append("Assign Ocean explicitly when the level contains multiple Oceans.")
	return messages
