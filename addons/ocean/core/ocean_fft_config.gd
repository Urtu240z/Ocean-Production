@tool
class_name OceanFftConfig
extends Resource
## Configuración interna de una banda FFT de Production.
## Sólo existe JONSWAP + Hasselmann; no hay selector de espectro.

var id: StringName
var resolution := 256
var domain_size_m := 128.0
var gravity_mps2 := 9.81
var min_wavelength_m := 4.0
var max_wavelength_m := 20.0
var transition_width_m := 0.75
var wind_direction := Vector2.RIGHT
var wind_speed_mps := 12.0
var energy := 0.00016
var directional_spread := 4.0
var short_wave_damping_m := 0.35
var choppiness := 1.0
var target_hs_m := 0.65
var fetch_length_m := 1000.0
var swell := 0.5
var jonswap_alpha := 0.0081
var detail := 1.0
var jonswap_spread := 0.2
var measured_hs_m := 0.0


func is_valid() -> bool:
	return not id.is_empty() \
		and resolution >= 2 \
		and (resolution & (resolution - 1)) == 0 \
		and domain_size_m > 0.0 \
		and min_wavelength_m > 0.0 \
		and max_wavelength_m >= min_wavelength_m \
		and wind_speed_mps >= 0.0 \
		and target_hs_m >= 0.0 \
		and choppiness >= 0.0


func fft_stage_count() -> int:
	return int(round(log(float(resolution)) / log(2.0)))
