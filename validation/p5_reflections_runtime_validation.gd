extends SceneTree
## Lifecycle smoke: exercises the strict material/compositor OFF boundary.

const SCENE := preload("res://validation/p5_reflections.tscn")
const COASTAL_BAKE := preload("res://validation/p4_paradise/coastal_bake.tres")
const TOGGLES := 20
var _scene: Node
var _ocean: Ocean
var _elapsed := 0.0
var _toggle := 0

func _initialize() -> void:
	_scene = SCENE.instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"P0/Ocean") as Ocean
	_ocean.coastal_bake = COASTAL_BAKE

func _process(delta: float) -> bool:
	_elapsed += delta
	if _elapsed < 0.25:
		return false
	_elapsed = 0.0
	if _ocean == null:
		push_error("P5 validation lost Ocean.")
		quit(1)
		return true
	# Cover every live material variant while the reflection owner repeatedly
	# detaches and recreates its compositor resources.
	var mode := _toggle / 4
	_ocean.optics = (mode & 1) != 0
	_ocean.coastal = (mode & 2) != 0
	_ocean.crest_foam = (mode & 4) != 0
	_ocean.surface_foam = (mode & 8) != 0
	if _toggle == 16:
		_ocean.open_ocean_fft = false
		_ocean.open_ocean_fft = true
	if _toggle == 24:
		_ocean.wave_profile.emit_changed()
	if _toggle == 28:
		_ocean.quality_profile.emit_changed()
	_ocean.reflections = not _ocean.reflections
	_toggle += 1
	if _toggle >= TOGGLES * 2:
		print("P5_REFLECTION_TOGGLE_PASS")
		quit()
		return true
	return false
