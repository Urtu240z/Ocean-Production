extends Camera3D
## Cámara de inspección reutilizable para escenas temporales de validación.
## No usa InputMap ni depende del addon Ocean.

@export var look_sensitivity := 0.0025
@export var normal_speed := 12.0
@export var fast_multiplier := 4.0
@export var slow_multiplier := 0.25

func _ready() -> void:
	current = true
	_capture_mouse()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			_release_mouse()
		else:
			_capture_mouse()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		_capture_mouse()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * look_sensitivity)
		rotation.x = clampf(rotation.x - event.relative.y * look_sensitivity, -PI * 0.49, PI * 0.49)


func _process(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): input.z -= 1.0
	if Input.is_key_pressed(KEY_S): input.z += 1.0
	if Input.is_key_pressed(KEY_A): input.x -= 1.0
	if Input.is_key_pressed(KEY_D): input.x += 1.0
	if Input.is_key_pressed(KEY_Q): input.y -= 1.0
	if Input.is_key_pressed(KEY_E): input.y += 1.0
	if input == Vector3.ZERO:
		return

	var speed := normal_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= fast_multiplier
	elif Input.is_key_pressed(KEY_SPACE):
		speed *= slow_multiplier
	translate_object_local(input.normalized() * speed * delta)


func _capture_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _release_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
