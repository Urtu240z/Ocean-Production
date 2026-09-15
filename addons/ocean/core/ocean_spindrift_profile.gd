@tool
class_name OceanSpindriftProfile
extends Resource
## Authoring profile for the optional Ocean V4 wind-blown crest spray.
## The controller owns the GPU particles; this resource only owns tunable values.

@export_group("Source")
@export_range(0.0, 1.0, 0.01) var crest_threshold := 0.58:
	set(value):
		crest_threshold = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.01, 0.5, 0.01) var crest_softness := 0.16:
	set(value):
		crest_softness = clampf(value, 0.01, 0.5)
		emit_changed()
@export_range(0.0, 0.1, 0.001) var source_spawn_min := 0.002:
	set(value):
		source_spawn_min = clampf(value, 0.0, 0.1)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var min_wave_strength := 0.12:
	set(value):
		min_wave_strength = maxf(value, 0.0)
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
