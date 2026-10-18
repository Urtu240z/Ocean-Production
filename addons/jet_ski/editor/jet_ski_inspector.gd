@tool
extends EditorInspectorPlugin
const Rules:=preload("res://addons/jet_ski/editor/authoring_rules.gd")
var show_all := false

func _can_handle(object: Object) -> bool:
	return Rules.handles(object)

func _parse_begin(object: Object) -> void:
	var toggle:=CheckBox.new()
	toggle.text="Show All Mode Settings"
	toggle.tooltip_text="Muestra los ajustes de ayudas desactivadas. Los modelos antiguos siguen separados en Legacy → Show Legacy Settings. Ocultar ajustes no borra sus valores guardados."
	toggle.button_pressed=show_all
	toggle.toggled.connect(func(value: bool):
		show_all=value
		EditorInterface.get_editor_settings().set_project_metadata("jet_ski_inspector","show_all",value)
		object.notify_property_list_changed())
	add_custom_control(toggle)
	if Rules.script_path(object)==Rules.ROOT and (int(object.get("buoyancy_mode"))!=1 or int(object.get("hull_response_mode"))!=0):
		var notice:=Label.new()
		notice.text="Legacy physics is active. See Legacy → Show Legacy Settings."
		notice.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
		notice.tooltip_text="Esta escena conserva un modelo antiguo activo. Para volver al estándar: Legacy → Show Legacy Settings, Buoyancy Mode = Buoyancy Physics y Hull Response Mode = Standard."
		add_custom_control(notice)

func _parse_property(object: Object, _type: Variant.Type, name: String, _hint_type: PropertyHint,
		_hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	# Returning true suppresses only this editor row. Native controls, Undo/Redo,
	# scene storage, animation keys and every property value remain unchanged.
	return not Rules.visible(object,name,show_all)
