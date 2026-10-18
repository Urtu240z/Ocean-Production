@tool
class_name OceanReflectionProfile
extends Resource
## Compact P5 authoring surface. Defaults are the effective V3 Lab values.

enum ReflectionMode { SCREEN_SPACE, PLANAR }
@export_group("Reflection Method")
## Planar renders the scene again from a mirrored camera, including off-screen objects.
@export var reflection_mode: ReflectionMode = ReflectionMode.SCREEN_SPACE:
	set(value):
		reflection_mode = value
		emit_changed()
@export_range(0.25, 1.0, 0.05) var planar_resolution_scale := 0.5:
	set(value):
		planar_resolution_scale = clampf(value, 0.25, 1.0)
		emit_changed()
## Use scene render layers to omit underwater geometry or expensive effects.
@export_flags_3d_render var planar_cull_mask: int = 1048575:
	set(value):
		planar_cull_mask = value
		emit_changed()

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
@export_group("Environment Specular")
@export_range(0.0, 2.0, 0.01, "or_greater") var environment_specular_near_boost := 0.65:
	set(value):
		environment_specular_near_boost = value
		emit_changed()
@export_range(0.0, 2.0, 0.01, "or_greater") var environment_specular_far_boost := 0.65:
	set(value):
		environment_specular_far_boost = value
		emit_changed()
@export_range(0.0, 500.0, 0.1, "suffix:m") var environment_specular_near_distance := 20.0:
	set(value):
		environment_specular_near_distance = value
		emit_changed()
@export_range(0.0, 500.0, 0.1, "suffix:m") var environment_specular_far_distance := 80.0:
	set(value):
		environment_specular_far_distance = value
		emit_changed()

@export_group("Low light reflections")
## Multiplies the existing specular response only in low light. Does not add
## emission, a brightness floor, or change the camera exposure. 1 disables it.
@export_range(1.0, 3.0, 0.01) var low_light_reflection_boost := 1.5:
	set(value): low_light_reflection_boost = clampf(value, 1.0, 3.0); emit_changed()
## Full daylight response resumes at this directional irradiance (linear).
@export_range(0.01, 4.0, 0.01) var low_light_reference_energy := 0.5:
	set(value): low_light_reference_energy = maxf(value, 0.01); emit_changed()

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
