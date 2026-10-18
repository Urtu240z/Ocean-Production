@tool
class_name OceanLocalSeaState
extends Resource
## Shared FFT settings. A null wave_profile inherits the host Ocean's spectrum.
@export var state_name := "Sheltered water"
@export var wave_profile: Resource
@export_group("Ocean Space")
@export_range(0.25,4.0,0.01) var ocean_scale := 1.0
@export_range(0.25,4.0,0.01) var clipmap_geometry_scale := 1.0
@export_group("Sea State")
@export_enum("WIND_DRIVEN", "MANUAL_HS") var sea_state_mode := 0
@export_range(0.0,15.0,0.01,"suffix:m") var significant_wave_height_m := 0.25
@export_range(0.0,3.0,0.01) var wave_height_scale := 0.5
@export_range(0.0,3.0,0.01) var wave_speed_multiplier := 1.0
@export_range(0.0,60.0,0.1,"suffix:m/s") var wind_speed_mps := 3.0
@export_range(-180.0,180.0,0.1,"suffix:deg") var wind_direction_degrees := 5.71
@export_range(0.0,1.0,0.01) var swell := 0.15
@export_group("Wave Structure")
@export_range(0.5,2.5,0.01) var long_wave_spacing := 1.0
@export_range(0.0,1.5,0.01) var mid_fill_amount := 1.0
@export_range(0.0,3.0,0.01) var long_band_scale := 1.0
@export_range(0.0,3.0,0.01) var mid_band_scale := 1.0
@export_range(0.0,3.0,0.01) var short_band_scale := 1.0
## Multiplies the profile's actual FFT choppiness in all three bands.
@export_range(0.0,2.0,0.01) var choppiness_scale := 1.0

func fingerprint(profile: Resource, seed: int) -> int:
	var values: Array = [seed]
	for property in get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.name not in ["state_name","wave_speed_multiplier","ocean_scale","clipmap_geometry_scale"]:
			values.append(get(property.name))
	for band in [profile.long_band,profile.mid_band,profile.short_band]:
		if band == null: continue
		for property in band.get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE: values.append(band.get(property.name))
	values.append(profile.wind_speed_mps)
	return hash(values)
