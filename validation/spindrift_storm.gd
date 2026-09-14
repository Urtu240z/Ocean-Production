extends Node3D
## Visual validation scene: strong wind, existing crest foam, and all spindrift layers.

const MODE_NAMES := ["OFF", "SOURCE_MASK", "CHUNKS_ONLY", "SPINDRIFT_ONLY", "MIST_ONLY", "FULL", "FORCE_EMISSION", "HEIGHT_ONLY", "STEEPNESS_ONLY", "CREST_ONLY", "POSITION_DEBUG"]
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
}

var _ocean: Ocean
var _mode_label: Label


func _ready() -> void:
	_ocean = get_node_or_null(^"Ocean") as Ocean
	if _ocean == null:
		push_error("Spindrift storm scene requires the P0 Ocean node.")
		return
	_ocean.spindrift_profile = load("res://validation/profiles/p0_spindrift_profile.tres") as OceanSpindriftProfile
	# Start in the normal final gate. FORCE_EMISSION remains available on key 7.
	_ocean.spindrift_debug_mode = 5
	_ocean.enable_spindrift = true
	_create_hud()
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
	var mode := clampi(_ocean.spindrift_debug_mode, 0, MODE_NAMES.size() - 1)
	_mode_label.text = "SPINDRIFT MODE: %s\n1 OFF   2 SOURCE_MASK   3 CHUNKS_ONLY   4 SPINDRIFT_ONLY   5 MIST_ONLY   6 FULL\n7 FORCE_EMISSION   8 HEIGHT_ONLY   9 STEEPNESS_ONLY   0 CREST_ONLY\nF10 POSITION_DEBUG" % MODE_NAMES[mode]
