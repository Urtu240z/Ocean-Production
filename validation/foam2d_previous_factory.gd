extends RefCounted
## Validation-only frozen first-iteration reference, without swapping live files.
static func create(generation := "iteration1_sources") -> Node:
	var snapshot := "res://temp/foam2d/"+generation+"/addons/ocean/surface/foam2d/"
	var history_source := FileAccess.get_file_as_string(snapshot + "projected_wake_history.gd")
	history_source = history_source.replace("res://addons/ocean/surface/foam2d/history_%s.glsl", snapshot + "history_%s.glsl")
	# Snapshot directories are intentionally excluded from resource import.
	history_source = history_source.replace("var file := load(path) as RDShaderFile\n\t\tvar spirv := file.get_spirv()",
		"var source := RDShaderSource.new()\n\t\tsource.source_compute = FileAccess.get_file_as_string(path).replace(\"#[compute]\", \"\")\n\t\tvar spirv := _rd.shader_compile_spirv_from_source(source)")
	var history_script := GDScript.new()
	history_script.source_code = history_source
	assert(history_script.reload() == OK)
	var director_source := FileAccess.get_file_as_string(snapshot + "foam2d_review_director.gd")
	director_source = director_source.replace("const History := preload(\"res://addons/ocean/surface/foam2d/projected_wake_history.gd\")", "var History: GDScript")
	for file in ["contact_projection.gdshaderinc", "projected_fragment.inc"]:
		director_source = director_source.replace("res://addons/ocean/surface/foam2d/" + file, snapshot + file)
	var director_script := GDScript.new()
	director_script.source_code = director_source
	assert(director_script.reload() == OK)
	var director: Node = director_script.new()
	director.set("History", history_script)
	return director
