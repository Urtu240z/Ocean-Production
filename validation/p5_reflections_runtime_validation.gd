extends SceneTree
## P5 variant-binding smoke. It deliberately does not rebuild FFT: this test
## proves that Optics shader swaps retain the same published SSPR binding.

const SCENE := preload("res://validation/p5_reflections.tscn")
const COASTAL_BAKE := preload("res://validation/p4_paradise/coastal_bake.tres")
const OPTICS_VARIANT_SWAPS := 40 # 20 OFF -> ON cycles
const SETTLE_S := 0.5

var _scene: Node
var _ocean: Ocean
var _elapsed := 0.0
var _phase := 0
var _swap := 0

func _initialize() -> void:
	_scene = SCENE.instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node(^"P0/Ocean") as Ocean
	_ocean.coastal_bake = COASTAL_BAKE
	_ocean.reflections = true


func _process(delta: float) -> bool:
	_elapsed += delta
	if _elapsed < SETTLE_S:
		return false
	_elapsed = 0.0
	if _ocean == null:
		push_error("P5 variant validation lost Ocean.")
		quit(1)
		return true
	match _phase:
		0:
			if not _reflection_binding_is_live(): return true
			_phase = 1
		1:
			if not _reflection_binding_is_live(): return true
			if _swap >= OPTICS_VARIANT_SWAPS:
				_ocean.reflections = false
				_phase = 2
				return false
			_ocean.optics = not _ocean.optics
			_swap += 1
		2:
			# Reflections OFF uses a non-SSPR shader variant and the manager is gone.
			if _ocean.get_node_or_null(^"OpenOceanFFT/OceanSSPR") != null:
				push_error("P5 validation retained OceanSSPR while Reflections was OFF.")
				quit(1)
				return true
			_ocean.reflections = true
			_phase = 3
		3:
			if not _reflection_binding_is_live(): return true
			print("P5_VARIANT_BINDING_PASS swaps=%d" % OPTICS_VARIANT_SWAPS)
			quit()
			return true
	return false


func _reflection_binding_is_live() -> bool:
	var surface := _ocean.get_node_or_null(^"OpenOceanFFT/OceanClipmapSurface") as OceanClipmapSurface
	var material: ShaderMaterial = surface.get("_material") as ShaderMaterial if surface != null else null
	if material != null and material.get_shader_parameter(&"reflection_sspr_available") == true:
		return true
	push_error("P5 validation lost reflection_sspr_available after an Optics variant swap.")
	quit(1)
	return false
