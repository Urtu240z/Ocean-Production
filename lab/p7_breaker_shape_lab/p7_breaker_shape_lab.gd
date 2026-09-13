extends Node3D
## World-space multi-phase breaker VDM lab, topology diagnostic, and isolated refinement tile.

const VDMGenerator := preload("res://lab/p7_breaker_shape_lab/breaker_shape_vdm_generator.gd")
const COASTAL_BAKE_PATH := "res://validation/p4_paradise/coastal_bake.tres"
const WATERLINE_RAW_PATH := "res://temp/waterline_source/T_PL_Wave_1_Disp_source.bin"
const WATERLINE_RAW_BYTES := 2097152
const EXTERNAL_VDM_PATH := "res://addons/ocean/breakers/assets/breaker_plunging_test_v01.exr"
const WAVEFRONT_WIDTH_M := 32.0
const BREAKER_LENGTH_M := 32.0
const REFINEMENT_OUTER_S_EXTENT_M := 20.0
const REFINEMENT_OUTER_V_EXTENT_M := 16.0
const REFINEMENT_CORE_S_EXTENT_M := 12.0
const REFINEMENT_CORE_V_EXTENT_M := 5.0
const REFINEMENT_OUTER_SPACING_M := 0.25
const REFINEMENT_CORE_SPACING_M := 0.125
const FLATTEN_STRENGTH := 0.90
const COASTAL_PREFERRED_DEPTH_M := 2.5
const COASTAL_MIN_DEPTH_M := 1.5
const COASTAL_MAX_DEPTH_M := 4.0
const COASTAL_SHORE_DEPTH_NEAR_M := 0.25
const COASTAL_SHORE_DEPTH_FAR_M := 8.0
const SHORE_DISTANCE_NEAR_M := 0.0
const SHORE_DISTANCE_FAR_M := 12.0
const BREAKER_CYCLE_SECONDS := 4.0
const BREAKER_TRAVEL_M := 8.0

@export_range(1, 5, 1) var debug_mode := 4

var _surface: OceanClipmapSurface
var _camera: Camera3D
var _vdm: Texture2D
var _origin := Vector2.ZERO
var _propagation := Vector2(0.0, 1.0)
var _shoreward_reference_direction := Vector2(0.0, -1.0)
var _hud: Label
var _vdm_source := "OWN MULTI-PHASE VDM"
var _test_depth_m := 0.0
var _test_shore_distance_m := 0.0
var _shore_distance_texture: Texture2D
var _animation_enabled := true
var _phase_override := -1
var _topology_mode := 0
var _topology_info: Dictionary = {}
var _refinement_mode := -1
var _refinement_info: Dictionary = {}
var _tiled_info: Dictionary = {}
var _tiled_pattern_index := 0
var _p5_move_step := 0


func _ready() -> void:
	_camera = get_node_or_null(^"P0/FreeCamera") as Camera3D
	call_deferred(&"_activate_lab")


func _activate_lab() -> void:
	await get_tree().process_frame
	if _camera == null:
		push_error("P7 2D2 lab: FreeCamera is missing.")
		return
	var ocean := get_node_or_null(^"P0/Ocean")
	_surface = ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface if ocean != null else null
	if _surface == null:
		push_error("P7 2D2 lab: production OceanClipmapSurface is not ready.")
		return
	var camera_forward := -_camera.global_transform.basis.z
	_propagation = Vector2(camera_forward.x, camera_forward.z).normalized()
	if _propagation.length_squared() < 0.000001:
		_propagation = Vector2(0.0, 1.0)
	var bake := load(COASTAL_BAKE_PATH) as CoastalBakeAsset
	if bake == null or bake.bathymetry == null or not bake.bathymetry.is_valid():
		push_error("P7 2D2 lab: Coastal bake/bathymetry is missing or invalid; lab not activated.")
		return
	var selected := _find_shallow_test_location(bake.bathymetry, Vector2(_camera.global_position.x, _camera.global_position.z))
	if selected.is_empty():
		push_error("P7 2D2 lab: no valid shallow Coastal water point in depth range 1.5-4.0 m; lab not activated.")
		return
	_origin = selected["world_xz"]
	var bathymetry_sample: BathymetrySample = selected["sample"]
	_test_depth_m = bathymetry_sample.depth_m
	_test_shore_distance_m = bathymetry_sample.shore_signed_distance_m
	if bathymetry_sample.gradient.length_squared() >= 0.000001:
		_propagation = bathymetry_sample.gradient.normalized()
	var offshore_direction := bathymetry_sample.gradient.normalized()
	if offshore_direction.length_squared() < 0.000001:
		offshore_direction = _propagation
	_shoreward_reference_direction = (-offshore_direction).normalized()
	if _shoreward_reference_direction.length_squared() < 0.000001:
		_shoreward_reference_direction = Vector2(0.0, -1.0)
	var view_xz := _origin - _propagation * 18.0
	_camera.global_position = Vector3(view_xz.x, 8.0, view_xz.y)
	_camera.look_at(Vector3(_origin.x, 1.5, _origin.y), Vector3.UP)
	print("P7 COASTAL TEST LOCATION\nworld_xz=(%.3f, %.3f)\ndepth=%.3f m\nshore_signed_distance=%.3f m\ngradient=(%.3f, %.3f)\nis_water=true" % [_origin.x, _origin.y, _test_depth_m, _test_shore_distance_m, bathymetry_sample.gradient.x, bathymetry_sample.gradient.y])
	_shore_distance_texture = _build_shore_distance_texture(bake.bathymetry)
	if _shore_distance_texture == null:
		push_error("P7 2D2 lab: shore signed-distance texture could not be created; lab not activated.")
		return
	_vdm = VDMGenerator.build()
	if _vdm == null:
		push_error("P7 2E1 lab: authored multi-phase VDM atlas could not be generated; lab not activated.")
		return
	_vdm_source = "OWN MULTI-PHASE VDM"
	_surface.enable_breaker_shape_lab(_vdm, _origin, _propagation, _shoreward_reference_direction, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH, debug_mode)
	_surface.configure_breaker_shape_lab_multiphase(_shore_distance_texture, _animation_enabled)
	_tiled_info = _surface.configure_breaker_shape_lab_tiled_refinement_diagnostic(_origin, _shoreward_reference_direction, 5, 4, 4.0, 0.25, 0.125)
	_tiled_pattern_index = 0
	_p5_move_step = 0
	if debug_mode == 5:
		_apply_tiled_pattern()
	_build_hud()
	_refresh_hud()


func _load_vdm() -> Texture2D:
	# Retained as reference/extraction infrastructure; 2E1 never activates this path.
	if FileAccess.file_exists(WATERLINE_RAW_PATH):
		var raw_bytes := FileAccess.get_file_as_bytes(WATERLINE_RAW_PATH)
		if raw_bytes.size() != WATERLINE_RAW_BYTES:
			push_error("P7 Waterline RAW: expected %d bytes at %s, got %d" % [WATERLINE_RAW_BYTES, WATERLINE_RAW_PATH, raw_bytes.size()])
			return null
		var waterline_image: Image = Image.create_from_data(512, 512, false, Image.FORMAT_RGBAH, raw_bytes)
		if waterline_image == null:
			push_error("P7 Waterline RAW: Image.create_from_data failed")
			return null
		if waterline_image.get_width() != 512 or waterline_image.get_height() != 512 or waterline_image.get_format() != Image.FORMAT_RGBAH:
			push_error("P7 Waterline RAW: image validation failed (expected 512x512 RGBAH)")
			return null
		if not _validate_waterline_raw_image(waterline_image):
			push_error("P7 Waterline RAW: numerical sanity check failed; refusing to compensate")
			return null
		var waterline_texture := ImageTexture.create_from_image(waterline_image)
		_vdm_source = "WATERLINE RAW"
		return waterline_texture
	if ResourceLoader.exists(EXTERNAL_VDM_PATH):
		var imported := load(EXTERNAL_VDM_PATH)
		if imported is Texture2D:
			var imported_image := (imported as Texture2D).get_image()
			if imported_image != null and imported_image.get_width() == 512 and imported_image.get_height() == 256:
				var imported_format := imported_image.get_format()
				if imported_format == Image.FORMAT_RGBAH or imported_format == Image.FORMAT_RGBAF:
					_vdm_source = "EXTERNAL EXR"
					print("P7 2C2 VDM | source=EXTERNAL EXR | size=512x256 | format=%s" % imported_format)
					return imported as Texture2D
				push_warning("P7 2C2 lab: EXR import is not RGBAH/RGBAF; using procedural fallback.")
	return VDMGenerator.build()


func _build_shore_distance_texture(bathymetry: BathymetryData) -> Texture2D:
	if bathymetry.shore_signed_distance_m.size() != bathymetry.width * bathymetry.height:
		push_error("P7 2D2 lab: bathymetry shore_signed_distance_m size does not match its grid.")
		return null
	var image := Image.create(bathymetry.width, bathymetry.height, false, Image.FORMAT_RF)
	for z in bathymetry.height:
		for x in bathymetry.width:
			var index := z * bathymetry.width + x
			image.set_pixel(x, z, Color(bathymetry.shore_signed_distance_m[index], 0.0, 0.0, 1.0))
	return ImageTexture.create_from_image(image)


func _find_shallow_test_location(bathymetry: BathymetryData, camera_xz: Vector2) -> Dictionary:
	var best_score := INF
	var best_camera_distance := INF
	var best: Dictionary = {}
	for z in bathymetry.height:
		for x in bathymetry.width:
			var world_xz := bathymetry.world_origin_xz + Vector2(float(x), float(z)) * bathymetry.cell_size_m
			var sample: BathymetrySample = bathymetry.sample_bathymetry(world_xz)
			if not sample.in_bounds or not sample.is_water:
				continue
			if sample.depth_m < COASTAL_MIN_DEPTH_M or sample.depth_m > COASTAL_MAX_DEPTH_M:
				continue
			var score := absf(sample.depth_m - COASTAL_PREFERRED_DEPTH_M)
			var camera_distance := world_xz.distance_squared_to(camera_xz)
			if score < best_score or (is_equal_approx(score, best_score) and camera_distance < best_camera_distance):
				best_score = score
				best_camera_distance = camera_distance
				best = {"world_xz": world_xz, "sample": sample}
	return best


func _validate_waterline_raw_image(image: Image) -> bool:
	var min_r := INF
	var min_g := INF
	var min_b := INF
	var min_a := INF
	var max_r := -INF
	var max_g := -INF
	var max_b := -INF
	var max_a := -INF
	var invalid := false
	for y in 512:
		for x in 512:
			var pixel := image.get_pixel(x, y)
			if is_nan(pixel.r) or is_inf(pixel.r) or is_nan(pixel.g) or is_inf(pixel.g) or is_nan(pixel.b) or is_inf(pixel.b) or is_nan(pixel.a) or is_inf(pixel.a):
				invalid = true
			min_r = minf(min_r, pixel.r)
			min_g = minf(min_g, pixel.g)
			min_b = minf(min_b, pixel.b)
			min_a = minf(min_a, pixel.a)
			max_r = maxf(max_r, pixel.r)
			max_g = maxf(max_g, pixel.g)
			max_b = maxf(max_b, pixel.b)
			max_a = maxf(max_a, pixel.a)
	print("P7 WATERLINE RAW\npath=%s\nbytes=%d\nimage_format=RGBAH\nR=%.6f/%.6f\nG=%.6f/%.6f\nB=%.6f/%.6f\nA=%.6f/%.6f" % [WATERLINE_RAW_PATH, WATERLINE_RAW_BYTES, min_r, max_r, min_g, max_g, min_b, max_b, min_a, max_a])
	var ranges_ok := min_r >= -0.5 and max_r <= 1.0 and min_g >= -0.5 and max_g <= 0.1 and min_b >= -0.5 and max_b <= 0.5
	var alpha_ok := is_equal_approx(min_a, 1.0) and is_equal_approx(max_a, 1.0)
	return not invalid and ranges_ok and alpha_ok


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var next_mode := -1
		match event.keycode:
			KEY_0:
				_animation_enabled = not _animation_enabled
				if _surface != null:
					_surface.configure_breaker_shape_lab_multiphase(_shore_distance_texture, _animation_enabled)
				_refresh_hud()
				return
			KEY_LEFT:
				_phase_override = maxi(_phase_override - 1, 0) if _phase_override >= 0 else 0
				if _surface != null:
					_surface.set_breaker_shape_lab_phase_override(_phase_override)
				_refresh_hud()
				return
			KEY_RIGHT:
				_phase_override = mini(_phase_override + 1, 7) if _phase_override >= 0 else 1
				if _surface != null:
					_surface.set_breaker_shape_lab_phase_override(_phase_override)
				_refresh_hud()
				return
			KEY_SPACE:
				_phase_override = -1
				if _surface != null:
					_surface.clear_breaker_shape_lab_phase_override()
				_refresh_hud()
				return
			KEY_T:
				if debug_mode == 5 and _surface != null:
					_tiled_pattern_index = (_tiled_pattern_index + 1) % 6
					_apply_tiled_pattern()
					_refresh_hud()
				return
			KEY_R:
				return
			KEY_M:
				if debug_mode == 5 and _tiled_pattern_index == 5 and _surface != null:
					_p5_move_step = (_p5_move_step + 1) % 3
					_apply_tiled_pattern()
					_refresh_hud()
				return
			KEY_5: next_mode = 1
			KEY_6: next_mode = 2
			KEY_7: next_mode = 3
			KEY_8: next_mode = 4
			KEY_9: next_mode = 5
		if next_mode > 0:
			var previous_mode := debug_mode
			debug_mode = next_mode
			if _surface != null:
				if previous_mode != 5 and debug_mode == 5:
					_apply_tiled_pattern()
				elif previous_mode == 5 and debug_mode != 5:
					_surface.set_breaker_shape_lab_topology_mode(0)
				_surface.set_breaker_shape_lab_mode(debug_mode)
			_refresh_hud()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(14.0, 14.0)
	_hud.add_theme_font_size_override(&"font_size", 14)
	layer.add_child(_hud)


func _pattern_name() -> String:
	var names: Array[String] = ["P0 ALL COARSE", "P1 ISOLATED HIGH", "P2 3x1 HIGH", "P3 3x2 HIGH", "P4 CROSS HIGH", "P5 MOVING 3x2"]
	return names[clampi(_tiled_pattern_index, 0, 5)]


func _pattern_high_tiles() -> Array[Vector2i]:
	var tiles: Array[Vector2i] = []
	match _tiled_pattern_index:
		0: pass
		1: tiles = [Vector2i(2, 1)]
		2: tiles = [Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1)]
		3: tiles = [Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)]
		4: tiles = [Vector2i(2, 2), Vector2i(1, 2), Vector2i(3, 2), Vector2i(2, 1), Vector2i(2, 3)]
		_:
			var start_x := _p5_move_step
			tiles = [Vector2i(start_x, 1), Vector2i(start_x + 1, 1), Vector2i(start_x + 2, 1), Vector2i(start_x, 2), Vector2i(start_x + 1, 2), Vector2i(start_x + 2, 2)]
	return tiles


func _apply_tiled_pattern() -> void:
	if _surface == null:
		return
	_tiled_info = _surface.set_breaker_shape_lab_tiled_pattern(_pattern_name(), _pattern_high_tiles())


func _refresh_hud() -> void:
	if _hud == null:
		return
	var mode_names: Array[String] = ["", "BASE", "FLATTEN_ONLY", "VDM_ONLY", "COMBINED", "TILED_REFINEMENT"]
	var mode_name: String = mode_names[clampi(debug_mode, 1, 5)]
	var phase_text := "INTERPOLATED"
	var phase_freeze_text := "NO"
	var travel_text := "TRAVEL: %.1f m / %.1f s TOWARD SHORE" % [BREAKER_TRAVEL_M, BREAKER_CYCLE_SECONDS]
	var coordinate_text := "U WORLD: SHORE DISTANCE 0–12 m\nPROFILE U: OFFSHORE 0 -> SHORE 1"
	if _phase_override >= 0:
		phase_text = VDMGenerator.phase_name(_phase_override)
		phase_freeze_text = "YES"
		travel_text = "TRAVEL OFFSET: 0.0 m"
	var reference_text := ""
	if debug_mode == 5:
		coordinate_text = "U SOURCE: FIXED PARAMETRIC 12 m\nBASE_S == WORLD REFERENCE_S"
		reference_text = "\nDIRECTION: FIXED SHOREWARD LAB FRAME\nCOASTAL SHAPE INPUT: NONE\nBASE OCEAN: REMOVED INSIDE AUTHORITY\nDIAGNOSTIC: TILED RUNTIME LOCAL REFINEMENT\nT: NEXT PATTERN   M: MOVE P5 REGION\n%s\n" % _tiled_hud_text()
	_hud.text = "PHASE 2E1 — MULTI-PHASE BREAKER\nSHAPE SOURCE: OWN MULTI-PHASE VDM\nMODE: %s\nCURRENT PHASE: %s\nPHASE FREEZE: %s\nANIMATION: %s (0)\nLEFT/RIGHT: FREEZE PHASE   SPACE: RESUME\n%s\n+S / +R: TOWARD SHORE\n%s%s\nPROFILE: NON-MONOTONIC PLUNGE\nTEST DEPTH: %.2f m\nTEST XZ: (%.2f, %.2f)\nAUTHORITY: DEPTH + LATERAL EDGE + VDM A\nCAMERA AUTO-PLACED: YES\nwidth: %.1f m   length: %.1f m\nflatten: %.2f   ATLAS: 256x2048 RGBAH" % [mode_name, phase_text, phase_freeze_text, "ON" if _animation_enabled else "OFF", travel_text, coordinate_text, reference_text, _test_depth_m, _origin.x, _origin.y, WAVEFRONT_WIDTH_M, BREAKER_LENGTH_M, FLATTEN_STRENGTH]


func _tiled_hud_text() -> String:
	var info := _tiled_info
	var active_masks: Array = info.get("active_high_mask_variants", [])
	return "PATTERN: %s\nTILE GRID: %d × %d   TILE SIZE: %.1f m\nSPACING COARSE/HIGH: %.3f / %.3f m\nLOGICAL TILE COUNT: %d\nCOARSE TILE COUNT: %d\nHIGH TILE COUNT: %d\nTOTAL ACTIVE TRIS: %d\nACTIVE HIGH MASKS N/E/S/W: %s\nMESH ASSIGNMENTS LAST CHANGE: %d\nMESHES GENERATED SINCE STARTUP: %d\nMESHES GENERATED THIS FRAME: %d\nARRAYMESH REBUILDS THIS FRAME: %d\nMESH INSTANCES: %d\nSURFACES / DRAW CALLS: %d / %d\nPREBUILT MESHES: %d (1 coarse + 16 high)\nMANIFOLD VARIANTS: %s   OVERLAP: %s" % [_pattern_name(), int(info.get("grid_width", 0)), int(info.get("grid_height", 0)), float(info.get("tile_size_m", 0.0)), float(info.get("coarse_spacing_m", 0.0)), float(info.get("high_spacing_m", 0.0)), int(info.get("logical_tile_count", 0)), int(info.get("coarse_tile_count", 0)), int(info.get("high_tile_count", 0)), int(info.get("total_triangles", 0)), active_masks, int(info.get("mesh_assignments_last_transition", 0)), int(info.get("meshes_generated_since_startup", 0)), int(info.get("meshes_generated_this_frame", 0)), int(info.get("arraymesh_rebuilds_this_frame", 0)), int(info.get("mesh_instance_count", 0)), int(info.get("surface_count", 0)), int(info.get("draw_call_count_approx", info.get("surface_count", 0))), int(info.get("prebuilt_mesh_count", 0)), "YES" if bool(info.get("all_variants_manifold", false)) else "NO", "NONE" if bool(info.get("no_overlapping_surface", false)) else "YES"]


func _topology_hud_text() -> String:
	match _topology_mode:
		0:
			var t0_info: Dictionary = _topology_info.get("t0", {})
			return "TOPOLOGY TEST: T0 PRODUCTION_CLIPMAP\nGRID SPACING: L0 %.4f m\nGRID EXTENT: L0 %.2f × %.2f m (%d × %d cells)\nGRID VERTICES: %d (all levels)\nGRID TRIANGLES: %d (all levels)" % [float(t0_info.get("spacing_m", 0.0)), float(t0_info.get("cells_per_side", 0)) * float(t0_info.get("spacing_m", 0.0)), float(t0_info.get("cells_per_side", 0)) * float(t0_info.get("spacing_m", 0.0)), int(t0_info.get("cells_per_side", 0)), int(t0_info.get("cells_per_side", 0)), int(t0_info.get("vertices", 0)), int(t0_info.get("triangles", 0))]
		1:
			var t1_info: Dictionary = _topology_info.get("t1", {})
			return "TOPOLOGY TEST: T1 ALIGNED_PRODUCTION_DENSITY\nGRID SPACING: %.4f m\nGRID EXTENT: S %.2f m × V %.2f m\nGRID CELLS: S %d × V %d\nGRID VERTICES: %d\nGRID TRIANGLES: %d" % [float(t1_info.get("spacing_m", 0.0)), float(t1_info.get("s_extent_m", 0.0)), float(t1_info.get("v_extent_m", 0.0)), int(t1_info.get("s_cells", 0)), int(t1_info.get("v_cells", 0)), int(t1_info.get("vertices", 0)), int(t1_info.get("triangles", 0))]
		2:
			var t2_info: Dictionary = _topology_info.get("t2", {})
			return "TOPOLOGY TEST: T2 ALIGNED_HALF_DENSITY\nGRID SPACING: %.4f m\nGRID EXTENT: S %.2f m × V %.2f m\nGRID CELLS: S %d × V %d\nGRID VERTICES: %d\nGRID TRIANGLES: %d" % [float(t2_info.get("spacing_m", 0.0)), float(t2_info.get("s_extent_m", 0.0)), float(t2_info.get("v_extent_m", 0.0)), int(t2_info.get("s_cells", 0)), int(t2_info.get("v_cells", 0)), int(t2_info.get("vertices", 0)), int(t2_info.get("triangles", 0))]
		_:
			var t3_info: Dictionary = _topology_info.get("t3", {})
			return "TOPOLOGY TEST: T3 ALIGNED_DENSE_4X\nGRID SPACING: %.4f m\nGRID EXTENT: S %.2f m × V %.2f m\nGRID CELLS: S %d × V %d\nGRID VERTICES: %d\nGRID TRIANGLES: %d" % [float(t3_info.get("spacing_m", 0.0)), float(t3_info.get("s_extent_m", 0.0)), float(t3_info.get("v_extent_m", 0.0)), int(t3_info.get("s_cells", 0)), int(t3_info.get("v_cells", 0)), int(t3_info.get("vertices", 0)), int(t3_info.get("triangles", 0))]


func _refinement_hud_text() -> String:
	var state_name := "R0 ALL_COARSE" if _refinement_mode == 0 else "R1 CORE_2_TO_1"
	var info: Dictionary = _refinement_info.get("r0" if _refinement_mode == 0 else "r1", {})
	var edge_summary: Dictionary = info.get("edge_summary", {})
	return "REFINEMENT TEST: %s\nOUTER EXTENT: S %.2f m × V %.2f m\nCORE SIZE: S %.2f m × V %.2f m\nOUTER SPACING: %.3f m\nCORE SPACING: %.3f m\nOUTER TRIANGLES: %d\nCORE TRIANGLES: %d\nSTITCH TRIANGLES: %d\nTOTAL TRIANGLES: %d\nVERTICES: %d\nMESH COUNT: %d\nDRAW SURFACE COUNT: %d\nNON-MANIFOLD EDGES: %d" % [state_name, float(info.get("outer_s_extent_m", 0.0)), float(info.get("outer_v_extent_m", 0.0)), float(info.get("core_s_extent_m", 0.0)), float(info.get("core_v_extent_m", 0.0)), float(info.get("outer_spacing_m", 0.0)), float(info.get("core_spacing_m", 0.0)), int(info.get("outer_triangles", 0)), int(info.get("core_triangles", 0)), int(info.get("stitch_triangles", 0)), int(info.get("triangles", 0)), int(info.get("vertices", 0)), int(_refinement_info.get("mesh_count", 0)), int(info.get("surface_count", 0)), int(edge_summary.get("non_manifold_edges", 0))]
