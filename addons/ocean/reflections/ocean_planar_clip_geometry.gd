@tool
extends RefCounted
## Reversible, opt-in ShaderMaterial variants. Never changes shared mesh,
## shader or material resources, nor converts StandardMaterial3D implicitly.
const CAMERA_PARAM := &"_ocean_planar_clip_camera"
const LEVEL_PARAM := &"_ocean_planar_clip_level"
const DECLARATIONS := "\ninstance uniform vec3 _ocean_planar_clip_camera = vec3(1e20);\ninstance uniform float _ocean_planar_clip_level = -1e20;\n"
const CLIP := "\nif (distance(CAMERA_POSITION_WORLD, _ocean_planar_clip_camera) < 0.01 && (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y < _ocean_planar_clip_level) { discard; }\n"
var _entries: Array[Dictionary] = []
var _shaders: Dictionary = {}
var unsupported: Array[String] = []
var _warned: Dictionary = {}

func restore() -> void:
	for entry in _entries:
		var mesh: MeshInstance3D = entry.mesh
		if not is_instance_valid(mesh): continue
		if int(entry.index) < 0:
			if mesh.material_override == entry.applied: mesh.material_override = entry.original
		elif int(entry.index) < mesh.get_surface_override_material_count():
			if mesh.get_surface_override_material(entry.index) == entry.applied:
				mesh.set_surface_override_material(entry.index, entry.original)
		mesh.set_instance_shader_parameter(CAMERA_PARAM, null)
		mesh.set_instance_shader_parameter(LEVEL_PARAM, null)
	_entries.clear()

func _variant(source: Material) -> ShaderMaterial:
	if not source is ShaderMaterial or source.shader == null or source.next_pass != null: return null
	var code: String = source.shader.code
	if code.count("instance uniform") > 13 or "_ocean_planar_clip_camera" in code: return null
	var shader: Shader
	var cached: Dictionary = _shaders.get(source.shader, {})
	if cached.get("source", "") == code:
		shader = cached.shader
	else:
		var regex := RegEx.new()
		regex.compile("void\\s+fragment\\s*\\(\\s*\\)\\s*\\{")
		var match := regex.search(code)
		if match == null: return null
		code = code.insert(match.get_end(), CLIP)
		var first_semicolon := code.find(";", code.find("shader_type"))
		if first_semicolon < 0: return null
		code = code.insert(first_semicolon + 1, DECLARATIONS)
		# A new Shader has no source directory; make local includes explicit.
		regex.compile('#include\\s+"([^"\\n]+)"')
		var matches := regex.search_all(code)
		for index in range(matches.size() - 1, -1, -1):
			var include_path: String = matches[index].get_string(1)
			if not include_path.begins_with("res://"):
				if source.shader.resource_path.is_empty(): return null
				var absolute: String = source.shader.resource_path.get_base_dir().path_join(include_path)
				code = code.substr(0, matches[index].get_start(1)) + absolute + code.substr(matches[index].get_end(1))
		shader = Shader.new()
		shader.code = code
		_shaders[source.shader] = {"source": source.shader.code, "shader": shader}
	var material: ShaderMaterial = source.duplicate()
	material.shader = shader
	return material

func scan(tree: SceneTree, world: World3D, group: StringName, ocean_surface: Node) -> void:
	restore()
	unsupported.clear()
	if group == &"": return
	for node in tree.root.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		if mesh.mesh == null or not mesh.is_inside_tree() or mesh.get_world_3d() != world or ocean_surface.is_ancestor_of(mesh): continue
		var tagged := false
		var parent: Node = mesh
		while parent != null:
			if parent.is_in_group(group): tagged = true; break
			parent = parent.get_parent()
		if not tagged: continue
		var indices: Array[int] = []
		if mesh.material_override != null: indices.append(-1)
		if indices.is_empty():
			for index in mesh.mesh.get_surface_count(): indices.append(index)
		for index in indices:
			var original: Material = mesh.material_override if index < 0 else mesh.get_surface_override_material(index)
			var source: Material = original if original != null else mesh.mesh.surface_get_material(index)
			var material := _variant(source)
			if material == null:
				var path := str(mesh.get_path())
				unsupported.append(path)
				if not _warned.has(path):
					push_warning("Planar partial clip skipped for %s: use a ShaderMaterial with fragment(), <=13 instance uniforms and no next_pass; or move it to the exclude group." % path)
					_warned[path] = true
				continue
			_entries.append({"mesh": mesh, "index": index, "original": original, "applied": material})
			if index < 0: mesh.material_override = material
			else: mesh.set_surface_override_material(index, material)

func set_plane(camera_position: Vector3, level: float) -> void:
	for entry in _entries:
		var mesh: MeshInstance3D = entry.mesh
		if is_instance_valid(mesh):
			mesh.set_instance_shader_parameter(CAMERA_PARAM, camera_position)
			mesh.set_instance_shader_parameter(LEVEL_PARAM, level)

func get_state() -> Dictionary:
	return {"clipped_surfaces": _entries.size(), "unsupported": unsupported.duplicate()}
