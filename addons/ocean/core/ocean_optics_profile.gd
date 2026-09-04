class_name OceanOpticsProfile
extends Resource
## Compact P4 above-water authoring values promoted from the active V3 route.

@export_group("Water body")
@export_color_no_alpha var shallow_water_color := Color(0.19490916, 0.38508072, 0.3838458)
@export_color_no_alpha var deep_water_color := Color(0.019474017, 0.0909042, 0.088472255)
@export_color_no_alpha var horizon_water_color := Color(0.0075189536, 0.07750165, 0.04554274)
@export_color_no_alpha var trough_tint := Color(0.005060052, 0.04589343, 0.02705579)
@export_color_no_alpha var crest_tint := Color(0.022200117, 0.15144762, 0.1125462)
@export var absorption_coeff_rgb := Vector3(0.35, 0.14, 0.10)
@export_range(1.0, 100.0, 0.5, "suffix:m") var maximum_optical_depth_above_m := 48.0
@export_range(0.0, 20.0, 0.1, "suffix:m") var water_body_depth_start_m := 0.7
@export_range(0.1, 50.0, 0.1, "suffix:m") var water_body_depth_end_m := 26.0
@export_range(1.0, 1000.0, 1.0, "suffix:m") var opacity_distance_end := 1000.0

@export_group("Refraction")
@export_range(0.0, 0.5, 0.01) var refraction_micro_normal_strength := 0.15
@export_range(0.0, 64.0, 1.0, "suffix:px") var refraction_max_offset_px := 24.0
@export_range(0.0, 2.0, 0.01, "suffix:m") var refraction_depth_tolerance_m := 0.35
@export_range(0.0, 20.0, 0.01) var refraction_wave_strength := 1.0
@export_range(0.0, 20.0, 0.01) var refraction_long_weight := 1.0
@export_range(0.0, 20.0, 0.01) var refraction_mid_weight := 3.0
@export_range(0.0, 20.0, 0.01) var refraction_short_weight := 2.0
@export_range(0.1, 100.0, 0.1, "suffix:m") var refraction_depth_end_m := 38.0

@export_group("Scattering")
@export_color_no_alpha var scattering_color := Color(0.02, 0.32, 0.42)
@export_range(0.0, 2.0, 0.01) var scattering_strength := 0.45
@export_range(0.0, 2.0, 0.01) var shallow_scattering_strength := 0.5
@export_range(0.0, 2.0, 0.01) var water_turbidity := 0.35
@export_range(0.0, 0.5, 0.01) var crest_transmission_boost := 0.12
@export_range(0.0, 0.5, 0.01) var trough_density_boost := 0.10
@export_range(0.0, 100.0, 0.5, "suffix:m") var transmission_detail_fade_start_m := 7.0
@export_range(1.0, 150.0, 0.5, "suffix:m") var transmission_detail_fade_end_m := 46.5
@export_range(0.0, 8.0, 0.1) var transmission_max_lod := 5.0
