extends Node3D
## Minimal host: only generic input bindings. No Ocean or development integrator.
func _enter_tree() -> void:
	var bindings := {"throttle": KEY_W, "brake": KEY_S, "steer_left": KEY_A,
		"steer_right": KEY_D, "rider_shift_forward": KEY_UP, "rider_shift_back": KEY_DOWN,
		"rider_shift_left": KEY_LEFT, "rider_shift_right": KEY_RIGHT,
		"reset_vehicle": KEY_R, "recover_vehicle": KEY_SPACE, "eject_rider": KEY_E}
	for action in bindings:
		if InputMap.has_action(action): continue
		InputMap.add_action(action)
		var key := InputEventKey.new()
		key.physical_keycode = bindings[action]
		InputMap.action_add_event(action, key)
