@tool
class_name OceanQualityProfile
extends Resource
## P0 sólo usa este Resource para el clipmap; por eso ya tiene utilidad real.

@export var profile_name := "Standard"
@export var cells_per_side := 192
@export var base_spacing_m := 0.25
@export var level_count := 10
@export var horizon_distance_m := 7000.0
@export var short_fade_range_m := Vector2(0.0, 55.0)
@export var mid_fade_range_m := Vector2(96.0, 280.0)
@export var long_fade_range_m := Vector2(768.0, 2500.0)
