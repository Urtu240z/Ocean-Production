extends Node3D
## P5.6 validation fixture. All diagnostic shader edits are made in memory.
## The production defaults and physical FFT inputs remain unchanged.

const BASE_SHADER_PATH := "res://addons/ocean/shaders/ocean_surface.gdshader"
const BASE_OUTER_WIDTH_M := 48.0
const BASE_CELLS := 192
const LEVEL_COUNT := 10

enum VisualMode {
	SURFACE,
	UNSHADED,
	LOD_COLORS,
}

enum FilterMode {
	BASELINE,
	LOWPASS_HALF_SPACING,
	LOWPASS_SPACING,
	STRONG_MACRO,
	Y_ONLY,
	XYZ,
	XZ_AGGRESSIVE,
}

const FILTER_NAMES := ["BASELINE", "LOWPASS 0.5xSPACING", "LOWPASS 1.0xSPACING", "STRONG MACRO", "Y-ONLY", "XYZ", "XZ-AGGRESSIVE"]

var _ocean: Ocean
var _quality: Resource
var _surface: Node
var _material: ShaderMaterial
var _status: Label
var _case_id := "BASELINE"
var _visual_mode := VisualMode.UNSHADED
var _filter_mode := FilterMode.BASELINE
var _xz_scale := 1.0
var _frozen := false
var _wireframe := false
var _detail_enabled := false
var _sspr_enabled := false
var _base_variant_source := ""


func _ready() -> void:
	call_deferred(&"_initialize_diagnostic")


func _initialize_diagnostic() -> void:
	_ocean = get_node_or_null(^"P0OpenOcean/Ocean") as Ocean
	if _ocean == null:
		push_error("P5.6 diagnostic: Production Ocean node is missing.")
		return
	_ocean.coastal = false
	_ocean.optics = false
	_ocean.reflections = false
	_ocean.crest_foam = false
	_ocean.surface_foam = false
	_ocean.surface_detail = false
	_quality = _ocean.quality_profile
	if _quality == null:
		push_error("P5.6 diagnostic: quality profile is missing.")
		return
	var camera := get_node_or_null(^"P0OpenOcean/FreeCamera") as Camera3D
	if camera != null:
		camera.global_position = Vector3(0.0, 3.0, 80.0)
		camera.rotation_degrees = Vector3(-18.0, 0.0, 0.0)
	var args := OS.get_cmdline_user_args()
	if "--p5-6-lod" in args or "--p5-6b-lod" in args:
		_visual_mode = VisualMode.LOD_COLORS
	if "--p5-6b-unshaded" in args:
		_visual_mode = VisualMode.UNSHADED
	if "--p5-6b-wireframe" in args:
		_wireframe = true
	if "--p5-6b-lp-half" in args:
		_filter_mode = FilterMode.LOWPASS_HALF_SPACING
	elif "--p5-6b-lp-spacing" in args:
		_filter_mode = FilterMode.LOWPASS_SPACING
	elif "--p5-6b-macro" in args:
		_filter_mode = FilterMode.STRONG_MACRO
	elif "--p5-6b-y-only" in args:
		_filter_mode = FilterMode.Y_ONLY
	elif "--p5-6b-xyz" in args:
		_filter_mode = FilterMode.XYZ
	elif "--p5-6b-xz-aggressive" in args:
		_filter_mode = FilterMode.XZ_AGGRESSIVE
	if "--p5-6b-detail" in args:
		_detail_enabled = true
		_ocean.surface_detail = true
	if "--p5-6b-sspr" in args:
		_sspr_enabled = true
		_ocean.reflections = true
	for _frame in 8:
		await get_tree().process_frame
	_apply_diagnostic_shader()
	_freeze_fft()
	_add_overlay()
	_apply_visual_state()
	_print_case_report()
	if "--p5-6-batch" in OS.get_cmdline_user_args():
		call_deferred(&"_run_batch")
	elif "--p5-6-xz-batch" in OS.get_cmdline_user_args():
		call_deferred(&"_run_xz_batch")


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).keycode
	match key:
		KEY_F1: _switch_case("BASELINE", BASE_CELLS, BASE_OUTER_WIDTH_M / float(BASE_CELLS), 0)
		KEY_F2: _switch_case("CHECKERBOARD", BASE_CELLS, BASE_OUTER_WIDTH_M / float(BASE_CELLS), 1)
		KEY_F3: _switch_case("DENSITY_MODERATE", 224, BASE_OUTER_WIDTH_M / 224.0, 0)
		KEY_F4: _switch_case("DENSITY_HIGH", 256, BASE_OUTER_WIDTH_M / 256.0, 0)
		KEY_F5: _switch_case("CHECKERBOARD_PLUS_MODERATE", 224, BASE_OUTER_WIDTH_M / 224.0, 1)
		KEY_F6: _set_xz_scale(1.0)
		KEY_F7: _set_xz_scale(0.75)
		KEY_F8: _set_xz_scale(0.50)
		KEY_F9: _set_xz_scale(0.0)
		KEY_L: _set_visual_mode(VisualMode.LOD_COLORS if _visual_mode != VisualMode.LOD_COLORS else VisualMode.UNSHADED)
		KEY_U: _set_visual_mode(VisualMode.UNSHADED)
		KEY_S: _set_visual_mode(VisualMode.SURFACE)
		KEY_1: _set_filter_mode(FilterMode.BASELINE)
		KEY_2: _set_filter_mode(FilterMode.LOWPASS_HALF_SPACING)
		KEY_3: _set_filter_mode(FilterMode.LOWPASS_SPACING)
		KEY_4: _set_filter_mode(FilterMode.STRONG_MACRO)
		KEY_5: _set_filter_mode(FilterMode.Y_ONLY)
		KEY_6: _set_filter_mode(FilterMode.XYZ)
		KEY_7: _set_filter_mode(FilterMode.XZ_AGGRESSIVE)
		KEY_W: _toggle_wireframe()
		KEY_D: _toggle_surface_detail()
		KEY_R: _toggle_sspr()
		KEY_SPACE: _toggle_freeze()
		KEY_ESCAPE: get_tree().quit()


func _switch_case(case_name: String, cells: int, spacing: float, diagonal_mode: int) -> void:
	if _ocean == null or _quality == null:
		return
	_case_id = case_name
	_ocean.shutdown()
	_quality.cells_per_side = cells
	_quality.base_spacing_m = spacing
	_quality.validation_diagonal_mode = diagonal_mode
	_ocean.initialize()
	_base_variant_source = ""
	for _frame in 8:
		await get_tree().process_frame
	_apply_diagnostic_shader()
	_freeze_fft()
	_apply_visual_state()
	_print_case_report()


func _run_batch() -> void:
	await _capture_case("BASELINE")
	await _switch_case("CHECKERBOARD", BASE_CELLS, BASE_OUTER_WIDTH_M / float(BASE_CELLS), 1)
	await _capture_case("CHECKERBOARD")
	await _switch_case("DENSITY_MODERATE", 224, BASE_OUTER_WIDTH_M / 224.0, 0)
	await _capture_case("DENSITY_MODERATE")
	await _switch_case("DENSITY_HIGH", 256, BASE_OUTER_WIDTH_M / 256.0, 0)
	await _capture_case("DENSITY_HIGH")
	await _switch_case("CHECKERBOARD_PLUS_MODERATE", 224, BASE_OUTER_WIDTH_M / 224.0, 1)
	await _capture_case("CHECKERBOARD_PLUS_MODERATE")
	for scale in [1.0, 0.75, 0.50, 0.0]:
		_set_xz_scale(scale)
	print("P5_6_BATCH_COMPLETE")
	get_tree().quit()


func _run_xz_batch() -> void:
	for pair in [["XZ_100", 1.0], ["XZ_75", 0.75], ["XZ_50", 0.50], ["XZ_0", 0.0]]:
		_set_xz_scale(pair[1])
		await _capture_case(pair[0])
	print("P5_6_XZ_BATCH_COMPLETE")
	get_tree().quit()


func _capture_case(case_name: String) -> void:
	await get_tree().create_timer(0.25).timeout
	var image := get_viewport().get_texture().get_image()
	if image != null:
		var path := "res://validation/captures/p5_6_%s.png" % case_name.to_lower()
		var error := image.save_png(path)
		print("P5_6_CAPTURE case=%s path=%s error=%s" % [case_name, path, error])


func _apply_diagnostic_shader() -> void:
	_surface = _ocean.get("_open_ocean").get_node_or_null(^"OceanClipmapSurface")
	if _surface == null:
		push_error("P5.6 diagnostic: OceanClipmapSurface was not created.")
		return
	_material = _surface.get("_material") as ShaderMaterial
	if _material == null:
		push_error("P5.6 diagnostic: surface material is missing.")
		return
	if _base_variant_source.is_empty():
		_base_variant_source = _material.shader.code if _material.shader != null else FileAccess.get_file_as_string(BASE_SHADER_PATH)
	var source := _base_variant_source
	var render_mode_marker := "render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;"
	if _wireframe and _visual_mode != VisualMode.SURFACE:
		source = source.replace(render_mode_marker, "render_mode wireframe, unshaded, cull_disabled;")
	elif _wireframe:
		source = source.replace(render_mode_marker, "render_mode wireframe, cull_disabled, diffuse_burley, specular_schlick_ggx;")
	elif _visual_mode != VisualMode.SURFACE:
		source = source.replace(render_mode_marker, "render_mode unshaded, cull_disabled;")
	var uniform_marker := "uniform int debug_view = 0;"
	if not source.contains(uniform_marker):
		push_error("P5.6 diagnostic: base shader uniform marker changed.")
		return
	source = source.replace(uniform_marker, uniform_marker + "\nuniform int p5_6_visual_mode = 0;\nuniform int p5_6_filter_mode = 0;\nuniform float p5_6_xz_scale = 1.0;\ninstance uniform float p5_6_lod_level = 0.0;\ninstance uniform float p5_6_spacing_m = 0.25;\nvec3 p5_6_lod_color(float level) {\n\tif (level < 0.5) return vec3(0.10, 0.75, 1.00);\n\tif (level < 1.5) return vec3(0.15, 1.00, 0.35);\n\tif (level < 2.5) return vec3(0.95, 1.00, 0.15);\n\tif (level < 3.5) return vec3(1.00, 0.55, 0.10);\n\tif (level < 4.5) return vec3(1.00, 0.15, 0.15);\n\tif (level < 5.5) return vec3(0.90, 0.15, 1.00);\n\treturn vec3(0.35, 0.15, 0.85);\n}")
	var filter_marker := "void vertex() {"
	if not source.contains(filter_marker):
		push_error("P5.6B diagnostic: vertex marker changed.")
		return
	var filter_functions := """
float p5_6_lod_filter_weight(float spacing_m) {
	float samples_per_min_wave = 16.0 / max(spacing_m, 0.001);
	return 1.0 - smoothstep(2.0, 8.0, samples_per_min_wave);
}

vec3 p5_6_long_4tap(vec2 sample_xz, float radius_m) {
	vec2 radius_x = vec2(radius_m, 0.0);
	vec2 radius_z = vec2(0.0, radius_m);
	vec3 p0 = texture(displacement_long, world_uv(sample_xz + radius_x, domain_long_m)).xyz;
	vec3 p1 = texture(displacement_long, world_uv(sample_xz - radius_x, domain_long_m)).xyz;
	vec3 p2 = texture(displacement_long, world_uv(sample_xz + radius_z, domain_long_m)).xyz;
	vec3 p3 = texture(displacement_long, world_uv(sample_xz - radius_z, domain_long_m)).xyz;
	return (p0 + p1 + p2 + p3) * 0.25;
}

vec3 p5_6_long_5tap(vec2 sample_xz, float radius_m) {
	vec2 radius_x = vec2(radius_m, 0.0);
	vec2 radius_z = vec2(0.0, radius_m);
	vec3 center = texture(displacement_long, world_uv(sample_xz, domain_long_m)).xyz;
	vec3 p0 = texture(displacement_long, world_uv(sample_xz + radius_x, domain_long_m)).xyz;
	vec3 p1 = texture(displacement_long, world_uv(sample_xz - radius_x, domain_long_m)).xyz;
	vec3 p2 = texture(displacement_long, world_uv(sample_xz + radius_z, domain_long_m)).xyz;
	vec3 p3 = texture(displacement_long, world_uv(sample_xz - radius_z, domain_long_m)).xyz;
	return (center + p0 + p1 + p2 + p3) * 0.2;
}

vec3 p5_6_long_y_only(vec2 sample_xz, float radius_m) {
	vec2 radius_x = vec2(radius_m, 0.0);
	vec2 radius_z = vec2(0.0, radius_m);
	vec3 center = texture(displacement_long, world_uv(sample_xz, domain_long_m)).xyz;
	vec3 p0 = texture(displacement_long, world_uv(sample_xz + radius_x, domain_long_m)).xyz;
	vec3 p1 = texture(displacement_long, world_uv(sample_xz - radius_x, domain_long_m)).xyz;
	vec3 p2 = texture(displacement_long, world_uv(sample_xz + radius_z, domain_long_m)).xyz;
	vec3 p3 = texture(displacement_long, world_uv(sample_xz - radius_z, domain_long_m)).xyz;
	float filtered_y = (center.y + p0.y + p1.y + p2.y + p3.y) * 0.2;
	return vec3(center.x, filtered_y, center.z);
}

vec3 p5_6_long_geometry(vec2 sample_xz) {
	float weight = p5_6_lod_filter_weight(p5_6_spacing_m);
	float radius_m = p5_6_spacing_m * weight;
	if (p5_6_filter_mode == 1) return p5_6_long_4tap(sample_xz, p5_6_spacing_m * 0.5 * weight);
	if (p5_6_filter_mode == 2) return p5_6_long_4tap(sample_xz, radius_m);
	if (p5_6_filter_mode == 3) return p5_6_long_5tap(sample_xz, max(p5_6_spacing_m * 4.0, 8.0) * weight);
	if (p5_6_filter_mode == 4) return p5_6_long_y_only(sample_xz, radius_m);
	if (p5_6_filter_mode == 6) {
		vec3 filtered_y = p5_6_long_4tap(sample_xz, radius_m);
		vec3 filtered_xz = p5_6_long_4tap(sample_xz, p5_6_spacing_m * 2.0 * weight);
		return vec3(filtered_xz.x, filtered_y.y, filtered_xz.z);
	}
	return p5_6_long_4tap(sample_xz, radius_m);
}
"""
	source = source.replace(filter_marker, filter_functions + "\n" + filter_marker)
	var displacement_marker := "\tsurface_foam_displacement_xz = surface_displacement.xz;"
	if not source.contains(displacement_marker):
		push_error("P5.6 diagnostic: displacement marker changed.")
		return
	var long_sample_marker := "\tvec3 long_displacement = texture(displacement_long, world_uv(world_xz, domain_long_m)).xyz;"
	if not source.contains(long_sample_marker):
		push_error("P5.6B diagnostic: LONG sample marker changed.")
		return
	source = source.replace(long_sample_marker, "\tvec3 long_displacement = p5_6_filter_mode == 0 || coastal_enabled ? texture(displacement_long, world_uv(world_xz, domain_long_m)).xyz : p5_6_long_geometry(world_xz);")
	source = source.replace(displacement_marker, "\tsurface_displacement.xz *= p5_6_xz_scale;\n" + displacement_marker)
	var fragment_marker := "\tif (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;"
	if not source.contains(fragment_marker):
		push_error("P5.6 diagnostic: fragment marker changed.")
		return
	source = source.replace(fragment_marker, fragment_marker + "\n\tif (p5_6_visual_mode == 1) { ALBEDO = vec3(0.38); EMISSION = vec3(0.38); ROUGHNESS = 1.0; SPECULAR = 0.0; METALLIC = 0.0; }\n\tif (p5_6_visual_mode == 2) { ALBEDO = p5_6_lod_color(p5_6_lod_level); EMISSION = ALBEDO; ROUGHNESS = 1.0; SPECULAR = 0.0; METALLIC = 0.0; }")
	var diagnostic_shader := Shader.new()
	diagnostic_shader.code = source
	_material.shader = diagnostic_shader
	var levels: Array = _surface.get("_levels")
	for index in levels.size():
		levels[index].set_instance_shader_parameter(&"p5_6_lod_level", float(index))
		levels[index].set_instance_shader_parameter(&"p5_6_spacing_m", float(levels[index].get_meta("clipmap_spacing_m", _quality.base_spacing_m * pow(2.0, index))))


func _apply_visual_state() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"p5_6_visual_mode", _visual_mode)
	_material.set_shader_parameter(&"p5_6_filter_mode", _filter_mode)
	_material.set_shader_parameter(&"p5_6_xz_scale", _xz_scale)
	_update_overlay()


func _set_filter_mode(value: int) -> void:
	_filter_mode = clampi(value, FilterMode.BASELINE, FilterMode.XZ_AGGRESSIVE)
	_apply_visual_state()
	_print_filter_report()


func _set_visual_mode(value: int) -> void:
	_visual_mode = value
	_apply_diagnostic_shader()
	_apply_visual_state()


func _toggle_wireframe() -> void:
	_wireframe = not _wireframe
	_apply_diagnostic_shader()
	_apply_visual_state()


func _toggle_surface_detail() -> void:
	_detail_enabled = not _detail_enabled
	_ocean.surface_detail = _detail_enabled
	call_deferred(&"_restore_diagnostic_after_variant")


func _toggle_sspr() -> void:
	_sspr_enabled = not _sspr_enabled
	_ocean.reflections = _sspr_enabled
	call_deferred(&"_restore_diagnostic_after_variant")


func _restore_diagnostic_after_variant() -> void:
	await get_tree().process_frame
	_base_variant_source = ""
	_apply_diagnostic_shader()
	_apply_visual_state()


func _set_xz_scale(value: float) -> void:
	_xz_scale = value
	_apply_visual_state()
	print("P5_6_XZ_DIAGNOSTIC case=%s xz_scale=%.2f y_scale=1.00" % [_case_id, _xz_scale])


func _toggle_freeze() -> void:
	_frozen = not _frozen
	if _ocean != null and _ocean.get("_open_ocean") != null:
		_ocean.get("_open_ocean").set_process(not _frozen)
	_update_overlay()


func _freeze_fft() -> void:
	_frozen = true
	if _ocean != null and _ocean.get("_open_ocean") != null:
		_ocean.get("_open_ocean").set_process(false)


func _print_filter_report() -> void:
	var samples := 1
	if _filter_mode == FilterMode.STRONG_MACRO or _filter_mode == FilterMode.Y_ONLY:
		samples = 5
	elif _filter_mode == FilterMode.XZ_AGGRESSIVE:
		samples = 8
	elif _filter_mode != FilterMode.BASELINE:
		samples = 4
	print("P5_6B_FILTER mode=%s long_fetches_per_vertex=%d lod_weight_from_samples=16/spacing smoothstep(2,8)" % [FILTER_NAMES[_filter_mode], samples])


func _print_case_report() -> void:
	if _surface == null:
		return
	var levels: Array = _surface.get("_levels")
	var vertex_count := 0
	var triangle_count := 0
	var invalid_triangle_count := 0
	for level in levels:
		var arrays: Array = level.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		vertex_count += vertices.size()
		triangle_count += int(indices.size() / 3)
		for triangle_base in range(0, indices.size(), 3):
			var a: Vector3 = vertices[indices[triangle_base]]
			var b: Vector3 = vertices[indices[triangle_base + 1]]
			var c: Vector3 = vertices[indices[triangle_base + 2]]
			if (b - a).cross(c - a).y <= 0.00000001:
				invalid_triangle_count += 1
	print("P5_6_CASE case=%s cells=%d spacing=%.9f levels=%d vertices=%d triangles=%d invalid_triangles=%d diagonal=%s frozen=%s" % [
		_case_id, _quality.cells_per_side, _quality.base_spacing_m, levels.size(), vertex_count, triangle_count,
		invalid_triangle_count, "CHECKERBOARD" if int(_quality.validation_diagonal_mode) == 1 else "FIXED", "YES" if _frozen else "NO",
	])
	_print_filter_report()
	_update_overlay()


func _add_overlay() -> void:
	_status = Label.new()
	_status.position = Vector2(24.0, 24.0)
	_status.add_theme_color_override(&"font_color", Color(1.0, 1.0, 1.0))
	_status.add_theme_color_override(&"font_shadow_color", Color(0.0, 0.0, 0.0, 0.9))
	_status.add_theme_constant_override(&"shadow_offset_x", 2)
	_status.add_theme_constant_override(&"shadow_offset_y", 2)
	add_child(_status)
	_update_overlay()


func _camera_probe() -> Dictionary:
	var camera := get_node_or_null(^"P0OpenOcean/FreeCamera") as Camera3D
	if camera == null or _surface == null:
		return {"distance": -1.0, "radius": -1.0, "level": -1, "spacing": 0.0}
	var forward := -camera.global_transform.basis.z
	if abs(forward.y) < 0.0001:
		return {"distance": -1.0, "radius": -1.0, "level": -1, "spacing": 0.0}
	var distance_to_sea := (_ocean.sea_level - camera.global_position.y) / forward.y
	if distance_to_sea <= 0.0:
		return {"distance": -1.0, "radius": -1.0, "level": -1, "spacing": 0.0}
	var probe := camera.global_position + forward * distance_to_sea
	var radius := Vector2(probe.x, probe.z).distance_to(Vector2(_surface.global_position.x, _surface.global_position.z))
	var level := 0
	var outer_half := BASE_OUTER_WIDTH_M * 0.5
	while level < LEVEL_COUNT - 1 and radius > outer_half:
		level += 1
		outer_half *= 2.0
	return {"distance": distance_to_sea, "radius": radius, "level": level, "spacing": _quality.base_spacing_m * pow(2.0, level)}


func _update_overlay() -> void:
	if _status == null:
		return
	var visual: String = ["SURFACE", "UNSHADED", "LOD COLORS"][_visual_mode]
	var probe := _camera_probe()
	var probe_text := "probe n/a"
	if float(probe.distance) > 0.0:
		probe_text = "camera→sea %.1fm | target r %.1fm ≈ L%d / %.2fm" % [probe.distance, probe.radius, probe.level, probe.spacing]
	_status.text = "P5.6 GEOMETRY / ANTI-FACETING (validation only)\n" + \
		"%s | %s | cells %d | base spacing %.5f m | XZ %.0f%% | %s\n" % [_case_id, FILTER_NAMES[_filter_mode], _quality.cells_per_side, _quality.base_spacing_m, _xz_scale * 100.0, visual] + \
		"%s | wireframe %s | Detail %s | SSPR %s\n" % [probe_text, "ON" if _wireframe else "OFF", "ON" if _detail_enabled else "OFF", "ON" if _sspr_enabled else "OFF"] + \
		"1 baseline  2 LP .5xS  3 LP 1xS  4 macro  5 Y-only  6 XYZ  7 XZ-aggressive\n" + \
		"F1/F2/F3/F4 mesh cases  W wire  L LOD colors  U unshaded  S shaded\n" + \
		"D detail  R SSPR  F6/F7/F8/F9 XZ 100/75/50/0%%  SPACE freeze  ESC quit\n" + \
		"LONG geometry only; FFT and fragment normals remain unchanged | FFT: %s" % ("FROZEN" if _frozen else "LIVE")
