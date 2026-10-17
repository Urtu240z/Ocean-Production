extends Node
## Optional input adapter. Disabling/removing this node leaves follow/effects intact.
@export var controls_enabled := true


func _active_rig() -> Node3D:
	if not controls_enabled: return null
	var rig := get_parent() as Node3D
	var camera := rig.get_node_or_null("Camera3D") as Camera3D
	return rig if camera != null and camera.is_current() else null


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_pressed() or event.is_echo(): return
	var rig := _active_rig()
	if rig == null: return
	if event.keycode in [KEY_KP_ADD, KEY_EQUAL]: rig.call("adjust_distance", -0.25)
	if event.keycode in [KEY_KP_SUBTRACT, KEY_MINUS]: rig.call("adjust_distance", 0.25)
	if event.keycode == KEY_PAGEUP: rig.call("adjust_height", 0.15)
	if event.keycode == KEY_PAGEDOWN: rig.call("adjust_height", -0.15)
	if event.keycode == KEY_C: rig.call("cycle_preset")


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var rig := _active_rig()
		if rig == null: return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP: rig.call("adjust_distance", -0.25)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN: rig.call("adjust_distance", 0.25)
