@tool
class_name Ocean
extends Node3D
## API pública P0. El nodo expone authoring; la simulación vive en OpenOceanFFT.

const OpenOcean := preload("res://addons/ocean/fft/open_ocean_fft.gd")
const UnderwaterMedium := preload("res://addons/ocean/underwater/ocean_underwater_medium.gd")
const AUTHORING_REBUILD_DEBOUNCE_S := 0.15

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
				_rebuild_debounce_remaining = -1.0
				set_process(false)
				shutdown()
			elif open_ocean_fft and _open_ocean == null:
				initialize()
@export var sea_level := 0.0:
	set(value):
		sea_level = value
		_sync_underwater_medium()
		_request_rebuild()
@export var simulation_seed := 1:
	set(value):
		simulation_seed = value
		_request_rebuild()
@export var quality_profile: Resource:
	set(value):
		if quality_profile == value:
			_connect_profile_changed(quality_profile, _on_quality_profile_changed)
			return
		_disconnect_profile_changed(quality_profile, _on_quality_profile_changed)
		quality_profile = value
		_connect_profile_changed(quality_profile, _on_quality_profile_changed)
		_request_rebuild()

@export_group("Sea State")
@export var wave_profile: Resource:
	set(value):
		if wave_profile == value:
			_connect_profile_changed(wave_profile, _on_wave_profile_changed)
			return
		_disconnect_profile_changed(wave_profile, _on_wave_profile_changed)
		wave_profile = value
		_connect_profile_changed(wave_profile, _on_wave_profile_changed)
		_request_rebuild()
@export var significant_wave_height_m := 2.574:
	set(value):
		significant_wave_height_m = maxf(value, 0.0)
		_request_rebuild()
@export var wind_speed_mps := 18.0:
	set(value):
		wind_speed_mps = maxf(value, 0.0)
		_request_rebuild()
@export var wind_direction_degrees := 5.71:
	set(value):
		wind_direction_degrees = value
		_request_rebuild()
@export_range(0.0, 1.0, 0.01) var swell := 0.80:
	set(value):
		swell = clampf(value, 0.0, 1.0)
		_request_rebuild()

@export_group("Systems")
@export var open_ocean_fft := true:
	set(value):
		open_ocean_fft = value
		if _initializing:
			_rebuild_requested = true
			return
		if is_inside_tree():
			if not value:
				_rebuild_debounce_remaining = -1.0
				set_process(false)
				shutdown()
			elif enabled and _open_ocean == null:
				initialize()
@export var coastal := false:
	set(value):
		coastal = value
		_sync_coastal_runtime()
@export var crest_foam := true:
	set(value):
		crest_foam = value
		if _open_ocean != null: _open_ocean.set_crest_foam(crest_foam)
@export var surface_foam := true:
	set(value):
		surface_foam = value
		if _open_ocean != null: _open_ocean.set_surface_foam(surface_foam)

@export var optics := false:
	set(value):
		optics = value
		if _open_ocean != null:
			_open_ocean.set_optics(optics, optics_profile)
			_sync_coastal_runtime()
@export var reflections := false:
	set(value):
		reflections = value
		if _open_ocean != null:
			_open_ocean.set_reflections(reflections, reflection_profile)
@export var surface_detail := false:
	set(value):
		surface_detail = value
		if _open_ocean != null:
			_open_ocean.set_surface_detail(surface_detail, surface_detail_profile)
@export var underwater_medium := false:
	set(value):
		underwater_medium = value
		_sync_underwater_medium()

@export_group("System Resources")
@export var coastal_bake: Resource:
	set(value):
		coastal_bake = value
		_sync_coastal_runtime()
@export var crest_foam_profile: OceanCrestFoamProfile:
	set(value):
		if crest_foam_profile == value:
			_connect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
			return
		_disconnect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
		crest_foam_profile = value
		_connect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
		if _open_ocean != null: _open_ocean.set_crest_foam_profile(crest_foam_profile)
@export var surface_foam_profile: OceanSurfaceFoamProfile:
	set(value):
		if surface_foam_profile == value:
			_connect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
			return
		_disconnect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
		surface_foam_profile = value
		_connect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
		if _open_ocean != null: _open_ocean.set_surface_foam_profile(surface_foam_profile)
@export var optics_profile: OceanOpticsProfile:
	set(value):
		if optics_profile == value:
			_connect_profile_changed(optics_profile, _on_optics_profile_changed)
			return
		_disconnect_profile_changed(optics_profile, _on_optics_profile_changed)
		optics_profile = value
		_connect_profile_changed(optics_profile, _on_optics_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_optics_profile(optics_profile)
			_sync_coastal_runtime()
@export var reflection_profile: OceanReflectionProfile:
	set(value):
		if reflection_profile == value:
			_connect_profile_changed(reflection_profile, _on_reflection_profile_changed)
			return
		_disconnect_profile_changed(reflection_profile, _on_reflection_profile_changed)
		reflection_profile = value
		_connect_profile_changed(reflection_profile, _on_reflection_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_reflection_profile(reflection_profile)
@export var surface_detail_profile: OceanSurfaceDetailProfile:
	set(value):
		if surface_detail_profile == value:
			_connect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
			return
		_disconnect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
		surface_detail_profile = value
		_connect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
		if _open_ocean != null:
			_open_ocean.set_surface_detail_profile(surface_detail_profile)
@export var underwater_medium_profile: OceanUnderwaterMediumProfile:
	set(value):
		if underwater_medium_profile == value:
			_connect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
			return
		_disconnect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
		underwater_medium_profile = value
		_connect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
		_sync_underwater_medium()

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
var _underwater_medium: OceanUnderwaterMedium
var _overlay: Label
var _initializing := false
var _rebuild_requested := false
var _rebuild_debounce_remaining := -1.0


func _ready() -> void:
	_connect_profile_changed(wave_profile, _on_wave_profile_changed)
	_connect_profile_changed(quality_profile, _on_quality_profile_changed)
	_connect_profile_changed(optics_profile, _on_optics_profile_changed)
	_connect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
	_connect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
	_connect_profile_changed(reflection_profile, _on_reflection_profile_changed)
	_connect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
	_connect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
	set_process(false)
	if Engine.is_editor_hint(): return
	_sync_underwater_medium()
	if enabled and open_ocean_fft: initialize()
	# In inherited validation scenes an exported P6 override can be applied after
	# this first ready pass. Re-sync once the scene's final property state exists.
	call_deferred(&"_sync_underwater_medium")


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
	var initialized := candidate.initialize(wave_profile, quality_profile, simulation_seed, sea_level, significant_wave_height_m, wind_speed_mps, wind_direction_degrees, swell, crest_foam, surface_foam, crest_foam_profile, surface_foam_profile)
	if initialized:
		# Publicar sólo un runtime completamente construido. Los setters pueden
		# solicitar un rebuild durante la construcción, pero nunca desmontarlo.
		_open_ocean = candidate
		_open_ocean.set_enabled(enabled and open_ocean_fft)
		_open_ocean.set_debug_view(debug_view)
		_open_ocean.set_crest_foam(crest_foam)
		_open_ocean.set_surface_foam(surface_foam)
		_open_ocean.set_crest_foam_profile(crest_foam_profile)
		_open_ocean.set_surface_foam_profile(surface_foam_profile)
		_open_ocean.set_optics(optics, optics_profile)
		_sync_coastal_runtime()
		_open_ocean.set_reflections(reflections, reflection_profile)
		_open_ocean.set_surface_detail(surface_detail, surface_detail_profile)
		_sync_underwater_medium()
		_update_overlay()
	else:
		candidate.shutdown()
		candidate.queue_free()
	_initializing = false
	if _rebuild_requested:
		_rebuild_requested = false
		_request_rebuild()
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
	_shutdown_underwater_medium()


func _exit_tree() -> void:
	_rebuild_debounce_remaining = -1.0
	set_process(false)
	_disconnect_profile_changed(wave_profile, _on_wave_profile_changed)
	_disconnect_profile_changed(quality_profile, _on_quality_profile_changed)
	_disconnect_profile_changed(optics_profile, _on_optics_profile_changed)
	_disconnect_profile_changed(crest_foam_profile, _on_crest_foam_profile_changed)
	_disconnect_profile_changed(surface_foam_profile, _on_surface_foam_profile_changed)
	_disconnect_profile_changed(reflection_profile, _on_reflection_profile_changed)
	_disconnect_profile_changed(surface_detail_profile, _on_surface_detail_profile_changed)
	_disconnect_profile_changed(underwater_medium_profile, _on_underwater_medium_profile_changed)
	shutdown()


func _on_wave_profile_changed() -> void:
	_request_rebuild()


func _on_quality_profile_changed() -> void:
	_request_rebuild()


func _on_optics_profile_changed() -> void:
	if _open_ocean != null:
		_open_ocean.set_optics_profile(optics_profile)
		_sync_coastal_runtime()


func _on_crest_foam_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_crest_foam_profile(crest_foam_profile)


func _on_surface_foam_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_surface_foam_profile(surface_foam_profile)


func _on_reflection_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_reflection_profile(reflection_profile)


func _on_surface_detail_profile_changed() -> void:
	if _open_ocean != null: _open_ocean.set_surface_detail_profile(surface_detail_profile)


func _on_underwater_medium_profile_changed() -> void:
	# Resource edits update only CPU packet state. RenderingDevice work stays render-thread owned.
	_sync_underwater_medium()


func _sync_underwater_medium() -> void:
	if Engine.is_editor_hint() or not is_inside_tree(): return
	if not enabled or not underwater_medium:
		_shutdown_underwater_medium()
		return
	if _open_ocean == null:
		return
	if _underwater_medium == null:
		_underwater_medium = UnderwaterMedium.new()
		_underwater_medium.name = &"OceanUnderwaterMedium"
		add_child(_underwater_medium)
		_underwater_medium.configure(sea_level, underwater_medium_profile)
		_underwater_medium.set_surface_source(_open_ocean)
	else:
		_underwater_medium.update(sea_level, underwater_medium_profile)
		_underwater_medium.set_surface_source(_open_ocean)


func _shutdown_underwater_medium() -> void:
	if _underwater_medium == null: return
	_underwater_medium.shutdown()
	_underwater_medium.queue_free()
	_underwater_medium = null


func _sync_coastal_runtime() -> void:
	if _open_ocean == null:
		return
	# Coastal waves and P4 optical seabed authority are the only consumers of a
	# bake. When both are OFF, passing null makes the OFF path real: no validation,
	# no ImageTextures and no interaction with editor placeholders.
	var required_bake: Resource = coastal_bake if coastal or optics else null
	_open_ocean.set_coastal(coastal, required_bake)


func _connect_profile_changed(profile: Resource, callback: Callable) -> void:
	if profile == null: return
	if profile.has_method("ensure_change_propagation"):
		profile.ensure_change_propagation()
	if not profile.changed.is_connected(callback):
		profile.changed.connect(callback)


func _disconnect_profile_changed(profile: Resource, callback: Callable) -> void:
	if profile != null and profile.changed.is_connected(callback):
		profile.changed.disconnect(callback)


func _request_rebuild() -> void:
	if _initializing:
		_rebuild_requested = true
		return
	if Engine.is_editor_hint() or not is_inside_tree() or _open_ocean == null: return
	_rebuild_debounce_remaining = AUTHORING_REBUILD_DEBOUNCE_S
	set_process(true)


func _process(delta: float) -> void:
	if _rebuild_debounce_remaining < 0.0: return
	_rebuild_debounce_remaining -= delta
	if _rebuild_debounce_remaining > 0.0: return
	_rebuild_debounce_remaining = -1.0
	set_process(false)
	_rebuild_if_ready()


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
