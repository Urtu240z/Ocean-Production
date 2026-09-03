@tool
class_name Ocean
extends Node3D
## API pública P0. El nodo expone authoring; la simulación vive en OpenOceanFFT.

const OpenOcean := preload("res://addons/ocean/fft/open_ocean_fft.gd")

enum DebugView { OFF, NORMALS }

@export_group("General")
@export var enabled := true:
	set(value):
		enabled = value
		if _initializing:
			_rebuild_requested = true
			return
		if is_inside_tree():
			if not enabled:
				shutdown()
			elif open_ocean_fft and _open_ocean == null:
				initialize()
@export var sea_level := 0.0:
	set(value):
		sea_level = value
		_rebuild_if_ready()
@export var simulation_seed := 1:
	set(value):
		simulation_seed = value
		_rebuild_if_ready()
@export var quality_profile: Resource

@export_group("Sea State")
@export var wave_profile: Resource
@export var significant_wave_height_m := 2.574:
	set(value):
		significant_wave_height_m = maxf(value, 0.0)
		_rebuild_if_ready()
@export var wind_speed_mps := 18.0:
	set(value):
		wind_speed_mps = maxf(value, 0.0)
		_rebuild_if_ready()
@export var wind_direction_degrees := 5.71:
	set(value):
		wind_direction_degrees = value
		_rebuild_if_ready()
@export_range(0.0, 1.0, 0.01) var swell := 0.80:
	set(value):
		swell = clampf(value, 0.0, 1.0)
		_rebuild_if_ready()

@export_group("Systems")
@export var open_ocean_fft := true:
	set(value):
		open_ocean_fft = value
		if _initializing:
			_rebuild_requested = true
			return
		if is_inside_tree():
			if not value:
				shutdown()
			elif enabled and _open_ocean == null:
				initialize()
@export var coastal := false:
	set(value):
		coastal = value
		if _open_ocean != null: _open_ocean.set_coastal(coastal, coastal_bake)
@export var coastal_bake: Resource:
	set(value):
		coastal_bake = value
		if _open_ocean != null: _open_ocean.set_coastal(coastal, coastal_bake)
@export var crest_foam := true:
	set(value):
		crest_foam = value
		if _open_ocean != null: _open_ocean.set_crest_foam(crest_foam)
@export var surface_foam := true:
	set(value):
		surface_foam = value
		if _open_ocean != null: _open_ocean.set_surface_foam(surface_foam)

@export_group("Diagnostics")
@export var performance_overlay := false:
	set(value):
		performance_overlay = value
		_update_overlay()
@export_enum("Off", "Normals") var debug_view: int = DebugView.OFF:
	set(value):
		debug_view = clampi(value, DebugView.OFF, DebugView.NORMALS)
		if _open_ocean != null: _open_ocean.set_debug_view(debug_view)

var _open_ocean: Node3D
var _overlay: Label
var _initializing := false
var _rebuild_requested := false


func _ready() -> void:
	if Engine.is_editor_hint(): return
	if enabled and open_ocean_fft: initialize()


func initialize() -> bool:
	if _initializing:
		_rebuild_requested = true
		return false
	if _open_ocean != null: return true
	if wave_profile == null or quality_profile == null:
		push_error("Ocean necesita Wave Profile y Quality Profile.")
		return false
	_initializing = true
	var candidate := OpenOcean.new()
	candidate.name = &"OpenOceanFFT"
	add_child(candidate)
	var initialized := candidate.initialize(wave_profile, quality_profile, simulation_seed, sea_level, significant_wave_height_m, wind_speed_mps, wind_direction_degrees, swell, crest_foam, surface_foam)
	if initialized:
		# Publicar sólo un runtime completamente construido. Los setters pueden
		# solicitar un rebuild durante la construcción, pero nunca desmontarlo.
		_open_ocean = candidate
		_open_ocean.set_enabled(enabled and open_ocean_fft)
		_open_ocean.set_debug_view(debug_view)
		_open_ocean.set_coastal(coastal, coastal_bake)
		_open_ocean.set_crest_foam(crest_foam)
		_open_ocean.set_surface_foam(surface_foam)
		_update_overlay()
	else:
		candidate.shutdown()
		candidate.queue_free()
	_initializing = false
	if _rebuild_requested:
		_rebuild_requested = false
		_rebuild_if_ready()
	return initialized


func shutdown() -> void:
	if _initializing:
		_rebuild_requested = true
		return
	if _open_ocean != null:
		_open_ocean.shutdown()
		_open_ocean.queue_free()
		_open_ocean = null
	if _overlay != null:
		_overlay.queue_free()
		_overlay = null


func _exit_tree() -> void:
	shutdown()


func _rebuild_if_ready() -> void:
	if _initializing:
		_rebuild_requested = true
		return
	if not is_inside_tree() or _open_ocean == null: return
	shutdown()
	if enabled and open_ocean_fft: initialize()


func _update_overlay() -> void:
	if not is_inside_tree(): return
	if not performance_overlay:
		if _overlay != null:
			_overlay.queue_free()
			_overlay = null
		return
	if _overlay == null:
		_overlay = Label.new()
		_overlay.position = Vector2(16.0, 16.0)
		_overlay.add_theme_font_size_override("font_size", 16)
		get_tree().root.add_child.call_deferred(_overlay)
	_overlay.text = "Ocean P3\nLONG · MID · SHORT\nJONSWAP + Hasselmann"
