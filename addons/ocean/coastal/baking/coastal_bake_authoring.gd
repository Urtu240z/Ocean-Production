@tool
class_name OceanCoastalBakeAuthoring
extends Node3D
## Authoring-only pipeline: geometry -> Bathymetry -> Eikonal -> Warp -> disk.
## Este Node no se instancia ni se ejecuta como parte del runtime de OceanV3.

@export_dir var output_root := "res://coastal_bakes"
const SAFE_ID_CHARS := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
const BathymetryBakerScript := preload("res://addons/ocean/coastal/baking/bathymetry_baker.gd")
const EikonalBakerScript := preload("res://addons/ocean/coastal/baking/coastal_eikonal_baker.gd")
const WarpBakerScript := preload("res://addons/ocean/coastal/baking/coastal_warp_baker.gd")

@export_category("Source")
## Drop the Terrain3D node here, then press Bake. All its active regions are included.
@export var terrain: Node3D
@export_enum("512:512", "1024:1024", "2048:2048") var terrain_resolution := 512
@export var advanced_settings := false:
	set(value):
		advanced_settings = value
		notify_property_list_changed()
@export var full_terrain := true
@export var sync_ocean_on_bake := true
@export var coast_id := "coast"
@export var source_root: Node3D
@export var source: MeshInstance3D
## Terrain3D nodes; no hard dependency on the Terrain3D addon.
@export var terrain_sources: Array[Node3D] = []
@export var ocean: Node3D
@export var apply_after_bake := true
@export var last_bake: OceanPortableCoastalBakeAsset
@export_tool_button("Read sea level and direction from Ocean", "Reload") var read_ocean_button = read_ocean

@export_category("Bathymetry")
@export var sea_level_y := 0.0
@export_range(0.1, 32.0, 0.1, "suffix:m") var cell_size_m := 1.0
@export var bounds_min_xz := Vector2(-64.0, -64.0)
@export var bounds_max_xz := Vector2(64.0, 64.0)
@export var use_source_bounds := true
@export_range(4096, 1048576, 4096) var max_grid_cells := 262144
@export_range(0.0, 10000.0, 1.0, "suffix:m") var bounds_padding_m := 64.0
@export var synthetic_depth_enabled := true
@export_range(0.0, 10.0, 0.01) var synthetic_slope := 0.20
@export_range(0.0, 10000.0, 0.1, "suffix:m") var synthetic_max_depth_m := 20.0
@export_range(0.0, 128.0, 0.5, "suffix:m") var optical_seabed_feather_m := 12.0

@export_category("Eikonal")
@export var incoming_direction_xz := Vector2.RIGHT
@export_range(0.1, 200.0, 0.1, "suffix:m") var reference_wavelength_m := 16.0
@export_range(0.1, 30.0, 0.01, "suffix:m/s²") var gravity_mps2 := 9.81
@export_range(0.01, 20.0, 0.01, "suffix:m") var min_valid_depth_m := 0.25
@export_range(1, 512, 1) var max_sweep_cycles := 16
@export_range(0.0000001, 0.1, 0.0000001, "or_greater") var convergence_tolerance_s := 1.0e-4
@export var shadow_recovery_enabled := true
@export_range(0.0, 1.0, 0.01) var shadow_min_scale := 0.15
@export_range(0.0, 1.0, 0.01) var shadow_occlusion_entry_scale := 0.70
@export_range(0.1, 1000.0, 0.1, "suffix:m") var shadow_detour_length_m := 32.0
@export_range(0, 8, 1) var shadow_smoothing_passes := 2
@export_range(0.0, 45.0, 0.1, "suffix:deg") var shadow_diffraction_angle_deg := 12.0
@export_range(0.0, 1.0, 0.01) var shadow_recovery_strength := 1.0
@export_range(0, 8, 1) var direction_smoothing_passes := 3
@export_range(0.0, 1.0, 0.01) var direction_smoothing_strength := 0.35
@export_range(0.0, 90.0, 0.1, "suffix:deg") var direction_smoothing_threshold_deg := 6.0

@export_category("Cut locus")
@export var cut_locus_enabled := true
@export_range(0.0, 180.0, 0.1, "suffix:deg") var cut_locus_detect_angle_deg := 35.0
@export_range(0.0, 1000.0, 0.1, "suffix:m") var cut_locus_blend_radius_m := 12.0
@export_range(0, 64, 1) var cut_locus_blend_passes := 12
@export_range(0.0, 1.0, 0.01) var cut_locus_blend_strength := 0.55

@export_category("Phase regularization")
@export var phase_regularization_enabled := true
@export_range(0, 128, 1) var phase_regularization_passes := 24
@export_range(0.0, 1.0, 0.01) var phase_regularization_strength := 0.65
@export_range(0.0, 4.0, 0.01) var phase_regularization_raw_fidelity := 0.25

@export_category("Warp")
@export_enum("PHASE_TRANSVERSE_IDENTITY", "LEGACY_CHARACTERISTIC_BACKTRACE") var warp_mapping_mode := 0
@export_range(0.05, 8.0, 0.05) var backtrace_step_cells := 0.5
@export_range(0.0, 1.0, 0.01) var detj_safe_threshold := 0.5
@export_range(0, 1000000, 1) var max_backtrace_steps := 0

@export_category("Bake")
@export_multiline var status := "Assign Terrain3D and press BAKE COASTAL ASSET. All terrain regions are included."
@export var preview: Texture2D
@export_tool_button("BAKE COASTAL ASSET", "Play") var bake_coastal_asset_button = bake_coastal_asset


func bake_coastal_asset() -> OceanPortableCoastalBakeAsset:
	## Operación explícita de authoring; nunca la llama OceanV3 al ejecutar el juego.
	var safe_id := _sanitize_coast_id(coast_id)
	if ocean != null and sync_ocean_on_bake:
		read_ocean()
	status = "Bake failed; see Output for details. Previous bake retained."
	if safe_id.is_empty():
		push_error("OceanCoastalBakeAuthoring: coast_id vacío o inválido.")
		return null
	if terrain == null and source_root == null and source == null and terrain_sources.is_empty():
		push_error("OceanCoastalBakeAuthoring: asigna source_root o source.")
		return null
	var direction := incoming_direction_xz.normalized()
	if direction.length_squared() <= 1.0e-8:
		push_error("OceanCoastalBakeAuthoring: incoming_direction_xz no puede ser cero.")
		return null

	var bathymetry_baker := BathymetryBakerScript.new()
	bathymetry_baker.terrain_sources.assign(terrain_sources)
	if terrain != null and not bathymetry_baker.terrain_sources.has(terrain):
		bathymetry_baker.terrain_sources.append(terrain)
	bathymetry_baker.max_grid_cells = max_grid_cells
	bathymetry_baker.source_root = source_root
	bathymetry_baker.source = source
	bathymetry_baker.sea_level_y = sea_level_y
	bathymetry_baker.cell_size_m = cell_size_m
	bathymetry_baker.bounds_min_xz = bounds_min_xz
	bathymetry_baker.bounds_max_xz = bounds_max_xz
	bathymetry_baker.use_source_bounds = use_source_bounds
	if terrain != null and full_terrain:
		bathymetry_baker.use_source_bounds = true
		bathymetry_baker.grid_samples_longest_side = terrain_resolution
		bathymetry_baker.max_grid_cells = terrain_resolution * terrain_resolution
	bathymetry_baker.bounds_padding_m = bounds_padding_m
	bathymetry_baker.synthetic_depth_enabled = synthetic_depth_enabled
	bathymetry_baker.synthetic_slope = synthetic_slope
	bathymetry_baker.synthetic_max_depth_m = synthetic_max_depth_m
	bathymetry_baker.optical_seabed_feather_m = optical_seabed_feather_m
	print("COASTAL ASSET: baking bathymetry...")
	var bathymetry: OceanPortableBathymetryData = bathymetry_baker.bake()
	if bathymetry == null or not bathymetry.is_valid():
		push_error("OceanCoastalBakeAuthoring: OceanPortableBathymetryData inválida.")
		return null
	cell_size_m = bathymetry.cell_size_m
	bounds_min_xz = bathymetry.world_origin_xz
	bounds_max_xz = bathymetry.world_max_xz()

	var eikonal_baker := EikonalBakerScript.new()
	eikonal_baker.bathymetry_data = bathymetry
	eikonal_baker.incoming_direction_xz = direction
	eikonal_baker.reference_wavelength_m = reference_wavelength_m
	eikonal_baker.gravity_mps2 = gravity_mps2
	eikonal_baker.min_valid_depth_m = min_valid_depth_m
	eikonal_baker.max_sweep_cycles = max_sweep_cycles
	eikonal_baker.convergence_tolerance_s = convergence_tolerance_s
	eikonal_baker.shadow_recovery_enabled = shadow_recovery_enabled
	eikonal_baker.shadow_min_scale = shadow_min_scale
	eikonal_baker.shadow_occlusion_entry_scale = shadow_occlusion_entry_scale
	eikonal_baker.shadow_detour_length_m = shadow_detour_length_m
	eikonal_baker.shadow_smoothing_passes = shadow_smoothing_passes
	eikonal_baker.shadow_diffraction_angle_deg = shadow_diffraction_angle_deg
	eikonal_baker.shadow_recovery_strength = shadow_recovery_strength
	eikonal_baker.direction_smoothing_passes = direction_smoothing_passes
	eikonal_baker.direction_smoothing_strength = direction_smoothing_strength
	eikonal_baker.direction_smoothing_threshold_deg = direction_smoothing_threshold_deg
	eikonal_baker.cut_locus_enabled = cut_locus_enabled
	eikonal_baker.cut_locus_detect_angle_deg = cut_locus_detect_angle_deg
	eikonal_baker.cut_locus_blend_radius_m = cut_locus_blend_radius_m
	eikonal_baker.cut_locus_blend_passes = cut_locus_blend_passes
	eikonal_baker.cut_locus_blend_strength = cut_locus_blend_strength
	eikonal_baker.phase_regularization_enabled = phase_regularization_enabled
	eikonal_baker.phase_regularization_passes = phase_regularization_passes
	eikonal_baker.phase_regularization_strength = phase_regularization_strength
	eikonal_baker.phase_regularization_raw_fidelity = phase_regularization_raw_fidelity
	print("COASTAL ASSET: solving Eikonal...")
	var propagation: OceanPortableCoastalPropagationData = eikonal_baker.bake()
	if propagation == null or not propagation.is_valid():
		push_error("OceanCoastalBakeAuthoring: OceanPortableCoastalPropagationData inválida.")
		return null

	var warp_baker := WarpBakerScript.new()
	warp_baker.propagation = propagation
	warp_baker.mapping_mode = warp_mapping_mode as WarpBakerScript.WarpMappingMode
	warp_baker.backtrace_step_cells = backtrace_step_cells
	warp_baker.max_backtrace_steps = max_backtrace_steps
	warp_baker.detj_safe_threshold = detj_safe_threshold
	print("COASTAL ASSET: building warp...")
	var warp: OceanPortableCoastalWarpData = warp_baker.bake()
	if warp == null or not warp.is_valid():
		push_error("OceanCoastalBakeAuthoring: OceanPortableCoastalWarpData inválida.")
		return null

	var asset := OceanPortableCoastalBakeAsset.new()
	asset.format_version = OceanPortableCoastalBakeAsset.CURRENT_FORMAT_VERSION
	asset.coast_id = safe_id
	asset.bathymetry = bathymetry
	asset.propagation = propagation
	asset.warp = warp
	asset.bathymetry_cell_size_m = bathymetry.cell_size_m
	asset.bathymetry_sea_level_y = bathymetry.sea_level_y
	asset.bathymetry_bounds_min_xz = bathymetry.world_origin_xz
	asset.bathymetry_bounds_max_xz = bathymetry.world_max_xz()
	asset.bathymetry_synthetic_depth_enabled = synthetic_depth_enabled
	asset.bathymetry_synthetic_slope = synthetic_slope
	asset.bathymetry_synthetic_max_depth_m = synthetic_max_depth_m
	asset.eikonal_incoming_direction_xz = direction
	asset.eikonal_reference_wavelength_m = reference_wavelength_m
	asset.eikonal_gravity_mps2 = gravity_mps2
	asset.eikonal_min_valid_depth_m = min_valid_depth_m
	asset.eikonal_max_sweep_cycles = max_sweep_cycles
	asset.eikonal_convergence_tolerance_s = convergence_tolerance_s
	asset.eikonal_shadow_recovery_enabled = shadow_recovery_enabled
	asset.eikonal_shadow_min_scale = shadow_min_scale
	asset.eikonal_shadow_occlusion_entry_scale = shadow_occlusion_entry_scale
	asset.eikonal_shadow_detour_length_m = shadow_detour_length_m
	asset.eikonal_shadow_smoothing_passes = shadow_smoothing_passes
	asset.eikonal_shadow_diffraction_angle_deg = shadow_diffraction_angle_deg
	asset.eikonal_shadow_recovery_strength = shadow_recovery_strength
	asset.eikonal_direction_smoothing_passes = direction_smoothing_passes
	asset.eikonal_direction_smoothing_strength = direction_smoothing_strength
	asset.eikonal_direction_smoothing_threshold_deg = direction_smoothing_threshold_deg
	asset.eikonal_cut_locus_enabled = cut_locus_enabled
	asset.eikonal_cut_locus_detect_angle_deg = cut_locus_detect_angle_deg
	asset.eikonal_cut_locus_blend_radius_m = cut_locus_blend_radius_m
	asset.eikonal_cut_locus_blend_passes = cut_locus_blend_passes
	asset.eikonal_cut_locus_blend_strength = cut_locus_blend_strength
	asset.eikonal_phase_regularization_enabled = phase_regularization_enabled
	asset.eikonal_phase_regularization_passes = phase_regularization_passes
	asset.eikonal_phase_regularization_strength = phase_regularization_strength
	asset.eikonal_phase_regularization_raw_fidelity = phase_regularization_raw_fidelity
	asset.warp_backtrace_step_cells = backtrace_step_cells
	asset.warp_max_backtrace_steps = max_backtrace_steps
	asset.warp_detj_safe_threshold = detj_safe_threshold
	if not asset.is_valid():
		push_error("OceanCoastalBakeAuthoring: el manifest no supera la validación de grid.")
		return null

	var saved := _persist_canonical_asset(asset, bathymetry, propagation, warp, safe_id)
	if saved == null:
		return null
	last_bake = saved
	if last_bake != null and apply_after_bake and ocean != null:
		ocean.set("coastal_bake", last_bake)
		ocean.set("coastal", true)
	if last_bake != null:
		status = "Saved %dx%d at %.2f m: %s" % [bathymetry.width, bathymetry.height, cell_size_m, last_bake.resource_path]
		_build_preview(bathymetry)
		if Engine.is_editor_hint():
			EditorInterface.mark_scene_as_unsaved()
	return last_bake


func read_ocean() -> void:
	if ocean == null:
		push_error("Coastal: assign Ocean first.")
		return
	sea_level_y = float(ocean.get("sea_level"))
	var angle := deg_to_rad(float(ocean.get("wind_direction_degrees")))
	incoming_direction_xz = Vector2(cos(angle), sin(angle))
	status = "Ocean sea level and direction copied. Bake again to apply."
	notify_property_list_changed()


func _validate_property(property: Dictionary) -> void:
	if property.name in [&"last_bake", &"status"]:
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == "preview":
		property.usage &= ~PROPERTY_USAGE_STORAGE
	var simple := [&"terrain", &"terrain_resolution", &"ocean", &"coast_id", &"output_root", &"last_bake", &"status", &"preview", &"bake_coastal_asset_button", &"advanced_settings", &"source_root"]
	if not advanced_settings and property.name not in simple and (property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0:
		property.usage &= ~PROPERTY_USAGE_EDITOR


func _build_preview(data: Resource) -> void:
	var image := Image.create(data.width, data.height, false, Image.FORMAT_RGB8)
	for z in data.height:
		for x in data.width:
			var index: int = z * data.width + x
			var color := Color(0.35, 0.28, 0.15)
			if data.land_water_mask[index] != 0:
				var amount := clampf(data.depth_m[index] / maxf(synthetic_max_depth_m, 1.0), 0.0, 1.0)
				color = Color(0.1, 0.8, 0.85).lerp(Color(0.02, 0.08, 0.3), amount)
				if data.real_seabed_coverage[index] == 0:
					color = color.lerp(Color(0.6, 0.15, 0.7), 0.4)
			image.set_pixel(x, z, color)
	image.resize(mini(512, data.width), mini(512, data.height), Image.INTERPOLATE_NEAREST)
	preview = ImageTexture.create_from_image(image)


func _persist_canonical_asset(asset: OceanPortableCoastalBakeAsset, _bathymetry: OceanPortableBathymetryData, _propagation: OceanPortableCoastalPropagationData, _warp: OceanPortableCoastalWarpData, safe_id: String) -> OceanPortableCoastalBakeAsset:
	# One binary bundle keeps all three grids together during a failed rebake.
	if not output_root.begins_with("res://") or output_root.contains(".."):
		push_error("Coastal: output_root must be inside this project.")
		return null
	var directory := "%s/%s" % [output_root.trim_suffix("/"), safe_id]
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	if error != OK:
		push_error("Coastal: cannot create output directory (%s)." % error_string(error))
		return null
	var path := directory + "/coastal_bake.res"
	error = ResourceSaver.save(asset, path, ResourceSaver.FLAG_COMPRESS)
	if error != OK:
		push_error("Coastal: cannot save bake (%s)." % error_string(error))
		return null
	asset.take_over_path(path)
	asset.emit_changed()
	print("COASTAL ASSET: saved %s" % path)
	return asset


func _sanitize_coast_id(value: String) -> String:
	var result := ""
	for character in value.strip_edges():
		if SAFE_ID_CHARS.find(character) >= 0:
			result += character
	return result
