extends RefCounted
## Wet heave approximation only; physical mass, hydrostatics and yaw stay intact.

static func heave_response(mass_kg: float, displaced_water_mass_kg: float,
		net_water_vertical_force_n: float, relative_vertical_speed_mps: float,
		added_mass_coefficient: float, resistance_rate_per_s: float, delta_s: float) -> Dictionary:
	var result := {"added_mass_kg": 0.0, "drag_force_n": 0.0,
		"inertia_force_n": 0.0, "force_n": 0.0, "acceleration_scale": 1.0}
	for value in [mass_kg, displaced_water_mass_kg, net_water_vertical_force_n,
			relative_vertical_speed_mps, added_mass_coefficient, resistance_rate_per_s, delta_s]:
		if not is_finite(value):
			return result
	if mass_kg <= 0.0 or displaced_water_mass_kg <= 0.000001 or delta_s <= 0.0:
		return result
	var added_mass := displaced_water_mass_kg * maxf(added_mass_coefficient, 0.0)
	var effective_mass := mass_kg + added_mass
	# Instantaneous relative-water drag. The cap prevents this extra damper from
	# consuming more than 25% of relative heave velocity in one physics step.
	var coefficient := minf(displaced_water_mass_kg * maxf(resistance_rate_per_s, 0.0),
		0.25 * effective_mass / delta_s)
	var drag := -coefficient * relative_vertical_speed_mps
	var acceleration_scale := mass_kg / effective_mass
	# m*a = F_water + m*g + F_drag - m_added*a, solved algebraically.
	# Including gravity keeps the old hydrostatic equilibrium exactly unchanged.
	# This affects only wet water-driven heave, not engine/control forces.
	var inertia_force := -(1.0 - acceleration_scale) * (net_water_vertical_force_n + drag)
	result.added_mass_kg = added_mass
	result.drag_force_n = drag
	result.inertia_force_n = inertia_force
	result.force_n = drag + inertia_force
	result.acceleration_scale = acceleration_scale
	return result
