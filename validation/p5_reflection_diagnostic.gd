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

enum NormalSpace {
	CURRENT_WORLD,
	WORLD_TO_VIEW,
	FLAT_WORLD_UP,
}

enum NormalProbe {
	NONE,
	FFT_WORLD,
	FFT_VIEW,
}

var _mode := Mode.FINAL_NORMAL
var _probe := BaseProbe.NONE
var _normal_space := NormalSpace.CURRENT_WORLD
var _normal_probe := NormalProbe.NONE
var _surface: Node
var _material: ShaderMaterial
var _sun: DirectionalLight3D
var _status: Label
var _ocean: Ocean
var _camera: Camera3D
var _fixed_camera_position := Vector3.ZERO
var _locked_camera_yaw := 0.0
var _locked_camera_roll := 0.0
var _pitch_degrees := 0.0
var _foam_enabled := false
var _world_environment: WorldEnvironment
var _original_sky: Sky
var _uniform_sky: Sky
var _uniform_sky_enabled := false


func _ready() -> void:
	call_deferred(&"_initialize_diagnostic")


func _initialize_diagnostic() -> void:
	_ocean = get_node_or_null(^"P0OpenOcean/Ocean") as Ocean
	if _ocean == null:
		push_error("P5 diagnostic: Production Ocean node is missing.")
		return
	# This fixture is explicitly the no-SSPR, no-P4, no-foam baseline.
	_ocean.optics = false
	_ocean.crest_foam = false
	_ocean.surface_foam = false
	_camera = get_node_or_null(^"P0OpenOcean/FreeCamera") as Camera3D
	if _camera == null:
		push_error("P5 diagnostic: FreeCamera is missing.")
		return
	_fixed_camera_position = _camera.global_position
	_locked_camera_yaw = _camera.rotation.y
	_locked_camera_roll = _camera.rotation.z
	_world_environment = get_node_or_null(^"P0OpenOcean/WorldEnvironment") as WorldEnvironment
	if _world_environment == null or _world_environment.environment == null:
		push_error("P5 diagnostic: WorldEnvironment is missing.")
		return
	_original_sky = _world_environment.environment.sky
	_uniform_sky = _create_uniform_sky()
	await get_tree().process_frame
	_surface = _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface")
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
	source = source.replace(marker, marker + "\nuniform int p5_diagnostic_mode = 0;\nuniform int p5_base_probe = 0;\nuniform int p5_normal_space = 0;\nuniform int p5_normal_probe = 0;")
	marker = '''vec3 shading_normal_world = normalize(long_normal * long_weight
		+ texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight
		+ texture(normal_short, world_uv(world_xz, domain_short_m)).xyz * short_weight);
	vec3 visual_normal = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);
	NORMAL = visual_normal;'''
	if not source.contains(marker):
		push_error("P5 diagnostic: base normal marker changed.")
		return
	source = source.replace(marker, _normal_space_fragment())
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


func _process(_delta: float) -> void:
	if _camera == null:
		return
	# Input may request Q/E vertical travel, but neither mouse rotation nor X/Z
	# translation is allowed to influence this comparison. Only fixed presets set
	# the pitch; yaw and roll stay at the initial values.
	_camera.global_position = _fixed_camera_position
	_camera.rotation = Vector3(deg_to_rad(_pitch_degrees), _locked_camera_yaw, _locked_camera_roll)


func _normal_space_fragment() -> String:
	return '''
	vec3 p5_fft_normal_world = normalize(long_normal * long_weight
		+ texture(normal_mid, world_uv(world_xz, domain_mid_m)).xyz * mid_weight
		+ texture(normal_short, world_uv(world_xz, domain_short_m)).xyz * short_weight);
	vec3 p5_fft_normal_view = normalize(mat3(VIEW_MATRIX) * p5_fft_normal_world);
	if (p5_normal_space == 0) {
		// A: current Production behaviour.
		NORMAL = p5_fft_normal_world;
	} else if (p5_normal_space == 1) {
		// B: explicit world-to-view conversion.
		NORMAL = p5_fft_normal_view;
	} else {
		// C: view-space flat water control.
		NORMAL = normalize(mat3(VIEW_MATRIX) * vec3(0.0, 1.0, 0.0));
	}
'''


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
	} else if (p5_normal_probe == 1) {
		// These probes intentionally never read NORMAL after Godot receives it.
		EMISSION = p5_fft_normal_world * 0.5 + 0.5;
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (p5_normal_probe == 2) {
		EMISSION = p5_fft_normal_view * 0.5 + 0.5;
		ALBEDO = vec3(0.0);
		ROUGHNESS = 1.0;
		SPECULAR = 0.0;
	} else if (p5_base_probe == 2) {
		ALBEDO = NORMAL * 0.5 + 0.5;
		EMISSION = vec3(0.0);
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
		KEY_Z: _set_normal_space(NormalSpace.CURRENT_WORLD)
		KEY_X: _set_normal_space(NormalSpace.WORLD_TO_VIEW)
		KEY_C: _set_normal_space(NormalSpace.FLAT_WORLD_UP)
		KEY_G: _set_normal_probe(NormalProbe.FFT_WORLD)
		KEY_H: _set_normal_probe(NormalProbe.FFT_VIEW)
		KEY_J: _set_normal_probe(NormalProbe.NONE)
		KEY_F1: _set_pitch_degrees(12.0)
		KEY_F2: _set_pitch_degrees(0.0)
		KEY_F3: _set_pitch_degrees(-12.0)
		KEY_F4: _set_pitch_degrees(-28.0)
		KEY_F5: _set_foam_enabled(not _foam_enabled)
		KEY_F11: _set_uniform_sky_enabled(not _uniform_sky_enabled)


func _set_mode(value: Mode) -> void:
	_mode = value
	_probe = BaseProbe.NONE
	_apply_mode()


func _set_probe(value: BaseProbe) -> void:
	_probe = value
	_apply_mode()


func _set_normal_space(value: NormalSpace) -> void:
	_normal_space = value
	_normal_probe = NormalProbe.NONE
	_apply_mode()


func _set_normal_probe(value: NormalProbe) -> void:
	_normal_probe = value
	_apply_mode()


func _set_pitch_degrees(value: float) -> void:
	if _camera == null:
		return
	_pitch_degrees = value
	_camera.rotation = Vector3(deg_to_rad(_pitch_degrees), _locked_camera_yaw, _locked_camera_roll)
	_apply_mode()


func _set_foam_enabled(value: bool) -> void:
	_foam_enabled = value
	if _ocean != null:
		_ocean.crest_foam = value
		_ocean.surface_foam = value
	_apply_mode()


func _set_uniform_sky_enabled(value: bool) -> void:
	_uniform_sky_enabled = value
	if _world_environment != null and _world_environment.environment != null:
		_world_environment.environment.sky = _uniform_sky if value else _original_sky
	_apply_mode()


func _apply_mode() -> void:
	if _material == null:
		return
	_material.set_shader_parameter(&"p5_diagnostic_mode", _mode)
	_material.set_shader_parameter(&"p5_base_probe", _probe)
	_material.set_shader_parameter(&"p5_normal_space", _normal_space)
	_material.set_shader_parameter(&"p5_normal_probe", _normal_probe)
	if _sun != null:
		_sun.visible = _mode != Mode.IBL_FALLBACK_ONLY
	if _status != null:
		_status.text = "P5 REFLECTION DIAGNOSTIC (validation only)\n" + _mode_name() + " | " + _normal_space_name() + "\n" + _probe_name() + " | " + _normal_probe_name() + " | Foam " + ("ON" if _foam_enabled else "OFF") + " | " + _sky_name() + "\nFixed position (%.1f, %.1f, %.1f), pitch %.0f° | F1/F2/F3/F4 pitch | Z/X/C normal A/B/C | F11 sky\n0-5 modes | F5 foam | F6 clear probe | F7 Albedo | F8 Normal | F9 Roughness | F10 Specular" % [_fixed_camera_position.x, _fixed_camera_position.y, _fixed_camera_position.z, _pitch_degrees]
	print("P5_DIAGNOSTIC mode=%s normal_space=%s normal_probe=%s foam=%s sky=%s position=(%.1f,%.1f,%.1f) pitch=%.1f sspr_present=NO" % [_mode_name(), _normal_space_name(), _normal_probe_name(), "ON" if _foam_enabled else "OFF", _sky_name(), _fixed_camera_position.x, _fixed_camera_position.y, _fixed_camera_position.z, _pitch_degrees])


func _mode_name() -> String:
	return ["MODE 0 — FINAL NORMAL", "MODE 1 — SSPR RAW RGB", "MODE 2 — SSPR CONFIDENCE", "MODE 3 — IBL/FALLBACK ONLY", "MODE 4 — SSPR CONTRIBUTION ONLY", "MODE 5 — FINAL COMPOSITION"][_mode]


func _probe_name() -> String:
	return ["Base PBR probe: none", "Base PBR probe: ALBEDO", "Base PBR probe: NORMAL", "Base PBR probe: ROUGHNESS", "Base PBR probe: SPECULAR"][_probe]


func _normal_space_name() -> String:
	return ["A CURRENT world", "B WORLD→VIEW", "C FLAT world-up"][_normal_space]


func _normal_probe_name() -> String:
	return ["FFT probe: none", "FFT_NORMAL_WORLD", "FFT_NORMAL_VIEW"][_normal_probe]


func _sky_name() -> String:
	return "Uniform clear sky" if _uniform_sky_enabled else "Kloofendal HDRI"


func _create_uniform_sky() -> Sky:
	var material := ProceduralSkyMaterial.new()
	var clear := Color(0.62, 0.78, 0.98)
	material.sky_top_color = clear
	material.sky_horizon_color = clear
	material.ground_bottom_color = clear
	material.ground_horizon_color = clear
	material.sun_angle_max = 0.0
	material.energy_multiplier = 1.0
	var sky := Sky.new()
	sky.sky_material = material
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	return sky


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
