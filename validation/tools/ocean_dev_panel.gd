class_name OceanDevPanel
extends CanvasLayer
## Development-only live controls.  It deliberately lives in validation/, keeps
## no global state, and only observes the asynchronous waterline diagnostics.

const FEATURE_ROWS := [
	["LONG", &"long_enabled"], ["MID", &"mid_enabled"], ["SHORT", &"short_enabled"],
	["Coastal", &"coastal"], ["Crest Foam", &"crest_foam"], ["Surface Foam", &"surface_foam"],
	["Optics", &"optics"], ["Reflections / SSPR", &"reflections"], ["Surface Detail", &"surface_detail"],
	["Underwater Medium", &"underwater_medium"], ["Underwater Bubbles", &"underwater_bubbles"], ["Underwater Sunrays", &"underwater_sunrays"],
]
const TARGET_HEIGHTS := [480, 540, 600, 640, 720, 800, 900, 1080, 1200, 1440]
const SCALE_PRESETS := [["Ultra Quality", 0.77], ["Quality", 0.67], ["Balanced", 0.59], ["Performance", 0.50], ["Native", 1.0]]

var _ocean: Object
var _world: WorldEnvironment
var _sun: DirectionalLight3D
var _camera: Camera3D
var _panel: PanelContainer
var _status: Label
var _feature_buttons := {}
var _environment_buttons := {}
var _scale_mode: OptionButton
var _internal_resolution: OptionButton
var _scale_preset: OptionButton
var _sharpness: HSlider
var _sharpness_value: Label
var _status_elapsed := 0.0
var _resolution_output_size := Vector2i.ZERO
var _resolution_dynamic_scale := NAN
var _menu_open := false
var _camera_was_processing := true
var _camera_was_unhandled := true
var _mouse_was_captured := true
var _initial := {}


func _ready() -> void:
	_resolve_references()
	if _ocean == null:
		queue_free()
		return
	_capture_initial_state()
	_build_ui()
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	set_process(true)
	set_process_unhandled_input(true)
	_set_menu_open(false)


func _resolve_references() -> void:
	var root := get_parent()
	_ocean = root.get_node_or_null(^"Ocean") if root != null else null
	_world = root.get_node_or_null(^"WorldEnvironment") as WorldEnvironment if root != null else null
	_sun = root.get_node_or_null(^"Sun") as DirectionalLight3D if root != null else null
	_camera = root.get_node_or_null(^"FreeCamera") as Camera3D if root != null else null


func _capture_initial_state() -> void:
	for feature in FEATURE_ROWS:
		_initial[str(feature[1])] = bool(_ocean.get(feature[1]))
	var viewport := get_viewport()
	_initial["scaling_mode"] = viewport.scaling_3d_mode
	_initial["scaling_scale"] = viewport.scaling_3d_scale
	_initial["fsr_sharpness"] = viewport.fsr_sharpness
	if _world != null:
		_initial["glow"] = _world.environment.glow_enabled if _world.environment != null else false
		_initial["auto_exposure"] = _world.camera_attributes.auto_exposure_enabled if _world.camera_attributes != null else false
	if _sun != null:
		_initial["sun_shadows"] = _sun.shadow_enabled


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel.position = Vector2(12.0, 12.0)
	_panel.size = Vector2(500.0, 700.0)
	add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(500.0, 700.0)
	_panel.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	_add_title(content, "OCEAN DEV CONTROL PANEL  |  F3 close")
	_add_section(content, "OCEAN SYSTEMS")
	for feature in FEATURE_ROWS:
		_add_feature_row(content, str(feature[0]), feature[1])
	var full := Button.new()
	full.text = "FULL OCEAN"
	full.pressed.connect(_set_full_ocean)
	content.add_child(full)
	_add_section(content, "RENDER / UPSCALING")
	_scale_mode = OptionButton.new()
	_scale_mode.add_item("NATIVE 1:1")
	_scale_mode.add_item("BILINEAR")
	_scale_mode.add_item("FSR 1")
	_scale_mode.add_item("FSR 2 (Native/TAA at 1.0)")
	_scale_mode.item_selected.connect(_on_scale_mode_selected)
	_add_labeled_control(content, "Upscaler", _scale_mode)
	_internal_resolution = OptionButton.new()
	_internal_resolution.item_selected.connect(_on_internal_resolution_selected)
	_add_labeled_control(content, "Internal 3D resolution", _internal_resolution)
	_scale_preset = OptionButton.new()
	for preset in SCALE_PRESETS:
		_scale_preset.add_item(str(preset[0]))
		_scale_preset.set_item_metadata(_scale_preset.item_count - 1, float(preset[1]))
	_scale_preset.item_selected.connect(_on_scale_preset_selected)
	_add_labeled_control(content, "Scale preset", _scale_preset)
	_sharpness = HSlider.new()
	_sharpness.min_value = 0.0
	_sharpness.max_value = 2.0
	_sharpness.step = 0.05
	_sharpness.value_changed.connect(_on_sharpness_changed)
	_sharpness_value = Label.new()
	var sharpness_row := HBoxContainer.new()
	sharpness_row.add_child(_sharpness)
	sharpness_row.add_child(_sharpness_value)
	_add_labeled_control(content, "FSR sharpness (0 sharp / 2 soft)", sharpness_row)
	_add_section(content, "ENVIRONMENT DEBUG")
	_add_environment_row(content, "Auto Exposure", &"auto_exposure")
	_add_environment_row(content, "Glow", &"glow")
	_add_environment_row(content, "Sun Shadows", &"sun_shadows")
	var reset := Button.new()
	reset.text = "RESET P0"
	reset.pressed.connect(_reset_p0)
	content.add_child(reset)
	_add_section(content, "LIVE STATUS")
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(460.0, 260.0)
	content.add_child(_status)
	_refresh_controls()


func _add_title(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override(&"font_size", 18)
	parent.add_child(label)


func _add_section(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = "\n" + text
	label.add_theme_font_size_override(&"font_size", 15)
	parent.add_child(label)


func _add_feature_row(parent: Control, label_text: String, property: StringName) -> void:
	var button := CheckBox.new()
	button.text = label_text
	button.button_pressed = bool(_ocean.get(property))
	button.toggled.connect(_on_feature_toggled.bind(property))
	parent.add_child(button)
	_feature_buttons[property] = button


func _add_environment_row(parent: Control, label_text: String, key: StringName) -> void:
	var button := CheckBox.new()
	button.text = label_text
	button.toggled.connect(_on_environment_toggled.bind(key))
	parent.add_child(button)
	_environment_buttons[key] = button


func _add_labeled_control(parent: Control, label_text: String, control: Control) -> void:
	var row := VBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	row.add_child(label)
	row.add_child(control)
	parent.add_child(row)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		_set_menu_open(not _menu_open)
		get_viewport().set_input_as_handled()


func _set_menu_open(open: bool) -> void:
	_menu_open = open
	if _panel != null:
		_panel.visible = open
	if _camera == null:
		return
	if open:
		_camera_was_processing = _camera.is_processing()
		_camera_was_unhandled = _camera.is_processing_unhandled_input()
		_mouse_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		_camera.set_process(false)
		_camera.set_process_unhandled_input(false)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_camera.set_process(_camera_was_processing)
		_camera.set_process_unhandled_input(_camera_was_unhandled)
		if _mouse_was_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _on_feature_toggled(enabled: bool, property: StringName) -> void:
	_ocean.set(property, enabled)


func _on_environment_toggled(enabled: bool, key: StringName) -> void:
	if key == &"auto_exposure" and _world != null and _world.camera_attributes != null:
		_world.camera_attributes.auto_exposure_enabled = enabled
	elif key == &"glow" and _world != null and _world.environment != null:
		_world.environment.glow_enabled = enabled
	elif key == &"sun_shadows" and _sun != null:
		_sun.shadow_enabled = enabled


func _on_scale_mode_selected(index: int) -> void:
	var viewport := get_viewport()
	match index:
		0:
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			viewport.scaling_3d_scale = 1.0
		1: viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		2: viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		3: viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	_refresh_controls()


func _on_internal_resolution_selected(index: int) -> void:
	var render_scale := float(_internal_resolution.get_item_metadata(index))
	var viewport := get_viewport()
	if is_equal_approx(render_scale, 1.0):
		viewport.scaling_3d_scale = 1.0
	else:
		if _scale_mode.selected == 0:
			_scale_mode.select(1)
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		viewport.scaling_3d_scale = render_scale
	_refresh_controls()


func _on_scale_preset_selected(index: int) -> void:
	var render_scale := float(_scale_preset.get_item_metadata(index))
	var viewport := get_viewport()
	if render_scale < 1.0 and _scale_mode.selected == 0:
		_scale_mode.select(1)
		viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = render_scale
	_refresh_controls()


func _on_sharpness_changed(value: float) -> void:
	get_viewport().fsr_sharpness = value
	_refresh_controls()


func _set_full_ocean() -> void:
	for feature in FEATURE_ROWS:
		_ocean.set(feature[1], true)
	_refresh_controls()


func _reset_p0() -> void:
	for feature in FEATURE_ROWS:
		_ocean.set(feature[1], _initial.get(str(feature[1]), true))
	var viewport := get_viewport()
	var initial_mode: Viewport.Scaling3DMode = _initial.get("scaling_mode", Viewport.SCALING_3D_MODE_BILINEAR)
	viewport.scaling_3d_mode = initial_mode
	viewport.scaling_3d_scale = float(_initial.get("scaling_scale", 1.0))
	viewport.fsr_sharpness = float(_initial.get("fsr_sharpness", 0.0))
	if _world != null and _world.environment != null:
		_world.environment.glow_enabled = bool(_initial.get("glow", _world.environment.glow_enabled))
	if _world != null and _world.camera_attributes != null:
		_world.camera_attributes.auto_exposure_enabled = bool(_initial.get("auto_exposure", _world.camera_attributes.auto_exposure_enabled))
	if _sun != null:
		_sun.shadow_enabled = bool(_initial.get("sun_shadows", _sun.shadow_enabled))
	_refresh_controls()


func _process(delta: float) -> void:
	_status_elapsed += maxf(delta, 0.0)
	if _status_elapsed < 0.25:
		return
	_status_elapsed = 0.0
	_refresh_status()


func _on_viewport_size_changed() -> void:
	_refresh_scaling_controls()
	_refresh_status()


func _refresh_controls() -> void:
	if _ocean == null:
		return
	for property in _feature_buttons:
		_feature_buttons[property].set_pressed_no_signal(bool(_ocean.get(property)))
	_refresh_environment_controls()
	_refresh_scaling_controls()
	_refresh_status()


func _refresh_environment_controls() -> void:
	if _environment_buttons.has(&"auto_exposure"):
		_environment_buttons[&"auto_exposure"].set_pressed_no_signal(_world != null and _world.camera_attributes != null and _world.camera_attributes.auto_exposure_enabled)
		_environment_buttons[&"glow"].set_pressed_no_signal(_world != null and _world.environment != null and _world.environment.glow_enabled)
		_environment_buttons[&"sun_shadows"].set_pressed_no_signal(_sun != null and _sun.shadow_enabled)


func _refresh_scaling_controls() -> void:
	var viewport := get_viewport()
	var mode := viewport.scaling_3d_mode
	_scale_mode.select(2 if mode == Viewport.SCALING_3D_MODE_FSR else 3 if mode == Viewport.SCALING_3D_MODE_FSR2 else 0 if is_equal_approx(viewport.scaling_3d_scale, 1.0) else 1)
	var output := viewport.get_visible_rect().size
	var output_i := Vector2i(roundi(output.x), roundi(output.y))
	var actual_scale := viewport.scaling_3d_scale
	var has_fixed_scale := _has_fixed_resolution_scale(actual_scale, output_i.y)
	var dynamic_scale := actual_scale if not is_equal_approx(actual_scale, 1.0) and not has_fixed_scale else NAN
	var dynamic_scale_changed := is_nan(dynamic_scale) != is_nan(_resolution_dynamic_scale) or (not is_nan(dynamic_scale) and not is_equal_approx(dynamic_scale, _resolution_dynamic_scale))
	if output_i != _resolution_output_size or dynamic_scale_changed:
		_rebuild_internal_resolution_options(output_i, dynamic_scale)
	var selected := 0
	for index in _internal_resolution.item_count:
		if is_equal_approx(float(_internal_resolution.get_item_metadata(index)), actual_scale):
			selected = index
			break
	_internal_resolution.select(selected)
	_sharpness.set_value_no_signal(viewport.fsr_sharpness)
	_sharpness.editable = mode == Viewport.SCALING_3D_MODE_FSR or mode == Viewport.SCALING_3D_MODE_FSR2
	_sharpness_value.text = " %.2f" % viewport.fsr_sharpness


func _has_fixed_resolution_scale(render_scale: float, output_height: int) -> bool:
	if is_equal_approx(render_scale, 1.0):
		return true
	for height in TARGET_HEIGHTS:
		if height < output_height and is_equal_approx(float(height) / float(output_height), render_scale):
			return true
	return false


func _rebuild_internal_resolution_options(output_i: Vector2i, dynamic_scale: float) -> void:
	_internal_resolution.clear()
	var output_height := maxi(output_i.y, 1)
	var aspect := float(output_i.x) / float(output_height)
	for height in TARGET_HEIGHTS:
		if height >= output_height:
			continue
		var width := int(round(float(height) * aspect))
		width -= width % 2
		_internal_resolution.add_item("%dx%d" % [width, height])
		_internal_resolution.set_item_metadata(_internal_resolution.item_count - 1, float(height) / float(output_height))
	if not is_nan(dynamic_scale):
		var current := Vector2i(roundi(float(output_i.x) * dynamic_scale), roundi(float(output_i.y) * dynamic_scale))
		_internal_resolution.add_item("CURRENT %dx%d (%d%%)" % [current.x, current.y, roundi(dynamic_scale * 100.0)])
		_internal_resolution.set_item_metadata(_internal_resolution.item_count - 1, dynamic_scale)
	_internal_resolution.add_item("%dx%d / Native" % [output_i.x, output_i.y])
	_internal_resolution.set_item_metadata(_internal_resolution.item_count - 1, 1.0)
	_resolution_output_size = output_i
	_resolution_dynamic_scale = dynamic_scale


func _refresh_status() -> void:
	if _status == null:
		return
	var runtime: Dictionary = _ocean.get_runtime_feature_state() if _ocean.has_method(&"get_runtime_feature_state") else {}
	var waterline: Dictionary = _ocean.get_waterline_state() if _ocean.has_method(&"get_waterline_state") else {}
	var viewport := get_viewport()
	var output := viewport.get_visible_rect().size
	var output_i := Vector2i(roundi(output.x), roundi(output.y))
	var internal := Vector2i(roundi(output.x * viewport.scaling_3d_scale), roundi(output.y * viewport.scaling_3d_scale))
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(viewport.get_viewport_rid())
	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(viewport.get_viewport_rid())
	var distance := float(waterline.get("signed_distance_to_surface", NAN))
	var open: Object = _ocean.find_child("OpenOceanFFT", true, false)
	var graph: Dictionary = open.get_cascade_runtime_state() if open != null and open.has_method(&"get_cascade_runtime_state") else {}
	var band_effective := {"LONG": false, "MID": false, "SHORT": false}
	for band in graph.get("bands", []):
		band_effective[str(band.get("name", ""))] = bool(band.get("effective", false))
	var bands := "LONG=%s MID=%s SHORT=%s" % [band_effective.get("LONG", false), band_effective.get("MID", false), band_effective.get("SHORT", false)]
	var mode_name := "BILINEAR" if viewport.scaling_3d_mode == Viewport.SCALING_3D_MODE_BILINEAR else "FSR 1" if viewport.scaling_3d_mode == Viewport.SCALING_3D_MODE_FSR else "FSR 2"
	_status.text = "FPS %.1f | GPU %.3f ms | CPU %.3f ms\noutput %dx%d | internal %dx%d | scale %.3f | %s | sharpness %.2f\nwater %s | signed distance %s | async age %s\n%s | Coastal=%s Crest=%s Foam=%s @ %.0f Hz\nOptics=%s SSPR=%s Detail=%s | Medium=%s Raster=%s Bubbles=%s Sunrays=%s\nrequested/effective: Foam %s/%s  Optics %s/%s  SSPR %s/%s  Detail %s/%s" % [Engine.get_frames_per_second(), gpu_ms, cpu_ms, output_i.x, output_i.y, internal.x, internal.y, viewport.scaling_3d_scale, mode_name, viewport.fsr_sharpness, runtime.get("runtime_water_state", "TRANSITION"), "NA" if is_nan(distance) else "%.3f" % distance, runtime.get("readback_age_frames", -1), bands, _ocean.get(&"coastal"), runtime.get("crest_foam", false), runtime.get("surface_foam_presentation_active", false), float(runtime.get("surface_foam_update_hz", 30.0)), runtime.get("optics_runtime_active", false), runtime.get("sspr_runtime_active", false), runtime.get("surface_detail_runtime_active", false), runtime.get("medium_fullscreen_active", false), runtime.get("waterline_raster_active", false), runtime.get("bubbles_runtime_active", false), runtime.get("sunrays_runtime_active", false), _ocean.get(&"surface_foam"), runtime.get("surface_foam_presentation_active", false), _ocean.get(&"optics"), runtime.get("optics_runtime_active", false), _ocean.get(&"reflections"), runtime.get("sspr_runtime_active", false), _ocean.get(&"surface_detail"), runtime.get("surface_detail_runtime_active", false)]
