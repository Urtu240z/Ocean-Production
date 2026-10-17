extends Control
## Manual review controls; all changes are event-driven.
var style: Resource
var panel: PanelContainer
var status: Label
var variant: OptionButton

func configure(settings: Resource) -> void:
	style=settings
	mouse_filter=Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var font_theme := Theme.new()
	font_theme.default_font_size=22
	theme=font_theme
	var toggle := Button.new()
	toggle.name="AbrirSalpicaduras"
	toggle.text="Splash and Tail Jet"
	toggle.position=Vector2(20,315)
	add_child(toggle)
	panel=PanelContainer.new()
	panel.position=Vector2(20,20)
	var background := StyleBoxFlat.new()
	background.bg_color=Color(0.025,0.04,0.05,0.98)
	background.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel",background)
	add_child(panel)
	var column := VBoxContainer.new()
	panel.add_child(column)
	var title := Label.new()
	title.text="SPLASH AND TAIL JET"
	column.add_child(title)
	variant=OptionButton.new()
	variant.add_item("Tail Jet: Splash 3 · Dense Jet",0)
	variant.add_item("Tail Jet: Splash 4 · Fine Droplets",1)
	variant.select(style.tail_variant)
	variant.item_selected.connect(func(value: int): style.tail_variant=value)
	column.add_child(variant)
	for entry in [["sides_enabled","Sides Enabled"],["tail_enabled","Tail Enabled"]]:
		var check := CheckBox.new()
		check.text=entry[1]
		check.button_pressed=style.get(entry[0])
		var key: String=entry[0]
		check.toggled.connect(func(value: bool): style.set(key,value))
		column.add_child(check)
	for entry in [["side_opacity","Side Opacity",0.0,1.0,0.01],
		["impact_threshold","Impact Threshold",0.2,6.0,0.05],
		["side_delay","Side Delay",0.02,0.3,0.01],
		["cooldown","Cooldown",0.15,1.5,0.01],
		["tail_opacity","Tail Opacity",0.0,1.0,0.01],
		["tail_length","Tail Length",0.5,6.0,0.05],
		["tail_width","Tail Width",0.2,3.0,0.05],
		["tail_height","Tail Height",0.05,2.0,0.05]]:
		var row := HBoxContainer.new()
		column.add_child(row)
		var label := Label.new()
		label.text=entry[1]
		label.custom_minimum_size.x=360
		row.add_child(label)
		var number := SpinBox.new()
		number.min_value=entry[2]
		number.max_value=entry[3]
		number.step=entry[4]
		number.value=style.get(entry[0])
		number.custom_minimum_size.x=180
		var key: String=entry[0]
		number.value_changed.connect(func(value: float): style.set(key,value))
		row.add_child(number)
	var save := Button.new()
	save.text="Save Settings"
	save.pressed.connect(func():
		if style.resource_path.is_empty() or style.resource_path.contains("::"):
			status.text="This style needs its own resource file."
			return
		var error := OK
		for profile in [style.splash_appearance,style.tail_appearance]:
			if not profile.resource_path.is_empty() and not profile.resource_path.contains("::"):
				error=ResourceSaver.save(profile,profile.resource_path)
				if error!=OK: break
		if error==OK: error=ResourceSaver.save(style,style.resource_path)
		status.text="Settings saved." if error==OK else error_string(error))
	column.add_child(save)
	var close := Button.new()
	close.name="CerrarSalpicaduras"
	close.text="Close"
	close.pressed.connect(func():panel.hide())
	column.add_child(close)
	status=Label.new()
	status.text="Live changes. Use the button to open settings."
	column.add_child(status)
	panel.hide()
	toggle.pressed.connect(func():panel.visible=not panel.visible)
