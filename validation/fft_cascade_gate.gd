extends Node
## Gate temporal de validación. No forma parte del addon Ocean.

const CascadeState := preload("res://addons/ocean/core/ocean_cascade_state.gd")
enum CascadeMode { FULL, NO_MID, NO_SHORT, LONG_ONLY }

var _ocean: Node
var _mode := CascadeMode.FULL

func _ready() -> void:
	_ocean = get_parent().get_node_or_null("Ocean")
	if _ocean == null:
		push_warning("FFT cascade gate: Ocean no encontrado.")
		return
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
	if mode < 0 or _ocean == null:
		return
	_apply_mode(mode)
	get_viewport().set_input_as_handled()


func _apply_mode(mode: int) -> void:
	_mode = mode
	_ocean.set_fft_cascade_mask(_mask_for_mode(mode))
	print("FFT CASCADE GATE: %s" % _mode_name(mode))
	call_deferred(&"_print_runtime_graph")


func _print_runtime_graph() -> void:
	if _ocean == null: return
	var open_ocean := _ocean.get_node_or_null("OpenOceanFFT")
	if open_ocean != null and open_ocean.has_method(&"print_cascade_runtime_graph"):
		open_ocean.print_cascade_runtime_graph()


func _mask_for_mode(mode: int) -> int:
	match mode:
		CascadeMode.NO_MID: return CascadeState.LONG | CascadeState.SHORT
		CascadeMode.NO_SHORT: return CascadeState.LONG | CascadeState.MID
		CascadeMode.LONG_ONLY: return CascadeState.LONG
		_: return CascadeState.FULL


func _mode_name(mode: int) -> String:
	match mode:
		CascadeMode.NO_MID: return "NO_MID"
		CascadeMode.NO_SHORT: return "NO_SHORT"
		CascadeMode.LONG_ONLY: return "LONG_ONLY"
		_: return "FULL"
