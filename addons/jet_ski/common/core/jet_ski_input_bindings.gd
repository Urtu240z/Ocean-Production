class_name JetSkiInputBindings
extends Resource
## Zona muerta de las acciones nuevas que instala este recurso de entradas. Las acciones existentes conservan sus ajustes.
@export_range(0.0, 1.0, 0.01) var deadzone := 0.5
## Relación entre acciones de la moto y sus eventos físicos de entrada. Solo se instalan acciones que aún no existen.
@export var bindings: Dictionary[StringName, InputEvent] = {
	&"throttle": _key(KEY_W), &"brake": _key(KEY_S),
	&"steer_left": _key(KEY_A), &"steer_right": _key(KEY_D),
	&"rider_shift_left": _key(KEY_LEFT), &"rider_shift_right": _key(KEY_RIGHT),
	&"rider_shift_forward": _key(KEY_UP), &"rider_shift_back": _key(KEY_DOWN),
	&"reset_vehicle": _key(KEY_R), &"recover_vehicle": _key(KEY_T),
	&"eject_rider": _key(KEY_E)
}

static func _key(code: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = code
	return event

func install_missing_actions() -> void:
	for action in bindings:
		if InputMap.has_action(action): continue
		InputMap.add_action(action, deadzone)
		if bindings[action] != null:
			InputMap.action_add_event(action, bindings[action])
