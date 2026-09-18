@tool
class_name OceanSpindriftProfile
extends Resource
## Authoring profile for the optional Ocean V4 wind-blown crest spray.
## The controller owns the GPU particles; this resource only owns tunable values.

@export_group("Source")
@export_range(0.0, 1.0, 0.01) var breaking_trigger_threshold := 0.72:
	set(value):
		breaking_trigger_threshold = clampf(value, 0.0, 1.0)
		if breaking_rearm_threshold >= breaking_trigger_threshold:
			breaking_rearm_threshold = maxf(0.0, breaking_trigger_threshold - 0.01)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var breaking_rearm_threshold := 0.28:
	set(value):
		breaking_rearm_threshold = clampf(value, 0.0, 1.0)
		if breaking_rearm_threshold >= breaking_trigger_threshold:
			breaking_rearm_threshold = maxf(0.0, breaking_trigger_threshold - 0.01)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var emission_density := 0.72:
	set(value):
		emission_density = clampf(value, 0.0, 2.0)
		emit_changed()

@export_group("Storm / Wind")
@export_range(0.0, 1.0, 0.01) var storm_strength := 0.85:
	set(value):
		storm_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var wind_velocity_multiplier := 1.0:
	set(value):
		wind_velocity_multiplier = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var crest_kick := 0.42:
	set(value):
		crest_kick = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var horizontal_spread := 0.30:
	set(value):
		horizontal_spread = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var vertical_spread := 0.10:
	set(value):
		vertical_spread = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var turbulence_strength := 0.45:
	set(value):
		turbulence_strength = maxf(value, 0.0)
		emit_changed()
@export_range(0.01, 4.0, 0.01) var turbulence_scale := 0.16:
	set(value):
		turbulence_scale = maxf(value, 0.01)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var turbulence_speed := 1.35:
	set(value):
		turbulence_speed = maxf(value, 0.0)
		emit_changed()

@export_group("Region / LOD")
@export_range(8.0, 120.0, 1.0, "suffix:m") var spindrift_radius := 48.0:
	set(value):
		spindrift_radius = maxf(value, 8.0)
		emit_changed()
@export_range(1.0, 100.0, 1.0, "suffix:m") var chunks_lod_end_m := 22.0:
	set(value):
		chunks_lod_end_m = maxf(value, 1.0)
		emit_changed()
@export_range(1.0, 150.0, 1.0, "suffix:m") var streaks_lod_end_m := 55.0:
	set(value):
		streaks_lod_end_m = maxf(value, 1.0)
		emit_changed()
@export_range(1.0, 150.0, 1.0, "suffix:m") var mist_lod_end_m := 46.0:
	set(value):
		mist_lod_end_m = maxf(value, 1.0)
		emit_changed()

@export_group("Particle Budget")
@export_range(32, 1024, 32) var chunks_amount := 256:
	set(value):
		chunks_amount = maxi(value, 32)
		emit_changed()
@export_range(64, 2048, 64) var streaks_amount := 768:
	set(value):
		streaks_amount = maxi(value, 64)
		emit_changed()
@export_range(64, 2048, 64) var mist_amount := 512:
	set(value):
		mist_amount = maxi(value, 64)
		emit_changed()
@export_range(0.1, 2.0, 0.01, "suffix:s") var chunks_lifetime := 0.65:
	set(value):
		chunks_lifetime = maxf(value, 0.1)
		emit_changed()
@export_range(0.1, 3.0, 0.01, "suffix:s") var streaks_lifetime := 0.95:
	set(value):
		streaks_lifetime = maxf(value, 0.1)
		emit_changed()
@export_range(0.1, 3.0, 0.01, "suffix:s") var mist_lifetime := 1.15:
	set(value):
		mist_lifetime = maxf(value, 0.1)
		emit_changed()

@export_group("Art / Life Fade")
## Normalized lifetime fractions. A newborn particle fades in from zero over
## fade_in_fraction and fades out to zero at normalized age 1.0, starting at
## fade_out_start_fraction. Values are clamped so the two intervals can never
## reverse or collapse into a zero-width smoothstep.
@export_range(0.0, 0.5, 0.01) var chunks_fade_in_fraction := 0.07:
	set(value):
		chunks_fade_in_fraction = clampf(value, 0.0, 0.5)
		chunks_fade_out_start_fraction = maxf(chunks_fade_out_start_fraction, chunks_fade_in_fraction)
		emit_changed()
@export_range(0.0, 0.5, 0.01) var streaks_fade_in_fraction := 0.05:
	set(value):
		streaks_fade_in_fraction = clampf(value, 0.0, 0.5)
		streaks_fade_out_start_fraction = maxf(streaks_fade_out_start_fraction, streaks_fade_in_fraction)
		emit_changed()
@export_range(0.0, 0.5, 0.01) var mist_fade_in_fraction := 0.10:
	set(value):
		mist_fade_in_fraction = clampf(value, 0.0, 0.5)
		mist_fade_out_start_fraction = maxf(mist_fade_out_start_fraction, mist_fade_in_fraction)
		emit_changed()
@export_range(0.3, 1.0, 0.01) var chunks_fade_out_start_fraction := 0.70:
	set(value):
		chunks_fade_out_start_fraction = clampf(value, chunks_fade_in_fraction, 1.0)
		emit_changed()
@export_range(0.3, 1.0, 0.01) var streaks_fade_out_start_fraction := 0.72:
	set(value):
		streaks_fade_out_start_fraction = clampf(value, streaks_fade_in_fraction, 1.0)
		emit_changed()
@export_range(0.3, 1.0, 0.01) var mist_fade_out_start_fraction := 0.58:
	set(value):
		mist_fade_out_start_fraction = clampf(value, mist_fade_in_fraction, 1.0)
		emit_changed()

@export_group("Art / Water Contact")
## Height above sea level where the water fade reaches full contribution. At sea
## level the spray is invisible; it never needs collision, FFT reads or raycasts.
@export_range(0.01, 2.0, 0.01, "suffix:m") var chunks_water_fade_height_m := 0.35:
	set(value):
		chunks_water_fade_height_m = clampf(value, 0.01, 2.0)
		emit_changed()
@export_range(0.01, 2.0, 0.01, "suffix:m") var streaks_water_fade_height_m := 0.45:
	set(value):
		streaks_water_fade_height_m = clampf(value, 0.01, 2.0)
		emit_changed()
@export_range(0.01, 2.0, 0.01, "suffix:m") var mist_water_fade_height_m := 0.65:
	set(value):
		mist_water_fade_height_m = clampf(value, 0.01, 2.0)
		emit_changed()
## A detached child that falls this far below sea level releases its GPU slot
## immediately. This is a cheap sea-level cleanup, not a water collision.
@export_range(0.0, 1.0, 0.01, "suffix:m") var water_kill_depth_m := 0.10:
	set(value):
		water_kill_depth_m = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Art / Motion")
@export_range(0.0, 20.0, 0.1, "suffix:m/s²") var chunks_gravity_mps2 := 9.0:
	set(value):
		chunks_gravity_mps2 = clampf(value, 0.0, 20.0)
		emit_changed()
@export_range(0.0, 20.0, 0.1, "suffix:m/s²") var streaks_gravity_mps2 := 6.0:
	set(value):
		streaks_gravity_mps2 = clampf(value, 0.0, 20.0)
		emit_changed()
@export_range(0.0, 20.0, 0.1, "suffix:m/s²") var mist_gravity_mps2 := 2.5:
	set(value):
		mist_gravity_mps2 = clampf(value, 0.0, 20.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var chunks_wind_drag := 0.30:
	set(value):
		chunks_wind_drag = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var streaks_wind_drag := 0.42:
	set(value):
		streaks_wind_drag = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var mist_wind_drag := 0.75:
	set(value):
		mist_wind_drag = clampf(value, 0.0, 3.0)
		emit_changed()
## Layer weight on the shared global turbulence_strength. The turbulence system
## itself stays global: only the per-layer amount changes.
@export_range(0.0, 3.0, 0.01) var chunks_turbulence_multiplier := 0.65:
	set(value):
		chunks_turbulence_multiplier = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var streaks_turbulence_multiplier := 1.0:
	set(value):
		streaks_turbulence_multiplier = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var mist_turbulence_multiplier := 1.45:
	set(value):
		mist_turbulence_multiplier = clampf(value, 0.0, 3.0)
		emit_changed()

@export_group("Art / Visual Scale")
## Scales the generated billboard/patch dimensions only. The particle world
## transform, the emission footprint and the LOD distances are untouched.
@export_range(0.1, 3.0, 0.01) var chunks_visual_scale := 1.0:
	set(value):
		chunks_visual_scale = clampf(value, 0.1, 3.0)
		emit_changed()
@export_range(0.1, 3.0, 0.01) var streaks_visual_scale := 1.0:
	set(value):
		streaks_visual_scale = clampf(value, 0.1, 3.0)
		emit_changed()
@export_range(0.1, 3.0, 0.01) var mist_visual_scale := 1.0:
	set(value):
		mist_visual_scale = clampf(value, 0.1, 3.0)
		emit_changed()

@export_group("Art / Shape")
## Silhouette pass. Width/length reshape the generated billboard only: the
## particle world transform, emission footprint and LOD distances are untouched.
@export_range(0.20, 3.0, 0.01) var chunks_width_scale := 1.10:
	set(value):
		chunks_width_scale = clampf(value, 0.20, 3.0)
		emit_changed()
@export_range(0.20, 3.0, 0.01) var streaks_width_scale := 0.65:
	set(value):
		streaks_width_scale = clampf(value, 0.20, 3.0)
		emit_changed()
@export_range(0.20, 3.0, 0.01) var mist_width_scale := 1.25:
	set(value):
		mist_width_scale = clampf(value, 0.20, 3.0)
		emit_changed()
@export_range(0.20, 4.0, 0.01) var chunks_length_scale := 0.90:
	set(value):
		chunks_length_scale = clampf(value, 0.20, 4.0)
		emit_changed()
@export_range(0.20, 4.0, 0.01) var streaks_length_scale := 1.55:
	set(value):
		streaks_length_scale = clampf(value, 0.20, 4.0)
		emit_changed()
@export_range(0.20, 4.0, 0.01) var mist_length_scale := 1.10:
	set(value):
		mist_length_scale = clampf(value, 0.20, 4.0)
		emit_changed()
## Procedural alpha-edge softness. Low values give a hard torn edge, high values
## a diffuse one.
@export_range(0.01, 0.50, 0.01) var chunks_edge_softness := 0.12:
	set(value):
		chunks_edge_softness = clampf(value, 0.01, 0.50)
		emit_changed()
@export_range(0.01, 0.50, 0.01) var streaks_edge_softness := 0.08:
	set(value):
		streaks_edge_softness = clampf(value, 0.01, 0.50)
		emit_changed()
@export_range(0.01, 0.50, 0.01) var mist_edge_softness := 0.22:
	set(value):
		mist_edge_softness = clampf(value, 0.01, 0.50)
		emit_changed()
## Silhouette fragmentation. 0 keeps a continuous shape, 1 bites hard into the
## edges. The centre is protected by core_strength, so it never becomes noise.
@export_range(0.0, 1.0, 0.01) var chunks_breakup_strength := 0.38:
	set(value):
		chunks_breakup_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_breakup_strength := 0.48:
	set(value):
		streaks_breakup_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_breakup_strength := 0.22:
	set(value):
		mist_breakup_strength = clampf(value, 0.0, 1.0)
		emit_changed()
## Internal density variation. Never erases the whole particle.
@export_range(0.0, 1.0, 0.01) var chunks_mottle_strength := 0.20:
	set(value):
		chunks_mottle_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_mottle_strength := 0.16:
	set(value):
		streaks_mottle_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_mottle_strength := 0.30:
	set(value):
		mist_mottle_strength = clampf(value, 0.0, 1.0)
		emit_changed()
## End-of-life visual shrink, reaching this fraction at normalized age 1.0.
@export_range(0.1, 1.0, 0.01) var chunks_terminal_scale := 0.65:
	set(value):
		chunks_terminal_scale = clampf(value, 0.1, 1.0)
		emit_changed()
@export_range(0.1, 1.0, 0.01) var streaks_terminal_scale := 0.52:
	set(value):
		streaks_terminal_scale = clampf(value, 0.1, 1.0)
		emit_changed()
@export_range(0.1, 1.0, 0.01) var mist_terminal_scale := 0.78:
	set(value):
		mist_terminal_scale = clampf(value, 0.1, 1.0)
		emit_changed()
## How much a coherent opaque centre survives the fragmentation. High keeps a
## defined core, low gives a diffuse cloud.
@export_range(0.0, 1.0, 0.01) var chunks_core_strength := 0.75:
	set(value):
		chunks_core_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_core_strength := 0.58:
	set(value):
		streaks_core_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_core_strength := 0.35:
	set(value):
		mist_core_strength = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Appearance")
@export_color_no_alpha var chunks_color := Color(0.82, 0.86, 0.86):
	set(value):
		chunks_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var chunks_alpha := 0.82:
	set(value):
		chunks_alpha = clampf(value, 0.0, 1.0)
		emit_changed()
@export_color_no_alpha var streaks_color := Color(0.72, 0.78, 0.78):
	set(value):
		streaks_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_alpha := 0.58:
	set(value):
		streaks_alpha = clampf(value, 0.0, 1.0)
		emit_changed()
@export_color_no_alpha var mist_color := Color(0.66, 0.73, 0.74):
	set(value):
		mist_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_alpha := 0.22:
	set(value):
		mist_alpha = clampf(value, 0.0, 1.0)
		emit_changed()
