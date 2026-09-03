@tool
class_name OceanWaveProfile
extends Resource
## El perfil conserva los detalles técnicos LONG/MID/SHORT fuera del nodo raíz.

const BandScript := preload("res://addons/water_race_ocean/core/ocean_wave_band.gd")
const FftConfigScript := preload("res://addons/water_race_ocean/core/ocean_fft_config.gd")

@export var profile_name := "Rough"
@export var wind_speed_mps := 18.0
@export var long_band: Resource
@export var mid_band: Resource
@export var short_band: Resource


func build_fft_configs(overall_hs_m := -1.0, wind_speed_override_mps := -1.0, primary_direction_degrees := -1000.0, swell_override := -1.0) -> Array:
	var bands := [_band_or_default(long_band, 0), _band_or_default(mid_band, 1), _band_or_default(short_band, 2)]
	var ids: Array[StringName] = [&"LONG", &"MID", &"SHORT"]
	var domains := [512.0, 137.0, 37.0]
	var result := []
	for index in 3:
		var band: Resource = bands[index]
		var config = FftConfigScript.new()
		config.id = ids[index]
		config.resolution = 256
		config.domain_size_m = domains[index]
		config.wind_speed_mps = wind_speed_mps
		config.target_hs_m = band.significant_wave_height_m
		config.choppiness = band.choppiness
		config.wind_direction = band.wind_direction.normalized() if band.wind_direction.length_squared() > 0.0 else Vector2.RIGHT
		config.directional_spread = band.directional_spread
		config.fetch_length_m = band.fetch_length_m
		config.swell = band.swell
		config.detail = band.detail
		config.jonswap_spread = band.jonswap_spread
		config.min_wavelength_m = band.min_wavelength_m
		config.max_wavelength_m = maxf(band.max_wavelength_m, band.min_wavelength_m)
		config.transition_width_m = band.transition_width_m
		config.short_wave_damping_m = band.short_wave_damping_m
		result.append(config)
	var profile_hs := combined_significant_wave_height_m()
	var hs_scale := overall_hs_m / profile_hs if overall_hs_m >= 0.0 and profile_hs > 0.0 else 1.0
	var reference_direction: Vector2 = _band_or_default(long_band, 0).wind_direction.normalized()
	var direction_offset := deg_to_rad(primary_direction_degrees) - reference_direction.angle() if primary_direction_degrees > -999.0 else 0.0
	var reference_swell: float = _band_or_default(long_band, 0).swell
	var swell_scale: float = swell_override / reference_swell if swell_override >= 0.0 and reference_swell > 0.0 else 1.0
	for config in result:
		config.target_hs_m *= hs_scale
		if wind_speed_override_mps >= 0.0: config.wind_speed_mps = wind_speed_override_mps
		config.wind_direction = config.wind_direction.rotated(direction_offset)
		config.swell *= swell_scale
	return result


func combined_significant_wave_height_m() -> float:
	var variance := 0.0
	for band in [_band_or_default(long_band, 0), _band_or_default(mid_band, 1), _band_or_default(short_band, 2)]:
		variance += band.significant_wave_height_m * band.significant_wave_height_m
	return sqrt(variance)


func _band_or_default(value: Resource, index: int) -> Resource:
	if value != null:
		return value
	var fallback = BandScript.new()
	match index:
		0:
			fallback.min_wavelength_m = 16.0
			fallback.max_wavelength_m = 128.0
			fallback.transition_width_m = 4.0
			fallback.fetch_length_m = 25000.0
			fallback.swell = 0.8
			fallback.jonswap_spread = 0.05
		1:
			fallback.min_wavelength_m = 4.0
			fallback.max_wavelength_m = 20.0
		2:
			fallback.min_wavelength_m = 0.5
			fallback.max_wavelength_m = 5.0
			fallback.transition_width_m = 0.15
			fallback.fetch_length_m = 300.0
			fallback.swell = 0.15
			fallback.jonswap_spread = 0.75
	return fallback
