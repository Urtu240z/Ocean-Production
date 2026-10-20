@tool
extends EditorPlugin
const Exporter = preload("res://addons/ocean/editor/ocean_shader_export.gd")
var _exporter: EditorExportPlugin

func _enter_tree() -> void:
	_exporter = Exporter.new()
	add_export_plugin(_exporter)

func _exit_tree() -> void:
	remove_export_plugin(_exporter)
	_exporter = null
