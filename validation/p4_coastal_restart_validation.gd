extends SceneTree
## Bounded lifecycle smoke for a serialized CoastalBakeAsset. It never bakes;
## it only restarts the existing Production Ocean runtime against the asset.

const SCENE := preload("res://validation/p4_water_optics.tscn")
const RESTARTS_PER_MODE := 20
const SETTLE_S := 0.25

var _scene: Node
var _ocean: Ocean
var _elapsed := 0.0
var _mode := 0
var _restart := 0


func _initialize() -> void:
	_scene = SCENE.instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"P0/Ocean") as Ocean


func _process(delta: float) -> bool:
	_elapsed += delta
	if _elapsed < SETTLE_S:
		return false
	_elapsed = 0.0
	if _ocean == null:
		push_error("P4 coastal restart validation lost Ocean.")
		quit(1)
		return true
	if _restart >= RESTARTS_PER_MODE:
		_mode += 1
		_restart = 0
		if _mode >= 3:
			print("P4_COASTAL_RESTART_MATRIX_PASS")
			quit()
			return true
	_match_mode()
	_ocean.open_ocean_fft = false
	_ocean.open_ocean_fft = true
	if _ocean.get("_open_ocean") == null:
		push_error("P4 coastal restart validation failed to restore OpenOceanFFT.")
		quit(1)
		return true
	_restart += 1
	return false


func _match_mode() -> void:
	match _mode:
		0: # OFF real: assigned bake must not be activated or validated.
			_ocean.coastal = false
			_ocean.optics = false
		1: # Coastal waves require the bake.
			_ocean.coastal = true
			_ocean.optics = false
		2: # P4 optics retains only the independent seabed authority.
			_ocean.coastal = false
			_ocean.optics = true
