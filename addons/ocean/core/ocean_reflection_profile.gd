@tool
class_name OceanReflectionProfile
extends Resource
## Compact P5 authoring surface. Defaults are the effective V3 Lab values.

@export_group("Authoring")
@export_range(0.0, 1.0, 0.01) var base_roughness := 0.08
@export var roughness_distance_m := Vector2(80.0, 300.0)
@export_range(0.25, 1.0, 0.05) var sspr_resolution_scale := 0.40
@export_range(0.0, 1.0, 0.01) var distortion_strength := 1.0
@export_range(0.0, 0.25, 0.005) var edge_fade := 0.25
@export_range(-2.0, 2.0, 0.05) var radiance_exposure_ev := -1.5
@export_range(0.0, 2.0, 0.01) var radiance_saturation := 0.36
@export_range(0.0, 1.5, 0.01) var screen_space_weight := 0.55
@export_range(0.5, 2.0, 0.01) var environment_specular_boost := 0.65

@export_group("Advanced")
@export var temporal_enabled := true
@export_range(0.0, 0.5, 0.01) var temporal_weight := 0.12
@export_range(0.001, 0.25, 0.001) var temporal_depth_threshold := 0.035

@export_group("Internal")
@export var kawase_enabled := false
@export var near_ssr_enabled := false
