extends CanvasLayer
## Independent gameplay overlay: no ocean/debug-profile changes on mode switch.

var _mode_label: Label
var _vehicle: RigidBody3D


func _ready() -> void:
	_vehicle = get_parent() as RigidBody3D
	layer = 10
	var margin := MarginContainer.new()
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	margin.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	margin.offset_right = -20.0
	margin.offset_top = 20.0
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mode_label = Label.new()
	margin.add_child(_mode_label)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mode_label.add_theme_color_override("font_color", Color.WHITE)
	_mode_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_mode_label.add_theme_constant_override("outline_size", 3)
	_update_label()


func _process(_delta: float) -> void:
	_update_label()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.is_pressed() or event.is_echo():
		return
	if event.keycode == KEY_H:
		var physics: JetSkiWaterPhysicsSystem = _vehicle.get("water_physics_system")
		var next_mode := 1 - physics.buoyancy_mode
		physics.set_buoyancy_mode(next_mode)
		_vehicle.set("buoyancy_mode", physics.buoyancy_mode)
	elif event.keycode == KEY_J:
		_vehicle.call("set_hull_response_mode", 1 - int(_vehicle.get("hull_response_mode")))
	else:
		return
	_update_label()
	get_viewport().set_input_as_handled()


func _update_label() -> void:
	if _mode_label == null or not is_instance_valid(_vehicle):
		return
	var physics: JetSkiWaterPhysicsSystem = _vehicle.get("water_physics_system")
	var distributed := physics.buoyancy_mode == JetSkiWaterPhysicsSystem.BuoyancyMode.HULL_BUOYANCY_V1
	_mode_label.text = "[H] %s\n%d hull samples | %.0f kg" % [
		physics.get_buoyancy_mode_name(), 12 if distributed else 4, _vehicle.mass]
	if distributed:
		_mode_label.text += "\nDisplacement %.3f m³ | wet %d/12" % [
			physics.hull_buoyancy.submerged_volume_m3, physics.hull_buoyancy.wet_sample_count]
		_mode_label.text += "\n[J] %s | added water inertia %.0f kg" % [
			_vehicle.call("get_hull_response_mode_name"), physics.heavy_heave_added_mass_kg]
		if bool(_vehicle.call("is_heavy_hull_active")):
			_mode_label.text += "\nPitch / roll inertia ×%.1f / ×%.1f" % [
				float(_vehicle.get("heavy_pitch_inertia_multiplier")), float(_vehicle.get("heavy_roll_inertia_multiplier"))]
			_mode_label.text += "\nUPRIGHT: %s | wave tilt %.0f%%" % [
				"ON" if physics.heavy_upright_enabled else "OFF", physics.heavy_wave_tilt_influence * 100.0]
	var provider: Node = _vehicle.call("get_water_provider")
	if is_instance_valid(provider) and provider.has_method("get_water_sync_status"):
		var sync: Dictionary = provider.call("get_water_sync_status")
		_mode_label.text += "\nWATER SYNC: %s | ocean r%d / spectrum v%d" % [
			sync.status, sync.ocean_revision, sync.spectrum_version]
	else:
		_mode_label.text += "\nWATER SYNC: UPDATING"
