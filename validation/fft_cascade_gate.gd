extends Node
## Gate temporal de validación. No forma parte del addon Ocean.

enum CascadeMode { FULL, NO_MID, NO_SHORT, LONG_ONLY }

var _ocean: Node
var _base_profile: Resource
var _mode := CascadeMode.FULL

func _ready() -> void:
	_ocean = get_parent().get_node_or_null("Ocean")
	if _ocean == null:
		push_warning("FFT cascade gate: Ocean no encontrado.")
		return
	_base_profile = _ocean.wave_profile.duplicate(true) if _ocean.wave_profile != null else null
	print("FFT CASCADE GATE: FULL | 1=FULL 2=NO_MID 3=NO_SHORT 4=LONG_ONLY")


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var mode := -1
	match event.keycode:
		KEY_1: mode = CascadeMode.FULL
		KEY_2: mode = CascadeMode.NO_MID
		KEY_3: mode = CascadeMode.NO_SHORT
		KEY_4: mode = CascadeMode.LONG_ONLY
	if mode < 0 or _ocean == null or _base_profile == null:
		return
	_apply_mode(mode)
	get_viewport().set_input_as_handled()


func _apply_mode(mode: int) -> void:
	_mode = mode
	var profile: Resource = _base_profile.duplicate(true)
	if mode == CascadeMode.NO_MID or mode == CascadeMode.LONG_ONLY:
		profile.mid_band.significant_wave_height_m = 0.0
	if mode == CascadeMode.NO_SHORT or mode == CascadeMode.LONG_ONLY:
		profile.short_band.significant_wave_height_m = 0.0
	_ocean.wave_profile = profile
	print("FFT CASCADE GATE: %s" % _mode_name(mode))


func _mode_name(mode: int) -> String:
	match mode:
		CascadeMode.NO_MID: return "NO_MID"
		CascadeMode.NO_SHORT: return "NO_SHORT"
		CascadeMode.LONG_ONLY: return "LONG_ONLY"
		_: return "FULL"
