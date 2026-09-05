@tool
class_name OceanReflectionProfile
extends Resource
## Compact P5 authoring surface. Defaults are the effective V3 Lab values.

@export_group("Authoring")
@export_range(0.0, 1.0, 0.01) var base_roughness := 0.08:
	set(value):
		base_roughness = value
		emit_changed()
@export var roughness_distance_m := Vector2(80.0, 300.0):
	set(value):
		roughness_distance_m = value
		emit_changed()
@export_range(0.25, 1.0, 0.05) var sspr_resolution_scale := 0.40:
	set(value):
		sspr_resolution_scale = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var distortion_strength := 1.0:
	set(value):
		distortion_strength = value
		emit_changed()
@export_range(0.0, 0.25, 0.005) var edge_fade := 0.25:
	set(value):
		edge_fade = value
		emit_changed()
@export_range(-2.0, 2.0, 0.05) var radiance_exposure_ev := -1.5:
	set(value):
		radiance_exposure_ev = value
		emit_changed()
@export_range(0.0, 2.0, 0.01) var radiance_saturation := 0.36:
	set(value):
		radiance_saturation = value
		emit_changed()
@export_range(0.0, 1.5, 0.01) var screen_space_weight := 0.55:
	set(value):
		screen_space_weight = value
		emit_changed()
@export_range(0.5, 2.0, 0.01) var environment_specular_boost := 0.65:
	set(value):
		environment_specular_boost = value
		emit_changed()

@export_group("Advanced")
@export var temporal_enabled := true:
	set(value):
		temporal_enabled = value
		emit_changed()
@export_range(0.0, 0.5, 0.01) var temporal_weight := 0.12:
	set(value):
		temporal_weight = value
		emit_changed()
@export_range(0.001, 0.25, 0.001) var temporal_depth_threshold := 0.035:
	set(value):
		temporal_depth_threshold = value
		emit_changed()

@export_group("Internal")
@export var kawase_enabled := false:
	set(value):
		kawase_enabled = value
		emit_changed()
@export var near_ssr_enabled := false:
	set(value):
		near_ssr_enabled = value
		emit_changed()
