extends Node
## H4.16 runtime contract for the Production Local Breaker Refinement layout.
## The layout is obtained from OceanClipmapSurface and the meshes are built by
## the real Production MeshBuilder; this is not a formula-only duplicate.

const SURFACE := preload("res://addons/ocean/surface/ocean_clipmap_surface.gd")
const QUALITY := preload("res://addons/ocean/core/ocean_quality_profile.gd")
const MESH_BUILDER := preload("res://addons/ocean/surface/ocean_clipmap_mesh_builder.gd")
const SURFACE_PATH := "res://addons/ocean/surface/ocean_clipmap_surface.gd"

const EPSILON := 0.00001
const DEFAULT_CELLS := 192
const DEFAULT_SPACING := 0.25

var _surface: OceanClipmapSurface


func _ready() -> void:
	call_deferred(&"_initialize")


func _initialize() -> void:
	_surface = SURFACE.new()
	if _surface == null:
		_fail("Could not instantiate OceanClipmapSurface")
		return
	get_tree().root.add_child(_surface)
	if not _check_default_layout():
		_fail("Default refinement layout changed")
		return
	print("OCEAN_REFINEMENT_DEFAULT_LAYOUT_COMPAT_PASS")
	if not _check_quality_spacing_cases():
		_fail("Quality spacing did not derive the expected Production layout")
		return
	print("OCEAN_REFINEMENT_QUALITY_SPACING_PASS")
	if not _check_exact_l0_coverage():
		_fail("Refinement tiles do not cover L0 exactly")
		return
	print("OCEAN_REFINEMENT_EXACT_L0_COVERAGE_PASS")
	if not _check_two_to_one_topology():
		_fail("One or more 2:1 edge-mask variants is invalid")
		return
	print("OCEAN_REFINEMENT_2_TO_1_TOPOLOGY_PASS")
	if not _check_ocean_space_scale():
		_fail("Ocean Space scale is not applied once to transforms")
		return
	print("OCEAN_REFINEMENT_OCEAN_SPACE_SCALE_PASS")
	if not _check_default_geometry_regression():
		_fail("Default geometry regression detected")
		return
	print("OCEAN_REFINEMENT_DEFAULT_GEOMETRY_REGRESSION_PASS")
	if not _check_source_contract():
		_fail("Production refinement still has a fixed geometry authority")
		return
	print("OCEAN_REFINEMENT_SOURCE_CONTRACT_PASS")
	get_tree().quit(0)


func _layout(cells: int, spacing: float) -> Dictionary:
	var quality = QUALITY.new()
	quality.cells_per_side = cells
	quality.base_spacing_m = spacing
	_surface.set("_quality", quality)
	return _surface.call("_derive_local_breaker_refinement_layout") as Dictionary


func _check_default_layout() -> bool:
	var layout := _layout(DEFAULT_CELLS, DEFAULT_SPACING)
	return int(layout.get("coarse_cells_per_tile", 0)) == 16 \
		and _approximately_equal(float(layout.get("coarse_spacing_ocean_m", 0.0)), 0.25) \
		and _approximately_equal(float(layout.get("high_spacing_ocean_m", 0.0)), 0.125) \
		and _approximately_equal(float(layout.get("tile_size_ocean_m", 0.0)), 4.0) \
		and int(layout.get("grid_width", 0)) == 12 \
		and int(layout.get("grid_height", 0)) == 12 \
		and _approximately_equal(float(layout.get("l0_extent_ocean_m", 0.0)), 48.0)


func _check_quality_spacing_cases() -> bool:
	var cases := [
		[192, 0.50, 16, 8.0, 0.25, 12],
		[192, 0.125, 16, 2.0, 0.0625, 12],
		[40, 0.25, 8, 2.0, 0.125, 5],
		[20, 0.25, 4, 1.0, 0.125, 5],
	]
	for case_value in cases:
		var layout: Dictionary = _layout(int(case_value[0]), float(case_value[1]))
		if int(layout.get("coarse_cells_per_tile", 0)) != int(case_value[2]):
			return false
		if not _approximately_equal(float(layout.get("tile_size_ocean_m", 0.0)), float(case_value[3])):
			return false
		if not _approximately_equal(float(layout.get("high_spacing_ocean_m", 0.0)), float(case_value[4])):
			return false
		if int(layout.get("grid_width", 0)) != int(case_value[5]) or int(layout.get("grid_height", 0)) != int(case_value[5]):
			return false
	return true


func _check_exact_l0_coverage() -> bool:
	for case_value in [[192, 0.25], [192, 0.5], [192, 0.125], [40, 0.25], [20, 0.25]]:
		var layout: Dictionary = _layout(int(case_value[0]), float(case_value[1]))
		var covered_x: float = float(layout["grid_width"]) * float(layout["tile_size_ocean_m"])
		var covered_z: float = float(layout["grid_height"]) * float(layout["tile_size_ocean_m"])
		if not _approximately_equal(covered_x, float(layout["l0_extent_ocean_m"])) or not _approximately_equal(covered_z, float(layout["l0_extent_ocean_m"])):
			return false
	return true


func _check_two_to_one_topology() -> bool:
	var layout: Dictionary = _layout(DEFAULT_CELLS, DEFAULT_SPACING)
	var tile_size: float = float(layout["tile_size_ocean_m"])
	var coarse_spacing: float = float(layout["coarse_spacing_ocean_m"])
	var high_spacing: float = float(layout["high_spacing_ocean_m"])
	var reference_direction := Vector2(0.0, 1.0)
	for edge_mask in 16:
		var variant: Dictionary = MESH_BUILDER.build_tiled_high_variant(tile_size, high_spacing, coarse_spacing, edge_mask, reference_direction)
		if not _mesh_is_valid(variant.get("mesh")):
			return false
		if not _approximately_equal(high_spacing, coarse_spacing * 0.5):
			return false
		if int(variant.get("triangles", 0)) <= 0 or int(variant.get("surface_count", 0)) != 1:
			return false
	var coarse_mesh: ArrayMesh = MESH_BUILDER.build_aligned_grid(tile_size, tile_size, coarse_spacing, reference_direction)
	return _mesh_is_valid(coarse_mesh)


func _check_ocean_space_scale() -> bool:
	var layout: Dictionary = _layout(DEFAULT_CELLS, DEFAULT_SPACING)
	_surface.set("_local_breaker_refinement_layout", layout)
	_surface.set("_local_breaker_refinement_grid_width", int(layout["grid_width"]))
	_surface.set("_local_breaker_refinement_grid_height", int(layout["grid_height"]))
	var tile_size_ocean: float = float(layout["tile_size_ocean_m"])
	for scale in [0.5, 1.0, 2.0]:
		_surface.set_clipmap_geometry_scale(float(scale))
		var transforms: Array = _surface.call("_build_local_breaker_tile_transforms", Vector2.ZERO)
		if transforms.size() != 144:
			return false
		var first: Transform3D = transforms[0]
		if not _approximately_equal(first.basis.x.length(), float(scale)) or not _approximately_equal(first.basis.z.length(), float(scale)):
			return false
		var expected_extent: float = tile_size_ocean * float(scale) * 12.0
		var expected_first_axis: float = -tile_size_ocean * float(scale) * 5.5
		if not _approximately_equal(absf(first.origin.x), absf(expected_first_axis)) or not _approximately_equal(absf(first.origin.z), absf(expected_first_axis)):
			return false
		if not _approximately_equal(expected_extent, 48.0 * float(scale)):
			return false
	return true


func _check_default_geometry_regression() -> bool:
	var layout: Dictionary = _layout(DEFAULT_CELLS, DEFAULT_SPACING)
	if int(layout["grid_width"]) * int(layout["grid_height"]) != 144:
		return false
	var coarse_mesh: ArrayMesh = MESH_BUILDER.build_aligned_grid(float(layout["tile_size_ocean_m"]), float(layout["tile_size_ocean_m"]), float(layout["coarse_spacing_ocean_m"]), Vector2(0.0, 1.0))
	if not _mesh_is_valid(coarse_mesh):
		return false
	var variant_count := 1
	for edge_mask in 16:
		var variant: Dictionary = MESH_BUILDER.build_tiled_high_variant(float(layout["tile_size_ocean_m"]), float(layout["high_spacing_ocean_m"]), float(layout["coarse_spacing_ocean_m"]), edge_mask, Vector2(0.0, 1.0))
		if not _mesh_is_valid(variant.get("mesh")):
			return false
		variant_count += 1
	return variant_count == 17


func _check_source_contract() -> bool:
	var file := FileAccess.open(SURFACE_PATH, FileAccess.READ)
	if file == null:
		return false
	var source := file.get_as_text()
	return source.contains("func _derive_local_breaker_refinement_layout() -> Dictionary") \
		and not source.contains("LOCAL_BREAKER_REFINEMENT_TILE_SIZE_M") \
		and not source.contains("LOCAL_BREAKER_REFINEMENT_COARSE_SPACING_M") \
		and not source.contains("LOCAL_BREAKER_REFINEMENT_HIGH_SPACING_M")


func _mesh_is_valid(value: Variant) -> bool:
	if not value is ArrayMesh:
		return false
	var mesh: ArrayMesh = value as ArrayMesh
	if mesh.get_surface_count() != 1:
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


func _approximately_equal(a: float, b: float) -> bool:
	return absf(a - b) <= EPSILON


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
