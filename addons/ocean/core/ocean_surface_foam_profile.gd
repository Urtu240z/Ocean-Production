@tool
class_name OceanSurfaceFoamProfile
extends Resource
## P3 authoring and presentation values. Solver topology remains internal.

@export_group("Surface Foam / Source")
@export_range(0.0, 1.0, 0.01) var whitecap_threshold := 0.58:
	set(value):
		whitecap_threshold = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 10.0, 0.01) var source_gain := 2.05:
	set(value):
		source_gain = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var selectivity := 0.28:
	set(value):
		selectivity = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.02, 1.0, 0.01, "suffix:s") var attack := 0.16:
	set(value):
		attack = maxf(value, 0.02)
		emit_changed()
@export_range(0.1, 5.0, 0.05, "suffix:s") var lifetime := 1.10:
	set(value):
		lifetime = maxf(value, 0.1)
		emit_changed()
@export_range(0.0, 1.5, 0.01) var evolution_speed := 0.59:
	set(value):
		evolution_speed = maxf(value, 0.0)
		emit_changed()
@export_group("Surface Foam / MID fold")
@export_range(0.0, 1.0, 0.01) var mid_fold_start := 0.0:
	set(value):
		mid_fold_start = clampf(value, 0.0, 1.0)
		if mid_fold_end < mid_fold_start: mid_fold_end = mid_fold_start
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mid_fold_end := 1.0:
	set(value):
		mid_fold_end = clampf(value, mid_fold_start, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mid_fold_influence := 1.0:
	set(value):
		mid_fold_influence = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Surface Foam / Presentation")
@export_range(0.0, 4.0, 0.01) var intensity := 2.52:
	set(value):
		intensity = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var threshold_visual := 0.11:
	set(value):
		threshold_visual = clampf(value, 0.0, 1.0)
		emit_changed()
@export var distance_fade_range_m := Vector2(200.0, 600.0):
	set(value):
		distance_fade_range_m = Vector2(maxf(value.x, 0.0), maxf(value.y, maxf(value.x, 0.0)))
		emit_changed()
@export_color_no_alpha var color := Color(0.8954583, 0.9249786, 0.9149783):
	set(value):
		color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var roughness := 0.82:
	set(value):
		roughness = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var specular := 0.37:
	set(value):
		specular = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var ocean_coupling := 0.35:
	set(value):
		ocean_coupling = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Surface Foam / Micro detail")
@export var stochastic_deperiodization_enabled := true:
	set(value):
		stochastic_deperiodization_enabled = value
		emit_changed()
@export_range(16.0, 96.0, 0.5, "suffix:m") var stochastic_cell_size_m := 32.0:
	set(value):
		stochastic_cell_size_m = clampf(value, 16.0, 96.0)
		emit_changed()

@export_group("Surface Foam / Crest Filigree")
@export_range(0.0, 1.0, 0.01) var crest_filigree_whitecap := 0.40:
	set(value):
		crest_filigree_whitecap = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var crest_residual_filigree_strength := 0.62:
	set(value):
		crest_residual_filigree_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.1, 4.0, 0.01) var crest_filigree_contrast := 1.0:
	set(value):
		crest_filigree_contrast = maxf(value, 0.1)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var crest_filigree_threshold := 0.0:
	set(value):
		crest_filigree_threshold = clampf(value, 0.0, 1.0)
		emit_changed()
