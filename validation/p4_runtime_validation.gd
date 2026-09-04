extends SceneTree
## Headless lifecycle smoke for the P4 material variant and P0-P3 composition.

var _scene: Node
var _ocean: Ocean
var _elapsed := 0.0
var _phase := 0


func _initialize() -> void:
	_scene = load("res://validation/p4_water_optics.tscn").instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node("P0/Ocean")


func _process(delta: float) -> bool:
	_elapsed += delta
	if _elapsed < 1.0: return false
	_elapsed = 0.0
	match _phase:
		0:
			_ocean.optics = false
		1:
			_ocean.optics = true
		2:
			_ocean.coastal = false
			_ocean.crest_foam = false
			_ocean.surface_foam = false
		3:
			_ocean.coastal = true
			_ocean.crest_foam = true
			_ocean.surface_foam = true
		4:
			_ocean.significant_wave_height_m += 0.01
		5, 6, 7:
			pass
		8:
			if _ocean.get("_open_ocean") == null:
				push_error("P4 runtime validation lost OpenOceanFFT after rebuild")
			else:
				print("P4_RUNTIME_MATRIX_PASS")
			quit()
	_phase += 1
	return false
