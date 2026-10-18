extends Node3D
## Autonomous visual camera for the parent vehicle. Reads existing telemetry only.
## Camera controls and any HUD are optional consumers of this rig's public API.
signal settings_changed(action: String)

const CameraHeading = preload("res://addons/jet_ski/common/visual/jet_ski_camera_heading.gd")
const CameraMotion = preload("res://addons/jet_ski/common/visual/jet_ski_camera_motion.gd")
const CameraImpact = preload("res://addons/jet_ski/common/visual/jet_ski_camera_impact.gd")

@export_group("Follow Camera")
## Activa el seguimiento de la moto con su cámara. Al desactivarlo se conserva una cámara libre para inspección.
@export var follow_camera := true
## Distancia base de la cámara por detrás de la moto, antes de aplicar el alejamiento por velocidad.
@export_range(2.0, 12.0, 0.1, "suffix:m") var camera_distance_m := 2.7
## Altura del seguimiento de cámara respecto a la posición de referencia de la moto.
@export_range(0.8, 5.0, 0.1, "suffix:m") var camera_height_m := 1.6
## Altura del punto al que mira la cámara respecto a la moto.
@export_range(0.1, 1.5, 0.05, "suffix:m") var camera_look_height_m := 0.65
## Distancia por delante de la moto donde se sitúa el objetivo de la cámara.
@export_range(0.0, 5.0, 0.1, "suffix:m") var camera_look_ahead_m := 1.5
## Ángulo de visión vertical de la cámara. Más valor muestra más escena y aumenta la sensación de velocidad.
@export_range(50.0, 90.0, 1.0, "suffix:°") var camera_fov_degrees := 70.0
## Rapidez con la que la cámara sigue los cambios de posición. Más valor reduce el retraso del seguimiento.
@export_range(1.0, 20.0, 0.5) var camera_follow_rate := 7.0
## Alejamiento adicional de cámara al alcanzar la velocidad configurada para el máximo alejamiento.
@export_range(0.0, 3.0, 0.05, "suffix:m") var camera_speed_pullback_m := 0.6
## Velocidad donde el alejamiento adicional de cámara alcanza su intensidad completa.
@export_range(1.0, 60.0, 1.0, "suffix:m/s") var camera_speed_pullback_full_speed_mps := 28.0
@export_group("Camera Motion")
## Activa el movimiento y vibración de navegación de la cámara. Los impactos se controlan por separado.
@export var camera_motion_enabled := true
## Amplitud del movimiento de posición de cámara debido a la velocidad.
@export_range(0.0, 0.3, 0.005, "suffix:m") var camera_speed_motion_m := 0.035
## Amplitud del movimiento de posición de cámara cuando la moto está sumergida.
@export_range(0.0, 0.5, 0.01, "suffix:m") var camera_submerged_motion_m := 0.12
## Amplitud angular de la vibración de cámara por velocidad.
@export_range(0.0, 3.0, 0.05, "suffix:°") var camera_speed_shake_degrees := 0.4
## Amplitud angular de la vibración de cámara durante la inmersión.
@export_range(0.0, 6.0, 0.1, "suffix:°") var camera_submerged_shake_degrees := 2.0
## Velocidad a partir de la que empieza el movimiento de cámara asociado al avance.
@export_range(0.0, 40.0, 0.5, "suffix:m/s") var camera_motion_start_speed_mps := 10.0
## Frecuencia del movimiento suave de persecución de la cámara.
@export_range(0.1, 5.0, 0.1, "suffix:Hz") var camera_chase_frequency_hz := 1.3
## Frecuencia de la vibración de cámara durante la inmersión.
@export_range(0.1, 15.0, 0.1, "suffix:Hz") var camera_submerged_frequency_hz := 6.0
## Rapidez con la que aumenta y disminuye el movimiento de cámara al cambiar de estado.
@export_range(0.5, 15.0, 0.5) var camera_motion_response_rate := 5.0
@export_group("Camera Impacts")
## Activa las sacudidas de cámara debidas a golpes y aterrizajes.
@export var camera_impact_enabled := true
## Desplazamiento máximo de la cámara al responder a un impacto.
@export_range(0.0, 0.6, 0.01, "suffix:m") var camera_impact_distance_m := 0.20
## Rotación máxima de la cámara al responder a un impacto.
@export_range(0.0, 8.0, 0.1, "suffix:°") var camera_impact_shake_degrees := 2.5
## Aceleración mínima necesaria para disparar una respuesta de impacto de cámara.
@export_range(5.0, 70.0, 1.0, "suffix:m/s²") var camera_impact_threshold_mps2 := 22.0
## Tiempo de recuperación de la sacudida de cámara tras un impacto.
@export_range(0.15, 1.5, 0.05, "suffix:s") var camera_impact_recovery_seconds := 0.45

const CAMERA_PRESETS := [
	{"name": "CLOSE", "distance": 2.7, "height": 1.6, "look_height": 0.65, "look_ahead": 1.5, "fov": 70.0},
	{"name": "MEDIUM", "distance": 6.5, "height": 2.8, "look_height": 0.65, "look_ahead": 2.0, "fov": 72.0},
	{"name": "FAR", "distance": 9.0, "height": 3.4, "look_height": 0.7, "look_ahead": 2.5, "fov": 75.0},
]

var ski: JetSkiController
@onready var camera: Camera3D = $Camera3D
var camera_preset_index := 0
var _camera_heading := CameraHeading.new()
var _camera_previous_target := Vector3.ZERO
var _camera_follow_initialized := false
var _camera_motion := CameraMotion.new()
var _camera_motion_offset := Vector3.ZERO
var _camera_impact := CameraImpact.new()


func _ready() -> void:
	# A world-space camera must not inherit the hull's pitch/roll or teleport twice.
	top_level = true
	# The former integrator ran while paused and before the vehicle callbacks.
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = -1
	process_physics_priority = -1
	ski = get_parent() as JetSkiController
	if ski == null:
		push_error("Jet ski CameraRig requires a JetSkiController parent.")
		set_process(false)
		set_physics_process(false)
		return
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.fov = camera_fov_degrees
	ski.hard_landing.connect(_on_camera_hard_landing)
	ski.reset_completed.connect(_reset_camera_impact)
	if ski.is_node_ready():
		_on_vehicle_ready()
	else:
		ski.ready.connect(_on_vehicle_ready, CONNECT_ONE_SHOT)


func _on_vehicle_ready() -> void:
	_camera_heading.reset(ski.global_transform.basis)


func _process(delta: float) -> void:
	update_camera(delta)


func update_camera(delta: float) -> void:
	if ski == null: return
	var interpolated_transform := ski.get_global_transform_interpolated()
	var target := interpolated_transform.origin
	var backward := _camera_heading.update(interpolated_transform.basis, delta, camera_follow_rate)
	var horizontal_speed := ski.linear_velocity.slide(Vector3.UP).length()
	var speed_blend := smoothstep(0.0, maxf(camera_speed_pullback_full_speed_mps, 0.01), horizontal_speed)
	var follow_distance := camera_distance_m + camera_speed_pullback_m * speed_blend
	var desired := target + Vector3.UP * camera_height_m + backward * follow_distance
	# Remove the preceding visual offset before smoothing; never accumulate noise.
	camera.global_position -= _camera_motion_offset
	_camera_motion_offset = Vector3.ZERO
	if follow_camera:
		if _camera_follow_initialized:
			camera.global_position += target - _camera_previous_target
			camera.global_position = camera.global_position.lerp(desired, 1.0-exp(-delta*camera_follow_rate))
		else:
			camera.global_position = desired
		_camera_previous_target = target
		_camera_follow_initialized = true
		camera.fov = camera_fov_degrees
		var forward := -backward
		camera.look_at(target + forward * camera_look_ahead_m + Vector3.UP * camera_look_height_m)
		var motion := _update_camera_motion(delta, horizontal_speed)
		_camera_impact.update(delta, camera.global_basis)
		_camera_motion_offset = camera.global_basis.x * motion.x + camera.global_basis.y * motion.y \
			+ _camera_impact.position_offset_world
		camera.global_position += _camera_motion_offset
		var shake: Vector3 = _camera_motion.rotation_offset_radians + _camera_impact.rotation_offset_radians
		camera.rotate_object_local(Vector3.RIGHT, shake.x)
		camera.rotate_object_local(Vector3.UP, shake.y)
		camera.rotate_object_local(Vector3.BACK, shake.z)
	else:
		_camera_follow_initialized = false
		_camera_motion.reset()
		_camera_impact.reset()


func _physics_process(delta: float) -> void:
	_camera_impact.enabled = camera_motion_enabled and camera_impact_enabled and follow_camera
	_camera_impact.position_amplitude_m = camera_impact_distance_m
	_camera_impact.rotation_amplitude_degrees = camera_impact_shake_degrees
	_camera_impact.acceleration_threshold_mps2 = camera_impact_threshold_mps2
	_camera_impact.recovery_seconds = camera_impact_recovery_seconds
	if not is_instance_valid(ski) or not ski.is_node_ready() or ski.freeze or get_tree().paused:
		_camera_impact.reset()
		return
	var nav := ski.navigation_system.state
	var gravity_direction: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	var gravity := gravity_direction * float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * ski.gravity_scale
	_camera_impact.sample_physics(delta, ski.linear_velocity, gravity,
		nav.physical_contact_count > 0 or ski.water_physics_system.state.raw_contact_mask != 0,
		nav.physical_contact_impulse, ski.mass)


func _on_camera_hard_landing(intensity: float, _position: Vector3) -> void:
	if not is_instance_valid(ski) or not ski.is_node_ready() or not follow_camera or not camera_motion_enabled or not camera_impact_enabled: return
	if ski.navigation_system.state.physical_contact_count > 0: return
	_camera_impact.kick(-ski.water_physics_system.state.support_normal,
		lerpf(0.25, 1.0, clampf(intensity, 0.0, 1.0)), &"water_landing")


func _reset_camera_impact(_reason: StringName) -> void:
	_camera_impact.reset()


func _update_camera_motion(delta: float, horizontal_speed: float) -> Vector2:
	_camera_motion.enabled = camera_motion_enabled
	_camera_motion.speed_start_mps = camera_motion_start_speed_mps
	_camera_motion.speed_full_mps = camera_speed_pullback_full_speed_mps
	_camera_motion.speed_amplitude_m = camera_speed_motion_m
	_camera_motion.submerged_amplitude_m = camera_submerged_motion_m
	_camera_motion.speed_rotation_degrees = camera_speed_shake_degrees
	_camera_motion.submerged_rotation_degrees = camera_submerged_shake_degrees
	_camera_motion.chase_frequency_hz = camera_chase_frequency_hz
	_camera_motion.submerged_frequency_hz = camera_submerged_frequency_hz
	_camera_motion.response_rate = camera_motion_response_rate
	var water_physics := ski.water_physics_system
	var water_state := water_physics.state
	var drag_acceleration := (water_state.total_forward_drag_force + water_state.total_lateral_drag_force) \
		/ maxf(ski.mass, 1.0)
	return _camera_motion.update(delta, horizontal_speed, water_physics.hull_root_depth_m,
		drag_acceleration, water_state.raw_contact_mask != 0)


func get_preset_name() -> String:
	for preset in CAMERA_PRESETS:
		if is_equal_approx(camera_distance_m, preset.distance) and is_equal_approx(camera_height_m, preset.height) \
			and is_equal_approx(camera_look_height_m, preset.look_height) and is_equal_approx(camera_look_ahead_m, preset.look_ahead) \
			and is_equal_approx(camera_fov_degrees, preset.fov):
			return preset.name
	return "CUSTOM"


func adjust_distance(amount: float) -> void:
	camera_distance_m = clampf(camera_distance_m + amount, 2.0, 12.0)
	settings_changed.emit("DISTANCE")


func adjust_height(amount: float) -> void:
	camera_height_m = clampf(camera_height_m + amount, 0.8, 5.0)
	settings_changed.emit("HEIGHT")


func cycle_preset() -> void:
	var current_name := get_preset_name()
	var next_index := 0
	for i in CAMERA_PRESETS.size():
		if CAMERA_PRESETS[i].name == current_name:
			next_index = (i + 1) % CAMERA_PRESETS.size()
			break
	var preset: Dictionary = CAMERA_PRESETS[next_index]
	camera_preset_index = next_index
	camera_distance_m = preset.distance
	camera_height_m = preset.height
	camera_look_height_m = preset.look_height
	camera_look_ahead_m = preset.look_ahead
	camera_fov_degrees = preset.fov
	settings_changed.emit("PRESET")
