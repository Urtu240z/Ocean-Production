extends Node3D
## Visual P4 fixture: above-water depth/refraction against submerged geometry.
## A production CoastalBakeAsset can be assigned on the Ocean node for the
## separate real-seabed/shallow pass; this scene never fabricates bathymetry.

@onready var ocean: Ocean = $P0/Ocean


func _ready() -> void:
	ocean.optics = true
	_add_box(Vector3(0.0, -3.0, -20.0), Vector3(52.0, 2.0, 52.0), Color(0.46, 0.29, 0.12))
	_add_box(Vector3(-2.5, -1.0, -4.0), Vector3(1.4, 5.0, 1.4), Color(0.93, 0.24, 0.12))
	_add_box(Vector3(2.2, -2.0, -9.0), Vector3(2.8, 2.8, 2.8), Color(0.12, 0.55, 0.82))


func _add_box(position_m: Vector3, size_m: Vector3, color: Color) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size_m
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.65
	box.material = material
	mesh.mesh = box
	mesh.position = position_m
	add_child(mesh)
