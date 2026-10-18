@tool
extends EditorInspectorPlugin
const Rules:=preload("res://addons/jet_ski/editor/authoring_rules.gd")
var show_all := false

func _can_handle(object: Object) -> bool:
	return Rules.handles(object)

func _parse_begin(object: Object) -> void:
	var toggle:=CheckBox.new()
	toggle.text="Show All Mode Settings"
	toggle.tooltip_text="Muestra también los ajustes de otros modos y de ayudas desactivadas. Ocultarlos no borra sus valores guardados."
	toggle.button_pressed=show_all
	toggle.toggled.connect(func(value: bool):
		show_all=value
		EditorInterface.get_editor_settings().set_project_metadata("jet_ski_inspector","show_all",value)
		object.notify_property_list_changed())
	add_custom_control(toggle)

func _parse_property(object: Object, _type: Variant.Type, name: String, _hint_type: PropertyHint,
		_hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	# Returning true suppresses only this editor row. Native controls, Undo/Redo,
	# scene storage, animation keys and every property value remain unchanged.
	return not Rules.visible(object,name,show_all)
