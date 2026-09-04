@tool
class_name OceanCrestFoamProfile
extends Resource
## P2 authoring and presentation values. GPU layout and ownership stay internal.

@export_group("Crest Foam / LONG")
@export_range(0.0, 1.0, 0.01) var long_whitecap_threshold := 0.62:
	set(value):
		long_whitecap_threshold = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var long_amount := 1.60:
	set(value):
		long_amount = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 20.0, 0.01) var long_decay := 4.50:
	set(value):
		long_decay = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var long_weight := 1.00:
	set(value):
		long_weight = maxf(value, 0.0)
		emit_changed()
@export_group("Crest Foam / MID")
@export_range(0.0, 1.0, 0.01) var mid_whitecap_threshold := 0.66:
	set(value):
		mid_whitecap_threshold = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var mid_amount := 0.42:
	set(value):
		mid_amount = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 20.0, 0.01) var mid_decay := 4.50:
	set(value):
		mid_decay = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var mid_weight := 0.65:
	set(value):
		mid_weight = maxf(value, 0.0)
		emit_changed()

@export_group("Crest Foam / SHORT")
@export_range(0.0, 1.0, 0.01) var short_whitecap_threshold := 0.68:
	set(value):
		short_whitecap_threshold = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var short_amount := 0.22:
	set(value):
		short_amount = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 20.0, 0.01) var short_decay := 4.50:
	set(value):
		short_decay = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var short_weight := 0.10:
	set(value):
		short_weight = maxf(value, 0.0)
		emit_changed()

@export_group("Crest Foam / Presentation")
@export_range(0.0, 4.0, 0.01) var intensity := 0.96:
	set(value):
		intensity = maxf(value, 0.0)
		emit_changed()
@export_range(0.1, 4.0, 0.01) var contrast := 1.19:
	set(value):
		contrast = maxf(value, 0.1)
		emit_changed()
@export var distance_fade_range_m := Vector2(0.0, 5000.0):
	set(value):
		distance_fade_range_m = Vector2(maxf(value.x, 0.0), maxf(value.y, maxf(value.x, 0.0)))
		emit_changed()
@export_range(0.0, 1.0, 0.01) var detail_contribution := 0.35:
	set(value):
		detail_contribution = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var breakup_strength := 0.45:
	set(value):
		breakup_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(1.0, 200.0, 0.5, "suffix:m") var breakup_world_size_m := 14.0:
	set(value):
		breakup_world_size_m = maxf(value, 1.0)
		emit_changed()
@export_range(0.01, 0.49, 0.01) var edge_softness := 0.32:
	set(value):
		edge_softness = clampf(value, 0.01, 0.49)
		emit_changed()
@export_color_no_alpha var residual_color := Color(1.84945, 1.84945, 1.84945):
	set(value):
		residual_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var residual_roughness := 0.88:
	set(value):
		residual_roughness = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var residual_specular := 0.18:
	set(value):
		residual_specular = clampf(value, 0.0, 1.0)
		emit_changed()
