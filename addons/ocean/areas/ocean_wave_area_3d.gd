@tool
class_name OceanWaveArea3D
extends Area3D
## CollisionShape3D defines the full-strength XZ footprint; blending extends outside.

@export var ocean: Node3D
@export var enabled := true
@export var wave_priority := 0
@export_range(0.1, 500.0, 0.1, "suffix:m") var blend_distance_m := 15.0
@export_group("Local waves")
## Significant height of the randomized wind-wave band. Swell/ripples have independent heights below.
@export_range(0.0, 10.0, 0.01, "suffix:m") var wave_height_m := 0.25
@export_range(0.5, 200.0, 0.1, "suffix:m") var wavelength_m := 8.0
@export_range(0.0, 4.0, 0.01) var wave_speed := 1.0
@export_range(-180.0, 180.0, 0.1, "suffix:deg") var wind_direction_degrees := 0.0
@export_range(0.0, 60.0, 0.1, "suffix:m/s") var wind_speed_mps := 4.0
@export_range(0.0, 2.0, 0.01) var choppiness := 0.5
@export_range(0.0, 1.0, 0.01) var directional_spread := 0.3
@export var phase_seed := 1
@export_group("Spectrum variety")
@export_range(4, 24, 1) var wave_components := 12
@export_range(0.0, 1.0, 0.01) var wavelength_variation := 0.65
@export_range(0.0, 1.0, 0.01) var height_variation := 0.6
@export_range(0.0, 1.0, 0.01) var wind_height_influence := 0.0
@export_range(0.0, 1.0, 0.01) var cross_sea_amount := 0.0
@export_range(-180.0, 180.0, 0.1, "suffix:deg") var cross_sea_angle_degrees := 75.0
@export_group("Wave groups")
@export_range(0.0, 1.0, 0.01) var wave_group_strength := 0.3
@export_range(1.0, 1000.0, 0.5, "suffix:m") var wave_group_size_m := 80.0
@export_range(0.0, 4.0, 0.01) var wave_group_speed := 1.0
@export_group("Independent swell")
@export_range(0.0, 10.0, 0.01, "suffix:m") var swell_height_m := 0.0
@export_range(1.0, 500.0, 0.5, "suffix:m") var swell_wavelength_m := 35.0
@export_range(-180.0, 180.0, 0.1, "suffix:deg") var swell_direction_degrees := 0.0
@export_range(0.0, 4.0, 0.01) var swell_speed := 1.0
@export_group("Surface ripples")
@export_range(0.0, 1.0, 0.005, "suffix:m") var ripple_height_m := 0.0
@export_range(0.25, 10.0, 0.05, "suffix:m") var ripple_wavelength_m := 1.5
@export_range(0.0, 4.0, 0.01) var ripple_speed := 1.2
@export_group("Mix and foam")
@export_range(0.0, 1.0, 0.01) var influence := 1.0
@export_range(0.0, 2.0, 0.01) var local_foam_strength := 1.0
## Remaining global micro-normal detail; 0 gives only the local wave normals.
@export_range(0.0, 1.0, 0.01) var surface_detail_strength := 0.35
@export_group("Starting presets")
@export_tool_button("Sheltered harbor", "Anchor") var harbor_preset = func(): apply_preset("harbor")
@export_tool_button("Channel", "Curve3D") var channel_preset = func(): apply_preset("channel")
@export_tool_button("Island passage", "WorldEnvironment") var passage_preset = func(): apply_preset("passage")

func apply_preset(kind: String) -> void:
	var values: Dictionary
	match kind:
		"harbor": values = {"wave_height_m":0.18,"wavelength_m":5.0,"wave_speed":0.7,"wind_speed_mps":2.0,"choppiness":0.2,"directional_spread":0.8,"swell_height_m":0.06,"swell_wavelength_m":25.0,"ripple_height_m":0.025,"ripple_wavelength_m":0.9,"wave_group_strength":0.25,"cross_sea_amount":0.0}
		"channel": values = {"wave_height_m":0.4,"wavelength_m":10.0,"wave_speed":0.9,"wind_speed_mps":5.0,"choppiness":0.45,"directional_spread":0.2,"swell_height_m":0.12,"swell_wavelength_m":30.0,"ripple_height_m":0.035,"ripple_wavelength_m":1.2,"wave_group_strength":0.4,"cross_sea_amount":0.0}
		_: values = {"wave_height_m":0.8,"wavelength_m":16.0,"wave_speed":1.0,"wind_speed_mps":8.0,"choppiness":0.8,"directional_spread":0.5,"swell_height_m":0.35,"swell_wavelength_m":45.0,"ripple_height_m":0.05,"ripple_wavelength_m":1.5,"wave_group_strength":0.5,"cross_sea_amount":0.6}
	values.merge({"wave_components":16,"wavelength_variation":0.7,"height_variation":0.7,"wind_height_influence":0.0,"influence":1.0,"swell_speed":1.0,"ripple_speed":1.2},true)
	for key in values: set(key,values[key])
	notify_property_list_changed()
	if Engine.is_editor_hint(): EditorInterface.mark_scene_as_unsaved()

func _enter_tree() -> void:
	add_to_group(&"ocean_wave_areas")

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
	if not supported:
		messages.append("Add an enabled CollisionShape3D with a Box, Sphere or Cylinder shape.")
	if is_inside_tree() and ocean == null and get_tree().get_nodes_in_group(&"ocean_wave_area_hosts").size() > 1:
		messages.append("Assign Ocean explicitly when the level contains multiple Oceans.")
	return messages
