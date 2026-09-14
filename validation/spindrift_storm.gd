extends Node3D
## Visual validation scene: strong wind, existing crest foam, and all spindrift layers.

const MODE_NAMES := ["OFF", "SOURCE_MASK_REAL", "CHUNKS_ONLY", "SPINDRIFT_ONLY", "MIST_ONLY", "FULL", "FORCE_EMISSION", "HEIGHT_ONLY", "STEEPNESS_ONLY", "CREST_ONLY", "POSITION_DEBUG", "SOURCE_MASK_FORCE_0", "SOURCE_MASK_FORCE_1", "POSITION_DEBUG_FORCE", "DEBUG_HEIGHT_RAW", "DEBUG_HEIGHT_GATE", "DEBUG_STEEPNESS_RAW", "DEBUG_STEEPNESS_GATE", "DEBUG_CREST_RAW", "DEBUG_CREST_GATE", "DEBUG_BREAKUP_RAW", "DEBUG_DOMAIN_FADE", "DEBUG_CLIPMAP_FADE", "DEBUG_SOURCE_PRE_THRESHOLD", "DEBUG_SOURCE_FINAL", "DEBUG_SHORT_FADE", "DEBUG_MID_FADE", "DEBUG_LONG_FADE", "DEBUG_ACTIVE_RADIUS_FADE"]
const MODE_BY_KEY := {
	KEY_1: 0,
	KEY_2: 1,
	KEY_3: 2,
	KEY_4: 3,
	KEY_5: 4,
	KEY_6: 5,
	KEY_7: 6,
	KEY_8: 7,
	KEY_9: 8,
	KEY_0: 9,
	KEY_F10: 10,
	KEY_F1: 11,
	KEY_F2: 12,
	KEY_F11: 13,
	KEY_F3: 14,
	KEY_F4: 15,
	KEY_F5: 16,
	KEY_F6: 17,
	KEY_F7: 18,
	KEY_F8: 19,
	KEY_F9: 20,
	KEY_F12: 21,
	KEY_F13: 22,
	KEY_F14: 23,
	KEY_F15: 24,
	KEY_F16: 25,
	KEY_F17: 26,
	KEY_F18: 27,
	KEY_F19: 28,
	KEY_B: 1,
	KEY_N: 2,
	KEY_M: 3,
	KEY_V: 4,
	KEY_C: 5,
}

var _ocean: Ocean
var _mode_label: Label


func _ready() -> void:
	_ocean = get_node_or_null(^"Ocean") as Ocean
	if _ocean == null:
		push_error("Spindrift storm scene requires the P0 Ocean node.")
		return
	_ocean.spindrift_profile = load("res://validation/profiles/p0_spindrift_profile.tres") as OceanSpindriftProfile
	# The scene property is the single startup source of truth. Auxiliary tests
	# are available without changing the Inspector value at runtime.
	_ocean.enable_spindrift = true
	_create_hud()
	_update_hud()


func _process(_delta: float) -> void:
	# Read the controller's effective mode so Inspector/script ordering cannot
	# make the HUD claim a different mode than the runtime actually uses.
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key_event := event as InputEventKey
	if not MODE_BY_KEY.has(key_event.keycode):
		return
	_ocean.spindrift_debug_mode = MODE_BY_KEY[key_event.keycode]
	_update_hud()
	get_viewport().set_input_as_handled()


func _create_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = &"SpindriftValidationHUD"
	add_child(canvas)
	_mode_label = Label.new()
	_mode_label.name = &"ModeLabel"
	_mode_label.position = Vector2(24.0, 20.0)
	_mode_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var settings := LabelSettings.new()
	settings.font_size = 30
	settings.font_color = Color(1.0, 1.0, 1.0, 1.0)
	settings.outline_size = 9
	settings.outline_color = Color(0.0, 0.0, 0.0, 0.90)
	_mode_label.label_settings = settings
	canvas.add_child(_mode_label)


func _update_hud() -> void:
	if _mode_label == null or _ocean == null:
		return
	var requested_mode := clampi(_ocean.spindrift_debug_mode, 0, MODE_NAMES.size() - 1)
	var runtime := _ocean.get_spindrift_runtime_state()
	var effective_name := str(runtime.get("debug_mode_name", MODE_NAMES[requested_mode]))
	var mismatch := ""
	if effective_name != MODE_NAMES[requested_mode]:
		mismatch = "\nREQUESTED: %s (waiting for controller)" % MODE_NAMES[requested_mode]
	_mode_label.text = "SPINDRIFT MASK DEBUG: %s%s\n1 OFF  2 SOURCE_MASK_REAL  3 CHUNKS  4 STREAKS  5 MIST  6 FULL  7 FORCE\nF1 FORCE_0  F2 FORCE_1  F10 POSITION_DEBUG  F11 POSITION_DEBUG_FORCE\nF3 HEIGHT_RAW  F4 HEIGHT_GATE  F5 STEEPNESS_RAW  F6 STEEPNESS_GATE\nF7 CREST_RAW  F8 CREST_GATE  F9 BREAKUP_RAW  F12 DOMAIN_FADE  F13 CLIPMAP_FADE\nF14 PRE_THRESHOLD  F15 SOURCE_FINAL  F16 SHORT_FADE  F17 MID_FADE  F18 LONG_FADE  F19 ACTIVE_RADIUS" % [effective_name, mismatch]
