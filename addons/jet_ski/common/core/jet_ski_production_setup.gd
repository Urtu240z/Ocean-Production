extends Node
## One-time production initialization formerly performed by jet_ski_ocean.gd.
## No force calculations, water queries, clock updates or per-frame processing.
@export var input_bindings: JetSkiInputBindings = preload("res://addons/jet_ski/resources/default_input_bindings.tres")
@export var water_race_mode := true
@export var stabilized_angular_mode := true
@export var combined_rider_inertia := true
@export var diagnostics_enabled := false

func _enter_tree() -> void:
	if input_bindings != null: input_bindings.install_missing_actions()

func _ready() -> void:
	var vehicle := get_parent() as JetSkiController
	if vehicle.is_node_ready():
		_apply()
	else:
		vehicle.ready.connect(_apply, CONNECT_ONE_SHOT)

func _apply() -> void:
	var vehicle := get_parent() as JetSkiController
	vehicle.water_physics_system.diagnostics_enabled = diagnostics_enabled
	vehicle.set_ballast_mode(vehicle.ballast_mode)
	vehicle.set_draft_mode(vehicle.draft_mode)
	vehicle.set_drive_mode(vehicle.drive_mode)
	vehicle.water_physics_system.water_race_mode = water_race_mode
	vehicle.water_physics_system.stabilized_angular_mode = stabilized_angular_mode
	vehicle.set_combined_rider_inertia(combined_rider_inertia)
