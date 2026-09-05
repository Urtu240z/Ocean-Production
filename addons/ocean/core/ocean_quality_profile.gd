@tool
class_name OceanQualityProfile
extends Resource
## P0 sólo usa este Resource para el clipmap; por eso ya tiene utilidad real.

@export var profile_name := "Standard":
	set(value):
		if profile_name == value: return
		profile_name = value
		emit_changed()
@export var cells_per_side := 192:
	set(value):
		var effective := max(value, 2)
		if cells_per_side == effective: return
		cells_per_side = effective
		emit_changed()
@export var base_spacing_m := 0.25:
	set(value):
		var effective := maxf(value, 0.001)
		if is_equal_approx(base_spacing_m, effective): return
		base_spacing_m = effective
		emit_changed()
@export var level_count := 10:
	set(value):
		var effective := max(value, 1)
		if level_count == effective: return
		level_count = effective
		emit_changed()
## Validation-only topology switch. Zero preserves the Production mesh.
@export_enum("Fixed diagonal", "Checkerboard diagonal") var validation_diagonal_mode := 0:
	set(value):
		var effective := clampi(value, 0, 1)
		if validation_diagonal_mode == effective: return
		validation_diagonal_mode = effective
		emit_changed()
@export var horizon_distance_m := 7000.0:
	set(value):
		var effective := maxf(value, 1.0)
		if is_equal_approx(horizon_distance_m, effective): return
		horizon_distance_m = effective
		emit_changed()
@export var short_fade_range_m := Vector2(0.0, 55.0):
	set(value):
		_set_fade_range(&"short_fade_range_m", value)
@export var mid_fade_range_m := Vector2(96.0, 280.0):
	set(value):
		_set_fade_range(&"mid_fade_range_m", value)
@export var long_fade_range_m := Vector2(768.0, 2500.0):
	set(value):
		_set_fade_range(&"long_fade_range_m", value)

func _set_fade_range(property: StringName, value: Vector2) -> void:
	var effective := Vector2(maxf(value.x, 0.0), maxf(value.y, maxf(value.x, 0.0)))
	if get(property).is_equal_approx(effective): return
	match property:
		&"short_fade_range_m": short_fade_range_m = effective
		&"mid_fade_range_m": mid_fade_range_m = effective
		&"long_fade_range_m": long_fade_range_m = effective
	emit_changed()
