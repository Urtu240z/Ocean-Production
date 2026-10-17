extends Control
## Manual prototype controls. Event-driven; no per-frame polling or readback.
var style: Resource
var panel: PanelContainer
var status: Label
var widgets: Dictionary = {}

func configure(settings: Resource) -> void:
	style = settings
	var controls_theme := Theme.new()
	controls_theme.default_font_size = 24
	theme = controls_theme
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var toggle := Button.new()
	toggle.text = "Foam Settings [F7]"
	toggle.position = Vector2(20,265)
	add_child(toggle)
	panel = PanelContainer.new()
	panel.position = Vector2(20,20)
	panel.size = Vector2(660,900)
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.025,0.04,0.05,0.98)
	background.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel",background)
	add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var title := Label.new()
	title.text = "HULL FOAM · Live Settings"
	column.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(630,740)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var rows := VBoxContainer.new()
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(rows)
	_add_color(rows,"water_tint","Water Tint")
	_add_color(rows,"white_color","White Color")
	var opening := SpinBox.new()
	opening.min_value = 0.0
	opening.max_value = 24.4
	opening.step = 0.1
	opening.value = style.get_wake_opening_degrees()
	opening.custom_minimum_size.x = 180
	opening.value_changed.connect(func(degrees: float): style.set_wake_opening_degrees(degrees))
	_row(rows,"Wake Opening (°)").add_child(opening)
	widgets["wake_opening_degrees"] = opening
	for entry in [
		["initial_width_m","Initial Width M",0.2,4.0,0.01],
		["lifetime_s","Lifetime S",1.0,60.0,0.5],
		["calm_foam_strength","Calm Foam Strength",0.0,2.0,0.01],
		["outward_speed","Outward Speed",0.0,2.0,0.05],
		["impact_outward_boost","Impact Outward Boost",0.0,4.0,0.05],
		["edge_irregularity","Edge Irregularity",0.0,0.6,0.01],
		["edge_fade","Edge Fade",0.2,0.8,0.01],
		["filament_deformation","Filament Deformation",0.0,0.8,0.01],
		["filament_speed","Filament Speed",0.0,3.0,0.05],
		["motion_strength","Motion Strength",0.0,1.0,0.01],
		["motion_speed","Motion Speed",0.0,2.0,0.05],
		["opacity","Opacity",0.0,2.0,0.01],
		["tint_strength","Tint Strength",0.0,1.0,0.01],
		["roughness","Roughness",0.0,1.0,0.01],
		["specular","Specular",0.0,1.0,0.01],
		["normal_strength","Normal Strength",0.0,0.04,0.001],
		["whitening_threshold","Whitening Threshold",0.0,0.95,0.01],
		["whitening_transition","Whitening Transition",0.02,0.8,0.01],
		["white_strength","White Strength",0.0,1.5,0.01],
		["impact_sensitivity","Impact Sensitivity",0.0,3.0,0.05],
		["agitation_decay","Agitation Decay",0.05,2.0,0.01],
		["patch_size","Patch Size",0.3,4.0,0.05],
		["variation","Variation",0.0,1.0,0.01],
		["emission","Emission",0.0,2.0,0.05]]:
		_add_number(rows,entry)
	var running_title := Label.new()
	running_title.text = "RUNNING FOAM · Independent Appearance"
	rows.add_child(running_title)
	var enabled := CheckButton.new()
	enabled.button_pressed = style.running_enabled
	enabled.toggled.connect(func(value: bool): style.running_enabled = value)
	_row(rows,"Enabled").add_child(enabled)
	widgets["running_enabled"] = enabled
	_add_color(rows,"running_color","Color")
	for entry in [
		["running_start_kmh","Running Start (km/h)",0.0,30.0,0.5],
		["running_full_kmh","Running Full (km/h)",1.0,100.0,1.0],
		["running_speed_curve","Running Speed Curve",0.25,3.0,0.05],
		["running_response_seconds","Running Response Seconds",0.05,2.0,0.05],
		["running_strength","Running Strength",0.0,3.0,0.05],
		["running_whiteness","Running Whiteness",0.0,1.0,0.01],
		["running_roughness","Running Roughness",0.0,1.0,0.01],
		["running_specular","Running Specular",0.0,1.0,0.01],
		["running_normal_strength","Running Normal Strength",0.0,0.04,0.001],
		["running_half_width","Running Half Width",0.5,2.5,0.05],
		["running_half_length","Running Half Length",1.0,3.5,0.05],
		["running_edge_fade","Running Edge Fade",0.15,1.0,0.05]]:
		_add_number(rows,entry)
	var buttons := HBoxContainer.new()
	column.add_child(buttons)
	var save := Button.new()
	save.text = "Save Settings"
	save.pressed.connect(_save)
	buttons.add_child(save)
	var close := Button.new()
	close.text = "Close"
	close.pressed.connect(func(): panel.hide())
	buttons.add_child(close)
	status = Label.new()
	status.text = "Live changes. Save Settings keeps these values."
	column.add_child(status)
	panel.hide()
	toggle.pressed.connect(func(): panel.visible = not panel.visible)

func _row(parent: Control, text: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 380
	row.add_child(label)
	return row

func _add_color(parent: Control, key: String, title: String) -> void:
	var picker := ColorPickerButton.new()
	picker.custom_minimum_size = Vector2(180,40)
	picker.color = style.get(key)
	picker.edit_alpha = false
	picker.color_changed.connect(func(value: Color): style.set(key,value))
	_row(parent,title).add_child(picker)
	widgets[key] = picker

func _add_number(parent: Control, entry: Array) -> void:
	var key: String = entry[0]
	var value := SpinBox.new()
	value.min_value = entry[2]
	value.max_value = entry[3]
	value.step = entry[4]
	value.value = style.get(key)
	value.custom_minimum_size.x = 180
	value.value_changed.connect(func(number: float): style.set(key,number))
	_row(parent,entry[1]).add_child(value)
	widgets[key] = value

func _save() -> void:
	var path := style.resource_path
	if path.is_empty() or path.contains("::"):
		status.text = "This style needs its own resource file."
		return
	var error := ResourceSaver.save(style,path)
	status.text = "Settings saved." if error == OK else "Could not save: %s" % error_string(error)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		panel.visible = not panel.visible
		get_viewport().set_input_as_handled()
