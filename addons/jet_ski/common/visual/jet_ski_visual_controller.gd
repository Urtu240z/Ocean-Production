@tool
class_name JetSkiVisualController
extends Node3D

@export_group("Handle Pole")
@export var handle_pole_enabled: bool = true:
	set(value):
		handle_pole_enabled = value
		_refresh_editor_preview()

@export_range(-30.0, 30.0, 0.5) var handle_low_angle_degrees: float = -15.0:
	set(value):
		handle_low_angle_degrees = value
		_refresh_editor_preview()

@export_range(-30.0, 30.0, 0.5) var handle_rest_angle_degrees: float = 0.0:
	set(value):
		handle_rest_angle_degrees = value
		_refresh_editor_preview()

@export_range(-30.0, 30.0, 0.5) var handle_high_angle_degrees: float = 10.0:
	set(value):
		handle_high_angle_degrees = value
		_refresh_editor_preview()

@export_range(0.1, 30.0, 0.1) var handle_pole_sharpness: float = 8.0

@export_group("Water Material Tag")
@export var water_material_tag_enabled: bool = true
@export_range(0.001, 0.05, 0.001) var water_material_tag_roughness: float = 0.019608

@export_range(0.0, 1.0, 0.01) var handle_pole_preview: float = 0.5:
	set(value):
		handle_pole_preview = clampf(value, 0.0, 1.0)
		_refresh_editor_preview()

var handle_pole_normalized: float:
	get:
		return _angle_to_normalized(rad_to_deg(_base_target_angle_radians))

var handle_pole_angle_degrees: float:
	get:
		return rad_to_deg(_current_angle_radians)

var handle_pole_base_angle_degrees: float:
	get:
		return rad_to_deg(_base_target_angle_radians)

var handle_impact_offset_degrees: float:
	get:
		return rad_to_deg(_impact_offset_radians)

@onready var _handle_pivot: Node3D = %HandlePivot

var _base_target_angle_radians: float = 0.0
var _impact_offset_radians: float = 0.0
var _current_angle_radians: float = 0.0


func _ready() -> void:
	if not Engine.is_editor_hint():
		_apply_water_material_tag()
	_register_anime_toon_targets()
	if Engine.is_editor_hint():
		_base_target_angle_radians = deg_to_rad(
			_normalized_to_angle(handle_pole_preview)
		)
		_apply_angle_immediately(_get_final_target_angle_radians())
		return
	_base_target_angle_radians = deg_to_rad(handle_rest_angle_degrees)
	_apply_angle_immediately(_get_final_target_angle_radians())
	_connect_vehicle_reset()


func _register_anime_toon_targets() -> void:
	for node in find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance != null and mesh_instance.name != &"AnimeOutline":
			mesh_instance.add_to_group(&"anime_toon_target")


func _apply_water_material_tag() -> void:
	if not water_material_tag_enabled:
		return
	var hull_root := get_node_or_null("HullModel")
	if hull_root == null:
		return
	for node in hull_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		for surface_index in mesh_instance.mesh.get_surface_count():
			var source_material := mesh_instance.get_active_material(surface_index)
			if not (source_material is StandardMaterial3D):
				continue
			var tagged_material := (
				source_material as StandardMaterial3D
			).duplicate(false) as StandardMaterial3D
			if tagged_material == null:
				continue
			tagged_material.resource_local_to_scene = true
			tagged_material.roughness = water_material_tag_roughness
			tagged_material.roughness_texture = null
			mesh_instance.set_surface_override_material(
				surface_index,
				tagged_material
			)


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		_base_target_angle_radians = deg_to_rad(
			_normalized_to_angle(handle_pole_preview)
		)
		_apply_angle_immediately(_get_final_target_angle_radians())
		return
	if not handle_pole_enabled or not is_instance_valid(_handle_pivot):
		return
	var factor := 1.0 - exp(-handle_pole_sharpness * maxf(delta, 0.0))
	_current_angle_radians = lerp_angle(
		_current_angle_radians,
		_get_final_target_angle_radians(),
		factor
	)
	_apply_pivot_rotation(_current_angle_radians)


func set_handle_pole_normalized(value: float, immediate: bool = false) -> void:
	var normalized := clampf(value, 0.0, 1.0)
	handle_pole_preview = normalized
	set_handle_pole_angle_degrees(_normalized_to_angle(normalized), immediate)


func set_handle_pole_angle_degrees(
	angle_degrees: float,
	immediate: bool = false
) -> void:
	var minimum_angle := minf(handle_low_angle_degrees, handle_high_angle_degrees)
	var maximum_angle := maxf(handle_low_angle_degrees, handle_high_angle_degrees)
	_base_target_angle_radians = deg_to_rad(
		clampf(angle_degrees, minimum_angle, maximum_angle)
	)
	if immediate or Engine.is_editor_hint():
		_apply_angle_immediately(_get_final_target_angle_radians())


func set_handle_impact_offset_degrees(value: float) -> void:
	_impact_offset_radians = deg_to_rad(value)
	if Engine.is_editor_hint():
		_apply_angle_immediately(_get_final_target_angle_radians())


func snap_handle_to_rest() -> void:
	handle_pole_preview = 0.5
	_base_target_angle_radians = deg_to_rad(handle_rest_angle_degrees)
	_impact_offset_radians = 0.0
	_apply_angle_immediately(_get_final_target_angle_radians())


func _normalized_to_angle(value: float) -> float:
	value = clampf(value, 0.0, 1.0)
	if value <= 0.5:
		return lerpf(
			handle_low_angle_degrees,
			handle_rest_angle_degrees,
			value * 2.0
		)
	return lerpf(
		handle_rest_angle_degrees,
		handle_high_angle_degrees,
		(value - 0.5) * 2.0
	)


func _angle_to_normalized(angle_degrees: float) -> float:
	if angle_degrees <= handle_rest_angle_degrees:
		var lower_span := handle_rest_angle_degrees - handle_low_angle_degrees
		return (
			0.5
			if is_zero_approx(lower_span)
			else 0.5 * (angle_degrees - handle_low_angle_degrees) / lower_span
		)
	var upper_span := handle_high_angle_degrees - handle_rest_angle_degrees
	return (
		0.5
		if is_zero_approx(upper_span)
		else 0.5 + 0.5 * (angle_degrees - handle_rest_angle_degrees) / upper_span
	)


func _apply_angle_immediately(angle_radians: float) -> void:
	_current_angle_radians = angle_radians
	_apply_pivot_rotation(angle_radians)


func _get_final_target_angle_radians() -> float:
	var minimum_angle := deg_to_rad(
		minf(handle_low_angle_degrees, handle_high_angle_degrees)
	)
	var maximum_angle := deg_to_rad(
		maxf(handle_low_angle_degrees, handle_high_angle_degrees)
	)
	return clampf(
		_base_target_angle_radians + _impact_offset_radians,
		minimum_angle,
		maximum_angle
	)


func _apply_pivot_rotation(angle_radians: float) -> void:
	if not is_instance_valid(_handle_pivot):
		return
	var pivot_rotation := _handle_pivot.rotation
	pivot_rotation.x = angle_radians
	_handle_pivot.rotation = pivot_rotation


func _refresh_editor_preview() -> void:
	if Engine.is_editor_hint() and is_node_ready():
		_base_target_angle_radians = deg_to_rad(
			_normalized_to_angle(handle_pole_preview)
		)
		_apply_angle_immediately(_get_final_target_angle_radians())


func _connect_vehicle_reset() -> void:
	var ancestor := get_parent()
	while ancestor != null:
		if ancestor.has_signal("reset_completed"):
			var reset_callable := Callable(self, "_on_vehicle_reset_completed")
			if not ancestor.is_connected("reset_completed", reset_callable):
				ancestor.connect("reset_completed", reset_callable)
			return
		ancestor = ancestor.get_parent()


func _on_vehicle_reset_completed(_reason: StringName) -> void:
	snap_handle_to_rest()
