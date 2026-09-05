@tool
class_name OceanOpticsProfile
extends Resource
## Compact P4 above-water authoring values promoted from the active V3 route.

@export_group("Water body")
@export_color_no_alpha var shallow_water_color := Color(0.19490916, 0.38508072, 0.3838458):
	set(value): shallow_water_color = value; emit_changed()
@export_color_no_alpha var deep_water_color := Color(0.019474017, 0.0909042, 0.088472255):
	set(value): deep_water_color = value; emit_changed()
@export_color_no_alpha var horizon_water_color := Color(0.0075189536, 0.07750165, 0.04554274):
	set(value): horizon_water_color = value; emit_changed()
@export_color_no_alpha var trough_tint := Color(0.005060052, 0.04589343, 0.02705579):
	set(value): trough_tint = value; emit_changed()
@export_color_no_alpha var crest_tint := Color(0.022200117, 0.15144762, 0.1125462):
	set(value): crest_tint = value; emit_changed()
@export var absorption_coeff_rgb := Vector3(0.35, 0.14, 0.10):
	set(value): absorption_coeff_rgb = value; emit_changed()
@export_range(1.0, 100.0, 0.5, "suffix:m") var maximum_optical_depth_above_m := 48.0:
	set(value): maximum_optical_depth_above_m = value; emit_changed()
@export_range(0.0, 20.0, 0.1, "suffix:m") var water_body_depth_start_m := 0.7:
	set(value): water_body_depth_start_m = value; emit_changed()
@export_range(0.1, 50.0, 0.1, "suffix:m") var water_body_depth_end_m := 26.0:
	set(value): water_body_depth_end_m = value; emit_changed()
@export_range(0.0, 500.0, 1.0, "suffix:m") var opacity_distance_start := 80.0:
	set(value): opacity_distance_start = value; emit_changed()
@export_range(1.0, 1000.0, 1.0, "suffix:m") var opacity_distance_end := 1000.0:
	set(value): opacity_distance_end = value; emit_changed()

@export_group("Refraction")
@export_range(0.0, 0.5, 0.01) var refraction_micro_normal_strength := 0.15:
	set(value): refraction_micro_normal_strength = value; emit_changed()
@export_range(0.0, 64.0, 1.0, "suffix:px") var refraction_max_offset_px := 24.0:
	set(value): refraction_max_offset_px = value; emit_changed()
@export_range(0.0, 2.0, 0.01, "suffix:m") var refraction_depth_tolerance_m := 0.35:
	set(value): refraction_depth_tolerance_m = value; emit_changed()
@export_range(0.0, 20.0, 0.01) var refraction_wave_strength := 1.0:
	set(value): refraction_wave_strength = value; emit_changed()
@export_range(0.0, 20.0, 0.01) var refraction_long_weight := 1.0:
	set(value): refraction_long_weight = value; emit_changed()
@export_range(0.0, 20.0, 0.01) var refraction_mid_weight := 3.0:
	set(value): refraction_mid_weight = value; emit_changed()
@export_range(0.0, 20.0, 0.01) var refraction_short_weight := 2.0:
	set(value): refraction_short_weight = value; emit_changed()
@export_range(0.0, 50.0, 0.1, "suffix:m") var refraction_depth_start_m := 1.0:
	set(value): refraction_depth_start_m = value; emit_changed()
@export_range(0.1, 100.0, 0.1, "suffix:m") var refraction_depth_end_m := 38.0:
	set(value): refraction_depth_end_m = value; emit_changed()

@export_group("Scattering")
@export_color_no_alpha var scattering_color := Color(0.02, 0.32, 0.42):
	set(value): scattering_color = value; emit_changed()
@export_range(0.0, 2.0, 0.01) var scattering_strength := 0.45:
	set(value): scattering_strength = value; emit_changed()
@export_range(0.0, 1.0, 0.01) var scattering_shallow_tint_influence := 1.0:
	set(value): scattering_shallow_tint_influence = value; emit_changed()
@export_range(0.0, 1.0, 0.01) var scattering_deep_tint_influence := 0.15:
	set(value): scattering_deep_tint_influence = value; emit_changed()
@export_range(0.0, 2.0, 0.01) var shallow_scattering_strength := 0.5:
	set(value): shallow_scattering_strength = value; emit_changed()
@export_range(0.0, 20.0, 0.1, "suffix:m") var shallow_scattering_depth_start_m := 1.0:
	set(value): shallow_scattering_depth_start_m = value; emit_changed()
@export_range(0.1, 30.0, 0.1, "suffix:m") var shallow_scattering_depth_end_m := 8.0:
	set(value): shallow_scattering_depth_end_m = value; emit_changed()
@export_range(0.0, 2.0, 0.01) var water_turbidity := 0.35:
	set(value): water_turbidity = value; emit_changed()
@export_range(0.0, 0.5, 0.01) var crest_transmission_boost := 0.12:
	set(value): crest_transmission_boost = value; emit_changed()
@export_range(0.0, 0.5, 0.01) var trough_density_boost := 0.10:
	set(value): trough_density_boost = value; emit_changed()
@export_range(0.0, 100.0, 0.5, "suffix:m") var transmission_detail_fade_start_m := 7.0:
	set(value): transmission_detail_fade_start_m = value; emit_changed()
@export_range(1.0, 150.0, 0.5, "suffix:m") var transmission_detail_fade_end_m := 46.5:
	set(value): transmission_detail_fade_end_m = value; emit_changed()
@export_range(0.0, 8.0, 0.1) var transmission_max_lod := 5.0:
	set(value): transmission_max_lod = value; emit_changed()

@export_group("Seabed transmission")
@export_range(0.0, 50.0, 0.5, "suffix:m") var bottom_visibility_fade_start_m := 5.0:
	set(value): bottom_visibility_fade_start_m = value; emit_changed()
@export_range(0.1, 100.0, 0.5, "suffix:m") var bottom_visibility_fade_end_m := 41.1:
	set(value): bottom_visibility_fade_end_m = value; emit_changed()
@export_range(0.0, 20.0, 0.25, "suffix:m") var seabed_match_tolerance_start_m := 0.0:
	set(value): seabed_match_tolerance_start_m = value; emit_changed()
@export_range(0.1, 50.0, 0.25, "suffix:m") var seabed_match_tolerance_end_m := 22.85:
	set(value): seabed_match_tolerance_end_m = value; emit_changed()

@export_group("Shallow surface relief")
@export_range(0.0, 1.0, 0.01) var shallow_fresnel_relief := 0.58:
	set(value): shallow_fresnel_relief = value; emit_changed()
@export_range(0.0, 50.0, 0.1, "suffix:m") var shallow_fresnel_depth_start_m := 1.5:
	set(value): shallow_fresnel_depth_start_m = value; emit_changed()
@export_range(0.1, 100.0, 0.1, "suffix:m") var shallow_fresnel_depth_end_m := 48.6:
	set(value): shallow_fresnel_depth_end_m = value; emit_changed()
