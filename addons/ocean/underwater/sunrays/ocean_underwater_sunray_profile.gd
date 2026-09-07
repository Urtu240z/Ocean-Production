@tool
class_name OceanUnderwaterSunrayProfile
extends Resource
## Authoring surface for the Ocean V3 procedural, light-space sunray field.
## The compositor owns the render implementation; this resource only publishes values.

@export_group("Beam Field")
@export_range(0.0, 1.0, 0.01) var strength := 0.35:
	set(value): strength = clampf(value, 0.0, 1.0); emit_changed()
@export_color_no_alpha var color := Color(0.78, 0.95, 1.0, 1.0):
	set(value): color = value; emit_changed()
@export_range(0.0, 0.95, 0.01) var anisotropy := 0.72:
	set(value): anisotropy = clampf(value, 0.0, 0.95); emit_changed()
@export_range(0.0, 2.0, 0.01) var density := 0.08:
	set(value): density = clampf(value, 0.0, 2.0); emit_changed()
@export_range(1.0, 100.0, 1.0, "suffix: m") var max_distance_m := 30.0:
	set(value): max_distance_m = clampf(value, 1.0, 100.0); emit_changed()
@export_range(0.0, 1.0, 0.01) var length_variation := 0.70:
	set(value): length_variation = clampf(value, 0.0, 1.0); emit_changed()
@export_range(0.05, 10.0, 0.05, "suffix:x") var pattern_scale := 1.0:
	set(value): pattern_scale = clampf(value, 0.05, 10.0); emit_changed()
@export_range(0.0, 4.0, 0.05) var pattern_contrast := 1.4:
	set(value): pattern_contrast = clampf(value, 0.0, 4.0); emit_changed()
## Retained for V3 profile compatibility. The selected pre-lattice V3 shader did
## not consume this export, so Production deliberately does not invent drift.
@export_range(0.0, 2.0, 0.01, "suffix:x") var animation_speed := 0.12:
	set(value): animation_speed = clampf(value, 0.0, 2.0); emit_changed()

@export_group("Surface Wave Modulation")
@export var wave_modulation_enabled := true:
	set(value): wave_modulation_enabled = value; emit_changed()
@export_range(0.0, 10.0, 0.01, "suffix:x") var wave_animation_speed := 1.50:
	set(value): wave_animation_speed = clampf(value, 0.0, 10.0); emit_changed()
@export var wave_freeze := false:
	set(value): wave_freeze = value; emit_changed()
@export_range(0.0, 0.45, 0.01) var wave_intensity_strength := 0.35:
	set(value): wave_intensity_strength = clampf(value, 0.0, 0.45); emit_changed()
@export_range(0.0, 0.20, 0.01) var wave_width_strength := 0.10:
	set(value): wave_width_strength = clampf(value, 0.0, 0.20); emit_changed()
@export_range(1.0, 50.0, 0.5, "suffix: m") var wave_depth_fade_m := 15.0:
	set(value): wave_depth_fade_m = clampf(value, 1.0, 50.0); emit_changed()
@export var phase_debug_constant := false:
	set(value): phase_debug_constant = value; emit_changed()

@export_group("Segment")
## Analytic is the Production default: the slab segment follows the sea plane
## without inheriting a finite camera-centred region.
@export_enum("CURRENT_DEPTH_DRIVEN", "ANALYTIC_SEA_PLANE") var segment_mode := 1:
	set(value): segment_mode = clampi(value, 0, 1); emit_changed()

@export_group("Debug")
@export_enum("FINAL", "BEAM_FIELD", "SUN_DIRECTION", "WAVE_MODULATION", "SUNRAY_CONTRIBUTION") var debug_mode := 0:
	set(value): debug_mode = clampi(value, 0, 4); emit_changed()
