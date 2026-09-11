@tool
class_name OceanBreakerProfile
extends Resource
## P7 authoring values for Coastal LONG breaker deformation and lip geometry.

@export_group("Detection")
@export_range(0.0, 2.0, 0.01) var strength := 0.85:
	set(value):
		strength = clampf(value, 0.0, 2.0)
		emit_changed()
@export_range(0.0, 20.0, 0.05, "suffix:m") var shallow_fade_start_m := 0.35:
	set(value):
		shallow_fade_start_m = maxf(value, 0.0)
		emit_changed()
@export_range(0.05, 30.0, 0.05, "suffix:m") var shallow_fade_end_m := 1.20:
	set(value):
		shallow_fade_end_m = maxf(value, shallow_fade_start_m + 0.001)
		emit_changed()
@export_range(0.1, 100.0, 0.1, "suffix:m") var deep_activation_start_m := 4.0:
	set(value):
		deep_activation_start_m = maxf(value, shallow_fade_end_m)
		emit_changed()
@export_range(0.2, 150.0, 0.1, "suffix:m") var deep_activation_end_m := 14.0:
	set(value):
		deep_activation_end_m = maxf(value, deep_activation_start_m + 0.001)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var shoaling_start := 1.05:
	set(value):
		shoaling_start = maxf(value, 0.0)
		emit_changed()
@export_range(0.01, 6.0, 0.01) var shoaling_full := 1.30:
	set(value):
		shoaling_full = maxf(value, shoaling_start + 0.001)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var detj_compression_start := 0.92:
	set(value):
		detj_compression_start = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var detj_compression_full := 0.65:
	set(value):
		detj_compression_full = clampf(value, 0.0, detj_compression_start)
		emit_changed()
@export_range(0.0, 8.0, 0.01, "suffix:m") var crest_height_start_m := 0.20:
	set(value):
		crest_height_start_m = maxf(value, 0.0)
		emit_changed()
@export_range(0.01, 12.0, 0.01, "suffix:m") var crest_height_full_m := 1.00:
	set(value):
		crest_height_full_m = maxf(value, crest_height_start_m + 0.001)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var front_slope_start := 0.12:
	set(value):
		front_slope_start = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var front_slope_full := 0.55:
	set(value):
		front_slope_full = maxf(value, front_slope_start + 0.001)
		emit_changed()

@export_group("Shape")
@export_range(0.0, 0.30, 0.005) var forward_push_fraction := 0.045:
	set(value):
		forward_push_fraction = clampf(value, 0.0, 0.30)
		emit_changed()
@export_range(0.0, 0.30, 0.005) var face_compression_fraction := 0.030:
	set(value):
		face_compression_fraction = clampf(value, 0.0, 0.30)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var crest_lift_scale := 0.25:
	set(value):
		crest_lift_scale = clampf(value, 0.0, 2.0)
		emit_changed()
@export_range(0.25, 4.0, 0.01) var crest_curve := 1.50:
	set(value):
		crest_curve = clampf(value, 0.25, 4.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var normal_follow_strength := 0.80:
	set(value):
		normal_follow_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var pre_lip_strength := 0.0:
	set(value):
		pre_lip_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 0.15, 0.005) var pre_lip_forward_fraction := 0.04:
	set(value):
		pre_lip_forward_fraction = clampf(value, 0.0, 0.15)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var pre_lip_lift_scale := 0.15:
	set(value):
		pre_lip_lift_scale = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var lip_strength := 0.0:
	set(value):
		lip_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 0.20, 0.005) var lip_forward_fraction := 0.06:
	set(value):
		lip_forward_fraction = clampf(value, 0.0, 0.20)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var lip_drop_scale := 0.35:
	set(value):
		lip_drop_scale = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Safety")
@export_range(0.01, 0.50, 0.005) var max_horizontal_fraction := 0.14:
	set(value):
		max_horizontal_fraction = clampf(value, 0.01, 0.50)
		emit_changed()
@export_range(0.0, 1.50, 0.01) var max_vertical_lift_scale := 0.45:
	set(value):
		max_vertical_lift_scale = clampf(value, 0.0, 1.50)
		emit_changed()
