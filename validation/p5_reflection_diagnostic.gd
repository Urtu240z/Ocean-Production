extends Node3D
## Temporary P5 fixture. It derives a diagnostic-only copy of the P0-P3 base
## shader in memory; no addon API or production material resource is changed.

const BASE_SHADER_PATH := "res://addons/ocean/shaders/ocean_surface.gdshader"

enum Mode {
	FINAL_NORMAL,
	SSPR_RAW_RGB,
	SSPR_CONFIDENCE,
	IBL_FALLBACK_ONLY,
	SSPR_CONTRIBUTION_ONLY,
	FINAL_COMPOSITION,
}

enum BaseProbe {
	NONE,
	ALBEDO,
	NORMAL,
	ROUGHNESS,
	SPECULAR,
}

var _mode := Mode.FINAL_NORMAL
var _probe := BaseProbe.NONE
var _surface: Node
var _material: ShaderMaterial
var _sun: DirectionalLight3D
var _status: Label


func _ready() -> void:
	call_deferred(&"_initialize_diagnostic")


func _initialize_diagnostic() -> void:
	var ocean := get_node_or_null(^"P0OpenOcean/Ocean") as Ocean
	if ocean == null:
		push_error("P5 diagnostic: Production Ocean node is missing.")
		return
	# This fixture is explicitly the no-SSPR, no-P4 baseline.
	ocean.optics = false
	await get_tree().process_frame
	_surface = ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface")
	if _surface == null:
		push_error("P5 diagnostic: OceanClipmapSurface was not created.")
		return
	_material = _surface.get("_material") as ShaderMaterial
	if _material == null:
		push_error("P5 diagnostic: surface material is missing.")
		return
	var source := FileAccess.get_file_as_string(BASE_SHADER_PATH)
	if source.is_empty():
		push_error("P5 diagnostic: could not read the base surface shader.")
		return
	var marker := "uniform int debug_view = 0;"
	if not source.contains(marker):
		push_error("P5 diagnostic: base shader uniform marker changed.")
		return
	source = source.replace(marker, marker + "\nuniform int p5_diagnostic_mode = 0;\nuniform int p5_base_probe = 0;")
	marker = "if (debug_view == 1) ALBEDO = NORMAL * 0.5 + 0.5;"
	if not source.contains(marker):
		push_error("P5 diagnostic: base shader fragment marker changed.")
		return
	source = source.replace(marker, _diagnostic_fragment())
	var diagnostic_shader := Shader.new()
	diagnostic_shader.code = source
	_material.shader = diagnostic_shader
	_sun = get_node_or_null(^"P0OpenOcean/Sun") as DirectionalLight3D
	_add_reflective_geometry()
	_add_overlay()
	_apply_mode()
	_print_baseline_report()


func _diagnostic_fragment() -> String:
	return '''
	// P5 validation-only modes. Production has no SSPR resource yet, therefore
	// raw RGB, confidence and contribution are the defined zero/miss values.
	if (p5_diagnostic_mode == 1 || p5_diagnostic_mode == 2 || p5_diagnostic_mode == 4) {
		ALBEDO = vec3(0.0);
		EMISSION = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
		METALLIC = 0.0;
	} else if (p5_diagnostic_mode == 3) {
		// Preserve normal, roughness and specular. With the scene sun disabled by
		// the fixture, this isolates the environment/PBR reflection fallback.
		ALBEDO = vec3(0.0);
		EMISSION = vec3(0.0);
		METALLIC = 0.0;
	}
	if (p5_base_probe == 1) {
		EMISSION = ALBEDO;
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (p5_base_probe == 2) {
		EMISSION = NORMAL * 0.5 + 0.5;
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (p5_base_probe == 3) {
		EMISSION = vec3(ROUGHNESS);
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (p5_base_probe == 4) {
		EMISSION = vec3(SPECULAR);
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (debug_view == 1) {
		ALBEDO = NORMAL * 0.5 + 0.5;
	}
'''


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_0: _set_mode(Mode.FINAL_NORMAL)
		KEY_1: _set_mode(Mode.SSPR_RAW_RGB)
		KEY_2: _set_mode(Mode.SSPR_CONFIDENCE)
		KEY_3: _set_mode(Mode.IBL_FALLBACK_ONLY)
		KEY_4: _set_mode(Mode.SSPR_CONTRIBUTION_ONLY)
		KEY_5: _set_mode(Mode.FINAL_COMPOSITION)
		KEY_F7: _set_probe(BaseProbe.ALBEDO)
		KEY_F8: _set_probe(BaseProbe.NORMAL)
		KEY_F9: _set_probe(BaseProbe.ROUGHNESS)
		KEY_F10: _set_probe(BaseProbe.SPECULAR)
		KEY_F6: _set_probe(BaseProbe.NONE)


func _set_mode(value: Mode) -> void:
	_mode = value
	_probe = BaseProbe.NONE
	_apply_mode()


func _set_probe(value: BaseProbe) -> void:
	_probe = value
	_apply_mode()


func _apply_mode() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"p5_diagnostic_mode", _mode)
	_material.set_shader_parameter(&"p5_base_probe", _probe)
	if _sun != null:
		_sun.visible = _mode != Mode.IBL_FALLBACK_ONLY
	if _status != null:
		_status.text = "P5 REFLECTION DIAGNOSTIC (validation only)\n" + _mode_name() + "\n" + _probe_name() + "\n\n0-5 modes | F6 clear probe | F7 Albedo | F8 Normal | F9 Roughness | F10 Specular\nMode 3 disables Sun and isolates PBR environment fallback."
	print("P5_DIAGNOSTIC mode=%s probe=%s sspr_present=NO" % [_mode_name(), _probe_name()])


func _mode_name() -> String:
	return ["MODE 0 — FINAL NORMAL", "MODE 1 — SSPR RAW RGB", "MODE 2 — SSPR CONFIDENCE", "MODE 3 — IBL/FALLBACK ONLY", "MODE 4 — SSPR CONTRIBUTION ONLY", "MODE 5 — FINAL COMPOSITION"][_mode]


func _probe_name() -> String:
	return ["Base PBR probe: none", "Base PBR probe: ALBEDO", "Base PBR probe: NORMAL", "Base PBR probe: ROUGHNESS", "Base PBR probe: SPECULAR"][_probe]


func _print_baseline_report() -> void:
	var world := get_node_or_null(^"P0OpenOcean/WorldEnvironment") as WorldEnvironment
	var environment := world.environment if world != null else null
	print("P5_DIAGNOSTIC_BASE sspr=NO optics=NO")
	print("P5_DIAGNOSTIC_PBR base_roughness=0.08 base_specular=0.9 fresnel=Godot Schlick GGX")
	print("P5_DIAGNOSTIC_ENV sky=%s reflected_light_source=%s ambient_sky=%.2f" % [
		"YES" if environment != null and environment.sky != null else "NO",
		str(environment.reflected_light_source) if environment != null else "NONE",
		environment.ambient_light_sky_contribution if environment != null else 0.0,
	])


func _add_reflective_geometry() -> void:
	_add_box(Vector3(-3.0, 2.5, -12.0), Vector3(2.0, 5.0, 2.0), Color(0.95, 0.20, 0.08))
	_add_box(Vector3(3.0, 1.5, -18.0), Vector3(3.5, 3.0, 3.5), Color(0.08, 0.50, 0.95))


func _add_box(position_m: Vector3, size_m: Vector3, color: Color) -> void:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size_m
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.2
	material.roughness = 0.25
	mesh.material = material
	instance.mesh = mesh
	instance.position = position_m
	add_child(instance)


func _add_overlay() -> void:
	var layer := CanvasLayer.new()
	var panel := ColorRect.new()
	panel.color = Color(0.0, 0.0, 0.0, 0.62)
	panel.position = Vector2(16.0, 16.0)
	panel.size = Vector2(610.0, 136.0)
	layer.add_child(panel)
	_status = Label.new()
	_status.position = Vector2(28.0, 25.0)
	_status.size = Vector2(580.0, 120.0)
	_status.add_theme_font_size_override(&"font_size", 15)
	layer.add_child(_status)
	add_child(layer)
