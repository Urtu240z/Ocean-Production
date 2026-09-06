class_name OceanUnderwaterMedium
extends Node
## Main-thread P6 owner. It only publishes authoritative clipmap arrays and
## valid FFT source RIDs; the effect owns every P6 RenderingDevice resource.

const EFFECT := preload("res://addons/ocean/underwater/ocean_underwater_medium_effect.gd")

var _effect: OceanUnderwaterMediumEffect
var _compositor: Compositor
var _attached := false
var _sea_level := 0.0
var _profile: OceanUnderwaterMediumProfile
var _surface_source: Object
var _geometry_published := false
var _sources_published := false
var _raster_prepared := false


func configure(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_effect = EFFECT.new()
	_push_state()
	call_deferred(&"_attach")


func set_surface_source(source: Object) -> void:
	if _surface_source == source: return
	_surface_source = source
	_geometry_published = false
	_sources_published = false
	_raster_prepared = false
	_try_publish_raster_inputs()


func _try_publish_raster_inputs() -> void:
	if _effect == null or _surface_source == null or not is_instance_valid(_surface_source): return
	if not _surface_source.has_method(&"get_underwater_medium_raster_surface") or not _surface_source.has_method(&"get_underwater_medium_raster_sources"): return
	if not _geometry_published:
		var surface := _surface_source.get_underwater_medium_raster_surface() as OceanClipmapSurface
		if surface != null and is_instance_valid(surface):
			var geometry := surface.get_underwater_medium_raster_geometry()
			if not geometry.is_empty():
				_effect.set_raster_geometry(geometry)
				_geometry_published = true
	if not _sources_published:
		var sources: Dictionary = _surface_source.get_underwater_medium_raster_sources()
		var long_rid: RID = sources.get("long", RID())
		var mid_rid: RID = sources.get("mid", RID())
		var short_rid: RID = sources.get("short", RID())
		if long_rid.is_valid() and mid_rid.is_valid() and short_rid.is_valid():
			_effect.set_raster_sources(sources)
			_sources_published = true
	if _attached and _geometry_published and _sources_published and not _raster_prepared:
		# RD allocation remains render-thread only.
		RenderingServer.call_on_render_thread(_effect.prepare_resources)
		_raster_prepared = true


func update(sea_level: float, profile: OceanUnderwaterMediumProfile) -> void:
	_sea_level = sea_level
	_profile = profile
	_push_state()


func _process(_delta: float) -> void:
	_try_publish_raster_inputs()
	_push_state()


func _push_state() -> void:
	if _effect == null: return
	var profile := _profile
	_effect.configure(_sea_level, profile.waterline_mask_debug if profile != null else false, profile.absorption_coeff_rgb if profile != null else Vector3(0.35, 0.14, 0.10), profile.absorption_scale if profile != null else 0.43, profile.scattering_color if profile != null else Color(0.0024315654, 0.09275196, 0.13127226), profile.scattering_strength if profile != null else 1.0, profile.scattering_density if profile != null else 0.15, profile.maximum_optical_distance_m if profile != null else 120.0, profile.enter_margin_m if profile != null else 0.05, profile.exit_margin_m if profile != null else 0.05)


func _attach() -> void:
	if _attached or not is_inside_tree() or _effect == null: return
	var scene := get_tree().current_scene
	var world := scene.find_child("WorldEnvironment", true, false) if scene != null else null
	if world is WorldEnvironment:
		_compositor = world.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			world.compositor = _compositor
	else:
		var camera := get_viewport().get_camera_3d()
		if camera == null:
			push_warning("Ocean Underwater Medium needs a WorldEnvironment or active Camera3D.")
			return
		_compositor = camera.compositor
		if _compositor == null:
			_compositor = Compositor.new()
			camera.compositor = _compositor
	var effects := _compositor.compositor_effects.duplicate()
	effects.append(_effect)
	_compositor.compositor_effects = effects
	_attached = true
	_try_publish_raster_inputs()
	RenderingServer.call_on_render_thread(_effect.prepare_resources)


func shutdown() -> void:
	set_process(false)
	if _effect == null: return
	_effect.enabled = false
	_effect.begin_shutdown()
	_effect.configure(_sea_level, false, Vector3.ZERO, 0.0, Color.BLACK, 0.0, 0.0, 1.0, 0.05, 0.05)
	if _attached and _compositor != null:
		var effects := _compositor.compositor_effects.duplicate()
		effects.erase(_effect)
		_compositor.compositor_effects = effects
	RenderingServer.call_on_render_thread(_effect.free_resources)
	_effect = null
	_attached = false
	_geometry_published = false
	_sources_published = false
	_raster_prepared = false
	_surface_source = null


func _exit_tree() -> void:
	shutdown()
