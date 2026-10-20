@tool
extends EditorExportPlugin
## RDShaderFile export normally keeps imported SPIR-V and its .import remap.
## FileAccess readers (e.g. breaker lifecycle variants) also need original GLSL.
## Keep BOTH representations; do not skip or replace the imported resource.
func _get_name() -> String:
	return "OceanRawComputeSources"

func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with("res://addons/ocean/") and path.get_extension() == "glsl":
		add_file(path, FileAccess.get_file_as_bytes(path), false)
