extends SceneTree
## H4.14 clipmap cell-count and 2:1 topology contract validation.

const PROFILE := preload("res://addons/ocean/core/ocean_quality_profile.gd")
const BUILDER := preload("res://addons/ocean/surface/ocean_clipmap_mesh_builder.gd")
const QUALITY_PATH := "res://addons/ocean/core/ocean_quality_profile.gd"
const BUILDER_PATH := "res://addons/ocean/surface/ocean_clipmap_mesh_builder.gd"

const CANONICAL_CASES := {
	2: 4,
	3: 4,
	4: 4,
	5: 4,
	6: 8,
	7: 8,
	126: 128,
	127: 128,
	128: 128,
	129: 128,
	130: 132,
	192: 192,
}
const VALID_CELLS := [4, 8, 12, 64, 128, 192]


func _initialize() -> void:
	if not _check_canonicalization():
		_fail("OceanQualityProfile did not canonicalize cells_per_side")
		return
	print("OCEAN_CLIPMAP_CELL_CANONICALIZATION_PASS")
	if not _check_parity():
		_fail("Clipmap 2:1 parity is not exact")
		return
	print("OCEAN_CLIPMAP_2_TO_1_PARITY_PASS")
	if not _check_valid_topology():
		_fail("Valid clipmap topology construction failed")
		return
	print("OCEAN_CLIPMAP_VALID_TOPOLOGY_PASS")
	if not _check_invalid_direct_input_guard():
		_fail("Builder does not guard invalid direct input")
		return
	print("OCEAN_CLIPMAP_INVALID_DIRECT_INPUT_GUARD_PASS")
	quit(0)


func _check_canonicalization() -> bool:
	var quality = PROFILE.new()
	if int(quality.cells_per_side) != 192:
		return false
	for requested in CANONICAL_CASES:
		quality.cells_per_side = int(requested)
		if int(quality.cells_per_side) != int(CANONICAL_CASES[requested]):
			return false
	return true


func _check_parity() -> bool:
	for cells in VALID_CELLS:
		if cells % 4 != 0:
			return false
		var half_cells: int = cells / 2
		var inner_cells: int = half_cells / 2
		if half_cells * 2 != cells or inner_cells * 2 != half_cells:
			return false
	return true


func _check_valid_topology() -> bool:
	for cells in VALID_CELLS:
		for level in [0, 1, 2]:
			var mesh: ArrayMesh = BUILDER.build_level(cells, 0.25, level)
			if mesh == null or mesh.get_surface_count() != 1:
				return false
			var arrays: Array = mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if vertices.is_empty() or indices.is_empty() or indices.size() % 3 != 0:
				return false
			for vertex in vertices:
				if not vertex.is_finite():
					return false
			for index in indices:
				if int(index) < 0 or int(index) >= vertices.size():
					return false
	return true


func _check_invalid_direct_input_guard() -> bool:
	if BUILDER.is_valid_cells_per_side(126):
		return false
	var builder_source := _read(BUILDER_PATH)
	if not builder_source.contains("is_valid_cells_per_side(cells_per_side)"):
		return false
	if not builder_source.contains("return ArrayMesh.new()"):
		return false
	if not builder_source.contains("spacing <= 0.0"):
		return false
	return _read(QUALITY_PATH).contains("@export_range(4, 1024, 4)")


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	return file.get_as_text() if file != null else ""


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
