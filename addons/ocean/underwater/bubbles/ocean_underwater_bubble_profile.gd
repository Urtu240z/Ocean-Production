@tool
class_name OceanUnderwaterBubbleProfile
extends Resource
## Authoring values for the local entrained-air volume. GPU ownership remains
## inside OceanUnderwaterBubbles on the render thread.

@export_group("Volume")
@export_range(8.0, 256.0, 1.0, "suffix:m") var volume_extent_xz_m := 64.0:
	set(value): volume_extent_xz_m = clampf(value, 8.0, 256.0); emit_changed()
@export_range(0.0, 32.0, 0.25, "suffix:m") var volume_top_above_sea_m := 6.0:
	set(value): volume_top_above_sea_m = clampf(value, 0.0, 32.0); emit_changed()
@export_range(1.0, 64.0, 0.25, "suffix:m") var volume_depth_below_sea_m := 12.0:
	set(value): volume_depth_below_sea_m = clampf(value, 1.0, 64.0); emit_changed()
@export_range(16, 192, 8) var resolution_x := 96:
	set(value): resolution_x = clampi(value, 16, 192); emit_changed()
@export_range(8, 96, 4) var resolution_y := 32:
	set(value): resolution_y = clampi(value, 8, 96); emit_changed()
@export_range(16, 192, 8) var resolution_z := 96:
	set(value): resolution_z = clampi(value, 16, 192); emit_changed()

@export_group("Simulation")
@export_range(1.0, 60.0, 1.0, "suffix:Hz") var simulation_hz := 30.0:
	set(value): simulation_hz = clampf(value, 1.0, 60.0); emit_changed()
@export_range(0.0, 8.0, 0.01) var injection_strength := 1.0:
	set(value): injection_strength = clampf(value, 0.0, 8.0); emit_changed()
@export_range(0.1, 8.0, 0.05, "suffix:m") var injection_depth_m := 2.5:
	set(value): injection_depth_m = clampf(value, 0.1, 8.0); emit_changed()
@export_range(0.0, 5.0, 0.01, "suffix:m/s") var downward_entrainment_mps := 1.0:
	set(value): downward_entrainment_mps = clampf(value, 0.0, 5.0); emit_changed()
@export_range(0.0, 3.0, 0.01, "suffix:m/s") var buoyancy_mps := 0.35:
	set(value): buoyancy_mps = clampf(value, 0.0, 3.0); emit_changed()
@export_range(0.0, 2.0, 0.01, "suffix:m/s") var horizontal_drift_mps := 0.20:
	set(value): horizontal_drift_mps = clampf(value, 0.0, 2.0); emit_changed()
@export_range(0.0, 5.0, 0.01, "suffix:m/s") var curl_strength_mps := 0.80:
	set(value): curl_strength_mps = clampf(value, 0.0, 5.0); emit_changed()
@export_range(0.25, 32.0, 0.05, "suffix:m") var curl_scale_m := 3.0:
	set(value): curl_scale_m = clampf(value, 0.25, 32.0); emit_changed()
@export_range(0.0, 2.0, 0.01) var curl_time_scale := 0.20:
	set(value): curl_time_scale = clampf(value, 0.0, 2.0); emit_changed()
@export_range(0.0, 0.25, 0.005) var diffusion := 0.04:
	set(value): diffusion = clampf(value, 0.0, 0.25); emit_changed()
@export_range(0.1, 30.0, 0.1, "suffix:s") var decay_half_life_s := 5.0:
	set(value): decay_half_life_s = clampf(value, 0.1, 30.0); emit_changed()
@export_range(0.01, 4.0, 0.01) var max_density := 1.0:
	set(value): max_density = clampf(value, 0.01, 4.0); emit_changed()

@export_group("Render")
@export_range(0.0, 5.0, 0.01) var scatter_strength := 1.25:
	set(value): scatter_strength = clampf(value, 0.0, 5.0); emit_changed()
@export_range(0.0, 5.0, 0.01) var extinction_strength := 1.0:
	set(value): extinction_strength = clampf(value, 0.0, 5.0); emit_changed()
@export_color_no_alpha var bubble_tint := Color(0.92, 0.985, 1.0):
	set(value): bubble_tint = value; emit_changed()
@export_range(0.1, 3.0, 0.01) var density_gamma := 0.8:
	set(value): density_gamma = clampf(value, 0.1, 3.0); emit_changed()
@export_range(1, 64, 1) var march_steps := 12:
	set(value): march_steps = clampi(value, 1, 64); emit_changed()

@export_group("Debug")
## 0 final, 1 integrated density, 2 current FFT breaking source.
@export_enum("Final", "Integrated Bubble Density", "Injection Source") var debug_mode := 0:
	set(value): debug_mode = clampi(value, 0, 2); emit_changed()
@export var freeze_simulation := false:
	set(value): freeze_simulation = value; emit_changed()
