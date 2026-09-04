@tool
class_name OceanWaveBandProfile
extends Resource
## Datos físicos reutilizados por cada una de las tres bandas canónicas.

@export var significant_wave_height_m := 0.25:
	set(value):
		var effective := maxf(value, 0.0)
		if is_equal_approx(significant_wave_height_m, effective): return
		significant_wave_height_m = effective
		emit_changed()
@export var choppiness := 0.70:
	set(value):
		var effective := maxf(value, 0.0)
		if is_equal_approx(choppiness, effective): return
		choppiness = effective
		emit_changed()
@export var wind_direction := Vector2(1.0, 0.30).normalized():
	set(value):
		var effective := value if value.length_squared() > 0.000001 else Vector2.RIGHT
		if wind_direction.is_equal_approx(effective): return
		wind_direction = effective
		emit_changed()
@export var directional_spread := 5.0:
	set(value):
		var effective := maxf(value, 0.0)
		if is_equal_approx(directional_spread, effective): return
		directional_spread = effective
		emit_changed()
@export var fetch_length_m := 3000.0:
	set(value):
		var effective := maxf(value, 1.0)
		if is_equal_approx(fetch_length_m, effective): return
		fetch_length_m = effective
		emit_changed()
@export var swell := 0.45:
	set(value):
		var effective := clampf(value, 0.0, 1.0)
		if is_equal_approx(swell, effective): return
		swell = effective
		emit_changed()
@export var detail := 1.0:
	set(value):
		var effective := clampf(value, 0.0, 1.0)
		if is_equal_approx(detail, effective): return
		detail = effective
		emit_changed()
@export var jonswap_spread := 0.35:
	set(value):
		var effective := clampf(value, 0.0, 1.0)
		if is_equal_approx(jonswap_spread, effective): return
		jonswap_spread = effective
		emit_changed()
@export var min_wavelength_m := 4.0:
	set(value):
		var effective := maxf(value, 0.001)
		if is_equal_approx(min_wavelength_m, effective): return
		min_wavelength_m = effective
		emit_changed()
@export var max_wavelength_m := 20.0:
	set(value):
		var effective := maxf(value, 0.001)
		if is_equal_approx(max_wavelength_m, effective): return
		max_wavelength_m = effective
		emit_changed()
@export var transition_width_m := 0.75:
	set(value):
		var effective := maxf(value, 0.0)
		if is_equal_approx(transition_width_m, effective): return
		transition_width_m = effective
		emit_changed()
@export var short_wave_damping_m := 0.35:
	set(value):
		var effective := maxf(value, 0.0)
		if is_equal_approx(short_wave_damping_m, effective): return
		short_wave_damping_m = effective
		emit_changed()
