extends SceneTree

const Authoring = preload("res://addons/ocean/coastal/baking/coastal_bake_authoring.gd")
const Bathymetry = preload("res://addons/ocean/coastal/baking/bathymetry_baker.gd")

class TestData extends RefCounted:
	func get_region_locations() -> Array[Vector2i]:
		return [Vector2i(-2, -1), Vector2i(1, 2)]

	func get_height(p: Vector3) -> float:
		if p.x < -7.0:
			return NAN
		return 3.0 if p.x > 4.0 else -4.0

class TestTerrain extends Node3D:
	var data = TestData.new()
	var region_size := 4
	var vertex_spacing := 5.0

func _initialize() -> void:
	var terrain := TestTerrain.new()
	var geometry := Node3D.new()
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4.0, 4.0)
	mesh.mesh = plane
	mesh.position = Vector3(-2.0, -1.0, 0.0)
	geometry.add_child(mesh)
	var author = Authoring.new()
	var properties := {}
	for property in author.get_property_list():
		properties[property.name] = property.usage
	assert((properties["terrain"] & PROPERTY_USAGE_EDITOR) != 0)
	assert((properties["last_bake"] & PROPERTY_USAGE_EDITOR) != 0)
	assert((properties["bounds_min_xz"] & PROPERTY_USAGE_EDITOR) == 0, "Manual bounds should be advanced")
	author.source_root = geometry
	author.terrain_sources.assign([terrain])
	author.use_source_bounds = false
	author.bounds_min_xz = Vector2(-8, -8)
	author.bounds_max_xz = Vector2(8, 8)
	author.cell_size_m = 1.0
	author.coast_id = "baker_validation"
	author.output_root = "res://temp/coastal_baker_check"
	var bake = author.bake_coastal_asset()
	assert(bake != null and bake.is_valid(), "Mixed source bake failed")
	assert(is_equal_approx(bake.bathymetry.depth_m[8 * 17 + 6], 1.0), "Mesh must override lower terrain")
	assert(is_equal_approx(bake.bathymetry.depth_m[8 * 17 + 10], 4.0), "Terrain depth incorrect")
	assert(bake.bathymetry.land_water_mask[8 * 17 + 14] == 0, "Terrain island must be land")
	assert(bake.bathymetry.real_seabed_coverage[8 * 17] == 0, "Hole must not claim seabed coverage")
	var reload = ResourceLoader.load(bake.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
	assert(reload != null and reload.is_valid(), "Saved bake cannot reload")
	var second = author.bake_coastal_asset()
	assert(second != null and second.is_valid(), "Rebake failed")
	# Simple workflow: one Terrain3D node, no manual bounds or cell size.
	author.terrain = terrain
	author.terrain_sources.clear()
	author.source_root = null
	author.bounds_padding_m = 0.0
	author.terrain_resolution = 32
	author.coast_id = "whole_terrain_validation"
	var whole = author.bake_coastal_asset()
	assert(whole != null and whole.is_valid(), "Automatic full terrain bake failed")
	assert(whole.bathymetry.world_origin_xz == Vector2(-40, -20), "Negative regions or vertex spacing lost")
	assert(whole.bathymetry.width == 32 and whole.bathymetry.height == 32, "Automatic grid size incorrect")
	assert(whole.bathymetry.world_max_xz().x >= 40.0 and whole.bathymetry.world_max_xz().y >= 60.0, "Terrain was cropped")
	author.free()
	terrain.free()
	geometry.free()
	print("COASTAL_BAKER_PASS mixed sources, holes, save/reload, rebake, full extent, negative regions, vertex spacing, automatic grid")
	quit()
