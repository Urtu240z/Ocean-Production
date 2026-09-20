@tool
class_name OceanCausticsProfile
extends Resource
## Authoring values for the Ocean Lab caustics signal.
## This resource never owns RenderingDevice resources.

@export_group("Pattern")
@export var texture: Texture2D:
	set(value): texture = value; emit_changed()
## World-space pattern size in metres. Tiling is 1.0 / scale_m.
@export_range(0.05, 50.0, 0.01, "suffix: m") var scale_m := 4.0:
	set(value): scale_m = clampf(value, 0.05, 50.0); emit_changed()
@export_range(0.0, 8.0, 0.01) var strength := 1.0:
	set(value): strength = clampf(value, 0.0, 8.0); emit_changed()
@export_range(0.25, 8.0, 0.01) var power := 2.0:
	set(value): power = clampf(value, 0.25, 8.0); emit_changed()

@export_group("Animation")
@export_range(-5.0, 5.0, 0.001) var speed := 0.1:
	set(value): speed = clampf(value, -5.0, 5.0); emit_changed()

@export_group("Chromatic")
@export_range(0.0, 0.02, 0.0001) var chroma_split := 0.002:
	set(value): chroma_split = clampf(value, 0.0, 0.02); emit_changed()

@export_group("Layers")
@export_range(-4.0, 4.0, 0.01) var layer_a_speed_multiplier := 0.75:
	set(value): layer_a_speed_multiplier = clampf(value, -4.0, 4.0); emit_changed()
@export_range(-4.0, 4.0, 0.01) var layer_b_speed_multiplier := 1.0:
	set(value): layer_b_speed_multiplier = clampf(value, -4.0, 4.0); emit_changed()
@export_range(-4.0, 4.0, 0.01) var layer_a_scale_multiplier := 1.0:
	set(value): layer_a_scale_multiplier = clampf(value, -4.0, 4.0); emit_changed()
@export_range(-4.0, 4.0, 0.01) var layer_b_scale_multiplier := -1.0:
	set(value): layer_b_scale_multiplier = clampf(value, -4.0, 4.0); emit_changed()
@export var layer_a_direction := Vector2(1.0, 0.0):
	set(value): layer_a_direction = value; emit_changed()
@export var layer_b_direction := Vector2(1.0, 0.0):
	set(value): layer_b_direction = value; emit_changed()

@export_group("Lighting")
@export var luma_gradient: Texture2D:
	set(value): luma_gradient = value; emit_changed()
@export_range(-2.0, 2.0, 0.01) var luminance_mask_strength := 0.2:
	set(value): luminance_mask_strength = clampf(value, -2.0, 2.0); emit_changed()
@export_range(0.0, 1.0, 0.01) var sun_strength := 1.0:
	set(value): sun_strength = clampf(value, 0.0, 1.0); emit_changed()

@export_group("Depth")
@export_range(0.0, 20.0, 0.1, "suffix: m") var fade_start_depth_m := 4.0:
	set(value): fade_start_depth_m = clampf(value, 0.0, 20.0); emit_changed()
@export_range(0.1, 50.0, 0.1, "suffix: m") var max_depth_m := 6.0:
	set(value): max_depth_m = clampf(value, 0.1, 50.0); emit_changed()

@export_group("Surface")
## Positive values move the caustics cutoff downward below the FFT surface.
@export_range(-1.0, 1.0, 0.01, "suffix: m") var caustics_surface_offset := 0.0:
	set(value): caustics_surface_offset = clampf(value, -1.0, 1.0); emit_changed()
@export_range(0.0, 2.0, 0.01, "suffix: m") var caustics_surface_fade_distance := 0.15:
	set(value): caustics_surface_fade_distance = clampf(value, 0.0, 2.0); emit_changed()

@export_group("Debug")
@export_enum("NONE", "FINAL") var debug_mode := 0:
	set(value): debug_mode = clampi(value, 0, 1); emit_changed()
