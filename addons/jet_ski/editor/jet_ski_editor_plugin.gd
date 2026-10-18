@tool
extends EditorPlugin
const Inspector:=preload("res://addons/jet_ski/editor/jet_ski_inspector.gd")
const Rules:=preload("res://addons/jet_ski/editor/authoring_rules.gd")
var _inspector: EditorInspectorPlugin

func _enter_tree() -> void:
	_inspector=Inspector.new()
	_inspector.show_all=bool(EditorInterface.get_editor_settings().get_project_metadata("jet_ski_inspector","show_all",false))
	add_inspector_plugin(_inspector)
	EditorInterface.get_inspector().property_edited.connect(_property_edited)

func _exit_tree() -> void:
	if EditorInterface.get_inspector().property_edited.is_connected(_property_edited):
		EditorInterface.get_inspector().property_edited.disconnect(_property_edited)
	if _inspector!=null: remove_inspector_plugin(_inspector)

func _property_edited(property: String) -> void:
	if property not in Rules.REFRESH_PROPERTIES: return
	var object: Object=EditorInterface.get_inspector().get_edited_object()
	if is_instance_valid(object) and Rules.handles(object): object.notify_property_list_changed.call_deferred()
