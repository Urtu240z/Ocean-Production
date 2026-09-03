@tool
class_name OceanWaveBand
extends Resource
## Datos físicos reutilizados por cada una de las tres bandas canónicas.

@export var significant_wave_height_m := 0.25
@export var choppiness := 0.70
@export var wind_direction := Vector2(1.0, 0.30).normalized()
@export var directional_spread := 5.0
@export var fetch_length_m := 3000.0
@export var swell := 0.45
@export var detail := 1.0
@export var jonswap_spread := 0.35
@export var min_wavelength_m := 4.0
@export var max_wavelength_m := 20.0
@export var transition_width_m := 0.75
@export var short_wave_damping_m := 0.35
