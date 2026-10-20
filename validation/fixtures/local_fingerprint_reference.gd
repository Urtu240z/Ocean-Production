extends RefCounted
## Original reflection path, retained only for exact parity and A/B validation.
static func values(settings: Resource, profile: Resource, seed: int) -> Array:
	var result: Array = [seed]
	for property in settings.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.name not in ["state_name","wave_speed_multiplier","ocean_scale","clipmap_geometry_scale"]:
			result.append(settings.get(property.name))
	for band in [profile.long_band,profile.mid_band,profile.short_band]:
		if band == null: continue
		for property in band.get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE: result.append(band.get(property.name))
	result.append(profile.wind_speed_mps)
	return result

static func fingerprint(settings: Resource, profile: Resource, seed: int) -> int:
	return hash(values(settings,profile,seed))
