@tool
class_name OceanLocalSeaState
extends Resource
const BandProfile := preload("res://addons/ocean/core/ocean_wave_band_profile.gd")
## Shared FFT settings. A null wave_profile inherits the host Ocean's spectrum.
@export var state_name := "Sheltered water":
	set(value):
		if state_name == value: return
		state_name = value
		emit_changed()
@export var wave_profile: Resource:
	set(value):
		if wave_profile == value: return
		if wave_profile != null and wave_profile.changed.is_connected(emit_changed): wave_profile.changed.disconnect(emit_changed)
		wave_profile = value
		if wave_profile != null: wave_profile.changed.connect(emit_changed)
		emit_changed()
@export_group("Ocean Space")
@export_range(0.25,4.0,0.01) var ocean_scale := 1.0:
	set(value):
		if ocean_scale == value: return
		ocean_scale = value
		emit_changed()
@export_range(0.25,4.0,0.01) var clipmap_geometry_scale := 1.0:
	set(value):
		if clipmap_geometry_scale == value: return
		clipmap_geometry_scale = value
		emit_changed()
@export_group("Sea State")
@export_enum("WIND_DRIVEN", "MANUAL_HS") var sea_state_mode := 0:
	set(value):
		if sea_state_mode == value: return
		sea_state_mode = value
		emit_changed()
@export_range(0.0,15.0,0.01,"suffix:m") var significant_wave_height_m := 0.25:
	set(value):
		if significant_wave_height_m == value: return
		significant_wave_height_m = value
		emit_changed()
@export_range(0.0,3.0,0.01) var wave_height_scale := 0.5:
	set(value):
		if wave_height_scale == value: return
		wave_height_scale = value
		emit_changed()
@export_range(0.0,3.0,0.01) var wave_speed_multiplier := 1.0:
	set(value):
		if wave_speed_multiplier == value: return
		wave_speed_multiplier = value
		emit_changed()
@export_range(0.0,60.0,0.1,"suffix:m/s") var wind_speed_mps := 3.0:
	set(value):
		if wind_speed_mps == value: return
		wind_speed_mps = value
		emit_changed()
@export_range(-180.0,180.0,0.1,"suffix:deg") var wind_direction_degrees := 5.71:
	set(value):
		if wind_direction_degrees == value: return
		wind_direction_degrees = value
		emit_changed()
@export_range(0.0,1.0,0.01) var swell := 0.15:
	set(value):
		if swell == value: return
		swell = value
		emit_changed()
@export_group("Wave Structure")
@export_range(0.5,2.5,0.01) var long_wave_spacing := 1.0:
	set(value):
		if long_wave_spacing == value: return
		long_wave_spacing = value
		emit_changed()
@export_range(0.0,1.5,0.01) var mid_fill_amount := 1.0:
	set(value):
		if mid_fill_amount == value: return
		mid_fill_amount = value
		emit_changed()
@export_range(0.0,3.0,0.01) var long_band_scale := 1.0:
	set(value):
		if long_band_scale == value: return
		long_band_scale = value
		emit_changed()
@export_range(0.0,3.0,0.01) var mid_band_scale := 1.0:
	set(value):
		if mid_band_scale == value: return
		mid_band_scale = value
		emit_changed()
@export_range(0.0,3.0,0.01) var short_band_scale := 1.0:
	set(value):
		if short_band_scale == value: return
		short_band_scale = value
		emit_changed()
## Multiplies the profile's actual FFT choppiness in all three bands.
@export_range(0.0,2.0,0.01) var choppiness_scale := 1.0:
	set(value):
		if choppiness_scale == value: return
		choppiness_scale = value
		emit_changed()

func fingerprint(profile: Resource, seed: int) -> int:
	return hash(fingerprint_values(profile,seed))


func fingerprint_values(profile: Resource, seed: int) -> Array:
	# Read live values on every call, including same-tick edits. Only the schema
	# is explicit: avoid allocating inspector property Dictionaries every tick.
	# Keep the original order and Variant types so signatures remain identical.
	var values: Array = [seed]
	if get_script().get_base_script() == null:
		values.append_array([wave_profile,sea_state_mode,significant_wave_height_m,
			wave_height_scale,wind_speed_mps,wind_direction_degrees,swell,
			long_wave_spacing,mid_fill_amount,long_band_scale,mid_band_scale,
			short_band_scale,choppiness_scale])
	else:
		# Custom settings can add script fields; retain their original contract.
		for property in get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.name not in ["state_name","wave_speed_multiplier","ocean_scale","clipmap_geometry_scale"]:
				values.append(get(property.name))
	for band in [profile.long_band,profile.mid_band,profile.short_band]:
		if band == null: continue
		if band.get_script() == BandProfile:
			values.append_array(band.fingerprint_values())
		else:
			for property in band.get_property_list():
				if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE: values.append(band.get(property.name))
	values.append(profile.wind_speed_mps)
	return values
