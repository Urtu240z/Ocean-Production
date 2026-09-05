@tool
class_name OceanUnderwaterMediumProfile
extends Resource
## P6 authoring values. This resource never owns RenderingDevice resources.

@export_group("Optical medium")
@export var absorption_coeff_rgb := Vector3(0.35, 0.14, 0.10):
	set(value):
		absorption_coeff_rgb = Vector3(maxf(value.x, 0.0), maxf(value.y, 0.0), maxf(value.z, 0.0))
		emit_changed()
@export_range(0.0, 4.0, 0.01) var absorption_scale := 0.43:
	set(value): absorption_scale = clampf(value, 0.0, 4.0); emit_changed()
@export_color_no_alpha var scattering_color := Color(0.0024315654, 0.09275196, 0.13127226):
	set(value): scattering_color = value; emit_changed()
@export_range(0.0, 4.0, 0.01) var scattering_strength := 1.0:
	set(value): scattering_strength = clampf(value, 0.0, 4.0); emit_changed()
@export_range(0.0, 2.0, 0.005) var scattering_density := 0.15:
	set(value): scattering_density = clampf(value, 0.0, 2.0); emit_changed()
@export_range(1.0, 500.0, 1.0, "suffix:m") var maximum_optical_distance_m := 120.0:
	set(value): maximum_optical_distance_m = clampf(value, 1.0, 500.0); emit_changed()

@export_group("Advanced")
@export_range(0.0, 1.0, 0.001, "suffix:m") var enter_margin_m := 0.05:
	set(value): enter_margin_m = clampf(value, 0.0, 1.0); emit_changed()
@export_range(0.0, 1.0, 0.001, "suffix:m") var exit_margin_m := 0.05:
	set(value): exit_margin_m = clampf(value, 0.0, 1.0); emit_changed()

@export_group("Waterline mask prototype")
## True shows the binary region mask. False applies P6 optics only to water pixels.
@export var waterline_mask_debug := false:
	set(value): waterline_mask_debug = value; emit_changed()
