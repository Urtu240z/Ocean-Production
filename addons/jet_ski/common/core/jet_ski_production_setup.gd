extends Node
## Mapa de acciones que se instalan si todavía no existen en el proyecto. No sustituye entradas ya configuradas por el juego.
@export var input_bindings: JetSkiInputBindings = preload("res://addons/jet_ski/resources/default_input_bindings.tres")
## Selecciona el contrato de fuerzas de Water Race al iniciar la moto. Los valores de los modos de comparación se conservan.
@export var water_race_mode := true
## Activa al iniciar las ayudas angulares de estabilización del agua para los modos que las utilizan.
@export var stabilized_angular_mode := true
## Incluye la masa de referencia del piloto al calcular la inercia del cuerpo. No añade su peso otra vez.
@export var combined_rider_inertia := true
## Activa registros de diagnóstico de fuerzas y contactos. Úsalo para investigar; añade trabajo durante la ejecución.
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
