extends Ocean
const Runtime = preload("res://addons/ocean/areas/ocean_wave_area_runtime.gd")
const Waves = preload("res://addons/ocean/physics/water/hull_wave_state.gd")
const Tsunami = preload("res://addons/ocean/events/ocean_tsunami_state.gd")
var fixed_runtime := Runtime.new()
var fixed_waves := Waves.new()
var fixed_tsunami := Tsunami.new()
func get_wave_area_runtime() -> RefCounted: return fixed_runtime
func get_physical_hull_wave_state(_delta := -1.0) -> RefCounted: return fixed_waves
func get_boundary_tsunami_state() -> RefCounted: return fixed_tsunami
